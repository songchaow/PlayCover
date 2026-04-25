# HOK-016：消除 `com.tencent.ngr` 启动期 `QtsFileSystem Create Failed!!` 僵尸态

> 本文只沉淀 HOK-016 的**目的、核心静态 / LLDB 证据、当前根因链骨架、
> 修复方向、已证伪路径**。任务状态以 `00-Dashboard.md` 为准；本文不出现
> "DONE / TODO / 已落地 / 下一步" 等字样，也不写日期快照。
>
> **阅读建议**：做 HOK-016-C 系列任何子任务前总是读取；Dashboard 引用
> 到本文时也总是读取。日常非 HOK-016 工作不必展开。
>
> **子文档索引（都标注了"何时读"）**：
>
> - `HOK-016-appendix-tooling.md`：所有 `Scripts/hok016*` 脚本说明 +
>   LLDB BP / watchpoint callback 踩坑。**阅读建议：需要跑 / 新增
>   HOK-016 系列脚本或复用 Python probe helper 时读。**
> - `HOK-016-appendix-C23-C24.md`：`0x10432dd98` step-into + 真失败决
>   定点 `0x10017f184` 下钻。**阅读建议：需要复核 readiness B 内部控
>   制流、或理解 `0x10017f3c8` 为什么是死代码时读。**
> - `HOK-016-appendix-C25-C26.md`：rootB writer watchpoint + `mainChunk
>   -> "1"` 真缺口。**阅读建议：需要理解 rootB lazy-init、或判断某次
>   live run 里 reporter 插的第一个 key 是不是 `main` 时读。**
> - `HOK-016-appendix-C27.md`：HOK-016-C.2.7 的完整 live 证据（mainChunk
>   watchpoint / ba50c fallback / storage fail / dual-force / sibling
>   branch / hollow wrapper / err-slot / materialization trace）。**阅读建
>   议：做 HOK-016-C.2.7 / C.4 / C.5 任何 probe 或修复设计时总是读；只
>   想同步当前最新收紧口径时优先看其 §14。**
> - `HOK-016-appendix-CX.md`：seed 替换实验证伪详情。**阅读建议：需要
>   重跑 seed 实验、或怀疑 cmdline 会影响 QtsFS 时读。**

## 目的

HOK-013 + HOK-015 + HOK-010 + HOK-014 落地后，`com.tencent.ngr` 进程不
再秒崩，但 UE4 GameThread 并没有真正进入主循环：`%CPU` 峰值后迅速掉到
0.2% 以下、RSS 停在 ≈332MB、线程数 11、主窗口在屏幕外、`launch-events.jsonl`
仍稳定出现 1 条 `hok014_ngr_alert_suppressed title="Message"
message="QtsFileSystem Create Failed!!"`。

HOK-016 的目标是 **定位并消除** 这条 `QtsFileSystem Create Failed!!` 路
径的根因，让 `hok014_ngr_alert_suppressed` 归零、进程真正活着
（`%CPU ≥ 5%` 持续 ≥ 30s、`RSS ≥ 800MB`、线程 ≥ 20、主窗口与主屏有非
空交集）。Dashboard 定义的硬约束依旧：**bundle-scoped、PlayTools 层、
不动 NGR 二进制、失败时无副作用**。

## 核心证据（跨子任务一致）

### 字符串家族（HOK-016-A）

NGR 主 image `__TEXT,__ustring` 里 `QtsFileSystem` 前缀共 **3 条
UTF-16-LE TCHAR 字面量**，每一条都有 **恰好 1 条 ADRP+ADD xref**：

| value | 字符串 vmaddr | 唯一 xref |
|---|---|---|
| `QtsFileSystem init Failed!!`   | `0x10c09d00a` | `0x108879248` |
| `QtsFileSystem Create Failed!!` | `0x10c09d070` | `0x1088792d4` |
| `QtsFileSystem Create failed.`  | `0x10c09d0ac` | `0x10432f4b0` |

前两个 xref 同属 reporter 函数 `0x108879164`；第三条属独立函数
`0x10432f490`。

### reporter 函数 `0x108879164` 的关键分支

```
+144 bl  0x107c0ab8c                    ; w0 = "parse option 成功/失败"
+148 tbz w0, #0, +224                   ; w0==0 → "init Failed!!"
+172 mov x0, x19                        ; this
+176 bl  0x108877bd0                    ; w0 = "Create 成功/失败"
+180 tbz w0, #0, +364                   ; w0==0 → "Create Failed!!"
+224 adrp+add x1, 0x10c09d00a  → "init Failed!!"
+364 adrp+add x1, 0x10c09d070  → "Create Failed!!"
+420 bl  0x10432f490                    ; 第三条 "Create failed." 调用者
```

`0x108877bd0` 决定了 "Create Failed" 是否触发。

### 运行期 backtrace（HOK-016-B，跨 run 稳定）

```
frame #0: 0x108879164 NGR`reporter (QtsFS vtable[0x30])
frame #1: 0x103a29bec NGR`MeyersSingleton + 112
frame #2: 0x107e5df4c NGR`FactoryRegister + 60
frame #3: 0x103a29fa0 NGR`QtsFileSystem_Init + 832   ; writes 0x10e2146f8
frame #4: 0x107e5c970 NGR`QtsFS_InitWrapper + 12
frame #5: 0x103a227d0 NGR`MessagingInit + 44         ; FCommandLine::Get inline guard
frame #6: 0x104a04d38 NGR`NSThreadWorker + 164        ; 非主线程
frame #7: Foundation`__NSThread__start__
frame #8: libsystem_pthread.dylib`_pthread_start
```

reporter 命中时的寄存器（多次观察一致）：
`x2 = 0x10e20107a` = **HOK-015 preseeded `FCommandLine::CmdLine` 地址**。
即 reporter 把 cmdline 当 `%s` context 打印；**QtsFS 的失败不由 cmdline
内容决定**（已被 HOK-016-C.X 证伪实验再次坐实）。

### 与 HOK-013 的 slot writer 关系

frame 3 `0x103a29c60 +796` 的 `str x0, [x8, #0x6f8]` **正是 HOK-011 全
二进制扫描找到的唯一 writer**，目标 slot `0x10e2146f8`。当 NGR 走到
frame 3 这条路径时 HOK-013 预置的 stub 会被真 writer 覆盖；HOK-013 的
价值是在 frame 3 触发前防卫 early reader。HOK-015 让 frame 5 的
`FCommandLine::Get()` guard fall-through，这是 HOK-016 的必要前提。

## 已知真因判定（逐层收紧）

每一层的完整证据下沉到对应附录，这里只保留跨层骨干：

1. **C.X.1（证伪）**：换 HOK-015 seed value 不改变 `w0@+912`，
   `0x108878534` 返回 0 与 cmdline 内容无关。详见
   `HOK-016-appendix-CX.md`。
2. **C.1**：`0x108877bd0` 内部 `+900` 前 `w0=1`（readiness A ok）、
   `+912` 前 `w0=0`（readiness B fail）。`0x108878534` 是 readiness B
   dispatcher，函数实际范围 `0x108878534..0x1088786ec`（≈440 字节）。
3. **C.2.1 / C.2.2（证伪）**：sentinel `0x10e1eeef0` 运行期 = `0x05`，
   已满足 `cmp #0x4` / `cmp #0x2` 判定；全 `__text` 扫描 0 writer 命
   中。**sentinel 不是失败因**。
4. **C.2.3**：`0x108878534 +352 bl 0x10432dd98` 稳定被命中，且
   `0x10432dd98` 返回 0 → error path → `0x108878534` 返回 0。详见
   `HOK-016-appendix-C23-C24.md`。
5. **C.2.4**：真正的失败决定点是 `0x10017f184`，不是 `0x10017f3c8`
   （后者在当前 run **0 hit**，是死代码）。`0x10017f184` 做
   rootA→rootB 双层 lookup；运行期 rootB header 是空红黑树 sentinel
   自指。详见 `HOK-016-appendix-C23-C24.md`。
6. **C.2.5**：rootB writer 运行期 watchpoint 命中 2 次，位置在
   `0x1001cf020` 红黑树 insert，**发生在 reporter 内部** `0x108877bd0
   +692`（readiness B 之前）；rootB 是 lazy-init 模式。详见
   `HOK-016-appendix-C25-C26.md`。
7. **C.2.6**：reporter 实际插的第一个 key 就是 `"main"`；`rootB ->
   "main"` 第一层 lookup **已成功**。真正失败的是下一层：
   `0x1001bd448 +0x13c → 0x1001ba82c(mainChunk, "1")` 返回 0。
   `mainChunk+0x60` 是空壳，从对象出现到 readiness B fail 之间 **0
   hit**。详见 `HOK-016-appendix-C25-C26.md`。
8. **C.2.7**：natural run 经过 `ba50c` fallback builder → builder 返
   回非零对象 → `0x1001a5014` 内部 storage 创建失败（`0x10012bb7c`
   返回 null table，`storage+0x30 = 0x9000b`）→ storage method = 0 →
   a5014 = 0。C.4 dual-force（storage success + ready/save-header
   success）证明 dormant writer path
   `0x10432dfdc → 0x10017f3c8 → 0x1001bc220 → 0x1001bc970 →
   0x1001c6da4 → 0x1001c6e74` 会真实写 `mainChunk+0x60`；新增
   `build/hok-016c27-materialize-trace.json` 先把 create-table fail
   收紧成：failing helper state 下，`0x100122f54` 的 materialization
   vcall 直接返回 0。随后 `build/hok-016c27-materialize-vcall-trace-v3.json`
   证实：failing hit 与 2 次 success hit 共用同一个
   `x8(target)=0x10432a068`、同一个 `x0=0x10e16ded8` 与相同
   `helper_slot10raw`。最新一轮
   `build/hok-016c27-materialize-target-trace-v2.json`（与
   `build/hok-016c27-materialize-target-trace-v1.json` /
   `build/hok-016c27-materialize-target-trace-v1-recheck2.json` 一致）又把
   问题继续收紧成：这同一 target 在 success / fail 两边都共用
   `entry → post-helper1 → check1 → post-helper2 → check2 →
   0x10432a17c/0x10432a1c8` 这段前缀，而且在当前观测到的 success / fail
   hit 里，`branch-1c8` 之后的 post-`1c8` pair 已收敛为同一组
   `x21=0x10b248b8c`、`x22=0x10b308bee`；真正稳定分开的只剩 pre-`1c8`
   state：success tuple（`entryX2=0x10aa5264a`、
   `entryX1="../../../NGR/Content/Paks/1/1.db"`）在 `0x10432a10c` /
   `0x10432a17c` 呈现 `x22=0x21 → 0x3` 并继续进
   `0x10432a2c8/0x10432a2e0`，natural failing tuple
   （`entryX2=0x10aa4678c`、`entryX1="/Users/..."`）则呈现
   `x22=0x31 → 0x4` 并改走 `0x10432a224`，随后 caller 仍在
   `0x100122f58` 拿到 `x0=0` 并把空值回写到 `x21/helper+0x18`，再落入
   `err=9` provider 合成 `0x9000b`。本轮补的静态反汇编又把三处未闭合点
   再收紧一步：`0x1001ba720` 只是把 `lookup2(mainChunk, "1")` 的返回值直接
   快照进 `ctx+0x38`；`0x1001a588c` 的下一跳缺口落到 `pkg+0x10` 与
   `pkg+0xb0->0x30`；`0x10432a068` 在 `0x10432a224` 之后还会继续走
   `0x10432a238` compare ladder，并在 `0x10432a3e0/0x10432a580` 与
   `0x10432a2c8` 之间分流。`0x100122f98` 同时还是 success / fail 两支的
   join point，解读时必须用 `x30` 区分路径。详细寄存器与逐指令证据见
   `HOK-016-appendix-C27.md`。

### 当前根因链（骨架版）

```text
NSThread worker
 → MessagingInit → QtsFS_InitWrapper → QtsFileSystem_Init (writes 0x10e2146f8)
 → FactoryRegister → MeyersSingleton → reporter 0x108879164
 → reporter +176 bl 0x108877bd0
 → +688 先 insert "main" 到 rootB (lazy-init)
 → +908 bl 0x108878534 (readiness B)
 → +352 bl 0x10432dd98 (data-verify)
 → 经 Printf + cmp/vtable 分派，最终 bl 0x10017f184(x0=0)
   → rootA lookup 找到 entry ("main" / "1")
   → rootB["main"] lookup 成功，拿到 mainChunk
   → 0x1001bd448(mainChunk, "1", ...) → 0x1001ba82c(mainChunk, "1")
   → mainChunk+0x60 为 NULL → lookup 返 0
   → 0x1001bd464 进 fallback: 0x1001ba50c 返回非零 builder object
   → 0x1001a5014 内部 storage 创建: 0x10012bb7c 返回 null table
      (storage+0x30 = 0x9000b) → storage method = 0 → a5014 = 0
   → 0x10017f184 返回 0
 → 0x10432dd98 返回 0 → 0x108878534 返回 0
 → reporter +912 tbz w0,#0 → +364 "Create Failed!!" → UE_LOG + alert
 → frame 4 cbnz w0 → fatal tail-call → GameThread 退出，僵尸态
```

**dual-force 诊断（非 natural run）暴露的额外事实**：强推 storage
success + ready bit 后，`0x10432dfdc` 那支 sibling 会激活 dormant
writer path 真的把 tracked `mainChunk+0x60` 挂上非零 subtree root，但
`ctx+0x38=0` + hollow wrapper 使 second-gate 返回 0，进程仍回落到旧
failure sink。完整的 sibling branch / writer 对象字段 / `0x9000b`
direct-writer 调用链见 `HOK-016-appendix-C27.md`。

## 修复方向（HOK-016-C.2.7 之后的排序）

按"影响面从小到大 / 风险从低到高"排；必须在 PlayTools 层 bundle-scoped、
不动 NGR 二进制：

1. **C.2.7（当前主线）**：继续 live trace，聚焦回答三件事：
   - (a) 为什么 `0x10432df30` 这支首轮 `0x1001a53a0(..., 1)` 会在
     `0x1001a588c` / OpenNodeStorage gate 返回 0——具体是 `pkg+0x10`
     invalid mode 还是 `pkg+0xb0->0x30` 这层 nodeStorage errcode；
   - (b) 为什么 `0x10432dfdc` 这支会在 dormant writer 之前先触发
     `ba720(key="1")`；`ba720` 本体已经静态坐实为
     `lookup2(mainChunk, "1") -> ctx+0x38` 的直接快照，而不是 later overwrite；
   - (c) `0x10012595c → 0x1001148b8 → ... → 0x100122f20..0x100122f60`
     这条更深层 callee 链里，为什么**同一个** `0x100122f54`
     materializer target `0x10432a068` 在当前观测到的 natural / success
     run 里，已经在 `branch-1c8` 之后收敛到同一组 post-`1c8` pair
     （`x21=0x10b248b8c`、`x22=0x10b308bee`），却仍会因 pre-`1c8` 的
     entry tuple / helper state 差异——success 为
     `entryX2=0x10aa5264a`、`entryX1="../../../NGR/Content/Paks/1/1.db"`、
     `x22=0x21 → 0x3`，natural fail 为 `entryX2=0x10aa4678c`、
     `entryX1="/Users/..."`、`x22=0x31 → 0x4`——分别走向
     `0x10432a2c8/0x10432a2e0` 与 `0x10432a224`（以及其后尚未钉住的
     `0x10432a238 / 0x10432a3e0 / 0x10432a580` tail），并最终让 caller 在
     `0x100122f58` 收到 `x0=0`、再经 `mov x21,x0` /
     `str x0,[x19,#0x18]` 把 `x21/helper+0x18` 一起压空，写回 `0x9000b`。
2. **C.5**：若 C.2.7 能给出可重复的 child-registration API 签名或完
   整对象构造路径，PlayTools constructor 里按同样签名补齐。**最小侵
   入修法。**
3. **C.4**：若 C.2.7 证实注册路径过深、对象形状无法安全伪造，基于
   PlayTools 现有 bundle-scoped runtime hook / direct patch 基建做
   诊断性强制成功验证。
4. **C.3**：终极野蛮方案——fishhook interpose `0x108878534` 直接返回
   1，跳过整条 readiness B。稳定性风险极高，仅作最后兜底。
5. **C.6（降级）**：若必须依赖用户外部资源/登录态，才降级到 HOK-009
   方向。

## 已证伪路径（骨架）

- **(~~C.X~~) HOK-015 seed value 替换**：详见 `HOK-016-appendix-CX.md`。
- **(~~C.2.1 / C.2.2~~) sentinel `0x10e1eeef0` 未 bump 假设**：运行期
  实测 `= 0x05`；全 `__text` 扫描 0 writer。
- **(~~C.5 path fixup~~)**：rootB 的 lookup key 是内部 PascalString
  `"main"` / chunk 名 `"1"`，不是 FString 路径；进 `0x10017f184` 的
  x0 是 int(=0)；`0x10432dd98` 入口拿到的两个 FString 路径实际没被
  `0x1001ac168` / `0x1001cd114` 消费。
- **(~~"rootB 从头到尾是空"~~)**：C.2.5 watchpoint 实测 rootB 在
  reporter 运行期被 insert 2 次。
- **(~~"rootB 缺 main" / C.2.5 旧结论~~)**：C.2.6 实测 reporter 插
  的第一个 key 就是 `"main"`，真失败在 `mainChunk -> "1"`。

> 每条证伪的具体实验、寄存器值、脚本产物都在对应附录里。

落地前后的验证口径见 Dashboard "HOK-016-D 判据"
（`hok014_ngr_alert_suppressed = 0` / 进程活跃度 / 窗口可见性 / 无新
`NGR-*.ips`）。

## 参考

### 子文档

- `HOK-016-appendix-tooling.md`
- `HOK-016-appendix-C23-C24.md`
- `HOK-016-appendix-C25-C26.md`
- `HOK-016-appendix-C27.md`
- `HOK-016-appendix-CX.md`

每份附录顶部都有自己的"何时读"提示；文档顶部也有统一的索引。

### 相关前置文档

- `HOK-011-静态初始化链分析.md`：`0x10e2146f8` 唯一 writer 与反向
  BFS 方法论。**阅读建议：一般无需读取；需要对新 `__common` slot
  复用该扫描器 / 方法论时读。**
- `HOK-013-slot-preheat.md`：HOK-016 frame 3 触发前的 slot preheat。
  **阅读建议：修改 HOK-013 相关代码时读。**
- `HOK-014-alert-suppressor.md`：HOK-016 闭合前 HOK-014 仍承担"用户
  看不到 alert"的硬约束。**阅读建议：修改 HOK-014 / HOK-010 相关代
  码时读。**
- `HOK-015-cmdline-preseed.md`：HOK-016-B 的 x2 参数语义依赖 HOK-015
  的 preseed buffer。**阅读建议：修改 HOK-015 相关代码时读。**
