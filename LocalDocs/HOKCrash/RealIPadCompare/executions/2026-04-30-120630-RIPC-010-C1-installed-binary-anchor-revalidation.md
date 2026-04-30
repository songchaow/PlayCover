## RIPC-010-C1 installed-binary anchor revalidation

### 背景

本轮目标不是继续证明 `pdt006_ngr_convert_patch status=installed`，而是回答 `RIPC-010-C1` 当前最窄的问题链：为什么 `pdt006_convert_replacement()` 仍然没有留下 `pdt006_ngr_convert_call` / `ripc006_pak_path_normalize` 证据。

根据 [00-Dashboard.md](/Users/songdogwang/Codes/PlayCover/LocalDocs/HOKCrash/RealIPadCompare/00-Dashboard.md) 当前主线，这一轮先做**离线 installed-binary 复核**，判断旧锚点 `PDT006_CONVERT_FUNC_UNSLID = 0x10463f204` 是否仍能代表当前 `ConvertToPlatformPath` 热路径入口，避免继续把“补丁已安装”错误等同于“replacement 必然能看到 failing flow”。

### 执行时间

- `2026-04-30 12:06:30 +0800`

### 输入对象

- 已安装 app binary：`/Users/songdogwang/Library/Containers/io.playcover.PlayCover/Applications/com.tencent.ngr.app/NGR`
- 当前 locator 脚本：[pdt005_ngr_convert_to_platform_path_locator.py](/Users/songdogwang/Codes/PlayCover/Scripts/pdt005_ngr_convert_to_platform_path_locator.py)
- 当前长期文档：[RIPC-010-真机materializer采集与双端对比.md](/Users/songdogwang/Codes/PlayCover/LocalDocs/HOKCrash/RealIPadCompare/RIPC-010-真机materializer采集与双端对比.md)

### 执行命令

```bash
python3 /Users/songdogwang/Codes/PlayCover/Scripts/pdt005_ngr_convert_to_platform_path_locator.py --binary-path /Users/songdogwang/Library/Containers/io.playcover.PlayCover/Applications/com.tencent.ngr.app/NGR --output /Users/songdogwang/Codes/PlayCover/build/pdt-005-current-installed.json
```

命令输出摘要：

```text
report written: /Users/songdogwang/Codes/PlayCover/build/pdt-005-current-installed.json
summary: found 1 ADRP+ADD ref(s) to ['/var/', '/User'] across 1 literal(s)
  [/var/] adrp=0x107d009c4 add=0x107d009c8 branches=32 compares=6
```

随后对**旧锚点窗口**与**新定位窗口**做并排反汇编：

```bash
xcrun llvm-objdump --arch=arm64 --disassemble --start-address=0x10463f204 --stop-address=0x10463f244 /Users/songdogwang/Library/Containers/io.playcover.PlayCover/Applications/com.tencent.ngr.app/NGR
xcrun llvm-objdump --arch=arm64 --disassemble --start-address=0x107d00980 --stop-address=0x107d00ad0 /Users/songdogwang/Library/Containers/io.playcover.PlayCover/Applications/com.tencent.ngr.app/NGR
xcrun llvm-objdump --arch=arm64 --disassemble --start-address=0x1000a49e0 --stop-address=0x1000a4a60 /Users/songdogwang/Library/Containers/io.playcover.PlayCover/Applications/com.tencent.ngr.app/NGR
```

### 关键观察

1. `build/pdt-005-current-installed.json` 在当前 installed binary 中重新找到 `/var/` 相关窗口：
   - `adrpPc = 0x107d009c4`
   - `addPc = 0x107d009c8`
   - `targetVMAddr = 0x10bf8ac76`
2. 旧锚点 `0x10463f204` 的首条指令不是标准函数 prologue，而是：
   - `0x10463f204: b 0x1000a4a08`
3. `0x1000a4a08` 本身是一个 `/Users/` fast-path helper：
   - 从 `x1` 取字符串；
   - 按 UTF-16 宽字符逐段比较 `/Users/`；
   - 若完全匹配则直接 `ret`；
   - 否则落到 `0x1000a4a5c` 继续后续逻辑。
4. 这意味着当前硬编码 `PDT006_CONVERT_FUNC_UNSLID = 0x10463f204` 所打的 patch，语义上更接近“旧入口跳到 fast-path helper 之前的一个 branch site”，而不是**天然等同**于“当前 installed binary 中唯一/主导的 `ConvertToPlatformPath` 热路径入口”。

### 结论

本轮已经得到一个足够强的 `C1` 收紧结论：

- `pdt006_ngr_convert_patch status=installed` 目前**只能证明**旧锚点地址 `0x10463f204` 可写并成功替换成 `pdt006_convert_replacement`；
- 它**不能单独证明** failing `/Users/.../Saved/Paks/1/1.db` flow 一定会经过当前 replacement 的覆盖范围；
- 因此“没有 `pdt006_ngr_convert_call`”的第一解释，不应再直接写成“failing flow 没进 `ConvertToPlatformPath`”，而应先拆成：
  1. failing flow 没进 `ConvertToPlatformPath`；
  2. failing flow 进了 `ConvertToPlatformPath`，但不经过旧锚点 `0x10463f204` / `0x1000a4a08` 覆盖路径；
  3. failing flow 经过旧锚点覆盖路径，但 `x1` 形态与当前 UTF-8 `/Users/...` 假设不符。

### 对主线的直接影响

- `RIPC-010-C1` 仍保持当前默认主线。
- 但下一轮的**第一子任务**已经变化：
  - 不再是泛化地追问“有没有进 replacement”；
  - 而是先证明 failing flow 是否进入旧锚点 `0x10463f204` / `0x1000a4a08` 所覆盖的 `ConvertToPlatformPath` 路径。
- 只有在这一层覆盖范围被证明成立后，`pdt006_ngr_convert_call` 的 `pathPreview` / `pathBytesHex` / `matchesUsers` / `containsSavedPaks` / `looksUtf16UsersPrefix` / `normalized` 才能成为第一判读口径。

### 产物

- 新产物：`build/pdt-005-current-installed.json`
- 本次 execution note：[2026-04-30-120630-RIPC-010-C1-installed-binary-anchor-revalidation.md](/Users/songdogwang/Codes/PlayCover/LocalDocs/HOKCrash/RealIPadCompare/executions/2026-04-30-120630-RIPC-010-C1-installed-binary-anchor-revalidation.md)

### 未做事项

- 本轮**没有**修改 `PlayLoader.m` 代码。
- 本轮**没有**重新构建 `PlayTools` / `PlayCover`。
- 本轮**没有**重新跑 GUI live verify。

原因：当前更高价值的问题是先闭合“旧锚点是否仍覆盖 failing flow”，而这一步可以先通过离线 installed-binary 复核把问题空间显著缩小。