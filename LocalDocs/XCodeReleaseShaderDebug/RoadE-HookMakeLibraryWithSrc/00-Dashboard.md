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
4. 若这次实现了新功能，尽可能做**实际测试**(使用skill或mcp)；若受环境限制，至少做**模拟性质、离线或最小样本测试**
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

- **E-006（下一步：`E-006a2e8` 修复 texture sample bias ambiguous）**：`E-006a2e7` live 复测已完成 — `E-006a2e6` struct return `0` blocker 已消除 ✅。新 blocker 收敛到 1 类：`air.sample_texture_cube` 带 bias 参数时，`filterTextureArgs` 将 bias float 直接传递给 `sample(sampler, coord, bias_val)`，但 Metal 要求 `sample(sampler, coord, bias(bias_val))` 选项结构。仅影响 fragment `xlatMtlMain` 天空 shader（`_ReflectionCube.sample`）。
- **E-005b**：多 bitcode module 的源码聚合 / 替换策略已稳定，仍坚持"**全成全退**"。全部有效 LLVM module 都能完成 `llvm-dis + IRToMSLConverter` 且聚合后无重名时才单次 `makeLibrary(source:)` 重编译，否则整体 fallback。
- **E-005e**：payload 恢复链路对已知样本已打通，**不再是当前主线**。

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
| 原神 6.4.0 外网包（2026-04-03，`E-006a2e7` live 复测） | `build_and_install.sh` + `remove_playtools` / `inject_playtools` / `launch_app` / `create_session(timeout=30)`。`session` 10 秒内 `ready` 后 ~15 秒 `disconnected`（无新 crash report，与历史一致）。`ShaderSourceDiagnostics` 仅 1 个 `compile_failed`（fragment `xlatMtlMain` 天空 shader）。`E-006a2e6` struct return `0` blocker 已消除 ✅。新 blocker：`_ReflectionCube.sample(sampler, coord, bias_val)` ambiguous — Metal 的 `texturecube::sample` 有 `bias`/`level`/`min_lod_clamp` 三个重载都接受 `(sampler, float3, float)`，需要将 bias 包装为 `bias(value)` 选项结构 |
| 原神 6.4.0 外网包（2026-04-03，`E-006a2e6` live 复测） | `E-006a2e5` integer literal `h` 后缀 blocker 已消除 ✅。新 blocker 收敛到 1 类：struct 返回类型的 `ret undef`/`zeroinitializer` 产出 `return 0;`。已修复 `translateRet` 增加结构体零初始化分支 |
| 原神 6.4.0 外网包（2026-04-03，`E-006a2e5` live 复测） | `E-006a2e4` 三类旧 blocker 全部消除。新 blocker 收敛到 1 类：integer literal `h` 后缀 |
| 历史 live 样本摘要（2026-04-02 ～ 2026-04-03） | 主线演进：`host bridge` 权限 → `source recompile failed` → preflight guard → toucher/keymapping 隔离 → vertex `stage_in`/pointer → `undef`/`0xH8000` → intrinsic 类型歧义 → integer literal `h` 后缀 → struct return `0` → texture sample bias ambiguous。更早细节见 [00-Dashboard-Archive](00-Dashboard-Archive.md) |

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

> 当前最高优先级：`E-006a2e8`（修复 texture `sample` bias 参数 ambiguous lowering）。更早 live 样本、已完成子任务的详细归因，以及旧 blocker 的完整历史见 [00-Dashboard-Archive](00-Dashboard-Archive.md)。

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
|  | 当前主线：`E-006a2e7` live 复测已确认 `E-006a2e6` struct return `0` blocker 消除 ✅，新 blocker 收敛到 texture `sample` bias 参数 ambiguous（`air.sample_texture_cube` 的 bias float 需包装为 `bias(value)` 选项结构）。下一步 `E-006a2e8` 修复 | | |
| E-006a | ↳ 解决 injected runtime 调 `llvm-dis` 的执行权限 blocker | ✅ DONE | |
|  | 核心权限 blocker 已在 `E-006a1` 解决；host bridge 已通过 live 复测稳定运行 | | |
| E-006a1 | ↳ runtime→host `llvm-dis` bridge 落地 | ✅ DONE | |
|  | `RegistrationListener` 现支持 runtime→host `command`；GUI 侧 `MCPManager` / `LLVMToolManager` 已实现 `host_disassemble_bitcode` handler；`LLVMDisassembler` 改为优先走 host bridge，失败才 fallback 本地 `posix_spawn`。已通过 `FORCE_PLAYTOOLS_REBUILD=1 ./BuildScripts/sync_playtools_xcframework.sh`、`./BuildScripts/build_gui.sh`、`./BuildScripts/test_mcp.sh RegistrationListenerHostCommandTests` 验证 | | |
| E-006a2 | ↳ host bridge 版本的 live 重装 / 重注入 / 截帧复测 | 🔄 IN PROGRESS | |
|  | `E-006a2a`–`E-006a2e` 已把 blocker 从 preflight / toucher / keymapping / vertex `stage_in` / pointer / `undef` / `0xH8000` 一路前移到 intrinsic 类型歧义与 vector icmp/zext lowering；详细过程见 [00-Dashboard-Archive](00-Dashboard-Archive.md) | | |
| E-006a2e | ↳ `E-006a2d4` 后的 IR→MSL lowering 补洞与 live 复测轮次 | 🔄 IN PROGRESS | |
|  | `E-006a2e1`–`E-006a2e7` 已完成；`E-006a2e7` 确认 `E-006a2e6` struct return `0` blocker 消除 ✅，新 blocker 收敛到 texture `sample` bias 参数 ambiguous；下一步 `E-006a2e8` 修复 | | |
| E-006a2e1 | ↳ `E-006a2d4` 后首轮 live 归因复测 | ✅ DONE | |
|  | 已确认 vertex `stage_in` / `device T*` / `*(&...)` 旧 blocker 不再出现；`session` 已能 `ready` 后再掉线，诊断已前移到 `undef` 与 `0xH8000` | | |
| E-006a2e2 | ↳ `undef` / half 十六进制字面量 lowering 修复 | ✅ DONE | |
|  | 在 `IRToMSLConverter` 中修了三处：①`resolveIROperand()` 新增 IR typed constant 分发（`float undef` → 递归解析 `undef` → `0`）；②`formatIRLiteral()` 新增 `undef`/`poison` 守卫 + `0xH` half hex → IEEE-754 转十进制 / `as_type<half>(ushort(...))`；③`SSAContext.resolve()` 新增 `undef`/`poison` → `0`。`test-data/test_undef_half.metal/.ll` 已补，确认 IR 含 `<4 x float> undef` 与 `0xH4000` 等目标模式。`FORCE_PLAYTOOLS_REBUILD=1 ./BuildScripts/sync_playtools_xcframework.sh` 编译通过 | | |
| E-006a2e3 | ↳ `E-006a2e2` 后 live 重装 / 重注入复测 | ✅ DONE | |
|  | 按 `build_and_install.sh` + `remove_playtools` / `inject_playtools` / `launch_app` / `create_session(timeout=30)` 完成。`session` 10 秒内 `ready` 后 ~10 秒 `disconnected`（无新 crash report）。`ShaderSourceDiagnostics` 仅 `compile_failed`，`undef`/`0xH8000`/`stage_in`/`device T*`/`*(&...)` 旧 blocker 全部消失。新 blocker：①`clamp`/`fma` 的 `half`/`float` 重载歧义（`half` 操作数 + `double` literal）；②vector `icmp` 产出 `boolN` 赋给 `bool`；③`uint8_t2` 不存在（应为 `uchar2`） | | |
| E-006a2e4 | ↳ intrinsic 类型歧义 + vector icmp/zext lowering 修复 | ✅ DONE | |
|  | 三类修复：①intrinsic（`clamp`/`fma` 等）调用时 literal 参数类型应匹配首个操作数类型（`half` → `0.0h`）；②vector `fcmp`/`icmp` 结果应为 `boolN` 而非 `bool`；③`zext <N x i1> to <N x i8>` 应映射为 `ucharN` 而非 `uint8_tN`。额外修复：`translateIntCast` 中 `zext`/`sext` 应走 `irIntegerTypeToMSL` 而非 `irScalarTypeToMSL`。`test-data/test_intrinsic_vector_icmp_zext.ll/.metal` 已补，smoketest + Metal 编译通过 | | |
| E-006a2e5 | ↳ `E-006a2e4` 后 live 复测 + integer literal `h` 后缀修复 | ✅ DONE | |
|  | Live 复测确认 `E-006a2e4` 三类 blocker（`clamp`/`fma` ambiguous ×5、`bool2→bool`、`uint8_t2`）全部消除，新 blocker 收敛到 1 类：integer literal 被非法追加 `h` 后缀（`3h`/`0h`，Metal 只允许浮点字面量使用 `h`）。修复 `appendHalfSuffixIfFPLiteral`：整数字面量（不含 `.` 或 `e`）先转为浮点形式再追加 `h`（`3` → `3.0h`）。`test-data/test_int_literal_half_suffix.ll` 已补，编译通过 | | |
| E-006a2e6 | ↳ `E-006a2e5` 后 live 复测 + struct return `0` 修复 | ✅ DONE | |
|  | Live 复测确认 `E-006a2e5` integer literal `h` 后缀 blocker 已消除 ✅。新 blocker 收敛到 1 类：struct 返回类型的 `ret undef`/`ret zeroinitializer` 产出 `return 0;`（应为 `return StructType();`），仅影响 fragment `xlatMtlMain`（`XlatMtlMain_Out` 结构体）。修复 `translateRet`：当 `resolveIROperand` 返回 `"0"` 且 `functionReturnType` 是结构体类型（`isStructTypeName`）时，改用 `return StructType();` 零初始化。`test-data/test_ret_struct_undef.metal` 已补，`FORCE_PLAYTOOLS_REBUILD=1 ./BuildScripts/sync_playtools_xcframework.sh` 编译通过 | | |
| E-006a2e7 | ↳ `E-006a2e6` 后 live 重装 / 重注入复测 | ✅ DONE | |
|  | `build_and_install.sh` + `remove_playtools` / `inject_playtools` / `launch_app` / `create_session(timeout=30)`。`session` 10 秒内 `ready` 后 ~15 秒 `disconnected`（无新 crash report）。`ShaderSourceDiagnostics` 仅 1 个 `compile_failed`（fragment `xlatMtlMain` 天空 shader）。`E-006a2e6` struct return `0` blocker 已消除 ✅。新 blocker：`_ReflectionCube.sample(sampler, coord, bias_val)` ambiguous — `air.sample_texture_cube` 带 bias 时，`filterTextureArgs` 直接传递裸 float，但 Metal 要求 `bias(value)` 选项结构 | | |
| E-006a2e8 | ↳ 修复 texture `sample` bias 参数 ambiguous lowering | TODO | |
|  | `filterTextureArgs` 或 `generateMSLForAirCall` 需识别 bias 类 float 参数并包装为 `bias(value)`。需分析 `air.sample_texture_cube` IR 调用的参数顺序与含义 | | |
| E-007 | **PlayCover settings UI 集成** | TODO | |
|  | 添加 `injectShaderSources` 开关到 AppSettings / AppSettingsView；添加 LLVM 工具链下载 / 状态 UI | | |

## 踩坑与经验

- **`-frecord-sources` 不适用于当前场景**：它只能在 `MSL → AIR` 阶段嵌入源码，不能为已有 bitcode 补源码；因此必须走 IR→MSL 路线
- **IR metadata 仍是精确类型信息的主要来源**：新版 LLVM 使用 opaque pointer，很多参数/返回类型只能从 `!air.vertex` / `!air.fragment` / `!air.kernel` metadata 恢复
- **`newLibraryWithData:error:` 的真实参数类型是 `dispatch_data_t`**：不能按 `NSData` 直接假设处理
- **live 验证前必须同时刷新 GUI 与 app 注入**：仅 `sync_playtools_xcframework.sh` 不够，还需要 `build_and_install.sh` 重装 GUI，并对目标 app 重新执行 `remove_playtools` / `inject_playtools`
- **多 module 聚合要坚持"全成全退"**：所有 module 都能完成 `llvm-dis + IRToMSLConverter` 且聚合后无重名时才重编译；否则整体 fallback，避免部分替换把问题混淆
- **已知坏 MSL 不要继续盲编译**：preflight 与 `ShaderSourceDiagnostics` 的价值不只是拦错，更是把 blocker 从"运行时崩溃"前移到"可离线定位的源码问题"
- **`session ready` 不是 live 成功判据**：必须同时看 session、进程、crash report 与 diagnostics；本轮真正的进展是 diagnostics 从 vertex `stage_in` / pointer 问题前移到 `undef` 与 `0xH8000`
- **地址类 SSA 仍要显式区分"地址表达式"和"值表达式"**：`getelementptr` / `alloca` 统一产出地址表达式，再由 `load/store` 还原成合法 lvalue，才能稳定消除 `*(&...)` 并收敛 `device T*` 访问
- **`undef` 不能泄漏到生成的 MSL**：`E-006a2e2` 已统一修掉 — `resolveIROperand()` 新增 typed constant 分发、`formatIRLiteral()` 新增 `undef`/`poison` 守卫、`SSAContext.resolve()` 新增字面量处理；`float undef` / `half undef` 等带类型前缀的变体也会被递归解析为 `0`
- **half 十六进制立即数需在 lowering 阶段转为合法 MSL**：`E-006a2e2` 已修 — `formatIRLiteral()` 新增 `0xH` half hex 识别，通过 `formatHalfIRLiteral()` 将 16-bit IEEE-754 转十进制（常用值）或 `as_type<half>(ushort(...))`（Inf/NaN 特殊值）
- **`auto` + intrinsic 调用会暴露操作数类型歧义**：`clamp(half_var, 0.0, 1.0)` 中 `0.0`/`1.0` 是 `double` literal，Metal 的 `clamp(half,half,half)` 和 `clamp(float,float,float)` 都不精确匹配，编译器报 ambiguous。fix：intrinsic 发射时 literal 参数类型应跟随首个操作数
- **Metal 的 `h` 后缀只能用于浮点字面量**：`3h`、`0h` 不合法（integer literal 不能加 `h`），必须写成 `3.0h`、`0.0h`。`E-006a2e5` 已修 — `appendHalfSuffixIfFPLiteral` 对纯整数字面量（不含 `.`/`e`）先转为浮点形式再追加 `h`
- **vector `icmp` 结果是 `boolN`，不能赋给 `bool`**：`<2 x half>` 的 `icmp eq` 产出 `<2 x i1>`，应翻译为 `bool2` 而非 `bool`
- **`zext <N x i1> to <N x i8>` 不能映射为 `uint8_tN`**：MSL 没有 `uint8_t2` 类型，应使用 `uchar2`（即 `vector<uint8_t, 2>`）。`E-006a2e4` 已修 — `translateIntCast` 中 `zext`/`sext` 改为走 `irIntegerTypeToMSL`（而非 `irScalarTypeToMSL`），且 `irIntegerTypeToMSL` 内对 `i8` 向量元素特殊处理为 `ucharN`
- **vector `fcmp`/`icmp` 结果是 `boolN`，不能赋给 `bool`**：`E-006a2e4` 已修 — `translateFCmp`/`translateICmp` 都从操作数 IR 类型提取向量维度，`dim > 1` 时 `knownType` 设为 `bool\(dim)`
- **struct 返回类型的 `ret undef`/`zeroinitializer` 不能用 `return 0;`**：`E-006a2e6` 已修 — `translateRet` 中当 `resolveIROperand` 返回 `"0"` 且 `functionReturnType` 是结构体类型（通过 `isStructTypeName` 判断）时，改用 `return StructType();` 零初始化。根因：`resolveIROperand` 将 `undef`/`poison`/`zeroinitializer` 统一转为 `"0"` 不考虑上下文类型
- **Metal `texture::sample` 的 bias/level/min_lod_clamp 重载需要选项结构参数**：`sample(sampler, coord, float_val)` 中 `float_val` 会同时匹配 `bias`、`level`、`min_lod_clamp` 三个重载导致 ambiguous。必须写成 `sample(sampler, coord, bias(val))` 或 `sample(sampler, coord, level(val))` 等显式选项形式。`air.sample_texture_cube` 带 bias 时 IR 的 float 参数需在 `generateMSLForAirCall` 中包装
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
