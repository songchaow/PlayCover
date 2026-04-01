# E-003: 在 PlayTools 中实现 makeLibrary swizzle 骨架

## 状态：✅ DONE

## 目标

参考 `CommandQueueDiscoverySwizzles` 模式，添加 `LibrarySourceInjectionSwizzles` 类，拦截并记录每次 makeLibrary 调用（先 log-only，不修改返回值）。

## 实现方案

### 文件结构

| 文件 | 说明 |
|------|------|
| `Carthage/Checkouts/PlayTools/PlayTools/LibrarySourceInjectionSwizzles.swift` | 核心实现：swizzle 方法 + 安装服务 |
| `Carthage/Checkouts/PlayTools/PlayTools/PlayCover.swift` | 修改：在 `launch()` 中调用安装 |
| `Carthage/Checkouts/PlayTools/PlayTools.xcodeproj/project.pbxproj` | 修改：添加新文件引用 |

### 架构设计

1. **`LibrarySourceInjectionSwizzles`**（private final class）
   - 与 `CommandQueueDiscoverySwizzles` 完全一致的模式
   - 包含 7 个 `@objc dynamic` swizzle 替换方法
   - swizzle 后 `self` 指向 MTLDevice 实例

2. **`LibrarySourceInjectionService`**（class，singleton）
   - `installIfNeeded()`：通过 `object_getClass(device)` 获取设备类，安装所有 swizzle
   - `logLibraryCreation()`：统一日志记录，输出 selector、device 类、library 类、label、函数数量等
   - `statisticsSummary()`：返回调用统计摘要

### Hook 的 API 列表

**第一批（必须 hook）**——从 metallib 数据创建的主要路径：

| # | ObjC Selector | 替换方法 |
|---|---|---|
| 1 | `newLibraryWithData:error:` | `pc_newLibraryWithData(_:error:)` |
| 2 | `newLibraryWithURL:error:` | `pc_newLibraryWithURL(_:error:)` |
| 3 | `newDefaultLibrary` | `pc_newDefaultLibrary()` |
| 4 | `newDefaultLibraryWithBundle:error:` | `pc_newDefaultLibraryWithBundle(_:error:)` |
| 5 | `newLibraryWithFile:error:` | `pc_newLibraryWithFile(_:error:)` |

**第二批（仅日志）**——源码编译路径：

| # | ObjC Selector | 替换方法 |
|---|---|---|
| 6 | `newLibraryWithSource:options:error:` | `pc_newLibraryWithSource(_:options:error:)` |
| 7 | `newLibraryWithSource:options:completionHandler:` | `pc_newLibraryWithSourceAsync(_:options:completionHandler:)` |

### 初始化时机

在 `PlayCover.launch()` 中，紧跟 `MetalCaptureService.shared.initialize()` 之后调用：

```swift
LibrarySourceInjectionService.shared.installIfNeeded()
```

无需额外的开关控制——当前阶段仅输出日志，性能影响极小。

### 日志格式

```
[PlayTools] LibrarySourceInjection: sel=newLibraryWithData:error:, device=AGXG16SDevice, library=AGXGxxFamilyMTLLibrary, label=nil, functions=42, call#1/total#1, dataSize=12345
```

## 验证

- PlayTools xcframework 构建通过（`BUILD SUCCEEDED`）
- pbxproj 格式验证通过（`plutil -lint`）
- 运行时验证需等 E-004/E-005 完成后在实际 app 上测试

## 后续 E-004 衔接点

E-004 需要在 `pc_newLibraryWithData(_:error:)` 中添加：
1. 从 `dispatch_data_t` 提取 metallib 二进制
2. 解析 metallib 格式，提取 LLVM Bitcode / MSL 源码
3. 将提取的源码存储以供 E-005 重编译使用
