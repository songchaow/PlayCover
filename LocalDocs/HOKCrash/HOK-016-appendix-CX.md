# HOK-016 附录：HOK-016-C.X.1 seed 替换实验

> 本文是 `HOK-016-qts-fs-create-failed.md` 的附录，沉淀 HOK-016-C.X.1
> "HOK-015 seed value 驱动 QtsFS 失败" 假设的证伪实验：4 种 seed 下
> `0x108878534` 返回值恒为 0、reporter 内部 failure sink 命中次数恒为 3。
>
> **何时读**：
>
> - 需要重跑 seed 替换实验；
> - 需要引用该实验的 transcript / 产物作为"cmdline 不驱动 QtsFS"的
>   证据；
> - 需要评估"换 cmdline 能否影响 QtsFS"的兄弟假设；
> - 日常阅读 HOK-016 主文档不必进入本文。
>
> **相关文档**：
>
> - HOK-015 本体：`HOK-015-cmdline-preseed.md`；
> - readiness B 内部真失败点：`HOK-016-appendix-C23-C24.md`；
> - 脚本说明与 LLDB BP callback 踩坑：`HOK-016-appendix-tooling.md`。

## 脚本

- `Scripts/hok016cx_lldb_cmdline_override.py`：LLDB Python 模块；
  `rewrite_cmdline_on_hit` BP 回调 runtime 解析 NGR image slide、
  `process.WriteMemory` 写 seed UTF-16-LE + 2-byte null terminator 到
  `0x10e20107a`、并重置 `bInitialized=1 @ 0x10e201078`（幂等防御）。
- `Scripts/hok016cx_ngr_seed_experiment.py`：实验 driver；4 候选 seed
  顺序跑（`empty` / `project` = `"NGR"` / `ue4cmdfile` =
  `"../../../NGR/ue4commandline.txt"` / `uproject` = baseline
  `"../../../NGR/NGR.uproject"`），每个 seed 单独跑一轮 hok006 runner、
  抓 `w0@+900` / `w0@+912` / UE4 "Project file not found" 计数 /
  failure sink 计数，汇总到 `build/hok-016cx-summary.json`。

## 实验结果

| seed | UE4 "Project file not found" | w0@+900 | w0@+912 | failSink 命中次数 |
|---|---|---|---|---|
| `empty`      | 0 | 0x1 | **0x0** | 3 |
| `project`    | 0 | 0x1 | **0x0** | 3 |
| `ue4cmdfile` | 0 | 0x1 | **0x0** | 3 |
| `uproject`   | 1 | 0x1 | **0x0** | 3 |

### 关键观察

1. **所有 4 种 seed 下 `w0@+912 = 0`**——`0x108878534` 返回 0 与
   cmdline 内容**无关**。
2. `empty` / `project` / `ue4cmdfile` 三种 seed 确实消除了 UE4 的
   `[UE4] Project file not found` log，但这**不影响** QtsFS 的失败
   路径。
3. QtsFS 的 Create Failed sink 在全部 4 种 seed 下各触发 3 次，分布
   无变化。

**含义**：HOK-016-C.X（换 HOK-015 seed value）证伪了 "cmdline 内容驱
动 QtsFS 失败" 假设；Dashboard 据此把主线推进到 `0x108878534` 的内部
深度分析（HOK-016-C.2 系列）。

## 跨 run 稳定 transcript 片段

1. UE4 自身 stderr：`[UE4] Project file not found: ../../../NGR/NGR.uproject`
2. `(lldb)  register read x0` → `x0 = 0x0000000000000001`  ← `+900 tbz`
   前：readiness A (`0x108876a94`) 返回 **1 / ok**
3. `(lldb)  register read x0` → `x0 = 0x0000000000000000`  ← `+912 tbz`
   前：readiness B (`0x108878534`) 返回 **0 / fail**
4. `stop reason = breakpoint 3.1` @ `0x108878124` (+1364 failure sink)
   backtrace 与 HOK-016-B 完全一致；`x19` = QtsFS `this`、
   `x24` = `0x10e1ee000`（QtsFS 全局 subsystem readiness 表基址，
   `x24->0xef0` 是 sentinel byte）。

## 关键 LLDB 语法踩坑

`breakpoint set` **不支持** `--script-type python -F <func>` 形式（会
报 `unknown or ambiguous option`）；必须拆成两步 —— 先
`breakpoint set ...`，紧接 `breakpoint command add -s python -F <func>`
（默认对最后创建的 BP 操作，两条命令之间不能插入其它 `breakpoint
set`）。

## 证据产物

- `build/hok-016cx-summary.json`：全 4 seed 汇总。
- `build/hok-016cx-*-trace.json`：每 seed 单独的 hok006 trace。
