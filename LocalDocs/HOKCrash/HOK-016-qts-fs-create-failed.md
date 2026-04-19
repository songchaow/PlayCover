# HOK-016：消除 `com.tencent.ngr` 启动期 `QtsFileSystem Create Failed!!` 僵尸态

> 本文只沉淀 HOK-016 的**目的、核心静态/LLDB 证据（字符串家族 + reporter
> 调用链）、当前根因链（最终版）、修复方向、已证伪路径**。任务状态以
> `LocalDocs/HOKCrash/00-Dashboard.md` 为准；本文不出现 "DONE / TODO /
> 已落地 / 下一步" 等字样，也不写日期快照。
>
> **子文档下沉规则（避免主文档无限膨胀）**：
>
> - 运行期工具链 / 每个 `Scripts/hok016*` 脚本详细说明 / LLDB BP callback
>   踩坑 → `HOK-016-appendix-tooling.md`。
> - HOK-016-C.2.3 `0x10432dd98` step-into + C.2.4 `0x10017f184` 真失败
>   决定点下钻 → `HOK-016-appendix-C23-C24.md`。
> - HOK-016-C.2.5 rootB writer watchpoint live trace + C.2.6 `mainChunk
>   -> "1"` 二级子树缺口 → `HOK-016-appendix-C25-C26.md`。
> - HOK-016-C.2.7 的 10 步证据（mainChunk watchpoint / ba50c fallback /
>   storage fail / dual-force / sibling branch / hollow wrapper）→
>   `HOK-016-appendix-C27.md`。
> - HOK-016-C.X.1 seed 替换实验（证伪 "seed 驱动 QtsFS 失败"）→
>   `HOK-016-appendix-CX.md`。
>
> 主文档只维护当前**跨子任务一致的骨干证据**；要看具体某轮证据 / 寄存
> 器快照 / 数十 BP 的 callback 结构，按上面的"何时读"指引进入对应附录。

## 目的

HOK-015 `FCommandLine` preseed 落地（`bInitializedAfter=1` /
`cmdlinePreview="../../../NGR/NGR.uproject"` / `slide=0x44f0000`，`launch-events.jsonl`
已稳定观测 `hok015_ngr_cmdline_preseed status=primed`）之后，
`com.tencent.ngr` 进程不再秒崩，但 **UE4 GameThread 并没有真正进入主循
环**：`%CPU` 峰值到 ~59% 之后迅速掉到 0.2% 以下、RSS 停在 ≈332MB、线程
数 11、主窗口在屏幕外、`launch-events.jsonl` 仍稳定出现 1 条
`hok014_ngr_alert_suppressed title="Message" message="QtsFileSystem Create Failed!!"`。

HOK-016 的目标是 **定位并消除** 这条 `QtsFileSystem Create Failed!!` 路径
的根因，让 `hok014_ngr_alert_suppressed` 事件归零、进程真正活着（
`%CPU ≥ 5%` 持续 ≥ 30s、RSS ≥ 800MB、线程 ≥ 20、主窗口与主屏有非空交集）。
Dashboard 定义的硬约束依旧：**bundle-scoped、PlayTools 层、不动 NGR 二
进制、失败时无副作用**。

## 核心证据（跨子任务一致）

### 字符串家族（HOK-016-A）

NGR 主 image `__TEXT,__ustring` 里 `QtsFileSystem` 前缀共 **3 条
UTF-16-LE TCHAR 字面量**，每一条都有 **恰好 1 条 ADRP+ADD xref**：

| value | 字符串 vmaddr | 唯一 xref |
|---|---|---|
| `QtsFileSystem init Failed!!` | `0x10c09d00a` | `0x108879248` |
| `QtsFileSystem Create Failed!!` | `0x10c09d070` | `0x1088792d4` |
| `QtsFileSystem Create failed.` | `0x10c09d0ac` | `0x10432f4b0` |

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
`x2 = 0x10e20107a` = **HOK-015 preseeded `FCommandLine::CmdLine` 地
址**，即 reporter 把 cmdline 当 `%s` context 打印；**QtsFS 的失败不由
cmdline 内容决定**。

### 与 HOK-013 的 slot writer 关系

frame 3 `0x103a29c60 +796` 的指令 `str x0, [x8, #0x6f8]` **正是
HOK-011 全二进制扫描找到的唯一 writer**，目标 slot `0x10e2146f8`。当
NGR 走到 frame 3 这条路径时，HOK-013 预置的 stub 会被真 writer 覆盖；
HOK-013 的价值是在 frame 3 触发前防卫 early reader。HOK-015 让 frame
5 的 `FCommandLine::Get()` guard fall-through，这是 HOK-016 的必要前提。

## 已知真因判定（逐层收紧）

每一层的完整证据都下沉在对应附录，这里只保留跨层骨干：

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
   `0x10432dd98` 返回 0 → 进入 error path → `0x108878534` 返回 0。
   详见 `HOK-016-appendix-C23-C24.md`。
5. **C.2.4**：真正的失败决定点是 `0x10017f184`，不是 `0x10017f3c8`
   （后者在当前 run **0 hit**，是死代码）。`0x10017f184` 做
   rootA→rootB 双层 lookup；运行期 rootB header 是空红黑树 sentinel
   自指。详见 `HOK-016-appendix-C23-C24.md`。
6. **C.2.5**：rootB writer 运行期 watchpoint 命中 2 次，位置在
   `0x1001cf020` 红黑树 insert，**发生在 reporter 内部**
   `0x108877bd0 +692`（readiness B 之前）；rootB 是 lazy-init 模式。
   详见 `HOK-016-appendix-C25-C26.md`。
7. **C.2.6**：reporter 实际插的第一个 key 就是 `"main"`；`rootB ->
   "main"` 第一层 lookup **已成功**。真正失败的是下一层：
   `0x1001bd448 +0x13c → 0x1001ba82c(mainChunk, "1")` 返回 0。
   `mainChunk+0x60` 是空壳，从对象出现到 readiness B fail 之间 **0
   hit**。详见 `HOK-016-appendix-C25-C26.md`。
8. **C.2.7**：当前 natural run 经过 `ba50c` fallback builder，builder
   返回非零对象，但 `0x1001a5014` 内部 storage 创建失败
   （`0x10012bb7c` 返回 null table，`storage+0x30 = 0x9000b`）→
   storage method 返回 0 → a5014 返回 0。C.4 双 checkpoint（storage
   success + ready bit）顶开 old gate 后，dormant writer path
   `0x10432dfdc -> 0x10017f3c8 -> 0x1001bc220 -> 0x1001bc970 ->
   0x1001c6da4 -> 0x1001c6e74` 会真实写 `mainChunk+0x60`；最新
   `build/hok-016c4-force-storage-ready-open-node-v2.json` 又把 sibling
   branch 的分水岭进一步收紧：`0x10432df30` 与 `0x10432dfdc` 两支在
   `ba720(key="1")` 看到的 `ctx[0]` / `ctx+0x18` raw bytes 与 key 都一致，
   真正变化的是调用当下的 `mainChunk+0x60`——前者在 subtree root 已非零时
   lookup 返回 nonzero 并把 `ctx+0x38` 填起来，后者在 `mainChunk+0x60 = 0`
   时 lookup 返回 0、把 `ctx+0x38` 初始化成 0，随后被迫走硬编码 `w3=0`
   的 `bb73c`，产出 `backref-to-entry + null-child` 的 hollow wrapper。
   这一轮 `0x1001a588c` / `0x1001a5730` 的 direct probe 已真正命中：
   success 对照路径分别看到 `pkg+0xa8=2, pkg+0x110=1` 与
   `pkg+0xa8=2, pkg+0x110=3`，且 gate1/gate2 都返回 1；fail 的 branch A
   （`LR = 0x10432df30`）则直接命中 `0x1001a588c` / `0x1001a5730`，
   现场是 `pkg+0xa8=3, pkg+0x110=5`、`mainChunk+0x60` 已非零，但 gate1
   在 `0x1001a55b8` 立刻返回 0。与此同时，新增 natural-run storage 深 probe
   `build/hok-016c27-mainchunk-subtree-storage-v3.json` 还证明：
   `0x10012bb7c` entry 收到的并不是简单 PascalString `"1"`，而是一份
   49-byte descriptor（`x1/x20`）+ companion blob（`x2`）；而再往里补的
  `build/hok-016c27-mainchunk-subtree-trace-v3.json` +
  `build/hok-016c27-create-table-impl-static*.txt` 先把 helper 后半段收紧到：
  `0x10012bb7c` 入口只是 `str wzr, [x4]; b 0x100124e80` 的薄 wrapper；natural
  run 在 `0x10012502c -> 0x100135d80(..., errSlot)` 的第一层 gate 实测
  `w0=1`、`errSlot=0`，随后命中 `0x10012581c` entry-build branch
  （`node+0x48=0, node+0x50=0`），**没有** 命中 `0x100125334` 的 `err=9`
  写点。新增 `build/hok-016c27-final-check-errslot-watch.json` 又把 direct
  writer 真正钉死：gate-ret `0x100125030` 当场把 err slot watch 装到
  `0x6000013bbeb0`，随后第一次写入命中 `0x100122f98`，value=`0x9000b`，
  回溯是 `0x100122f98 <- 0x1001142a4 <- 0x100114994 <- 0x100125960 <- ...`。
  这说明 `0x100125960` final-check 只是消费已写好的 `0x9000b`，direct
  writer 实际位于 `0x10012595c -> 0x1001148b8` 更深层的 callee 链；随后
  `0x1001259c4` 才返回 null table。详见 `HOK-016-appendix-C27.md`。


### 当前根因链（跨 C.2.3 → C.2.7 稳定版本）

```text
NSThread worker
 → MessagingInit → QtsFS_InitWrapper → QtsFileSystem_Init (writes 0x10e2146f8)
 → FactoryRegister → MeyersSingleton → reporter 0x108879164
 → reporter +176 bl 0x108877bd0
 → +688 先 insert "main" 到 rootB (lazy-init)
 → +908 bl 0x108878534 (readiness B)
 → +352 bl 0x10432dd98 (data-verify)
 → 经过 Printf + cmp/vtable 分派，最终 bl 0x10017f184(x0=0)
   → rootA lookup 找到 entry ("main" / "1")
   → rootB["main"] lookup 成功，拿到 mainChunk
   → 0x1001bd448(mainChunk, "1", ...) → 0x1001ba82c(mainChunk, "1")
   → mainChunk+0x60 为 NULL → lookup 返回 0
   → 0x1001bd464 进 fallback: 0x1001ba50c 返回非零 builder object
   → 0x1001a5014 内部 storage 创建: 0x10012bb7c 返回 null table
      (storage+0x30 = 0x9000b) → storage method = 0 → a5014 = 0
   → 0x10017f184 返回 0
 → 0x10432dd98 返回 0 → 0x108878534 返回 0
 → reporter +912 tbz w0,#0 → +364 "Create Failed!!" → UE_LOG + alert
 → frame 4 cbnz w0 → fatal tail-call → GameThread 退出，僵尸态
```

**dual-force 诊断（非 natural run）暴露的额外事实**：在强推 storage
success + ready bit 后，`0x10432dfdc` 那支 sibling 会激活 dormant
writer path 真的把 tracked `mainChunk+0x60` 挂上非零 subtree root，
但 `ctx+0x38=0` 与 hollow wrapper 使 second-gate 返回 0，进程仍会回
落到旧 failure sink。

## 修复方向（HOK-016-C.2.7 之后的排序）

按 "影响面从小到大 / 风险从低到高" 排；必须在 PlayTools 层
bundle-scoped、不动 NGR 二进制：

1. **C.2.7（当前主线）**：继续 live trace，重点并行回答：(a) 为什么
   `0x10432df30` 这支首轮 `0x1001a53a0(..., 1)` 会在 `0x1001a588c` /
   OpenNodeStorage gate 返回 0；(b) 为什么 `0x10432dfdc` 这支
   `ba720(key="1")` lookup 返回 0、把 `ctx+0x38` 初始化成 0；(c) natural
   run 里 `0x10012bb7c` 的第一层 `0x100135d80(..., errSlot)` gate 已经返回 1、
   并已走进 `0x10012581c` entry-build 之后，真正把 error slot 写成
   `0x9000b` 的 direct writer 已收紧到
   `0x10012595c -> 0x1001148b8 -> 0x100114994 -> 0x1001142a4 -> 0x100122f98`；
   下一步要解释这条更深层 callee 链缺了哪一项前置契约，才让 helper 最终返
   回 null table。
2. **C.5**：若 C.2.7 能给出可重复的 child-registration API 签名或完
   整对象构造路径，PlayTools constructor 里按同样签名补齐。**最小侵
   入修法**。
3. **C.4**：若 C.2.7 证实注册路径过深、对象形状又无法安全伪造，基
   于 PlayTools 现有 bundle-scoped runtime hook / direct patch 基建
   做诊断性强制成功验证。
4. **C.3**：终极野蛮方案——fishhook interpose `0x108878534` 直接返回
   1，跳过整条 readiness B。稳定性风险极高，仅作最后兜底。
5. **C.6（降级）**：若必须依赖用户外部资源/登录态，才降级到
   HOK-009。

### 已证伪路径

- **(~~C.X~~) HOK-015 seed value 替换**：详见 `HOK-016-appendix-CX.md`。
- **(~~C.2.1 / C.2.2~~) sentinel `0x10e1eeef0` 未 bump 假设**：运行期
  实测 `= 0x05`；全 `__text` 扫描 0 writer。
- **(~~C.5 pt_stat / NSBundle path fixup，间接证伪~~)**：rootB 的
  lookup key 是内部 PascalString "main" / chunk 名 "1"，不是 FString
  路径；进 `0x10017f184` 的 x0 是 int(=0)；`0x10432dd98` 入口拿到的
  两个 FString 路径实际没被 `0x1001ac168` / `0x1001cd114` 消费。
- **(~~"rootB 从头到尾是空"~~)**：C.2.5 watchpoint 实测 rootB 在
  reporter 运行期被 insert 2 次（`0x1001cf020` 红黑树 insert 路径）。
- **(~~"rootB 缺 main" / C.2.5~~)**：C.2.6 实测 reporter 插的第一
  个 key 就是 `"main"`，真失败在 `mainChunk -> "1"`。

所有方向都必须保留 HOK-013 / HOK-014 / HOK-015 作为安全网，落地之前先
在 `build/hok-016-*.json` / `build/hok-016c-*.json` /
`build/hok-016c2-*.json` / `build/hok-016c24-*.json` /
`build/hok-016c25-*.json` / `build/hok-016cx-*.json` 记录证据；落地
后的验证口径见 Dashboard "HOK-016-D 判据"（`hok014_ngr_alert_suppressed
= 0` / 进程活跃度 / 窗口可见性 / 无新 `NGR-*.ips`）。

## 参考

### 子文档（按需读取）

- `HOK-016-appendix-tooling.md`：所有 `Scripts/hok016*` 脚本说明 +
  LLDB BP callback 踩坑。
- `HOK-016-appendix-C23-C24.md`：`0x10432dd98` step-into + `0x10017f184`
  真失败决定点。
- `HOK-016-appendix-C25-C26.md`：rootB writer watchpoint + `mainChunk
  -> "1"` 真缺口。
- `HOK-016-appendix-C27.md`：mainChunk watchpoint / ba50c fallback /
  storage fail / dual-force / sibling branch / hollow wrapper（10 步）。
- `HOK-016-appendix-CX.md`：seed 替换实验证伪详情。

### 相关前置文档

- `HOK-011-静态初始化链分析.md`：`0x10e2146f8` 的唯一 writer = frame
  3 函数内部 `0x103a29f7c`；frame 2 = HOK-011 记录的 "0x107e5df10 唯
  一 caller"；反向 BFS 方法论。
- `HOK-013-slot-preheat.md`：为何在 frame 3 触发前必须把 `0x10e2146f8`
  写成 stub。
- `HOK-014-alert-suppressor.md`：UIAlertController swizzle；HOK-016 闭
  合前 HOK-014 仍承担 "用户看不到 alert" 的硬约束。
- `HOK-015-cmdline-preseed.md`：FCommandLine 预置；HOK-016-B 的 x2
  参数语义校验依赖 HOK-015-A 输出 `build/hok-015-cmdline-slots.json`。
