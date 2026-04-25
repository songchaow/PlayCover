## HOK-007 二进制意图分析与 callsite 映射

> 本文只沉淀 HOK-007 的**离线 callsite 映射工具**、**patch 候选设计与选择理由**、**安全/回滚/重签口径**以及**候选 E 作为症状 workaround 的技术定位**。任务状态、apply 与 live 闭环结论、下游 `far=0x50` 之类 crash 是否继续跟踪，以 `00-Dashboard.md` 为准。
>
> **阅读建议**：一般无需读取；需要追查新 faulting callsite 或重新上/下候选 E 时按需读取。
>
> **相关文档**：
>
> - 静态初始化链与 `__common` slot writer 识别：`HOK-011-静态初始化链分析.md`；
> - Slot preheat（HOK-013 之后候选 E 的替代方案）：`HOK-013-slot-preheat.md`；
> - LLDB / watchpoint 方法论：`HOK-012-工具链与方法论归档.md`。

### 目标

- 在不改动 PlayTools / runtime 启动顺序的前提下，先把 `com.tencent.ngr` 当前 faulting callsite 的 `LLDB`、`.ips`、Mach-O 区段与磁盘字节流映射关系固化成 agent 可独立复用的离线证据。
- 在进入任何 app 二进制 patch 前，先证明 `0x10480df08` / `___lldb_unnamed_symbol272374 + 124` 对应的 file offset、相邻指令、`instructionByteStream` 与寄存器上下文是一致的。

### HOK-007A：离线 callsite 映射 mapper

- runner：`Scripts/hok007_ngr_callsite_mapper.py`
- 默认命令：`python3 Scripts/hok007_ngr_callsite_mapper.py`
- 默认行为：
  - 读取 `build/hok-006-ngr-lldb-report.json`
  - 解析同轮 `.ips`（由 LLDB 报告中的 crash window 时间锚定）
  - 解析 concrete binary path：`~/Library/Containers/io.playcover.PlayCover/Applications/com.tencent.ngr.app/NGR`
  - 解码 `.ips` 的 `instructionByteStream.beforePC` / `atPC`
  - 读取 `xcrun otool -l` 输出，将 crash `imageOffset` 映射到 `__TEXT,__text` 与磁盘 file offset
  - 使用 `xcrun llvm-objdump --arch=arm64 --disassemble --start-address=... --stop-address=...` 输出 faulting window
  - 将结构化离线结论写入 `build/hok-007-ngr-callsite-report.json`
- 结构化 checks：
  - `imageOffsetMatchesFaultPc`
  - `beforePcBytesMatch` / `atPcBytesMatch`
  - `disassemblyMatchesFaultInstruction`
  - `x19NullConfirmed`
- focused tests：`Scripts/test_hok007_ngr_callsite_mapper.py`
  - LLDB binary path 提取
  - `.ips` 双 JSON 文档解析
  - faulting frame / instruction 解析
  - register 抽取、instruction byte stream 解码、Mach-O region/file offset 映射、`llvm-objdump` 输出解析

### HOK-007B：候选 E（branch-to-epilogue）patch 设计

- runner：`Scripts/hok007b_ngr_patch_runner.py`
- 命令：
  - dry-run（默认）：`python3 Scripts/hok007b_ngr_patch_runner.py`
  - apply：`python3 Scripts/hok007b_ngr_patch_runner.py --apply`
  - revert：`python3 Scripts/hok007b_ngr_patch_runner.py --revert`
- 报告：`build/hok-007b-ngr-patch-report.json`
- 备份目录：`build/hok-007b-backups/hok-007b-<binarySha256Prefix>.bin`

#### 候选 E 的定义

- file offset：`0x480df08`
- 原指令 / 原字节（LE）：`ldr x8, [x19]` / `680240f9`
- 替换指令 / patched 字节（LE）：`b 0x10480df24` / `07000014`
- branch 距离：`0x10480df24 - 0x10480df08 = 0x1c`（7 条指令）
- 语义：`0x10480df24` 是当前函数 epilogue 的 **stack cookie 校验 + 寄存器恢复 + `ret`**（`0x10480df24: ldur x8, [x29, #-0x48]` 一路走到 `0x10480df54: ret`）。prologue 已经完整执行，跳到 epilogue 能保持 `sp` / `x29` / cookie 对称，把被空 `this` 触发的虚函数调用变成静默 no-op。

#### 候选 E 与 A/B/C/D 的比较

- 候选 A/B（把 `b.hs 0x10480dfa0` 改成无条件 `b`）不是真正的修复——后续大 buffer 分支 `0x10480dfe8: b.ge 0x10480dfac` / `0x10480dff4: b.ne 0x10480df00` 会把控制流重新送回 `0x10480df00`→`0x10480df08`，仍命中同一 null deref。
- 候选 C/D（在函数入口或 `ldr x8,[x19]` 位置做 `cbz x0, ...` / `cbnz x19, ...`）至少需要 2 条指令才能保持后续 `ldr x8,[x8,#0x10]; blr x8` 合法性，不满足"只改 4 字节"的最小约束。
- 候选 E 是唯一满足"**4 字节可逆、落在 faulting line 本身、跳点在同一函数内、不破坏栈帧对称性、不扩大影响面**"的候选。

#### 安全 / 回滚 / 重签

- 回滚：`--revert` 使用 `build/hok-007b-backups/` 下最新 `.bin` 还原原 4 字节并重新 `codesign -f -s -`。
- 重签：apply / revert 都会自动对 NGR 做 ad-hoc 重签（`codesign -f -s -`）；`--skip-codesign` 仅供诊断，不用于日常流程。
- 幂等：`--apply` 遇到已 patched 状态时报 `already-patched`；`--revert` 遇到已原样状态时报 `already-original`；任一状态不匹配时脚本拒绝写入，避免误改。
- `Scripts/hok007b_ngr_patch_runner.py` 是"磁盘 NGR 当前处于哪一代 patch"的唯一来源；不要另起手工流程。

### 候选 E 的技术定位

- 候选 E 是 faulting reader 侧的**最小可逆 workaround**，不是根因修复。HOK-011 的全二进制静态分析证明：faulting caller 读取的 `__common` 槽位 `0x10e2146f8` 在 NGR 自身 `__init_offsets` 链中不可达——真正 prime 它的代码必然存在于**外部 embedded framework / ObjC `+load` / 跨 dylib static ctor 链**。候选 E 让 NGR 的 reader init 跨过 null deref，但**不改变** `0x10e2146f8` 的 null 状态。
- 因此候选 E apply 后 app 会暴露依赖同一批 `__common` 槽位的下游问题（例如 `QtsFileSystem Create Failed!!`、`pc=0x10915b114 / far=0x50`、`far=0x30` 等）；这些**不是**候选 E 本身的缺陷，而是 HOK-012 要用 live-trace 锁定 writer 的原因。
- 详见 `LocalDocs/HOKCrash/HOK-011-静态初始化链分析.md`。
