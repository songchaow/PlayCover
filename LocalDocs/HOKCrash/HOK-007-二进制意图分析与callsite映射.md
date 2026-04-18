## HOK-007 二进制意图分析与 callsite 映射

### 目标

- 在不改动 PlayTools / runtime 启动顺序的前提下，先把 `com.tencent.ngr` 当前 faulting callsite 的 `LLDB`、`.ips`、Mach-O 区段与磁盘字节流映射关系固化成 agent 可独立复用的离线证据。
- 在进入任何 app 二进制 patch 前，先证明 `0x10480df08` / `___lldb_unnamed_symbol272374 + 124` 对应的 file offset、相邻指令、`instructionByteStream` 与寄存器上下文是一致的。

### 自动化入口

- runner：`Scripts/hok007_ngr_callsite_mapper.py`
- 默认命令：`python3 Scripts/hok007_ngr_callsite_mapper.py`
- 默认行为：
  - 读取 `build/hok-006-ngr-lldb-report.json`
  - 自动解析同轮 `.ips`：`/Users/songdogwang/Library/Logs/DiagnosticReports/NGR-2026-04-18-133909.ips`
  - 自动解析 concrete binary path：`/Users/songdogwang/Library/Containers/io.playcover.PlayCover/Applications/com.tencent.ngr.app/NGR`
  - 解码 `.ips` 的 `instructionByteStream.beforePC` / `atPC`
  - 读取 `xcrun otool -l` 结果，将 crash `imageOffset` 映射到 `__TEXT,__text` 与磁盘 file offset
  - 使用 `xcrun llvm-objdump --arch=arm64 --disassemble --start-address=... --stop-address=...` 输出 faulting window
  - 将结构化离线结论写入 `build/hok-007-ngr-callsite-report.json`

### HOK-007A 落地内容

- `Scripts/hok007_ngr_callsite_mapper.py`
  - 新增离线 mapper，统一消费 HOK-006 LLDB 报告、`.ips` 与 app 二进制。
  - 新增 `faultingFrame` / `faultingInstruction` 解析、`LLDB register read` 抽取、`.ips` 双 JSON 文档解析、`instructionByteStream` base64 解码、`otool -l` 区段映射与窄窗口反汇编。
  - 新增结构化 checks：`imageOffsetMatchesFaultPc`、`beforePcBytesMatch`、`atPcBytesMatch`、`disassemblyMatchesFaultInstruction`、`x19NullConfirmed` 等，用来判定离线 callsite 映射是否完成。
- `Scripts/test_hok007_ngr_callsite_mapper.py`
  - 覆盖 LLDB binary path 提取。
  - 覆盖 `.ips` 双 JSON 文档解析。
  - 覆盖 faulting frame / instruction 解析。
  - 覆盖 register 抽取、instruction byte stream 解码、Mach-O region/file offset 映射与 `llvm-objdump` 输出解析。

### 2026-04-18 latest offline 结果

- 运行命令：`python3 Scripts/hok007_ngr_callsite_mapper.py`
- 结构化报告：`build/hok-007-ngr-callsite-report.json`
- callsite 映射结论：
  - `faultPc=0x10480df08`
  - `.ips firstFrame.imageOffset=0x480df08`
  - `usedImage.base=0x100000000`
  - `preferredTextBase=0x100000000`
  - `fileOffset=0x480df08`
  - 命中区段：`__TEXT,__text`，其中 `vmaddr=0x100004000`、`fileoff=0x4000`
- 字节流结论：
  - `.ips instructionByteStream.beforePCHex` 与实际磁盘 `beforePCHex` 完全一致；长度均为 `40` bytes。
  - `.ips instructionByteStream.atPCHex` 与实际磁盘 `atPCHex` 完全一致；长度均为 `40` bytes。
  - 当前 faulting instruction 对应的磁盘原始字节为 `680240f9`；`llvm-objdump` 同一行显示为 `f9400268`，说明后续 patch 设计必须按磁盘小端字节序而不是反汇编展示序做 diff。
- 反汇编 / 寄存器结论：
  - faulting line 为 `ldr x8, [x19]`，与 HOK-006 结构化 LLDB 结论完全一致。
  - `x19=0x0` 在 `.ips` 与 LLDB register snapshot 中都再次命中。
  - `faultAddress=0x0` 与 `.ips far=0x0` 一致，继续支持“空指针解引用发生在 `NGR` 自身 early initializer 路径”的判断。
- gate 结论：
  - `beforePcBytesMatch=true`
  - `atPcBytesMatch=true`
  - `disassemblyMatchesFaultInstruction=true`
  - `x19NullConfirmed=true`
  - `checks.overallPass=true`

### 结论 / 下一步 handoff

- `HOK-007A` 已完成：当前 crash callsite 的 `LLDB` / `.ips` / Mach-O / file bytes 一致性已被离线固化，后续不需要再先靠人工做地址与字节映射。
- 下一步进入 `HOK-007B`：围绕 `0x10480df08` / `fileOffset=0x480df08` 设计**一个**最小可逆 patch 候选，并在真正改动前先写清楚 bytes diff、回滚方式与重签影响。
- `HOK-007B` 完成任一 patch 候选后，仍必须回到 `Scripts/hok004_ngr_startup_runner.py` + `Scripts/hok006_ngr_lldb_runner.py` 跑完整闭环，确认 faulting window 是否移动；在此之前不要切去 `HOK-008`。
