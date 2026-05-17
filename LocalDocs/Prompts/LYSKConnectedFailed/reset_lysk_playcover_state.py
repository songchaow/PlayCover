#!/usr/bin/env python3
"""
将 PlayCover 管理的某个 iOS App 恢复到“接近初装后的本地状态”。

默认目标：`com.papegames.lysk`

会执行的动作：
1. 定位并终止该 App 当前运行中的进程（只匹配目标 bundle 的 `Unity-iPhone`）
2. 删除该 App 的沙盒 `Data` 目录
3. 删除 PlayCover 侧与该 bundle 相关的设置、PlayChain、entitlements、keymapping
4. 删除 PlayCover 侧的运行诊断、shader corpus、shader source diagnostics
5. 打印清理结果与残留项

注意：
- 该脚本是破坏性操作，会清空本地数据。
- 它不会删除安装包本体 `.app`，只清空运行数据与 PlayCover 侧状态。
- 如需先预览将删除哪些路径，可先加 `--dry-run`。

示例：
    python3 reset_lysk_playcover_state.py --dry-run
    python3 reset_lysk_playcover_state.py --yes
    python3 reset_lysk_playcover_state.py --bundle-id com.papegames.lysk --yes
"""

from __future__ import annotations

import argparse
import os
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path

DEFAULT_BUNDLE_ID = "com.papegames.lysk"
DEFAULT_PLAYCOVER_CONTAINER = Path.home() / "Library/Containers/io.playcover.PlayCover"


def build_target_paths(bundle_id: str, playcover_container: Path) -> list[Path]:
    """构造本次要清理的关键路径。"""
    app_container = Path.home() / "Library/Containers" / bundle_id

    return [
        app_container / "Data",
        playcover_container / "App Settings" / f"{bundle_id}.plist",
        playcover_container / "PlayChain" / f"{bundle_id}.db",
        playcover_container / "Entitlements" / f"{bundle_id}.plist",
        playcover_container / "Keymapping" / f"{bundle_id}.plist",
        playcover_container / "Keymapping" / bundle_id,
        playcover_container / "RuntimeLaunchDiagnostics" / bundle_id,
        playcover_container / "ShaderCorpus" / bundle_id,
        playcover_container / "ShaderSourceDiagnostics" / bundle_id,
    ]


def find_running_target_pids(bundle_id: str) -> list[int]:
    """只匹配目标 bundle 对应的 Unity 进程，避免误杀其他游戏。"""
    marker = f"/{bundle_id}.app/Unity-iPhone"
    result = subprocess.run(
        ["ps", "ax", "-o", "pid=,command="],
        capture_output=True,
        text=True,
        check=False,
    )

    pids: list[int] = []
    for line in result.stdout.splitlines():
        line = line.strip()
        if not line or marker not in line:
            continue
        pid_str, _, _ = line.partition(" ")
        pid_str = pid_str.strip()
        if pid_str.isdigit():
            pids.append(int(pid_str))
    return sorted(set(pids))


def is_pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def terminate_target_processes(bundle_id: str, *, dry_run: bool) -> list[int]:
    pids = find_running_target_pids(bundle_id)
    if not pids:
        print("[process] 未发现目标进程")
        return []

    print(f"[process] 命中目标进程 PID: {', '.join(map(str, pids))}")
    if dry_run:
        print("[process] dry-run 模式：跳过终止进程")
        return pids

    for pid in pids:
        try:
            os.kill(pid, signal.SIGTERM)
        except OSError as exc:
            print(f"[process] SIGTERM 失败 pid={pid}: {exc}")

    deadline = time.time() + 3.0
    while time.time() < deadline and any(is_pid_alive(pid) for pid in pids):
        time.sleep(0.2)

    survivors = [pid for pid in pids if is_pid_alive(pid)]
    if survivors:
        print(f"[process] 仍存活，升级为 SIGKILL: {', '.join(map(str, survivors))}")
        for pid in survivors:
            try:
                os.kill(pid, signal.SIGKILL)
            except OSError as exc:
                print(f"[process] SIGKILL 失败 pid={pid}: {exc}")

        deadline = time.time() + 2.0
        while time.time() < deadline and any(is_pid_alive(pid) for pid in survivors):
            time.sleep(0.1)

    still_alive = [pid for pid in pids if is_pid_alive(pid)]
    if still_alive:
        print(f"[process] 警告：以下 PID 仍然存活: {', '.join(map(str, still_alive))}")
    else:
        print("[process] 目标进程已退出")

    return pids


def remove_path(path: Path, *, dry_run: bool) -> tuple[str, Path]:
    if not path.exists():
        return ("missing", path)

    if dry_run:
        return ("would_remove", path)

    try:
        if path.is_dir() and not path.is_symlink():
            shutil.rmtree(path)
        else:
            path.unlink()
        return ("removed", path)
    except Exception as exc:  # noqa: BLE001
        print(f"[remove] 删除失败: {path} -> {exc}")
        return ("failed", path)


def verify_remaining(paths: list[Path]) -> list[Path]:
    return [path for path in paths if path.exists()]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="清空某个 PlayCover app 的本地运行数据与 PlayCover 侧状态"
    )
    parser.add_argument(
        "--bundle-id",
        default=DEFAULT_BUNDLE_ID,
        help=f"目标 bundle id，默认 {DEFAULT_BUNDLE_ID}",
    )
    parser.add_argument(
        "--playcover-container",
        default=str(DEFAULT_PLAYCOVER_CONTAINER),
        help=f"PlayCover 容器根目录，默认 {DEFAULT_PLAYCOVER_CONTAINER}",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="只打印将执行的操作，不实际删除",
    )
    parser.add_argument(
        "--yes",
        action="store_true",
        help="跳过二次确认，直接执行",
    )
    return parser.parse_args()


def confirm_or_exit(args: argparse.Namespace, paths: list[Path]) -> None:
    print("将处理以下路径：")
    for path in paths:
        print(f"  - {path}")

    if args.dry_run:
        print("\n当前为 dry-run 模式，不会真的删除。")
        return

    if args.yes:
        return

    reply = input("\n这是破坏性操作，输入 yes 继续：").strip().lower()
    if reply != "yes":
        print("已取消。")
        raise SystemExit(1)


def main() -> int:
    args = parse_args()
    bundle_id = args.bundle_id
    playcover_container = Path(args.playcover_container).expanduser().resolve()
    paths = build_target_paths(bundle_id, playcover_container)

    print(f"[target] bundle_id={bundle_id}")
    print(f"[target] playcover_container={playcover_container}")

    confirm_or_exit(args, paths)
    terminate_target_processes(bundle_id, dry_run=args.dry_run)

    print("\n[cleanup] 开始清理")
    results: list[tuple[str, Path]] = []
    for path in paths:
        result = remove_path(path, dry_run=args.dry_run)
        results.append(result)
        print(f"  - {result[0]:>12}  {result[1]}")

    if args.dry_run:
        print("\n[dry-run] 结束")
        return 0

    remaining = verify_remaining(paths)
    print("\n[verify] 校验结果")
    if remaining:
        print("以下路径仍然存在：")
        for path in remaining:
            print(f"  - {path}")
        return 2

    print("所有目标路径均已删除。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
