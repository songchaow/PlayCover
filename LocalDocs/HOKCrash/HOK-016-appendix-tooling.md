# HOK-016 附录：运行期工具链与脚本目录

> 本文是 `HOK-016-qts-fs-create-failed.md` 的附录，沉淀 HOK-016-A/B/C
> 各子任务用到的所有 `Scripts/hok016*` 脚本的详细说明、输入/输出、
> 以及 LLDB BP callback 的关键踩坑。
>
> **何时读**：
>
> - 需要重跑某一轮 live trace；
> - 需要为新子任务复用现有 Python probe helper；
> - 需要按脚本名反查它解决的是 HOK-016 哪一层证据；
> - 日常阅读 HOK-016 主文档不必进入本文。
>
> **相关文档**：
>
> - HOK-016 本体 / 根因链骨架：`HOK-016-qts-fs-create-failed.md`；
> - C.2.3 / C.2.4 readiness B 内部：`HOK-016-appendix-C23-C24.md`；
> - C.2.5 / C.2.6 rootB + mainChunk：`HOK-016-appendix-C25-C26.md`；
> - C.2.7 storage fail + dual-force + err-slot：
>   `HOK-016-appendix-C27.md`；
> - seed 替换实验：`HOK-016-appendix-CX.md`。

## 静态分析

### `Scripts/hok016_ngr_qts_locator.py`

静态定位器（HOK-016-A）。复用 HOK-015 locator 的 Mach-O parser +
ARM64 decoder；新增能力：

1. 同时扫 `__cstring`（ASCII）与 `__ustring`（UTF-16-LE）两个 section；
2. 通过 primary marker 的 xref 走回 function prologue；
3. 枚举 family prefix 下的所有字符串并给出每条的 adrp+add xref；
4. dump reporter 入口的前 N 条指令（人读的 mnemonic hint）到 JSON。

产物：`build/hok-016-qts-fs-static.json`。

### `Scripts/hok016c2_ngr_sentinel_writer_scan.py`

HOK-016-C.2.2 的离线全 `__text` 段扫描器。复用 HOK-015/016 的 Mach-O
parser + ARM64 decoder；新增能力：

1. 原生 ARM64 定长 32-bit decode（4 字节步长遍历整个 NGR 主 __text 段，
   169MB 仅 2s 完成），**不依赖 llvm-objdump**；
2. 覆盖 `str` / `strb` / `strh` / `str.w`（32-bit GPR store）四种"写
   入某个全局 byte/short/word" 模式——HOK-011 原脚本只扫 `str`，漏
   掉 byte-level sentinel 的 writer；
3. 跟踪 `adrp+add`/`adrp`/`mov reg`/`add` 链的 per-register
   abstract state（不限 basic block），任意 writer 命中都附最近的
   函数 prologue walk-back（复用 HOK-016 的 `find_function_entry`）。

产物：`build/hok-016c2-sentinel-writer-full-text.json`。当前对
`0x10e1eeef0` 命中 **0 writer**——与运行期 probe 一起证实 "sentinel
未 bump" 假设被彻底推翻。

### `Scripts/hok016c25_ngr_rootB_xref_scan.py`

HOK-016-C.2.5 的离线 adrp+add xref 扫描器。枚举所有把目标全局地址
materialize 到寄存器的 `adrp+add` pair、按 dst reg + 函数分组给出
helper 消费视图。对 rootB 找到 94 hits / 52 不同函数、全部经 x0/x1
传参；产物 `build/hok-016c25-rootB-xrefs.json`。

### `Scripts/hok016c26_ngr_main_literal_xref.py` / `hok016c26_ngr_rootB_keys.py`

HOK-016-C.2.6 的两个离线 helper：

- `hok016c26_ngr_main_literal_xref.py`：扫描 NGR 二进制里所有
  `__cstring main` 文本 + 与 `__init_offsets` 可达链相交检查。产物
  `build/hok-016c26-main-literal.json`。
- `hok016c26_ngr_rootB_keys.py`：读取 C.2.5 watchpoint 抓到的新 node
  地址，解码 `node+0x20` PascalString，判断 rootB 实际插入的 key。

### `Scripts/hok016c27_ngr_mainchunk_callers.py`

HOK-016-C.2.7 的离线 caller scan。枚举 `0x1001ba82c` /
`0x1001bd448` / `0x1001cd114` 的 direct callers、shallow callers 与
附近 `#0x60` store；当前结果显示 `lookup2` 有 7 个 direct caller
function，`0x1001ba50c` 是唯一带 5 个 shallow callers 的 wrapper 候选。
产物 `build/hok-016c27-mainchunk-callers.json`。

## 运行期 LLDB driver

### `Scripts/hok016_ngr_qts_reporter_trace.py`

HOK-016-B 的 LLDB 运行期 backtrace/register 捕获器。wrapper 调用
`Scripts/hok006_ngr_lldb_runner.py`：

1. 从 `build/hok-016-qts-fs-static.json` 读取 reporter 入口 + 家族
   xref 地址；
2. 生成 `breakpoint set --shlib NGR --address <unslid> -C 'thread
   backtrace' -C 'register read x0..x8'` 命令（**必须 `--shlib NGR`**；
   绝对 VA 在 ASLR 下不命中，已验证）；
3. 跑 `hok006` runner 拿 15s `lldb-timeout`；
4. 解析 transcript 抽出每次 BP hit 的线程 / 寄存器，并与
   `build/hok-015-cmdline-slots.json` 做 x1/x2 低 28 位交叉比对。

产物：`build/hok-016-qts-reporter-lldb.json` + `build/hok-016-qts-
reporter-summary.json`。

### `Scripts/hok016c_ngr_qts_w0_trace.py`

HOK-016-C.1 的最小 runner。封装 `hok006` runner，在 `0x108877bd0` 的
两条 `tbz w0, #0, <fail>` 判定点前设 auto-continue BP 抓 `register
read x0`，在失败 sink 设 hard-stop BP 终结 run。BP 地址完全由
HOK-016-A/B 定位固化；**不动 NGR 二进制、不改 PlayTools 代码**。产物
`build/hok-016c-w0-trace.json`。

### `Scripts/hok016c2_lldb_sentinel_watch.py`

LLDB Python helper（HOK-016-C.2 系列 driver 用 `command script import`
引入）。提供两个 BP callback：

- `probe_sentinel_on_hit(frame, bp_loc, internal_dict)`：读 NGR main
  image 的 runtime slide → `ReadMemory(0x10e1eeef0 + slide, 1)` → 把
  byte 值 + ±8-byte window 打印到 transcript 为 `[hok016c2]
  sentinel @ <addr> = 0xNN ...`，driver 可用 regex 抓。auto-continue。
- `install_watchpoint_on_hit(frame, bp_loc, internal_dict)`：
  `target.WatchAddress(sent_addr, 1, read=False, write=True)` 装 1
  byte modify watchpoint。one-shot。

### `Scripts/hok016c2_ngr_sentinel_probe.py`

HOK-016-C.2.2 driver。在 HOK-016-C.1 的 3 个 BP（+900 / +912 /
+1364）各挂一个 `probe_sentinel_on_hit` Python callback（`--mode
probe`）；`--mode watchpoint` 则额外在 NGR `main` 入口（unslid
`0x107e5cad4`）挂 `install_watchpoint_on_hit`，arm 一个 sentinel
modify watchpoint。产物 `build/hok-016c2-sentinel-probe.json` /
`build/hok-016c2-sentinel-watch.json`。

### `Scripts/hok016c2_ngr_step_into_readinessB.py`

HOK-016-C.2.3 driver。在 `0x108878534 +352 bl 0x10432dd98` 前/后、
`0x10432dd98` 入口、以及 `0x108877bd0 +912 tbz` 和 `0x108878124
+1364` 失败 sink 各挂 shell `-C 'register read ...'` callback（全部
auto-continue 除 fail sink）。产物
`build/hok-016c2-step-into-readinessB.json`。

### `Scripts/hok016c24_ngr_readinessB_inner_args.py` + `hok016c24_lldb_inner_probes.py`

HOK-016-C.2.4 的 step-into driver + LLDB Python probe helper。在
`0x10432dd98` 全函数 + `0x10017f184` 的 lookup 入口/出口 + `0x10017f3c8`
的 lookup 入口/出口 + 可选的 `0x10432b734` 内部装 ~30 个 Python
callback BP，每个 BP 解析 FString / PascalString / rootB header；
产物 `build/hok-016c24-readinessB-inner-args.json`。

### `Scripts/hok016c25_ngr_rootB_watch.py`

HOK-016-C.2.5 的 LLDB watchpoint live-trace driver。在 NGR `main`
入口（unslid `0x107e5cad4`）装 8-byte modify watchpoint 到 rootB，
确保只抓 dyld static init 之后的写；命中时自动 dump backtrace +
registers。产物 `build/hok-016c25-rootB-watch.json`。

### `Scripts/hok016c27_ngr_mainchunk_subtree_trace.py` + `hok016c27_lldb_mainchunk_watch.py`

HOK-016-C.2.7 的 live trace driver + LLDB helper。在 `0x10017f1dc`
动态装 `mainChunk+0x60` watchpoint，并对 `0x1001bd448` /
`0x1001ba82c` / `0x1001ba50c` / `0x1001a5014` / `0x10432e074` 采样；
覆盖范围扩展到 storage method / create-table helper / entry-build
branch / `0x10012595c -> 0x1001148b8 -> 0x1001142a4 -> 0x100122f20/
0x100122f58/0x100122f60 -> 0x100122f98` 这条更深层 err-slot /
materialization 链 / final-check / err=9 写点。在 gate-ret
`0x100125030` 时会根据需要动态把 err slot watchpoint 装到 caller
传入的 err slot 上；新增的 materialization breakpoint 现在会同时覆盖
`0x100122f20` entry、`0x100122f54` precall、`0x100122f58` return、
`0x100122f60` result：既打出 `x20=errSlot` / `x21<-x2` / `x22<-x1` /
`x19=helper`，也打出 `0x100122f54` 那次 vcall 的 `x8 target` / saved args /
helper vtable，再配合返回值判断到底是 success-side 汇合
（`x30=0x100122f7c`）还是 err-provider 路径（`x30=0x100122f88`）。产物新增
`build/hok-016c27-materialize-vcall-trace-v3.json`；历史还保留
`build/hok-016c27-materialize-trace.json` /
`build/hok-016c27-deep-err-chain.json` /
`build/hok-016c27-mainchunk-subtree-trace.json` /
`build/hok-016c27-final-check-errslot-watch.json`。

### `Scripts/hok016c4_ngr_force_storage_success.py`

HOK-016-C.4 的诊断性 force-success runner。当前支持两档实验：

- (a) 只强制 `0x1001a522c` 的 storage-method return；
- (b) 再叠加 `0x1001a6958` 的 ready/save-header return。

后者已证明 `0x10017f184` / `0x10432dd98` 能被推成 success，并能激活
dormant writer path；产物
`build/hok-016c4-force-storage-success.json` /
`build/hok-016c4-force-storage-ready-success.json` /
`build/hok-016c4-force-storage-ready-no-wp.json`。

### `Scripts/hok016cx_lldb_cmdline_override.py` + `hok016cx_ngr_seed_experiment.py`

HOK-016-C.X.1 seed 替换实验。LLDB Python callback 动态改写
`FCommandLine::CmdLine` 为 4 候选 seed（empty / project / ue4cmdfile /
uproject），每 seed 跑一轮 hok006 runner；产物
`build/hok-016cx-summary.json` + 4 份 per-seed trace。**已用于证伪**
"HOK-015 seed 驱动 QtsFS 失败" 假设。

## LLDB BP callback 关键踩坑

- **`breakpoint set` + `breakpoint command add -s python -F` 必须拆两步**。
  `breakpoint set` 本身**不支持** `--script-type python -F <func>`（会
  报 `unknown or ambiguous option`）；必须拆成 `breakpoint set ...`
  + 紧邻的 `breakpoint command add -s python -F <func>` 两步。
  `breakpoint command add` 默认对最后创建的 BP 操作，所以两步之间
  **不能插入其它 `breakpoint set`**。参考
  `Scripts/hok016cx_ngr_seed_experiment.py` 的 pre_run_commands 结构。
- **`-C 'shell cmd'` 与 `command add -s python -F` 不能同时对同一 BP
  生效**（两种 callback 会冲突，产生无法分辨的 hit），必须二选一。
- **FString vs PascalString 不要混用**。NGR 的 Qtsk 容器里
  `[length:u64][chars:N\0]` PascalString 不等同于 UE4 FString
  (`[data_ptr:u64][Num:i32][Max:i32]`)，解码时要分开尝试。
- **fail-sink BP 不挂 Python probe**：`breakpoint command add -s
  python -F ...` 会**替换**原 `-C '...'` shell callback list，丢失
  `thread backtrace` / `register read` 输出。让 +912 probe 那一次
  命中去拿 sentinel 就够了。
- **绝对 VA 在 ASLR 下不命中**：对 NGR 主 image 内的固定地址必须用
  `breakpoint set --shlib NGR --address <unslid>` 的 module-relative
  格式；`hok006_ngr_lldb_runner.py` 本身只透传 pre-run-command 字
  符串，调用方负责拼这条格式。
- **LLDB transcript 解析 `-C` callback 输出**：LLDB 把 callback 命令
  echo 成 `(lldb)  <cmd>`（**2 空格**），而 `breakpoint set ... -C
  'cmd'` 这种 BP-creation 行 echo 成 `(lldb) <cmd>`（**1 空格**）。
  解析 "register read x0 的输出值" 时必须锚定
  `startswith("(lldb)  register read x0")` 两空格。
