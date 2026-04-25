## PDT-001A compare literal 提取

> **阅读建议**：只在需要复核 `PDT-001-A` 的离线证据、重新解释
> `0x10432a068` compare ladder、或决定是否还有必要重开 PathDifferenceTrial 时读取。
> 日常只看 `00-Dashboard.md` 即可。

## 目的

本页只沉淀 `0x10432a068` materializer target 内 fixed literal 的离线提取证据：

- 它实际比较的固定 UTF-16 literal 到底是什么；
- 这些 literal 是否包含路径前缀、目录层级、文件名或数据库片段；
- 因而 PathDifferenceTrial 是否还有继续做 `PDT-001-B` 的必要。

主文档只保留结论与优先级；详细方法、地址与结构化产物留在这里。

## 结构化产物

- `build/pdt-001a-compare-literals.json`
- `Scripts/pdt001_ngr_materializer_literal_extractor.py`
- `build/pdt001-target-disasm.txt`

## 方法

1. 对已安装的 `NGR` 二进制离线反汇编 `0x10432a068..0x10432a31c`；
2. 只提取该函数窗口内的 `ADRP + ADD` PC-relative 常量；
3. 过滤出落在 `__TEXT,__ustring` 的 UTF-16 literal 候选；
4. 直接按地址解码字符串，并额外回溯“所在完整 UTF-16 字面量上下文”；
5. 判断这些 literal 是否与路径 / 文件名相关。

## 关键反汇编落点

- `0x10432a198 / 0x10432a19c`
>  `adrp x23, 0x10c09a000` + `add x23, x23, #0xca2`
- `0x10432a1e8 / 0x10432a1ec`
>  `adrp x11, 0x10c09a000` + `add x11, x11, #0xca6`
- `0x10432a284 / 0x10432a288`
>  second compare 再次装载 `0x10c09aca6`

配合 compare ladder：

- `0x10432a1b0..0x10432a1e4`：先比较 `x10` 指向的 selected buffer 与 `x23`
- `0x10432a1f0..0x10432a224`：再比较 selected buffer 与 `0x10c09aca6`
- `0x10432a244..0x10432a2c4`：第二轮 compare，仍使用 `x23` 与 `0x10c09aca6`

## 提取结果

### fixed literal 真值

- `x23 = 0x10c09aca2` → UTF-16 `"r"`
- `0x10c09aca6` → UTF-16 `"rb"`
- 两者都位于 `__TEXT,__ustring`
- `0x10c09aca6 - 0x10c09aca2 = 4` 字节，即 2 个 UTF-16 code unit

### 完整上下文检查

本轮没有发现“指向更长路径字符串中间位置”的情况：

- `0x10c09aca2` 的完整上下文仍是 `"r"`
- `0x10c09aca6` 的完整上下文仍是 `"rb"`

因此这两个 literal **不是** `"../../../..."`、`"/Users/..."`、`"1.db"`、`"Paks"`
或其它路径/文件名片段的 suffix。

## 结论（已收窄）

`0x10432a068` compare ladder 的 fixed literal **与路径无关**。

这意味着：

- "materializer 内部固定模板直接做路径相关 compare" 这层假设已被排除；
- 但**不能排除**上层路径转换差异通过改变 selected buffer 内容来间接影响
  compare accumulator 的可能。UE4 `FIOSPlatformFile::ConvertToPlatformPath` 的源码
  已证实：对 `/var/` 开头路径直接透传，对 `/Users/` / `~/` / `../` 路径做
  `ReplaceInline("../")`、`FPaths::MakePlatformFilename`、以及基于
  `NSDocumentDirectory` / `NSLibraryDirectory` 的重新拼接。因此 iOS 真机的
  `/var/...` 与 PlayCover 的 `/Users/...` 在 UE4 层会被**不同处理**，这种差异
  可能改变 materializer 看到的 selected buffer。
- natural run 的实际 target 是 `0x100128c6c`，不是 `0x10432a068`；本页结论
  对 natural run 的适用性需待 `PDT-004` 验证。

## 对母线的影响

本页证据只排除了 **fixed literal 路径相关性**，没有直接解释：

- 为什么 success / fail 的 `entryX1` 字符串会不同；
- UE4 `ConvertToPlatformPath` 对 `/Users/...` 的实际转换结果是什么；
- natural run target `0x100128c6c` 是否使用相同的 fixed literal；
- pre-`1c8` selected buffer / compare accumulator 是如何被构造出来的。

因此 PathDifferenceTrial 不应关闭，而应继续推进 `PDT-001-B-revised`（验证 UE4
路径转换差异）和 `PDT-004`（提取 natural run target 的 literal）。
