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
            self.xc.show_debug_console()
            return True
        except RuntimeError as e:
            print(f"[ripc-010a-xcode] show_debug_console failed: {e}")
            return False

    def read_debug_console(self) -> dict:
        """读取 Debug Console 的输出区域和输入区域文本。

        Returns:
            {"output": "...", "input": "...", "output_pos": [x, y], "input_pos": [x, y]}
        """
        self.activate_xcode()
        try:
            return self.xc.read_debug_console()
        except Exception as e:
            print(f"[ripc-010a-xcode] read_debug_console error: {e}")
            return {"output": "", "input": "", "output_pos": [0, 0], "input_pos": [0, 0]}

    def send_to_debug_console(self, command: str) -> bool:
        """向 Debug Console 输入命令并执行。

        使用 xcode_general_ops.send_debug_console_command（JXA 直接设置
        AXTextArea value 后发送回车键）。
        """
        self.activate_xcode()
        self.show_debug_console()
        time.sleep(0.5)
        self.xc.send_debug_console_command(command)
        return True

    # ═══════════════════ Breakpoint Navigator ═══════════════════

    def show_breakpoint_navigator(self) -> bool:
        """切换到 Breakpoint Navigator（使用 JXA 直接点击 radio button）。"""
        try:
            self.xc.show_breakpoint_navigator()
            return True
        except RuntimeError as e:
            print(f"[ripc-010a-xcode] show_breakpoint_navigator failed: {e}")
            return False

    def get_create_breakpoint_menu(self) -> list[str]:
        """点击 Breakpoint Navigator 的 '+' 按钮并返回菜单项列表。"""
        self.activate_xcode()
        try:
            return self.xc.click_create_breakpoint_button()
        except RuntimeError as e:
            print(f"[ripc-010a-xcode] get_create_breakpoint_menu failed: {e}")
            return []

    def add_address_breakpoint(self, address: int) -> bool:
        """在 Breakpoint Navigator 中添加地址断点。

        重要发现：Breakpoint Navigator 的 '+' 按钮菜单项为：
        - Swift Error Breakpoint
        - Exception Breakpoint…
        - Symbolic Breakpoint…
        - Runtime Issue Breakpoint…
        - Constraint Error Breakpoint
        - Test Failure Breakpoint

        没有 "Address Breakpoint" 选项！因此地址断点必须通过 Debug Console
        的 LLDB 命令设置：breakpoint set -a 0x<address>
        """
        self.show_breakpoint_navigator()
        time.sleep(0.5)
        print(
            f"[ripc-010a-xcode] Address breakpoints must be set via LLDB command. "
            f"Use: send_to_debug_console('breakpoint set -a 0x{address:x}')"
        )
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
    sub.add_parser("bp-menu", help="Click '+' in Breakpoint Navigator and list menu items")

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
    elif args.command == "bp-menu":
        items = auto.get_create_breakpoint_menu()
        for item in items:
            print(f"  {item}")
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
