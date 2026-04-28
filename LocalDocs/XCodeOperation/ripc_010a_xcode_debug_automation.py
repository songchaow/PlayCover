#!/usr/bin/env python3
"""
RIPC-010-A: Xcode 真机调试自动化脚本

基于 xcode_general_ops.py 的 JXA/Accessibility 基础能力，自动化
Xcode 真机调试的关键步骤：Attach to Process → 加载 LLDB 脚本 →
设置断点 → 自动 continue。

环境要求:
    - macOS 辅助功能权限已授予执行终端
    - Xcode 16.4+ 已安装
    - 真机 iPad 已连接并通过 Xcode 侧边栏可见
    - 目标 app (com.songdog.ripc.debug) 已在真机上安装并运行

用法:
    python3 ripc_010a_xcode_debug_automation.py attach
    python3 ripc_010a_xcode_debug_automation.py load-script /path/to/probe.py
    python3 ripc_010a_xcode_debug_automation.py full /path/to/probe.py

注意:
    本脚本当前实现 Attach to Process 和 Debug Console 显示，
    Breakpoint Navigator 自动化和 Debug Console 命令输入需要
    根据实际 Xcode UI 结构进一步迭代。
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time
from pathlib import Path
from typing import Optional

# Add parent dir so we can import xcode_general_ops
SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from xcode_general_ops import XcodeGeneral, _jxa


class XcodeDeviceDebug:
    """Xcode 真机调试 GUI 自动化协调器。"""

    def __init__(self, delay: float = 0.8):
        self.xc = XcodeGeneral(delay=delay)

    # ═══════════════════ 设备/进程 attach ═══════════════════

    def activate_xcode(self) -> bool:
        """确保 Xcode 在前台。"""
        try:
            self.xc.activate()
            return True
        except RuntimeError as e:
            print(f"[ripc-010a-xcode] activate failed: {e}")
            return False

    def is_xcode_running(self) -> bool:
        r = subprocess.run(["pgrep", "-x", "Xcode"], capture_output=True, timeout=3)
        return r.returncode == 0

    def attach_to_process(self, process_name: str = "NGR") -> bool:
        """通过 Debug → Attach to Process 附加到指定进程。

        流程:
        1. 打开 Debug → Attach to Process 子菜单
        2. 扫描子菜单项，找到匹配 process_name 的项
        3. 点击该项
        """
        self.activate_xcode()
        time.sleep(0.5)

        # 展开 Debug → Attach to Process 子菜单（不点击，先列出）
        try:
            items = self.xc.get_submenu_items("Debug", "Attach to Process")
        except RuntimeError as e:
            print(f"[ripc-010a-xcode] Cannot read Attach to Process submenu: {e}")
            return False

        print(f"[ripc-010a-xcode] Attach to Process candidates:")
        for item in items:
            status = "✅" if item.get("enabled") else "❌"
            print(f"  {status} {item.get('name', '')}")

        target = None
        for item in items:
            name = item.get("name", "")
            if process_name in name:
                target = name
                break

        if target is None:
            print(f"[ripc-010a-xcode] ERROR: No process matching '{process_name}' found")
            return False

        if not any(item.get("name") == target and item.get("enabled") for item in items):
            print(f"[ripc-010a-xcode] ERROR: Target '{target}' is disabled")
            return False

        print(f"[ripc-010a-xcode] Attaching to: {target}")
        try:
            self.xc.click_submenu("Debug", "Attach to Process", target)
            print(f"[ripc-010a-xcode] Attach command sent, waiting...")
            time.sleep(5)  # attach 需要几秒
            return True
        except RuntimeError as e:
            print(f"[ripc-010a-xcode] Attach click failed: {e}")
            return False

    # ═══════════════════ Debug Console ═══════════════════

    def show_debug_console(self) -> bool:
        """显示 Debug Console (View → Debug Area → Activate Console)。"""
        self.activate_xcode()
        try:
            # 先显示 Debug Area
            self.xc.show_debug_area()
            time.sleep(0.3)
            # 再激活 Console（Cmd+Shift+C 或菜单）
            # Xcode 菜单: View → Debug Area → Activate Console
            self.xc.click_submenu("View", "Debug Area", "Activate Console")
            time.sleep(0.3)
            return True
        except RuntimeError as e:
            print(f"[ripc-010a-xcode] show_debug_console failed: {e}")
            return False

    def read_debug_console(self) -> str:
        """尝试读取 Debug Console 中的文本内容。

        通过遍历 Xcode 窗口的 AXStaticText 元素，提取位于 Debug Console
        区域（窗口下半部分）的文本。
        """
        self.activate_xcode()
        try:
            # 获取窗口大小以判断区域
            wins = self.xc.get_windows()
            if not wins:
                return ""
            win = wins[0]
            win_y = win.get("y", 0)
            win_h = win.get("height", 1200)
            # Debug Console 大致在窗口下半部分
            console_threshold_y = win_y + win_h * 0.6

            # 遍历所有静态文本
            result = _jxa("""
const se = Application("System Events");
const xcode = se.processes["Xcode"];
const win = xcode.windows[0];
let all = win.entireContents();
let out = [];
for (let i = 0; i < all.length; i++) {
    try {
        let el = all[i];
        if (el.role() === "AXStaticText" || el.role() === "AXTextArea") {
            let pos = el.position();
            let val = "";
            try { val = el.value(); } catch(e) {}
            if (val && val.length > 0) {
                out.push({text: val, x: pos[0], y: pos[1]});
            }
        }
    } catch(e) {}
}
JSON.stringify(out);
""", timeout=30)
            texts = json.loads(result)
            # 筛选位于下半部分的文本
            console_texts = [
                t["text"] for t in texts
                if t.get("y", 0) > console_threshold_y
            ]
            return "\n".join(console_texts)
        except Exception as e:
            print(f"[ripc-010a-xcode] read_debug_console error: {e}")
            return ""

    def send_to_debug_console(self, command: str) -> bool:
        """尝试向 Debug Console 输入命令并执行。

        当前实现：通过 cliclick 或 key event 发送文本。
        需要先聚焦 Debug Console 输入框。
        """
        self.activate_xcode()
        self.show_debug_console()
        time.sleep(0.5)

        # 尝试通过 AppleScript 发送按键到 Xcode
        # 先聚焦到 Debug Console 的输入区域（通常是底部的一行输入框）
        try:
            # 使用 Tab 键循环聚焦到 Console 输入框
            subprocess.run(
                ["osascript", "-e",
                 'tell application "System Events" to key code 48 control down'],
                check=True, timeout=5,
            )
            time.sleep(0.2)
        except Exception:
            pass

        # 输入命令
        try:
            subprocess.run(
                ["osascript", "-e",
                 f'tell application "System Events" to keystroke "{command}"'],
                check=True, timeout=5,
            )
            time.sleep(0.2)
            # 按回车
            subprocess.run(
                ["osascript", "-e",
                 'tell application "System Events" to key code 36'],
                check=True, timeout=5,
            )
            time.sleep(0.5)
            return True
        except Exception as e:
            print(f"[ripc-010a-xcode] send_to_debug_console failed: {e}")
            return False

    # ═══════════════════ Breakpoint Navigator ═══════════════════

    def show_breakpoint_navigator(self) -> bool:
        """切换到 Breakpoint Navigator。"""
        try:
            self.xc.show_navigator("Breakpoints")
            time.sleep(0.5)
            return True
        except RuntimeError as e:
            print(f"[ripc-010a-xcode] show_breakpoint_navigator failed: {e}")
            return False

    def add_address_breakpoint(self, address: int) -> bool:
        """在 Breakpoint Navigator 中添加地址断点。

        流程:
        1. 显示 Breakpoint Navigator
        2. 点击底部 '+' 按钮 → Add Address Breakpoint
        3. 在弹出的输入框中输入地址
        4. 确认

        TODO: 需要根据实际 Xcode UI 结构迭代实现。
        """
        self.show_breakpoint_navigator()
        time.sleep(0.5)
        print(f"[ripc-010a-xcode] TODO: add_address_breakpoint(0x{address:x}) 需要实际 UI 探测")
        return False

    # ═══════════════════ 组合流程 ═══════════════════

    def run_full_probe(self, probe_script_path: str) -> dict:
        """执行完整的真机调试采集流程。

        由于当前 UI 自动化限制，此流程需要人工配合:
        1. 确保真机上的 NGR 已启动
        2. 本脚本自动 attach
        3. 人工在 Xcode 中加载 probe 脚本（或后续版本自动加载）
        4. 脚本自动采集并保存结果
        """
        result = {
            "xcode_running": self.is_xcode_running(),
            "attach_ok": False,
            "console_ok": False,
            "probe_loaded": False,
            "message": "",
        }

        if not result["xcode_running"]:
            result["message"] = "Xcode is not running. Please open Xcode first."
            return result

        print("[ripc-010a-xcode] Step 1: Attaching to NGR on device...")
        result["attach_ok"] = self.attach_to_process("NGR")
        if not result["attach_ok"]:
            result["message"] = "Attach failed. Ensure NGR is running on the iPad."
            return result

        print("[ripc-010a-xcode] Step 2: Showing debug console...")
        result["console_ok"] = self.show_debug_console()

        print("[ripc-010a-xcode] Step 3: Loading probe script...")
        # 尝试自动加载 LLDB 脚本
        probe_path = Path(probe_script_path).expanduser().resolve()
        if probe_path.exists():
            cmd = f"command script import {probe_path}"
            if self.send_to_debug_console(cmd):
                result["probe_loaded"] = True
                result["message"] = "Probe script loaded. Breakpoints are now active."
            else:
                result["message"] = (
                    f"Could not auto-load probe. Please manually enter in Debug Console:\n"
                    f"  {cmd}"
                )
        else:
            result["message"] = f"Probe script not found: {probe_path}"

        return result


def main():
    parser = argparse.ArgumentParser(description="RIPC-010-A Xcode 真机调试自动化")
    sub = parser.add_subparsers(dest="command")

    sub.add_parser("attach", help="Attach Xcode to NGR process on device")
    sub.add_parser("show-console", help="Show and activate Debug Console")
    sub.add_parser("read-console", help="Read current Debug Console text")
    sub.add_parser("show-bp-nav", help="Show Breakpoint Navigator")

    p = sub.add_parser("load-script", help="Load LLDB probe script via Debug Console")
    p.add_argument("path", help="Path to .py LLDB script")

    p = sub.add_parser("full", help="Run full attach + load probe workflow")
    p.add_argument("path", help="Path to .py LLDB script")

    args = parser.parse_args()
    auto = XcodeDeviceDebug()

    if args.command == "attach":
        ok = auto.attach_to_process("NGR")
        sys.exit(0 if ok else 1)
    elif args.command == "show-console":
        ok = auto.show_debug_console()
        sys.exit(0 if ok else 1)
    elif args.command == "read-console":
        text = auto.read_debug_console()
        print(text)
    elif args.command == "show-bp-nav":
        ok = auto.show_breakpoint_navigator()
        sys.exit(0 if ok else 1)
    elif args.command == "load-script":
        ok = auto.send_to_debug_console(f"command script import {Path(args.path).resolve()}")
        sys.exit(0 if ok else 1)
    elif args.command == "full":
        result = auto.run_full_probe(args.path)
        print(json.dumps(result, indent=2, ensure_ascii=False))
        sys.exit(0 if result["attach_ok"] else 1)
    else:
        parser.print_help()


if __name__ == "__main__":
    main()
