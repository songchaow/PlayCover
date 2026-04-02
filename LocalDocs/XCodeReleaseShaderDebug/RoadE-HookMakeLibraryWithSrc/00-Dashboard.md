# Road E: Hook makeLibrary 注入 Shader 源码

## 问题背景

外网 Release 包体截帧后，Xcode 打开 `.gputrace` 时大部分 shader 显示 "Shader source not found"，因为 metallib 编译时未嵌入调试信息。PlayCover 已具备对 iOS app 的运行时注入能力（PlayTools via `LC_LOAD_DYLIB`），且已有 `MTLDevice.newCommandQueue` 的 swizzle 先例。

## 最终目标

在 PlayTools 运行时中 hook `MTLDevice.makeLibrary(data:)` 系列 API，从 metallib 中提取 LLVM Bitcode，经 `llvm-dis` 反汇编为 LLVM IR，再**逐指令翻译为语义等价的 MSL 源码**，通过 `makeLibrary(source:)` 重新编译并替换原始返回，使后续截帧的 gputrace 中自动携带 shader 源码。

**核心约束（按优先级）**：
1. **语义等价**：生成的 MSL 必须与原始 IR 逐指令语义等价（不追求还原原始代码风格，接受机械翻译的低可读性代码）
2. **可编译**：生成的 MSL 必须能通过 `makeLibrary(source:)` 编译，且函数签名与原始 metallib 一致
3. **可读性**：在满足 1、2 的前提下尽量提升（如识别 swizzle 模式、还原控制流结构）

**技术路线**：这是一个公开领域中没有先例的 Metal AIR → MSL 反编译器。LLVM 生态没有 IR→源码 的通用工具，Apple 也没有公开 AIR 规范。我们采用逐指令机械翻译（方案 A）——每条 IR 指令都有语义等价的 MSL 写法，因为 MSL 本身就是编译到这些 IR 的源语言。

## Agent 工作流

1. 读取本文档
2. 从 **TODO** 中选取当前最高优先级的 **一个** 未完成任务执行
3. 若发现任务工作量过大或涉及较多子任务，**拆分到 TODO 并只完成其中一个**
4. **编写或补充测试数据，用工具链实际验证**（见下方说明）
5. 执行完毕后更新本文档（任务状态、踩坑经验、参考信息）

> **严禁对着最终目标死磕，每个 agent 只完成一个任务。**

### 测试验证要求

每次修改 IR→MSL 转换逻辑后，**必须尽量做实际验证**，而非仅靠代码审查判断正确性：

- **编写针对性的测试 Metal shader**：在 `test-data/` 下新建 `.metal` 文件，覆盖本次修改涉及的 IR 模式（如 phi 节点→写 `test_phi.metal` 含循环/分支）
- **用工具链生成 IR 并检查**：`xcrun --sdk macosx metal -c xxx.metal -o xxx.air && llvm-dis xxx.air -o xxx.ll`，确认编译器确实生成了目标 IR 模式
- **编译验证**：运行 `FORCE_PLAYTOOLS_REBUILD=1 ./BuildScripts/sync_playtools_xcframework.sh` 确认 PlayTools 编译通过
- **测试数据入库**：将 `.metal` 和 `.ll` 文件提交到 `test-data/`，供后续任务回归使用；清理中间产物（`.air`、`.metallib`）

> 仅凭肉眼 review 代码容易遗漏边界情况（如编译器优化掉 phi、BB 标签格式差异等），实际编译+检查 IR 能暴露这些问题。

## 验证方式

**自动判断（脚本）**：gputrace 中 shader 源码以 `[0-9A-F]{16}` 命名的文本文件存在于根目录。统计数量和内容合法性即可判断覆盖率变化。

```bash
# 快速检查：
Scripts/check_gputrace_sources.py /path/to/xxx.gputrace
```

脚本位置：`Scripts/check_gputrace_sources.py`

**注意**：hash 文件不全是源码——原神的 hash 文件是 bplist（shader 编译统计），须以 `valid_msl_files`（而非 `source_files`）为准。

**基线数据**：

| 截帧 | valid_msl | index 引用 |
|---|---|---|
| QQ飞车外网 | 3 | 1116 |
| 原神外网 | 0 | 851 |

**人工确认（最终）**：Xcode 打开 gputrace → 选 Draw Call → 查看 Shader 面板是否显示源码而非 "Shader source not found"。此步无法自动化。

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

**关键设计决策**：PlayCover 管理的 iOS app 运行在 macOS 用户态（非真正 iOS 沙盒），PlayTools 可以 fork/exec 本地二进制。因此 `llvm-dis` 可直接在 PlayTools 运行时中通过 `Process()` 调用。

## TODO

| # | 任务 | 状态 | 子文档 |
|---|---|---|---|
| E-001 | **可行性 PoC：`-frecord-sources` 重编译验证** | ✅ DONE | [E-001-PoC](E-001-PoC-frecord-sources.md) |
| E-002 | **调研 MTLDevice Library API 入口** | ✅ DONE | [E-002-API](E-002-MTLDevice-Library-API.md) |
| E-003 | **makeLibrary swizzle 骨架** | ✅ DONE | [E-003-Swizzle](E-003-LibrarySwizzleSkeleton.md) |
| E-004 | **metallib → 源码提取**（已拆分） | 🔄 IN PROGRESS | [E-004](E-004-MetallibSourceExtraction.md) |
| E-004a | ↳ metallib 二进制格式解析器 | ✅ DONE | |
| E-004b | ↳ 提取函数级 LLVM Bitcode | ✅ DONE | |
| E-004c | ↳ **LLVM 工具链管理：下载并部署 `llvm-dis`** | ✅ DONE | |
|  | `PlayCover/Utils/LLVMToolManager.swift` — 从 GitHub Releases 下载 LLVM 19.1.0 macOS ARM64 预编译包，提取 `llvm-dis` 安装到 `~/Library/Containers/io.playcover.PlayCover/llvm-tools/` | | |
| E-004d | ↳ **PlayTools 中调用 `llvm-dis` 将 bitcode → LLVM IR 文本** | ✅ DONE | |
|  | `LLVMDisassembler.swift` — posix_spawn 调用 llvm-dis，支持路径自动发现、超时、批量处理、安全包装 | | |
| E-004e | ↳ **LLVM IR → MSL 反编译器**（已拆分） | 🔄 IN PROGRESS | |
|  | 逐指令翻译 IR 为语义等价的 MSL。采用方案 A（机械翻译）：每条 IR 指令对应一个 MSL 临时变量赋值，不追求还原原始代码风格，但保证语义等价且能通过 `makeLibrary(source:)` 编译。函数签名由 metadata 精确还原 | | |
| E-004e1 | ↳↳ IRToMSLConverter 骨架 + stub MSL 生成 | ✅ DONE | |
|  | 解析 IR `define` 行、推断 shader 类型、生成带正确 `[[attribute]]` 标注的 stub MSL。`IRToMSLConverter.swift` | | |
| E-004e2 | ↳↳ addrspace → MSL 地址空间限定符完整映射 | ✅ DONE | |
|  | `AddressSpace` 枚举完整映射 addrspace(0-6)→MSL 限定符（thread/device/constant/threadgroup/threadgroup_imageblock/ray_data/object_data），含 `isBufferAddressSpace`、`isReadOnly` 辅助属性。验证数据：test-data/test_addrspace.metal→.ll（覆盖 device/constant/threadgroup + vertex/fragment/kernel） | | |
| E-004e3 | ↳↳ air.* 内建 → MSL 等效调用映射 | ✅ DONE | |
|  | 84+ 个 air.* 内建映射表（数学/纹理/同步/SIMD/原子/导数/pack），含命名规则解析（strip type suffix、前缀匹配）。验证数据：test-data/test_builtins.metal→.ll | | |
| E-004e4 | ↳↳ 完整函数体转换（IR 指令→MSL 语句）（已拆分） | 🔄 IN PROGRESS | |
| E-004e4a | ↳↳↳ IR 函数体解析 + SSA→MSL 翻译框架 + 基础指令集 | ✅ DONE | |
|  | `SSAContext`（SSA→MSL 映射）+ `translateFunctionBody()` 入口。翻译 20+ 种 IR 指令为语义等价的 MSL 语句（算术/比较/向量/内存/类型转换/air.*/控制流）。`generateFunction` 从 stub 升级为真实函数体生成。验证数据：`test_instructions.metal`→`.ll`（覆盖 sdiv/udiv/srem/urem/shl/lshr/ashr/and/or/xor/sext/fptrunc/mul，fdiv→编译器优化为 fmul 倒数，frem→air.fast_fmod，trunc→i16 直接运算） | | |
| E-004e4b | ↳↳↳ phi 节点 + 多基本块控制流→MSL 变量声明/if/else | ✅ DONE | |
|  | 两遍翻译策略：`prescanPhiAndCFG` 预扫描所有 phi 节点和 CFG 结构，`translateFunctionBody` 第二遍利用预扫描信息。phi→变量预声明+前驱 BB 分支处赋值（语义等价），条件 br→if/else 块（含嵌套 phi 赋值），无条件 br→phi 赋值+fall-through。新增测试数据 `test_phi.metal`→`test_phi.ll`（含循环 phi、多前驱汇合） | | |
| E-004e4c | ↳↳↳ extractvalue/insertvalue + GEP 结构体路径还原 | ✅ DONE | |
|  | `extractvalue`：匿名聚合 `{<4xf32>, i8}`（air.sample 返回值）直接透传、命名结构体用 `.fieldName`。`insertvalue`：链式追踪已填充字段，最终生成 `{ val0, val1, ... }`。`GEP`：多级索引按类型层级解析——结构体字段索引查 metadata `air.struct_type_info` 获取字段名，数组索引生成 `[idx]`。新增解析方法：`parseIRStructTypes`（IR `%struct.XXX = type` 定义）、`parseStructTypeInfoNode`（5-token 格式字段信息）、`parseStructFieldInfoFromMetadata`（全局字段信息表）。SSAContext 扩展：`structTypeDefs`/`structFieldInfo`/`insertValueFields` + `lookupFieldName`/`lookupFieldType` 辅助方法。验证数据：`test_extractvalue.metal`→`test_extractvalue.ll`（覆盖 fragment extractvalue / vertex insertvalue / kernel GEP struct） | | |
| E-005 | **运行时 library 替换：用带源码的 library 替换原始返回** | TODO | |
|  | 在 `pc_newLibraryWithData` hook 中，将 E-004e 生成的 MSL 经 `makeLibrary(source:)` 编译后替换原始返回值。需处理：编译失败 fallback（退回原始 library）、函数签名一致性校验、性能优化（缓存已处理的 metallib） | | |
| E-006 | **端到端验证：语义等价 + 可编译 + 截帧可见** | TODO | |
|  | 验证三层目标：① MSL 能通过 `makeLibrary(source:)` 编译 ② 函数签名与原始 metallib 一致 ③ Xcode 截帧 gputrace 中 shader 源码可见。测试目标：QQ飞车 / 原神外网包 | | |
| E-007 | **PlayCover settings UI 集成** | TODO | |
|  | 添加 `injectShaderSources` 开关到 AppSettings / AppSettingsView；添加 LLVM 工具链下载/状态 UI | | |

## 踩坑与经验

（由 agent 不断维护，保持简要，详情写子文档）

- **PlayTools 最低部署目标低于 iOS 16**：`Substring.split(separator: StringProtocol, maxSplits:)` 方法仅 iOS 16+ 可用，PlayTools 中需使用 `components(separatedBy:)` 替代
- **`-frecord-sources` 不适用于已有 bitcode**：该选项仅在 `metal -c`（MSL→.air）阶段有效，将 MSL 源码嵌入 .air 中。`metallib` 命令不接受此参数。从现有 metallib 提取的 bitcode 不含源码，无法通过重编译补回。因此**必须走 IR→MSL 转换路径**
- **Metal 编译器调用**：必须用 `xcrun --sdk macosx metal` 方式调用，SDK 选择通过 xcrun 的 `--sdk` 参数完成
- **SOURCES section**：`-frecord-sources` 在 metallib 中新增 `SOURCES` section（约占原体积的 90%+），包含完整 MSL 源码文本
- **运行时编译可行**：`MTLDevice.makeLibrary(source:options:)` 在 Apple M4 Pro 上验证通过，函数签名与从 metallib 加载完全一致
- **Metal AIR 地址空间映射**：Metal 使用 LLVM addrspace(0-6)：0=thread, 1=device, 2=constant, 3=threadgroup, 4=threadgroup_imageblock, 5=ray_data, 6=object_data。`constant` 地址空间在 MSL 中隐含只读语义
- **LLVM 15+ Opaque Pointer**：新版 LLVM 默认使用 `ptr addrspace(N)` 而非 `float addrspace(1)*`，丢失了指向的元素类型信息，需从上下文推断或使用通用字节指针 `uint8_t*`
- **IR Metadata 是精确类型信息的唯一来源**：Xcode 16 Metal 编译器生成的 IR 全部使用 opaque pointer，但 `!air.vertex`/`!air.fragment`/`!air.kernel` named metadata 中包含完整的参数信息：`air.arg_type_name`（MSL 类型名）、`air.arg_name`（参数名）、`air.location_index`（绑定索引）、`air.address_space`（地址空间）、`air.read`/`air.read_write`（读写属性）。**必须解析 metadata 才能获取精确类型**
- **stage_in 参数在 IR 层被展平**：vertex_input/fragment_input 在 IR 的 define 行中是值传递的 `<4 x float> %0, <2 x float> %1`，不是指针参数。metadata 中有 `air.vertex_input`/`air.fragment_input` + `air.location_index` 区分
- **texture/sampler 也是 ptr addrspace**：texture 是 `ptr addrspace(1)`、sampler 是 `ptr addrspace(2)`，与普通 buffer 相同地址空间，只能通过 metadata 的 `air.texture`/`air.sampler` 标记区分
- **MSL 不支持 double**：LLVM IR 中的 `double` 类型需降级为 MSL `float`
- **MTLDevice 运行时类**：Apple Silicon 上的实际类是 GPU family 层类（如 M4 Pro=`AGXG16SDevice`），swizzle 必须通过 `object_getClass(device)` 动态获取
- **`newLibraryWithData:error:` 参数类型**：ObjC 层实际参数类型是 `dispatch_data_t`（桥接为 `__DispatchData`），不是 `NSData`
- **metallib 格式（MTLB）**：文件头 56 或 88 字节，magic `MTLB`。四大 section：FunctionList、PublicMetadata、PrivateMetadata、Bitcode。函数 Tag 格式详见 E-004 文档
- **dispatch_data_t → Data 转换**：不能直接 `as? Data`，需通过 `DispatchData.enumerateBytes` 逐段拷贝
- **Bitcode 模块去重**：metallib 中多个函数可能共享同一个 bitcode 模块（相同 OFFT+MDSZ），按 (offset, size) 去重可大幅减少处理量
- **LLVM 工具链**：macOS/Xcode 不自带 `llvm-dis`。LLVM 19.1.0 macOS ARM64 预编译包已验证可用
- **PlayTools 是 iOS target**：不能使用 `Foundation.Process`，必须用 `posix_spawn`。`environ`/wait 宏等需特殊处理，详见 E-004d 文档
- **air.* 内建函数命名规则**：`air.<category>.<name>.<type_suffix>`，type_suffix 编码参数类型（`v4f32`=`<4 x float>`、`v4f16`=`<4 x half>`、`i32`=`i32`）。去掉 type_suffix 后可用前缀匹配定位 MSL 等效调用
- **air.fast_* 与 air.* 双变体**：Metal 编译器在 fast-math 模式（默认）下生成 `air.fast_sin` 等 fast 变体；关闭 fast-math 后生成 `air.sin` 等无前缀变体。两者对应同一个 MSL 函数（`sin`/`cos`/...），映射表需同时覆盖
- **air.convert 命名特殊**：`air.convert.<dst_kind>.<dst_type>.<src_kind>.<src_type>`，如 `air.convert.f.v4f32.s.v4i32`（int4→float4）。整个后缀都是类型编码，strip 时只保留 `air.convert`，目标类型需单独解析
- **air.atomic 带符号性和 scope**：`air.atomic.global.add.u.i32`（global/device 原子 add, unsigned i32）、`air.atomic.local.add.s.i32`（threadgroup 原子 add, signed i32）。strip 时需保留到 op 级别（`air.atomic.global.add`）
- **air.clz/ctz 多一个 bool 参数**：IR 签名 `air.clz.i32(i32, i1)`，第二个参数是 "is_zero_undef" 标志，MSL 的 `clz(x)` 不需要此参数
- **纹理 air 内建是方法调用**：`air.sample_texture_2d.v4f32(tex, sampler, coord, ...)` 对应 MSL `tex.sample(sampler, coord, ...)`，第一个参数是 texture 对象而非普通值参数
- **IR 函数体提取**：`parseIRFunctions` 原来只取 define 行，E-004e4a 改为追踪到 `}` 行收集完整函数体。LLVM IR 的基本块标签有两种格式：纯数字+冒号（`10:`）和名字+冒号（`entry:`），后面可能跟 `; preds = %0, %1` 注释
- **IR 向量 splat**：LLVM 19+ 使用 `splat (float 2.0)` 替代旧式 `<float 2.0, float 2.0, float 2.0, float 2.0>` 向量常量语法
- **纹理 air 调用参数过滤**：`air.sample_texture_2d.v4f32` 除了用户可见参数（texture, sampler, coord）外，还有大量 i1/i32 控制标志（offset, bias 开关, LOD bias 值等），需在翻译时过滤
- **barrier flags 常量映射**：`air.wg.barrier(i32 2, i32 1)` 第一个参数是 mem_flags（1=device, 2=threadgroup, 3=both），第二个是 scope（固定为 1）
- **phi 降级策略**：将 phi 节点翻译为普通变量而非重建完整控制流（嵌套 if/else/loop）。预声明 `<type> phi_N;`，在每个前驱 BB 的 br 指令处插入 `phi_N = <value>;`。这保证语义等价且实现简单。两遍翻译：第一遍 `prescanPhiAndCFG` 收集所有 phi 和 CFG，第二遍利用预扫描信息
- **编译器 select 优化**：简单 if-else（无副作用）会被 Metal 编译器优化为 `select` 指令而非 phi 节点。只有循环、复杂分支、或带副作用的分支才保留 phi
- **基本块标签多格式**：IR 中 BB 标签有三种：纯名字 `entry:`、纯数字 `10:`、带前驱注释 `10:  ; preds = %7, %4`。解析时需同时处理，且要区分标签行和普通含冒号的指令
- **fast-math 下 fdiv/frem 不存在**：Metal 默认开启 fast-math，`fdiv` 被优化为 `fmul` 乘以倒数，`frem` 被翻译为 `air.fast_fmod` 调用。实际 metallib IR 中几乎不会出现 `fdiv`/`frem` 指令
- **trunc 被编译器省略**：`int→short` 截断在 IR 中被优化为直接在 i16 上做 `mul`+`and`，不生成显式 `trunc` 指令。编写测试数据时注意编译器可能优化掉目标指令
- **air.sample 返回值是匿名聚合**：`air.sample_texture_2d.v4f32` 在 IR 中返回 `{ <4 x float>, i8 }`，第二个字段是 coverage mask（片元覆盖信息），绝大多数情况只用 `extractvalue ..., 0` 取 float4。MSL 侧 `tex.sample()` 直接返回 float4，因此 extractvalue 可以透传
- **insertvalue 链式构建返回值**：vertex shader 的返回值结构体（如 `<{ <4 x float>, <2 x float> }>`）在 IR 中通过多步 insertvalue 从 undef 逐字段填充。需在 SSAContext 中追踪中间状态，最终生成 `{ val0, val1, ... }` 的 MSL 初始化列表
- **GEP 结构体索引 vs 数组索引**：GEP 的第一个索引是基指针偏移（可以是变量），后续索引按类型层级解析——对结构体类型必须是常量 i32（字段编号），对数组类型可以是变量。区分方式：当前层类型是否以 `%` 开头（结构体）或 `[` 开头（数组）
- **air.struct_type_info metadata 格式**：每个字段由 5 个 token 组成（offset, size, alignment, typeName, fieldName），如 `i32 0, i32 16, i32 0, !"float3", !"position"`。仅 buffer 参数有此信息，texture/sampler 无
- **IR 结构体类型名映射**：`%struct.Particle` → MSL `Particle`，`%"struct.metal::matrix"` → MSL `metal::matrix`（注意 IR 中带引号的命名格式）

## 参考信息

| 主题 | 位置 |
|---|---|
| 前期调研（5条路线评估） | `../Research/05-可行性评估与路线图.md` |
| Metal 编译流水线 | `../Research/03-Metal-Shader编译流水线.md` |
| gputrace 内部结构 | `../Research/02-gputrace内部结构分析.md` |
| 现有逆向工具 | `../Research/04-现有逆向工具.md` |
| PlayTools swizzle 模板 | `Carthage/Checkouts/PlayTools/PlayTools/MetalCaptureService.swift` — `CommandQueueDiscoverySwizzles` |
| PlayTools DYLD_INTERPOSE 模板 | `Carthage/Checkouts/PlayTools/PlayTools/PlayLoader.m` |
| PlaySettings 数据模型 | `Carthage/Checkouts/PlayTools/PlayTools/PlaySettings.swift` — `AppSettingsData` |
| 已有 Metal hook | 仅 `newCommandQueue` / `newCommandQueueWithMaxCommandBufferCount:`，无 Library/Pipeline 相关 hook |
| MetalLibraryArchive（metallib 解析） | https://github.com/YuAo/MetalLibraryArchive |
| applegpu（GPU ISA 反汇编） | https://github.com/dougallj/applegpu |
| metallib 逆向分析 | https://worthdoingbadly.com/metalbitcode/ |
| Apple metallibdsym 文档 | https://developer.apple.com/documentation/metal/generating-and-loading-a-metal-library-symbol-file |
| LLVM 预编译下载 | https://github.com/llvm/llvm-project/releases （19.1.0 macOS ARM64 已验证可用） |
| PlayCover 外部命令封装 | `PlayCover/Utils/Shell.swift` — `Process()` 封装 |
| PlayCover 组件安装目录 | `~/Library/Containers/io.playcover.PlayCover/` — 见 `PlayTools.swift` |
