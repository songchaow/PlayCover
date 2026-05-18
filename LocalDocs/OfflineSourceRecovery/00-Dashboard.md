# Offline Shader Source Recovery — 任务面板

## 概述

**目标**：从运行时轻量提取 shader 调试信息（metallib + bitcode），后续离线进行反编译和 gputrace 修改。

**分两阶段**：
1. ✅ **PlayCover 改造**：添加轻量 "提取 shader 调试信息" 模式（已完成）
2. ⬜ **离线后处理**：反编译 IR、修改 gputrace 文件注入调试信息（待实施）

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

## 阶段二：离线后处理（进行中）

### 已完成

**注入 IR 增强的 shader stub 到 gputrace**：

脚本 `LocalDocs/OfflineSourceRecovery/scripts/inject_shader_debug_info.py` 实现了：
1. 读取 ShaderDebugInfo 中的 bitcode 模块
2. 离线使用 `llvm-dis` 反汇编为 LLVM IR 文本
3. 生成注释增强的 .metal stub 文件（包含完整 IR + 资源列表 + MSL 编译桩）
4. 注入到 gputrace bundle 中缺失源码的 pipeline 位置

**注入结果**：
- 对 `capture_20260518_110050.gputrace` 注入了 154 个 shader stub
- 每个文件包含：元数据头 + 结构体定义 + 纹理/Buffer 列表 + 完整 LLVM IR + MSL stub
- gputrace 中源码文件从 23 增加到 177

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

### 当前限制

- **Pipeline ID ↔ metallib 映射不精确**：当前按顺序填充，不保证对应关系正确
- **需要运行时收集映射**：后续需在 hook 中记录每个 `makeLibrary` 返回的 library 对象地址或 pipeline hash 与 metallib cacheKey 的关联
- **剩余 1576 个 pipeline 无源码**：index 中有 1730 个缺失，目前只注入了 154 个

### 后续计划

1. 在运行时 hook 中收集 pipeline hex ID → metallib 的精确映射
2. 实现 IR → MSL 的离线反编译（可复用 IRToMSLConverter）
3. 用真实 MSL 替换 stub，使 Xcode 能 Apply 修改后的 shader

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

# 注入 IR 增强源码到 gputrace
python3 LocalDocs/OfflineSourceRecovery/scripts/inject_shader_debug_info.py \
    --gputrace /path/to/capture.gputrace \
    --debug-info ~/Library/Containers/io.playcover.PlayCover/ShaderDebugInfo/com.papegames.lysk

# 注入前先预览（dry-run + 输出到单独目录）
python3 LocalDocs/OfflineSourceRecovery/scripts/inject_shader_debug_info.py \
    --gputrace /path/to/capture.gputrace \
    --debug-info ~/Library/Containers/io.playcover.PlayCover/ShaderDebugInfo/com.papegames.lysk \
    --dry-run --max-inject 5 --output-dir /tmp/preview
```
