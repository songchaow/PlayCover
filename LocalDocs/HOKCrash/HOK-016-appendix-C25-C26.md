# HOK-016 附录：HOK-016-C.2.5 / C.2.6 证据详解

> 本文是 `HOK-016-qts-fs-create-failed.md` 的附录，沉淀 HOK-016-C.2.5
> （rootB writer 运行期 live trace、lazy-init 模式验证）与 C.2.6
> （真正缺失的不是 `rootB -> "main"`，而是 `mainChunk -> "1"` 二级
> 子树）的完整证据。
>
> **何时读**：
>
> - 需要理解"rootB 在 reporter 运行期被 insert，但 insert 的 key 是
>   什么"；
> - 需要复现 watchpoint 抓新 node 内容的流程；
> - 需要判断某次 live run 里 reporter 实际插入的第一个 key 是不是
>   `main`；
> - 日常阅读 HOK-016 主文档不必进入本文。
>
> **相关文档**：
>
> - readiness B 内部控制流 / `0x10017f184` 真失败决定点：
>   `HOK-016-appendix-C23-C24.md`；
> - fallback builder / storage create-table / `0x9000b`：
>   `HOK-016-appendix-C27.md`；
> - 脚本说明与 LLDB BP callback 踩坑：`HOK-016-appendix-tooling.md`。

## HOK-016-C.2.5：rootB writer 在 reporter 内部才 fire，是 lazy-init 模式

C.2.4 给出的"rootB 为空"结论需要再精化——C.2.5 用两条分析路径证实：

### 离线 direct-store 扫描

`Scripts/hok016c2_ngr_sentinel_writer_scan.py --target-address
0x10e184b18` 对 rootB 做全 `__text` 直接 store 扫描，**只命中 2 条**：

- 1 条是真 writer：`0x1001cf314 str x8, [x1]`，位于 `0x1001cf20c`
  这个 static constructor——它出现在 `__init_offsets` 可达链里，意味
  着 dyld 启动阶段**必然**被调用、并把 rootB 初始化为 "sentinel
  self-loop" 空容器状态；
- 另 1 条（`0x109adbcb8 str.w wzr, [x19+0xb18]`）经交叉验证是 scanner
  的 constant-propagation 误报（`x19 = x22 + 0x9000`，与 rootB 无关）。

产物 `build/hok-016c25-rootB-writer.json`。

### xref 扫描

`Scripts/hok016c25_ngr_rootB_xref_scan.py` 枚举所有 `adrp+add x?,
0x10e184000, #0xb18` pattern，即 "把 rootB 地址 materialize 到某寄
存器" 的站点。**结果 94 个 hit，93 个 dst=x0**，跨 52 个不同函数。
这说明 rootB 不是一个 "简单 store 目标"，而是一个被大量 helper
`find/insert/erase` **当 this 消费** 的容器；真正的 entry insert
一定通过 helper 间接完成、不会出现在直接 store 扫描里。产物
`build/hok-016c25-rootB-xrefs.json`。

### LLDB watchpoint live trace

`Scripts/hok016c25_ngr_rootB_watch.py` 在 NGR `main` 入口装 8-byte
modify watchpoint（此时 dyld static constructors 已执行完，确保只抓
main 之后的写）。结果：**2 次命中**，都在同一线程同一 callchain 上，
PC 均为 `0x1001cf020`（即 `0x1001cef38` 这个 `unnamed_symbol6059`
内的 +232，指令序列 `stp xzr,xzr,[x21]; str x23,[x21+0x10]; str x21,
[x22]; ldr x8,[x19]; ldr x8,[x8]; mov x1,x21; cbz x8; str x8,[x19] ←
被 watchpoint 捕获; ldr x1,[x22]`——典型的红黑树 `insert_unique`
插入节点+更新 leftmost 路径）。

- **Hit #0**：backtrace 只有 1 frame（因为 watchpoint 立即
  auto-continue；oldValue/newValue 未捕获，但 PC 仍指向
  `0x1001cf020`）。
- **Hit #1**：`oldValue = 0x10E1EFCB60`，`newValue = 0x1168D82A0`
  （把 `rootB[0]` 从一个 `__common` 地址改成一个 heap 指针，即更新
  leftmost child 指针），**backtrace 11 层明确**：

  ```
  #0 0x1001cf020 unnamed_symbol6059 +232  ; red-black insert
  #1 0x1001ccf34 unnamed_symbol6021 +108  ; inner helper
  #2 0x1001b8d3c unnamed_symbol5797 +728  ; inner helper
  #3 0x10017c1e8 unnamed_symbol5139 +232  ; inner helper
  #4 0x108877e84 = 0x108877bd0 +692       ; ← reporter 内部
  #5 0x108879214 = 0x108879164 +176       ; ← reporter vtable[0x30] 入口 +176
  #6 0x103a29bec MeyersSingleton +112
  #7 0x107e5df4c FactoryRegister +60
  #8 0x103a29fa0 QtsFileSystem_Init +832
  #9 0x107e5c970 QtsFS_InitWrapper +12
  #10 0x103a227d0 MessagingInit +44
  #11 0x104a04d38 NSThreadWorker +164
  ```

**关键洞察**：rootB 的 insert 并不是在 dyld static init 或 pre-reporter
阶段发生的，而是 **发生在 reporter 运行期间，具体是 `0x108877bd0 +692`
这个点**——这位于 `+176 bl ...` 和 `+908 bl 0x108878534`（readiness
B dispatcher）之间，但**顺序上先于** readiness B。也就是说 reporter
自己会先尝试往 rootB 插入一些 entry，然后才做 readiness check。

然而 C.2.4 v5 run 在 reporter 内部 `0x10017f1d8 bl 0x1001cd114` 前读
rootB，header 仍是 `*rootB = *(rootB+0x8)` (两 ptr 同值 = 单 node 或
空)，count=1；同时 `bl 0x1001cd114(..., "main", 1)` 返回 0。结合
C.2.5 的 2 次 watchpoint hit：**reporter 实际 insert 的是别的 key，
不是 "main"**（只插了 2 个 node、而 readiness B 需要 "main"）。

换言之，**macOS 下 iOS 预期在 reporter 之前就注册好的 "main" chunk**
没被注册进来。reporter 的 "按需 insert" 行为只插入它自己当下调用上下
文需要的 entry（可能是当前 asset 的标识），但 "main" 这个基础 chunk
需要由 **更早期的初始化代码** 预注册——目前看这段 iOS-specific 的预
注册在 macOS 下缺失。

> **注**：C.2.5 的 "reporter 实际 insert 的不是 main" 结论在 C.2.6
> 被再次改写——reporter 插的第一个 key 就是 `main`；真正缺的是
> `mainChunk -> "1"` 二级子树。见下节。

产物：`build/hok-016c25-rootB-writer.json`（离线 direct-store scan）+
`build/hok-016c25-rootB-xrefs.json`（离线 adrp+add xref scan）+
`build/hok-016c25-rootB-watch.json`（LLDB watchpoint live trace）。

## HOK-016-C.2.6：`rootB -> "main"` 实际成功，真正缺的是 `mainChunk -> "1"`

C.2.5 的关键误差是把 rootB 的失败停在了 **第一层** 名字查找。C.2.6
用新的离线脚本 + 运行期 LLDB trace 把这条链继续往后推，结论是：

### 1. 离线 `"main"` literal 扫描没有找到可用的 dyld registrar

`Scripts/hok016c26_ngr_main_literal_xref.py` 扫到的只有与当前主线无关
的 `__cstring main` 文本（例如普通日志字符串 / ObjC method name），
**没有**找到与 `__init_offsets` 可达链相交的 PascalString `"main"`
预注册路径。这条结果本身不能给出修法，但它排除了"磁盘里就有一个明
确的 static constructor 专门注册 `main`"这条最省事路线。产物
`build/hok-016c26-main-literal.json`。

### 2. reporter 内部第一次 insert 的 key 就是 `"main"`

`Scripts/hok016c26_ngr_rootB_keys.py` +
`Scripts/hok016c26_lldb_rootb_key_watch.py` 在 C.2.5 的 rootB
watchpoint 基础上，直接读取新 node 的 `node+0x20` PascalString，实测：

- watchpoint hit @ `0x1001cf020`
- `x19 = rootB = 0x10e184b18`
- `x21 = newNode`
- `newNode+0x20 = 04 00 00 00 00 00 00 00 6d 61 69 6e 00 00 00 00`

即 reporter 不是"插了两个非-`main` entry"，而是**至少有一次插的就
是 `main`**。insert 之后 rootB header 变成单节点树（两个 ptr 都指向
新节点，count=1）。产物 `build/hok-016c26-rootB-keys.json`。

### 3. `0x10017f184` 内第一层 lookup 已经成功

在 `0x10017f1dc`（`bl 0x1001cd114` 返回后）设 BP，实测：

- `x0 = 0x137027a00`（非零；每次 run 地址不同）
- 因而 `0x10017f1e0 cbz x0` **不会** 触发

这直接推翻了 C.2.4 / C.2.5 的旧结论 "`bl 0x1001cd114(rootB, "main",
1)` 返回 0"。也就是说 **rootB 里的 `"main"` 名字查找已经闭合**。

### 4. 失败发生在下一层：`0x1001bd448` 内的 `0x1001ba82c(mainChunk, "1")`

静态反汇编显示：

- `0x10017f290` 调 `0x1001bd448(x0 = mainChunk, x1 = entry+0x20 = "1",
  x2 = sp+0x28, x3 = sp+0x10)`
- `0x1001bd448 +0x13c` 调 `0x1001ba82c(x0 = mainChunk, x1 = "1")`
- `0x1001bd588` 处实测 `x0 = 0`
- 随后 `0x10017f29c` 处 `x0 = 0 / x19 = 0`
- 最终 `0x10432e074` 看到 `0x10017f184` 返回 0

也就是说真失败点不再是 `rootB -> "main"`，而是 **`mainChunk -> "1"`**
这层二级查找。

### 5. `mainChunk` 是个空壳对象：`obj+0x60 = 0x0` 且直到 failure 前都没人写它

对 `0x10017f1dc` 处返回的 `mainChunk` 对象做快照，实测：

- `obj+0x60 = 0x0`
- `obj+0xe0` 有非空数组边界（说明对象本身不是空指针）

而 `0x1001ba82c` 的静态逻辑正是：

- `mainChunk+0x60` 取一棵内部树的 root
- 用 key `"1"` 做 tree lookup
- 命中则返回 `match+0x30`
- miss 则直接返回 0

C.2.6 在 `mainChunk+0x60` 上临时装了动态 watchpoint；从对象出现到
readiness B failure 之间 **0 hit**。这证明 reporter 插到 rootB 里的
`main` 对象只是一个 **名字已存在、但内部 `"1"` 子项树为空** 的骨架
对象。

### C.2.6 对根因链的改写（覆盖 C.2.5 的说法）

```text
reporter 内部 insert main 到 rootB
  → rootB["main"] lookup succeeds
  → 得到 mainChunk object
  → mainChunk+0x60 secondary tree is NULL / never populated
  → 0x1001ba82c(mainChunk, "1") returns 0
  → 0x1001bd448 returns 0
  → 0x10017f184 returns 0
  → 0x10432dd98 returns 0
  → readiness B fail
  → "QtsFileSystem Create Failed!!"
```

因此，后续修复目标不再是 "往 rootB 里补一个 `main` entry"，而是更
精确的：**让 `mainChunk` 对象下面的 `"1"` 子注册闭合**，或者在更靠
后的诊断点（`0x1001ba82c` / `0x1001bd448`）做 bundle-scoped 强制成
功验证。

> **注**：C.2.6 又在 C.2.7 被进一步收紧——active failure 其实经过
> `ba50c` fallback builder + `0x1001a5014` storage 创建失败
> （`0x10012bb7c` 返回 null table / `storage+0x30 = 0x9000b`），并
> 暴露出 dormant writer path 与 sibling branch 结构。详见
> `HOK-016-appendix-C27.md`。
