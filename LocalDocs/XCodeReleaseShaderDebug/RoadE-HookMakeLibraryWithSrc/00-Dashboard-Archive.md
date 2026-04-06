# Road E Dashboard 归档参考

## 作用

本文档用于承接从 `00-Dashboard.md` 主体下沉的历史信息：旧 live 样本、已完成子任务的详细脉络，以及当前不再需要长期占据 dashboard 主体的经验。`00-Dashboard.md` 只保留当前主线、最新验证、正在推进的 TODO 和仍会影响决策的经验。

> ⚠️ **本文档是历史归档，不代表当前日常工作流。** 当前流程已经切换为 **corpus-driven / offline-first**：先采集真实样本形成 `ShaderCorpus/`，再做离线 replay、批量编译与最小 live 验证；详见 `00-Dashboard.md`。

## 历史 live 样本归档

> 当前最新 live 结果以 `00-Dashboard.md` 为准；这里仅保留更早样本的简要脉络，方便回看 blocker 是如何逐步前移的。

| 时间 / 阶段 | 关键现象 | 结论 |
|---|---|---|
| 2026-04-02，host bridge 修复前 | 重启 PlayCover、重新注入后，`session` 与 `capture_metal_frame` 都能稳定执行；但 `.gputrace` 中 `valid_msl=0`，注入 runtime 内 `posix_spawn(llvm-dis)` 统一报 `Operation not permitted` | 当时主 blocker 仍是 injected runtime 直接拉起 `llvm-dis` 的权限问题 |
| 2026-04-02，host bridge 修复后受控 5 轮复测 | `session` 能 `ready`，但很快 `disconnected`，每轮都新增 `Yuanshen-*.ips`；统一日志已进入 `LibrarySourceInjection` 主路径，并稳定出现 `source recompile failed: expected unqualified-id` | blocker 从"无法执行 `llvm-dis`"前移到 "IR→MSL 产物本身无效" |
| 2026-04-03，preflight guard 后单轮对照复测 | `session` 一度可维持约 73 秒，`get_capture_status` 返回 `available=true`，但最终 crash 栈顶落在 `playcover.toucher` 的 `Toucher.touchcam(...)` Optional unwrap | preflight guard 已显著改变 live 表现，说明应先隔离 toucher / keymapping 干扰 |
| 2026-04-03，关闭 `keymapping` 后 2 轮受控复测 | crash 从 `playcover.toucher` 转回 `UnityGfxDeviceWorker`；同时 `ShaderSourceDiagnostics` 再次出现 `preflight_rejected` / `compile_failed`，坏行示例为 `fragment float4{ <4 xlatMtlMain(...)` | toucher / keymapping 干扰已基本剥离，主 blocker 回到 IR→MSL lowering |
| 2026-04-03，`E-006a2d3` 后单轮 live 复测 | `create_session(timeout=30)` 在 30 秒内未等到 runtime 注册；新的 diagnostics 已从 `<N x T>` / `%...` 残留前移到 vertex `xlatMtlMain` 的参数映射 / pointer 访问坏行 | 说明 `E-006a2d3` 已清掉一批 SSA/vector 问题，但仍被 vertex `stage_in` / pointer 发射拦住 |
| 2026-04-03，`E-006a2e3` 后单轮 live 复测 | `session` 10 秒内 `ready` 后 ~10 秒 `disconnected`，无新 crash report。diagnostics 仅 `compile_failed`（无 `preflight_rejected`）；旧 blocker 全清。新 blocker 为 `clamp`/`fma` 歧义、`bool2` → `bool` 赋值、`uint8_t2` 不存在 | `undef` / `0xH8000` 修复有效，blocker 进一步前移到 intrinsic 类型系统与 vector 整型映射 |
| 2026-04-04，`E-006c` 真实 `.gputrace` 可见性确认 | 原神现存 6 份 `.gputrace` 批量检查 `valid_msl_files` 全为 `0`；Xcode 可打开 `capture_20260402_roadE_e006_diag.gputrace` 并进入 draw call 分析，但 fresh `launch_app -> create_session` 后 session 很快 `disconnected`，新增 `Yuanshen-2026-04-04-015803.ips`（`EXC_BAD_ACCESS / SIGSEGV`） | 说明当前 trace 仍只具备"可开/可步进"而非"源码可见"；主 blocker 仍在 IR→MSL 有效性与 live 稳定性，`E-006c` 暂不能关单 |
| 2026-04-05，`E-006d8` 五轮矩阵 + fresh `replacement-on-run3` | 最近一串提交把 `run matrix`、benign metadata drift 过滤、`replacement_attempt` 落盘与文档口径逐步收敛到同一主线；fresh `replacement-on-run3` 已恢复 `replacement_attempt=91`、`replacement=36`，但 `session=ready` 后仍会在 `get_capture_status` / `capture_metal_frame` 前后掉线 | 当前主线已从"为什么没有 replacement attempt"收窄为"session/capture bridge 不稳定 + 55 个 `llvm-dis` 权限失败样本"；并且这两条线都应继续通过 agent 可独立完成的自动流程推进，而不是重新引入人工 gate |
| 2026-04-05，`E-006d8` fresh `replacement-on-run5` 恢复 | fresh build/install + 注入后 `session=ready`，成功产出带源码的 `.gputrace`（`valid_msl=2/11`）；launch / registration 主链恢复；`RuntimeLaunchDiagnostics` 记录了完整阶段链路 | capture 链路恢复，但 trace 侧合法 MSL 覆盖仍偏低 |
| 2026-04-06，`E-006d8` host split-brain 修复 + `replacement-on-run6` | 定位到 `SessionHealthMonitor` stale cleanup 只删 registry 不断 registration channel；修复为同步 `disconnectSessions(...)` + 测试覆盖。`on-run6` 再次验证 launch / registration 可拉起 | split-brain 型 `Session not registered` 修复已落地；当前 blocker 前移为 capture bridge reachability |
| 2026-04-06，`E-006d8` capture status probe decoupling + `replacement-on-run7` | `get_capture_status` 反复 `Receive timed out`，但 session 保持 `ready` 未再掉线；不再复现 split-brain。定位到 status probe 自身承担了两层不当副作用：①强制 `valueOnMainSync` 占用主线程；②触发 `ensureGPUToolsCaptureLoaded()` / `dlopen(libmtlcapture)`。修复为 runtime 侧去 lazy-load + 去 valueOnMainSync + 线程安全快照。`e006d_render_diff.py` 落地，四条 blocker 正式收敛 | blocker #1 排查面收窄；区分"capture 库未加载"与"真正 bridge / capture timeout"能力已具备 |
| 2026-04-06，`E-006d8` fresh `replacement-on-run8` / `on-run9` | **这两轮是 capture bridge reachability 关键证据**：`on-run8` 说明加载期 command bridge / capture command 存在时序波动，但 `.gputrace` 可能稍后在默认容器落盘；`on-run9` 进一步明确——直接对 `list_sessions` 中的 ready session 执行 `get_capture_status` / `capture_metal_frame` 可立即成功（`available=true / supportsGPUTrace=true / trackedCommandQueues=2`），但同轮 `create_session(bundleId, timeout=20)` 仍报 bridge not reachable；同时自定义 `output_path` 落在 app 默认容器 `Captures/` 内时也可成功。**最终 blocker #1 从"capture/status 命令是否整体不可达"收窄到 host 侧 `create_session` reachability probe / ready-session 复用判定分歧；blocker #2 从"自定义路径全部被拒"修正为"容器外路径权限边界未明"。** 详见 `E-006d-GenshinRenderingNondeterminism.md` | blocker #1 已基本收敛 |
| 2026-04-06，`E-006d8` fresh `replacement-on-run10` + blocker #1 live 复测 | `create_session(bundleId)` 首次即返回 ready session，`get_capture_status` 最终进入 `available=true`，容器内显式 `output_path` 的 `capture_metal_frame` 成功并经 `finalize-run --latest-gputrace` 固化。出现过一次短暂 `list_sessions` 空窗，但再次 `create_session(bundleId)` 仍可立即命中同一 runtime，更像 session 可见性抖动而非 bundle 级 reachability 失败。后续用 v4 工具复盘确认：canonical `index` 统计仍为 `valid MSL = 0/807`、`referenced non-MSL = 9`、`missing = 798`，trace 目录里另有 2 个 14/15 位短 hash bplist；11/11 可见 hash 文件均非 MSL。**blocker #1 基本收敛**，主排查面转向 trace 导出 / 源码未写入 bundle | blocker #1 基本收敛，主瓶颈转向 trace 合法 MSL 覆盖偏低 |
| 2026-04-06，`E-006d8-b3` source attribution preload 验证 + `replacement-on-run11` | 在 `PlayCover.launch()` 早期预加载 GPUToolsCapture 后，fresh live 中 `get_capture_status` 显示 `gpuToolsCaptureLoaded=true`、latest queue class=`CaptureMTLCommandQueue`。第一次 `device` capture 仍报 bridge timeout，只落盘瘦 trace（仅 `index/metadata/store0`，`14` 个 hash 全缺失）；第二次在更稳定界面下切到 `scope`，`capture_20260406_sourcepreload_validation.gputrace` / `replacement-on-run11` 出现 14 个可见 hash，其中 3 个为被 `index` 引用的合法 MSL，canonical `index` 提升为 `922 refs = 3 valid + 9 referenced non-MSL + 910 missing` | 说明 preload 修复已让源码重新进入 trace；主 blocker 从“完全未写入 bundle”收窄为“只部分写入、覆盖率仍极低” |

## 已完成子任务归档

### E-005：payload 恢复与 runtime library 替换

- **`E-005a` / `E-005b`**：`pc_newLibraryWithData` 主路径已接入 `bitcode 提取 → llvm-dis → IRToMSLConverter → makeLibrary(source:)`；多 module 聚合也已落地，并明确采用"全成全退"策略。
- **`E-005e` 当前结论**：对已知真实样本，wrapper / header-compat / function list / `OFFT` slicing 已打通；raw `MTLB` / `xar` / `bplist_keyed_archive` recovered payload 都已推进到 `OK modules=3 functions=3` 且 `valid_llvm=3`。这条链路对当前已知样本不再是主 blocker。
- **`E-005e1 / E-005e1b`**：已补 `payload` 指纹、前导字节、`dispatch_data` 运行时类名，以及非 `MTLB` payload 的调用栈诊断，便于下一轮 live 样本反推上游来源。
- **`E-005e2a` 系列**：已落地通用 wrapper 剥离、`mtlb_suspicious` 二次剥离、非标准 raw `MTLB` header 兼容解析，并把未识别或已 recovered 的 payload 落盘到 `ShaderPayloadSamples`。
- **`E-005e2b` 系列**：已打通 `gzip`、`zip`、`xar`、`NSKeyedArchiver bplist` 的定向恢复路径；剩余"其他自定义 archive / keyed archive"仅在出现新的真实样本时再继续。

### E-006：live blocker 前移路径

- **`E-006a1`**：runtime→host `llvm-dis` bridge 已落地；`RegistrationListener` / `MCPManager` / `LLVMToolManager` 可承接 `host_disassemble_bitcode`，runtime 侧改为优先走 bridge。
- **`E-006a2a`**：`LibrarySourceInjectionService` 已在 `makeLibrary(source:)` 前加入 preflight，并把 `preflight_rejected` / `compile_failed` 的聚合源码和上下文落到 `ShaderSourceDiagnostics/<bundleId>/`。
- **`E-006a2b`**：preflight guard 改变了 live 基线，说明问题已不再只是"刚 ready 就掉线"，而是开始进入更可定位的 runtime / shader 主线分流。
- **`E-006a2c1 / E-006a2c2`**：先修 `Toucher.touchcam` 的 `keyWindow` 空值崩溃，再通过禁用 `keymapping` 的受控复测把 toucher 干扰从 shader 主线里剥离。
- **`E-006a2d1`**：修 fragment packed-return 误判为向量的问题；最小样本验证 `<{ <4 x float> }>` 必须先走 aggregate 分支。
- **`E-006a2d2a`**：修 metadata→参数映射、suffixed SSA 回接，以及 `fadd/fmul/fdiv fast` 共享类型二元算术解析。
- **`E-006a2d2b`**：修 texture/sampler 形参发射、自定义 struct 字段命名/定义、`air.struct_type_info` 提取和 fragment `stage_in` 合成。
- **`E-006a2d3`**：修 vertex aggregate return 与向量维度收敛；return metadata 现可驱动真正的 entry output struct 发射。
- **`E-006a2d4`**：修 vertex `stage_in` 参数映射与 pointer-like SSA 发射；live 已确认 `param1/param2/param3`、`device T*` 坏访问与 `*(&...)` 不再出现。
- **`E-006a2e2`**：修 `undef` / `0xH` half hex lowering；在 `IRToMSLConverter` 中统一处理了带类型前缀的 `undef`/`poison`（如 `float undef`）和 LLVM IR half 立即数（如 `0xH8000` → IEEE-754 转十进制或 `as_type<half>(ushort(...))`）。
- **`E-006a2e3`**：live 重装 / 重注入复测确认旧 blocker 全清。`session` 10 秒内 `ready` 后 ~10 秒 `disconnected`（无新 crash report）。diagnostics 仅 `compile_failed`，`undef`/`0xH8000`/`stage_in`/`device T*`/`*(&...)` 全部消失。新 blocker 收敛到：①`clamp`/`fma` 的 `half`/`float` 重载歧义；②vector `icmp` 产出 `boolN` 赋给 `bool`；③`uint8_t2` 不存在（应为 `uchar2`）。当前已交接 `E-006a2e4`。

## 经验归档

### 从 dashboard 主体下沉的非当前决策性备注

- 以下内容曾在 `00-Dashboard.md` 的"踩坑与经验"中长期保留，但它们更适合作为**历史实现脉络 / 已收敛技术经验**来查阅，而不是继续占据当前控制面：
  - 早期 live 中 `session ready` / crash / diagnostics 三者之间的时间线关系
  - `IR metadata`、缺失值参数 fallback、`air.struct_type_info`、结构体类型名一致性等 lowering 细节
  - 注入 MSL 注释识别、重复函数名、多模块聚合失败等已知 compile blocker 的历史演进
- 当前 dashboard 只保留仍直接影响"下一步做什么"的规则；这些历史技术备注如果再次影响判断，应优先回看 `E-004-MetallibSourceExtraction.md`、`E-006d-GenshinRenderingNondeterminism.md` 与本归档。

### Payload / wrapper 恢复

- **真实 `headerSize=15` 样本里的 `OFFT` payload 是 3×`UInt64` 三元组**：前两项分别是 public/private metadata 偏移，第 3 项才是 bitcode section 内相对偏移；此前误读首个 `UInt64` 才会把 3 个 module 错切成 `0/8/16`。
- **`functionList` section 不能从 offset 0 直接按 tag 流读取**：真实 `headerSize=15` 样本在 section 开头先放 `4-byte entryCount`，每个函数 entry 再以 `4-byte tagGroupSize` 开头；`functionListSize` 看起来只覆盖各 entry 的 size 总和，不包含最前面的 `entryCount`。
- **`OFFT` / `MDSZ` 这类 payload 的定长字段不要直接 `withUnsafeBytes.load(as:)`**：在 macOS/iOS 运行时可能触发未对齐访问崩溃，统一走按字节拼装的 `UInt16/32/64` helper 更稳。
- **`headerSize=0` 失败场景现在应先看 payload 指纹日志**：确认 `dispatch_data` 类名、hex / ASCII 前导字节，以及 `MTLB/bplist/zip/gzip/llvm bitcode` 等格式指纹，再决定是否继续解包。
- **对可疑 `MTLB` 应先尝试 direct compat parse**：`MTLB` magic 不是 raw metallib 的充分条件，但 `headerSize` 异常也不等于假头；`xar` / `NSKeyedArchiver` 解包后的 payload 可能就是 offset 0 的异常 raw `MTLB`。
- **`NSKeyedArchiver` 本质仍是 `bplist`，但应单独标成 `bplist_keyed_archive`**：优先把 `$objects[...]` 当作专用候选空间，再配合 `$top` / `CF$UID` 追踪，诊断语义更完整。
- **`gzip` / `zip` / `xar` 的恢复策略已经定型**：`gzip` 优先走 `inflateInit2(15 + 32)`，`zip` 先读 central directory 再 fallback 扫 local header，`xar` 则先抓 big-endian header + zlib TOC + heap entry。

### Host bridge / runtime 约束

- **`NSHomeDirectory()` 在 injected runtime 中返回的是目标 app 容器，不是宿主用户 Home**：宿主 LLVM 工具链路径不能直接基于它拼接。
- **PlayTools 是 iOS target**：不能依赖 `Foundation.Process`；若必须在 injected runtime 内起子进程，只能自己走 `posix_spawn`。
- **真正拦住 `llvm-dis` 的不是"找不到工具"，而是目标 app 的 macOS sandbox**：`composeEntitlements()` 会带 `com.apple.security.app-sandbox = true`，SBPL 中明确有 `(deny process-fork)`。
- **现有 `RegistrationListener` 足够承接一次性 runtime→host 工具请求**：不必额外新开 IPC；新增短连接 `command` / `commandResponse` 即可。

### IR→MSL 历史修复

- **`<{ ... }>` packed return 必须先于 `<N x T>` 向量分支处理**：否则会把 packed aggregate 错拆成 `float4{ <4` 这类坏函数签名。
- **参数映射必须按 metadata `argIndex` 精确回接，且不能继续跳过 `air.vertex_input`**：否则 vertex `%0/%1/%2` 容易退化成 `param0/param1/param2`。
- **`parseMetadataFuncNode` 里拿参数列表引用时，不能把开头的 `ptr @func` 也算进 `refs` 下标**：`parseMetadataRefList(...)` 实际只返回 `!N` 引用。
- **`setupParameterMappings` 必须吃"纯 IR 参数列表"，不能喂整条 `define ...` 签名**：否则会出现把 `long(tid)` 错翻成 `long(vectorOut)` 这类回接错误。
- **LLVM 二元算术要按 `<type> lhs, rhs` 的共享类型文法解析**：尤其是 `fadd/fmul/fdiv fast` 的第二个操作数不会重复写类型。
- **metadata token 拆分必须识别引号上下文**：`!"texture2d<float, sample>"` 这类字符串内部自带逗号，不能按普通 token 切。
- **`parseStructFieldInfoFromMetadata` 必须先取 `=` 右侧的 node content**：否则 `Uniforms` / `Particle` 这类字段表会一直为空。
- **vertex/fragment 的 return metadata 不只是用来判断 stage type**：它还必须驱动真正的 entry output struct 发射。
- **`shufflevector ... <N x i32> zeroinitializer` 的结果维度必须跟着 mask type 走**：不能把 `zeroinitializer` 一律当成 4 维。

### Live 复测方法论

- **host bridge 版本 live 复测要同时看 session、进程、crash report 与 diagnostics**：`create_session` 返回 `ready` 只能说明 runtime 曾注册过，不能说明应用已经稳定。
- **"`llvm-dis` 权限问题已解"不等于 live 主线已通**：统一日志里看到 `LibrarySourceInjection` 主路径稳定执行，往往意味着问题已经前移到 IR→MSL 产物 / fallback / 运行时稳定性层。
- **先堵 toucher 自身硬崩溃，再做 keymapping 隔离复测**：这样才能把 shader 主线问题和输入路径问题拆开看。
- **关闭 `keymapping` 后若 crash 从 `playcover.toucher` 转回 `UnityGfxDeviceWorker`，说明 toucher 干扰已基本剥离**。
- **即使 `session` 从未 `ready`，live 复测也要同时对齐 diagnostics 与 crash 时间线**：diagnostics 往往比 MCP 的 session 状态更早给出有效信号。

## 参考跳转

- 当前主线、最新验证与最新 TODO：`00-Dashboard.md`
- metallib / bitcode / llvm-dis / IR→MSL 主实现记录：`E-004-MetallibSourceExtraction.md`
