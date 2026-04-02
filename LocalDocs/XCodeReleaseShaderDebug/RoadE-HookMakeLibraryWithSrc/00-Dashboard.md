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

- **E-005e**：当前已知 `headerSize=15` 样本的 wrapper / header-compat / function list / `OFFT` slicing 已离线打通；raw `MTLB` / `xar` / `bplist_keyed_archive` recovered payload 均已推进到 `OK modules=3 functions=3` 且 `valid_llvm=3`
- **E-005b**：多 bitcode module 的源码聚合 / 替换策略已落地：对全部有效 LLVM module 逐个执行 `llvm-dis + IRToMSLConverter`，去掉每份自动生成 MSL 的公共头部后聚合为单份源码，再单次 `makeLibrary(source:)` 重编译；若任一 module 失败或聚合后函数名冲突，则整体 fallback 原始 library。本轮已用 `FORCE_PLAYTOOLS_REBUILD=1 ./BuildScripts/sync_playtools_xcframework.sh` 编译通过
- **E-006**：`LLVMDisassembler` 的 runtime→host `llvm-dis` bridge、`makeLibrary(source:)` 前的 MSL preflight guard，以及 `E-006a2c1` 的 `Toucher.touchcam` 空值防护均已落地，并已通过 `FORCE_PLAYTOOLS_REBUILD=1 ./BuildScripts/sync_playtools_xcframework.sh`、`./BuildScripts/build_gui.sh`、`./BuildScripts/test_mcp.sh RegistrationListenerHostCommandTests` 验证构建与桥接链路。2026-04-03 基于这版构建完成了 `E-006a2c2` 的 **关闭 `keymapping` 后 2 轮受控 live 复测**：按 `PLAYCOVER_INSTALL_MODE=user FORCE_PLAYTOOLS_REBUILD=1 ./BuildScripts/build_and_install.sh` 重装 GUI，对原神设置 `keymapping=false`，并从 `pkill Yuanshen` 干净状态执行 `remove_playtools` / `inject_playtools` / `launch_app` / `create_session`。第 1 轮 `session` 在 `00:47:37 +0800` ready 后，前 10 秒仍保持 ready，约 **42 秒**后 app 退出并新增 `Yuanshen-2026-04-03-004819.ips`；第 2 轮 `session` 在 `00:50:00 +0800` ready 后约 **10 秒**即变为 `disconnected`，并新增 `Yuanshen-2026-04-03-005012.ips`。两轮新 crash 均不再落在 `playcover.toucher`，而是统一回到 `UnityGfxDeviceWorker -> objc_release -> objc_autoreleasePoolPop` 的 `EXC_BAD_ACCESS / SIGSEGV`；与此同时，`~/Library/Containers/io.playcover.PlayCover/ShaderSourceDiagnostics/com.miHoYo.Yuanshen/` 新增了多份 `preflight_rejected` / `compile_failed` 样本，最新 compile failure 仍为 `program_source:14:16: expected unqualified-id`，坏行示例是 `fragment float4{ <4 xlatMtlMain(...)`。这说明 `keymapping` / toucher 路径已基本与 shader 注入主线解耦，当前 blocker 已重新收敛到 **IR→MSL 产物仍残留 LLVM vector / SSA / 返回签名错误**，以及其伴随的 worker 线程崩溃。

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
| 原神 6.4.0 外网包（2026-04-03，关闭 `keymapping` 后 2 轮受控复测） | 已按 `PLAYCOVER_INSTALL_MODE=user FORCE_PLAYTOOLS_REBUILD=1 ./BuildScripts/build_and_install.sh` 重装 GUI，把原神设置为 `keymapping=false`，并从 `pkill Yuanshen` 干净状态执行 `remove_playtools` / `inject_playtools` / `launch_app` / `create_session`。第 1 轮 `session` 在 `00:47:37 +0800` ready 后前 10 秒仍为 ready，约 **42 秒**后 app 退出并新增 `Yuanshen-2026-04-03-004819.ips`；第 2 轮 `session` 在 `00:50:00 +0800` ready 后约 **10 秒**即 `disconnected`，并新增 `Yuanshen-2026-04-03-005012.ips`，导致 `get_capture_status` / `capture_metal_frame` 尚未来得及稳定执行。两轮新 crash 均统一为 `UnityGfxDeviceWorker -> objc_release -> objc_autoreleasePoolPop` 的 `EXC_BAD_ACCESS / SIGSEGV`，不再落在 `playcover.toucher`；同时 `ShaderSourceDiagnostics/com.miHoYo.Yuanshen/` 新增 `preflight_rejected` / `compile_failed` 样本，最新 compile failure 仍是 `program_source:14:16: expected unqualified-id`，坏行示例为 `fragment float4{ <4 xlatMtlMain(...)`。说明关闭 `keymapping` 已把 toucher 干扰从主线里剥离出来，当前 blocker 重新回到 IR→MSL 产物本身 |
| 原神 6.4.0 外网包（2026-04-03，preflight guard 后单轮对照复测） | 已用 `PLAYCOVER_INSTALL_MODE=user FORCE_PLAYTOOLS_REBUILD=1 ./BuildScripts/build_and_install.sh` 重装 GUI，并从 `pkill Yuanshen` 干净状态执行 `remove_playtools` / `inject_playtools` / `launch_app` / `create_session`。`session` 在 `2026-04-03 00:29:33 +0800` ready 后至少维持约 **73 秒**，前 10 秒内未再复现旧的“很快 `disconnected` + 新增 `.ips`”基线；`get_capture_status` 返回 `available=true`，但 `trackedCommandQueueCount=0`，且 `ShaderSourceDiagnostics/com.miHoYo.Yuanshen/` 仍无新样本。最终 app 在 `00:30:46 +0800` 退出并新增 `Yuanshen-2026-04-03-003046.ips`，随后 `session` 变为 `disconnected`；新 crash 为 `EXC_BREAKPOINT / SIGTRAP`，faulting thread=40，dispatch queue=`playcover.toucher`，栈顶是 `Toucher.touchcam(...)` 的 `Unexpectedly found nil while unwrapping an Optional value`。说明 preflight guard 已显著改变 live 表现，当前 blocker 更像是 toucher / keymapping 路径，而不是此前稳定出现的 `source recompile failed` |
| 原神 6.4.0 外网包（2026-04-02，host bridge 修复后受控 5 轮复测） | 已按 `build_and_install.sh` 重装 GUI，并在 `remove_playtools` / `inject_playtools` 后做 **5 轮受控复测**；每轮都从 `pkill Yuanshen` 干净状态开始，再执行 `launch_app` / `create_session`。结果为 **5/5 稳定复现**：session 先 `ready` 后很快变 `disconnected`，进程退出，且每轮都新增 `Yuanshen-*.ips`。新 crash 以 worker 线程 `objc_release -> objc_autoreleasePoolPop -> Yuanshen offsets` 的 `EXC_BAD_ACCESS / SIGSEGV` 为主，夹杂少量主线程 `EXC_CRASH / SIGTRAP`；统一日志同时显示 `LibrarySourceInjection` 主路径已执行，并稳定出现 `source recompile failed: program_source:15:16: error: expected unqualified-id`。可作为 preflight guard 落地前的 host bridge 基线 |
| 原神 6.4.0 外网包（2026-04-02，retry + diag，**host bridge 修复前**） | 多轮 live 复测已完成：重启 PlayCover、`remove_playtools` / `inject_playtools` 后，`session` 与 `capture_metal_frame` 均稳定；`capture_20260402_roadE_e006_retry.gputrace`（349MB）结果为 `valid_msl=0`、`index 引用=854`，`capture_20260402_roadE_e006_diag.gputrace`（388MB）结果为 `valid_msl=0`、`index 引用=922`。这些样本对应的是 host bridge 落地前的旧构建：当时宿主路径查找已修复，但 injected runtime 内 `posix_spawn(llvm-dis)` 仍统一报 `Operation not permitted`；可作为 host bridge 修复前的基线对照 |

**人工确认（最终）**：Xcode 打开 `.gputrace` → 选 Draw Call → 查看 Shader 面板是否显示源码而非 `Shader source not found`。

## 整体架构

```
PlayCover 主应用 (macOS)
  ├── LLVMToolManager: 下载/管理 LLVM 预编译工具链 (llvm-dis)
  │     → 安装到 ~/Library/Containers/io.playcover.PlayCover/llvm-tools/
  ├── RegistrationListener / MCPManager: runtime→host bridge 命令入口
  │     → 承接 injected runtime 的 `host_disassemble_bitcode` 请求
  └── PlayTools.framework (注入到 iOS app)
        ├── LibrarySourceInjectionSwizzles: hook makeLibrary 系列 API
        ├── MetallibParser: 解析 metallib, 提取 LLVM Bitcode
        ├── LLVMDisassembler: 优先经 bridge 请求宿主执行 `llvm-dis`，失败再 fallback 本地 spawn
        ├── IRToMSLConverter: 将 LLVM IR 逐指令翻译为语义等价的 MSL 源码
        └── LibrarySourceInjectionService: 聚合单/多 module MSL，并调用 `makeLibrary(source:)` 编译替换原始 library
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
|  | 当前策略：先让原始 `newLibraryWithData` 正常成功，再尝试 `bitcode 提取 → llvm-dis → IRToMSLConverter → 单/多 module 源码聚合 → makeLibrary(source:)`；任一步失败立即 fallback | | |
| E-005a | ↳ `newLibraryWithData` 最小闭环接线 | ✅ DONE | |
|  | 已在 `pc_newLibraryWithData` 主路径接入 `bitcode 提取 → llvm-dis → IRToMSLConverter → makeLibrary(source:)` 单次尝试；保留原始返回/错误语义，失败只记录日志并 fallback | | |
| E-005b | ↳ 多 bitcode module 的源码聚合策略 | ✅ DONE | |
|  | 已改为对全部有效 LLVM module 逐个执行 `llvm-dis + IRToMSLConverter`，再把多份自动生成 MSL 去头聚合成单份源码并单次重编译；若任一 module 失败或聚合后函数名冲突，则整体 fallback | | |
| E-005c | ↳ 替换前接口一致性校验 | TODO | |
|  | 对重编译后的 library 做函数名 / 数量 / 关键 metadata 对齐校验 | | |
| E-005d | ↳ 缓存与观测性 | TODO | |
|  | 以 metallib 内容或 bitcode 模块 `(offset,size)` / hash 为键缓存处理结果，并补充 success / fallback reason 日志 | | |
| E-005e | ↳ **非 MTLB `newLibraryWithData` payload 识别/解包** | 🔄 IN PROGRESS | |
|  | 对当前已知真实样本，wrapper / header-compat / function list / `OFFT` slicing 已离线打通；raw `MTLB` / `xar` / `bplist_keyed_archive` recovered payload 现已推进到 `OK modules=3 functions=3` 且 `valid_llvm=3`。对这些已知样本，下一步不应再回头重复 payload 恢复链路，而应转向 `E-005b` 的多 module 替换策略；`E-005e` 后续只保留给新的未知 wrapper 样本 | | |
| E-005e3 | ↳ `OFFT` 三元组语义校正 + bitcode slicing 修复 | ✅ DONE | |
|  | 已确认真实 `OFFT` payload 不是单个偏移，而是 `(publicMetaOffset, privateMetaOffset, bitcodeOffset)` 三个 `UInt64`；`MetallibParser` 现改为读取第 3 项作为 bitcode 相对偏移，并统一复用按字节拼装的 `readUInt64` 避免未对齐访问。离线验证显示同一 `headerSize=15` 样本已从 `0/8/16` 错切片恢复到 `0/3552/7104`，raw / `xar` / `bplist_keyed_archive` 三种入口均为 `valid_llvm=3` | | |
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
| E-005e2a2 | ↳ 非标准 raw `MTLB` header 兼容解析 | ✅ DONE | |
|  | 已在 `parseHeader` 增加兼容分支：当 `headerSize < 56` 但 `fileSize`、`funcList`、`pub/priv metadata`、`bitcode` 边界自洽时，仍按 88-byte 扩展布局解析；同时 `recoverMetallibCandidate` 对 `mtlb_suspicious` 改为先尝试 direct compat parse，再 fallback embedded `MTLB` 扫描。已用真实 `mtlb_suspicious` / `xar` / `NSKeyedArchiver bplist` 三类 payload 离线验证，三者均从 parse failure 推进到 `OK modules=0 functions=1` | | |
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
|  | 已在 `MetallibParser` 增加最小 `xar` reader：解析 big-endian header、zlib 压缩 TOC XML、遍历 `file/data` 节点并按 heap offset 取 entry data；对 `application/x-gzip` / `zlib` entry 会先解压，再继续递归尝试 `MTLB` / `gzip` / `zip` / `bplist` / embedded `MTLB` 恢复。已用 `FORCE_PLAYTOOLS_REBUILD=1 ./BuildScripts/sync_playtools_xcframework.sh` 做编译验证；synthetic `metallib → xar` 与真实 `xar` payload 都已确认恢复路径能命中 `xar:test.metallib.headerCompat`，当前剩余 blocker 已转为 recovered `MTLB` 的 bitcode module 提取，而不是 `xar` entry 定位或 header 兼容本身 | | |
| E-005e2b2b2 | ↳ 自定义 archive / keyed archive 定向取值 | 🔄 IN PROGRESS | |
|  | 已拆分为“`NSKeyedArchiver` bplist 先落地”与“其他自定义 archive 继续样本驱动”两步，避免继续把所有 `bplist` 都只当成无语义的通用容器 | | |
| E-005e2b2b2a | ↳ `NSKeyedArchiver` bplist 定向取值 + 诊断 | ✅ DONE | |
|  | 已将 `bplist` 进一步细分为 `bplist_keyed_archive`；`MetallibParser` 对该类 payload 会先尝试按 `$top` / `$objects` / `CF$UID` 追踪 reachable object graph，若未先命中再 fallback 扫描 `$objects[...]` 内的 `Data`。synthetic 最小 `raw MTLB → NSKeyedArchiver` 样本已验证恢复路径命中 `bplist:$keyedArchive.$objects[2]`；本轮又用真实 `bplist_keyed_archive_12064B` 样本确认 `bplist:$keyedArchive.$objects[2].headerCompat` 已命中；并已用 `FORCE_PLAYTOOLS_REBUILD=1 ./BuildScripts/sync_playtools_xcframework.sh` 做编译验证 | | |
| E-005e2b2b2b | ↳ 其他自定义 archive / keyed archive 真实样本驱动 | TODO | |
|  | 继续等待下一轮 live `ShaderPayloadSamples` 真实样本，再决定是否需要补 keyed archive 之外的自定义 archive 家族，或把 `$top` 精确追踪扩成完整对象图解引用 | | |
| E-006 | **端到端验证：语义等价 + 可编译 + 截帧可见** | 🔄 IN PROGRESS | |
|  | runtime→host 的 `llvm-dis` bridge 与聚合 MSL preflight guard 均已接通并通过编译/单测验证。2026-04-03 的最新单轮 live 对照复测显示：旧的“很快 `ready -> disconnected -> source recompile failed`”模式已被打破，但 app 仍会在约 73 秒后崩溃退出，并新增 `Yuanshen-2026-04-03-003046.ips`；当前最突出的新 crash 摘要落在 `playcover.toucher` queue，而不是 `program_source:15:16` 这类已知 compile failure。本轮已完成 `E-006a2c1` 的 `Toucher.touchcam` 空值防护并通过编译验证，下一步转向 `E-006a2c2` 的 keymapping 隔离后 live 复测 | | |
| E-006a | ↳ 解决 injected runtime 调 `llvm-dis` 的执行权限 blocker | 🔄 IN PROGRESS | |
|  | 已将任务拆成“host bridge 落地”和“live 复测 / blocker 重新归因”两步，避免继续在旧 `posix_spawn` 设计上空转 | | |
| E-006a1 | ↳ runtime→host `llvm-dis` bridge 落地 | ✅ DONE | |
|  | `RegistrationListener` 现支持 runtime→host `command`；GUI 侧 `MCPManager` / `LLVMToolManager` 已实现 `host_disassemble_bitcode` handler；`LLVMDisassembler` 改为优先走 host bridge，失败才 fallback 本地 `posix_spawn`。已通过 `FORCE_PLAYTOOLS_REBUILD=1 ./BuildScripts/sync_playtools_xcframework.sh`、`./BuildScripts/build_gui.sh`、`./BuildScripts/test_mcp.sh RegistrationListenerHostCommandTests` 验证 | | |
| E-006a2 | ↳ host bridge 版本的 live 重装 / 重注入 / 截帧复测 | 🔄 IN PROGRESS | |
|  | 已拆成“`E-006a2a` 先拦截明显非法的聚合 MSL 并落盘诊断样本”“`E-006a2b` 基于新 guard 做 live 对照复测”“`E-006a2c` 先修 toucher 自身崩溃，再做 keymapping 隔离后的 live 复测”“`E-006a2d` 再基于最新 diagnostics 样本继续修 IR→MSL 产物”四步，避免把源码无效、输入路径崩溃和 capture 条件不足混在一起 | | |
| E-006a2a | ↳ 重编译前 preflight + 失败源码落盘 | ✅ DONE | |
|  | `LibrarySourceInjectionService` 现会在 `makeLibrary(source:)` 前扫描聚合 MSL 中残留的 LLVM token（如 `<N x T>` / `ptr` / `addrspace` / `%...` / 原始 `i32` / `undef`），若命中则直接 fallback 原始 library，并把 `.metal` / `.txt` 样本落到 `~/Library/Containers/io.playcover.PlayCover/ShaderSourceDiagnostics/<bundleId>/`；若仍进入 compile failure，也会补 `program_source` 行列与附近上下文。已通过 `FORCE_PLAYTOOLS_REBUILD=1 ./BuildScripts/sync_playtools_xcframework.sh` 与 `./BuildScripts/build_gui.sh` 编译验证 | | |
| E-006a2b | ↳ 基于 preflight guard 的 live 对照复测 | ✅ DONE | |
|  | 已按 `PLAYCOVER_INSTALL_MODE=user FORCE_PLAYTOOLS_REBUILD=1 ./BuildScripts/build_and_install.sh` 重装 GUI，并对原神执行 `pkill`、`remove_playtools` / `inject_playtools`、`launch_app` / `create_session`。结果显示：`session` 不再像旧基线那样很快掉线，而是先稳定 ready，`get_capture_status` 也返回 `available=true`；但最终 app 仍在约 73 秒后退出、`session` 变为 `disconnected`，并新增 `Yuanshen-2026-04-03-003046.ips`。本轮未产出新的 `ShaderSourceDiagnostics` 样本，最新 crash 栈顶则落在 `playcover.toucher` 的 `Toucher.touchcam(...)` Optional unwrap | | |
| E-006a2c | ↳ 隔离 `playcover.toucher` / keymapping 干扰后继续截帧 | ✅ DONE | |
|  | 已完成“`E-006a2c1` 先修 `Toucher.touchcam` 的 `keyWindow` 空值崩溃”“`E-006a2c2` 再在禁用 / 绕开 keymapping 后做 live 复测”两步；最新结论是 toucher / keymapping 路径已基本与 shader 注入主线解耦，但 app 仍会在 12–42 秒内断开并新增 worker-thread crash，需继续转向最新 diagnostics 样本驱动的 IR→MSL 修复 | | |
| E-006a2c1 | ↳ `Toucher.touchcam` 空值防护 + window fallback | ✅ DONE | |
|  | `Toucher.touchcam` 在 `phase == .began` 时现改为 `guard let window = screen.keyWindow`，若拿不到 key window 则记录日志并跳过本次 touch；拿到 window 后使用 `window.hitTest(point, with: nil) ?? window` 作为 view fallback，避免 `playcover.toucher` queue 上的 `keyWindow!` 崩溃。已通过 `FORCE_PLAYTOOLS_REBUILD=1 ./BuildScripts/sync_playtools_xcframework.sh` 与 `./BuildScripts/build_gui.sh` 编译验证 | | |
| E-006a2c2 | ↳ 禁用 / 绕开 keymapping 后继续 live 截帧复测 | ✅ DONE | |
|  | 已对原神设置 `keymapping=false`，并按 `build_and_install.sh` 重装 GUI 后，从 `pkill Yuanshen` 干净状态执行 `remove_playtools` / `inject_playtools` / `launch_app` / `create_session` 做 **2 轮受控复测**。第 1 轮 `session` ready 后前 10 秒仍存活，约 42 秒后 app 退出并新增 `Yuanshen-2026-04-03-004819.ips`；第 2 轮 ready 后约 10 秒即 `disconnected`，并新增 `Yuanshen-2026-04-03-005012.ips`。两轮 crash 均统一为 `UnityGfxDeviceWorker -> objc_release -> objc_autoreleasePoolPop` 的 `EXC_BAD_ACCESS / SIGSEGV`，不再落在 `playcover.toucher`；同时 `ShaderSourceDiagnostics` 重新出现 `preflight_rejected` / `compile_failed` 样本，说明 keymapping 干扰已基本剥离，但 capture 仍在 shader 主线问题解决前被后续崩溃打断 | | |
| E-006a2d | ↳ 基于最新 diagnostics 样本修 IR→MSL 中的返回签名 / vector / SSA 泄漏 | TODO | |
|  | 结合 `2026-04-02T16_50_11Z_*` 等新样本，优先修复 `fragment float4{ <4 xlatMtlMain(...)` 这类函数签名拼接错误，以及 `%0.field*`、`<4 x float>`、`fadd/fmul fast` 等 LLVM token 泄漏，再继续做 live 截帧复测 | | |
| E-007 | **PlayCover settings UI 集成** | TODO | |
|  | 添加 `injectShaderSources` 开关到 AppSettings / AppSettingsView；添加 LLVM 工具链下载 / 状态 UI | | |

## 踩坑与经验

- **`-frecord-sources` 不适用于当前场景**：它只能在 `MSL → AIR` 阶段嵌入源码，不能为已有 bitcode 补源码；因此必须走 IR→MSL 路线
- **IR metadata 是精确类型信息的主要来源**：新版 LLVM 使用 opaque pointer，很多精确参数类型只能从 `!air.vertex` / `!air.fragment` / `!air.kernel` metadata 获取
- **`newLibraryWithData:error:` 的参数类型是 `dispatch_data_t`**：不能按 `NSData` 直接假设处理
- **live 验证前必须刷新 GUI 和 app 注入**：`sync_playtools_xcframework.sh` 后，还需要 `build_and_install.sh` 重装 GUI，并对目标 app 执行 `remove_playtools` / `inject_playtools`，否则 live runtime 可能仍是旧版本
- **多 module 聚合要坚持“全成全退”**：当前策略要求所有 module 都能完成 `llvm-dis + IRToMSLConverter`，再剥掉每份自动生成 MSL 的公共头部后合并为单次 `makeLibrary(source:)` 输入；若任一 module 失败或聚合后出现重名函数，宁可整体 fallback，也不要做部分替换
- **真实 `headerSize=15` 样本里的 `OFFT` payload 是 3×`UInt64` 三元组**：前两项分别是 public/private metadata 偏移，第 3 项才是 bitcode section 内相对偏移；此前误读首个 `UInt64` 才会把 3 个 module 错切成 `0/8/16`，修正后同一样本已恢复到 `0/3552/7104` 且 `valid_llvm=3`
- **`functionList` section 不能从 offset 0 直接按 tag 流读取**：真实 `headerSize=15` 样本在 section 开头先放 `4-byte entryCount`，每个函数 entry 再以 `4-byte tagGroupSize` 开头；此外 `functionListSize` 看起来只覆盖各 entry 的 size 总和，不包含最前面的 `entryCount`
- **`OFFT` / `MDSZ` 这类 payload 的定长字段不要直接 `withUnsafeBytes.load(as:)`**：在 macOS/iOS 运行时可能触发未对齐访问崩溃，统一走按字节拼装的 `UInt16/32/64` helper 更稳；本轮 `MetallibParser` 已改成复用 `readUInt64`
- **`headerSize=0` 现在应优先看 payload 指纹日志**：新日志会同时给出 `dispatch_data` 运行时类名、前 16 字节 hex / ASCII，以及 `MTLB/bplist/zip/gzip/bzip2/llvm bitcode` 等格式指纹，先确认 wrapper 形态再决定是否需要解包
- **`E-005e2` 先做“通用剥离 + 样本落盘”比盲猜格式更稳**：当前已支持从 `bplist` 递归扫描嵌套 `Data`、以及从 payload / 嵌套 `Data` 中剥离 embedded `MTLB`；即使还原成功，也会把原始非 `MTLB` payload 落盘到 `~/Library/Containers/io.playcover.PlayCover/ShaderPayloadSamples/<bundleId>/`，便于下一轮定向补 `gzip` / `zip` / archive 解包
- **非 `MTLB` payload 现在要连同调用栈一起看**：`ShaderPayloadSamples` 的 `.txt` 元数据会带上首次命中的 `selector` / `dispatchClass` / `callStack[*]`，能直接帮助判断 wrapper 是 App 侧、Metal 桥接层还是系统解包链路生成的
- **`gzip` wrapper 解包优先走 `zlib inflateInit2(15 + 32)`**：这样能自动识别 `gzip/zlib` header，比分别手拆 header 或仅依赖高层压缩 API 更适合当前 iOS target 内的小型定向恢复逻辑；解压后继续递归跑 `bplist` / embedded `MTLB` 剥离即可
- **`zip` wrapper 先读 central directory，再 fallback 扫 local header 更稳**：不少 ZIP entry 会把可靠的大小信息放在 central directory；只有拿不到 central directory 时，才退回顺序扫描 local file header。当前已支持 stored / deflate，两种 entry 都会继续递归尝试 `MTLB` / `gzip` / `bplist` / embedded `MTLB` 恢复
- **`xar` 最小解包先抓 `header + zlib TOC + heap entry` 就能验证主路径**：`xar` header 使用 big-endian，TOC 是 zlib 压缩 XML，`file/data/offset/length/encoding` 足以定位 heap entry；本轮 synthetic `metallib → xar` 与真实 `xar` payload 都已确认恢复路径可命中 `xar:test.metallib.headerCompat`，当前剩余 blocker 已转为 recovered `MTLB` 的 bitcode module 提取，而不是 `xar` entry 定位或 header 兼容本身
- **`NSKeyedArchiver` 本质仍是 `bplist`，但应单独标成 `bplist_keyed_archive`**：单靠泛化的 `$root` 递归扫描虽然偶尔能捞到 `Data`，但 keyed archive 的诊断语义会丢失；当前更稳妥的路径是优先把 `$objects[...]` 当作专用候选空间，并保留 `$top` / `CF$UID` 追踪作为后续可继续精细化的方向。synthetic 最小 `raw MTLB → NSKeyedArchiver` 样本已确认恢复日志会命中 `bplist:$keyedArchive.$objects[2]`
- **`MTLB` magic 不是 raw metallib 的充分条件，但 `headerSize` 异常也不等于假头**：真实样本存在 `headerSize=15` 的 raw `MTLB`，其 `fileSize` / `funcList` / `pub/priv metadata` / `bitcode` 仍与 88-byte 扩展 header 自洽；因此对可疑 `MTLB` 应先尝试兼容解析，失败后再继续把它当 wrapper 候选向内扫描 embedded `MTLB`
- **wrapper 恢复链路要先尝试 direct compat parse**：`xar` / `NSKeyedArchiver` 解包后拿到的 payload 可能就是 offset 0 的异常 raw `MTLB`；若 `recoverMetallibCandidate` 只扫 non-zero offset 的 embedded `MTLB`，会把本可解析的样本误判成未恢复
- **`NSHomeDirectory()` 在 injected runtime 中返回的是目标 app 容器，不是宿主用户 Home**：像 `~/Library/Containers/io.playcover.PlayCover/llvm-tools/llvm-dis` 这类宿主路径不能直接基于 `NSHomeDirectory()` 拼接，否则会误变成双层容器路径；本轮已改为优先用 `getpwuid(getuid())` / `NSUserName()` 推导宿主目录
- **PlayTools 是 iOS target**：不能依赖 `Foundation.Process`；若必须在 injected runtime 内起子进程，只能自己走 `posix_spawn`
- **真正拦住 `llvm-dis` 的不是“找不到工具”，而是目标 app 的 macOS sandbox**：`composeEntitlements()` 会附带 `com.apple.security.app-sandbox = true`，且 SBPL 里明确有 `(deny process-fork)`；因此修正宿主路径后，`posix_spawn(llvm-dis)` 仍会被内核直接打回 `Operation not permitted`
- **现有 `RegistrationListener` 足够承接一次性 runtime→host 工具请求**：不必额外新开一套 IPC；复用现有 registration 端口，新增短连接 `command` / `commandResponse` 即可把 `llvm-dis` 挪到宿主进程执行，同时保留 runtime 侧最小改动和本地 fallback
- **host bridge 版本 live 复测要同时看 session、进程和 crash report**：`create_session` 返回 `ready` 不能说明 app 已稳定；原神在本轮受控 5 轮复测里都是刚 ready 就掉成 `disconnected`，同时在 `~/Library/Logs/DiagnosticReports/` 生成新的 `Yuanshen-*.ips`，如果只盯着 MCP 返回值，很容易误判为已经进入截帧阶段
- **“`llvm-dis` 权限问题已解”不等于 Road E live 已通**：当前统一日志已能看到 `LibrarySourceInjection` 主路径稳定执行，甚至走到了 `source recompile failed`；这说明问题已经前移到 IR→MSL 产物 / fallback / 运行时稳定性层，而不是继续卡在 injected runtime 无法执行 `llvm-dis`
- **已知坏 MSL 不要继续盲编译**：像 `program_source:15:16: expected unqualified-id` 这类稳定 compile failure，下一轮 live 前应先在聚合源码层面做 preflight，把 `<N x T>` / `ptr` / `addrspace` / `%...` / 原始 `i32` / `undef` 等 LLVM 残留直接拦下；否则会把“源码无效”和“编译/运行时副作用”两类问题混在一起，难以判断崩溃是否真由 `makeLibrary(source:)` 触发
- **聚合 MSL 诊断要保留源码和行号上下文**：当前 `LibrarySourceInjectionService` 已把 preflight 拒绝或 compile failure 的聚合源码落到 `~/Library/Containers/io.playcover.PlayCover/ShaderSourceDiagnostics/<bundleId>/`；若错误信息包含 `program_source:line:column`，侧车 `.txt` 会一并记录对应行列和附近上下文，便于离线直接定位无效产物
- **先把 toucher 自身的硬崩溃口堵上，再做 keymapping 隔离 live 复测**：2026-04-03 的原神单轮对照复测显示，新 crash 栈顶落在 `playcover.toucher` queue 的 `Toucher.touchcam(...)` Optional unwrap；因此 `E-006a2c` 已先拆出 `E-006a2c1`，在 `phase == .began` 时对 `screen.keyWindow` 做 `guard`，并用 `hitTest(...) ?? window` 兜底，避免因为 key window 短暂缺失直接崩溃。完成这一步后，再对目标 app 禁用 / 绕开 keymapping 做 live 复测，更容易判断 shader 注入链路是否仍有独立 blocker
- **关闭 `keymapping` 后若 crash 从 `playcover.toucher` 转回 `UnityGfxDeviceWorker`，说明 toucher 干扰已基本剥离**：本轮把原神设置为 `keymapping=false` 后，新增 `Yuanshen-2026-04-03-004819.ips` / `005012.ips` 的 faulting thread 都回到 `UnityGfxDeviceWorker -> objc_release -> objc_autoreleasePoolPop`，不再是输入路径崩溃；这类结果比“单纯 session 仍会掉线”更有信息量，能明确提示下一轮应继续盯住 shader 主线而不是 keymapping
- **关闭 `keymapping` 后重新出现的 `ShaderSourceDiagnostics` 更能代表 shader 主线真实 blocker**：本轮新样本同时出现 `preflight_rejected` 与 `compile_failed`，其中 compile failure 仍是 `program_source:14:16: expected unqualified-id`，坏行示例为 `fragment float4{ <4 xlatMtlMain(...)`；而 preflight 也直接暴露了 `%0.field*`、`<4 x float>`、`fadd/fmul fast` 等 LLVM token 泄漏。说明下一轮应优先修 `IRToMSLConverter` 的返回签名 / vector lowering / SSA 聚合体访问，而不是继续扩大 live 复测覆盖面

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
