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

- **E-006（下一步：`E-006a2e12` 修复 `uint8_t2` 第二实例 + `sample_compare` 参数不匹配）**：`E-006a2e11` live 复测确认 `E-006a2e10` 三 blocker 已消除 ✅，同时修复了两个新 blocker：①天空 shader `xlatMtlMain` `[[color]]` 结构体 depth 属性缺失（`generateEntryOutputStructDefinition` 增加 `air.depth` kind + 字段名 heuristic 检测，分配 `[[depth(any)]]`）②`translateMetalIntrinsic` 参数溢出（`fract(x, 0)` 多传元数据标志，增加 `mslArgCount` 字段按类别过滤参数）。新发现的 blocker：①大 shader（28KB+）中 `uint8_t2` 再现（不同 code path）②`sample_compare` 参数不匹配。原神间歇性 `EXC_BAD_ACCESS` 崩溃（`objc_release` in Thread 48/49，与 PlayTools 无关）增加了 live 验证难度。
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
| 原神 6.4.0 外网包（2026-04-03，`E-006a2e11` live 复测） | `build_and_install.sh` + `remove_playtools` / `inject_playtools` / `launch_app` / `create_session(timeout=30)`。原神间歇性 `EXC_BAD_ACCESS` 崩溃（`objc_release` Thread 48/49，与 PlayTools 无关，同偏移 0xd44b804），需多次重试。成功 session 中 `ShaderSourceDiagnostics` 确认：天空 shader `[[color]]` depth blocker ✅ 已消除、`fract(x, 0)` 参数溢出 ✅ 已消除、`E-006a2e10` 三 blocker ✅ 均未再现。新 blocker：①大 shader（28KB+）`uint8_t2` 再现（不同 code path）②`sample_compare` 参数不匹配 |
| 原神 6.4.0 外网包（2026-04-03，`E-006a2e10` smoketest） | `FORCE_PLAYTOOLS_REBUILD=1` + `sync_playtools_xcframework.sh` 编译通过 ✅，`test_mcp.sh` 687 tests (1 pre-existing failure 无关)。新增 `test_metal_intrinsic_sampler_state.ll` smoketest通过 |
| 原神 6.4.0 外网包（2026-04-03，`E-006a2e9` live 复测） | session 30 秒+ 持续 `ready`。`E-006a2e8` texture sample bias/level ambiguous blocker 已消除 ✅ |
| 历史更多 live 样本摘要（2026-04-02 ～ 2026-04-03） | 主线演进见 [00-Dashboard-Archive](00-Dashboard-Archive.md) |

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

> 当前最高优先级：`E-006a2e12`（修复 `uint8_t2` 第二实例 + `sample_compare` 参数不匹配）。更早 live 样本、已完成子任务的详细归因，以及旧 blocker 的完整历史见 [00-Dashboard-Archive](00-Dashboard-Archive.md)。

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
|  | 当前主线：`E-006a2e11` live 复测确认 `E-006a2e10` 三 blocker 已消除 ✅，同时修复 depth 属性 + intrinsic 参数溢出，新 blocker 前移到 `uint8_t2` 第二实例 + `sample_compare` | | |
| E-006a | ↳ 解决 injected runtime 调 `llvm-dis` 的执行权限 blocker | ✅ DONE | |
|  | 核心权限 blocker 已在 `E-006a1` 解决；host bridge 已通过 live 复测稳定运行 | | |
| E-006a1 | ↳ runtime→host `llvm-dis` bridge 落地 | ✅ DONE | |
|  | `RegistrationListener` 现支持 runtime→host `command`；GUI 侧 `MCPManager` / `LLVMToolManager` 已实现 `host_disassemble_bitcode` handler；`LLVMDisassembler` 改为优先走 host bridge，失败才 fallback 本地 `posix_spawn`。已通过 `FORCE_PLAYTOOLS_REBUILD=1 ./BuildScripts/sync_playtools_xcframework.sh`、`./BuildScripts/build_gui.sh`、`./BuildScripts/test_mcp.sh RegistrationListenerHostCommandTests` 验证 | | |
| E-006a2 | ↳ host bridge 版本的 live 重装 / 重注入 / 截帧复测 | 🔄 IN PROGRESS | |
|  | `E-006a2a`–`E-006a2e` 已把 blocker 从 preflight / toucher / keymapping / vertex `stage_in` / pointer / `undef` / `0xH8000` 一路前移到 intrinsic 类型歧义与 vector icmp/zext lowering；详细过程见 [00-Dashboard-Archive](00-Dashboard-Archive.md) | | |
| E-006a2e | ↳ `E-006a2d4` 后的 IR→MSL lowering 补洞与 live 复测轮次 | 🔄 IN PROGRESS | |
|  | `E-006a2e1`–`E-006a2e11` 已完成；`E-006a2e11` 确认 `E-006a2e10` 三 blocker 消除 ✅，同时修复 depth 属性 + intrinsic 参数溢出 ✅，新 blocker 前移到 `uint8_t2` 第二实例 + `sample_compare` | | |
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
| E-006a2e8 | ↳ 修复 texture `sample` bias/level 参数 ambiguous lowering | ✅ DONE | |
|  | Air IR 中 `air.sample_texture_*` 的 bias/level 由 `i1` 标志区分（`false`=bias, `true`=level）。修复：①`filterTextureArgs` 改为返回 `(args, types)` 元组保留类型信息；②`generateMSLForAirCall` 对 `sample` 方法调用，扫描原始参数中 `i1` 后接 `float` 的标志位，将尾部 float/half 包装为 `bias(value)` 或 `level(value)` 选项结构；③同时修复 `hasPrefix("0.0")` 过度过滤 bug（会误过滤 0.01 等非零小值）。`test-data/test_sample_bias.ll` 已补（覆盖 bias/level/bias(0) 三种情况）。`FORCE_PLAYTOOLS_REBUILD=1 ./BuildScripts/sync_playtools_xcframework.sh` 编译通过，`test_mcp.sh` 全部通过（1 个 pre-existing failure 无关） |
| E-006a2e9 | ↳ `E-006a2e8` 后 live 重装 / 重注入复测 | ✅ DONE | |
|  | texture sample bias/level ambiguous blocker 已消除 ✅。session 从 ~10-15 秒 `disconnected` 提升到 30 秒+ 持续 `ready`。天空 shader `[[color]]` 仍存在（旧 blocker）。新 blocker：①`@___metal_fract_v2float` 内联 intrinsic 未翻译 ②`@__air_sampler_state` 全局 symbol 泄露到 `.sample()` / `.sample_compare()` ③`uint8_t2` 类型回退 | | |
| E-006a2e10 | ↳ 修复 `___metal_fract` / `@__air_sampler_state` / `uint8_t2` 新 blocker | ✅ DONE | |
|  | 三类修复：①`translateCall` 增加 `@___metal_` 前缀识别，新增 `translateMetalIntrinsic` + `metalIntrinsicMappings` 映射表（覆盖 sin/cos/tan/fract/sqrt/exp/log/floor/ceil/clamp/mix/fma/fabs/abs/dot/cross/length/normalize/distance 及 `fast_` 变体）②`resolveIROperand` 增加 `@` 全局 symbol 处理：开头 `@` 匹配 sampler 参数（addrspace(2)）；同时增加 `@` token 尾部提取递归（处理 `readonly captures(none) @__air_sampler_state` 等限定词包裹场景）；`filterTextureArgs` 增加 `arg.isEmpty` 过滤兜底 ③`irScalarTypeToMSL` 向量分支增加 `i8` 特殊处理：`<N x i8>` → `ucharN`（与 `irIntegerTypeToMSL` 一致）。`test-data/test_metal_intrinsic_sampler_state.ll` 已补。`FORCE_PLAYTOOLS_REBUILD=1` + `test_mcp.sh` 通过 | | |
| E-006a2e11 | ↳ `E-006a2e10` 后 live 重装 / 重注入复测 | ✅ DONE | |
|  | Live 复测确认 `E-006a2e10` 三 blocker（`___metal_fract`/`@__air_sampler_state`/`uint8_t2`）全部消除 ✅。同时修复两个新 blocker：①天空 shader `[[color]]` depth 属性缺失 — `generateEntryOutputStructDefinition` 增加 `air.depth` kind 映射 + 字段名 heuristic（含 "depth" → `[[depth(any)]]`）②`translateMetalIntrinsic` 参数溢出 — `metalIntrinsicMappings` 增加 `mslArgCount` 字段，unary/binary/ternary/vector 分类定义期望参数数，`translateMetalIntrinsic` 按 `mslArgCount` 过滤多余元数据参数。`test-data/test_fragment_depth_output.ll` 已补，Metal 编译通过。原神间歇性 `EXC_BAD_ACCESS` 崩溃（Thread 48/49 `objc_release`，与 PlayTools 无关）。新 blocker：①大 shader（28KB+）`uint8_t2` 再现 ②`sample_compare` 参数不匹配 | | |
| E-006a2e12 | ↳ 修复 `uint8_t2` 第二实例 + `sample_compare` 参数不匹配 | TODO | | |
| E-007 | **PlayCover settings UI 集成** | TODO | |
|  | 添加 `injectShaderSources` 开关到 AppSettings / AppSettingsView；添加 LLVM 工具链下载 / 状态 UI | | |

## 踩坑与经验

- **`-frecord-sources` 不适用于当前场景**：它只能在 `MSL → AIR` 阶段嵌入源码，不能为已有 bitcode 补源码；因此必须走 IR→MSL 路线
- **IR metadata 仍是精确类型信息的主要来源**：新版 LLVM 使用 opaque pointer，很多参数/返回类型只能从 `!air.vertex` / `!air.fragment` / `!air.kernel` metadata 恢复
- **`newLibraryWithData:error:` 的真实参数类型是 `dispatch_data_t`**：不能按 `NSData` 直接假设处理
- **live 验证前必须同时刷新 GUI 与 app 注入**：仅 `sync_playtools_xcframework.sh` 不够，还需要 `build_and_install.sh` 重装 GUI，并对目标 app 重新执行 `remove_playtools` / `inject_playtools`
- **多 module 聚合要坚持"全成全退"**：所有 module 都能完成 `llvm-dis + IRToMSLConverter` 且聚合后无重名时才重编译；否则整体 fallback，避免部分替换把问题混淆
- **已知坏 MSL 不要继续盲编译**：preflight 与 `ShaderSourceDiagnostics` 的价值不只是拦错，更是把 blocker 从"运行时崩溃"前移到"可离线定位的源码问题"
- **`filterTextureArgs` 的 float 零值过滤不要用 `hasPrefix("0.0")`**：`0.01`、`0.05` 等非零小值也会匹配 `hasPrefix("0.0")` 被错误过滤。应只精确匹配 `"0.0"` 和 `"0.000000e+00"`。`E-006a2e8` 已修
- **地址类 SSA 仍要显式区分"地址表达式"和"值表达式"**：`getelementptr` / `alloca` 统一产出地址表达式，再由 `load/store` 还原成合法 lvalue，才能稳定消除 `*(&...)` 并收敛 `device T*` 访问
- **`undef` 不能泄漏到生成的 MSL**：`E-006a2e2` 已统一修掉 — `resolveIROperand()` 新增 typed constant 分发、`formatIRLiteral()` 新增 `undef`/`poison` 守卫、`SSAContext.resolve()` 新增字面量处理；`float undef` / `half undef` 等带类型前缀的变体也会被递归解析为 `0`
- **half 十六进制立即数需在 lowering 阶段转为合法 MSL**：`E-006a2e2` 已修 — `formatIRLiteral()` 新增 `0xH` half hex 识别，通过 `formatHalfIRLiteral()` 将 16-bit IEEE-754 转十进制（常用值）或 `as_type<half>(ushort(...))`（Inf/NaN 特殊值）
- **`auto` + intrinsic 调用会暴露操作数类型歧义**：`clamp(half_var, 0.0, 1.0)` 中 `0.0`/`1.0` 是 `double` literal，Metal 的 `clamp(half,half,half)` 和 `clamp(float,float,float)` 都不精确匹配，编译器报 ambiguous。fix：intrinsic 发射时 literal 参数类型应跟随首个操作数
- **Metal 的 `h` 后缀只能用于浮点字面量**：`3h`、`0h` 不合法（integer literal 不能加 `h`），必须写成 `3.0h`、`0.0h`。`E-006a2e5` 已修 — `appendHalfSuffixIfFPLiteral` 对纯整数字面量（不含 `.`/`e`）先转为浮点形式再追加 `h`
- **vector `icmp` 结果是 `boolN`，不能赋给 `bool`**：`<2 x half>` 的 `icmp eq` 产出 `<2 x i1>`，应翻译为 `bool2` 而非 `bool`
- **`zext <N x i1> to <N x i8>` 不能映射为 `uint8_tN`**：MSL 没有 `uint8_t2` 类型，应使用 `uchar2`（即 `vector<uint8_t, 2>`）。`E-006a2e4` 修了 `translateIntCast` 走 `irIntegerTypeToMSL`；`E-006a2e10` 补修了 `irScalarTypeToMSL` 向量分支的 `i8` 特殊处理，覆盖所有调用路径
- **vector `fcmp`/`icmp` 结果是 `boolN`，不能赋给 `bool`**：`E-006a2e4` 已修 — `translateFCmp`/`translateICmp` 都从操作数 IR 类型提取向量维度，`dim > 1` 时 `knownType` 设为 `bool\(dim)`
- **struct 返回类型的 `ret undef`/`zeroinitializer` 不能用 `return 0;`**：`E-006a2e6` 已修 — `translateRet` 中当 `resolveIROperand` 返回 `"0"` 且 `functionReturnType` 是结构体类型（通过 `isStructTypeName` 判断）时，改用 `return StructType();` 零初始化。根因：`resolveIROperand` 将 `undef`/`poison`/`zeroinitializer` 统一转为 `"0"` 不考虑上下文类型
- **Metal `texture::sample` 的 bias/level/min_lod_clamp 重载需要选项结构参数**：`sample(sampler, coord, float_val)` 中 `float_val` 会同时匹配 `bias`、`level`、`min_lod_clamp` 三个重载导致 ambiguous。必须写成 `sample(sampler, coord, bias(val))` 或 `sample(sampler, coord, level(val))` 等显式选项形式。`E-006a2e8` 已修 — `generateMSLForAirCall` 根据原始 `i1` 标志自动区分 bias(false) 和 level(true)
- **Air IR `sample_texture_*` 的 `i1` 标志区分 bias 与 level**：`air.sample_texture_2d(tex, sampler, coord, i1_offset, offset, i1_lod, float_val, ...)` 中 `i1_lod=false` → bias, `i1_lod=true` → level(explicit LOD)。cube/3d 变体省略 offset 参数但 LOD 标志位置类似。`filterTextureArgs` 跳过了 `i1`，因此 bias/level 包装需回查原始参数
- **`translateCall` 需识别 `@___metal_` 前缀的 LLVM Metal intrinsic**：LLVM Metal 编译器会将部分标准库函数内联为 `@___metal_fract_v2float` 等形式，不是 `@air.*` 前缀。`E-006a2e10` 已修 — 新增 `translateMetalIntrinsic` + `metalIntrinsicMappings`，通过前缀匹配（最长优先）将 `___metal_<name>_<typesuffix>` 映射为 MSL 函数名 `<name>`
- **`@__air_sampler_state` 全局 symbol 不应出现在生成的 MSL 中**：air 调用中的 sampler 参数有时被 IR 编译器解析为全局 `@__air_sampler_state` 并嵌入 IR 限定词（如 `readonly captures(none) @__air_sampler_state`）。`E-006a2e10` 已修 — `resolveIROperand` 开头 `@` 直接匹配 sampler 参数，同时增加 `@` token 尾部提取递归处理限定词包裹场景；`filterTextureArgs` 增加 `arg.isEmpty` 过滤兜底
- **Metal fragment 返回结构体的每个成员必须有显式属性**：`[[color(N)]]`、`[[depth(any)]]`、`[[position]]` 等。`E-006a2e11` 已修 — `generateEntryOutputStructDefinition` 增加 `air.depth` kind 映射 + 字段名 heuristic（含 "depth" → `[[depth(any)]]`）。Metal AIR 规范中 fragment depth 输出可能不以 `air.render_target` 作为 metadata kind，需通过字段名检测兜底
- **`___metal_*` intrinsic 的 IR 参数可能包含元数据标志**：`@___metal_fract_v2float(<2 x float>, i32 0)` 的第二个参数 `i32 0` 是 Metal 编译器内部标志，MSL 的 `fract()` 不接受。`E-006a2e11` 已修 — `metalIntrinsicMappings` 增加 `mslArgCount` 字段，`translateMetalIntrinsic` 按 `mslArgCount` 过滤多余参数
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
