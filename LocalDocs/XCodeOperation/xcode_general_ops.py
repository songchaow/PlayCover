#!/usr/bin/env python3
"""
xcode_general_ops.py — Xcode 通用 GUI 自动化操作库

提供不依赖 GPU Frame Capture 的通用 Xcode 操作：
- 窗口管理
- 菜单操作
- Navigator 切换
- 文件打开
- 面板显示/隐藏
"""

import subprocess
import json
import time
from typing import Optional


def _jxa(script: str, timeout: int = 15) -> str:
    result = subprocess.run(
        ["osascript", "-l", "JavaScript", "-e", script],
        capture_output=True, text=True, timeout=timeout
    )
    if result.returncode != 0:
        raise RuntimeError(f"JXA error: {result.stderr.strip()}")
    return result.stdout.strip()


def _applescript(script: str, timeout: int = 15) -> str:
    result = subprocess.run(
        ["osascript", "-e", script],
        capture_output=True, text=True, timeout=timeout
    )
    if result.returncode != 0:
        raise RuntimeError(f"AppleScript error: {result.stderr.strip()}")
    return result.stdout.strip()


_JXA_PREAMBLE = """
const se = Application("System Events");
const xcode = se.processes["Xcode"];
const win = xcode.windows[0];
"""


class XcodeGeneral:
    """Xcode 通用 GUI 操作。"""

    def __init__(self, delay: float = 0.5):
        self.delay = delay

    # ═══════════════════ 窗口 ═══════════════════

    def activate(self):
        """将 Xcode 置为前台。"""
        _jxa('Application("Xcode").activate();')
        time.sleep(0.3)

    def get_windows(self) -> list[dict]:
        """获取 Xcode 所有窗口信息。"""
        result = _jxa("""
        const se = Application("System Events");
        const xcode = se.processes["Xcode"];
        let wins = xcode.windows();
        let out = [];
        for (let i = 0; i < wins.length; i++) {
            let w = wins[i];
            try {
                let title = w.attributes["AXTitle"].value() || "";
                let pos = w.attributes["AXPosition"].value();
                let sz = w.attributes["AXSize"].value();
                out.push({index: i, title: title, x: pos[0], y: pos[1],
                           width: sz[0], height: sz[1]});
            } catch(e) {}
        }
        JSON.stringify(out);
        """)
        return json.loads(result)

    def get_document_path(self) -> Optional[str]:
        """获取当前窗口的文档路径。"""
        result = _jxa(_JXA_PREAMBLE + """
        win.attributes["AXDocument"].value() || "";
        """)
        return result if result else None

    # ═══════════════════ 菜单 ═══════════════════

    def get_menu_bar_items(self) -> list[str]:
        """获取菜单栏所有项名称。"""
        result = _applescript(
            'tell application "System Events" to tell process "Xcode" '
            'to get name of every menu bar item of menu bar 1'
        )
        return [x.strip() for x in result.split(",")]

    def get_menu_items(self, menu_name: str) -> list[dict]:
        """获取指定菜单的所有项及 enabled 状态。"""
        result = _jxa(_JXA_PREAMBLE + f"""
        let items = xcode.menuBars[0].menus["{menu_name}"].menuItems();
        let out = [];
        for (let mi of items) {{
            try {{
                let n = mi.name();
                if (n) out.push({{name: n, enabled: mi.enabled()}});
            }} catch(e) {{}}
        }}
        JSON.stringify(out);
        """)
        return json.loads(result)

    def get_submenu_items(self, menu_name: str, submenu_name: str) -> list[dict]:
        """获取指定子菜单的所有项及 enabled 状态。"""
        result = _jxa(_JXA_PREAMBLE + f"""
        let parent = xcode.menuBars[0].menus["{menu_name}"].menuItems["{submenu_name}"];
        let submenus = parent.menus();
        if (submenus.length === 0) {{
            JSON.stringify([]);
        }} else {{
            let items = submenus[0].menuItems();
            let out = [];
            for (let mi of items) {{
                try {{
                    let n = mi.name();
                    if (n) out.push({{name: n, enabled: mi.enabled()}});
                }} catch(e) {{}}
            }}
            JSON.stringify(out);
        }}
        """)
        return json.loads(result)

    def click_menu(self, menu_name: str, item_name: str):
        """点击菜单项。"""
        _jxa(_JXA_PREAMBLE + f"""
        xcode.menuBars[0].menus["{menu_name}"].menuItems["{item_name}"].click();
        delay({self.delay});
        "ok";
        """)

    def click_submenu(self, menu_name: str, submenu_name: str, item_name: str):
        """点击子菜单项 (如 View > Navigators > Debug)。"""
        _applescript(
            f'tell application "System Events" to tell process "Xcode" to '
            f'click menu item "{item_name}" of menu "{submenu_name}" of '
            f'menu item "{submenu_name}" of menu "{menu_name}" of menu bar 1'
        )
        time.sleep(self.delay)

    # ═══════════════════ Navigator ═══════════════════

    def show_navigator(self, name: str):
        """切换到指定 Navigator。

        Args:
            name: Project/Source Control/Bookmarks/Find/Issues/Tests/Debug/Breakpoints/Reports
        """
        self.click_submenu("View", "Navigators", name)

    def hide_navigator(self):
        """隐藏 Navigator。"""
        try:
            self.click_submenu("View", "Navigators", "Hide Navigator")
        except RuntimeError:
            pass  # 可能已经隐藏

    def get_current_navigator(self) -> Optional[str]:
        """获取当前激活的 Navigator 名称。"""
        result = _jxa(_JXA_PREAMBLE + """
        let nav = win.groups.whose({description: "navigator"});
        if (nav.length === 0) { "hidden"; }
        else {
            let radios = nav[0].radioButtons();
            let active = radios.filter(r => r.value() === 1);
            active.length > 0 ? active[0].description() : "unknown";
        }
        """)
        return result

    # ═══════════════════ Toolbar ═══════════════════

    def get_toolbar_buttons(self) -> list[dict]:
        """获取工具栏按钮信息。"""
        result = _jxa(_JXA_PREAMBLE + """
        let tb = win.toolbars[0];
        let elems = tb.uiElements();
        let out = [];
        for (let e of elems) {
            try {
                let desc = e.description();
                let role = e.role();
                out.push({role: role, description: desc});
            } catch(ex) {}
        }
        JSON.stringify(out);
        """)
        return json.loads(result)

    # ═══════════════════ 面板 ═══════════════════

    def show_debug_area(self):
        """显示 Debug Area。"""
        try:
            self.click_submenu("View", "Debug Area", "Show Debug Area")
        except RuntimeError:
            pass

    def hide_debug_area(self):
        """隐藏 Debug Area。"""
        try:
            self.click_submenu("View", "Debug Area", "Show Debug Area")
        except RuntimeError:
            pass

    def show_inspector(self):
        """显示 Inspector。"""
        try:
            self.click_submenu("View", "Inspectors", "Show Inspector")
        except RuntimeError:
            pass

    # ═══════════════════ Sheet / Alert ═══════════════════

    def get_sheets(self) -> list[dict]:
        """获取当前窗口上的 sheet/alert 摘要。"""
        result = _jxa(_JXA_PREAMBLE + """
        let sheets = win.sheets();
        let out = [];
        for (let i = 0; i < sheets.length; i++) {
            let sheet = sheets[i];
            let texts = [];
            let buttons = [];
            try {
                for (let st of sheet.staticTexts()) {
                    try {
                        let name = st.name();
                        if (name) texts.push(name);
                    } catch (e) {}
                }
            } catch (e) {}
            try {
                for (let btn of sheet.buttons()) {
                    try {
                        let name = btn.name();
                        if (name) buttons.push({name: name, enabled: btn.enabled()});
                    } catch (e) {}
                }
            } catch (e) {}
            out.push({
                index: i,
                role: sheet.role(),
                description: sheet.description(),
                texts: texts,
                buttons: buttons,
            });
        }
        JSON.stringify(out);
        """)
        return json.loads(result)

    def click_sheet_button(self, button_name: str, sheet_index: int = 0):
        """点击当前窗口 sheet 上的按钮。"""
        _jxa(_JXA_PREAMBLE + f"""
        let sheets = win.sheets();
        if (sheets.length <= {sheet_index}) {{
            throw new Error("sheet index out of range");
        }}
        let buttons = sheets[{sheet_index}].buttons();
        let matched = false;
        for (let btn of buttons) {{
            try {{
                if (btn.name() === "{button_name}") {{
                    btn.click();
                    matched = true;
                    break;
                }}
            }} catch (e) {{}}
        }}
        if (!matched) {{
            throw new Error("sheet button not found: {button_name}");
        }}
        delay({self.delay});
        "ok";
        """)

    # ═══════════════════ 文件操作 ═══════════════════

    def open_file(self, path: str):
        """在 Xcode 中打开指定文件。"""
        _jxa(f"""
        const app = Application("Xcode");
        app.open("{path}");
        """)
        time.sleep(self.delay)

    # ═══════════════════ UI 探查 ═══════════════════

    def dump_ui_tree(self, max_elements: int = 200) -> list[dict]:
        """导出窗口 UI 元素树 (用于调试)。"""
        result = _jxa(_JXA_PREAMBLE + f"""
        let all = win.entireContents();
        let out = [];
        let limit = Math.min(all.length, {max_elements});
        for (let i = 0; i < limit; i++) {{
            try {{
                let role = all[i].role();
                let desc = "";
                try {{ desc = all[i].description(); }} catch(e) {{}}
                let name = "";
                try {{ name = all[i].name(); }} catch(e) {{}}
                let val = "";
                try {{ val = "" + all[i].value(); }} catch(e) {{}}
                let pos = [];
                try {{ pos = all[i].position(); }} catch(e) {{}}
                out.push({{index: i, role: role, description: desc,
                           name: name, value: val,
                           x: pos[0] || 0, y: pos[1] || 0}});
            }} catch(e) {{}}
        }}
        JSON.stringify(out);
        """)
        return json.loads(result)


def main():
    import argparse
    parser = argparse.ArgumentParser(description="Xcode 通用 GUI 操作")
    sub = parser.add_subparsers(dest="command")

    sub.add_parser("windows", help="列出窗口")
    sub.add_parser("menubar", help="列出菜单栏")
    sub.add_parser("toolbar", help="列出工具栏")
    sub.add_parser("navigator", help="当前 Navigator")
    sub.add_parser("doc", help="当前文档路径")
    sub.add_parser("sheets", help="列出当前窗口 sheet/alert")

    p = sub.add_parser("menu", help="显示菜单项")
    p.add_argument("name", help="菜单名")

    p = sub.add_parser("submenu", help="显示子菜单项")
    p.add_argument("menu", help="菜单名")
    p.add_argument("submenu", help="子菜单名")

    p = sub.add_parser("click", help="点击菜单项")
    p.add_argument("menu", help="菜单名")
    p.add_argument("item", help="菜单项名")

    p = sub.add_parser("click-submenu", help="点击子菜单项")
    p.add_argument("menu", help="菜单名")
    p.add_argument("submenu", help="子菜单名")
    p.add_argument("item", help="子菜单项名")

    p = sub.add_parser("click-sheet", help="点击 sheet/alert 按钮")
    p.add_argument("button", help="按钮名")
    p.add_argument("--sheet-index", type=int, default=0)

    p = sub.add_parser("show-nav", help="切换 Navigator")
    p.add_argument("name", help="Navigator 名")

    p = sub.add_parser("uitree", help="导出 UI 树")
    p.add_argument("-n", "--max", type=int, default=200)

    args = parser.parse_args()
    xc = XcodeGeneral()

    if args.command == "windows":
        for w in xc.get_windows():
            print(f"  [{w['index']}] {w['title']} ({w['width']}x{w['height']})")
    elif args.command == "menubar":
        for name in xc.get_menu_bar_items():
            print(f"  {name}")
    elif args.command == "menu":
        for item in xc.get_menu_items(args.name):
            s = "✅" if item["enabled"] else "❌"
            print(f"  {s} {item['name']}")
    elif args.command == "submenu":
        for item in xc.get_submenu_items(args.menu, args.submenu):
            s = "✅" if item["enabled"] else "❌"
            print(f"  {s} {item['name']}")
    elif args.command == "click":
        xc.click_menu(args.menu, args.item)
        print("ok")
    elif args.command == "click-submenu":
        xc.click_submenu(args.menu, args.submenu, args.item)
        print("ok")
    elif args.command == "toolbar":
        for b in xc.get_toolbar_buttons():
            print(f"  {b['role']}: {b['description']}")
    elif args.command == "navigator":
        print(xc.get_current_navigator())
    elif args.command == "doc":
        print(xc.get_document_path())
    elif args.command == "sheets":
        for sheet in xc.get_sheets():
            print(json.dumps(sheet, ensure_ascii=False))
    elif args.command == "show-nav":
        xc.show_navigator(args.name)
        print(f"Switched to {args.name}")
    elif args.command == "click-sheet":
        xc.click_sheet_button(args.button, args.sheet_index)
        print("ok")
    elif args.command == "uitree":
        for e in xc.dump_ui_tree(args.max):
            role = str(e.get('role') or "")
            desc = str(e.get('description') or "")
            name = str(e.get('name') or "")
            value = str(e.get('value') or "")[:40]
            print(f"  {e['index']:4d} {role:20s} | {desc:30s} | "
                  f"{name:20s} | {value:40s} @{e['x']},{e['y']}")
    else:
        parser.print_help()


if __name__ == "__main__":
    main()
