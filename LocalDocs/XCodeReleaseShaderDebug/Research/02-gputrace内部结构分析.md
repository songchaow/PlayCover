# 02 - `.gputrace` 内部结构分析

## 一、概述

`.gputrace` 是一个目录（macOS Bundle），Xcode 用它回放和调试一帧 GPU 工作负载。

## 二、文件清单（QQ飞车样本，651 个条目）

### 2.1 核心元数据

| 文件 | 类型 | 大小 | 说明 |
|---|---|---|---|
| `metadata` | Apple binary plist | ~1KB | 捕获会话元数据 |
| `index` | 自定义二进制 (`xdic`) | ~52KB | 所有资源的索引，引用源码 hash |
| `capture` | 自定义二进制 | 315KB | 帧命令流（含少量 MTLB 引用） |
| `store0` | zlib 压缩 | 2.8MB | 解压后 16KB，辅助数据 |

### 2.2 设备资源

| 文件 | 魔数 | 大小 | 说明 |
|---|---|---|---|
| `device-resources-0x15981c000` | `MTSP` | 1.7MB | **所有 Pipeline State 的二进制集合** |
| `unsorted-capture` | `MTSP` | 303KB | 未排序的捕获数据 |
| `unused-device-resources-0x15981c000` | — | — | 未使用的资源，**包含源码 hash 引用** |

### 2.3 GPU 资源快照

- `MTLBuffer-*`：GPU Buffer 数据快照（Uniform Buffer、Vertex Buffer 等）
- `MTLTexture-*-mipmap*-slice*`：纹理 mipmap 数据快照

### 2.4 Shader 源码文件（仅 3 个）

| 文件名（内容 hash） | 行数 | 大小 | 说明 |
|---|---|---|---|
| `204B066DC1C1F31C` | 490 | 40KB | Unity built-in MSL 源码 |
| `961E4C799865072F` | 483 | 41KB | Unity built-in MSL 源码 |
| `EA71C8E37DA79585` | 650 | 34KB | Unity built-in MSL 源码 |

这些是 Unity 编译 shader 时用 `-frecord-sources` 嵌入的少数 compute shader 源码（如天空盒、雾效处理）。
大量 render pipeline 的 shader 没有对应源码文件。

## 三、MTSP 格式初步分析

`device-resources` 文件以 `MTSP` (Metal Shader Pipeline?) 魔数开头：

```
00000000: 4d54 5350 0004 0000 3c00 0000 10d0 ffff  MTSP....<.......
```

内部结构包含：
- Pipeline State 描述符（render-pipeline-states, compute-pipeline-states）
- Buffer 绑定描述（vertexBuffer.0, vertexBuffer.1 ...）
- Uniform Block 引用（UnityPerDraw, UnityDrawCallInfo ...）
- shader 函数名引用（clear_vprog, clear_fshader ...）

**关键发现**：MTSP 中**不包含**独立的 `.metallib` 二进制（未找到 MTLB 魔数），Pipeline State 中存储的是已经编译到 GPU native code 的二进制，而非 Metal IR。

## 四、源码引用机制

在 `unused-device-resources` 中，源码通过以下结构引用：

```
offset  内容
------  -----
+0x00   "library" 标记
+0x08   源码 hash（如 "204B066DC1C1F31C"）
+0x19   关联 hash（如 "699E4F91CC182690"）
```

`index` 文件同样包含这些 hash 引用，用于将 Pipeline State 映射到源码文件。

## 五、关键结论

1. gputrace 中的 shader 二进制已经是 **GPU native code**（非 Metal IR/AIR）
2. 只有编译时加了 `-frecord-sources` 的 library 才有源码文件
3. 源码通过 content hash 命名和引用
4. `device-resources` 中不包含可提取的 `.metallib`，pipeline state 已经是最终编译形态
