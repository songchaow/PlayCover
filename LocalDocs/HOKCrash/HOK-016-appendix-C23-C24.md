# HOK-016 附录：HOK-016-C.2.3 / C.2.4 证据详解

> 本文是 `HOK-016-qts-fs-create-failed.md` 的附录，沉淀 HOK-016-C.2.3
> （`0x10432dd98` 的 step-into 证据）与 C.2.4（真正失败决定点下钻到
> `0x10017f184`）的完整控制流、寄存器快照、rootA/rootB 结构解析与
> 收尾结论。
>
> **何时读**：
>
> - 需要理解"为什么 `0x10017f3c8` 是死代码 / 真正被调用的是
>   `0x10017f184`"；
> - 需要查 `0x10432dd98` 各关键 offset 的实测寄存器值；
> - 需要复现 C.2.4 的 30 个 Python callback BP；
> - 日常阅读 HOK-016 主文档不必进入本文。
>
> **相关文档**：
>
> - 上一层 readiness B dispatcher：见 HOK-016 主文档"核心证据"段；
> - rootB writer / `mainChunk -> "1"` 缺口：
>   `HOK-016-appendix-C25-C26.md`；
> - storage create-table / `0x9000b` err-slot 与 materialization 链：
>   `HOK-016-appendix-C27.md`；
> - 脚本说明与 LLDB BP callback 踩坑：`HOK-016-appendix-tooling.md`。

## HOK-016-C.2.3：`0x10432dd98` 内部 step-into 证据

`Scripts/hok016c2_ngr_step_into_readinessB.py` 在 `0x108878534` 的
`+352 bl 0x10432dd98` 前、后、以及 `0x10432dd98` 入口各设探针 BP，
稳定观察到：

- `+352` before bl：`x0=0x12148dc90, x1=0x1, x2=0x1708c64d8,
  x3=0x1708c64c8, x22=0x10e1ee000` —— 4 参数调用、x22 仍是 `__common`
  段基址（callee-saved）。
- **`0x10432dd98` entry：同样的 4 个寄存器值被命中**——与 Dashboard 先
  前"`0x10432dd98` BP 0 次命中"的陈述直接冲突。**Dashboard 原判定是
  误读**（HOK-016-C.1 的 BP 当时可能没用 `--shlib NGR --address`
  module-relative 格式），实际 `bl 0x10432dd98` 被稳定 call 到。
- `+356` after bl：`x0 = 0x0` —— `0x10432dd98` **返回 0**，这正是
  `0x108878534` 内部 `+360 tbz w0, #0, +84 → 0x1088786f0` 的判定输
  入；w0=0 → 走 error path → `mov x0, x20 = 0` → `0x108878534` 返
  回 0 → reporter `+912 tbz w0, #0, +1364` 进入 Create Failed。

### `0x10432dd98` 的静态语义

- 入口做 `FString::Printf("%d", …)` 构造一个数字字符串到 `sp+0x38`
  （`bl 0x10473a3d4`，参数 `adrp x0,<%d@0x10c09b392>`）；
- 然后执行若干 FString 构造 + 两次 Qtsk allocator 类调用
  (`bl 0x10432b734` / `bl 0x104826068`) + 一个 vtable 派发
  (`ldr x8,[x19,#0x60]; blr [x8+0x190]`);
- 最终 `+412 bl 0x10017f3c8(w0=[sp+0x14], w1=1, w2=0)`，其返回值
  经 `tbz w0,#0, error_path` 决定本函数的返回 (w19=1 = 成功 /
  w19=0 = 失败)。

`0x10017f3c8` 进入 `ChunkAllocator<Qtsk::STGlobalMemData,false,false>`
合并符号内（strip 后所有 `Qtsk::STGlobalMemData` 系 helper 都归进
这个符号名 `_FinalClean`，实际是**多组互独立**的函数，符号表边界
至 `___cxa_throw` 之前；仅按地址聚合，不是真的都来自 `_FinalClean`）。
其入口做 `adrp x8, 0x10e184000; ldr x0, [x8, #0x9f0]` 然后
`bl 0x1001ac168` 填充 stack 结构 `sp+0x60`，再 `cbz x8, fail_slot_1
(return w19=0)`、`bl 0x1001cd114(x0=@0x10e184b18, x1=x8+0x10, w2=1)`
后 `cbz x0, fail_slot_2 (return w19=0)`。

> **注意**：这条“`0x10017f3c8` 内部失败”假设在 C.2.4 中被修正：
> `0x10017f3c8` 实际上在当前 run 中不可达；真正被调用并返回 0 的是
> `0x10017f184`。见下节。

## HOK-016-C.2.4：真正的失败决定点是 `0x10017f184`，不是 `0x10017f3c8`

`Scripts/hok016c24_ngr_readinessB_inner_args.py` +
`Scripts/hok016c24_lldb_inner_probes.py` 分三轮实验（v2 / v3 /
v4-5）给 `0x10432dd98` 全函数装 ~30 个 Python callback BP，**把"到
底从哪条 early-exit 返回 0"彻底钉死**。

### 完整控制流（跨 run 稳定）

```
0x10432dd98 entry
  x0 = this (QtsFS instance)
  x1 = 0x1 (mode)
  x2 = FString*("../../../NGR/Content/paks")      ← cooked 资源相对路径
  x3 = FString*("/Users/songdogwang/Library/NGR/Saved/Paks")  ← 容器内绝对路径

+0x00..0x40  FString::Printf("%d", x1=1)  →  sp+0x38 内 FString = "1"

+0x48..0x54  ldr w22, [sp,#0x40] (=2, FString "1" 的 Num incl. NUL)
             ldr w8,  [0x10f0df000 + 0xc08] (=2, "decision" global)
             cmp w22, w8  →  EQ  →  b.eq 0x10432df8c

+0x1F8 (0x10432df8c): 进入 alt-path
  cmp w22, #0x2 (=2) → NOT lt → fallthrough
  ldr x0, [sp+0x38] (= Printf 出的 FString data ptr)
  ldr x1, [0x10f0df000 + 0xc00] (=另一个 global)
  bl  0x1047482ac(x0=printf_str, x1=global_c00)  →  w0
  cbnz w0, 0x10432ddfc                           →  看 w0
    ↓ (w0 == 0 的实际观察情形；实测 w0 非零也会回到 de10)
  b   0x10432de10

+0x78..0xF8 (0x10432de10..de88): 两次 FString 包装 +
             两次 bl 0x104826068 (某个 TMap/TSet 插入或查找)

+0x11C 第一次 vtable blr  (x8 @ [x19+0x60] -> +0xf8)  →  x21 = return (=0x1)
+0x13C 第二次 vtable blr  (相同 vtable -> +0xf8)      →  x20 = return (=0x0)
+0x14C bl  0x104329c18  (构造 uint key)               →  w1 stored to [sp+0x14]
+0x154 cbnz w21, 0x10432dfac                          ←  w21=1 → jump dfac

+0x214 (0x10432dfac): cbz w20, 0x10432e06c            ←  w20=0 → jump e06c

+0x2D4 (0x10432e06c):
  mov x0, x1 (=0 here, see v4 probe at 10432e06c)
  bl 0x10017f184(x0=0)                               ←  核心 lookup 调用
  tbnz w0, #0, 0x10432dfbc                           ←  实测 bit0=0 → fallthrough

+0x2E0..0x2FC: ldr x0, [x19+0x60]; ldr x8,[x0]; blr [x8+0x190]
             再次 vtable 派发 (logging / classifier)
+0x2F8 ldrb sentinel; cmp #2; b.lo 0x10432e058 (不跳，因为 sentinel=5)
+0x30C bl  0x10432e194 (logging)
+0x310 b   0x10432e058

+0x2C0 (0x10432e058): mov w19, #0x0                   ←  **FAIL_EXIT_A 就地**
+0x2C4 b   0x10432df38 → epilogue → return 0
```

### `0x10017f184` 内部（与 `0x10017f3c8` 同构但目标不同）

```
0x10017f184 entry
  x0 = key (int)  ; v4 实测 x0 = 0
  mov x1, x0     ; save as int-key for later lookup

+0x30   adrp x8, 0x10e184000; ldr x0, [x8, #0x9f0]   ; rootA
        add  x8, sp, #0x20                            ; out slot
+0x38   bl   0x1001ac168(x0=rootA, x1=key=0, x8=out)
+0x3C   ldr  x8, [sp, #0x20]                          ; entry ptr
+0x40   cbz  x8, 0x10017f2f0                          ; lookup A miss → fail_slot_1

+0x44..0x50 add x1, x8, #0x10   ; x1 = entry+0x10 = PascalString header
           adrp x0, 0x10e184000; add x0, x0, #0xb18 ; rootB = 0x10e184b18
           mov  w2, #0x1
+0x54   bl   0x1001cd114(x0=rootB, x1=entry+0x10, w2=1)
+0x58   mov  x19, x0                                  ; return value
+0x5C   cbz  x0, 0x10017f2bc                          ; lookup B miss → fail_slot_2
```

### `entry+0x10` 的真实结构（PascalString，不是 FString）

v4-5 run 在 `0x10017f1d8` 抓的 hex48：

```
entry+0x10 hex: 04 00 00 00 00 00 00 00 | 6d 61 69 6e 00 00 00 00 | ...
                length=4                 | 'm' 'a' 'i' 'n' \0\0\0\0
entry+0x20 hex: 01 00 00 00 00 00 00 00 | 31 00 00 00 00 00 00 00
                length=1                 | '1'  \0\0\0\0\0\0\0
entry+0x30 hex: 01 01 00 00 00 00 00 00 ; flags?
```

也就是说 entry 里记着 **name = "main"**，**chunk signature = "1"**。
HOK-016-C.2.4 前的假设 "x1 指向 FString" 是错的——它是一个在线
PascalString (`[length: u64][chars: N][padding]`) 结构，被 lookup B
当作字符串 key 使用。

### rootB 状态与失败直接原因

v5 run `f184_before_bl2` 抓的 `rootB_hdr` (32 bytes @ `0x10e184b18`)：

```
10 3e 33 16 01 00 00 00 | 10 3e 33 16 01 00 00 00 |
01 00 00 00 00 00 00 00 | 00 00 00 00 00 00 00 00
```

解读：`*rootB = 0x116333e10`，`*(rootB+0x8) = 0x116333e10`（自指
sentinel），`count = 0x01`。典型的**空红黑树 sentinel 自指**结构，
count=1 通常是 nil-node 本身被计入容量或 sentinel reservation。
**运行期观察到的 bl 0x1001cd114 调用 v5 的 x0(rootB)=`0x10e184b18`**
（与静态分析一致），该容器在 lookup 到 key "main" 时**返回 0
（lookup B miss）**。

### HOK-016-C.2.4 收尾结论

- 真因**不在** `0x10017f3c8`：`probe_inner_entry` / 其 7 个 BP 在 v3/
  v4/v5 run **0 次命中**，说明整条 HOK-016-C.2.3 里"bl 0x10432dd98 内
  部 `+412 bl 0x10017f3c8`" 路径实际上是**死代码**（该路径要求
  `0x10432df0c cbz w20, 0x10432df34` 走 success 或 `0x10432df18 bl
  0x10017faa0` 返回非零 → 跳 dfec → 再经 `b.lo sentinel` 路径返回
  success；两条都不是当前 run 的实际走向）。
- 真因**就在** `0x10017f184`：它和 `0x10017f3c8` 共享同一个 lookup
  模板（adrp → ldr root → bl 0x1001ac168 → cbz → bl 0x1001cd114 →
  cbz），但用的是 `sp+0x20` 而不是 `sp+0x60`，且入参是一个 int key
  = 0；`bl 0x1001ac168` 查 rootA 能找到 "main/1" 的 entry，但
  `bl 0x1001cd114` 拿 entry+0x10 的 PascalString "main" 去 rootB 查
  **查不到**（rootB 是一个 sentinel-self-loop 的空红黑树），于是返
  回 0。
- 这把 HOK-016-C.2.x 系列的 "readiness B 失败 = rootB 空" 的判定
  精确到了**具体 key = "main"**。
- 资源路径 FString `../../../NGR/Content/paks` 与
  `/Users/songdogwang/Library/NGR/Saved/Paks` **只是 0x10432dd98 的
  两个参数**，没有被 `bl 0x10017f184` 实际使用——它们只在更早的路径
  （b.eq 10432df8c 之前）才会被 `bl 0x10432b734` 当成 key 使用。因
  此 **HOK-016-C.5 (pt_stat / NSBundle swizzle path fixup) 不是治
  本方向**，这条线在 C.2.4 被间接证伪。

> **注**：C.2.4 的 "rootB 缺 main" 结论在 C.2.6 被进一步改写——实际
> rootB **会被 insert**，真实缺口在 `mainChunk -> "1"` 二级子树。
> 详见 `HOK-016-appendix-C25-C26.md`。

产物：`build/hok-016c24-readinessB-inner-args.json` (= v5 run 的副
本，保留完整 transcript + summary)。
