# PDT-006: `ConvertToPlatformPath` Runtime Patch Prototype

> **何时读**：需要复现或审计 PDT-006 的机器码 patch 实现细节时阅读。
> **不维护任务状态**；进度与优先级只在 `00-Dashboard.md` 维护。

## Patch 目标

- **函数**：`FIOSPlatformFile::ConvertToPlatformPath`
- **NGR 二进制地址**：`0x10463f204`（边界 `0x10463f204..0x10463ff48`）
- **Patch 位置**：函数入口前 16 字节
- **Patch 大小**：16 字节

## 核心思路

在 `ConvertToPlatformPath` 入口处插入一个 16 字节的 absolute-branch hook：

```
ldr x16, #8
br  x16
.quad &pdt006_convert_replacement
```

该 hook 将控制流重定向到 PlayTools 内部的 `pdt006_convert_replacement` C 函数。该函数检查 `x1`（`const TCHAR* Filename`）是否以 `/Users/` 开头：

- **若匹配**：直接返回 `x1`，跳过 UE4 内部所有 `ReplaceInline("../")`、`ReplaceInline("..")`、`ReplaceInline(BaseDir, "")`、`AdditionalRootDirectory` 循环以及 `NSSearchPathForDirectoriesInDomains` 重拼接逻辑。这等价于 iOS 真机上 `/var/...` 的透传行为。
- **若不匹配**：通过 `mmap` 分配的 exec page 执行原始函数前 16 字节 prologue，再跳转回 `0x10463f204 + 16` 继续正常逻辑。

## 可逆性

1. 安装前将原 16 字节保存到 `pdt006_original_bytes[16]`。
2. `mmap` 分配的可执行页包含原始 16 字节 + 跳回原函数的 trampoline。
3. 若需卸载，只需把 `pdt006_original_bytes` 写回目标地址并 `munmap` exec page 即可。
4. 当前实现未提供运行时卸载函数，但保留所有原始数据，卸载逻辑可在未来需要时 10 行代码内补完。

## Bundle-Scoped 与安全性

- **Gate**：复用 `pt_ngr_should_preheat_slot()`（检查 `CFBundleGetMainBundle()` 的 identifier 是否为 `com.tencent.ngr`）。
- **主 image 校验**：复用 HOK-013 的 `pt_ngr_find_main_image()` + `__TEXT.vmaddr` 校验（`unslidTextVMAddr == 0x100000000`），防止 NGR 重链接后地址漂移。
- **写保护**：使用已有的 `pt_ngr_make_patch_writable()`（`mprotect` / `vm_protect` 双 fallback）解除 `__TEXT` 写保护，patch 后调用 `pt_ngr_restore_patch_protection()` 恢复 `R-X`。
- **指令缓存**：每次 patch 后调用 `sys_icache_invalidate()` 刷新 AArch64 指令缓存。

## 代码落点

- **Patch 实现**：`Carthage/Checkouts/PlayTools/PlayTools/PlayLoader.m`
  - 常量：`PDT006_CONVERT_FUNC_UNSLID` / `PDT006_PATCH_SIZE`
  - 核心函数：`pdt006_convert_replacement()` / `pdt006_install_convert_patch_once()`
  - 安装触发：`initialize()` constructor
- **诊断回调**：`Carthage/Checkouts/PlayTools/PlayTools/PlayCover.swift`
  - `recordPDT006ConvertPatchDiagnostic(details:)`

## 诊断事件

安装成功后会往 `launch-events.jsonl` 写入：

```jsonl
{"event":"pdt006_ngr_convert_patch","status":"installed","patchAddr":"...","slide":"...","detail":"ConvertToPlatformPath patched for /Users/ pass-through"}
```

失败事件：
- `main-image-not-found`
- `unexpected-text-vmaddr`
- `mprotect-failed`
- `mmap-failed`

## 已知限制与风险

1. **Prologue 假设**：假设 `0x10463f204` 开头 16 字节为标准 prologue（`sub sp` / `stp` / `add x29` 等），不含 PC-relative 指令（`adrp` / `b` / `bl` / `ldr literal` 等）。若该假设被未来 NGR 构建打破，exec page 上的复制指令会因 PC 偏移而行为异常。
2. **函数签名假设**：假设 `ConvertToPlatformPath` 的调用约定为 x0 = `this`, x1 = `const TCHAR*`。若编译器优化导致参数传递方式改变（如 `x0` 直接传字符串），透传逻辑可能检查错寄存器。当前代码对 `x1` 和 `x0` 都做了保守的 `/Users/` 检查（replacement 函数中只检查 `x1`；若需要可同时检查两者）。
3. **线程安全**：patch 在 `dispatch_once` 中执行，早于 NGR 主线程启动，无竞争。

## 产物

- 代码：`Carthage/Checkouts/PlayTools/PlayTools/PlayLoader.m`（PDT-006 区块）
- 代码：`Carthage/Checkouts/PlayTools/PlayTools/PlayCover.swift`（`recordPDT006ConvertPatchDiagnostic`）
- 构建：`Carthage/Build/PlayTools.xcframework/ios-arm64/PlayTools.framework`
