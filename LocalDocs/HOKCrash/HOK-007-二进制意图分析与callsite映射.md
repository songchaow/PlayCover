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

### HOK-007B 落地内容

- runner：`Scripts/hok007b_ngr_patch_runner.py`
- 默认命令：
  - dry-run（默认）：`python3 Scripts/hok007b_ngr_patch_runner.py`
  - apply：`python3 Scripts/hok007b_ngr_patch_runner.py --apply`
  - revert：`python3 Scripts/hok007b_ngr_patch_runner.py --revert`
- 结构化报告：`build/hok-007b-ngr-patch-report.json`
- 备份目录：`build/hok-007b-backups/hok-007b-<binarySha256Prefix>.bin`

#### 选定的 patch 候选（候选 E：branch-to-epilogue）

- file offset：`0x480df08`
- 原指令 / 原字节（LE）：`ldr x8, [x19]` / `680240f9`
- 替换指令 / patched 字节（LE）：`b 0x10480df24` / `07000014`
- branch 距离：`0x10480df24 - 0x10480df08 = 0x1c`（7 条指令）
- 语义：`0x10480df24` 是当前函数 epilogue 的 **stack cookie 校验 + 寄存器恢复 + `ret`**（见 `0x10480df24: ldur x8, [x29, #-0x48]` 一路走到 `0x10480df54: ret`）。由于 prologue 已经完整执行，跳到 epilogue 能保持 `sp` / `x29` / cookie 对称，把被空 `this` 触发的虚函数调用变成静默 no-op。
- 选候选 E 而非其他候选的依据：
  - 候选 A/B（把 `b.hs 0x10480dfa0` 改成无条件 `b`）不是真正的修复——后续大 buffer 分支 `0x10480dfe8: b.ge 0x10480dfac` / `0x10480dff4: b.ne 0x10480df00` 会把控制流重新送回 `0x10480df00`→`0x10480df08`，仍会命中同一 null deref。
  - 候选 C/D（在函数入口或 `ldr x8,[x19]` 位置做 `cbz x0, ...` / `cbnz x19, ...`）需要至少 2 条指令才能保持后续 `ldr x8,[x8,#0x10]; blr x8` 的合法性，不满足"只改 4 字节"的最小约束。
  - 候选 E 是唯一满足"**4 字节可逆、落在 faulting line 本身、跳点在同一函数内、不破坏栈帧对称性、不扩大影响面**"的候选。

#### 安全/回滚/重签

- 回滚：`--revert` 会使用 `build/hok-007b-backups/` 下最新 `.bin` 还原原 4 字节并重新 `codesign -f -s -`。
- 重签：apply / revert 都会自动对 NGR 做 ad-hoc 重签（`codesign -f -s -`）；`--skip-codesign` 仅用于诊断，不应用于日常流程。
- 幂等：`--apply` 遇到已 patched 状态时会报 `already-patched`；`--revert` 遇到已原样状态时报 `already-original`；任一状态不匹配时脚本拒绝写入，避免误改。

### 2026-04-18 apply + live 闭环结果

- 磁盘校验：
  - pre-apply sha256 `b0e109d761a3eefb67e8cd6ad117ad60db8ce642642042ea6b285e21e3455211`
  - post-apply sha256 `7f6ae20cf003475edff186e3f720741f33322787393f0235cc94aa247f9c8079`
  - 实际反汇编：`10480df08: 14000007  b 0x10480df24`（与候选 E 设计完全一致）
  - `codesign -dvv` 继续显示 `adhoc` 签名。
- HOK-004 live baseline（`build/hok-007b-post-patch-hok004.json`）：`createSessionSucceeded=true`、`readyObservedDuringSettleWindow=true`、`disconnectedObservedDuringSettleWindow=false`、`newCrashReportsDetected=false`、`overallPass=true`。**patch 之后 10s settle window 内 session 不再秒断且没有新 `.ips`。**
- HOK-006 live（`build/hok-007b-post-patch-hok006.json`）：LLDB capture window 内 `lldbStopObserved=false` / `faultingInstruction=None`；但在该轮更长的存活时间里观察到新 `.ips` `NGR-2026-04-18-154537.ips`，其 `pc=0x10915b114` / `imageOffset=0x4839d14` / `far=0x50`，**与 `0x10480df08` / `far=0x0` 属于完全不同的 callsite**。
- 结论：候选 E 已经成功把原来的 faulting window（`ldr x8,[x19]` / `far=0x0`）绕过；后续崩溃已经迁移到下游另一处（`far=0x50`，疑似对象偏移 `0x50` 上的另一个 null 依赖链），不再是本文档跟踪的 callsite。

### 结论 / 下一步 handoff

- `HOK-007A` 已完成：callsite 映射被离线固化。
- `HOK-007B` 已完成：候选 E（`ldr x8,[x19]` → `b 0x10480df24`）已应用并通过 HOK-004 baseline + HOK-006 交叉验证，faulting window 已移动到 `0x10915b114`（`far=0x50`）。
- 下一步主线：回到 Dashboard，基于新的 downstream crash（`NGR-2026-04-18-154537.ips`）决定是否要为 `0x10915b114` 再做一次 HOK-007A 风格的离线映射 + HOK-007B 风格的最小可逆 patch；不要在没有新映射证据的情况下直接跳到 `HOK-008`。
