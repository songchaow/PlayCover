# RIPC-010-A 执行记录 — 2026-04-28

## 执行内容

完成了 RIPC-010-A（真机 materializer 断点采集）的**脚本基础设施开发**，包括：

1. **LLDB Python 采集脚本** `Scripts/ripc_010a_materializer_probe.py`
2. **Xcode GUI 自动化协调脚本** `LocalDocs/XCodeOperation/ripc_010a_xcode_debug_automation.py`
3. **Dashboard 子任务拆分** — 将原 RIPC-010-A 拆分为 4 个可渐进完成的子任务

## 技术决策

### 路线选择

- `ios-deploy --nolldb` 已验证不可行（错误：`Unable to locate DeviceSupport directory with suffix 'DeveloperDiskImage.dmg'`）。这与 Dashboard 中记录的"`ios-deploy --debug` 在 Xcode 16.4 + iPadOS 26.4.1 下不兼容"结论一致。
- 转向 **Xcode GUI 自动化** 路线，基于 `LocalDocs/XCodeOperation` 已有的 JXA/Accessibility API 基础能力进行扩展。

### RIPC-010-A 子任务拆分

| 子任务 | 状态 | 说明 |
|--------|------|------|
| RIPC-010-A1 | **IN-PROGRESS → 已完成基础设施** | LLDB Python 采集脚本已创建，支持 materializer entry/return 断点自动采集 x1/x0/lr |
| RIPC-010-A2 | TODO | Xcode GUI 自动化 attach 脚本基础框架已创建，待实际 Xcode attach 场景验证 |
| RIPC-010-A3 | TODO | Debug Console 命令输入自动化待迭代（需探测实际 Xcode UI 结构） |
| RIPC-010-A4 | TODO | 端到端真机采集验证（需要人工配合或 A2/A3 验证通过后才能执行） |

## 产物详情

### `Scripts/ripc_010a_materializer_probe.py`

功能：
- 在 materializer entry (`0x10432a068`) 和 return (`0x10432a31c`) 设置断点
- 自动解析 NGR binary 的 ASLR slide，动态计算运行时地址
- Entry 断点回调采集：x0, x1, x2, x3, x30(lr)，并解码 x1 为 Pascal 字符串
- Return 断点回调采集：x0（返回值），并与对应 entry 记录关联
- 增量保存结果到 `build/ripc-010a-ipad-materializer-args.json`
- 同时输出人类可读的逐行日志到 `/tmp/ripc-010a-materializer-log.jsonl`

设计要点：
- 基于 `hok016c27_lldb_mainchunk_watch.py` 的成熟模式（`_reg_u64`、`_decode_pascal_string`、`_resolve_ngr_slide`）
- 断点回调返回 `False`（auto-continue），确保不中断 app 正常执行
- 支持多线程：使用 `thread_id` 将 entry 和 return 正确配对

用法（在已 attach 到真机进程的 LLDB 中）：
```lldb
command script import /Users/songdogwang/Codes/PlayCover/Scripts/ripc_010a_materializer_probe.py
```

### `LocalDocs/XCodeOperation/ripc_010a_xcode_debug_automation.py`

功能：
- `attach_to_process("NGR")`：通过 Xcode Debug → Attach to Process 菜单自动附加到真机 NGR 进程
- `show_debug_console()`：自动显示并激活 Debug Console
- `read_debug_console()`：通过 Accessibility API 遍历 `AXStaticText`/`AXTextArea` 尝试读取 Console 文本
- `send_to_debug_console(cmd)`：通过 AppleScript `keystroke` 向 Console 输入命令
- `show_breakpoint_navigator()`：切换 Breakpoint Navigator
- `run_full_probe(path)`：组合流程：attach → show console → load script

当前限制：
- `send_to_debug_console` 依赖 `keystroke` 和 `key code`，可能因 Xcode 版本/UI 布局差异而失效
- `add_address_breakpoint` 尚未实现（需要 Breakpoint Navigator 中 '+' 按钮的精确 UI 路径）
- 需要实际 Xcode attach 场景验证和迭代

## 下一步

1. **人工配合验证 A2**：由用户在 Xcode 中手动 Attach to Process → NGR，然后运行 `python3 ripc_010a_xcode_debug_automation.py attach` 验证菜单自动化是否成功
2. **UI 探测迭代 A3**：在 attach 成功的 Xcode 窗口上运行 `xcode_general_ops.py uitree` 和 `dump_ui_tree`，定位 Debug Console 输入框和 Breakpoint Navigator '+' 按钮的精确 Accessibility 路径
3. **端到端采集 A4**：A2/A3 验证通过后，运行完整流程，自动采集 materializer 调用参数

## 环境状态

- 真机：`Songchao的iPad` (iPadOS 26.4.1) 已连接
- Xcode 16.4 可用
- `com.songdog.ripc.debug` 已安装在真机上
- `ios-deploy 1.12.2` 已确认与当前环境不兼容
