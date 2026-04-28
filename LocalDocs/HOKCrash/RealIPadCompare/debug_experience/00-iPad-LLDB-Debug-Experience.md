# iPad 真机 LLDB 调试经验手册

> 本文档汇总了在 PlayCover 项目中进行 iPad 真机 LLDB 调试的全部经验，
> 包括工具链、操作流程、已知问题与解决方案。
> 最后更新：2026-04-28

## 目录

1. [环境与工具链](#1-环境与工具链)
2. [进程管理：启动、杀掉、查询](#2-进程管理启动杀掉查询)
3. [LLDB Attach 方式对比](#3-lldb-attach-方式对比)
4. [断点设置与 ASLR Slide](#4-断点设置与-aslr-slide)
5. [Xcode GUI 自动化](#5-xcode-gui-自动化)
6. [已知问题与踩坑记录](#6-已知问题与踩坑记录)
7. [当前任务状态 (RIPC-010-A4)](#7-当前任务状态-ripc-010-a4)
8. [推荐后续方案](#8-推荐后续方案)

---

## 1. 环境与工具链

### 硬件/软件

| 项目 | 值 |
|---|---|
| iPad | Songchao的iPad (iPad Air 5, J407AP) |
| iPadOS | 26.4.1 (23E254) |
| UDID | `00008103-0011050A0E3B001E` |
| Mac | Apple Silicon (arm64e) |
| Xcode | 16.4 |
| 签名身份 | `BB36AD6577F23F304F93A1A75A940DAE92559A7B` (Apple Development) |
| Team | Songchao Wang (`L7CZY6S98T`) |
| 目标 App | `com.songdog.ripc.debug` (重签名后的王者荣耀世界) |
| IPA 源 | `~/Downloads/com.tencent.ngr_1.0.8_und3fined.ipa` (3.07GB, cryptid=0) |

### 关键工具

| 工具 | 用途 | 安装 |
|---|---|---|
| `xcrun devicectl` | 真机进程管理（启动/终止/调试） | Xcode 自带 |
| `xcrun lldb` | 调试器 | Xcode 自带 |
| `ios-deploy` | 备用部署工具 | `brew install ios-deploy` |
| `libimobiledevice` | 设备交互（idevicesyslog等） | `brew install libimobiledevice` |
| `pexpect` (Python) | LLDB 交互自动化 | `pip3 install pexpect` |

### 关键脚本

| 脚本路径 | 功能 |
|---|---|
| `Scripts/ripc_010a_materializer_probe.py` | LLDB Python probe：materializer entry/return 断点自动采集 |
| `Scripts/ripc_010a_check_slide.py` | 快速检查 NGR ASLR slide |
| `LocalDocs/XCodeOperation/xcode_general_ops.py` | Xcode GUI 自动化基础库（JXA/Accessibility） |
| `LocalDocs/XCodeOperation/ripc_010a_xcode_debug_automation.py` | Xcode 真机调试自动化（attach + console） |
| `Scripts/ripc_resign.sh` | IPA 重签名工具链 |

---

## 2. 进程管理：启动、杀掉、查询

### 查询设备

```bash
# 列出已连接设备
xcrun xctrace list devices

# 检查特定设备
xcrun xctrace list devices 2>&1 | grep "Songchao"
# → Songchao的iPad (26.4.1) (00008103-0011050A0E3B001E)
```

### 启动 App

```bash
# 普通启动
xcrun devicectl device process launch \
    --device 00008103-0011050A0E3B001E \
    --json-output /tmp/launch.json \
    com.songdog.ripc.debug

# ★ 挂起模式启动（等待调试器 attach）
xcrun devicectl device process launch \
    --device 00008103-0011050A0E3B001E \
    --start-stopped \
    --json-output /tmp/launch.json \
    com.songdog.ripc.debug

# 获取 PID
python3 -c "import json; d=json.load(open('/tmp/launch.json')); \
    print(f'PID={d[\"result\"][\"process\"][\"processIdentifier\"]}')"
```

### 杀掉 App

```bash
# 用 PID 杀
xcrun devicectl device process terminate \
    --device 00008103-0011050A0E3B001E \
    --pid <PID> --kill

# 注意：杀掉后需等 3-5 秒再重新启动，否则可能连到旧进程
```

### 重要经验

- `devicectl device process launch` 的 `terminateExistingInstances` 默认为 `false`。
  如果 App 已在运行，launch 命令不会杀掉旧实例，而是返回旧 PID。
- **必须先杀掉旧进程，等 3 秒，再启动新实例。**
- `--start-stopped` 不总是可靠：有时进程不在 `_dyld_start` 而在 `mach_msg2_trap`。
  这可能因为系统缓存了 App 状态（iPadOS 快速启动机制）。

---

## 3. LLDB Attach 方式对比

### 方式 A：CLI LLDB + `device process attach`

```bash
xcrun lldb
(lldb) device select 00008103-0011050A0E3B001E
(lldb) device process attach -p <PID>
```

**优点**：最直接，脚本化友好
**缺点**：`device select` 无确认输出；attach 输出是异步的

### 方式 B：CLI LLDB + `--batch --source`

```bash
# 创建命令文件
cat > /tmp/lldb_cmds.txt << 'EOF'
device select 00008103-0011050A0E3B001E
device process attach -p <PID>
command script import /path/to/probe.py
continue
EOF

xcrun lldb --batch --source /tmp/lldb_cmds.txt
```

**优点**：完全自动化
**缺点**：`device process attach` 在 batch 模式下不等待 attach 完成；
  `continue` 可能在 attach 未完成时执行

### 方式 C：Python pexpect 自动化

```python
import pexpect
c = pexpect.spawn("/usr/bin/xcrun", ["lldb"], timeout=300, encoding="utf-8")
c.expect(r"\(lldb\)", timeout=10)

c.sendline("device select 00008103-0011050A0E3B001E")
c.expect(r"\(lldb\)", timeout=15)

c.sendline(f"device process attach -p {pid}")
c.expect(r"Process \d+ stopped", timeout=60)  # ★ 等待 attach 确认
c.expect(r"\(lldb\)", timeout=10)

# 设置断点、加载脚本等...
c.sendline("continue")
```

**优点**：可以等待特定输出模式，比 batch 更可控
**缺点**：Ctrl-C 会杀死 LLDB 进程（pexpect EOF 问题）；
  异步输出匹配困难；进程长时间运行时 pexpect 可能断开

### 方式 D：Xcode GUI 自动化 (JXA)

```python
from xcode_general_ops import XcodeGeneral
from ripc_010a_xcode_debug_automation import XcodeDeviceDebug

auto = XcodeDeviceDebug()
auto.attach_to_process("NGR")       # Debug → Attach to Process
auto.show_debug_console()            # 显示 Debug Console
auto.send_to_debug_console("command script import /path/to/probe.py")
```

**优点**：与 Xcode 原生调试入口一致
**缺点**："Attach to Process" 子菜单进程列表加载极慢（>30 秒仍显示
  "Getting Process List…"）；JXA Accessibility 权限需要授予；
  `Application("Xcode").activate()` 会导致 JXA 永久挂起（必须用
  `System Events` 的 `frontmost = true`）

### 方式 E：LLDB Python API 直接

```python
import lldb
debugger = lldb.SBDebugger.Create()
ci = debugger.GetCommandInterpreter()
result = lldb.SBCommandReturnObject()
ci.HandleCommand("device select 00008103-0011050A0E3B001E", result)
ci.HandleCommand("device process attach -p <PID>", result)
```

**优点**：最程序化，不依赖 pexpect
**缺点**：`HandleCommand` 是同步的，device 命令可能需要异步处理；
  `device select` 等命令的行为与 CLI 不同；文档较少

### ★ 推荐方式

**交互式手动操作**最可靠：在终端直接运行 `lldb`，手动输入命令。

对于自动化，**方式 C (pexpect)** 是目前最实用的，但需要处理以下问题：
- attach 后等待 "Process N stopped" 再继续
- 不要用 Ctrl-C 中断（会杀死 LLDB），改用 `process interrupt` 命令
- 设置较长的 timeout

---

## 4. 断点设置与 ASLR Slide

### ASLR Slide 计算

```python
# 在 LLDB 中：
image list NGR
# 输出: [0] UUID 0xLOAD_ADDR /path/NGR.app/NGR (0xMODULE_ADDR)
# slide = LOAD_ADDR - 0x100000000

# 在 Python probe 脚本中：
for module in target.modules:
    if module.GetFileSpec().GetFilename() == "NGR":
        text = module.FindSection("__TEXT")
        slid = text.GetLoadAddress(target)
        slide = slid - 0x100000000  # _NGR_TEXT_BASE
```

### 断点地址计算

```python
# materializer 入口（unslid 地址来自 PlayCover 侧分析）
ENTRY_UNSOLID = 0x10432A068
RETURN_UNSOLID = 0x10432A31C

# 运行时地址 = unslid + slide
entry_runtime = ENTRY_UNSOLID + slide
return_runtime = RETURN_UNSOLID + slide
```

### 设置断点

```bash
# 方式 1：直接用运行时地址
(lldb) breakpoint set -a 0x107266068

# 方式 2：通过 probe 脚本自动设置
(lldb) command script import Scripts/ripc_010a_materializer_probe.py

# 方式 3：用 Python API
target.BreakpointCreateByAddress(entry_runtime)
```

### 验证断点状态

```bash
(lldb) breakpoint list
# 关键字段：
#   resolved / unresolved — 断点是否已解析到实际代码位置
#   hit count — 命中次数
#   locations — 断点位置数量
```

### ★ 核心发现：断点在 dyld 前后状态不同

**在 `_dyld_start` 阶段设置的断点**：
- `breakpoint list` 显示 `resolved = 1`
- 但 continue 后 dyld 运行完，断点变为 `unresolved`
- 结果：断点永远不会触发

**在 dyld 完成后（进程运行中）设置的断点**：
- `breakpoint list` 显示 `resolved = 1`
- 断点确实可以触发（已用 `objc_msgSend` 验证）
- 但此时 materializer 已被调用过（初始化阶段已过）

**这是当前 RIPC-010-A4 的核心卡点。**

---

## 5. Xcode GUI 自动化

### 可用的通用操作

| 操作 | 方法 |
|---|---|
| 激活 Xcode | `xc.activate()` — 使用 System Events，**不用** `Application("Xcode").activate()` |
| 列出窗口 | `xc.get_windows()` |
| 菜单操作 | `xc.click_menu("Debug", "Attach to Process by PID or Name…")` |
| 子菜单操作 | `xc.click_submenu("Debug", "Attach to Process", "NGR on Songchao的iPad")` |
| Debug Console | `xc.show_debug_console()` / `xc.read_debug_console()` |
| 发送命令 | `xc.send_debug_console_command("command script import /path/to/script.py")` |
| Breakpoint Navigator | `xc.show_breakpoint_navigator()` |
| UI 树 | `xc.dump_ui_tree()` |

### 关键经验

1. **`Application("Xcode").activate()` 会导致 JXA 永久挂起**。
   必须改用 `Application("System Events").processes["Xcode"].frontmost = true`。

2. **Debug Console 输入**：`AXValue.setValue()` 在 JXA 中报类型转换错误 (-1700)。
   绕过方法：`inputArea.value = "command text"` 直接赋值。

3. **"Attach to Process" 子菜单**：
   - 进程列表加载极慢（>30秒仍显示 "Getting Process List…"）
   - 目标进程名可能带设备前缀：`NGR on Songchao的iPad`
   - 需要等待 "Getting Process List…" 消失后再扫描

4. **Breakpoint Navigator "+" 按钮**：没有 "Address Breakpoint" 选项。
   地址断点必须通过 Debug Console 的 LLDB 命令设置。

5. **"Attach to Process by PID or Name…"** 在没有项目窗口时可能被禁用。

---

## 6. 已知问题与踩坑记录

### 问题 1：`--start-stopped` 不可靠

**现象**：使用 `--start-stopped` 启动后，有时进程不在 `_dyld_start` 而在
`mach_msg2_trap`（主循环）。

**原因**：可能因为 iPadOS 快速启动机制缓存了 App 状态；或之前的进程未完全退出。

**解决方案**：
- 先用 `--pid` 杀掉旧进程，等 3-5 秒
- 再用 `--start-stopped` 启动
- 验证 attach 后的 backtrace 是否在 `_dyld_start`

### 问题 2：断点在 dyld 运行后变为 unresolved

**现象**：在 `_dyld_start` 阶段设置断点，`breakpoint list` 显示 resolved。
Continue 后 dyld 完成链接，断点变为 unresolved，永远不会触发。

**原因**：dyld 在链接过程中可能重新映射模块，使之前设置的断点失效。

**影响**：这是 RIPC-010-A4 的核心阻塞问题——无法在 App 初始化阶段捕获
materializer 调用。

**已尝试的方案**：
- ✗ 在 `_dyld_start` 设断点后 continue → 断点变为 unresolved
- ✗ 两阶段策略（先 continue 过 dyld，再中断设断点）→ pexpect Ctrl-C 杀死 LLDB
- ✗ LLDB batch 模式 → `device process attach` 不等待 attach 完成
- ✗ LLDB `--source` 模式 → 同 batch 问题

### 问题 3：pexpect Ctrl-C 会杀死 LLDB

**现象**：用 `c.sendcontrol('c')` 中断进程时，LLDB 进程本身被杀死，
导致 `OSError: [Errno 5] Input/output error`。

**解决方案**：
- 用 `process interrupt` 命令代替 Ctrl-C
- 或用 `script lldb.debugger.GetSelectedTarget().GetProcess().Stop()` 

### 问题 4：`device select` 无确认输出

**现象**：`device select <UDID>` 命令只回显命令本身，不输出成功/失败信息。

**解决方案**：后续命令（如 `device process attach`）的成败可间接确认
device select 是否成功。

### 问题 5：`ios-deploy --debug` 不兼容

**现象**：`ios-deploy --debug` 在 Xcode 16.4 + iPadOS 26.4.1 组合下不兼容。

**解决方案**：使用 `xcrun devicectl` 代替 `ios-deploy` 进行真机调试。

### 问题 6：Attach to Process 子菜单加载极慢

**现象**：Xcode "Debug → Attach to Process" 子菜单进程列表加载超过 30 秒，
始终显示 "Getting Process List…"。

**解决方案**：避免使用此方式 attach。改用 CLI LLDB + `device process attach`。

### 问题 7：LLDB `--batch` 模式下 device 命令异步问题

**现象**：`lldb --batch --source cmdfile.txt` 中，`device process attach`
的输出是异步的，`continue` 可能在 attach 未完成时执行。

**解决方案**：使用 pexpect 等待 "Process N stopped" 输出后再继续。

---

## 7. 当前任务状态 (RIPC-010-A4)

### 目标

在真机 iPad 上对 materializer 函数 (0x10432a068) 设置 entry/return 断点，
采集 3 次调用的 entryX1 实参与返回值 (x0)，产物为
`build/ripc-010a-ipad-materializer-args.json`。

### 已验证的事实

1. ✅ NGR 可在真机上成功启动（无 QtsFileSystem Create Failed）
2. ✅ `devicectl device process launch --start-stopped` 可以让进程停在 `_dyld_start`
3. ✅ LLDB 可以通过 `device select` + `device process attach` 附加到真机进程
4. ✅ 断点在进程运行态下可以被正确解析（resolved = 1）
5. ✅ 运行态下的断点可以触发（`objc_msgSend` 断点已验证命中）
6. ✅ materializer 地址处的代码确实存在（反汇编验证了函数 prologue）
7. ✅ NGR 模块 UUID 在所有 session 中一致：`6249E7CD-DED6-3A79-BACA-8DAFFF80E837`
8. ✅ probe 脚本可以正确计算 ASLR slide 并设置断点

### 核心阻塞

**断点在 `_dyld_start` 阶段设置后，dyld 完成链接时变为 unresolved**。

这导致无法在 App 初始化阶段捕获 materializer 调用。所有尝试的自动化方案
（pexpect、batch、Xcode GUI）都受此限制。

### 尝试历史摘要

| 尝试 | 方式 | 结果 |
|---|---|---|
| #1 | CLI LLDB batch + device process attach | attach 未完成就执行 continue |
| #2 | pexpect + attach + probe + continue | 断点 resolved 但 30s 未命中 |
| #3 | pexpect + start-stopped + probe + 120s wait | 断点 resolved 但 120s 未命中 |
| #4 | pexpect + attach to running + objc_msgSend | ✅ objc_msgSend 命中！断点机制有效 |
| #5 | pexpect + start-stopped + probe + 5min wait | 断点 resolved 但 5min 未命中 |
| #6 | pexpect + attach to running + materializer bp | 断点 resolved 但进程已在主循环 |
| #7 | 两阶段（continue 过 dyld → Ctrl-C → 设断点） | Ctrl-C 杀死了 LLDB 进程 |
| #8 | shell script + lldb --batch 两阶段 | batch 模式 device attach 不可靠 |
| #9 | LLDB 内部 device process launch | "No such process" 错误 |

---

## 8. 推荐后续方案

### 方案 A：两阶段手动调试（最可靠）

1. 用 `devicectl` 以 `--start-stopped` 启动 NGR
2. 在终端手动运行 `lldb`
3. `device select <UDID>` → `device process attach -p <PID>`
4. `continue` — 让 dyld 完成
5. 等待 2-3 秒，手动按 Ctrl-C 中断
6. `image list NGR` — 确认模块已加载
7. 设置 materializer 断点：`breakpoint set -a 0x<entry>`
8. `continue` — 等待断点命中
9. **问题**：此方案需要人工操作，但 materializer 在 UE4 init 早期被调用，
  可能已被错过。需要验证 2-3 秒是否足够 dyld 完成但 materializer 尚未调用。

### 方案 B：RIPCProbe dylib 内联 hook（最可靠但需开发）

1. 修改 `RIPCProbe.m`（或创建新的 dylib），使用 `fishhook` 或
  `dlsym + inline hook` 拦截 materializer 函数
2. dylib 通过 `insert_dylib` 注入，在 App 初始化时自动加载
3. hook 函数记录 x1 参数和 x0 返回值
4. 通过 NSLog 或文件输出结果
5. **优点**：不依赖 LLDB，自动在初始化阶段运行
6. **缺点**：需要开发 C/Objective-C hook 代码；materializer 是 C++ 函数，
  不能用 ObjC method swizzling

### 方案 C：LLDB stop-hook + 自动化（中等难度）

1. 在 LLDB 中设置 stop-hook，在每次进程停止时检查是否可以设置 materializer 断点
2. `--start-stopped` 启动后，设置 `_dyld_start` 断点
3. Continue 到 `_dyld_start` 断点后，检查 NGR 模块是否已加载
4. 如果已加载，设置 materializer 断点
5. Continue
6. **优点**：纯 LLDB 方案，不需要额外开发
7. **缺点**：stop-hook 的触发时机可能不够精确

### 方案 D：`debugserver` 直接连接（底层方案）

1. 在 iPad 上手动启动 `debugserver`
2. 使用 LLDB 的 `process connect` 连接
3. 直接设置断点和调试
4. **优点**：绕过 CoreDevice 层，可能更可靠
5. **缺点**：需要在设备上部署 debugserver；配置复杂

### ★ 推荐优先级

1. **方案 A**（手动两阶段调试）— 立即可尝试
2. **方案 B**（dylib hook）— 如果 A 不可行
3. **方案 C**（stop-hook）— 如果需要自动化
