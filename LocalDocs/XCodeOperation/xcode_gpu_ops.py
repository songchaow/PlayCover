#!/usr/bin/env python3
"""
xcode_gpu_ops.py — Xcode GPU Frame Capture 自动化操作库

通过 macOS Accessibility API (JXA / osascript) + cliclick 操控 Xcode
GPU Frame Capture 窗口，提供结构化的 Python 接口。

依赖:
    brew install cliclick

用法:
    from xcode_gpu_ops import XcodeGPU
    gpu = XcodeGPU()
    gpu.list_command_buffers()
    gpu.step_next_draw_call()
    gpu.read_breadcrumbs()
"""

import subprocess
import json
import time
import os
import re
from typing import Optional


# ─────────────────────── 底层 JXA 执行器 ───────────────────────

def _jxa(script: str, timeout: int = 120) -> str:
    """执行 JXA (JavaScript for Automation) 脚本，返回 stdout。"""
    result = subprocess.run(
        ["osascript", "-l", "JavaScript", "-e", script],
        capture_output=True, text=True, timeout=timeout
    )
    if result.returncode != 0:
        raise RuntimeError(f"JXA error: {result.stderr.strip()}")
    return result.stdout.strip()


def _activate_xcode():
    """确保 Xcode 在前台 (cliclick 坐标点击需要窗口可见)。"""
    subprocess.run(
        ["osascript", "-l", "JavaScript", "-e",
         'Application("System Events").processes["Xcode"].frontmost = true;'],
        check=True, timeout=3,
    )
    time.sleep(0.2)


def _cliclick(action: str):
    """执行 cliclick 命令。action 如 'c:100,200' 或 'kp:esc'"""
    _activate_xcode()
    subprocess.run(["cliclick", action], check=True, timeout=5)


def _cliclick_available() -> bool:
    """检查 cliclick 是否已安装。"""
    try:
        subprocess.run(["which", "cliclick"], capture_output=True, check=True)
        return True
    except (subprocess.CalledProcessError, FileNotFoundError):
        return False


# ─────────────────────── JXA 脚本模板 ───────────────────────

# 获取基础引用的 JXA 前缀 (每个脚本都需要)
_JXA_PREAMBLE = """
const se = Application("System Events");
const xcode = se.processes["Xcode"];
const win = xcode.windows[0];
"""

_JXA_NAV_OUTLINE = _JXA_PREAMBLE + """
const nav = win.groups.whose({description: "navigator"})[0];
const outline = nav.scrollAreas[0].outlines[0];
"""


# ─────────────────────── 核心类 ───────────────────────

class XcodeGPU:
    """Xcode GPU Frame Capture 自动化操作接口。"""

    def __init__(self, delay_after_action: float = 0.5):
        """
        Args:
            delay_after_action: 每次 UI 操作后等待的秒数 (给 Xcode 响应时间)
        """
        self.delay = delay_after_action
        self._has_cliclick = _cliclick_available()
        if not self._has_cliclick:
            print("⚠️  cliclick 未安装。部分操作 (展开节点/Inspector popup) 不可用。")
            print("   安装: brew install cliclick")

    # ═══════════════════ 窗口与菜单 ═══════════════════

    def get_window_info(self) -> dict:
        """获取 Xcode 窗口基本信息。"""
        result = _jxa(_JXA_PREAMBLE + """
        let title = win.attributes["AXTitle"].value();
        let pos = win.attributes["AXPosition"].value();
        let sz = win.attributes["AXSize"].value();
        let doc = win.attributes["AXDocument"].value();
        JSON.stringify({title: title, position: pos, size: sz, document: doc});
        """)
        return json.loads(result)

    def get_debug_menu_items(self) -> list[dict]:
        """获取 Debug 菜单所有项及其 enabled 状态。"""
        result = _jxa(_JXA_PREAMBLE + """
        let items = xcode.menuBars[0].menus["Debug"].menuItems();
        let out = [];
        for (let mi of items) {
            try {
                let n = mi.name();
                if (n) out.push({name: n, enabled: mi.enabled()});
            } catch(e) {}
        }
        JSON.stringify(out);
        """)
        return json.loads(result)

    def click_menu(self, menu_name: str, item_name: str):
        """点击 Xcode 菜单栏的指定菜单项。"""
        _jxa(_JXA_PREAMBLE + f"""
        xcode.menuBars[0].menus["{menu_name}"].menuItems["{item_name}"].click();
        delay({self.delay});
        "ok";
        """)

    # ═══════════════════ Debug Navigator ═══════════════════

    def list_navigator_rows(self) -> list[dict]:
        """读取 Debug Navigator outline 的所有行。

        Returns:
            [{index, text, selected, has_disclosure, expanded}, ...]
        """
        result = _jxa(_JXA_NAV_OUTLINE + """
        let rows = outline.rows();
        let out = [];
        for (let i = 0; i < rows.length; i++) {
            let statics = rows[i].uiElements[0].staticTexts();
            let t = statics.map(s => s.value()).filter(v => v).join(" | ");
            let sel = rows[i].selected();
            let hasDisc = false, expanded = false;
            try {
                let dts = rows[i].uiElements[0].uiElements.whose({role: "AXDisclosureTriangle"});
                if (dts.length > 0) { hasDisc = true; expanded = dts[0].value() === 1; }
            } catch(e) {}
            out.push({index: i, text: t, selected: sel,
                       has_disclosure: hasDisc, expanded: expanded});
        }
        JSON.stringify(out);
        """)
        return json.loads(result)

    def list_command_buffers(self) -> list[dict]:
        """只列出 Command Buffer 行。"""
        rows = self.list_navigator_rows()
        return [r for r in rows if r["text"].startswith("Command Buffer")]

    def select_navigator_row(self, index: int):
        """选中 Debug Navigator 中指定索引的行 (0-based)。"""
        _jxa(_JXA_NAV_OUTLINE + f"""
        outline.rows[{index}].selected = true;
        delay({self.delay});
        "ok";
        """)

    def select_navigator_row_by_text(self, text_prefix: str) -> int:
        """选中文本以 text_prefix 开头的行，返回行索引。"""
        rows = self.list_navigator_rows()
        for r in rows:
            if r["text"].startswith(text_prefix):
                self.select_navigator_row(r["index"])
                return r["index"]
        raise ValueError(f"未找到以 '{text_prefix}' 开头的行")

    def expand_navigator_row(self, index: int):
        """展开 Navigator 中指定行的 disclosure triangle (需要 cliclick)。"""
        if not self._has_cliclick:
            raise RuntimeError("需要 cliclick: brew install cliclick")
        # 获取该行 disclosure triangle 的坐标
        result = _jxa(_JXA_NAV_OUTLINE + f"""
        let cell = outline.rows[{index}].uiElements[0];
        let dts = cell.uiElements.whose({{role: "AXDisclosureTriangle"}});
        if (dts.length === 0) {{ "none"; }}
        else {{
            let dt = dts[0];
            if (dt.value() === 1) {{ "already_expanded"; }}
            else {{
                let p = dt.position(), s = dt.size();
                Math.round(p[0]+s[0]/2) + "," + Math.round(p[1]+s[1]/2);
            }}
        }}
        """)
        if result == "none":
            raise ValueError(f"Row {index} 没有 disclosure triangle")
        if result == "already_expanded":
            return  # 已经展开
        _cliclick(f"c:{result}")
        time.sleep(self.delay)

    def collapse_navigator_row(self, index: int):
        """折叠 Navigator 中指定行 (需要 cliclick)。"""
        if not self._has_cliclick:
            raise RuntimeError("需要 cliclick: brew install cliclick")
        result = _jxa(_JXA_NAV_OUTLINE + f"""
        let cell = outline.rows[{index}].uiElements[0];
        let dts = cell.uiElements.whose({{role: "AXDisclosureTriangle"}});
        if (dts.length === 0) {{ "none"; }}
        else {{
            let dt = dts[0];
            if (dt.value() === 0) {{ "already_collapsed"; }}
            else {{
                let p = dt.position(), s = dt.size();
                Math.round(p[0]+s[0]/2) + "," + Math.round(p[1]+s[1]/2);
            }}
        }}
        """)
        if result in ("none", "already_collapsed"):
            return
        _cliclick(f"c:{result}")
        time.sleep(self.delay)

    # ═══════════════════ GPU Navigator Mode ═══════════════════

    def get_gpu_navigator_mode(self) -> str:
        """获取当前 GPU Navigator Mode。返回 'Group by API Call' 或 'Group by Pipeline State'。"""
        return _jxa(_JXA_NAV_OUTLINE + """
        outline.rows[5].uiElements[0].popUpButtons[0].value();
        """)

    def set_gpu_navigator_mode(self, mode: str):
        """切换 GPU Navigator Mode。

        Args:
            mode: 'Group by API Call' 或 'Group by Pipeline State'
        """
        _jxa(_JXA_NAV_OUTLINE + f"""
        let popup = outline.rows[5].uiElements[0].popUpButtons[0];
        popup.click();
        delay(0.3);
        popup.menus[0].menuItems["{mode}"].click();
        delay({self.delay});
        "ok";
        """)

    # ═══════════════════ Draw Call 步进 ═══════════════════

    def step_next_draw_call(self):
        """步进到下一个 Draw/Dispatch Call。"""
        self.click_menu("Debug", "Step to Next Draw/Dispatch Call")

    def step_prev_draw_call(self):
        """步进到上一个 Draw/Dispatch Call。"""
        self.click_menu("Debug", "Step to Previous Draw/Dispatch Call")

    def step_next_gpu_call(self):
        """步进到下一个 GPU Call (更细粒度)。"""
        self.click_menu("Debug", "Step to Next GPU Call")

    def step_prev_gpu_call(self):
        """步进到上一个 GPU Call (更细粒度)。"""
        self.click_menu("Debug", "Step to Previous GPU Call")

    # ═══════════════════ 面包屑导航 ═══════════════════

    def read_breadcrumbs(self) -> dict:
        """读取编辑器面包屑导航栏的所有 popup 值。

        Returns:
            {gputrace, command_buffer, render_encoder, draw_call,
             editor_mode, inspector_mode, inspector_submode, navigator_mode}
        """
        result = _jxa(_JXA_PREAMBLE + """
        let sg = win.splitterGroups[0].splitterGroups[0];
        let edGroup = sg.uiElements[0];
        let innerSplit = edGroup.uiElements[0].uiElements[0];

        // 左侧 Jump Bar (面包屑: gputrace > CB > RE > drawCall > Bound Resources)
        let leftJumpBar = innerSplit.uiElements[1];
        let leftPopups = leftJumpBar.popUpButtons();
        let left = leftPopups.map(p => { try { return p.value(); } catch(e) { return ""; } });

        // 右侧 Jump Bar (Inspector: Automatic > Attachments)
        let right = [];
        try {
            let rightJumpBar = innerSplit.uiElements[3].uiElements[1];
            let rightPopups = rightJumpBar.popUpButtons();
            right = rightPopups.map(p => { try { return p.value(); } catch(e) { return ""; } });
        } catch(e) {}

        // Navigator mode
        let navMode = "";
        try {
            let nav = win.groups.whose({description: "navigator"})[0];
            navMode = nav.scrollAreas[0].outlines[0].rows[5].uiElements[0].popUpButtons[0].value();
        } catch(e) {}

        JSON.stringify({left: left, right: right, navigator_mode: navMode});
        """)
        raw = json.loads(result)
        left = raw.get("left", [])
        right = raw.get("right", [])

        out = {}
        left_names = ["gputrace", "command_buffer", "render_encoder", "draw_call",
                       "editor_mode"]
        for i, name in enumerate(left_names):
            out[name] = left[i] if i < len(left) else None

        right_names = ["inspector_mode", "inspector_submode"]
        for i, name in enumerate(right_names):
            out[name] = right[i] if i < len(right) else None

        out["navigator_mode"] = raw.get("navigator_mode", None)
        return out

    def read_current_location(self) -> str:
        """返回人类可读的当前位置字符串，如 'CB4 > RE16 > drawCall#25765'。"""
        bc = self.read_breadcrumbs()
        parts = []
        if bc.get("command_buffer"):
            parts.append(bc["command_buffer"].split(" 0x")[0])
        if bc.get("render_encoder"):
            parts.append(bc["render_encoder"].split(" 0x")[0])
        if bc.get("draw_call"):
            dc = bc["draw_call"]
            # 提取 call 序号
            match = re.match(r"(\d+)\s", dc)
            parts.append(f"#{match.group(1)}" if match else dc[:60])
        return " > ".join(parts) if parts else "(unknown)"

    # ═══════════════════ 编辑器 GPU 绑定表 ═══════════════════

    def read_editor_outline(self) -> list[dict]:
        """读取编辑器中当前 draw call 的 GPU 资源绑定表。

        Returns:
            [{row_index, columns: [col1, col2, ...]}, ...]
            列通常为: [资源名, 绑定点, 类型, Uniform名, 访问, Insights, 大小]
        """
        result = _jxa(_JXA_PREAMBLE + """
        let sg = win.splitterGroups[0].splitterGroups[0];
        let edGroup = sg.uiElements[0];
        // 精确路径到编辑器 outline
        let innerSplit = edGroup.uiElements[0].uiElements[0];
        let leftSplit = innerSplit.uiElements[0].uiElements[0];
        let outline = leftSplit.scrollAreas[0].outlines[0];
        let rows = outline.rows();
        let out = [];
        for (let i = 0; i < rows.length; i++) {
            let cells = rows[i].uiElements();
            let texts = [];
            for (let j = 0; j < cells.length; j++) {
                try {
                    let statics = cells[j].staticTexts();
                    for (let k = 0; k < statics.length; k++) {
                        let v = statics[k].value();
                        if (v) texts.push(v);
                    }
                } catch(e) {}
            }
            out.push({row_index: i, columns: texts});
        }
        JSON.stringify(out);
        """)
        return json.loads(result)

    def read_editor_summary(self) -> dict:
        """将编辑器 outline 解析为结构化摘要。

        Returns:
            {pipeline_state, vertex_function, fragment_function,
             vertex_resources: [...], fragment_resources: [...],
             attachments: [...]}
        """
        rows = self.read_editor_outline()
        summary = {
            "pipeline_state": None, "vertex_function": None,
            "fragment_function": None, "vertex_resources": [],
            "fragment_resources": [], "attachments": []
        }
        section = None
        for r in rows:
            cols = r["columns"]
            if not cols:
                continue
            first = cols[0]

            if first == "Render Pipeline State":
                section = "header"
                continue
            if first == "Vertex":
                section = "vertex"
                continue
            if first == "Fragment":
                section = "fragment"
                continue
            if first in ("Vertex Attributes", "Geometry"):
                section = "geometry"
                continue
            if first == "Attachments":
                section = "attachments"
                continue

            if section == "header":
                if len(cols) >= 3:
                    summary["pipeline_state"] = cols[0]
                    if "Vertex Function" in cols:
                        summary["vertex_function"] = cols[0]
                    elif "Fragment Function" in cols:
                        summary["fragment_function"] = cols[0]
                # shader name is often in the first "header" row
                if summary["pipeline_state"] is None and len(cols) >= 2:
                    summary["pipeline_state"] = cols[0]
            elif section in ("vertex", "fragment"):
                resource = {"name": cols[0] if cols else ""}
                if len(cols) > 1:
                    resource["binding"] = cols[1]
                if len(cols) > 2:
                    resource["type"] = cols[2]
                if len(cols) > 3:
                    resource["uniform"] = cols[3]
                if len(cols) > 4:
                    resource["access"] = cols[4]
                if len(cols) > 5:
                    resource["insights"] = cols[5]
                if len(cols) > 6:
                    resource["size"] = cols[6]
                summary[f"{section}_resources"].append(resource)
            elif section == "attachments":
                attach = {"name": cols[0] if cols else ""}
                if len(cols) > 1:
                    attach["slot"] = cols[1]
                if len(cols) > 2:
                    attach["type"] = cols[2]
                if len(cols) > 4:
                    attach["load_action"] = cols[4]
                if len(cols) > 5:
                    attach["store_action"] = cols[5]
                if len(cols) > 6:
                    attach["size"] = cols[6]
                summary["attachments"].append(attach)

        return summary

    # ═══════════════════ Inspector 区域 ═══════════════════

    def read_inspector_texts(self, min_x: int = 1100) -> list[dict]:
        """读取 Inspector 区域的所有文本元素。

        Args:
            min_x: Inspector 区域的最小 x 坐标 (默认 1100)

        Returns:
            [{text, x, y}, ...]
        """
        result = _jxa(_JXA_PREAMBLE + f"""
        let sg = win.splitterGroups[0].splitterGroups[0];
        let edGroup = sg.uiElements[0];
        let all = edGroup.entireContents();
        let out = [];
        for (let i = 0; i < all.length; i++) {{
            try {{
                if (all[i].role() === "AXStaticText") {{
                    let pos = all[i].position();
                    if (pos[0] > {min_x}) {{
                        let v = all[i].value();
                        if (v && v.length > 1) out.push({{text: v, x: pos[0], y: pos[1]}});
                    }}
                }}
            }} catch(e) {{}}
        }}
        JSON.stringify(out);
        """)
        return json.loads(result)

    def read_inspector_attachments(self) -> list[dict]:
        """读取 Inspector 中的 Attachment (Color/Depth/Stencil) Grid 信息。"""
        result = _jxa(_JXA_PREAMBLE + """
        let sg = win.splitterGroups[0].splitterGroups[0];
        let edGroup = sg.uiElements[0];
        let all = edGroup.entireContents();
        let grids = [];
        for (let i = 0; i < all.length; i++) {
            try {
                if (all[i].role() === "AXGrid") {
                    let desc = all[i].description();
                    let pos = all[i].position();
                    let sz = all[i].size();
                    grids.push({description: desc, x: pos[0], y: pos[1],
                                width: sz[0], height: sz[1]});
                }
            } catch(e) {}
        }
        JSON.stringify(grids);
        """)
        return json.loads(result)

    # ═══════════════════ Filter Toggles ═══════════════════

    def read_filter_state(self) -> dict:
        """读取编辑器 filter checkbox 的状态。

        Returns:
            {Bound: bool, Accessed: bool, All: bool, Vertex: bool, Fragment: bool}
        """
        result = _jxa(_JXA_PREAMBLE + """
        let sg = win.splitterGroups[0].splitterGroups[0];
        let edGroup = sg.uiElements[0];
        let innerSplit = edGroup.uiElements[0].uiElements[0];
        let leftSplit = innerSplit.uiElements[0].uiElements[0];
        // checkboxes are direct children of leftSplit
        let cbs = leftSplit.checkboxes();
        let out = {};
        for (let i = 0; i < cbs.length; i++) {
            try {
                let n = cbs[i].name();
                if (["Bound","Accessed","All","Vertex","Fragment"].indexOf(n) >= 0) {
                    out[n] = cbs[i].value() === "1" || cbs[i].value() === 1;
                }
            } catch(e) {}
        }
        JSON.stringify(out);
        """)
        return json.loads(result)

    def set_filter(self, name: str, enabled: bool):
        """设置 filter checkbox。name: Bound/Accessed/All/Vertex/Fragment"""
        _jxa(_JXA_PREAMBLE + f"""
        let sg = win.splitterGroups[0].splitterGroups[0];
        let edGroup = sg.uiElements[0];
        let innerSplit = edGroup.uiElements[0].uiElements[0];
        let leftSplit = innerSplit.uiElements[0].uiElements[0];
        let cbs = leftSplit.checkboxes();
        for (let i = 0; i < cbs.length; i++) {{
            try {{
                if (cbs[i].name() === "{name}") {{
                    let cur = cbs[i].value() === "1" || cbs[i].value() === 1;
                    if (cur !== {str(enabled).lower()}) {{
                        cbs[i].click();
                    }}
                    break;
                }}
            }} catch(e) {{}}
        }}
        delay({self.delay});
        "ok";
        """)

    # ═══════════════════ 截图 ═══════════════════

    def screenshot(self, output_path: str = "/tmp/xcode_gpu_screenshot.png",
                   silent: bool = True):
        """截取当前屏幕。

        Args:
            output_path: 保存路径
            silent: 是否静音 (-x)
        """
        cmd = ["screencapture"]
        if silent:
            cmd.append("-x")
        cmd.append(output_path)
        subprocess.run(cmd, check=True, timeout=10)
        return output_path

    # ═══════════════════ 高级组合操作 ═══════════════════

    def walk_all_draw_calls(self, max_steps: int = 500,
                            callback=None) -> list[dict]:
        """遍历所有 draw call，每步收集信息。

        Args:
            max_steps: 最大步数 (防止无限循环)
            callback: 每步调用的回调函数 fn(step_index, info_dict)

        Returns:
            [{step, location, breadcrumbs}, ...]
        """
        results = []
        prev_location = ""
        for step in range(max_steps):
            bc = self.read_breadcrumbs()
            loc = self.read_current_location()

            info = {"step": step, "location": loc, "breadcrumbs": bc}
            results.append(info)

            if callback:
                callback(step, info)

            # 步进
            try:
                self.step_next_draw_call()
            except RuntimeError:
                break  # 菜单项 disabled = 到末尾了

            # 检查是否循环回到起点
            time.sleep(0.1)
            new_loc = self.read_current_location()
            if new_loc == results[0]["location"] and step > 0:
                break
            prev_location = new_loc

        return results

    def dump_frame_summary(self, output_dir: str = "/tmp/xcode_gpu_dump"):
        """导出当前帧的完整摘要到指定目录。

        输出:
            {output_dir}/navigator.json  — Navigator 树
            {output_dir}/pipelines.json  — Pipeline State 模式下的 shader 列表
            {output_dir}/memory_info.txt — 内存信息
        """
        os.makedirs(output_dir, exist_ok=True)

        # 1. Navigator 树 (API Call 模式)
        self.set_gpu_navigator_mode("Group by API Call")
        time.sleep(self.delay)
        nav_rows = self.list_navigator_rows()
        with open(os.path.join(output_dir, "navigator_api_call.json"), "w") as f:
            json.dump(nav_rows, f, indent=2, ensure_ascii=False)

        # 2. Pipeline State 模式
        self.set_gpu_navigator_mode("Group by Pipeline State")
        time.sleep(self.delay)
        pipeline_rows = self.list_navigator_rows()
        with open(os.path.join(output_dir, "navigator_pipeline_state.json"), "w") as f:
            json.dump(pipeline_rows, f, indent=2, ensure_ascii=False)

        # 3. 内存信息
        memory_row = [r for r in nav_rows if "MiB" in r.get("text", "")
                      or "Memory" in r.get("text", "")]
        with open(os.path.join(output_dir, "memory_info.txt"), "w") as f:
            for r in memory_row:
                f.write(r["text"] + "\n")

        # 切回 API Call 模式
        self.set_gpu_navigator_mode("Group by API Call")

        print(f"✅ Frame summary dumped to {output_dir}")
        return output_dir

    def screenshot_each_draw_call(self, output_dir: str = "/tmp/xcode_gpu_screenshots",
                                  max_steps: int = 100):
        """步进遍历 draw call，每步截图。

        Returns:
            [{step, location, screenshot_path}, ...]
        """
        os.makedirs(output_dir, exist_ok=True)
        results = []

        def on_step(step, info):
            loc = info["location"].replace(" ", "_").replace(">", "-").replace("#", "")
            path = os.path.join(output_dir, f"step_{step:04d}_{loc[:60]}.png")
            self.screenshot(path)
            results.append({"step": step, "location": info["location"],
                           "screenshot_path": path})
            print(f"  [{step}] {info['location']}")

        self.walk_all_draw_calls(max_steps=max_steps, callback=on_step)

        # 保存索引
        with open(os.path.join(output_dir, "index.json"), "w") as f:
            json.dump(results, f, indent=2, ensure_ascii=False)

        print(f"✅ {len(results)} screenshots saved to {output_dir}")
        return results


# ─────────────────────── CLI 入口 ───────────────────────

def main():
    import argparse
    parser = argparse.ArgumentParser(description="Xcode GPU Frame Capture 自动化操作")
    sub = parser.add_subparsers(dest="command")

    sub.add_parser("info", help="显示窗口信息")
    sub.add_parser("nav", help="列出 Navigator 所有行")
    sub.add_parser("cbs", help="列出 Command Buffers")
    sub.add_parser("breadcrumbs", help="读取面包屑导航")
    sub.add_parser("location", help="显示当前位置")
    sub.add_parser("editor", help="读取编辑器绑定表")
    sub.add_parser("summary", help="读取编辑器摘要")
    sub.add_parser("inspector", help="读取 Inspector 文本")
    sub.add_parser("filters", help="读取 filter 状态")
    sub.add_parser("menu", help="显示 Debug 菜单")

    p = sub.add_parser("step", help="步进 draw call")
    p.add_argument("direction", choices=["next", "prev"], default="next", nargs="?")
    p.add_argument("--fine", action="store_true", help="细粒度 (GPU Call)")

    p = sub.add_parser("select", help="选中 Navigator 行")
    p.add_argument("index", type=int, help="行索引 (0-based)")

    p = sub.add_parser("expand", help="展开 Navigator 行")
    p.add_argument("index", type=int, help="行索引 (0-based)")

    p = sub.add_parser("mode", help="切换 GPU Navigator Mode")
    p.add_argument("mode", choices=["api", "pipeline"], help="模式")

    p = sub.add_parser("screenshot", help="截图")
    p.add_argument("-o", "--output", default="/tmp/xcode_gpu_screenshot.png")

    p = sub.add_parser("dump", help="导出帧摘要")
    p.add_argument("-o", "--output", default="/tmp/xcode_gpu_dump")

    p = sub.add_parser("walk", help="遍历所有 draw call 并截图")
    p.add_argument("-o", "--output", default="/tmp/xcode_gpu_screenshots")
    p.add_argument("-n", "--max-steps", type=int, default=100)

    args = parser.parse_args()
    gpu = XcodeGPU()

    if args.command == "info":
        print(json.dumps(gpu.get_window_info(), indent=2, ensure_ascii=False))
    elif args.command == "nav":
        for r in gpu.list_navigator_rows():
            marker = " *" if r["selected"] else ""
            disc = " ▸" if r["has_disclosure"] and not r["expanded"] else ""
            disc = " ▾" if r["has_disclosure"] and r["expanded"] else disc
            print(f"  {r['index']:3d}: {r['text']}{disc}{marker}")
    elif args.command == "cbs":
        for r in gpu.list_command_buffers():
            print(f"  {r['index']:3d}: {r['text']}")
    elif args.command == "breadcrumbs":
        print(json.dumps(gpu.read_breadcrumbs(), indent=2, ensure_ascii=False))
    elif args.command == "location":
        print(gpu.read_current_location())
    elif args.command == "editor":
        for r in gpu.read_editor_outline():
            print(f"  {r['row_index']:3d}: {' | '.join(r['columns'])}")
    elif args.command == "summary":
        print(json.dumps(gpu.read_editor_summary(), indent=2, ensure_ascii=False))
    elif args.command == "inspector":
        for t in gpu.read_inspector_texts():
            print(f"  ({t['x']},{t['y']}): {t['text']}")
    elif args.command == "filters":
        print(json.dumps(gpu.read_filter_state(), indent=2))
    elif args.command == "menu":
        for item in gpu.get_debug_menu_items():
            status = "✅" if item["enabled"] else "❌"
            print(f"  {status} {item['name']}")
    elif args.command == "step":
        if args.fine:
            (gpu.step_next_gpu_call if args.direction == "next"
             else gpu.step_prev_gpu_call)()
        else:
            (gpu.step_next_draw_call if args.direction == "next"
             else gpu.step_prev_draw_call)()
        print(gpu.read_current_location())
    elif args.command == "select":
        gpu.select_navigator_row(args.index)
        print(f"Selected row {args.index}")
    elif args.command == "expand":
        gpu.expand_navigator_row(args.index)
        print(f"Expanded row {args.index}")
    elif args.command == "mode":
        mode_map = {"api": "Group by API Call", "pipeline": "Group by Pipeline State"}
        gpu.set_gpu_navigator_mode(mode_map[args.mode])
        print(f"Switched to {mode_map[args.mode]}")
    elif args.command == "screenshot":
        path = gpu.screenshot(args.output)
        print(f"Screenshot saved to {path}")
    elif args.command == "dump":
        gpu.dump_frame_summary(args.output)
    elif args.command == "walk":
        gpu.screenshot_each_draw_call(args.output, args.max_steps)
    else:
        parser.print_help()


if __name__ == "__main__":
    main()
