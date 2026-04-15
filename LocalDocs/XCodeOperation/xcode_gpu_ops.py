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
from pathlib import Path
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


def _press_keycode(keycode: int):
    """向当前前台应用发送单个按键 keycode。"""
    _activate_xcode()
    subprocess.run(
        ["osascript", "-e", f'tell application "System Events" to key code {keycode}'],
        check=True,
        timeout=5,
    )
    time.sleep(0.1)


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

    def _document_uri(self, path: str) -> str:
        """将本地路径规范化为 Xcode Accessibility 暴露的 file:// URI。"""
        return Path(path).expanduser().resolve().as_uri()

    def _raise_window_for_document(self, document_uri: str) -> bool:
        """尝试把匹配指定文档 URI 的 Xcode 窗口切到前台。"""
        result = _jxa(_JXA_PREAMBLE + f"""
        const targetDoc = {json.dumps(document_uri, ensure_ascii=False)};
        let matched = false;
        let wins = xcode.windows();
        for (let i = 0; i < wins.length; i++) {{
            let candidate = wins[i];
            let doc = "";
            try {{ doc = candidate.attributes["AXDocument"].value() || ""; }} catch(e) {{}}
            if (doc !== targetDoc) continue;
            matched = true;
            try {{
                candidate.actions.byName("AXRaise").perform();
            }} catch (raiseErr) {{
                try {{
                    candidate.attributes["AXMain"].setValue(true);
                }} catch (mainErr) {{}}
            }}
            break;
        }}
        matched ? "matched" : "missing";
        """)
        if result == "matched":
            _activate_xcode()
        return result == "matched"

    def _wait_for_document_window(self, document_uri: str, timeout: int = 10) -> bool:
        """等待目标文档窗口成为当前前台窗口。"""
        for _ in range(timeout):
            try:
                current_doc = str(self.get_window_info().get("document") or "")
            except RuntimeError:
                current_doc = ""
            if current_doc == document_uri:
                return True
            self._raise_window_for_document(document_uri)
            time.sleep(1)
        return False

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
            try {
                let cell = rows[i].uiElements[0];
                let statics = cell.staticTexts();
                let t = statics.map(s => s.value()).filter(v => v).join(" | ");
                let sel = rows[i].selected();
                let hasDisc = false, expanded = false;
                try {
                    let dts = cell.uiElements.whose({role: "AXDisclosureTriangle"});
                    if (dts.length > 0) { hasDisc = true; expanded = dts[0].value() === 1; }
                } catch(e2) {}
                out.push({index: i, text: t, selected: sel,
                           has_disclosure: hasDisc, expanded: expanded});
            } catch(e) {
                out.push({index: i, text: "", selected: false,
                           has_disclosure: false, expanded: false});
            }
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

    def _get_navigator_row_metrics(self, index: int) -> dict:
        """获取指定 Navigator 行及其 disclosure triangle 的几何信息。"""
        result = _jxa(_JXA_NAV_OUTLINE + f"""
        let rows = outline.rows();
        if ({index} < 0 || {index} >= rows.length) {{
            JSON.stringify({{exists: false, index: {index}}});
        }} else {{
            let row = rows[{index}];
            let cell = row.uiElements[0];
            let wp = win.attributes["AXPosition"].value();
            let ws = win.attributes["AXSize"].value();
            let rp = row.position();
            let rs = row.size();
            let text = "";
            try {{
                text = cell.staticTexts().map(s => s.value()).filter(v => v).join(" | ");
            }} catch(e) {{}}

            let hasDisc = false;
            let expanded = false;
            let discCenter = null;
            try {{
                let dts = cell.uiElements.whose({{role: "AXDisclosureTriangle"}});
                if (dts.length > 0) {{
                    let dt = dts[0];
                    let dp = dt.position();
                    let ds = dt.size();
                    hasDisc = true;
                    expanded = dt.value() === 1;
                    discCenter = [Math.round(dp[0] + ds[0] / 2), Math.round(dp[1] + ds[1] / 2)];
                }}
            }} catch(e) {{}}

            let rowCenter = [Math.round(rp[0] + rs[0] / 2), Math.round(rp[1] + rs[1] / 2)];
            let margin = 2;
            function inside(pt) {{
                if (!pt) return false;
                return pt[0] >= wp[0] + margin && pt[0] <= wp[0] + ws[0] - margin &&
                       pt[1] >= wp[1] + margin && pt[1] <= wp[1] + ws[1] - margin;
            }}

            JSON.stringify({{
                exists: true,
                index: {index},
                text: text,
                selected: row.selected(),
                has_disclosure: hasDisc,
                expanded: expanded,
                row_center: rowCenter,
                disclosure_center: discCenter,
                row_inside_window: inside(rowCenter),
                disclosure_inside_window: inside(discCenter),
                window_origin: wp,
                window_size: ws
            }});
        }}
        """)
        return json.loads(result)

    def _wait_for_row_expanded_state(self, index: int, expanded: bool,
                                     attempts: int = 6, delay: float = 0.2) -> bool:
        """等待指定行达到目标展开状态。"""
        for _ in range(attempts):
            try:
                metrics = self._get_navigator_row_metrics(index)
            except RuntimeError:
                metrics = {"exists": False}
            if metrics.get("exists") and metrics.get("expanded") == expanded:
                return True
            time.sleep(delay)
        return False

    def _safe_navigator_click(self, index: int, target: str, action: str):
        """仅在点击目标位于 Xcode 窗口内时才执行 cliclick。"""
        metrics = self._get_navigator_row_metrics(index)
        if not metrics.get("exists"):
            raise ValueError(f"Row {index} 不存在")

        point = metrics.get(f"{target}_center")
        if not point:
            raise RuntimeError(f"Row {index} 缺少 {target} 点击坐标")
        if not metrics.get(f"{target}_inside_window"):
            raise RuntimeError(
                f"Row {index} 的 {target} 坐标 {point} 位于 Xcode 窗口外，已跳过不安全点击"
            )

        _cliclick(f"{action}:{point[0]},{point[1]}")
        time.sleep(self.delay)

    def select_navigator_row_by_text(self, text_prefix: str) -> int:
        """选中文本以 text_prefix 开头的行，返回行索引。"""
        rows = self.list_navigator_rows()
        for r in rows:
            if r["text"].startswith(text_prefix):
                self.select_navigator_row(r["index"])
                return r["index"]
        raise ValueError(f"未找到以 '{text_prefix}' 开头的行")

    def expand_navigator_row(self, index: int):
        """展开 Navigator 中指定行的 disclosure triangle。"""
        metrics = self._get_navigator_row_metrics(index)
        if not metrics.get("exists"):
            raise ValueError(f"Row {index} 不存在")
        if not metrics.get("has_disclosure"):
            raise ValueError(f"Row {index} 没有 disclosure triangle")
        if metrics.get("expanded"):
            return

        self.select_navigator_row(index)
        time.sleep(0.2)

        _press_keycode(124)
        if self._wait_for_row_expanded_state(index, True):
            return

        if not self._has_cliclick:
            raise RuntimeError("展开失败，且未安装 cliclick 供坐标兜底: brew install cliclick")

        self._safe_navigator_click(index, "disclosure", "c")
        if not self._wait_for_row_expanded_state(index, True):
            raise RuntimeError(f"Row {index} 展开失败")

    def collapse_navigator_row(self, index: int):
        """折叠 Navigator 中指定行。"""
        metrics = self._get_navigator_row_metrics(index)
        if not metrics.get("exists"):
            raise ValueError(f"Row {index} 不存在")
        if not metrics.get("has_disclosure"):
            return
        if not metrics.get("expanded"):
            return

        self.select_navigator_row(index)
        time.sleep(0.2)

        _press_keycode(123)
        if self._wait_for_row_expanded_state(index, False):
            return

        if not self._has_cliclick:
            raise RuntimeError("折叠失败，且未安装 cliclick 供坐标兜底: brew install cliclick")

        self._safe_navigator_click(index, "disclosure", "c")
        if not self._wait_for_row_expanded_state(index, False):
            raise RuntimeError(f"Row {index} 折叠失败")

    def double_click_navigator_row(self, index: int):
        """双击 Navigator 中指定行 (需要 cliclick)。

        双击 draw call 行可以激活 GPU 绑定表编辑器和步进功能。
        仅 select 不够，必须双击才能进入分析模式。
        """
        if not self._has_cliclick:
            raise RuntimeError("需要 cliclick: brew install cliclick")
        self.select_navigator_row(index)
        time.sleep(0.3)
        self._safe_navigator_click(index, "row", "dc")

    # ═══════════════════ GPU Navigator Mode ═══════════════════

    def get_gpu_navigator_mode(self) -> str:
        """获取当前 GPU Navigator Mode。返回 'Group by API Call' 或 'Group by Pipeline State'。"""
        return _jxa(_JXA_NAV_OUTLINE + """
        let rows = outline.rows();
        let val = "unknown";
        for (let i = 0; i < Math.min(rows.length, 10); i++) {
            try {
                let pbs = rows[i].uiElements[0].popUpButtons();
                if (pbs.length > 0) { val = pbs[0].value(); break; }
            } catch(e) {}
        }
        val;
        """)

    def set_gpu_navigator_mode(self, mode: str):
        """切换 GPU Navigator Mode。

        Args:
            mode: 'Group by API Call' 或 'Group by Pipeline State'
        """
        _jxa(_JXA_NAV_OUTLINE + f"""
        let rows = outline.rows();
        let popup = null;
        for (let i = 0; i < Math.min(rows.length, 10); i++) {{
            try {{
                let pbs = rows[i].uiElements[0].popUpButtons();
                if (pbs.length > 0) {{ popup = pbs[0]; break; }}
            }} catch(e) {{}}
        }}
        if (!popup) throw new Error("找不到 Navigator mode popup");
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
        // 编辑器区域: 通过多层 splitterGroup 查找
        let sg = win.splitterGroups[0].splitterGroups[0];
        let edGroup = sg.uiElements[0];

        // 健壮地查找 Jump Bar: 在编辑器 group 的深层子元素中搜索
        function findJumpBars(root, depth) {
            if (depth > 5) return [];
            let bars = [];
            try {
                let ues = root.uiElements();
                for (let i = 0; i < ues.length; i++) {
                    try {
                        if (ues[i].description() === "Jump Bar") {
                            bars.push(ues[i]);
                        } else {
                            bars = bars.concat(findJumpBars(ues[i], depth + 1));
                        }
                    } catch(e) {}
                }
            } catch(e) {}
            return bars;
        }

        let jumpBars = findJumpBars(edGroup, 0);

        // 面包屑 Jump Bar: 含有 gputrace / CB / RE 等 popup 的那个
        let left = [];
        let right = [];
        for (let jb of jumpBars) {
            try {
                let popups = jb.popUpButtons();
                let vals = popups.map(p => { try { return p.value(); } catch(e) { return ""; } });
                if (vals.length >= 3 && vals[0].indexOf("gputrace") >= 0) {
                    left = vals;
                } else if (vals.length >= 1 && vals.length <= 3) {
                    right = vals;
                }
            } catch(e) {}
        }

        // Navigator mode
        let navMode = "";
        try {
            let nav = win.groups.whose({description: "navigator"})[0];
            let outline = nav.scrollAreas[0].outlines[0];
            let rows = outline.rows();
            for (let i = 0; i < Math.min(rows.length, 10); i++) {
                try {
                    let pbs = rows[i].uiElements[0].popUpButtons();
                    if (pbs.length > 0) { navMode = pbs[0].value(); break; }
                } catch(e) {}
            }
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

    @staticmethod
    def is_xcode_running() -> bool:
        """检查 Xcode 是否正在运行。"""
        r = subprocess.run(["pgrep", "-x", "Xcode"],
                           capture_output=True, timeout=3)
        return r.returncode == 0

    @staticmethod
    def wait_for_xcode(timeout: int = 30) -> bool:
        """等待 Xcode 启动就绪，返回是否成功。"""
        for _ in range(timeout):
            if XcodeGPU.is_xcode_running():
                time.sleep(1)  # 额外等待 UI 就绪
                return True
            time.sleep(1)
        return False

    def _find_replay_candidates(self, max_elements: int = 1200) -> list[dict]:
        """扫描窗口中可能的 replay 入口控件。"""
        result = _jxa(_JXA_PREAMBLE + f"""
        let all = win.entireContents();
        let out = [];
        let limit = Math.min(all.length, {max_elements});
        for (let i = 0; i < limit; i++) {{
            try {{
                let el = all[i];
                let role = "";
                let name = "";
                let desc = "";
                let value = "";
                let enabled = true;
                try {{ role = el.role(); }} catch(e) {{}}
                try {{ name = el.name() || ""; }} catch(e) {{}}
                try {{ desc = el.description() || ""; }} catch(e) {{}}
                try {{ value = "" + el.value(); }} catch(e) {{}}
                try {{ enabled = el.enabled(); }} catch(e) {{}}
                out.push({{
                    index: i,
                    role: role,
                    name: name,
                    description: desc,
                    value: value,
                    enabled: enabled
                }});
            }} catch(e) {{}}
        }}
        JSON.stringify(out);
        """)
        candidates = json.loads(result)

        replay_pattern = re.compile(r"(replay|start replay|resume replay|open.*gpu|gpu debug)", re.IGNORECASE)
        supported_roles = {
            "AXButton", "AXMenuButton", "AXPopUpButton", "AXRadioButton", "AXMenuItem"
        }
        filtered: list[dict] = []
        seen: set[tuple[str, str, str, str]] = set()
        for item in candidates:
            role = str(item.get("role") or "")
            if role not in supported_roles:
                continue
            haystack = " | ".join(
                str(item.get(key) or "") for key in ("name", "description", "value")
            )
            if not replay_pattern.search(haystack):
                continue
            key = (
                role,
                str(item.get("name") or ""),
                str(item.get("description") or ""),
                str(item.get("value") or ""),
            )
            if key in seen:
                continue
            seen.add(key)
            filtered.append(item)
        return filtered

    def get_replay_candidates(self, max_elements: int = 1200) -> list[dict]:
        """公开当前窗口中与 replay 相关的候选控件，便于诊断 UI 漂移。"""
        return self._find_replay_candidates(max_elements=max_elements)

    def _click_replay_candidate(self, candidate: dict) -> bool:
        """点击指定 replay 候选控件。"""
        index = int(candidate["index"])
        result = _jxa(_JXA_PREAMBLE + f"""
        let all = win.entireContents();
        let idx = {index};
        if (idx >= all.length) {{
            "out_of_range";
        }} else {{
            let el = all[idx];
            try {{
                if (!el.enabled || el.enabled()) {{
                    el.click();
                    delay({self.delay});
                    "clicked";
                }} else {{
                    "disabled";
                }}
            }} catch(e) {{
                "error: " + e;
            }}
        }}
        """)
        return result == "clicked"

    def _find_and_click_replay(self) -> tuple[bool, list[dict]]:
        """查找并尝试点击 replay 入口。返回是否成功及候选列表。"""
        try:
            candidates = self._find_replay_candidates()
            if not candidates:
                return False, []

            priority_patterns = [
                re.compile(r"^Replay$", re.IGNORECASE),
                re.compile(r"Start Replay", re.IGNORECASE),
                re.compile(r"Resume Replay", re.IGNORECASE),
                re.compile(r"Replay", re.IGNORECASE),
                re.compile(r"GPU Debug", re.IGNORECASE),
            ]

            def candidate_priority(candidate: dict) -> tuple[int, int]:
                text = " | ".join(
                    str(candidate.get(key) or "") for key in ("name", "description", "value")
                )
                for idx, pattern in enumerate(priority_patterns):
                    if pattern.search(text):
                        return (idx, int(candidate.get("index", 0)))
                return (len(priority_patterns), int(candidate.get("index", 0)))

            for candidate in sorted(candidates, key=candidate_priority):
                if not candidate.get("enabled", True):
                    continue
                if self._click_replay_candidate(candidate):
                    return True, candidates
            return False, candidates
        except RuntimeError:
            return False, []

    def _wait_for_navigator_data(self, timeout: int = 30) -> bool:
        """等待 Navigator 中出现 Command Buffer 数据。"""
        for _ in range(timeout):
            try:
                rows = self.list_navigator_rows()
                cbs = [r for r in rows if r["text"].startswith("Command Buffer")]
                if cbs:
                    return True
            except RuntimeError:
                pass
            time.sleep(1)
        return False

    def _enter_draw_call_analysis(self) -> bool:
        """展开第一个 CB 和 RE，双击第一个 draw call 进入分析模式。

        Returns:
            True 如果成功进入分析模式 (步进菜单已启用)
        """
        rows = self.list_navigator_rows()
        cb0 = next((r for r in rows if r["text"].startswith("Command Buffer")), None)
        if not cb0:
            return False

        # 展开 CB0
        if not cb0["expanded"]:
            self.select_navigator_row(cb0["index"])
            time.sleep(0.3)
            self.expand_navigator_row(cb0["index"])
            time.sleep(0.8)

        # 找 RE0 并展开
        rows = self.list_navigator_rows()
        re0 = next((r for r in rows if r["text"].startswith("Render Encoder 0 ")), None)
        if not re0:
            return False

        if not re0["expanded"]:
            self.select_navigator_row(re0["index"])
            time.sleep(0.3)
            self.expand_navigator_row(re0["index"])
            time.sleep(0.8)

        # 找第一个 draw call 行 (RE0 展开后的子节点中第二行通常是 draw call)
        rows = self.list_navigator_rows()
        draw_call_row = None
        for r in rows:
            idx = r["index"]
            if idx > re0["index"] and not r["text"].startswith("Render Encoder"):
                # 跳过 renderCommandEncoder 行，找 draw 行
                if "draw" in r["text"].lower() or r["text"].strip().split()[0].isdigit():
                    if "renderCommandEncoder" not in r["text"]:
                        draw_call_row = r
                        break
                    # renderCommandEncoder 行之后的才是 draw call
                    continue
            if r["text"].startswith("Render Encoder") and idx > re0["index"]:
                break  # 进入下一个 RE 了

        if not draw_call_row:
            # fallback: 双击 RE0 后面第二行
            for r in rows:
                if r["index"] == re0["index"] + 2:
                    draw_call_row = r
                    break

        if not draw_call_row:
            return False

        # 双击 draw call 行
        self.double_click_navigator_row(draw_call_row["index"])
        time.sleep(1)

        # 验证步进菜单是否启用
        try:
            menu = self.get_debug_menu_items()
            for m in menu:
                if m.get("name") == "Step to Next Draw/Dispatch Call":
                    return m.get("enabled", False)
        except RuntimeError:
            pass
        return False

    def open_gputrace(self, gputrace_path: str,
                      show_navigator: bool = True,
                      enter_analysis: bool = True,
                      timeout: int = 30) -> dict:
        """一键打开 gputrace 文件并进入 GPU 分析模式。

        完整流程:
        1. 用 Xcode 打开 gputrace 文件
        2. 等待 Xcode 启动
        3. 显示 Debug Navigator
        4. 点击 Replay 按钮
        5. 等待 Command Buffer 数据出现
        6. 展开 CB0 > RE0 → 双击 draw call → 激活步进功能

        Args:
            gputrace_path: .gputrace 文件的绝对路径
            show_navigator: 是否自动显示 Debug Navigator
            enter_analysis: 是否自动展开 CB 并进入 draw call 分析
            timeout: 等待超时秒数

        Returns:
            {success, xcode_running, navigator_ready, replay_done,
             cb_count, analysis_ready, message}
        """
        status = {
            "success": False, "xcode_running": False,
            "navigator_ready": False, "replay_done": False,
            "cb_count": 0, "analysis_ready": False, "message": "",
            "replay_candidates": []
        }

        # 1. 打开文件
        if not os.path.exists(gputrace_path):
            status["message"] = f"文件不存在: {gputrace_path}"
            return status

        resolved_gputrace = str(Path(gputrace_path).expanduser().resolve())
        target_document_uri = self._document_uri(resolved_gputrace)
        subprocess.run(["open", "-a", "Xcode", resolved_gputrace],
                       check=True, timeout=10)

        # 2. 等待 Xcode 启动
        if not self.wait_for_xcode(timeout):
            status["message"] = "Xcode 启动超时"
            return status
        status["xcode_running"] = True
        time.sleep(3)  # 额外等待窗口初始化

        if not self._wait_for_document_window(target_document_uri, timeout=min(timeout, 15)):
            status["message"] = f"未切换到目标 gputrace 窗口: {target_document_uri}"
            return status

        # 3. 显示 Debug Navigator
        if show_navigator:
            from xcode_general_ops import XcodeGeneral
            xc = XcodeGeneral()
            try:
                xc.show_navigator("Debug")
                time.sleep(1)
                status["navigator_ready"] = True
            except RuntimeError as e:
                status["message"] = f"显示 Navigator 失败: {e}"
                return status

        # 4. 若数据已存在，则不必再次点击 Replay
        if self._wait_for_navigator_data(timeout=2):
            status["replay_done"] = True
        else:
            clicked, candidates = self._find_and_click_replay()
            status["replay_candidates"] = [
                {
                    "index": item.get("index"),
                    "role": item.get("role"),
                    "name": item.get("name"),
                    "description": item.get("description"),
                    "value": item.get("value"),
                    "enabled": item.get("enabled"),
                }
                for item in candidates[:8]
            ]
            if not clicked:
                if self._wait_for_navigator_data(timeout=2):
                    status["replay_done"] = True
                else:
                    if status["replay_candidates"]:
                        summary = "; ".join(
                            filter(None, [
                                " / ".join(
                                    filter(None, [
                                        str(item.get("role") or ""),
                                        str(item.get("name") or ""),
                                        str(item.get("description") or ""),
                                        str(item.get("value") or ""),
                                    ])
                                )
                                for item in status["replay_candidates"][:3]
                            ])
                        )
                        status["message"] = f"未能点击 replay 入口，候选控件: {summary}"
                    else:
                        status["message"] = "未找到 replay 相关入口控件"
                    return status

        # 5. 等待 CB 数据
        if not self._wait_for_navigator_data(timeout):
            status["message"] = "等待 Command Buffer 数据超时"
            return status
        status["replay_done"] = True

        rows = self.list_navigator_rows()
        cbs = [r for r in rows if r["text"].startswith("Command Buffer")]
        status["cb_count"] = len(cbs)

        # 6. 进入 draw call 分析
        if enter_analysis and self._has_cliclick:
            if self._enter_draw_call_analysis():
                status["analysis_ready"] = True
            else:
                status["message"] = "进入 draw call 分析失败 (步进菜单未启用)"
                status["success"] = True  # Replay 已成功，分析入口可手动重试
                return status

        status["success"] = True
        status["message"] = (
            f"✅ 已就绪: {status['cb_count']} 个 Command Buffer"
            + (", 步进已启用" if status["analysis_ready"] else "")
        )
        return status

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

    # 读取类命令
    sub.add_parser("info", help="显示窗口信息")
    sub.add_parser("nav", help="列出 Navigator 所有行")
    sub.add_parser("cbs", help="列出 Command Buffers")
    sub.add_parser("breadcrumbs", help="读取面包屑导航")
    sub.add_parser("location", help="显示当前位置")
    sub.add_parser("editor", help="读取编辑器绑定表 (慢, ~30s)")
    sub.add_parser("summary", help="读取编辑器摘要 (慢, ~30s)")
    sub.add_parser("inspector", help="读取 Inspector 文本")
    sub.add_parser("filters", help="读取 filter 状态")
    sub.add_parser("menu", help="显示 Debug 菜单")
    sub.add_parser("status", help="检查 Xcode 运行状态")
    p = sub.add_parser("replay-candidates", help="列出当前窗口里的 replay 候选控件")
    p.add_argument("-n", "--max", type=int, default=1200, help="最多扫描的 UI 元素数量")

    # 操作类命令
    p = sub.add_parser("open", help="打开 gputrace 文件并进入分析模式")
    p.add_argument("path", help=".gputrace 文件路径")
    p.add_argument("--no-analysis", action="store_true",
                   help="只 Replay，不自动进入 draw call 分析")
    p.add_argument("--timeout", type=int, default=30, help="超时秒数")

    p = sub.add_parser("step", help="步进 draw call")
    p.add_argument("direction", choices=["next", "prev"], default="next", nargs="?")
    p.add_argument("--fine", action="store_true", help="细粒度 (GPU Call)")

    p = sub.add_parser("select", help="选中 Navigator 行")
    p.add_argument("index", type=int, help="行索引 (0-based)")

    p = sub.add_parser("expand", help="展开 Navigator 行 (需要 cliclick)")
    p.add_argument("index", type=int, help="行索引 (0-based)")

    p = sub.add_parser("collapse", help="折叠 Navigator 行 (需要 cliclick)")
    p.add_argument("index", type=int, help="行索引 (0-based)")

    p = sub.add_parser("dclick", help="双击 Navigator 行 (进入绑定表视图)")
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
    elif args.command == "status":
        running = gpu.is_xcode_running()
        print(f"Xcode: {'running' if running else 'not running'}")
        if running:
            try:
                info = gpu.get_window_info()
                print(f"Window: {info.get('title', '(no title)')}")
                print(f"Document: {info.get('document', '(none)')}")
            except RuntimeError:
                print("Window: (无法读取)")
            try:
                menu = gpu.get_debug_menu_items()
                step_ok = any(m.get("name") == "Step to Next Draw/Dispatch Call"
                              and m.get("enabled") for m in menu)
                print(f"GPU Debug: {'active' if step_ok else 'inactive'}")
            except RuntimeError:
                print("GPU Debug: unknown")
    elif args.command == "replay-candidates":
        print(json.dumps(gpu.get_replay_candidates(args.max), indent=2, ensure_ascii=False))
    elif args.command == "open":
        result = gpu.open_gputrace(
            args.path,
            enter_analysis=not args.no_analysis,
            timeout=args.timeout
        )
        print(json.dumps(result, indent=2, ensure_ascii=False))
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
    elif args.command == "collapse":
        gpu.collapse_navigator_row(args.index)
        print(f"Collapsed row {args.index}")
    elif args.command == "dclick":
        gpu.double_click_navigator_row(args.index)
        print(f"Double-clicked row {args.index}")
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
