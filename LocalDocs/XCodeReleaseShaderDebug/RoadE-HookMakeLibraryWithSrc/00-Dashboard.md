# Road E: Hook makeLibrary 注入 Shader 源码

## 问题背景

外网 Release 包体截帧后，Xcode 打开 `.gputrace` 时大部分 shader 显示 `Shader source not found`，因为原始 metallib 通常未嵌入源码或可用调试信息。

## 最终目标

在 PlayTools 运行时中 hook `MTLDevice.makeLibrary(data:)` 系列 API，从 metallib 中提取 LLVM Bitcode，经 `llvm-dis` 反汇编为 LLVM IR，再**逐指令翻译为语义等价的 MSL 源码**，通过 `makeLibrary(source:)` 重新编译并替换原始返回，使后续截帧的 `.gputrace` 自动携带 shader 源码。

**核心约束（按优先级）**：
1. **语义等价**：生成的 MSL 必须与原始 IR 逐指令语义等价
2. **可编译**：生成的 MSL 必须能通过 `makeLibrary(source:)` 编译，且函数签名与原始 metallib 一致
3. **可读性**：在满足 1、2 的前提下尽量提升

**技术路线**：采用逐指令机械翻译（方案 A）。LLVM 生态没有可直接用于 Metal AIR → MSL 的通用工具，因此当前方案仍以 `metallib → bitcode → llvm-dis → IR → MSL → makeLibrary(source:)` 为唯一主线。

## Agent 工作流

1. 读取本文档，先理解**当前主线**与 **TODO** 的最新状态
2. 从 **TODO** 中选取当前最高优先级的 **一个** 未完成任务执行
3. 若任务过大，先拆分到 TODO，再只完成其中一个
4. 只要动了 IR→MSL 转换逻辑，就尽量补测试数据并做实际验证
5. 执行完毕后更新本文档：结合最新情况，**简洁地整合**相关内容（尤其当前主线、TODO、验证、经验），保持前后一致，**不要只做追加**

> **严禁对着最终目标死磕，每个 agent 只完成一个任务。**

### IR→MSL 改动时的验证要求

仅在修改 `IRToMSLConverter` 或相关翻译逻辑时执行：

- 在 `test-data/` 下补对应 `.metal` / `.ll` 样本
- 用工具链确认目标 IR 模式确实出现
- 运行 `FORCE_PLAYTOOLS_REBUILD=1 ./BuildScripts/sync_playtools_xcframework.sh` 确认 PlayTools 编译通过

## 当前主线

- **E-005e**：识别 / 解包 `newLibraryWithData:error:` 中的**非原始 MTLB payload**
- **E-006**：继续真实样本验证，但当前优先服务于 `E-005e` 的定位，而不是盲目重复截帧

## 验证方式

**自动检查**：

```bash
Scripts/check_gputrace_sources.py /path/to/xxx.gputrace
```

脚本位置：`Scripts/check_gputrace_sources.py`

**注意**：hash 文件不全是源码——原神样本中的 hash 文件是 bplist，必须以 `valid_msl_files` 而非 `source_files` 为准。

**最新 live 样本**：

| 样本 | 结果 |
|---|---|
| 原神 6.4.0 外网包（2026-04-02） | `capture_metal_frame` 成功，`.gputrace` 已生成；`valid_msl=0`、`index 引用=875`，当前 blocker 为 `MetallibParser: unsupported metallib header size: 0` |

**人工确认（最终）**：Xcode 打开 `.gputrace` → 选 Draw Call → 查看 Shader 面板是否显示源码而非 `Shader source not found`。

## 整体架构

```
PlayCover 主应用 (macOS)
  ├── LLVMToolManager: 下载/管理 LLVM 预编译工具链 (llvm-dis)
  │     → 安装到 ~/Library/Containers/io.playcover.PlayCover/llvm-tools/
  └── PlayTools.framework (注入到 iOS app)
        ├── LibrarySourceInjectionSwizzles: hook makeLibrary 系列 API
        ├── MetallibParser: 解析 metallib, 提取 LLVM Bitcode
        ├── LLVMDisassembler: 调用 llvm-dis 将 bitcode → LLVM IR 文本
        ├── IRToMSLConverter: 将 LLVM IR 逐指令翻译为语义等价的 MSL 源码
        └── ShaderSourceRecompiler: 调 makeLibrary(source:) 编译 MSL, 替换原始 library
```

## TODO

| # | 任务 | 状态 | 子文档 |
|---|---|---|---|
| E-001 | **可行性 PoC：`-frecord-sources` 重编译验证** | ✅ DONE | [E-001-PoC](E-001-PoC-frecord-sources.md) |
| E-002 | **调研 MTLDevice Library API 入口** | ✅ DONE | [E-002-API](E-002-MTLDevice-Library-API.md) |
| E-003 | **makeLibrary swizzle 骨架** | ✅ DONE | [E-003-Swizzle](E-003-LibrarySwizzleSkeleton.md) |
| E-004 | **metallib → 源码提取** | 🔄 IN PROGRESS | [E-004](E-004-MetallibSourceExtraction.md) |
|  | E-004a–d 已完成：`MetallibParser`、bitcode 提取、`llvm-dis` 工具链、PlayTools 内 `llvm-dis` 调用均已落地 | | |
|  | E-004e 持续中：IR→MSL 主体已落地，`E-004e1/e2/e3/e4a/e4b/e4c/e4d` 均已完成；后续补洞以真实样本驱动，不再先验扩张范围 | | |
| E-005 | **运行时 library 替换：用带源码的 library 替换原始返回** | 🔄 IN PROGRESS | |
|  | 当前策略：优先建立“原始 `newLibraryWithData` 成功后，再尝试源码重编译并安全替换；任一步失败立即 fallback”的最小闭环 | | |
| E-005a | ↳ `newLibraryWithData` 最小闭环接线 | ✅ DONE | |
|  | 已在 `pc_newLibraryWithData` 主路径接入 `bitcode 提取 → llvm-dis → IRToMSLConverter → makeLibrary(source:)` 单次尝试；保留原始返回/错误语义，失败只记录日志并 fallback | | |
| E-005b | ↳ 多 bitcode module 的源码聚合策略 | TODO | |
|  | 当前仅在**单个 bitcode module** 场景尝试替换；多 module 先 fallback | | |
| E-005c | ↳ 替换前接口一致性校验 | TODO | |
|  | 对重编译后的 library 做函数名 / 数量 / 关键 metadata 对齐校验 | | |
| E-005d | ↳ 缓存与观测性 | TODO | |
|  | 以 metallib 内容或 bitcode 模块 `(offset,size)` / hash 为键缓存处理结果，并补充 success / fallback reason 日志 | | |
| E-005e | ↳ **非 MTLB `newLibraryWithData` payload 识别/解包** | 🔄 IN PROGRESS | |
|  | **当前最高优先级**。原神 6.4.0 live 验证表明：即使最新 GUI 与最新 PlayTools 已重新注入，`MetallibParser` 仍会对大量 `newLibraryWithData:error:` 输入报 `unsupported metallib header size: 0`。说明该入口收到的很多 payload **并非原始 `MTLB` metallib blob**，需先识别前导字节 / wrapper / archive / 上游调用路径，必要时补解包逻辑 | | |
| E-005e1 | ↳ `payload` 指纹 / 前导字节诊断日志 | ✅ DONE | |
|  | 已在 `pc_newLibraryWithData` 与 `MetallibParser.safeExtractBitcodeModules` 补充 `dispatch_data` 运行时类名、payload 前 16 字节 hex / ASCII、以及 `MTLB/bplist/zip/gzip/bzip2/llvm bitcode` 等格式指纹日志；`headerSize=0` 失败场景现在会直接带出摘要，便于下一轮 live 复现锁定真实 wrapper 形态 | | |
| E-005e1b | ↳ 非 `MTLB` payload 上游调用栈诊断 | ✅ DONE | |
|  | 已在 `pc_newLibraryWithData` 首次遇到某个非 `MTLB` payload 指纹时记录精简调用栈，并把 `selector` / `dispatch_data` 运行时类名 / `callStack[*]` 一并写入 `ShaderPayloadSamples` 元数据；下一轮 live 复现可以直接从日志或样本侧车文件反推上游入口 | | |
| E-005e2 | ↳ 基于真实 payload 样本实现解包 | 🔄 IN PROGRESS | |
|  | 已将任务拆分为“通用 wrapper 剥离 / 样本采集”与“定向格式解包”两步，先优先拿到可复现的真实 payload，而不是盲猜完整格式族 | | |
| E-005e2a | ↳ 通用 wrapper 剥离 + payload 样本落盘 | ✅ DONE | |
|  | 已在 `MetallibParser` 增加两级 fallback：1) 对 `bplist` 递归扫描嵌套 `Data` 中的原始或 embedded `MTLB`；2) 在原始 payload / 嵌套 `Data` 中扫描 embedded `MTLB` 并按 `fileSize` 裁剪。对未识别或已 recovered 的非 `MTLB` payload，会落盘到 `~/Library/Containers/io.playcover.PlayCover/ShaderPayloadSamples/<bundleId>/`（含 `.bin`、`.txt`，`bplist` 额外导出 `.plist`）供后续离线分析 | | |
| E-005e2a1 | ↳ 可疑 `mtlb_like` payload 二次剥离 + 样本保留 | ✅ DONE | |
|  | 已将 `MTLB` 前缀细分为“可直接解析的 raw metallib”和“`headerSize` / `fileSize` 明显异常的 `mtlb_suspicious`”；对后者不再直接短路，而是继续保留 origin / payload sample，并统一复用 `gzip` / `zip` / `xar` / `bplist` entry 的 embedded `MTLB` 扫描路径。这样像 `headerSize=15` 这类解包后仍带伪 `MTLB` 头的 payload，不会再因为前 4 字节命中 magic 就提前停止恢复 | | |
| E-005e2b | ↳ 基于样本补定向解包（`gzip` / `zip` / `xar` / 自定义 archive） | 🔄 IN PROGRESS | |
|  | 已拆分为按格式逐个落地，避免在缺真实样本前一次性铺太大范围 | | |
| E-005e2b1 | ↳ `gzip` payload 解包 + 递归恢复 | ✅ DONE | |
|  | 已在 `MetallibParser` 增加 `gzip` 解压路径（`zlib inflateInit2` 自动识别 `gzip/zlib` header），解压后会继续递归执行 `bplist` / embedded `MTLB` 剥离；支持 `gzip → MTLB`、`gzip → bplist → Data`、`gzip → wrapper → embedded MTLB` 等链路 | | |
| E-005e2b2 | ↳ `zip` / `xar` / 自定义 archive 定向解包 | 🔄 IN PROGRESS | |
|  | 已继续拆分为“`zip` 先落地、`xar` / 自定义 archive 等样本驱动”两步，避免在无真实 payload 时盲猜整套 archive 家族 | | |
| E-005e2b2a | ↳ `zip` payload 解包 + 递归恢复 | ✅ DONE | |
|  | 已在 `MetallibParser` 增加最小 ZIP reader：优先读取 central directory，失败再顺序扫描 local file header；支持 stored / deflate entry，并会对 entry data 继续递归执行 `MTLB` / `gzip` / `bplist` / embedded `MTLB` 恢复。已用 `FORCE_PLAYTOOLS_REBUILD=1 ./BuildScripts/sync_playtools_xcframework.sh` 做编译验证 | | |
| E-005e2b2b | ↳ `xar` / 自定义 archive 定向解包 | 🔄 IN PROGRESS | |
|  | 已拆分为“`xar` 最小 TOC/heap 解包”与“自定义 archive / keyed archive 样本驱动”两步，先把确定格式的 `xar` 路径接通 | | |
| E-005e2b2b1 | ↳ `xar` payload 解包 + 递归恢复 | ✅ DONE | |
|  | 已在 `MetallibParser` 增加最小 `xar` reader：解析 big-endian header、zlib 压缩 TOC XML、遍历 `file/data` 节点并按 heap offset 取 entry data；对 `application/x-gzip` / `zlib` entry 会先解压，再继续递归尝试 `MTLB` / `gzip` / `zip` / `bplist` / embedded `MTLB` 恢复。已用 `FORCE_PLAYTOOLS_REBUILD=1 ./BuildScripts/sync_playtools_xcframework.sh` 做编译验证；另用 synthetic `metallib → xar` 样本确认运行时已命中 `xar:test.metallib` 解包路径，但最终仍受现有 raw `MTLB headerSize=15` 解析限制阻塞 | | |
| E-005e2b2b2 | ↳ 自定义 archive / keyed archive 定向取值 | TODO | |
|  | 继续等待下一轮 live `ShaderPayloadSamples` 真实样本，再决定是否需要补 keyed archive / 其他 archive 家族的定向解包 | | |
| E-006 | **端到端验证：语义等价 + 可编译 + 截帧可见** | 🔄 IN PROGRESS | |
|  | 首轮真实样本（原神外网包）已执行：runtime 与 capture 链路正常，`.gputrace` 成功生成，但当前 `valid_msl=0`；后续验证优先服务于 `E-005e2` 的解包实现，而不是继续盲目截帧 | | |
| E-007 | **PlayCover settings UI 集成** | TODO | |
|  | 添加 `injectShaderSources` 开关到 AppSettings / AppSettingsView；添加 LLVM 工具链下载 / 状态 UI | | |

## 踩坑与经验

- **`-frecord-sources` 不适用于当前场景**：它只能在 `MSL → AIR` 阶段嵌入源码，不能为已有 bitcode 补源码；因此必须走 IR→MSL 路线
- **IR metadata 是精确类型信息的主要来源**：新版 LLVM 使用 opaque pointer，很多精确参数类型只能从 `!air.vertex` / `!air.fragment` / `!air.kernel` metadata 获取
- **`newLibraryWithData:error:` 的参数类型是 `dispatch_data_t`**：不能按 `NSData` 直接假设处理
- **live 验证前必须刷新 GUI 和 app 注入**：`sync_playtools_xcframework.sh` 后，还需要 `build_and_install.sh` 重装 GUI，并对目标 app 执行 `remove_playtools` / `inject_playtools`，否则 live runtime 可能仍是旧版本
- **`E-005a` 当前只做单 module 闭环**：多 module 场景尚未定义聚合策略，先回退原始 library
- **原神当前的主 blocker 不是 IR→MSL 覆盖率，而是 payload 形态**：live 样本已证明很多 `newLibraryWithData` 输入并非原始 `MTLB`，必须先完成 `E-005e`
- **`headerSize=0` 现在应优先看 payload 指纹日志**：新日志会同时给出 `dispatch_data` 运行时类名、前 16 字节 hex / ASCII，以及 `MTLB/bplist/zip/gzip/bzip2/llvm bitcode` 等格式指纹，先确认 wrapper 形态再决定是否需要解包
- **`E-005e2` 先做“通用剥离 + 样本落盘”比盲猜格式更稳**：当前已支持从 `bplist` 递归扫描嵌套 `Data`、以及从 payload / 嵌套 `Data` 中剥离 embedded `MTLB`；即使还原成功，也会把原始非 `MTLB` payload 落盘到 `~/Library/Containers/io.playcover.PlayCover/ShaderPayloadSamples/<bundleId>/`，便于下一轮定向补 `gzip` / `zip` / archive 解包
- **非 `MTLB` payload 现在要连同调用栈一起看**：`ShaderPayloadSamples` 的 `.txt` 元数据会带上首次命中的 `selector` / `dispatchClass` / `callStack[*]`，能直接帮助判断 wrapper 是 App 侧、Metal 桥接层还是系统解包链路生成的
- **`gzip` wrapper 解包优先走 `zlib inflateInit2(15 + 32)`**：这样能自动识别 `gzip/zlib` header，比分别手拆 header 或仅依赖高层压缩 API 更适合当前 iOS target 内的小型定向恢复逻辑；解压后继续递归跑 `bplist` / embedded `MTLB` 剥离即可
- **`zip` wrapper 先读 central directory，再 fallback 扫 local header 更稳**：不少 ZIP entry 会把可靠的大小信息放在 central directory；只有拿不到 central directory 时，才退回顺序扫描 local file header。当前已支持 stored / deflate，两种 entry 都会继续递归尝试 `MTLB` / `gzip` / `bplist` / embedded `MTLB` 恢复
- **`xar` 最小解包先抓 `header + zlib TOC + heap entry` 就能验证主路径**：`xar` header 使用 big-endian，TOC 是 zlib 压缩 XML，`file/data/offset/length/encoding` 足以定位 heap entry；本轮 synthetic `metallib → xar` 样本已确认运行时能命中 `xar:test.metallib` 解包路径，当前剩余 blocker 已转为 raw `MTLB headerSize=15` 解析兼容，而不是 `xar` entry 定位本身
- **`MTLB` magic 不是 raw metallib 的充分条件**：若 `headerSize` / `fileSize` 明显不可信（如 `headerSize=15`），不能因为前 4 字节命中 `MTLB` 就停止；应继续把它当作 wrapper 候选处理，保留 origin / sample，并向内扫描 non-zero offset 的 embedded `MTLB`
- **PlayTools 是 iOS target**：调用 `llvm-dis` 仍需走 `posix_spawn`，不能依赖 `Foundation.Process`

## 参考信息

| 主题 | 位置 |
|---|---|
| `-frecord-sources` PoC 与关键否定结论 | `E-001-PoC-frecord-sources.md` |
| metallib / bitcode / llvm-dis / IR→MSL 主实现记录 | `E-004-MetallibSourceExtraction.md` |
| Metal 编译流水线 | `../Research/03-Metal-Shader编译流水线.md` |
| `.gputrace` 内部结构 | `../Research/02-gputrace内部结构分析.md` |
| PlayTools swizzle 模板 | `Carthage/Checkouts/PlayTools/PlayTools/MetalCaptureService.swift` |
| PlaySettings 数据模型 | `Carthage/Checkouts/PlayTools/PlayTools/PlaySettings.swift` |
| PlayCover 组件安装目录 | `~/Library/Containers/io.playcover.PlayCover/` |
