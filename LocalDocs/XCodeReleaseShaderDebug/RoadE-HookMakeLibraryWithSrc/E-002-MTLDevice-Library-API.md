## E-002: `MTLDevice` Library API 入口与 corpus 覆盖优先级

## 状态：✅ DONE（结论保留，组织方式重写）

## 文档目的

E-002 的原始结论没有变化：我们已经识别出 `MTLDevice` 创建 `MTLLibrary` 的主要 API 入口，并据此完成了 E-003 的 swizzle 骨架。

随着 Road E 转向**离线优先**，本文件的重点也从"列全 API 名单"变成：

1. **哪些入口决定真实 shader corpus 的覆盖面**
2. **哪些入口已经被纳入主链路，哪些还只是日志**
3. **后续若要提高离线 corpus 完整性，应该先补哪些 selector**

## 完整入口清单

### 真实加载 metallib 的核心 API

| # | Swift API | ObjC Selector | 当前离线价值 | 备注 |
|---|---|---|---|---|
| 1 | `makeLibrary(data:)` | `newLibraryWithData:error:` | **P0：最高** | 当前最常见，也已真正进入 `metallib -> bitcode -> IR -> MSL` 主链路 |
| 2 | `makeLibrary(URL:)` | `newLibraryWithURL:error:` | **P1：高** | 已在代码路径上读取 `.metallib` 并接入统一导出 / 替换链路；后续重点是确认真实命中率 |
| 3 | `makeDefaultLibrary()` | `newDefaultLibrary` | **P1：高** | 已接入统一导出链路；当前通过 bundle 显式名称 + 资源扫描保守定位默认 `.metallib` |
| 4 | `makeDefaultLibrary(bundle:)` | `newDefaultLibraryWithBundle:error:` | **P1：高** | 同上 |
| 5 | `makeLibrary(filepath:)` *(deprecated)* | `newLibraryWithFile:error:` | **P1：中** | 兼容旧路径，已复用统一导出 / 替换逻辑 |

### 已有源码或辅助路径

| # | Swift API | ObjC Selector | 当前离线价值 | 备注 |
|---|---|---|---|---|
| 6 | `makeLibrary(source:options:)` | `newLibraryWithSource:options:error:` | P2：低 | 主要服务于我们自己重编译生成的 MSL |
| 7 | `makeLibrary(source:options:completionHandler:)` | `newLibraryWithSource:options:completionHandler:` | P2：低 | 异步版本 |
| 8 | `makeLibrary(stitchedDescriptor:)` | `newLibraryWithStitchedDescriptor:error:` | P3：观察即可 | 目前不是 Road E 主路径 |
| 9 | `makeLibrary(stitchedDescriptor:completionHandler:)` | `newLibraryWithStitchedDescriptor:completionHandler:` | P3：观察即可 | 异步版本 |

### 不需要作为主采集面的动态库 API

| Swift API | ObjC Selector | 说明 |
|---|---|---|
| `makeDynamicLibrary(library:)` | `newDynamicLibrary:error:` | 对已有 `MTLLibrary` 的封装，不是原始 shader 入口 |
| `makeDynamicLibrary(url:)` | `newDynamicLibraryWithURL:error:` | 同上 |

## 当前实现与覆盖状态

### 已完成

- 已识别完整 API 集合
- 已确认 selector 分布在 GPU family 层与 `_MTLDevice` 层，但统一用 `object_getClass(device)` 安装 swizzle 即可
- E-003 已对关键入口完成 hook

### 当前真正进入主链路的入口

- **`newLibraryWithData:error:`**
- **`newLibraryWithURL:error:`**
- **`newDefaultLibrary`**
- **`newDefaultLibraryWithBundle:error:`**
- **`newLibraryWithFile:error:`**

它们现在都已具备或复用了以下能力：
- metallib / payload 转 `Data`
- bitcode 提取
- `llvm-dis`
- `IRToMSLConverter`
- `makeLibrary(source:)` 替换
- `ShaderCorpus/` 导出

这意味着：

**当前离线 corpus 的覆盖范围已经不再只受限于 `newLibraryWithData:error:` 的真实命中率，而是取决于真实 app 是否会命中这些入口以及 default 路径的 bundle `.metallib` 解析是否与目标包体一致。**

## 结论

E-002 的核心结论仍然成立：Library API 入口已经被识别清楚，且 **全部真实加载入口已接入统一导出 / 替换 / corpus 链路**。

当前 corpus 覆盖边界不再受 selector 限制，而取决于真实 app 是否会稳定命中这些入口、default 路径的 bundle `.metallib` 定位是否与目标包体一致。
