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

## 阶段二：离线后处理（待实施）

目标：在截帧完成后，利用阶段一提取的数据：
1. 离线使用 `llvm-dis` 将 bitcode 反汇编为 LLVM IR
2. 使用 IRToMSLConverter 或其他工具将 IR 转换为 MSL
3. 修改 `.gputrace` 文件，注入 shader 源码/调试信息
4. 使 Xcode 打开 gputrace 时能显示 shader 源码

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
```
