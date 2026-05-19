# Offline Shader Source Recovery — 任务面板

## 概述

**目标**：从运行时轻量提取 shader 调试信息（metallib + bitcode），后续离线进行反编译和 gputrace 修改，使 Xcode 打开 gputrace 时能显示原本缺失的 shader 源码。

**分两阶段**：
1. ✅ **PlayCover 改造**：添加轻量 "提取 shader 调试信息" 模式（已完成）
2. ⬜ **离线后处理**：反编译 IR、修改 gputrace 文件注入调试信息（研究中）

---

## Xcode 源码显示机制（核心认知）

Xcode 从 gputrace 的 `store0` 中读取 shader 源码。`store0` 是多段 zlib 压缩的数据存储，解压后包含：
- 所有被 app 使用的 **metallib 二进制**
- 对于 `makeLibrary(source:)` 路径的 metallib，其后紧跟一份**独立的源码文本 blob**

**关键事实**：
- 源码文本**不嵌入** metallib 二进制内部（metallib 的 `file_size` 字段之外）
- Xcode **不从 bitcode 反编译**源码（即使 metallib 含完整 LLVM bitcode，若无配套源码 blob 则显示 "source not found"）
- gputrace 中的 sidecar 文件（hex ID 命名的 .metal 文件）**不是** Xcode 显示源码的来源，替换其内容不影响显示
- `makeLibrary(data:)` 路径的 metallib 在 store0 中只存储了 metallib 本身，没有配套源码 blob

**结论**：要让 Xcode 显示源码，唯一可靠的方式是在截帧时让 shader 走 `makeLibrary(source:)` 路径，或者离线修改 store0 注入源码 blob。

---

## 阶段一：轻量提取模式（已完成）

### 新增开关

| 开关名 | 设置键 | 默认值 | 说明 |
|--------|--------|--------|------|
| 提取 Shader 调试信息 | `shaderDebugInfoExtractionEnabled` | `false` | 运行时提取 metallib + bitcode，不干涉渲染行为 |
| Shader 源码替换 | `shaderSourceReplacementEnabled` | `true` | 完整的 hook + 反编译 + 替换链路（已有） |

两个开关独立生效：
- **仅 extraction**：只保存数据，不做反编译/替换，零运行时干扰
- **仅 replacement**：原有的完整链路
- **两者都开**：保存数据 + 尝试替换
- **两者都关**：不安装 hook 逻辑（直接返回原始 library）

### 修改的文件

| 文件 | 变更 |
|------|------|
| `Carthage/Checkouts/PlayTools/PlayTools/PlaySettings.swift` | 新增 `shaderDebugInfoExtractionEnabled` 字段和 lazy 属性 |
| `Carthage/Checkouts/PlayTools/PlayTools/LibrarySourceInjectionSwizzles.swift` | 新增 `extractAndSaveDebugInfo()` 方法；修改 `attemptReplacementForMetallibData()` 支持新模式 |
| `Carthage/Checkouts/PlayTools/PlayTools/PlayCover.swift` | 在启动诊断中记录新开关状态 |
| `PlayCover/Model/AppSettings.swift` | 新增 `shaderDebugInfoExtractionEnabled` 字段及解码 |
| `PlayCover/Views/AppSettingsView.swift` | 新增 Toggle UI |
| `PlayCover/en.lproj/Localizable.strings` | 英文翻译 |
| `PlayCover/zh-Hans.lproj/Localizable.strings` | 中文翻译 |
| `Scripts/set_shader_replacement_mode.py` | 支持 `--mode extraction` 参数 |

### 输出数据结构

```
~/Library/Containers/io.playcover.PlayCover/ShaderDebugInfo/<bundleId>/
  └── <cacheKey>/                      # 以 metallib 指纹为目录名
      ├── library.metallib             # 原始 metallib 二进制
      ├── extraction.meta.json         # 元数据 (bundleId, selector, timestamp, 函数名列表等)
      └── modules/
          └── <sha256>/                # 以 bitcode SHA256 为子目录名
              ├── module.bc            # 原始 LLVM bitcode
              └── module.meta.json     # 模块元数据 (函数名, 类型, 大小等)
```

### 验证结果

- 恋与深空 (`com.papegames.lysk`) 以 extraction 模式运行
- 成功提取 **154 个 metallib** 及其 bitcode 模块
- 总数据量 ~4.5MB（metallib 1.7MB + bitcode 1.6MB + 元数据）
- 应用运行正常，无崩溃，无渲染异常
- 运行时诊断日志正确记录了开关状态

---

## 阶段二：离线后处理（研究中）

### 已完成

**注入 IR 增强的 shader stub 到 gputrace sidecar**：

脚本 `LocalDocs/OfflineSourceRecovery/scripts/inject_shader_debug_info.py` 实现了：
1. 读取 ShaderDebugInfo 中的 bitcode 模块
2. 离线使用 `llvm-dis` 反汇编为 LLVM IR 文本
3. 生成注释增强的 .metal stub 文件（包含完整 IR + 资源列表 + MSL 编译桩）
4. 放入 gputrace bundle 的 sidecar 位置

**注意**：这些 sidecar 文件无法让 Xcode 显示源码（因为 Xcode 不从 sidecar 读取源码），但仍可作为人工参考使用。

**生成文件格式示例**：
```metal
// === PlayCover Shader Debug Info ===
// Pipeline: 1005856DD0954091
// Function: xlatMtlMain
// Type: fragment
// Selector: newLibraryWithData:error:
// MetallibCacheKey: 04DEF5F04015AEEC_23809
// Structs: AsukaPerShader_PerCamera_Type, UnityPerMaterial_Type, ...
// Resources: _MainTex, _NormalMap, _ScreenShadowTexture, unity_SpecCube0
// Intrinsics: air.sample_texture_2d, air.fma, air.dot, ...
//
// === LLVM IR BEGIN ===
// ; ModuleID = 'xlatMtlMain'
// target triple = "air64_v24-apple-ios15.0.0"
// define <{ <4 x half>, half }> @xlatMtlMain(...) {
//   %43 = call { <4 x half>, i8 } @air.sample_texture_2d.v4f16(...)
//   ...
// }
// === LLVM IR END ===

#include <metal_stdlib>
using namespace metal;

fragment half4 xlatMtlMain(float4 position [[position]]) {
    return half4(1.0h, 0.0h, 1.0h, 1.0h); // magenta = placeholder
}
```

### 可行攻坚方向

#### 方向 A: 运行时截帧时启用源码替换模式（最直接）

PlayCover 已有的 `shaderSourceReplacementEnabled` 模式会拦截 `makeLibrary(data:)` → 反编译 bitcode 为 MSL → 通过 `makeLibrary(source:)` 重新编译。如果在截帧时启用此模式，Xcode 截帧引擎会自动保存源码到 store0，后续打开 gputrace 即可看到源码。

**优势**：完全利用 Xcode 原生机制，无需破解 gputrace 格式
**代价**：运行时性能开销；反编译的 MSL 可能含错误导致部分 shader 编译失败

#### 方向 B: 离线修改 store0 注入源码 blob

解压 store0 → 在 metallib 后插入源码 blob → 更新所有引用偏移 → 重新压缩写回。

**挑战**：需要完全理解 store0 的 blob 索引/引用机制

#### 方向 C: 研究 Xcode "Import Sources" 功能

Xcode "Shader source not found" 对话框有 "Import Sources" 按钮，研究其工作方式。

### 当前限制

- **Pipeline ID ↔ metallib 映射不精确**：当前按顺序填充，不保证对应关系正确
- **需要运行时收集映射**：后续需在 hook 中记录每个 `makeLibrary` 返回的 library 对象地址与 metallib cacheKey 的关联
- **IR → MSL 反编译**：没有公开的 AIR bitcode → MSL 反编译工具，需自行实现 `IRToMSLConverter` 或利用 Xcode 私有能力

### 相关 gputrace

- 位置：`/Users/songdogwang/Library/Containers/com.papegames.lysk/Data/Documents/Captures/capture_20260518_110050.gputrace`
- ShaderDebugInfo：`~/Library/Containers/io.playcover.PlayCover/ShaderDebugInfo/com.papegames.lysk/`

---

## 命令参考

```bash
# 设置为 extraction 模式
python3 Scripts/set_shader_replacement_mode.py --bundle-id com.papegames.lysk --mode extraction

# 设置为完整 replacement 模式
python3 Scripts/set_shader_replacement_mode.py --bundle-id com.papegames.lysk --mode on

# 关闭所有 shader 处理
python3 Scripts/set_shader_replacement_mode.py --bundle-id com.papegames.lysk --mode off

# 构建全量
./BuildScripts/build_all.sh

# 同步 PlayTools 到系统
rm -rf ~/Library/Frameworks/PlayTools.framework
cp -R build/Build/Products/Release/PlayCover.app/Contents/Frameworks/PlayTools.framework ~/Library/Frameworks/PlayTools.framework

# 注入 IR 增强源码到 gputrace（sidecar，仅供人工参考）
python3 LocalDocs/OfflineSourceRecovery/scripts/inject_shader_debug_info.py \
    --gputrace /path/to/capture.gputrace \
    --debug-info ~/Library/Containers/io.playcover.PlayCover/ShaderDebugInfo/com.papegames.lysk

# 注入前先预览（dry-run + 输出到单独目录）
python3 LocalDocs/OfflineSourceRecovery/scripts/inject_shader_debug_info.py \
    --gputrace /path/to/capture.gputrace \
    --debug-info ~/Library/Containers/io.playcover.PlayCover/ShaderDebugInfo/com.papegames.lysk \
    --dry-run --max-inject 5 --output-dir /tmp/preview
```
