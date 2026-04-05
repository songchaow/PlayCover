## E-003: `makeLibrary` swizzle 骨架与采集入口

## 状态：✅ DONE

## 当前定位

E-003 已经完成"能 hook 到 `MTLDevice.makeLibrary(...)` 系列 API"这一基础目标。随着 Road E 主流程转向**离线优先**，E-003 的定位也从"单纯 log-only 骨架"升级为：

**所有后续 shader corpus 采集能力的统一入口。**

也就是说，E-003 现在的价值不是继续扩展 swizzle 技巧本身，而是回答两个问题：

1. 哪些 Library API 入口已经被 hook？
2. 哪些入口已经真正进入了 `metallib -> bitcode -> IR -> MSL` 主链路，哪些还只是日志？

## 已有实现

### 文件结构

| 文件 | 说明 |
|---|---|
| `Carthage/Checkouts/PlayTools/PlayTools/LibrarySourceInjectionSwizzles.swift` | 核心实现：swizzle 方法 + `LibrarySourceInjectionService` |
| `Carthage/Checkouts/PlayTools/PlayTools/PlayCover.swift` | 启动时安装 hook |

### 当前 hook 的 API 列表

#### 第一批：真实 shader 采集相关入口

| # | ObjC Selector | 当前状态 | 备注 |
|---|---|---|---|
| 1 | `newLibraryWithData:error:` | **已接入主链路** | 当前最关键入口；已进入 bitcode 提取、IR 反汇编、MSL 转换与替换 |
| 2 | `newLibraryWithURL:error:` | **已接入主链路** | 已在代码路径上读取 `.metallib` 并复用统一 corpus 导出 / 替换逻辑 |
| 3 | `newDefaultLibrary` | **已接入主链路** | 已通过 bundle 内默认 `.metallib` 定位逻辑接入统一导出链路 |
| 4 | `newDefaultLibraryWithBundle:error:` | **已接入主链路** | 同上 |
| 5 | `newLibraryWithFile:error:` | **已接入主链路** | 兼容旧路径，并复用统一导出 / 替换逻辑 |

#### 第二批：源码或辅助路径

| # | ObjC Selector | 当前状态 | 备注 |
|---|---|---|---|
| 6 | `newLibraryWithSource:options:error:` | 已 hook，日志 / 回编译使用 | 主要用于 `makeLibrary(source:)` 重编译 |
| 7 | `newLibraryWithSource:options:completionHandler:` | 已 hook，日志 / 回编译使用 | 异步版本 |

## 在新流程中的角色

### 角色 1：真实世界采集面

E-003 决定了我们能从哪些真实 runtime API 入口观察到 shader 加载行为。对于离线优先流程，它的核心意义是：

- **让真实 app 成为 corpus 生产器**
- 而不是只作为一个现场调试环境

### 角色 2：覆盖率边界定义

截至 2026-04-04，`newLibraryWithData:error:` 与 `URL/default/file` 入口都已真正进入主链路，这意味着：

- 我们当前的 corpus 覆盖边界已经不再只受单一 selector 限制
- 后续 coverage boundary 更主要取决于真实 app 在 live 中是否命中这些入口，以及 default 路径的 bundle `.metallib` 定位是否与目标 app 的打包方式一致

因此 E-003 仍然是 **coverage boundary** 文档：它现在更关注"哪些入口已经接通、哪些还需要真实样本验证"，而不再只是解释为什么 corpus 只来自 `data` 路径。

### 角色 3：后续 E-004f 的扩展起点

后续若要做"成功路径全量导出 corpus"，最自然的扩展顺序是：

1. 继续把 `newLibraryWithData:error:` 打磨成稳定导出主路径
2. 再逐步把 `URL/default/file` 路径纳入同样的提取 / 导出逻辑
3. 最后再看是否需要处理更少见的 stitched / source 路径

## 结论

- E-003 已经证明 swizzle 面是够用的，当前瓶颈**不在 hook 能不能装上**
- 五大真实加载入口已全部接入统一导出 / 替换链路
- 后续更值得投入的是验证真实 app 命中情况，而不是继续停留在文档层面的 selector 讨论
