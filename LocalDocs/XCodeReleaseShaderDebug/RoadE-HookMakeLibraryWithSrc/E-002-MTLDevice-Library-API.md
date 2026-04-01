# E-002: MTLDevice 创建 Library 的全部 API 入口

## 状态：✅ DONE

## 调研方法

1. 查阅 Apple Developer Documentation — `MTLDevice` protocol
2. 通过 ObjC runtime 枚举 `MTLDevice` 协议的 required/optional 方法
3. 对运行时设备类执行 `responds(to:)` 和 `class_getInstanceMethod` 验证
4. 沿类继承链定位每个 selector 的实际实现类

## MTLDevice 协议中的 Library 创建 API 完整列表

### 核心 API（需要 hook）

| # | Swift API | ObjC Selector | Type Encoding | 优先级 | 说明 |
|---|---|---|---|---|---|
| 1 | `makeLibrary(data:)` | `newLibraryWithData:error:` | `@32@0:8@16^@24` | 🔴 最高 | 从 metallib 二进制数据创建，**App 最常用的方式** |
| 2 | `makeLibrary(source:options:)` | `newLibraryWithSource:options:error:` | - | 🟡 中 | 从 MSL 源码编译，源码已有不需注入 |
| 3 | `makeLibrary(source:options:completionHandler:)` | `newLibraryWithSource:options:completionHandler:` | - | 🟡 中 | 异步版本，源码已有不需注入 |
| 4 | `makeLibrary(URL:)` | `newLibraryWithURL:error:` | - | 🔴 高 | 从 URL 加载 metallib |
| 5 | `makeDefaultLibrary()` | `newDefaultLibrary` | - | 🔴 高 | 从 App Bundle 加载默认 metallib |
| 6 | `makeDefaultLibrary(bundle:)` | `newDefaultLibraryWithBundle:error:` | - | 🔴 高 | 从指定 Bundle 加载 metallib |
| 7 | `makeLibrary(filepath:)` *(deprecated)* | `newLibraryWithFile:error:` | - | 🟢 低 | 已废弃，但部分旧 App 仍使用 |
| 8 | `makeLibrary(stitchedDescriptor:)` | `newLibraryWithStitchedDescriptor:error:` | - | 🟢 低 | Function Stitching API（iOS 15+） |
| 9 | `makeLibrary(stitchedDescriptor:completionHandler:)` | `newLibraryWithStitchedDescriptor:completionHandler:` | - | 🟢 低 | 异步版本 |

### 动态库 API（不需要 hook）

| Swift API | ObjC Selector | 说明 |
|---|---|---|
| `makeDynamicLibrary(library:)` | `newDynamicLibrary:error:` | 从已有 MTLLibrary 创建动态库 |
| `makeDynamicLibrary(url:)` | `newDynamicLibraryWithURL:error:` | 从 URL 加载动态库 |

> Dynamic Library 本质是对已编译 Library 的封装，不直接加载 metallib 数据，不需要 hook。

## 运行时类信息

### 设备类继承链（Apple M4 Pro）

```
AGXG16SDevice
  → AGXG16XFamilyDevice
    → IOGPUMetalDevice
      → _MTLDevice
        → NSObject
```

> **注意**：不同 GPU 型号的类名不同（如 M1=`AGXG13GDevice`，M2=`AGXG14SDevice`），
> 但 swizzle 通过 `object_getClass(device)` 动态获取，不硬编码类名。
> 这与现有 `CommandQueueDiscoverySwizzles` 的做法一致。

### 方法定义位置

| Selector | 定义类 |
|---|---|
| `newLibraryWithData:error:` | `AGXG16XFamilyDevice`（GPU Family 层） |
| `newLibraryWithSource:options:error:` | `AGXG16XFamilyDevice` |
| `newLibraryWithSource:options:completionHandler:` | `AGXG16XFamilyDevice` |
| `newLibraryWithURL:error:` | `_MTLDevice`（Metal 框架层） |
| `newDefaultLibrary` | `AGXG16XFamilyDevice` |
| `newDefaultLibraryWithBundle:error:` | `_MTLDevice` |
| `newLibraryWithFile:error:` | `AGXG16XFamilyDevice` |
| `newLibraryWithStitchedDescriptor:error:` | `_MTLDevice` |
| `newLibraryWithStitchedDescriptor:completionHandler:` | `_MTLDevice` |

> 方法分布在 GPU family 层和 Metal 框架层，但 `class_getInstanceMethod(deviceClass, sel)` 
> 能沿继承链自动找到，所以 swizzle 目标类统一用 `object_getClass(device)` 即可。

## E-003 Hook 策略建议

### 第一批（必须 hook）

这些是 App 从 metallib 数据创建 Library 的主要路径：

1. **`newLibraryWithData:error:`** — App 内嵌 metallib，通过 NSData 加载（最常见）
2. **`newLibraryWithURL:error:`** — 从文件 URL 加载 metallib
3. **`newDefaultLibrary`** — 从 App Bundle 的默认 metallib 加载
4. **`newDefaultLibraryWithBundle:error:`** — 从指定 Bundle 加载
5. **`newLibraryWithFile:error:`** — 从文件路径加载（已废弃但部分 App 仍用）

### 第二批（可选 hook / 仅日志）

6. **`newLibraryWithSource:options:error:`** — 源码编译，源码已有（仅需日志记录）
7. **`newLibraryWithSource:options:completionHandler:`** — 异步源码编译
8. **`newLibraryWithStitchedDescriptor:error:`** — Stitching API（少见）
9. **`newLibraryWithStitchedDescriptor:completionHandler:`** — 异步 Stitching

### Swizzle 实现要点

1. **目标类获取**：`let deviceClass = object_getClass(MTLCreateSystemDefaultDevice()!)!`
   - 与现有 `installQueueDiscoveryIfNeeded()` 模式完全一致
2. **方法签名匹配**：用 `NSSelectorFromString()` 指定 selector，`class_getInstanceMethod` 找方法
3. **返回值类型**：所有同步方法返回 `AnyObject?`（即 `id _Nullable`），符合现有 swizzle 模式
4. **异步方法处理**：completionHandler 版本的 hook 需要包装 callback
5. **`self` 语义**：swizzle 后 `self` 指向 MTLDevice 实例，与 `CommandQueueDiscoverySwizzles` 一致

### 注意事项

- `makeLibrary(source:options:)` 的 hook 策略不同：不需要注入源码（已有源码），但可以记录日志
- `newLibraryWithURL:error:` 和 `newDefaultLibrary` 底层可能调用 `newLibraryWithData:error:`，
  需要实测是否会重复触发。如果重复，可以在 hook 中用 data hash 去重
- `newLibraryWithStitchedDescriptor:` 是 Function Stitching API（iOS 15+ / macOS 12+），
  用于组合 visible function table，较少见但理论上也需要覆盖
