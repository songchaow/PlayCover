# HOK-016 附录：HOK-016-C.2.7 证据详解

> 本文是 `HOK-016-qts-fs-create-failed.md` 的附录，沉淀 HOK-016-C.2.7
> 的完整逐层证据：从 `mainChunk+0x60` watchpoint live trace，一路下钻
> 到 `ba50c` fallback builder → `0x1001a5014` storage 创建 →
> `0x10012bb7c` null table → dual-force checkpoint → sibling branch +
> hollow wrapper → `0x9000b` err-slot / materialization 链。
>
> **何时读**：
>
> - 做 HOK-016-C.2.7 / C.4 / C.5 任何 probe 或修复设计时总是读；
> - 只需要同步**当前最新收紧口径**时，优先看 **§14**；
> - 需要复盘“问题是如何从 `mainChunk+0x60` 缺口一路收紧到
>   materialization vcall 返回 0”时，再按顺序回看 §1-§13；
> - 需要理解两支 sibling branch 如何共同把 second-gate 压回 0、或需
>   要在 C.5 PlayTools shim 里决定"模拟哪一层 contract"时读；
> - 日常阅读 HOK-016 主文档不必进入本文。
>
> **相关文档**：
>
> - 上一层 rootB / mainChunk 缺口：`HOK-016-appendix-C25-C26.md`；
> - readiness B 内部控制流 / `0x10017f184` 真失败决定点：
>   `HOK-016-appendix-C23-C24.md`；
> - 脚本说明与 LLDB BP callback 踩坑：`HOK-016-appendix-tooling.md`。

## 1. live trace 已能在 `mainChunk` 出现的第一时间稳定装上 `mainChunk+0x60` watchpoint

新增 `Scripts/hok016c27_ngr_mainchunk_subtree_trace.py` +
`Scripts/hok016c27_lldb_mainchunk_watch.py`，在 `0x10017f1dc`
（`rootB["main"]` 返回后）抓到 `mainChunk` 对象并动态装 8-byte
watchpoint 到 `mainChunk+0x60`。这轮还顺手修正了 LLDB
`watchpoint command add` 的参数顺序坑；当前 probe 安装过程已无额外
Python callback 噪音。

## 2. 当前 macOS failure run 里，`lookup2` 只活跃 1 次，而且就是 dashboard 已知的失败 wrapper

`build/hok-016c27-mainchunk-subtree-trace.json` 里唯一一条
`[hok016c27-lookup2]` 记录为：

- `pc = 0x1001ba82c`
- `x0(mainChunk) = 0x...`（tracked object）
- `x1(key)` 解码恒为 PascalString `"1"`
- `x30 = 0x1001bd588`（即 callsite = `0x1001bd584`，caller function =
  `0x1001bd464` / 当前失败链 wrapper）
- `mainChunk+0x60 = 0x0`

也就是说，这一轮 live run **没有**出现任何来自另外 6 个 `lookup2`
direct caller 的 runtime hit。

## 3. 从 `mainChunk` 出现到现有 failure sink，`mainChunk+0x60` watchpoint 仍 0 hit

失败窗口内我们持续看到：

- `[hok016c27-mainchunk]`：`subtree-wp=id1@mainChunk+0x60`
- `[hok016c27-lookup2]`：`tracked=true`、key = `"1"`、`mainChunk+0x60=0x0`
- `[hok016c27-post]`：`0x1001bd588` / `0x10017f29c` / `0x10432e074`
  三处返回值都延续为 0
- LLDB 最终仍停在既有 failure sink `0x108878124`，`watchpointHitCount = 0`

这把 C.2.6 的结论收紧成：**当前失败 run 里，`mainChunk` 出现之后直到
readiness-B fail，根本没有任何 runtime writer 试图填 `+0x60`。**

## 4. 离线 caller scan 给出了 `lookup2` / `bd448` / `rootbLookup` 的完整 static 面

`Scripts/hok016c27_ngr_mainchunk_callers.py` 产物
`build/hok-016c27-mainchunk-callers.json`：

- `0x1001ba82c`（`lookup2`）共有 **7** 个 direct caller function：
  `0x1001822a8`、`0x1001b9c68`、`0x1001ba50c`、`0x1001bc220`、
  `0x1001bd464`、`0x1001bdde4`、`0x1001becb0`
- `0x1001bd448` 仅 **1** 个 direct caller function：`0x10017f194`
- `0x1001ba50c` 是唯一带 **5** 个 shallow callers 的 `lookup2` wrapper，
  当前最值得继续反推
- 当前 run 唯一 live 命中的 `lookup2` caller 仍是 `0x1001bd464`

## 5. 这轮证据对主线的含义

到这一步可以排除"`mainChunk` 在 reporter failure window 内晚到写入"
这条路。Dashboard 的 HOK-016-C.2.7 分解条目据此改写：

- 静态 / live 结合反推 `0x1001ba50c` 与它的 5 个 shallow callers；
- 拆 `0x1001bd464 → 0x1001ba50c → 0x1001a5014` 这条 miss 后 fallback
  builder / post-builder contract；
- 对另外 6 个未在当前 run 活跃的 `lookup2` direct caller 做按需 probe；
- 只有当这些路径都证明"注册逻辑过深、返回对象形状又无法安全伪造"时，
  Dashboard 才考虑进入 C.4 诊断性强制成功方案。

## 6. 当前 run 并不是止步于 `lookup2` miss，而是继续走到 `ba50c` fallback builder，但仍在 `0x1001a5014` 后归零

在 `0x1001bd464` 里追加 probe 后，当前 run 观察到：

- `0x1001ba50c` **确实被调用**，且 `tracked=true`
- 其入参是 `(mainChunk, "../../../NGR/Content/Paks/1", "1", 0, 1)`
- `0x1001ba50c` **返回非零对象**（`x0 = 0x...`）
- 但 `0x1001bd888` 处（`bl 0x1001a5014` 返回后）实测 `x0 = 0`
- 此时 builder 返回对象 `x27` 与新分配对象 `x24` 的 `+0x60` 都仍为 `0`

这意味着：

- `lookup2` miss 后的 fallback builder **不是完全失效**；它能构造出
  一份非零对象
- 真正把这条 fallback 路径继续压成失败的，是后续 `0x1001a5014` 的
  校验 / 组装阶段
- 因而 C.5 的最小 shim 目标不应再停留在"让 `lookup2` 返回非零"或
  "单独调 `ba50c`"，而应改成：**让 `ba50c` 返回对象进入
  `0x1001a5014` 时具备足够的下游契约，或直接复用一份已满足该契约
  的现成对象**

## 7. `0x1001a5014` 进一步给出了 `+0x60` 的真实传播方向

反汇编 `0x1001a5014` 后可见：

- 它会把 `x1` / `x2` 两个字符串参数分别写进新对象 `x21+0x20` /
  `x21+0x30`
- 它会调用一组下游 helper / vtable method；只有这些后半段检查成功时，
  才会执行：

  - `stp w23, w23, [x21, #0x48]`
  - `str x22, [x21, #0x60]`
  - `str w20, [x21, #0x50]`（带上限修正）

- 在 `0x1001bd464` 调用点里，`x22` 正是 `x27+0x60`（即 `ba50c`
  fallback object 的 `+0x60` 字段）

因而当前 run 的失败更精确地说是：**`ba50c` 虽然返回了非零对象，但这
份 builder object 的 `+0x60` 仍为空，导致 `0x1001a5014` 既拿不到要
传播的 `x22`，也拿不到后半段所需的 success bit。**

## 8. 当前 run 既不是 path precheck fail，也不是 open-db fail，真正死在 storage create-table

在现有 `Scripts/hok016c27_ngr_mainchunk_subtree_trace.py` /
`Scripts/hok016c27_lldb_mainchunk_watch.py` 上继续加 probe 后，最新
run 观察到：

- `0x1001a50ec`（`0x1016b91c0` 返回后那个 `tbz w0` 分支点）**0 hit**。
  当前 run 直接从 `0x1001a50d4 tbnz w0` 走 fast-path 到 `0x1001a50f0`，
  即 `a5014` 的 path precheck 已通过，不是当前失败源。
- `0x1001a5114` 处实测 `x0(db)=3`、`*dbErr=0`；随后 `newObj+0xa8`
  变成非零，说明 `0x10012b2a4` open-db 已成功，失败也**不是** db-handle
  这一层。
- `0x1001a522c` 处实测：`newObj+0xb0` 已挂上非零 storage 对象，storage
  vtable `slot+0x18` 归一化后是 `0x1001b3d0c`；但该调用返回 `w0=0`，
  所以 `0x1001a5230..0x1001a524c` 那组 success path 赋值
  （`stp w23,w23,[x21,#0x48]` / `str x22,[x21,#0x60]` /
  `str w20,[x21,#0x50]`）根本不会执行。
- 对 `0x1001b3d0c` / `0x1001b3d7c` 的静态反汇编可见：storage slot
  `+0x18` 先调用 `0x1001b3d7c`，其内部在 `0x1001b3df0` 调
  `0x10012bb7c`，并把返回值写到 `storage+0x18`。`0x1001b3df4` live
  probe 直接读到：`x0(table)=0`、`storage+0x30 = 0x9000b`，随后
  `0x1001b3ecc cset w0, ne` 把整条 storage method 压成 failure。

当前 active failure 链：

```text
ba50c fallback object exists
  → a5014 path precheck passes
  → a5014 open-db succeeds (db handle = 3, err = 0)
  → a5014 creates storage object (newObj+0xb0)
  → storage.vtable[0x18] = 0x1001b3d0c
  → 0x1001b3d7c calls 0x10012bb7c
  → 0x10012bb7c returns null table, storage+0x30 = 0x9000b
  → storage method returns 0
  → a5014 returns 0
  → bd464 / f184 / dd98 continue returning 0
```

因而 create-table 的失败并不发生在 `0x1001a5014` 外层校验，而是发
生在更深一层：`0x10012bb7c` 为什么在 key=`"1"` 时返回 null table、
`0x9000b` 代表缺了哪一个前置契约。Dashboard 会把这一层抽象成 C.5
应该模拟什么（`mainChunk+0x60` 子树本身 / storage 对象的建表前置状
态 / 更深一层 registrar / schema 初始化）。

## 9. C.4 诊断性双 checkpoint 已证明：old gate 能被顶开，并且 dormant writer path 会真的写 `mainChunk+0x60`

新增 `Scripts/hok016c4_ngr_force_storage_success.py` 后，连续做了三
轮实验：

### 9.a storage-only force

仅在 `0x1001a522c` 把 storage method return 强制为 1。结果：`a5014`
确实返回 1，`newObj` 的 `+0x48/+0x50` 被填上，但 `0x10017f184` /
`0x10432dd98` 仍返回 0，说明"只让 storage create success"还不够。

### 9.b storage + ready dual force（带 watchpoint）

在 storage force 的基础上，再在 `0x1001a6958` 把 `0x1001a6830` 内
SaveHeader / ready result 强制为 1。这轮里 `0x1001bd960`、
`0x10017f29c`、`0x10432e074` 都已实测 `x0 = 1`，old readiness-B
gate 被真正顶开；同一 run 里 `mainChunk+0x60` watchpoint 首次在
`0x1001c6e74` 之后触发，LLDB 停在 `0x1001c6e78`。backtrace 显示
真 writer path 是：

```text
0x10432dfdc
  -> 0x10017f3c8
  -> 0x1001bc220
  -> 0x1001bc970
  -> 0x1001c6da4
  -> 0x1001c6e74 writes mainChunk+0x60
```

这条链恰好落在 C.2.7 静态 caller scan 里原先**未在 natural run 活跃**
的 `lookup2` direct caller `0x1001bc220` 上。

### 9.c storage + ready dual force（无 watchpoint）

为了避免 probe 自己拦停进程，再跑了一轮
`--skip-mainchunk-watchpoint`。结果表明：虽然当前这轮
`0x10432dd98 -> 0x10017f184` 已被推成 success，但进程后续仍会重新
回落到旧 failure sink `0x108878124` 并 disconnect。说明双 checkpoint
足以暴露真 writer path，却**仍不足以**直接达到稳定启动。

### 对主线的含义

- `mainChunk+0x60` 的 writer 已不再是假设，而是已经拿到真实 dynamic
  chain；
- natural run 缺的不是 "根本不存在 writer"，而是 **没有满足这条
  dormant writer path 的一项或多项 gating condition**；
- 因此 Dashboard 把 C.2.7 的焦点从"盲猜 `+0x60` 应该长什么样"改成
  "解释为什么只有在 storage success + ready bit 都被强推后
  `0x10432dfdc → 0x10017f3c8 → 0x1001bc220 → 0x1001bc970 →
  0x1001c6da4` 才会活过来，以及 natural run 里到底缺了哪个
  prerequisite"。

## 10. writer 命中已经从"停在 watchpoint"升级成"拿到真实 tracked-dst 写入"，而且 writer 后还有第二次 `f3c8` 回落

在 `Scripts/hok016c4_ngr_force_storage_success.py --force-ready-to-use
--skip-mainchunk-watchpoint --trace-dormant-writer` 这轮结构化 run 里：

### 10.a `0x1001c6e78` callback 抓到 tracked writer

`0x1001c6e78` callback 直接打印：`x23(dst) = tracked mainChunk+0x60`，
`trackedDst=true`；同一命中还读到 `dstBefore = 0x125d95d20`，并在
helper 的 tracked-chunk extra 中同步看到 `mainChunk+0x60 =
0x125d95d20`。这说明 dormant path 已经不是"疑似附近写入"，而是
**真的把当前 tracked mainChunk 的 subtree root 挂上了非零对象**
——但这里的"真的"仍限定在 dual-force 诊断条件下。

写入对象 `x22(src)` 的首 0x40 bytes 也被抓下来：里面能看到
`0x12603ae60`（即 tracked `mainChunk+0x60` 自身）以及若干状态位，说
明这份 writer object 至少已经带了与目标 subtree root 绑定的内部指针
/ metadata。

### 10.b 第二次 `f3c8` 回落：sibling branch 的暴露

同一 run 还抓到一条新的后续事实：`0x10432dfdc` 那次 `f3c8` 成功之后，
在更早的 sibling branch `0x10432def0..0x10432df30` 里，`0x10017f3c8`
会被**再次**调用（`LR = 0x10432df30`），而那第二次命中返回
`x0 = 0`。继续加 `0x10017faa0` 的 return probe 后，又能看到：

- 第一轮 `0x10432dfbc -> 0x10017faa0` 的 return site `0x10017fb44`
  在真正 `mov x0, x19` 之前，`x19 = 0`；
- 第二轮 `0x10432df10 -> 0x10017faa0` 的 return site `0x10017fb44`
  同样是 `x19 = 0`；

再往里加 `0x1001be550` 的 probe 后，又能把这两次失败拆成不同形状。
结合 `0x1001be61c` 的静态语义（成功时返回树节点 `+0x30` 上挂着的
entry/payload object，而不是树 node 本体），当前动态结果应理解成：

- **第一轮**（`flag=0`）时，`0x1001be584` 处 `x0=0`。也就是 writer
  path 触发前，`mainChunk+0x60` subtree 里**连目标 entry/payload
  object 都不存在**；
- **第二轮**（`flag=1`）时，`0x1001be584` 处已经能拿到非零 override
  object；但新增的 stage-correlation probe
  （`build/hok-016c4-force-storage-ready-stage-correlation.json`）证明：
  **"首轮 `0x1001a53a0(..., 1)` 失败"与"`bb73c(..., 0)` 产出 hollow
  wrapper"并不是同一条直线控制流，而是同一轮 dual-force run 里的两
  个 sibling branch**。

### 10.c sibling branch 关键证据

- `0x1001bae8c` 这次首轮 `bl 0x1001a53a0(..., w3=1)` 的 return site，
  来自 `LR = 0x10432df30` 这支 sibling branch；它虽然看到 `ctx+0x40`
  已经是 nonzero candidate，但在 `0x1001a53dc` 内部的第一个 gate
  `0x1001a55b8`（`bl 0x1001a588c` 返回后）就已经观测到 `w0 = 0`，且
  没有同分支的 `0x1001a55c8` 命中。这说明首轮失败的具体位置不是泛
  化的"override contract 不闭合"，而是 **`0x1001a588c` /
  OpenNodeStorage 这一级直接返回 0**；静态 failure 文案
  `0x1001a5730` 也对应 `"QtsfPackage OpenNodeStorage failed!
  package=%s"`。
- `0x1001bb73c(..., 0)` 则来自另一支 `LR = 0x10432dfdc`。这支里真正
  被调用的是 `0x1001baf80` 处的 **第二轮** `0x1001a53a0(..., w3=0)`；
  它在 `0x1001a55b8` / `0x1001a55c8` 两个 gate 上都实测 `w0 = 1`，
  并在 `0x1001baf84` 返回 `w0 = 1`。也就是说，`w3=0` 这轮 package
  load 本身**成功**。
- 紧接着 `0x1001bafa8` 处直接读到 `ctx+0x38 = 0`；而新增的
  `build/hok-016c4-force-storage-ready-context-init.json` 进一步把
  这个 producer 锁定到上游 `0x1001ba720` context-builder：
  - 在 `LR = 0x10432df30` 这支里，`0x1001ba7a8` 的 lookup return 是
    nonzero `0x120eb04f0`，随后 `0x1001ba7c0` 直接观测到
    `ctx+0x38 = 0x120eb04f0`；
  - 在 `LR = 0x10432dfdc` 这支里，同一个 `0x1001ba7a8` lookup return
    变成 `0`，`0x1001ba7c0` 也随之把 `ctx+0x38` 初始化成 `0`。

  再结合对 `0x1001ba940..0x1001bb120` 的静态反汇编筛选——`ba940` 一
  带对 `[x19,#0x38]` 只有多处 `ldr`、**没有任何 `str` 写入**——可以
  确认：`bb73c(..., 0)` 被选中，不是因为"首轮 `a53a0(..., 1)` 失败
  后直接跌落到这里"，而是因为当前这支路径在进入 `ba940` 之前，
  `ba720(key="1")` 自己就已经把 `ctx+0x38` 初始化成了 0。
- `0x1001bafbc` 的静态反汇编同时坐实：传给 `0x1001bb73c` 的 `w3 = 0`
  是函数内的硬编码 `mov w3, #0`，而 `0x1001bb73c` 自身在
  `0x1001bb798` 对 `w22/x3` 做 `cbz`；当 `x3 == 0` 时直接跳过
  `0x1001bc970` 的 child / payload 路径。
- `0x1001bafc4` 处 `bb73c` 返回对象已经是 hollow wrapper 形状：首
  qword 与第二 qword 都还是 `0`，`+0x48 = 0`、`+0x50 = 0xffffffff`；
  随后 `0x1001bb844` 的静态反汇编 + live probe 进一步证实：它只做
  `str x19, [x20]`，也就是把 final entry 回写到 wrapper 首 qword 里
  形成 backref；**不会** 补 child / payload。`0x1001bb014` 处
  `str x22, [x8, #0x8]` 确实执行，final entry 的 `slot1` 也确实从
  `0` 变成了这份 wrapper。

### 10.d 新 sequence

把这些证据合起来，当前口径应修正为：**dual-force run 里至少有两支
sibling path**——一支在 `0x10432df30` 上把 `0x1001a53a0(..., 1)` 卡
死在 `0x1001a588c` / OpenNodeStorage gate；另一支在 `0x10432dfdc`
上让 `0x1001a53a0(..., 0)` 顺利通过，但因为上游 `ba720(key="1")`
lookup 自己就返回 0、把 `ctx+0x38` 初始化成了 0，于是被迫走硬编码
`w3=0` 的 `bb73c` 路径，最终把 `backref-to-entry + null-child` 的
hollow wrapper 写进 `slot1`；`0x1001be550(flag=1)` 看到它时自然继续
把 return 压回 `0`。

```text
dual-force pushes first writer branch alive
  -> first 0x10017faa0 still returns 0, so sibling branch A reaches 0x10432df30
  -> branch A calls ba940 first-stage 0x1001a53a0(..., 1)
  -> inside 0x1001a53dc, gate#1 (0x1001a588c / OpenNodeStorage) already returns 0
  -> branch A returns 0 without producing a usable override object
  -> sibling branch B at 0x10432dfdc activates the dormant writer path and writes tracked mainChunk+0x60
  -> branch B enters ba940 second-stage 0x1001a53a0(..., 0)
  -> gate#1 + gate#2 both return 1, so second-stage package load itself succeeds
  -> ba940 then reads ctx+0x38 and still gets 0
  -> code executes hardcoded 0x1001bb73c(..., "1", 1, 0)
  -> because x3 == 0, bb73c skips 0x1001bc970 and returns a hollow wrapper
  -> 0x1001bb844 only patches entry backref into that wrapper
  -> ba940 finally writes entry.slot1 = hollowWrapper
  -> second 0x10017faa0 / 0x1001be550(flag=1) reads that same wrapper
  -> second gate still returns 0
  -> sibling branch later calls 0x10017f3c8 again and the process eventually falls back to the old readiness-B sink
```

### 11. `ba720` 的 branch 差异现在已经收紧到 `mainChunk+0x60` 是否已挂上 subtree root

新增 `build/hok-016c4-force-storage-ready-open-node.json` 后，`ba720`
这条线又缩小了一步：

- `LR = 0x10432dfdc` 这支里，`[hok016c27-ba720-lookup]` 读到：
  - `lookupRet = 0`
  - `ctx[0] = 0x1158e9920`
  - `ctx+0x18 = 0x13480ce00`
  - `ctx0raw = 68 dc 80 0c 01 00 00 00 05 00 00 00 ... 6d 61 69 6e ...`
  - `ctx18raw = a8 e4 80 0c 01 00 00 00 ... 58 54 55 4d ...`
  - key 恒为 PascalString `"1"`
  - **调用当下 `mainChunk+0x60 = 0`**
- `LR = 0x10432df30` 这支里，同一个 `ba720(key="1")` 读到：
  - `lookupRet = 0x130c66d20`（nonzero）
  - `ctx[0]` / `ctx+0x18` / `ctx0raw` / `ctx18raw` / key 与上面那支保持一致
  - **但此时 `mainChunk+0x60 = 0x132f4dcd0` 已经非零**

这说明：**`ba720` miss 不再像是“ctx producer 自己构造错了另一份 header”**；
目前可见的分水岭是 **调用 `ba720` 时 subtree root 是否已经挂进
`mainChunk+0x60`**。也就是说，问题 (b) 的表述需要收紧成：

- 为什么 `0x10432dfdc` 这支总是在 `mainChunk+0x60` 仍为 0 时先触发
  `ba720(key="1")`，从而让 lookup 返回 0、把 `ctx+0x38` 初始化成 0；
- 为什么要到后续 sibling / dormant writer path 跑起来之后，同一个
  `ba720` 才会在 `0x10432df30` 这支里看到 nonzero subtree root，进而
  返回 nonzero 并把 `ctx+0x38` 真正填起来。

再跑一轮 `build/hok-016c4-force-storage-ready-open-node-v2.json` 后，
`0x1001a588c` / `0x1001a5730` 的 direct probe 已真正命中，branch A 的
entry-side 证据也补齐了：

- **success 对照 1**：`pkg+0xa8 = 2`、`pkg+0x110 = 1`，`mainChunk+0x60 = 0`；
  `0x1001a588c` 入口命中后，`0x1001a55b8` / `0x1001a55c8` 两个 gate 都读到
  `w0 = 1`。
- **success 对照 2**（`LR = 0x10432dfdc`）：`pkg+0xa8 = 2`、`pkg+0x110 = 3`，
  `mainChunk+0x60 = 0`；同样 gate1 / gate2 都返回 1。
- **fail 的 branch A**（`LR = 0x10432df30`）：`pkg+0xa8 = 3`、`pkg+0x110 = 5`，
  且此时 `mainChunk+0x60` 已经非零；但 `0x1001a588c` 刚返回，
  `0x1001a55b8` 就直接观测到 `w0 = 0`，随后 `0x1001a5730`
  `QtsfPackage OpenNodeStorage failed! package=%s` 分支被直接命中。

这把 branch A 的口径从“只看 return-site 推断 package state 差异”升级成了：
**`0x10432df30` 这支确实在 entry-side 带着 `pkg+0xa8 = 3 / pkg+0x110 = 5`
进入 `0x1001a588c`，并在 gate1 立刻失败；问题更像是 package / storage
state 尚未就绪，而不是 key / candidate materialization 自身有误。**

这把主线目标进一步改写为两层（Dashboard 会据此更新问题 (a)(b)）：

1. 解释 **为什么 `0x10432df30` 这支里的首轮 `0x1001a53a0(..., 1)`
   会在 `0x1001a588c` / OpenNodeStorage gate 上返回 0，以及为什么
   `0x10432dfdc` 这支会在 `mainChunk+0x60` 仍为 0 的时刻先触发
   `ba720(key="1")`**；
2. 继续收紧 natural run 为什么过不了 `storage success + ready` 以及
   更高层 mount / registrar state 这组一项或多项 prerequisite。

### 12. natural run 的 `0x10012bb7c` 入口实参现在也有了：它看到的是 descriptor/blob contract，不是简单 key `"1"`

新增 `build/hok-016c27-mainchunk-subtree-storage-v3.json` 后，natural run
的 storage 深 probe 进一步把 `0x10012bb7c` 入口实参钉死：

- `0x1001b3d0c` storage method 入口实测：
  `x0(storage)=0x12d03cfb0`、`x1=0x12d03c728`、`x2=0x2710`；此时
  `storage+0x18 = 0`、`storage+0x30 = 0`、`storage+0x3c = 0`。
- 到 `0x1001b3df0` call site 时，`x1 == x20 == 0x12d03c728`，其 raw bytes 为
  `31 00 00 00 00 00 00 00 01 01 00 00 ...`；也就是说它更像一份
  **49-byte descriptor**，不是前面 `ba720` / `lookup2` 那种简单 PascalString
  `"1"`。
- 同一 call site 的 `x2 = 0x170b819b8`，其 raw bytes 以 `0x2710` 开头，后面还跟着
  指针 / 长度字段；它更像一份与 descriptor 配套的 **companion blob**。
- `0x10012bb7c` entry 收到的就是这组 `(x0, x1/x20, x2, x4)` 组合；helper 返回后，
  `0x1001b3df4` 立刻观测到 `x0(table)=0`，随后 `storage+0x30` 才被写成
  `0x9000b`。

这说明：**到 `0x10012bb7c` 这一层，问题已经不应再表述成“key=`"1"` 查不到表”**，
而更像是“create-table helper 拿到的 descriptor/blob contract 缺了一项或多项前置状态”，
所以 helper 返回 null table，并把错误码落到 `0x9000b`。

## 13. `0x10012bb7c` 的第一层 descriptor/blob gate 已通过；natural run 失败后移到 entry-build 之后的 final-check

这轮先用 `build/hok-016c27-create-table-impl-static.txt` /
`build/hok-016c27-create-table-impl-static-tail.txt` 把 `0x10012bb7c` 的真实静态骨架拉了出来，再用
`build/hok-016c27-mainchunk-subtree-trace-v3.json` 对应地址做 natural-run live probe。

### 13.a 静态收紧：`0x10012bb7c` 只是薄 wrapper，真实实现是 `0x100124e80`

- `0x10012bb7c` 本身并不是普通 prologue，而是：
  - `str wzr, [x4]`：先把 caller 传进来的 error slot 清零；
  - `b 0x100124e80`：直接跳进真正的 helper 实现体。
- 这意味着 natural run 里看到的 `storage+0x30 = 0x9000b` **不是** wrapper 自己的参数校验产物，而是更深层 helper 后半段写出来的状态。
- `0x100124e80` 里最早的一层关键 gate 是 `0x10012502c -> bl 0x100135d80`，其入参带着：
  - 规范化后的 descriptor；
  - `x2 = sp+0x30` 的临时 out slot；
  - `x3 = errSlot`。

### 13.b live 结果 1：`0x100135d80(..., errSlot)` 这层 gate 在 natural run **返回 1**

`[hok016c27-create-table-gate-call]` / `[...-gate-ret]` 直接给出：

- 调 gate 前 `errBefore = 0`；
- gate 返回点 `0x100125030` 上 `w0 = 1`；
- 同时 `errAfter = 0`；
- transcript 里还能看到 descriptor/blob raw bytes 与前一节记录的 49-byte descriptor + companion blob 一致。

所以：**descriptor/blob contract 的第一层 gate 已经通过，不是当前 null table 的直接来源。**

### 13.c live 结果 2：natural run 会走进 `0x10012581c` 的 entry-build branch，而且没有命中 `err=9`

`[hok016c27-create-table-entry-build]` 证明 natural run 确实命中了 `0x10012581c`，且现场是：

- `node+0x48 = 0`
- `node+0x50 = 0`

对照静态分支：这是从 `0x100125318 cmp w8,#1; 0x100125320 b.lt 0x10012581c` 过来的，
意味着 helper 进入的是“先补 entry / container”的那条路径，而不是直接走
`0x100125324..330` 的 `err=9` 写点。实际 live transcript 里也**没有任何**
`[hok016c27-create-table-err9]` 命中。

这又把自然路径进一步收紧成：**当前失败既不是第一层 gate fail，也不是 `err=9` 这条显式错误码路径。**

### 13.d 阶段性结果 3：`0x100125960` 只是消费已写好的 `0x9000b`；更深层写点在当时先收紧到 `0x100122f98`

新增 `build/hok-016c27-final-check-errslot-watch.json` 后，这条线又向下收紧了一步：

- `[hok016c27-create-table-gate-ret]` 显示：在 `0x100125030` 时，第一层
  `0x100135d80(..., errSlot)` gate 仍保持 `w0 = 1`、`errAfter = 0`；同时
  动态把 err slot watchpoint 装到了 `0x6000013bbeb0`。
- watchpoint 的第一次后续写入直接命中
  `[hok016c27-err-slot-write] pc=0x100122f98 value=0x9000b`；其回溯是
  `0x100122f98 <- 0x1001142a4 <- 0x100114994 <- 0x100125960 <- 0x1001b3df4 <- ...`。
  这说明把 error slot 推成 `0x9000b` 的**直接写点**并不在
  `0x100125960` 自己，也不在 `0x100125984` 之后的 cleanup，而是位于
  `0x10012595c -> 0x1001148b8` 更深层的 callee 链里。
- 等控制流回到 `[hok016c27-create-table-final-check]` 时，`w0 = 0`、
  `errSlot = 0x9000b` 已经成立；随后 `0x1001259c4` 保持
  `x22(ret)=0` / `errSlot=0x9000b`，最终把 null table 返还给 storage method。

换句话说，**natural run 的 create-table 失败已不应再描述成“final-check 自己把 error slot 推成 `0x9000b`”**；更准确的表述是：helper 通过了前半 descriptor/blob gate，也进入了 entry-build，但在 `0x10012595c` 之后更深层的校验 / helper 链里，`0x100122f98` 先把 err slot 写成 `0x9000b`，`0x100125960` 只是消费这份已形成的错误状态并把返回值压回 0。

### 13.e 这轮结果对主线的含义

这轮结果把 create-table 失败的表述从"`0x100125960` final-check 自己
失败"修正成更深一层：

- 这对 descriptor/blob 至少能通过 `0x100135d80(..., errSlot)` 的
  **第一层** gate；
- 当前缺的前置条件从泛化的"`0x10012581c → 0x100125960` 后半 helper"
  收紧成 `0x10012595c → 0x1001148b8 → 0x100114994 → 0x1001142a4 →
  0x100122f98` 这条更深层 callee 链；
- **注意：以上仍是阶段性收紧，不是当前最终口径。** 第 14 节的
  materialization trace 会继续把这条线从“解释 `0x100122f98` 为什么命中”
  改写成“解释 `0x100122f54` 的 materialization vcall 为什么在 failing
  helper state 上直接返回 0”。

## 14. deep err-slot probe 继续把 create-table failure 收紧成 “`0x100122f54` materialization vcall 返 0 → `x21/helper+0x18` 被一起压空”

先前的 `build/hok-016c27-deep-err-chain.json` 已经把问题 (c) 收紧到：
`0x10012595c` 会把 caller err slot 作为 `x3` 传入 `0x1001148b8`，真正写
`0x9000b` 的是 `0x100122f94 str w8, [x20]`，而 `0x100122f98` 只是后面的
post-store compare。新增 `build/hok-016c27-materialize-trace.json` 后，这条线
又向前推进了一层：

- `0x100122f20..0x100122f9c` 的静态骨架现已明确：

  ```text
  0x100122f20 mov x20, x3        ; errSlot
  0x100122f24 mov x21, x2        ; incoming materialization arg
  0x100122f28 mov x22, x1
  0x100122f2c mov x19, x0        ; helper object
  0x100122f30..0x100122f38 blr x8
  0x100122f3c..0x100122f54 blr x8 ; vcall(x22, x21)
  0x100122f58 mov x21, x0
  0x100122f5c str x0, [x19, #0x18]
  0x100122f60 cbz x0, 0x100122f84 ; null -> err provider
  0x100122f64..0x100122f78 blr x8 ; non-null -> success-side second vcall
  0x100122f80 b 0x100122f98       ; success path 也会汇合到 0x100122f98
  0x100122f84..0x100122f94        ; err=9 provider + errSlot store
  0x100122f98 cmp x21, #0
  ```

- 这意味着：**`0x100122f98` 不是纯错误路径断点，而是 success / fail 两支的
  join point**。新的 live trace 共命中 8 组 materialization 事件：
  - 7 组 `materializeReturnedNull=false` / `willTakeErrProvider=false`，对应
    `0x100122f98` 上 `x30 = 0x100122f7c` 的 success-side 汇合；
  - 仅 1 组 `materializeReturnedNull=true` / `willTakeErrProvider=true`，对应
    `0x100122f98` 上 `x30 = 0x100122f88` 的真实 err-provider 路径。

- 真实 failing hit 的连续现场现在已经闭合：
  - `0x100122f20` entry：`x20 = errSlot`、`x21 = x2 = 0x10aa4678c`、
    `x22 = x1 = 0x600003c1b390`、`x19 = helper = 0x600001039140`，此时
    `helper+0x18 = 0`；
  - `0x100122f58` return：第二个 vtable call（`0x100122f54 blr x8`）
    **直接返回 `x0 = 0`**，而不是先成功 materialize 再被后续逻辑清空；
  - `0x100122f60` result：`mov x21, x0` + `str x0, [x19,#0x18]` 之后，
    `x21 = 0`、`helper+0x18 = 0`，于是 `cbz x0` 直接落入 `0x100122f84..94`；
  - `0x100122f98` fail-side hit：`x30 = 0x100122f88`、`x0raw` 首 word = `9`、
    `errWatch = 0x600003159fb0`、`errValue = 0x9000b`，与
    `(9 << 16) | 0xb` 完全对齐。

- 因而此前“`x21` 在 `0x100122f84` 前被某段未知逻辑压成 0”这句口径需要修正：
  **`x21` 只是 `0x100122f54` 这次 materialization vcall 返回值的镜像；真正要解释的
  已经不是 post-store compare，而是为什么该 vcall 在 failing hit 上直接返回 0，
  并让 `helper+0x18` 继续保持空。**

- 这轮同时也给出一个新的解读纪律：以后看 `0x100122f98` 时，必须同时看
  `x30` 来区分路径——`0x100122f7c` 表示 success-side 汇合，`0x100122f88`
  才表示真正走过 `err=9` provider。

换句话说，当前未闭合的前置条件已不再是“`0x100122f98` 为什么看到 `x21=0`”，
而是：**`0x100122f54` 这次 materialization vcall 在 failing helper state
（`helper+0x10 = 0x3200080a0`、`helper+0x18 = 0`）下，为什么会返回 0。**
只要这个返回值继续为 0，`0x100122f58/0x100122f5c` 就会稳定把 `x21` 与
`helper+0x18` 一起压空，随后 `0x100122f94` 继续把 create-table 压回 null table。
