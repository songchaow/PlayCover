## PDT-004 natural run target literal 提取

> **阅读建议**：只在需要复核 `PDT-004` 的离线证据、重新解释
> `0x100128c6c` 与 `0x10432a068` 的结构差异、或决定 PathDifferenceTrial
> 下一步方向时读取。日常只看 `00-Dashboard.md` 即可。

## 目的

验证或证伪以下问题：

- natural run 中 `0x100122f54` 的 `x8(target)=0x100128c6c` 是否与 dual-force
  的 `0x10432a068` 使用相同的 fixed compare literal（UTF-16 `"r"` / `"rb"`）；
- 若相同，则 `PDT-001-A` 结论可扩大到 natural run；
- 若不同，则 natural run 与 dual-force 的 materialize 代码路径存在结构性差异。

## 结构化产物

- `build/pdt-004-natural-target-literal.json`
- 复用 `Scripts/pdt001_ngr_materializer_literal_extractor.py`

## 方法

1. 对已安装的 `NGR` 二进制离线反汇编 `0x100128c6c..0x100128f20`；
2. 只提取该函数窗口内的 `ADRP + ADD` PC-relative 常量；
3. 过滤出落在 `__TEXT,__ustring` 的 UTF-16 literal 候选；
4. 判断这些 literal 是否与路径 / 文件名相关。

## 关键反汇编落点

- `0x100128c6c`：`mov x0, x1`
- `0x100128c70`：`mov x1, x2`
- `0x100128c74`：`b 0x107c040e4`

该地址不是函数入口，而是 `__ZN6Escher7Runtime8HandleEhINS_8_OpDec11EEEvPNS_6EhNodeERNS_10FrameStateEPKv` 这个大函数内部的一段 **dispatch stub**：它将参数重新排列后，通过无条件跳转 `b` 进入 `__stubs` 区域（`0x107c040e4`），最终经 `__la_symbol_ptr` 解析到外部函数。

窗口内继续向后反汇编（至 `0x100128f20`），均未发现任何 `ADRP + ADD` 对指向 `__TEXT,__ustring`；只有常规的寄存器移动、分支、函数调用与数组/哈希表操作指令。

## 提取结果

### fixed literal 真值

- **无**。`0x100128c6c..0x100128f20` 窗口内不存在任何 `__TEXT,__ustring` 中的 fixed literal。
- `pcRelativeConstants.all = []`
- `ustringCandidates = []`
- `compareLiterals.primary = null`
- `compareLiterals.secondary = null`

### 与 `0x10432a068` 的结构差异

| 维度 | `0x10432a068`（dual-force target） | `0x100128c6c`（natural run target） |
|---|---|---|
| 代码类型 | 本地函数，含完整 compare ladder | dispatch stub（mov + b） |
| compare literal | UTF-16 `"r"` / `"rb"` | **无** |
| 字符串操作 | 显式 `ldrb` / `cmp` / `cbz` 逐字符比较 | 无逐字符比较逻辑 |
| 后续跳转 | 本地分支（`branch-224`、`branch-238` 等） | 经 `__stubs` 进入外部函数 |
| 路径消费 | 内部直接消费 selected buffer | 参数透传至外部符号 |

## 结论与影响

1. **`PDT-001-A` 结论仅限 `0x10432a068`**：natural run 的 materialize target
   `0x100128c6c` 不是同一个 compare ladder，也不包含相同的 `"r"`/`"rb"` fixed literal。
2. **natural run 与 dual-force 的 materialize 路径存在结构性差异**：dual-force
   命中的是本地 compare ladder；natural run 命中的是一个 dispatch stub，真正的
   materialization 逻辑可能位于该 stub 跳转到的外部函数中。
3. **对 PathDifferenceTrial 的启示**：
   - 不能直接把 `PDT-001-A` 的 literal 结论套用到 natural run；
   - `PDT-001-B-revised` 若仍想在 PlayTools 层做路径伪装，目标不应是改变
     `0x100128c6c` 内部（因为它没有 compare literal），而应是改变**传入该 stub
     的参数**（即 `x1`、`x2` 等），从而影响外部函数的行为；
   - 若外部函数本身对路径敏感，路径差异假设仍可能成立，但验证口径需要从
     "materializer 内部 fixed literal" 切换到 "外部函数的输入参数差异"。

## 与 HOK-016-C.2.7 的交叉验证

- HOK-016 母 Dashboard 已指出：natural run 的 `x8(target)=0x100128c6c`（或
  `0x115a5eb30`），与 dual-force 的 `0x10432a068` 不同。
- C27 §14.b 的 `v1/v1-recheck2/v2` live trace 中，部分自然 run 仍命中
  `0x10432a068`，说明同一启动流程中**可能同时存在两条 materialization 路径**：
  一条走 `0x10432a068`（compare ladder），另一条走 `0x100128c6c`（dispatch stub）。
- 当前自然 run 中观察到 fail 的恰是 `0x100128c6c` 路径，这提示：**fail 可能不是
  compare literal 导致的，而是 dispatch stub 调用的外部函数在特定输入下返回 0**。

## 下一步建议

- 若继续推进 PathDifferenceTrial，优先方向是：
  1. 用 LLDB 在 `0x100122f54` 设 BP，捕获 natural fail 时 `x1(entryX1)` 的具体值；
  2. 同时捕获 `0x100128c6c` 执行后、进入 `__stubs` 前的寄存器状态；
  3. 尝试识别 `0x107c040e4 → 0x10a9eb718` 对应的外部符号，确认该外部函数是否
     对路径参数做进一步处理。
- 若识别外部符号困难，可将验证重心从 "compare literal" 转向 "entryX1 参数差异"。
