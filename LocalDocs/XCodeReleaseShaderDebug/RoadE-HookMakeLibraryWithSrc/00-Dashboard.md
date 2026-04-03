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
4. 若这次实现了新功能，尽可能做**实际测试**；若受环境限制，至少做**模拟性质、离线或最小样本测试**
5. 执行完毕后整理文档：结合已有内容，**深度整理并同步全局信息**，更新优先级、当前主线、TODO、验证与经验；较旧信息可下沉到独立参考文档，主体保持简洁，**不要只做追加**
6. 整理代码与改动内容；若本轮新增的测试脚本或辅助脚本对后续仍有价值，也应一并整理并提交
7. 收尾完成后执行 `git commit`

> **严禁对着最终目标死磕，每个 agent 只完成一个任务。**

### IR→MSL 改动时的验证要求

仅在修改 `IRToMSLConverter` 或相关翻译逻辑时执行：

- 在 `test-data/` 下补对应 `.metal` / `.ll` 样本
- 用工具链确认目标 IR 模式确实出现
- 运行 `FORCE_PLAYTOOLS_REBUILD=1 ./BuildScripts/sync_playtools_xcframework.sh` 确认 PlayTools 编译通过

## 当前主线

- **E-006（当前最高优先级：`E-006a2e2`）**：runtime→host `llvm-dis` bridge、聚合 MSL preflight guard、`Toucher.touchcam` 空值防护、`keymapping` 隔离复测，以及 `E-006a2d1/d2/d3/d4` 的 packed-return / 参数映射 / vector / pointer 发射修复均已落地。`E-006a2e1` 的 live 复测已确认：旧的 vertex `stage_in` 映射缺失、`device T*` 坏访问与 `*(&...)` 模式已从 diagnostics 中消失；当前 blocker 已前移到 **`undef` 残留** 与 **half 十六进制字面量 lowering**，下一步直接执行 `E-006a2e2` 修复后再做 live 重装 / 重注入复测。
- **E-005b**：多 bitcode module 的源码聚合 / 替换策略已稳定，仍坚持“**全成全退**”：全部有效 LLVM module 都能完成 `llvm-dis + IRToMSLConverter` 且聚合后无重名时才单次 `makeLibrary(source:)` 重编译，否则整体 fallback。该策略已通过 `FORCE_PLAYTOOLS_REBUILD=1 ./BuildScripts/sync_playtools_xcframework.sh` 编译验证。
- **E-005e**：当前已知 `headerSize=15` 样本的 wrapper / header-compat / function list / `OFFT` slicing 已离线打通；raw `MTLB` / `xar` / `bplist_keyed_archive` recovered payload 均已推进到 `OK modules=3 functions=3` 且 `valid_llvm=3`。对这些已知样本，payload 恢复链路**不再是当前主线**；后续仅在出现新的未知 wrapper 样本时再回到 `E-005e`。

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
| 原神 6.4.0 外网包（2026-04-03，`E-006a2d4` 后单轮 live 复测 / `E-006a2e1`） | 已按 `PLAYCOVER_INSTALL_MODE=user FORCE_PLAYTOOLS_REBUILD=1 ./BuildScripts/build_and_install.sh` 重装 GUI，并从 `pkill Yuanshen` 干净状态执行 `remove_playtools` / `inject_playtools` / `launch_app` / `create_session(timeout=30)`。`session` 在 `11:34:00 +0800` 成功 `ready`，约 **20 秒**后 `disconnected`，并新增 `Yuanshen-2026-04-03-113425.ips`；新的 `ShaderSourceDiagnostics` 已不再出现 vertex `stage_in` / `device T*` / `*(&...)` 旧 blocker，而是前移到 `float2(undef, 0.5)` 与 `half t54 = 0xH8000 - t47;`。当前验证重点已收敛到 **`undef` 与 half 常量 lowering** |
| 历史 live 样本摘要（2026-04-02 ～ 2026-04-03） | 主线演进为：`host bridge` 修复前卡在 injected runtime 内 `posix_spawn(llvm-dis)` 权限问题；修复后进入 `source recompile failed`；`preflight guard` 落地后先把明显坏 MSL 拦下；`keymapping` 隔离后确认 toucher 干扰已基本剥离；`E-006a2d4` 后旧 blocker 再前移到 `undef` / `0xH8000`。更早每轮样本、crash 与 diagnostics 细节见 [00-Dashboard-Archive](00-Dashboard-Archive.md) |

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

> 当前最高优先级：`E-006a2e2`。更早 live 样本、已完成子任务的详细归因，以及旧 blocker 的完整历史见 [00-Dashboard-Archive](00-Dashboard-Archive.md)。

| # | 任务 | 状态 | 子文档 |
|---|---|---|---|
| E-001 | **可行性 PoC：`-frecord-sources` 重编译验证** | ✅ DONE | [E-001-PoC](E-001-PoC-frecord-sources.md) |
| E-002 | **调研 MTLDevice Library API 入口** | ✅ DONE | [E-002-API](E-002-MTLDevice-Library-API.md) |
| E-003 | **makeLibrary swizzle 骨架** | ✅ DONE | [E-003-Swizzle](E-003-LibrarySwizzleSkeleton.md) |
| E-004 | **metallib → 源码提取** | 🔄 IN PROGRESS | [E-004](E-004-MetallibSourceExtraction.md) |
|  | `E-004a–d` 已完成；`E-004e` 仍持续中，但后续范围已收敛到真实 live diagnostics 驱动的 IR→MSL lowering 补洞 | | |
| E-005 | **运行时 library 替换：用带源码的 library 替换原始返回** | 🔄 IN PROGRESS | |
|  | `E-005a/b` 已完成；当前已知 wrapper 样本的 payload 恢复链路已打通，`E-005e` 暂不再作为主线，除非出现新的未知 wrapper | | |
| E-005c | ↳ 替换前接口一致性校验 | TODO | |
|  | 对重编译后的 library 做函数名 / 数量 / 关键 metadata 对齐校验 | | |
| E-005d | ↳ 缓存与观测性 | TODO | |
|  | 以 metallib 内容或 bitcode 模块 `(offset,size)` / hash 为键缓存处理结果，并补充 success / fallback reason 日志 | | |
| E-006 | **端到端验证：语义等价 + 可编译 + 截帧可见** | 🔄 IN PROGRESS | |
|  | 当前主线：先完成 `E-006a2e2` 修掉 `undef` 与 half immediate lowering，再回到 live 重装 / 重注入复测，确认是否能重新进入 `get_capture_status` / capture 阶段 | | |
| E-006a | ↳ 解决 injected runtime 调 `llvm-dis` 的执行权限 blocker | 🔄 IN PROGRESS | |
|  | 核心权限 blocker 已在 `E-006a1` 解决；当前剩余工作是 host bridge 版本的 live 复测与后续 blocker 归因 | | |
| E-006a1 | ↳ runtime→host `llvm-dis` bridge 落地 | ✅ DONE | |
|  | `RegistrationListener` 现支持 runtime→host `command`；GUI 侧 `MCPManager` / `LLVMToolManager` 已实现 `host_disassemble_bitcode` handler；`LLVMDisassembler` 改为优先走 host bridge，失败才 fallback 本地 `posix_spawn`。已通过 `FORCE_PLAYTOOLS_REBUILD=1 ./BuildScripts/sync_playtools_xcframework.sh`、`./BuildScripts/build_gui.sh`、`./BuildScripts/test_mcp.sh RegistrationListenerHostCommandTests` 验证 | | |
| E-006a2 | ↳ host bridge 版本的 live 重装 / 重注入 / 截帧复测 | 🔄 IN PROGRESS | |
|  | `E-006a2a`–`E-006a2d` 已完成并把 blocker 从 preflight / toucher / keymapping / vertex `stage_in` / pointer 发射一路前移到新的 IR→MSL lowering 问题；详细过程见 [00-Dashboard-Archive](00-Dashboard-Archive.md) | | |
| E-006a2e | ↳ 基于 `E-006a2d4` 的 live 重装 / 重注入 / diagnostics 复测 | 🔄 IN PROGRESS | |
|  | 已拆成“`E-006a2e1` 先确认旧 blocker 是否被清掉并抓新 diagnostics”“`E-006a2e2` 再针对新 diagnostics 做最小修复”两步 | | |
| E-006a2e1 | ↳ `E-006a2d4` 后首轮 live 归因复测 | ✅ DONE | |
|  | 已确认 vertex `stage_in` / `device T*` / `*(&...)` 旧 blocker 不再出现；`session` 已能 `ready` 后再掉线，诊断已前移到 `undef` 与 `0xH8000` | | |
| E-006a2e2 | ↳ `undef` / half 十六进制字面量 lowering 修复 | TODO | |
|  | 基于 `2026-04-03T03_34_24Z` diagnostics，优先修 `float2(undef, 0.5)` 的占位值发射与 `0xH8000` 这类 half immediate 的合法 MSL 表达方式；修完后回到 live 复测 | | |
| E-007 | **PlayCover settings UI 集成** | TODO | |
|  | 添加 `injectShaderSources` 开关到 AppSettings / AppSettingsView；添加 LLVM 工具链下载 / 状态 UI | | |

## 踩坑与经验

- **`-frecord-sources` 不适用于当前场景**：它只能在 `MSL → AIR` 阶段嵌入源码，不能为已有 bitcode 补源码；因此必须走 IR→MSL 路线
- **IR metadata 仍是精确类型信息的主要来源**：新版 LLVM 使用 opaque pointer，很多参数/返回类型只能从 `!air.vertex` / `!air.fragment` / `!air.kernel` metadata 恢复
- **`newLibraryWithData:error:` 的真实参数类型是 `dispatch_data_t`**：不能按 `NSData` 直接假设处理
- **live 验证前必须同时刷新 GUI 与 app 注入**：仅 `sync_playtools_xcframework.sh` 不够，还需要 `build_and_install.sh` 重装 GUI，并对目标 app 重新执行 `remove_playtools` / `inject_playtools`
- **多 module 聚合要坚持“全成全退”**：所有 module 都能完成 `llvm-dis + IRToMSLConverter` 且聚合后无重名时才重编译；否则整体 fallback，避免部分替换把问题混淆
- **已知坏 MSL 不要继续盲编译**：preflight 与 `ShaderSourceDiagnostics` 的价值不只是拦错，更是把 blocker 从“运行时崩溃”前移到“可离线定位的源码问题”
- **`session ready` 不是 live 成功判据**：必须同时看 session、进程、crash report 与 diagnostics；本轮真正的进展是 diagnostics 从 vertex `stage_in` / pointer 问题前移到 `undef` 与 `0xH8000`
- **地址类 SSA 仍要显式区分“地址表达式”和“值表达式”**：`getelementptr` / `alloca` 统一产出地址表达式，再由 `load/store` 还原成合法 lvalue，才能稳定消除 `*(&...)` 并收敛 `device T*` 访问
- **`undef` 不能泄漏到生成的 MSL**：像 `float2(undef, 0.5)` 这类产物会被 preflight 直接拦下；缺省值策略必须在 lowering 阶段统一处理
- **half 十六进制立即数不能直接按 `0xHxxxx` 发射到 MSL**：`0xH8000` 这类 AIR/LLVM 表示法需要在 lowering 阶段转成合法的 MSL `half(...)` / `as_type<half>(ushort(...))` / 等价 float-cast
- **更早的 wrapper 恢复、host bridge、live 基线与 IR→MSL 历史修复经验见 [00-Dashboard-Archive](00-Dashboard-Archive.md)**：dashboard 主体只保留当前仍会影响决策的经验

## 参考信息

| 主题 | 位置 |
|---|---|
| dashboard 下沉归档：历史 live 样本 / 已完成子任务 / 旧 blocker 经验 | `00-Dashboard-Archive.md` |
| `-frecord-sources` PoC 与关键否定结论 | `E-001-PoC-frecord-sources.md` |
| metallib / bitcode / llvm-dis / IR→MSL 主实现记录 | `E-004-MetallibSourceExtraction.md` |
| Metal 编译流水线 | `../Research/03-Metal-Shader编译流水线.md` |
| `.gputrace` 内部结构 | `../Research/02-gputrace内部结构分析.md` |
| PlayTools swizzle 模板 | `Carthage/Checkouts/PlayTools/PlayTools/MetalCaptureService.swift` |
| PlaySettings 数据模型 | `Carthage/Checkouts/PlayTools/PlayTools/PlaySettings.swift` |
| PlayCover 组件安装目录 | `~/Library/Containers/io.playcover.PlayCover/` |
