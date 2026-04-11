//
//  IRToMSLConverter.swift
//  PlayTools
//
//  E-004e: LLVM IR → MSL 转换器
//  从 llvm-dis 生成的 LLVM IR 文本中提取 Metal shader 函数信息，
//  生成可通过 makeLibrary(source:) 编译的 MSL 源码。
//
//  完成阶段：
//  - E-004e1: 基础骨架 + stub MSL 生成 ✅
//  - E-004e2: addrspace → MSL 地址空间限定符完整映射 ✅
//  - E-004e3: air.* 内建 → MSL 等效调用映射 ✅
//  - E-004e4: 完整函数体转换（已拆分）
//    · E-004e4a: IR 函数体解析 + SSA→MSL 表达式翻译框架 ✅
//      - IRBodyParser: 解析函数体 IR 指令流
//      - SSAContext: SSA 寄存器→MSL 表达式映射
//      - 翻译基础指令集: 算术(fadd/fmul/fsub/add/sub/mul/fma),
//        向量(shufflevector/extractelement/insertelement/extractvalue/insertvalue),
//        内存(load/store/getelementptr), 类型转换(zext/sext/fpext/fptrunc/bitcast),
//        控制流(ret/br/select), 比较(icmp/fcmp), air.* 内建调用
//      - generateFunction 从 stub 升级为真实函数体生成
//    · E-004e4b: phi 节点+多基本块控制流→MSL 变量声明/if/else ✅
//      - 两遍翻译：prescanPhiAndCFG 预扫描 + 翻译阶段利用预扫描信息
//      - phi → 变量预声明 + 在前驱 BB 分支处赋值（语义等价）
//      - 条件 br → if/else 块结构（含嵌套 phi 赋值）
//      - 无条件 br → phi 赋值 + fall-through
//    · E-004e4c: extractvalue/insertvalue + GEP 结构体路径还原 ✅
//      - 解析 IR 结构体定义 (%struct.XXX = type { ... })
//      - 解析 metadata 的 air.struct_type_info 获取字段名
//      - extractvalue: 从结构体中提取字段（如 air.sample 返回的 {float4, i8}）
//      - insertvalue: 构建返回值结构体（逐字段赋值）
//      - GEP: 结构体字段索引→正确的 .fieldN 成员访问
//

import Foundation

// MARK: - IRToMSLConverter

/// 将 LLVM IR 文本转换为可编译的 MSL (Metal Shading Language) 源码。
///
/// Metal 编译器（metal -c）将 MSL 编译为 AIR (Apple Intermediate Representation)，
/// 它是 LLVM IR 的一个 Metal 特化方言。llvm-dis 将 AIR 反汇编回标准 LLVM IR 文本格式。
/// 本转换器从 LLVM IR 文本中提取 shader 函数信息，重建可编译的 MSL 源码。
struct IRToMSLConverter {

    // MARK: - Error types

    enum ConversionError: LocalizedError {
        case emptyIR
        case noShaderFunctionsFound
        case parseError(String)

        var errorDescription: String? {
            switch self {
            case .emptyIR:
                return "Empty IR text provided"
            case .noShaderFunctionsFound:
                return "No Metal shader functions found in IR"
            case .parseError(let detail):
                return "IR parse error: \(detail)"
            }
        }
    }

    // MARK: - Parsed types

    /// Metal shader 函数的地址空间（对应 LLVM IR 中的 addrspace(N)）
    ///
    /// Metal AIR (Apple Intermediate Representation) 使用 LLVM 地址空间标注：
    /// - addrspace(0): thread — 线程私有内存（默认）
    /// - addrspace(1): device — 设备内存，可读写
    /// - addrspace(2): constant — 常量内存，只读（硬件优化路径）
    /// - addrspace(3): threadgroup — 线程组共享内存
    /// - addrspace(4): threadgroup_imageblock — Metal 2+ imageblock 内存
    /// - addrspace(5): ray_data — Metal raytracing intersection 数据
    /// - addrspace(6): object_data — Metal mesh shader object 数据
    enum AddressSpace: Int {
        case thread = 0              // addrspace(0) → thread (default, no qualifier)
        case device = 1              // addrspace(1) → device
        case constant = 2            // addrspace(2) → constant
        case threadgroup = 3         // addrspace(3) → threadgroup
        case threadgroupImageblock = 4  // addrspace(4) → threadgroup_imageblock
        case rayData = 5             // addrspace(5) → ray_data
        case objectData = 6          // addrspace(6) → object_data

        /// MSL 地址空间限定符
        var mslQualifier: String {
            switch self {
            case .thread: return ""
            case .device: return "device"
            case .constant: return "constant"
            case .threadgroup: return "threadgroup"
            case .threadgroupImageblock: return "threadgroup_imageblock"
            case .rayData: return "ray_data"
            case .objectData: return "object_data"
            }
        }

        /// 该地址空间是否表示需要 [[buffer(N)]] 标注的参数
        var isBufferAddressSpace: Bool {
            switch self {
            case .device, .constant: return true
            default: return false
            }
        }

        /// 该地址空间是否表示只读（constant 地址空间在 MSL 中是只读的）
        var isReadOnly: Bool {
            return self == .constant
        }

        /// 该地址空间是否需要 [[threadgroup(N)]] 标注
        var isThreadgroupAddressSpace: Bool {
            return self == .threadgroup
        }
    }

    /// 从 IR 参数中解析出的指针信息
    struct PointerInfo {
        /// 地址空间
        let addressSpace: AddressSpace
        /// 指针指向的元素类型（MSL 类型字符串）
        /// 对于 opaque pointer (`ptr addrspace(N)`)，需要从上下文推断
        let pointedMSLType: String
        /// 是否为 opaque pointer（LLVM 15+ 默认使用 opaque pointer）
        let isOpaquePointer: Bool
    }

    /// Metal shader 函数类型
    enum ShaderType: String {
        case vertex
        case fragment
        case kernel
        case helper

        /// 从 IR 函数属性中推断 shader 类型
        static func fromIRAttributes(_ attributes: String) -> ShaderType? {
            // Metal shader functions are annotated in IR metadata
            // "air.vertex" / "air.fragment" / "air.kernel"
            if attributes.contains("vertex") { return .vertex }
            if attributes.contains("fragment") { return .fragment }
            if attributes.contains("kernel") { return .kernel }
            return nil
        }
    }

    /// 从 IR 中解析出的 shader 函数参数
    struct ParsedParameter {
        let name: String
        let irType: String
        let addressSpace: AddressSpace?
        /// buffer 绑定索引（如果有 [[buffer(N)]]）
        let bufferIndex: Int?
        /// 属性标注（如 [[position]]、[[vertex_id]]、[[texture(N)]] 等）
        let attribute: String?
        /// 指针信息（如果参数是指针类型）
        let pointerInfo: PointerInfo?
        /// 参数在原始 IR `define` 参数列表中的索引（来自 metadata）
        let irArgIndex: Int?
        /// 参数在 AIR metadata 中的语义种类（如 `air.buffer` / `air.fragment_input` / `air.texture`）
        let kind: String?
        let hasNoAlias: Bool
        /// metadata 未覆盖时，从原始 IR 参数列表补齐的普通值参数需要显式发射到 entry signature。
        let emitAsValueParameter: Bool

        /// 生成该参数的 MSL 声明字符串
        var mslDeclaration: String? {
            // 有指针信息时生成精确声明
            if let ptr = pointerInfo {
                let qualifier = ptr.addressSpace.mslQualifier
                guard !qualifier.isEmpty else { return nil }

                let elemType = ptr.pointedMSLType
                let constPrefix = ptr.addressSpace.isReadOnly ? "const " : ""
                let restrictPrefix = hasNoAlias ? "__restrict " : ""

                if ptr.addressSpace.isBufferAddressSpace {
                    let idx = bufferIndex ?? 0
                    return "\(constPrefix)\(qualifier) \(elemType)* \(restrictPrefix)\(name) [[buffer(\(idx))]]"
                } else if ptr.addressSpace.isThreadgroupAddressSpace {
                    let idx = bufferIndex ?? 0
                    return "threadgroup \(elemType)* \(name) [[threadgroup(\(idx))]]"
                } else {
                    return "\(qualifier) \(elemType)* \(name)"
                }
            }

            // 非指针参数
            if let attr = attribute {
                if irType.hasPrefix("texture") {
                    return "\(IRToMSLConverter.cleanTextureTypeName(irType)) \(name) \(attr)"
                }
                if irType == "sampler" {
                    return "sampler \(name) \(attr)"
                }
                let mslType = IRToMSLConverter.irScalarTypeToMSL(irType)
                return "\(mslType) \(name) \(attr)"
            }

            return nil
        }
    }

    /// 从 IR 中解析出的 shader / helper 函数
    struct ParsedShaderFunction {
        let name: String
        let shaderType: ShaderType
        /// 是否是实际的 shader entry（vertex / fragment / kernel）
        let isEntryPoint: Bool
        let returnType: String
        /// 返回值字段（来自 metadata return node；多字段时需要生成 entry output struct）
        let outputs: [MetadataReturnInfo]
        let parameters: [ParsedParameter]
        /// 从 IR metadata 中提取的原始函数签名
        let irSignature: String
        /// 是否成功解析了完整签名
        let isFullyParsed: Bool
        /// 函数体中使用的 air.* 内建调用（E-004e3）
        let airBuiltinCalls: [AirBuiltinCall]
        /// 函数体 IR 文本（从 define 到 }，不含签名行）（E-004e4）
        let irBody: String
    }

    /// 转换结果
    struct ConversionResult {
        /// 生成的 MSL 源码
        let mslSource: String
        /// 解析出的 shader 函数列表
        let functions: [ParsedShaderFunction]
        /// 转换耗时（秒）
        let elapsedSeconds: Double
        /// 转换统计
        let stats: ConversionStats

        var summary: String {
            "functions=\(functions.count), " +
            "mslSize=\(mslSource.utf8.count), " +
            "elapsed=\(String(format: "%.3f", elapsedSeconds))s, " +
            "\(stats.summary)"
        }
    }

    /// 转换统计
    struct ConversionStats {
        var totalIRFunctions: Int = 0
        var shaderFunctions: Int = 0
        var fullyParsedFunctions: Int = 0
        var stubFunctions: Int = 0
        /// air.* 内建调用总数
        var airBuiltinCalls: Int = 0
        /// 已有映射的 air.* 调用数
        var mappedAirCalls: Int = 0
        /// 未映射的 air.* 调用数
        var unmappedAirCalls: Int = 0

        var summary: String {
            "irFuncs=\(totalIRFunctions), " +
            "shaders=\(shaderFunctions), " +
            "parsed=\(fullyParsedFunctions), " +
            "stubs=\(stubFunctions), " +
            "airCalls=\(airBuiltinCalls)(mapped=\(mappedAirCalls),unmapped=\(unmappedAirCalls))"
        }
    }

    // MARK: - Air Builtin Mapping (E-004e3)

    /// air.* 内建函数的分类。
    ///
    /// Metal 编译器将 MSL 标准库函数编译为 `air.*` 前缀的 LLVM IR 内建调用。
    /// 函数名采用 `air.<category>.<name>.<type_suffix>` 的命名规则，
    /// 其中 type_suffix 编码了参数/返回值类型（如 `v4f32` = `<4 x float>`）。
    enum AirBuiltinCategory: String {
        /// 纹理操作：sample, read, write, get_width/height 等
        case texture
        /// 同步屏障：threadgroup_barrier, simdgroup_barrier
        case synchronization
        /// 类型转换：float↔int, float↔half 等
        case conversion
        /// 数学函数：sin, cos, sqrt, dot, cross, normalize 等
        case math
        /// 整数数学和位操作：abs, min, max, clz, popcount, reverse_bits 等
        case integerMath
        /// SIMD/quad-group 操作：shuffle, reduce, broadcast, prefix_sum 等
        case simd
        /// 原子操作：atomic_add, atomic_cmpxchg 等
        case atomic
        /// 片段着色器特有：dfdx, dfdy, fwidth
        case fragmentDerivative
        /// pack/unpack：snorm4x8, unorm4x8 等
        case packUnpack
        /// 其他/未分类
        case misc
    }

    /// air.* 内建函数到 MSL 等效调用的映射条目。
    ///
    /// 每个条目描述一个 air 内建函数模式和对应的 MSL 调用方式。
    /// `airPattern` 使用前缀匹配：去掉类型后缀（如 `.v4f32`）后，
    /// 与 air 函数名的前缀进行匹配。
    struct AirBuiltinMapping {
        /// air 函数名前缀（去掉 type suffix），如 "air.fast_sin"
        let airPattern: String
        /// 对应的 MSL 函数/方法名，如 "sin"
        let mslFunction: String
        /// 分类
        let category: AirBuiltinCategory
        /// 参数数量（不含类型后缀中的隐含参数）：
        /// - 对于普通函数：实际 MSL 参数数
        /// - 对于纹理方法：-1 表示复杂签名，需特殊处理
        let paramCount: Int
        /// 是否为方法调用（如 texture.sample）而非自由函数
        let isMethodCall: Bool
        /// 简要描述
        let description: String
    }

    /// 从 IR 函数体中提取的 air.* 调用记录
    struct AirBuiltinCall {
        /// 被调用的 air 函数完整名称（如 "air.fast_sin.v4f32"）
        let airFunctionName: String
        /// 去掉类型后缀的函数名（如 "air.fast_sin"）
        let airBaseName: String
        /// 查到的映射（如有）
        let mapping: AirBuiltinMapping?
        /// IR 中的调用参数（原始文本）
        let irArguments: String
        /// 返回值 SSA 名（如 "%8"）
        let resultSSA: String?
    }

    /// 从 IR 顶层全局常量声明中提取的常量定义。
    struct IRGlobalConstant {
        /// IR 符号名（包含前缀 `@`）
        let irName: String
        /// 该常量的 IR 类型（如 `[4 x <4 x float>]`）
        let irType: String
        /// 初始化表达式（如 `[<4 x float> <...>, ...]`）
        let initializer: String
    }

    // swiftlint:disable function_body_length
    /// 完整的 air.* → MSL 映射表。
    ///
    /// 数据来源：将覆盖各类 MSL 内建函数的测试 shader 编译为 AIR 后
    /// 用 llvm-dis 反汇编，从实际 IR 中提取得到。
    /// 参见：test-data/test_builtins.metal, test-data/test_builtins.ll
    static let airBuiltinMappings: [AirBuiltinMapping] = {
        var m: [AirBuiltinMapping] = []

        // ── 数学函数（一元）──
        // Metal 编译器在 fast-math 模式下生成 air.fast_* 前缀，
        // 非 fast-math 模式生成 air.* 前缀（无 fast_）。两者都需映射。
        let unaryMath: [(String, String)] = [
            ("sin", "sin"), ("cos", "cos"), ("tan", "tan"),
            ("exp", "exp"), ("exp2", "exp2"),
            ("log", "log"), ("log2", "log2"),
            ("sqrt", "sqrt"), ("rsqrt", "rsqrt"),
            ("fabs", "abs"), ("floor", "floor"), ("ceil", "ceil"),
            ("round", "round"), ("rint", "rint"), ("trunc", "trunc"), ("fract", "fract"),
            ("saturate", "saturate"),
            ("asin", "asin"), ("acos", "acos"), ("atan", "atan"),
            ("sinh", "sinh"), ("cosh", "cosh"), ("tanh", "tanh"),
        ]
        for (airName, mslName) in unaryMath {
            // fast_* 变体
            m.append(AirBuiltinMapping(
                airPattern: "air.fast_\(airName)",
                mslFunction: mslName,
                category: .math,
                paramCount: 1,
                isMethodCall: false,
                description: "fast \(mslName)(x)"
            ))
            // 非 fast 变体
            m.append(AirBuiltinMapping(
                airPattern: "air.\(airName)",
                mslFunction: mslName,
                category: .math,
                paramCount: 1,
                isMethodCall: false,
                description: "\(mslName)(x)"
            ))
        }

        // sign 和 mix 没有 fast_ 前缀
        m.append(AirBuiltinMapping(
            airPattern: "air.sign",
            mslFunction: "sign",
            category: .math,
            paramCount: 1,
            isMethodCall: false,
            description: "sign(x)"
        ))

        // ── 数学函数（二元）──
        let binaryMath: [(String, String)] = [
            ("fmin", "fmin"), ("fmax", "fmax"),
            ("pow", "pow"), ("fmod", "fmod"),
            ("atan2", "atan2"), ("copysign", "copysign"),
            ("fdim", "fdim"), ("step", "step"),
        ]
        for (airName, mslName) in binaryMath {
            m.append(AirBuiltinMapping(
                airPattern: "air.fast_\(airName)",
                mslFunction: mslName,
                category: .math,
                paramCount: 2,
                isMethodCall: false,
                description: "fast \(mslName)(a, b)"
            ))
            m.append(AirBuiltinMapping(
                airPattern: "air.\(airName)",
                mslFunction: mslName,
                category: .math,
                paramCount: 2,
                isMethodCall: false,
                description: "\(mslName)(a, b)"
            ))
        }

        // ── 数学函数（三元）──
        let ternaryMath: [(String, String)] = [
            ("clamp", "clamp"), ("mix", "mix"),
            ("smoothstep", "smoothstep"), ("fma", "fma"),
        ]
        for (airName, mslName) in ternaryMath {
            m.append(AirBuiltinMapping(
                airPattern: "air.fast_\(airName)",
                mslFunction: mslName,
                category: .math,
                paramCount: 3,
                isMethodCall: false,
                description: "fast \(mslName)(a, b, c)"
            ))
            m.append(AirBuiltinMapping(
                airPattern: "air.\(airName)",
                mslFunction: mslName,
                category: .math,
                paramCount: 3,
                isMethodCall: false,
                description: "\(mslName)(a, b, c)"
            ))
        }

        // ── 向量运算 ──
        m.append(AirBuiltinMapping(
            airPattern: "air.dot",
            mslFunction: "dot",
            category: .math,
            paramCount: 2,
            isMethodCall: false,
            description: "dot(a, b)"
        ))
        m.append(AirBuiltinMapping(
            airPattern: "air.cross",
            mslFunction: "cross",
            category: .math,
            paramCount: 2,
            isMethodCall: false,
            description: "cross(a, b)"
        ))
        m.append(AirBuiltinMapping(
            airPattern: "air.fast_length",
            mslFunction: "length",
            category: .math,
            paramCount: 1,
            isMethodCall: false,
            description: "fast length(v)"
        ))
        m.append(AirBuiltinMapping(
            airPattern: "air.length",
            mslFunction: "length",
            category: .math,
            paramCount: 1,
            isMethodCall: false,
            description: "length(v)"
        ))
        m.append(AirBuiltinMapping(
            airPattern: "air.fast_normalize",
            mslFunction: "normalize",
            category: .math,
            paramCount: 1,
            isMethodCall: false,
            description: "fast normalize(v)"
        ))
        m.append(AirBuiltinMapping(
            airPattern: "air.normalize",
            mslFunction: "normalize",
            category: .math,
            paramCount: 1,
            isMethodCall: false,
            description: "normalize(v)"
        ))
        m.append(AirBuiltinMapping(
            airPattern: "air.fast_distance",
            mslFunction: "distance",
            category: .math,
            paramCount: 2,
            isMethodCall: false,
            description: "fast distance(a, b)"
        ))
        m.append(AirBuiltinMapping(
            airPattern: "air.distance",
            mslFunction: "distance",
            category: .math,
            paramCount: 2,
            isMethodCall: false,
            description: "distance(a, b)"
        ))

        // ── 整数数学和位操作 ──
        m.append(AirBuiltinMapping(
            airPattern: "air.abs",
            mslFunction: "abs",
            category: .integerMath,
            paramCount: 1,
            isMethodCall: false,
            description: "abs(x) — integer variant"
        ))
        m.append(AirBuiltinMapping(
            airPattern: "air.min",
            mslFunction: "min",
            category: .integerMath,
            paramCount: 2,
            isMethodCall: false,
            description: "min(a, b) — integer variant"
        ))
        m.append(AirBuiltinMapping(
            airPattern: "air.max",
            mslFunction: "max",
            category: .integerMath,
            paramCount: 2,
            isMethodCall: false,
            description: "max(a, b) — integer variant"
        ))
        m.append(AirBuiltinMapping(
            airPattern: "air.clamp",
            mslFunction: "clamp",
            category: .integerMath,
            paramCount: 3,
            isMethodCall: false,
            description: "clamp(x, lo, hi) — integer variant"
        ))
        m.append(AirBuiltinMapping(
            airPattern: "air.popcount",
            mslFunction: "popcount",
            category: .integerMath,
            paramCount: 1,
            isMethodCall: false,
            description: "popcount(x)"
        ))
        m.append(AirBuiltinMapping(
            airPattern: "air.clz",
            mslFunction: "clz",
            category: .integerMath,
            paramCount: 1,
            isMethodCall: false,
            description: "clz(x) — air adds bool param for undef-on-zero"
        ))
        m.append(AirBuiltinMapping(
            airPattern: "air.ctz",
            mslFunction: "ctz",
            category: .integerMath,
            paramCount: 1,
            isMethodCall: false,
            description: "ctz(x) — air adds bool param for undef-on-zero"
        ))
        m.append(AirBuiltinMapping(
            airPattern: "air.extract_bits",
            mslFunction: "extract_bits",
            category: .integerMath,
            paramCount: 3,
            isMethodCall: false,
            description: "extract_bits(val, offset, bits)"
        ))
        m.append(AirBuiltinMapping(
            airPattern: "air.insert_bits",
            mslFunction: "insert_bits",
            category: .integerMath,
            paramCount: 4,
            isMethodCall: false,
            description: "insert_bits(base, insert, offset, bits)"
        ))
        m.append(AirBuiltinMapping(
            airPattern: "air.reverse_bits",
            mslFunction: "reverse_bits",
            category: .integerMath,
            paramCount: 1,
            isMethodCall: false,
            description: "reverse_bits(x)"
        ))

        // ── 类型转换 ──
        // air.convert.<dst_kind>.<dst_type>.<src_kind>.<src_type>
        // dst/src kind: f=float, s=signed int, u=unsigned int
        // 映射为 MSL 的类型构造器：float4(intVec), int4(floatVec) 等
        m.append(AirBuiltinMapping(
            airPattern: "air.convert",
            mslFunction: "(type_cast)",
            category: .conversion,
            paramCount: 1,
            isMethodCall: false,
            description: "type conversion — mapped to MSL type constructor"
        ))

        // ── 同步屏障 ──
        m.append(AirBuiltinMapping(
            airPattern: "air.wg.barrier",
            mslFunction: "threadgroup_barrier",
            category: .synchronization,
            paramCount: 2,
            isMethodCall: false,
            description: "threadgroup_barrier(mem_flags) — air params: (scope i32, mem_flags i32)"
        ))
        m.append(AirBuiltinMapping(
            airPattern: "air.simdgroup.barrier",
            mslFunction: "simdgroup_barrier",
            category: .synchronization,
            paramCount: 2,
            isMethodCall: false,
            description: "simdgroup_barrier(mem_flags)"
        ))

        // ── 纹理操作 ──
        // sample: air.sample_texture_{dim}.{type} → texture.sample(sampler, coord, ...)
        m.append(AirBuiltinMapping(
            airPattern: "air.sample_texture_2d",
            mslFunction: "sample",
            category: .texture,
            paramCount: -1,
            isMethodCall: true,
            description: "texture2d.sample(sampler, coord, [bias/level])"
        ))
        m.append(AirBuiltinMapping(
            airPattern: "air.sample_texture_2d_grad",
            mslFunction: "sample",
            category: .texture,
            paramCount: -1,
            isMethodCall: true,
            description: "texture2d.sample(sampler, coord, gradient2d(dx, dy))"
        ))
        m.append(AirBuiltinMapping(
            airPattern: "air.sample_texture_2d_array",
            mslFunction: "sample",
            category: .texture,
            paramCount: -1,
            isMethodCall: true,
            description: "texture2d_array.sample(sampler, coord, array_index)"
        ))
        m.append(AirBuiltinMapping(
            airPattern: "air.sample_texture_3d",
            mslFunction: "sample",
            category: .texture,
            paramCount: -1,
            isMethodCall: true,
            description: "texture3d.sample(sampler, coord)"
        ))
        m.append(AirBuiltinMapping(
            airPattern: "air.sample_texture_cube",
            mslFunction: "sample",
            category: .texture,
            paramCount: -1,
            isMethodCall: true,
            description: "texturecube.sample(sampler, coord)"
        ))
        m.append(AirBuiltinMapping(
            airPattern: "air.sample_compare_depth_2d",
            mslFunction: "sample_compare",
            category: .texture,
            paramCount: -1,
            isMethodCall: true,
            description: "depth2d.sample_compare(sampler, coord, compare_value)"
        ))
        m.append(AirBuiltinMapping(
            airPattern: "air.gather_texture_2d",
            mslFunction: "gather",
            category: .texture,
            paramCount: -1,
            isMethodCall: true,
            description: "texture2d.gather(sampler, coord, [offset], [component])"
        ))
        // read: air.read_texture_{dim}.{type} → texture.read(coord)
        m.append(AirBuiltinMapping(
            airPattern: "air.read_texture_2d",
            mslFunction: "read",
            category: .texture,
            paramCount: -1,
            isMethodCall: true,
            description: "texture2d.read(coord)"
        ))
        m.append(AirBuiltinMapping(
            airPattern: "air.read_texture_3d",
            mslFunction: "read",
            category: .texture,
            paramCount: -1,
            isMethodCall: true,
            description: "texture3d.read(coord)"
        ))
        // write: air.write_texture_{dim}.{type} → texture.write(color, coord)
        m.append(AirBuiltinMapping(
            airPattern: "air.write_texture_2d",
            mslFunction: "write",
            category: .texture,
            paramCount: -1,
            isMethodCall: true,
            description: "texture2d.write(color, coord)"
        ))
        m.append(AirBuiltinMapping(
            airPattern: "air.write_texture_3d",
            mslFunction: "write",
            category: .texture,
            paramCount: -1,
            isMethodCall: true,
            description: "texture3d.write(color, coord)"
        ))
        // texture queries
        m.append(AirBuiltinMapping(
            airPattern: "air.get_width_texture_2d",
            mslFunction: "get_width",
            category: .texture,
            paramCount: -1,
            isMethodCall: true,
            description: "texture2d.get_width()"
        ))
        m.append(AirBuiltinMapping(
            airPattern: "air.get_height_texture_2d",
            mslFunction: "get_height",
            category: .texture,
            paramCount: -1,
            isMethodCall: true,
            description: "texture2d.get_height()"
        ))
        m.append(AirBuiltinMapping(
            airPattern: "air.get_depth_texture_3d",
            mslFunction: "get_depth",
            category: .texture,
            paramCount: -1,
            isMethodCall: true,
            description: "texture3d.get_depth()"
        ))
        m.append(AirBuiltinMapping(
            airPattern: "air.get_num_mip_levels_texture",
            mslFunction: "get_num_mip_levels",
            category: .texture,
            paramCount: -1,
            isMethodCall: true,
            description: "texture.get_num_mip_levels()"
        ))

        // ── SIMD group 操作 ──
        m.append(AirBuiltinMapping(
            airPattern: "air.simd_shuffle",
            mslFunction: "simd_shuffle",
            category: .simd,
            paramCount: 2,
            isMethodCall: false,
            description: "simd_shuffle(val, lane)"
        ))
        m.append(AirBuiltinMapping(
            airPattern: "air.simd_shuffle_xor",
            mslFunction: "simd_shuffle_xor",
            category: .simd,
            paramCount: 2,
            isMethodCall: false,
            description: "simd_shuffle_xor(val, mask)"
        ))
        m.append(AirBuiltinMapping(
            airPattern: "air.simd_shuffle_up",
            mslFunction: "simd_shuffle_up",
            category: .simd,
            paramCount: 2,
            isMethodCall: false,
            description: "simd_shuffle_up(val, delta)"
        ))
        m.append(AirBuiltinMapping(
            airPattern: "air.simd_shuffle_down",
            mslFunction: "simd_shuffle_down",
            category: .simd,
            paramCount: 2,
            isMethodCall: false,
            description: "simd_shuffle_down(val, delta)"
        ))
        m.append(AirBuiltinMapping(
            airPattern: "air.simd_sum",
            mslFunction: "simd_sum",
            category: .simd,
            paramCount: 1,
            isMethodCall: false,
            description: "simd_sum(val)"
        ))
        m.append(AirBuiltinMapping(
            airPattern: "air.simd_product",
            mslFunction: "simd_product",
            category: .simd,
            paramCount: 1,
            isMethodCall: false,
            description: "simd_product(val)"
        ))
        m.append(AirBuiltinMapping(
            airPattern: "air.simd_min",
            mslFunction: "simd_min",
            category: .simd,
            paramCount: 1,
            isMethodCall: false,
            description: "simd_min(val)"
        ))
        m.append(AirBuiltinMapping(
            airPattern: "air.simd_max",
            mslFunction: "simd_max",
            category: .simd,
            paramCount: 1,
            isMethodCall: false,
            description: "simd_max(val)"
        ))
        m.append(AirBuiltinMapping(
            airPattern: "air.simd_broadcast_first",
            mslFunction: "simd_broadcast_first",
            category: .simd,
            paramCount: 1,
            isMethodCall: false,
            description: "simd_broadcast_first(val)"
        ))
        m.append(AirBuiltinMapping(
            airPattern: "air.simd_prefix_exclusive_sum",
            mslFunction: "simd_prefix_exclusive_sum",
            category: .simd,
            paramCount: 1,
            isMethodCall: false,
            description: "simd_prefix_exclusive_sum(val)"
        ))
        m.append(AirBuiltinMapping(
            airPattern: "air.simd_prefix_inclusive_sum",
            mslFunction: "simd_prefix_inclusive_sum",
            category: .simd,
            paramCount: 1,
            isMethodCall: false,
            description: "simd_prefix_inclusive_sum(val)"
        ))
        m.append(AirBuiltinMapping(
            airPattern: "air.simd_prefix_exclusive_product",
            mslFunction: "simd_prefix_exclusive_product",
            category: .simd,
            paramCount: 1,
            isMethodCall: false,
            description: "simd_prefix_exclusive_product(val)"
        ))

        // ── 原子操作 ──
        // air.atomic.global.<op>.<signedness>.<type>(ptr, val, order, scope, volatile)
        m.append(AirBuiltinMapping(
            airPattern: "air.atomic.global.add",
            mslFunction: "atomic_fetch_add_explicit",
            category: .atomic,
            paramCount: -1,
            isMethodCall: false,
            description: "atomic_fetch_add_explicit(obj, val, order)"
        ))
        m.append(AirBuiltinMapping(
            airPattern: "air.atomic.global.sub",
            mslFunction: "atomic_fetch_sub_explicit",
            category: .atomic,
            paramCount: -1,
            isMethodCall: false,
            description: "atomic_fetch_sub_explicit(obj, val, order)"
        ))
        m.append(AirBuiltinMapping(
            airPattern: "air.atomic.global.min",
            mslFunction: "atomic_fetch_min_explicit",
            category: .atomic,
            paramCount: -1,
            isMethodCall: false,
            description: "atomic_fetch_min_explicit(obj, val, order)"
        ))
        m.append(AirBuiltinMapping(
            airPattern: "air.atomic.global.max",
            mslFunction: "atomic_fetch_max_explicit",
            category: .atomic,
            paramCount: -1,
            isMethodCall: false,
            description: "atomic_fetch_max_explicit(obj, val, order)"
        ))
        m.append(AirBuiltinMapping(
            airPattern: "air.atomic.global.and",
            mslFunction: "atomic_fetch_and_explicit",
            category: .atomic,
            paramCount: -1,
            isMethodCall: false,
            description: "atomic_fetch_and_explicit(obj, val, order)"
        ))
        m.append(AirBuiltinMapping(
            airPattern: "air.atomic.global.or",
            mslFunction: "atomic_fetch_or_explicit",
            category: .atomic,
            paramCount: -1,
            isMethodCall: false,
            description: "atomic_fetch_or_explicit(obj, val, order)"
        ))
        m.append(AirBuiltinMapping(
            airPattern: "air.atomic.global.xor",
            mslFunction: "atomic_fetch_xor_explicit",
            category: .atomic,
            paramCount: -1,
            isMethodCall: false,
            description: "atomic_fetch_xor_explicit(obj, val, order)"
        ))
        m.append(AirBuiltinMapping(
            airPattern: "air.atomic.global.xchg",
            mslFunction: "atomic_exchange_explicit",
            category: .atomic,
            paramCount: -1,
            isMethodCall: false,
            description: "atomic_exchange_explicit(obj, desired, order)"
        ))
        m.append(AirBuiltinMapping(
            airPattern: "air.atomic.global.cmpxchg",
            mslFunction: "atomic_compare_exchange_weak_explicit",
            category: .atomic,
            paramCount: -1,
            isMethodCall: false,
            description: "atomic_compare_exchange_weak_explicit(obj, expected, desired, succ, fail)"
        ))
        m.append(AirBuiltinMapping(
            airPattern: "air.atomic.global.load",
            mslFunction: "atomic_load_explicit",
            category: .atomic,
            paramCount: -1,
            isMethodCall: false,
            description: "atomic_load_explicit(obj, order)"
        ))
        m.append(AirBuiltinMapping(
            airPattern: "air.atomic.global.store",
            mslFunction: "atomic_store_explicit",
            category: .atomic,
            paramCount: -1,
            isMethodCall: false,
            description: "atomic_store_explicit(obj, val, order)"
        ))
        // threadgroup atomics use air.atomic.local.* prefix
        m.append(AirBuiltinMapping(
            airPattern: "air.atomic.local.add",
            mslFunction: "atomic_fetch_add_explicit",
            category: .atomic,
            paramCount: -1,
            isMethodCall: false,
            description: "atomic_fetch_add_explicit (threadgroup)"
        ))
        m.append(AirBuiltinMapping(
            airPattern: "air.atomic.local.sub",
            mslFunction: "atomic_fetch_sub_explicit",
            category: .atomic,
            paramCount: -1,
            isMethodCall: false,
            description: "atomic_fetch_sub_explicit (threadgroup)"
        ))
        m.append(AirBuiltinMapping(
            airPattern: "air.atomic.local.xchg",
            mslFunction: "atomic_exchange_explicit",
            category: .atomic,
            paramCount: -1,
            isMethodCall: false,
            description: "atomic_exchange_explicit (threadgroup)"
        ))
        m.append(AirBuiltinMapping(
            airPattern: "air.atomic.local.cmpxchg",
            mslFunction: "atomic_compare_exchange_weak_explicit",
            category: .atomic,
            paramCount: -1,
            isMethodCall: false,
            description: "atomic_compare_exchange_weak_explicit (threadgroup)"
        ))

        // ── 片段着色器导数 ──
        m.append(AirBuiltinMapping(
            airPattern: "air.dfdx",
            mslFunction: "dfdx",
            category: .fragmentDerivative,
            paramCount: 1,
            isMethodCall: false,
            description: "dfdx(val)"
        ))
        m.append(AirBuiltinMapping(
            airPattern: "air.dfdy",
            mslFunction: "dfdy",
            category: .fragmentDerivative,
            paramCount: 1,
            isMethodCall: false,
            description: "dfdy(val)"
        ))
        m.append(AirBuiltinMapping(
            airPattern: "air.fwidth",
            mslFunction: "fwidth",
            category: .fragmentDerivative,
            paramCount: 1,
            isMethodCall: false,
            description: "fwidth(val)"
        ))

        // ── pack/unpack ──
        m.append(AirBuiltinMapping(
            airPattern: "air.pack.snorm4x8",
            mslFunction: "pack_float_to_snorm4x8",
            category: .packUnpack,
            paramCount: 1,
            isMethodCall: false,
            description: "pack_float_to_snorm4x8(v)"
        ))
        m.append(AirBuiltinMapping(
            airPattern: "air.unpack.snorm4x8",
            mslFunction: "unpack_snorm4x8_to_float",
            category: .packUnpack,
            paramCount: 1,
            isMethodCall: false,
            description: "unpack_snorm4x8_to_float(packed)"
        ))
        m.append(AirBuiltinMapping(
            airPattern: "air.pack.unorm4x8",
            mslFunction: "pack_float_to_unorm4x8",
            category: .packUnpack,
            paramCount: 1,
            isMethodCall: false,
            description: "pack_float_to_unorm4x8(v)"
        ))
        m.append(AirBuiltinMapping(
            airPattern: "air.unpack.unorm4x8",
            mslFunction: "unpack_unorm4x8_to_float",
            category: .packUnpack,
            paramCount: 1,
            isMethodCall: false,
            description: "unpack_unorm4x8_to_float(packed)"
        ))
        m.append(AirBuiltinMapping(
            airPattern: "air.pack.snorm2x16",
            mslFunction: "pack_float_to_snorm2x16",
            category: .packUnpack,
            paramCount: 1,
            isMethodCall: false,
            description: "pack_float_to_snorm2x16(v)"
        ))
        m.append(AirBuiltinMapping(
            airPattern: "air.unpack.snorm2x16",
            mslFunction: "unpack_snorm2x16_to_float",
            category: .packUnpack,
            paramCount: 1,
            isMethodCall: false,
            description: "unpack_snorm2x16_to_float(packed)"
        ))
        m.append(AirBuiltinMapping(
            airPattern: "air.pack.unorm2x16",
            mslFunction: "pack_float_to_unorm2x16",
            category: .packUnpack,
            paramCount: 1,
            isMethodCall: false,
            description: "pack_float_to_unorm2x16(v)"
        ))
        m.append(AirBuiltinMapping(
            airPattern: "air.unpack.unorm2x16",
            mslFunction: "unpack_unorm2x16_to_float",
            category: .packUnpack,
            paramCount: 1,
            isMethodCall: false,
            description: "unpack_unorm2x16_to_float(packed)"
        ))

        return m
    }()
    // swiftlint:enable function_body_length

    /// 从完整的 air 函数名中去掉类型后缀，得到基础名称。
    ///
    /// 类型后缀编码了参数类型：
    /// - `v4f32` → `<4 x float>`, `v3f32` → `<3 x float>`
    /// - `v4f16` → `<4 x half>`, `v4i32` → `<4 x i32>`
    /// - `f32` → `float`, `f64` → `double`, `i32` → `i32`
    ///
    /// 示例：
    /// - `air.fast_sin.v4f32` → `air.fast_sin`
    /// - `air.sample_texture_2d.v4f32` → `air.sample_texture_2d`
    /// - `air.atomic.global.add.u.i32` → `air.atomic.global.add`
    /// - `air.convert.f.v4f32.s.v4i32` → `air.convert`
    static func airStripTypeSuffix(_ fullName: String) -> String {
        // 对于 air.convert.*，整个后缀都是类型编码，只保留 "air.convert"
        if fullName.hasPrefix("air.convert.") {
            return "air.convert"
        }

        // 对于 air.atomic.*，去掉符号性+类型后缀：
        //   air.atomic.global.add.u.i32 → air.atomic.global.add
        //   air.atomic.global.cmpxchg.weak.i32 → air.atomic.global.cmpxchg
        //   air.atomic.local.add.s.i32 → air.atomic.local.add
        if fullName.hasPrefix("air.atomic.") {
            let parts = fullName.components(separatedBy: ".")
            // air.atomic.{scope}.{op}[.weak].{sign}.{type}
            // 找到 op 的位置（index 3）并在其后截断
            if parts.count >= 4 {
                let scope = parts[2]  // "global" or "local"
                let op = parts[3]     // "add", "sub", "cmpxchg", etc.
                // cmpxchg 还有 .weak 子变体
                if op == "cmpxchg" && parts.count >= 5 {
                    return "air.atomic.\(scope).cmpxchg"
                }
                return "air.atomic.\(scope).\(op)"
            }
            return fullName
        }

        // 通用规则：去掉最后一个 . 分段（如果它是类型后缀）
        // 类型后缀的特征：以 v?[0-9]*[fiu][0-9]+ 匹配
        // 如 .v4f32, .v4f16, .v4i32, .f32, .i32
        guard let lastDotIdx = fullName.lastIndex(of: ".") else {
            return fullName
        }
        let suffix = String(fullName[fullName.index(after: lastDotIdx)...])
        if isTypeSuffix(suffix) {
            return String(fullName[fullName.startIndex..<lastDotIdx])
        }
        return fullName
    }

    /// 判断字符串是否为 air 函数的类型后缀
    private static func isTypeSuffix(_ s: String) -> Bool {
        // 匹配模式：v?[0-9]*[fiu][0-9]+
        // 例：v4f32, v3f32, v4f16, v4i32, v2i32, f32, f64, i32, i16
        let chars = Array(s)
        guard !chars.isEmpty else { return false }

        var i = 0
        // 可选的 'v' 前缀
        if chars[i] == "v" {
            i += 1
            // 后跟数字
            while i < chars.count && chars[i].isNumber { i += 1 }
        }
        // 必须有类型字母 f/i/u
        guard i < chars.count && (chars[i] == "f" || chars[i] == "i" || chars[i] == "u") else {
            return false
        }
        i += 1
        // 后跟数字
        guard i < chars.count && chars[i].isNumber else { return false }
        while i < chars.count {
            guard chars[i].isNumber else { return false }
            i += 1
        }
        return true
    }

    /// 查找 air 函数名对应的 MSL 映射。
    ///
    /// 先精确匹配 baseName，再用前缀匹配（longest prefix wins）。
    /// 返回匹配到的映射，或 nil。
    static func lookupAirBuiltin(_ fullAirName: String) -> AirBuiltinMapping? {
        let baseName = airStripTypeSuffix(fullAirName)

        // 1. 精确匹配
        if let exact = airBuiltinMappings.first(where: { $0.airPattern == baseName }) {
            return exact
        }

        // 2. 最长前缀匹配
        var bestMatch: AirBuiltinMapping?
        var bestLength = 0
        for mapping in airBuiltinMappings {
            if baseName.hasPrefix(mapping.airPattern) && mapping.airPattern.count > bestLength {
                bestMatch = mapping
                bestLength = mapping.airPattern.count
            }
        }
        return bestMatch
    }

    /// 从 IR 文本的函数体中提取所有 air.* 内建调用。
    ///
    /// 扫描 IR 文本中 `call` / `tail call` 指令中对 `@air.*` 函数的调用，
    /// 提取函数名、参数和返回值 SSA 名。
    ///
    /// IR 调用格式示例：
    /// ```
    /// %8 = tail call { <4 x float>, i8 } @air.sample_texture_2d.v4f32(
    ///         ptr addrspace(1) %5, ptr addrspace(2) %6, <2 x float> %1, ...)
    /// tail call void @air.wg.barrier(i32 2, i32 1)
    /// %15 = tail call i32 @air.convert.s.i32.f.f32(float %14)
    /// ```
    static func parseAirBuiltinCalls(_ irText: String) -> [AirBuiltinCall] {
        var calls: [AirBuiltinCall] = []
        let lines = irText.components(separatedBy: "\n")

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // 匹配包含 @air. 的 call 指令
            guard trimmed.contains("@air.") else { continue }
            guard trimmed.contains("call ") else { continue }

            // 提取结果 SSA 名
            let resultSSA: String?
            if let eqRange = trimmed.range(of: " = ") {
                let beforeEq = trimmed[trimmed.startIndex..<eqRange.lowerBound]
                    .trimmingCharacters(in: .whitespaces)
                resultSSA = beforeEq.hasPrefix("%") ? beforeEq : nil
            } else {
                resultSSA = nil
            }

            // 提取 air 函数名
            guard let atAirRange = trimmed.range(of: "@air.") else { continue }
            let afterAtAir = trimmed[atAirRange.lowerBound...]
            // 函数名到 '(' 为止
            guard let parenIdx = afterAtAir.firstIndex(of: "(") else { continue }
            let fullName = String(afterAtAir[afterAtAir.index(after: afterAtAir.startIndex)..<parenIdx])
            // fullName 现在是 "air.fast_sin.v4f32" 等

            // 提取参数列表
            let argsStart = afterAtAir.index(after: parenIdx)
            let args: String
            // 找匹配的闭括号
            var depth = 1
            var cursor = argsStart
            while cursor < afterAtAir.endIndex && depth > 0 {
                if afterAtAir[cursor] == "(" { depth += 1 }
                else if afterAtAir[cursor] == ")" { depth -= 1 }
                if depth > 0 { cursor = afterAtAir.index(after: cursor) }
            }
            args = String(afterAtAir[argsStart..<cursor])

            let baseName = airStripTypeSuffix(fullName)
            let mapping = lookupAirBuiltin(fullName)

            calls.append(AirBuiltinCall(
                airFunctionName: fullName,
                airBaseName: baseName,
                mapping: mapping,
                irArguments: args,
                resultSSA: resultSSA
            ))
        }

        return calls
    }

    private struct AirConvertSignature {
        let destinationKind: String
        let destinationTypeSuffix: String
        let sourceKind: String
        let sourceTypeSuffix: String
    }

    /// 解析 `air.convert.<dst_kind>.<dst_type>.<src_kind>.<src_type>` 的语义签名。
    private static func parseAirConvertSignature(_ airFuncName: String) -> AirConvertSignature? {
        guard airFuncName.hasPrefix("air.convert.") else { return nil }
        let rest = String(airFuncName.dropFirst("air.convert.".count))
        let parts = rest.components(separatedBy: ".")
        guard parts.count >= 4 else { return nil }
        return AirConvertSignature(
            destinationKind: parts[0],
            destinationTypeSuffix: parts[1],
            sourceKind: parts[2],
            sourceTypeSuffix: parts[3]
        )
    }

    /// 从 air.convert 函数名中解析转换的目标 MSL 类型。
    ///
    /// 命名规则：`air.convert.<dst_kind>.<dst_type>.<src_kind>.<src_type>`
    /// - kind: f=float, s=signed, u=unsigned
    /// - type: v4f32, v4i32, f32, i32, v4f16 等
    ///
    /// 示例：
    /// - `air.convert.f.v4f32.s.v4i32` → `float4` (int4 → float4)
    /// - `air.convert.s.v4i32.f.v4f32` → `int4` (float4 → int4)
    /// - `air.convert.u.v4i32.f.v4f32` → `uint4` (float4 → uint4，保留 unsigned 语义)
    static func parseAirConvertTargetType(_ airFuncName: String) -> String? {
        guard let signature = parseAirConvertSignature(airFuncName) else { return nil }
        return airTypeSuffixToMSL(signature.destinationTypeSuffix, integerKind: signature.destinationKind)
    }

    /// 将 air 类型后缀转换为 MSL 类型名。
    ///
    /// - `v4f32` → `float4`, `v3f32` → `float3`, `v2f32` → `float2`
    /// - `v4f16` → `half4`, `v4i32` → `int4`, `v2i32` → `int2`
    /// - `f32` → `float`, `f16` → `half`, `i32` → `int`, `i16` → `short`
    /// - 对 `air.convert.u.*` / `air.convert.s.*` 可通过 `integerKind` 覆盖整数 signedness
    static func airTypeSuffixToMSL(_ suffix: String, integerKind: String? = nil) -> String {
        // 向量类型：vNtBB → typeN (如 v4f32 → float4)
        if suffix.hasPrefix("v") {
            let chars = Array(suffix.dropFirst())
            // 提取维度数字
            var i = 0
            while i < chars.count && chars[i].isNumber { i += 1 }
            let dim = String(chars[0..<i])
            let scalarSuffix = String(chars[i...])
            let scalarMSL = airScalarSuffixToMSL(scalarSuffix, integerKind: integerKind)
            if scalarMSL == "uint8_t" {
                return "uchar\(dim)"
            }
            return "\(scalarMSL)\(dim)"
        }
        // 标量类型
        return airScalarSuffixToMSL(suffix, integerKind: integerKind)
    }

    /// 将 air 标量类型后缀转换为 MSL 标量类型。
    ///
    /// AIR 的 `air.convert.u.*.i32` / `air.convert.s.*.i32` 会复用同一个 IR 宽度后缀，
    /// 这里需要结合 `integerKind` 才能恢复真正的 unsigned / signed 目标语义。
    private static func airScalarSuffixToMSL(_ suffix: String, integerKind: String? = nil) -> String {
        switch suffix {
        case "f32": return "float"
        case "f16": return "half"
        case "f64": return "float"  // MSL 不支持 double
        case "i1": return "bool"
        case "i8":
            if integerKind == "s" { return "char" }
            return "uint8_t"
        case "i16":
            if integerKind == "u" { return "ushort" }
            return "short"
        case "i32":
            if integerKind == "u" { return "uint" }
            return "int"
        case "i64":
            if integerKind == "u" { return "ulong" }
            return "long"
        case "u8":
            if integerKind == "s" { return "char" }
            return "uint8_t"
        case "u16":
            if integerKind == "s" { return "short" }
            return "ushort"
        case "u32":
            if integerKind == "s" { return "int" }
            return "uint"
        case "u64":
            if integerKind == "s" { return "long" }
            return "ulong"
        default: return suffix
        }
    }

    /// 生成 air.convert 的 MSL 表达式，并在需要时补回 AIR 的 unsigned 语义。
    ///
    /// AIR 中 `air.convert.u.i32.f.f32` 等转换虽然在 IR 里仍然使用 `i32`/`<4 x i32>`，
    /// 但它们的行为语义是 unsigned。若直接降成 `int(src)`，会把负 float 转成负 int，
    /// 再在后续 `uitofp` / store 到 `uint*` 时产生可观测行为偏差（`test_casts` 就是此类）。
    private static func generateAirConvertMSL(airName: String, srcArg: String) -> String {
        guard let signature = parseAirConvertSignature(airName) else {
            let fallbackTargetType = parseAirConvertTargetType(airName) ?? "float"
            return "\(fallbackTargetType)(\(srcArg))"
        }

        let storageTargetType = airTypeSuffixToMSL(signature.destinationTypeSuffix)
        let semanticTargetType = airTypeSuffixToMSL(
            signature.destinationTypeSuffix,
            integerKind: signature.destinationKind
        )
        let storageSourceType = airTypeSuffixToMSL(signature.sourceTypeSuffix)
        let semanticSourceType = airTypeSuffixToMSL(
            signature.sourceTypeSuffix,
            integerKind: signature.sourceKind
        )

        let normalizedSource = storageSourceType == semanticSourceType
            ? srcArg
            : "\(semanticSourceType)(\(srcArg))"
        let semanticExpr = "\(semanticTargetType)(\(normalizedSource))"
        if semanticTargetType == storageTargetType {
            return semanticExpr
        }
        return "\(storageTargetType)(\(semanticExpr))"
    }

    // MARK: - IR Metadata Types

    /// 从 IR metadata 中解析出的参数信息。
    ///
    /// Metal AIR 在 LLVM IR 的 named metadata (!air.vertex, !air.fragment, !air.kernel)
    /// 中包含完整的函数签名信息，包括参数类型名、参数名、绑定索引等。
    /// 这些信息在 opaque pointer 时代（LLVM 15+）是获取精确类型的唯一途径。
    struct MetadataArgInfo {
        /// 参数在 IR define 中的位置索引
        let argIndex: Int
        /// 参数种类: "air.buffer", "air.texture", "air.sampler",
        /// "air.vertex_input", "air.fragment_input", "air.vertex_id",
        /// "air.base_vertex", "air.base_instance", "air.thread_position_in_grid" 等
        let kind: String
        /// MSL 类型名 (来自 "air.arg_type_name"): "float4", "uint", "Uniforms" 等
        let typeName: String
        /// MSL 参数名 (来自 "air.arg_name"): "positions", "uniforms" 等
        let argName: String
        /// buffer/texture/sampler 绑定索引 (来自 "air.location_index")
        let locationIndex: Int?
        /// 地址空间 (来自 "air.address_space")
        let addressSpace: Int?
        /// 是否只读 (有 "air.read" 标记)
        let isReadOnly: Bool
        /// 结构体字段信息（来自 "air.struct_type_info"），仅 buffer 参数有
        let structFieldInfo: [StructFieldInfo]
    }

    /// 从 IR metadata 中解析出的返回值字段信息。
    struct MetadataReturnInfo {
        /// 返回字段种类，如 `air.position` / `air.vertex_output` / `air.render_target`
        let kind: String
        /// MSL 类型名（来自 `air.arg_type_name`）
        let typeName: String
        /// 字段名（来自 `air.arg_name`，若缺失则使用推导名）
        let argName: String
        /// 颜色附件等输出槽位（若 metadata 提供）
        let locationIndex: Int?
        /// 返回字段 qualifier（如 `air.invariant`）
        let qualifiers: [String]
    }

    /// 从 IR metadata 中解析出的函数信息
    struct MetadataFuncInfo {
        /// 函数名
        let name: String
        /// shader 类型
        let shaderType: ShaderType
        /// 返回值字段描述（按 metadata 顺序）
        let returns: [MetadataReturnInfo]
        /// 参数列表（按 argIndex 排序）
        let args: [MetadataArgInfo]
    }

    // MARK: - Struct Type Info (E-004e4c)

    /// 从 IR 结构体定义中解析出的字段信息
    struct StructFieldInfo {
        /// 字段在结构体中的索引（0, 1, 2, ...）
        let index: Int
        /// MSL 字段类型名（如 "float3", "float4x4", "float"）
        let typeName: String
        /// MSL 字段名（如 "position", "velocity", "mass"）
        let fieldName: String
        /// 字段在结构体中的偏移量（字节）
        let offset: Int
        /// 字段大小（字节）
        let size: Int
        /// air.struct_type_info 第三个 i32：element count（数组长度，>1 时字段是数组类型）
        let elementCount: Int
    }

    /// IR 中解析出的结构体类型定义
    struct IRStructTypeDef {
        /// IR 结构体名（如 "%struct.Particle"）
        let irName: String
        /// 字段的 IR 类型列表
        let fieldIRTypes: [String]
        /// 是否为 packed struct（<{ ... }>）
        let isPacked: Bool
    }

    // MARK: - IR Metadata Parsing

    /// 从 IR 文本中解析 !air.vertex / !air.fragment / !air.kernel metadata，
    /// 提取每个 shader 函数的完整参数信息。
    ///
    /// IR metadata 格式示例:
    /// ```
    /// !air.vertex = !{!9, !22}          ← 顶层：列出所有 vertex 函数
    /// !9 = !{ptr @test_vertex, !10, !14} ← 函数节点：函数指针 + 返回描述 + 参数描述
    /// !14 = !{!15, !16, !17, !18, !20, !21}  ← 参数列表节点
    /// !18 = !{i32 3, !"air.buffer", !"air.buffer_size", i32 144,
    ///         !"air.location_index", i32 0, i32 1, !"air.read",
    ///         !"air.address_space", i32 2,
    ///         !"air.arg_type_name", !"Uniforms", !"air.arg_name", !"uniforms"}
    /// ```
    private static func parseIRMetadata(_ irText: String) -> [MetadataFuncInfo] {
        let lines = irText.components(separatedBy: "\n")

        // Step 1: 构建 metadata 节点表 (!N → content)
        var metadataNodes: [String: String] = [:]
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // 匹配 !N = !{...} 或 !N = distinct !{...}
            guard trimmed.hasPrefix("!") else { continue }
            guard let eqRange = trimmed.range(of: " = ") else { continue }
            let nodeId = String(trimmed[trimmed.startIndex..<eqRange.lowerBound])
            var content = String(trimmed[eqRange.upperBound...])
            if content.hasPrefix("distinct ") {
                content = String(content.dropFirst("distinct ".count))
            }
            metadataNodes[nodeId] = content
        }

        // Step 2: 找到 !air.vertex, !air.fragment, !air.kernel 的入口
        var results: [MetadataFuncInfo] = []

        let shaderTypeMap: [(String, ShaderType)] = [
            ("!air.vertex", .vertex),
            ("!air.fragment", .fragment),
            ("!air.kernel", .kernel),
        ]

        for (metaKey, shaderType) in shaderTypeMap {
            // 找 !air.vertex = !{!9, !22} 这样的行
            guard let topContent = metadataNodes[metaKey] else { continue }
            let funcNodeIds = parseMetadataRefList(topContent)

            for funcNodeId in funcNodeIds {
                guard let funcContent = metadataNodes[funcNodeId] else { continue }
                if let funcInfo = parseMetadataFuncNode(
                    funcContent,
                    shaderType: shaderType,
                    nodes: metadataNodes,
                    irText: irText
                ) {
                    results.append(funcInfo)
                }
            }
        }

        return results
    }

    /// 解析 metadata 引用列表: !{!9, !22} → ["!9", "!22"]
    private static func parseMetadataRefList(_ content: String) -> [String] {
        // content 格式: !{!9, !22} 或 !{}
        guard content.hasPrefix("!{") && content.hasSuffix("}") else { return [] }
        let inner = String(content.dropFirst(2).dropLast())
        if inner.trimmingCharacters(in: .whitespaces).isEmpty { return [] }

        return inner.components(separatedBy: ",").compactMap { part in
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("!") ? trimmed : nil
        }
    }

    /// 解析函数 metadata 节点。
    ///
    /// AIR 中常见两种形态都要支持：
    /// - `!{ptr @test_vertex, !10, !14}`：返回节点 + 参数列表分组节点
    /// - `!{ptr @xlatMtlMain, !1, !2, !4}`：返回节点 + 多个参数节点直接并列
    private static func parseMetadataFuncNode(
        _ content: String,
        shaderType: ShaderType,
        nodes: [String: String],
        irText: String
    ) -> MetadataFuncInfo? {
        _ = irText
        guard content.hasPrefix("!{") && content.hasSuffix("}") else { return nil }
        let inner = String(content.dropFirst(2).dropLast())

        // 提取函数名: "ptr @test_vertex" 或 "ptr @\"quoted.name\""
        let funcName: String
        if let atRange = inner.range(of: "@") {
            let afterAt = inner[atRange.upperBound...]
            if afterAt.hasPrefix("\"") {
                let nameStart = afterAt.index(after: afterAt.startIndex)
                if let quoteEnd = afterAt[nameStart...].firstIndex(of: "\"") {
                    funcName = String(afterAt[nameStart..<quoteEnd])
                } else {
                    return nil
                }
            } else {
                let nameEnd = afterAt.firstIndex(where: { $0 == "," || $0 == " " }) ?? afterAt.endIndex
                funcName = String(afterAt[afterAt.startIndex..<nameEnd])
            }
        } else {
            return nil
        }

        // `parseMetadataRefList(...)` 会返回函数节点里出现的所有 `!N` 引用。
        // 除了传统的 `[返回节点, 参数列表节点]`，还要兼容 `[返回节点, 参数节点, 参数节点, ...]`。
        let refs = parseMetadataRefList(content)
        guard let firstRef = refs.first else {
            return MetadataFuncInfo(name: funcName, shaderType: shaderType, returns: [], args: [])
        }

        let returns = parseMetadataReturnListNode(fromRefs: [firstRef], nodes: nodes)
        let args = parseMetadataArgListNode(fromRefs: Array(refs.dropFirst()), nodes: nodes)

        return MetadataFuncInfo(name: funcName, shaderType: shaderType, returns: returns, args: args)
    }

    private static func parseMetadataReturnListNode(
        fromRefs refs: [String],
        nodes: [String: String]
    ) -> [MetadataReturnInfo] {
        var returns: [MetadataReturnInfo] = []

        for ref in refs {
            guard let nodeContent = nodes[ref] else { continue }

            let nestedRefs = parseMetadataRefList(nodeContent)
            if !nestedRefs.isEmpty {
                let nestedReturns = parseMetadataReturnListNode(fromRefs: nestedRefs, nodes: nodes)
                if !nestedReturns.isEmpty {
                    returns.append(contentsOf: nestedReturns)
                    continue
                }
            }

            if let returnInfo = parseMetadataReturnNode(nodeContent) {
                returns.append(returnInfo)
            }
        }

        return returns
    }

    private static func parseMetadataArgListNode(
        fromRefs refs: [String],
        nodes: [String: String]
    ) -> [MetadataArgInfo] {
        var args: [MetadataArgInfo] = []

        for ref in refs {
            guard let nodeContent = nodes[ref] else { continue }

            let nestedRefs = parseMetadataRefList(nodeContent)
            if !nestedRefs.isEmpty {
                let nestedArgs = parseMetadataArgListNode(fromRefs: nestedRefs, nodes: nodes)
                if !nestedArgs.isEmpty {
                    args.append(contentsOf: nestedArgs)
                    continue
                }
            }

            if let argInfo = parseMetadataArgNode(nodeContent) {
                args.append(argInfo)
            }
        }

        return args.sorted { $0.argIndex < $1.argIndex }
    }

    private static func parseMetadataReturnNode(_ content: String) -> MetadataReturnInfo? {
        guard content.hasPrefix("!{") && content.hasSuffix("}") else { return nil }
        let inner = String(content.dropFirst(2).dropLast())
        let tokens = splitMetadataTokens(inner)
        guard !tokens.isEmpty else { return nil }

        let kind = unquoteMetadataString(tokens[0])
        var typeName = ""
        var argName = ""
        var locationIndex: Int?
        var qualifiers: [String] = []
        var i = 1

        while i < tokens.count {
            let token = unquoteMetadataString(tokens[i])

            switch token {
            case "air.arg_type_name":
                if i + 1 < tokens.count {
                    typeName = unquoteMetadataString(tokens[i + 1])
                    i += 2
                } else {
                    i += 1
                }
            case "air.arg_name":
                if i + 1 < tokens.count {
                    argName = unquoteMetadataString(tokens[i + 1])
                    i += 2
                } else {
                    i += 1
                }
            case "air.location_index":
                if i + 1 < tokens.count {
                    locationIndex = parseMetadataInt(tokens[i + 1])
                    i += 2
                } else {
                    i += 1
                }
            default:
                if locationIndex == nil,
                   token.hasPrefix("i32 "),
                   (kind == "air.render_target" || kind == "air.vertex_output") {
                    locationIndex = parseMetadataInt(tokens[i])
                } else if token.hasPrefix("air."), token != kind, token != "air.arg_unused" {
                    qualifiers.append(token)
                }
                i += 1
            }
        }

        let fallbackName: String
        switch kind {
        case "air.position":
            fallbackName = "position"
        case "air.render_target":
            fallbackName = "color\(locationIndex ?? 0)"
        case "air.vertex_output":
            fallbackName = "varying\(locationIndex ?? 0)"
        default:
            fallbackName = "out\(locationIndex ?? 0)"
        }

        return MetadataReturnInfo(
            kind: kind,
            typeName: typeName,
            argName: argName.isEmpty ? fallbackName : argName,
            locationIndex: locationIndex,
            qualifiers: Array(Set(qualifiers)).sorted()
        )
    }

    /// 解析单个参数 metadata 节点。
    ///
    /// 格式示例:
    /// ```
    /// !{i32 3, !"air.buffer", !"air.buffer_size", i32 144,
    ///   !"air.location_index", i32 0, i32 1, !"air.read",
    ///   !"air.address_space", i32 2,
    ///   !"air.arg_type_name", !"Uniforms", !"air.arg_name", !"uniforms"}
    ///
    /// !{i32 5, !"air.vertex_id", !"air.arg_type_name", !"uint", !"air.arg_name", !"vid"}
    /// ```
    private static func parseMetadataArgNode(_ content: String) -> MetadataArgInfo? {
        guard content.hasPrefix("!{") && content.hasSuffix("}") else { return nil }
        let inner = String(content.dropFirst(2).dropLast())
        let tokens = splitMetadataTokens(inner)

        guard tokens.count >= 2 else { return nil }

        // 第一个 token: i32 N (参数索引)
        let argIndex: Int
        if tokens[0].hasPrefix("i32 ") {
            argIndex = Int(String(tokens[0].dropFirst(4))) ?? 0
        } else {
            return nil
        }

        // 第二个 token: !"air.buffer" 或 !"air.vertex_id" 等（参数种类）
        let kind = unquoteMetadataString(tokens[1])
        guard kind.hasPrefix("air.") else { return nil }

        // 扫描后续 token 提取 key-value 对
        var typeName = ""
        var argName = ""
        var locationIndex: Int?
        var addressSpace: Int?
        var isReadOnly = false
        var structFieldInfo: [StructFieldInfo] = []

        var i = 2
        while i < tokens.count {
            let token = unquoteMetadataString(tokens[i])

            switch token {
            case "air.arg_type_name":
                if i + 1 < tokens.count {
                    typeName = unquoteMetadataString(tokens[i + 1])
                    i += 2
                } else { i += 1 }
            case "air.arg_name":
                if i + 1 < tokens.count {
                    argName = unquoteMetadataString(tokens[i + 1])
                    i += 2
                } else { i += 1 }
            case "air.location_index":
                if i + 1 < tokens.count {
                    locationIndex = parseMetadataInt(tokens[i + 1])
                    i += 2
                } else { i += 1 }
            case "air.address_space":
                if i + 1 < tokens.count {
                    addressSpace = parseMetadataInt(tokens[i + 1])
                    i += 2
                } else { i += 1 }
            case "air.read":
                isReadOnly = true
                i += 1
            case "air.read_write":
                isReadOnly = false
                i += 1
            case "air.struct_type_info":
                // air.struct_type_info 的值是一个 metadata 引用 !N
                // 但在这里它已经被 inline 展开了（从 nodes lookup 替换）
                // 格式: 后续 tokens 是字段描述序列:
                // i32 offset, i32 size, i32 alignment, !"typeName", !"fieldName", ...
                // 跳过这个 key，字段信息在后续 tokens 中
                if i + 1 < tokens.count {
                    let ref = tokens[i + 1].trimmingCharacters(in: .whitespaces)
                    if ref.hasPrefix("!") && !ref.hasPrefix("!\"") {
                        // 这是一个 metadata 引用，记录下来稍后在外部处理
                        // 标记使用特殊值让调用方知道
                        i += 2
                    } else {
                        i += 1
                    }
                } else { i += 1 }
            default:
                i += 1
            }
        }

        return MetadataArgInfo(
            argIndex: argIndex,
            kind: kind,
            typeName: typeName,
            argName: argName.isEmpty ? "arg\(argIndex)" : argName,
            locationIndex: locationIndex,
            addressSpace: addressSpace,
            isReadOnly: isReadOnly,
            structFieldInfo: structFieldInfo
        )
    }

    /// 分割 metadata 节点内容为 token 列表。
    /// 处理逗号分割，但保持 !{} 嵌套。
    private static func splitMetadataTokens(_ content: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var depth = 0
        var inQuotedString = false
        var previousChar: Character?

        for char in content {
            if char == "\"" && previousChar != "\\" {
                inQuotedString.toggle()
            } else if !inQuotedString {
                if char == "{" || char == "(" || char == "[" { depth += 1 }
                else if char == "}" || char == ")" || char == "]" { depth -= 1 }
            }

            if char == "," && depth == 0 && !inQuotedString {
                let trimmed = current.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { tokens.append(trimmed) }
                current = ""
            } else {
                current.append(char)
            }

            previousChar = char
        }
        let trimmed = current.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { tokens.append(trimmed) }
        return tokens
    }

    /// 去掉 metadata 字符串的引号: !"air.buffer" → "air.buffer"
    private static func unquoteMetadataString(_ token: String) -> String {
        var s = token
        if s.hasPrefix("!\"") && s.hasSuffix("\"") {
            s = String(s.dropFirst(2).dropLast())
        } else if s.hasPrefix("!") {
            s = String(s.dropFirst())
        }
        if s.hasPrefix("\"") && s.hasSuffix("\"") {
            s = String(s.dropFirst().dropLast())
        }
        return s
    }

    /// 从 metadata token 中提取整数: "i32 2" → 2
    private static func parseMetadataInt(_ token: String) -> Int? {
        let trimmed = token.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("i32 ") {
            return Int(String(trimmed.dropFirst(4)))
        }
        return Int(trimmed)
    }

    // MARK: - IR Struct Type Parsing (E-004e4c)

    /// 从 IR 文本中解析所有结构体类型定义。
    ///
    /// IR 格式示例：
    /// ```
    /// %struct.Particle = type { <3 x float>, <3 x float>, float, [12 x i8] }
    /// %struct.Uniforms = type <{ %"struct.metal::matrix", float, [12 x i8] }>
    /// ```
    private static func parseIRStructTypes(_ irText: String) -> [String: IRStructTypeDef] {
        var structDefs: [String: IRStructTypeDef] = [:]
        let lines = irText.components(separatedBy: "\n")

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // 匹配: %XXX = type { ... } 或 %XXX = type <{ ... }>
            guard trimmed.hasPrefix("%") else { continue }
            guard let eqRange = trimmed.range(of: " = type ") else { continue }

            let irName = String(trimmed[trimmed.startIndex..<eqRange.lowerBound])
            var bodyStr = String(trimmed[eqRange.upperBound...]).trimmingCharacters(in: .whitespaces)

            let isPacked = bodyStr.hasPrefix("<{")
            // 去掉外层 <{ }> 或 { }
            if isPacked {
                if bodyStr.hasPrefix("<{") && bodyStr.hasSuffix("}>") {
                    bodyStr = String(bodyStr.dropFirst(2).dropLast(2))
                }
            } else {
                if bodyStr.hasPrefix("{") && bodyStr.hasSuffix("}") {
                    bodyStr = String(bodyStr.dropFirst().dropLast())
                }
            }

            // 解析字段类型（用 splitIRParameters 正确处理嵌套 < > { }）
            let fieldTypes = splitIRParameters(bodyStr).map {
                $0.trimmingCharacters(in: .whitespaces)
            }.filter { !$0.isEmpty }

            structDefs[irName] = IRStructTypeDef(
                irName: irName,
                fieldIRTypes: fieldTypes,
                isPacked: isPacked
            )
        }

        return structDefs
    }

    /// 从 metadata 的 air.struct_type_info 引用中解析结构体字段信息。
    ///
    /// metadata 格式示例：
    /// ```
    /// !31 = !{i32 0, i32 16, i32 0, !"float3", !"position",
    ///         i32 16, i32 16, i32 0, !"float3", !"velocity",
    ///         i32 32, i32 4, i32 0, !"float", !"mass"}
    /// ```
    /// 每个字段由 5 个 token 组成：offset, size, alignment, typeName, fieldName
    private static func parseStructTypeInfoNode(
        _ content: String
    ) -> [StructFieldInfo] {
        guard content.hasPrefix("!{") && content.hasSuffix("}") else { return [] }
        let inner = String(content.dropFirst(2).dropLast())
        let tokens = splitMetadataTokens(inner)

        var fields: [StructFieldInfo] = []
        var i = 0
        var fieldIndex = 0

        // 每个字段由 5 个 token 组成: i32 offset, i32 size, i32 elementCount, !"typeName", !"fieldName"
        // 注意：第三个 i32 是 element count（数组长度），而非 alignment；element_count > 1 表示数组字段
        while i + 4 < tokens.count {
            let offset = parseMetadataInt(tokens[i]) ?? 0
            let size = parseMetadataInt(tokens[i + 1]) ?? 0
            let elementCount = parseMetadataInt(tokens[i + 2]) ?? 1
            let typeName = unquoteMetadataString(tokens[i + 3])
            let fieldName = unquoteMetadataString(tokens[i + 4])

            fields.append(StructFieldInfo(
                index: fieldIndex,
                typeName: typeName,
                fieldName: fieldName,
                offset: offset,
                size: size,
                elementCount: elementCount
            ))
            fieldIndex += 1
            i += 5
        }

        return fields
    }

    /// 从 IR metadata 中提取所有结构体字段信息。
    ///
    /// 扫描所有参数的 metadata，提取 air.struct_type_info 引用，
    /// 构建 MSL 类型名 → [StructFieldInfo] 的映射表。
    private static func parseStructFieldInfoFromMetadata(
        _ irText: String,
        metadataFuncs: [MetadataFuncInfo]
    ) -> [String: [StructFieldInfo]] {
        _ = metadataFuncs
        var result: [String: [StructFieldInfo]] = [:]

        let lines = irText.components(separatedBy: "\n")

        // Step 1: 构建 metadata 节点表
        var metadataNodes: [String: String] = [:]
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("!") else { continue }
            guard let eqRange = trimmed.range(of: " = ") else { continue }
            let nodeId = String(trimmed[trimmed.startIndex..<eqRange.lowerBound])
            var content = String(trimmed[eqRange.upperBound...])
            if content.hasPrefix("distinct ") {
                content = String(content.dropFirst("distinct ".count))
            }
            metadataNodes[nodeId] = content
        }

        // Step 2: 从参数 metadata 中找 air.struct_type_info 引用
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // 匹配包含 air.struct_type_info 的行
            guard trimmed.contains("air.struct_type_info") else { continue }
            guard trimmed.hasPrefix("!") else { continue }
            guard let eqRange = trimmed.range(of: " = ") else { continue }

            var nodeContent = String(trimmed[eqRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            if nodeContent.hasPrefix("distinct ") {
                nodeContent = String(nodeContent.dropFirst("distinct ".count))
            }
            guard nodeContent.hasPrefix("!{") && nodeContent.hasSuffix("}") else { continue }

            let tokens = splitMetadataTokens(
                String(nodeContent.dropFirst(2).dropLast())
            )

            // 找到 air.struct_type_info 之后的 metadata 引用
            var typeName = ""
            for (idx, tok) in tokens.enumerated() {
                let unquoted = unquoteMetadataString(tok)
                if unquoted == "air.struct_type_info" {
                    // 下一个 token 是 !N 引用
                    if idx + 1 < tokens.count {
                        let ref = tokens[idx + 1].trimmingCharacters(in: .whitespaces)
                        if let nodeContent = metadataNodes[ref] {
                            let fields = parseStructTypeInfoNode(nodeContent)
                            // 找到这个参数的 air.arg_type_name
                            for (j, t) in tokens.enumerated() {
                                if unquoteMetadataString(t) == "air.arg_type_name" && j + 1 < tokens.count {
                                    typeName = unquoteMetadataString(tokens[j + 1])
                                    break
                                }
                            }
                            if !typeName.isEmpty && !fields.isEmpty {
                                result[typeName] = fields
                            }
                        }
                    }
                }
            }
        }

        return result
    }

    /// 从 IR 顶层解析简单的 `constant` 全局定义，供 GEP/load 访问全局常量数组时发射到 MSL。
    private static func parseIRGlobalConstants(_ irText: String) -> [IRGlobalConstant] {
        var result: [IRGlobalConstant] = []

        for line in irText.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("@"), let eqRange = trimmed.range(of: " = ") else { continue }
            guard trimmed.contains(" constant ") else { continue }

            let irName = String(trimmed[trimmed.startIndex..<eqRange.lowerBound]).trimmingCharacters(in: .whitespaces)
            let rhs = String(trimmed[eqRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            guard let constantRange = rhs.range(of: " constant ") else { continue }

            let afterConstant = String(rhs[constantRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            let (irType, afterType) = parseIRType(afterConstant)
            guard !irType.isEmpty else { continue }

            let (initializer, _) = parseIRValue(afterType)
            guard !initializer.isEmpty else { continue }

            result.append(IRGlobalConstant(irName: irName, irType: irType, initializer: initializer))
        }

        return result
    }

    private static func collectCompareSamplerStateGlobals(_ irText: String) -> Set<String> {
        let symbolPattern = try? NSRegularExpression(pattern: #"@[^,\s\)]+"#)
        var globals: Set<String> = []

        for rawLine in irText.components(separatedBy: "\n") where rawLine.contains("@air.sample_compare_depth") {
            guard let symbolPattern else { continue }
            let line = rawLine as NSString
            let matches = symbolPattern.matches(in: rawLine, range: NSRange(location: 0, length: line.length))
            guard matches.count >= 2 else { continue }
            let symbol = line.substring(with: matches[1].range)
            globals.insert(symbol)
        }

        return globals
    }

    private static func parseUInt64IRLiteral(_ text: String) -> UInt64? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let signed = Int64(trimmed) {
            return UInt64(bitPattern: signed)
        }
        if let unsigned = UInt64(trimmed) {
            return unsigned
        }
        if trimmed.hasPrefix("0x") || trimmed.hasPrefix("0X") {
            return UInt64(trimmed.dropFirst(2), radix: 16)
        }
        return nil
    }

    private static func parseSamplerStateRawValue(irType: String, initializer: String) -> UInt64? {
        let trimmedType = irType.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedInit = initializer.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmedType == "i64" {
            return parseUInt64IRLiteral(trimmedInit)
        }

        if trimmedType == "[2 x i64]" {
            let firstElementPattern = try? NSRegularExpression(pattern: #"i64\s+(-?(?:0x[0-9A-Fa-f]+|\d+))"#)
            guard let firstElementPattern else { return nil }
            let nsInit = trimmedInit as NSString
            guard let match = firstElementPattern.firstMatch(in: trimmedInit, range: NSRange(location: 0, length: nsInit.length)) else {
                return nil
            }
            let token = nsInit.substring(with: match.range(at: 1))
            return parseUInt64IRLiteral(token)
        }

        return nil
    }

    private static func renderSamplerStateDeclaration(
        irName: String,
        irType: String,
        initializer: String,
        usedBySampleCompare: Bool
    ) -> String? {
        guard irName.contains("__air_sampler_state"),
              let rawValue = parseSamplerStateRawValue(irType: irType, initializer: initializer) else {
            return nil
        }

        let symbolName = sanitizeIdentifier(
            String(irName.dropFirst()).replacingOccurrences(of: "\"", with: ""),
            fallback: "air_sampler_state",
            uppercaseFirst: false
        )
        let payload = rawValue & 0x000F_FFFF

        let coordMode = (payload & 0x8000) != 0 ? "coord::pixel" : "coord::normalized"

        let addressMode: String
        switch payload & 0x00FF {
        case 0x00:
            addressMode = "clamp_to_zero"
        case 0x49:
            addressMode = "clamp_to_edge"
        case 0x92:
            addressMode = "repeat"
        case 0xDB:
            addressMode = "mirrored_repeat"
        default:
            addressMode = "clamp_to_edge"
        }

        let filterMode = (payload & 0x0A00) != 0 ? "filter::linear" : "filter::nearest"
        var options = [coordMode, "address::\(addressMode)", filterMode]

        if (payload & 0x4000) != 0 {
            options.append("mip_filter::linear")
        } else if (payload & 0x2000) != 0 {
            options.append("mip_filter::nearest")
        }

        let compareCode = Int((payload >> 16) & 0xF)
        let compareFunction: String?
        switch compareCode {
        case 1:
            compareFunction = "less"
        case 2:
            compareFunction = "less_equal"
        case 3:
            compareFunction = "greater"
        case 4:
            compareFunction = "greater_equal"
        case 5:
            compareFunction = "equal"
        case 6:
            compareFunction = "not_equal"
        case 7:
            compareFunction = "always"
        case 8 where usedBySampleCompare:
            compareFunction = "never"
        default:
            compareFunction = nil
        }

        if let compareFunction {
            options.append("compare_func::\(compareFunction)")
        }

        return "constexpr sampler \(symbolName)(\(options.joined(separator: ", ")));"
    }

    // MARK: - Public API

    /// 将 LLVM IR 文本转换为 MSL 源码。
    ///
    /// - Parameters:
    ///   - irText: llvm-dis 生成的 LLVM IR 文本
    ///   - functionNames: 原始 metallib 中的函数名列表（从 MetallibParser 获取）
    ///   - functionTypes: 函数类型列表（vertex/fragment/kernel，与 functionNames 对应）
    /// - Returns: 转换结果
    /// - Throws: `ConversionError`
    static func convert(
        irText: String,
        functionNames: [String] = [],
        functionTypes: [String] = []
    ) throws -> ConversionResult {
        guard !irText.isEmpty else {
            throw ConversionError.emptyIR
        }

        let startTime = CFAbsoluteTimeGetCurrent()

        // 1. 解析 IR metadata，获取精确的 shader 函数签名信息
        let metadataFuncs = parseIRMetadata(irText)

        // 1b. 解析 IR 结构体类型定义 (E-004e4c)
        let structTypeDefs = parseIRStructTypes(irText)
        // 1c. 解析 metadata 中的结构体字段信息 (E-004e4c)
        let structFieldInfo = parseStructFieldInfoFromMetadata(irText, metadataFuncs: metadataFuncs)
        // 1d. 解析顶层全局常量（供 GEP/load 命中 `@const_array[...]` 场景复用）
        let globalConstants = parseIRGlobalConstants(irText)

        // 2. 解析 IR 中的函数定义
        let (irFunctions, totalCount) = parseIRFunctions(irText)

        // 3. 解析 IR 中所有 air.* 内建调用（E-004e3）
        let allAirCalls = parseAirBuiltinCalls(irText)

        // 4. 结合 metallib 函数信息和 metadata，识别 shader 函数
        let shaderFunctions = identifyShaderFunctions(
            irFunctions: irFunctions,
            metallibNames: functionNames,
            metallibTypes: functionTypes,
            metadataFuncs: metadataFuncs,
            airBuiltinCalls: allAirCalls,
            irText: irText
        )

        // 5. 生成 MSL 源码（传入结构体信息用于 GEP/extractvalue/insertvalue）
        let mslSource = generateMSL(
            functions: shaderFunctions,
            structTypeDefs: structTypeDefs,
            structFieldInfo: structFieldInfo,
            globalConstants: globalConstants,
            irText: irText
        )

        let elapsed = CFAbsoluteTimeGetCurrent() - startTime

        var stats = ConversionStats()
        stats.totalIRFunctions = totalCount
        stats.shaderFunctions = shaderFunctions.count
        stats.fullyParsedFunctions = shaderFunctions.filter { $0.isFullyParsed }.count
        stats.stubFunctions = shaderFunctions.filter { !$0.isFullyParsed }.count
        stats.airBuiltinCalls = allAirCalls.count
        stats.mappedAirCalls = allAirCalls.filter { $0.mapping != nil }.count
        stats.unmappedAirCalls = allAirCalls.filter { $0.mapping == nil }.count

        return ConversionResult(
            mslSource: mslSource,
            functions: shaderFunctions,
            elapsedSeconds: elapsed,
            stats: stats
        )
    }

    /// 安全地转换 IR 到 MSL，失败时返回 nil 并记录日志。
    static func safeConvert(
        irText: String,
        functionNames: [String] = [],
        functionTypes: [String] = []
    ) -> ConversionResult? {
        do {
            let result = try convert(
                irText: irText,
                functionNames: functionNames,
                functionTypes: functionTypes
            )
            NSLog("[PlayTools] IRToMSLConverter: success — %@", result.summary)
            return result
        } catch {
            NSLog("[PlayTools] IRToMSLConverter: failed — %@", error.localizedDescription)
            return nil
        }
    }

    // MARK: - IR Parsing

    /// 从 IR 文本中匹配的函数定义信息
    private struct IRFunctionDef {
        let name: String
        let returnType: String
        let parameterList: String
        let attributes: String
        let fullDefinition: String
        /// 函数体 IR 文本（define 行之后到 } 之前的所有行）
        let body: String
    }

    /// 解析 IR 文本中的所有函数定义。
    /// 返回 (解析的函数列表, 总函数定义数)
    private static func parseIRFunctions(_ irText: String) -> ([IRFunctionDef], Int) {
        var functions: [IRFunctionDef] = []

        let lines = irText.components(separatedBy: "\n")
        var totalDefines = 0
        var i = 0

        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)

            // 匹配 define 行
            guard trimmed.hasPrefix("define ") else { i += 1; continue }
            totalDefines += 1

            guard let funcDef = parseDefineLine(trimmed) else { i += 1; continue }

            // 提取函数体：从 define 行之后到 } 行
            var bodyLines: [String] = []
            i += 1
            while i < lines.count {
                let bodyLine = lines[i]
                let bodyTrimmed = bodyLine.trimmingCharacters(in: .whitespaces)
                if bodyTrimmed == "}" {
                    i += 1
                    break
                }
                bodyLines.append(bodyLine)
                i += 1
            }
            let body = bodyLines.joined(separator: "\n")

            functions.append(IRFunctionDef(
                name: funcDef.name,
                returnType: funcDef.returnType,
                parameterList: funcDef.parameterList,
                attributes: funcDef.attributes,
                fullDefinition: funcDef.fullDefinition,
                body: body
            ))
        }

        return (functions, totalDefines)
    }

    /// 解析单行 define 语句
    private static func parseDefineLine(_ line: String) -> IRFunctionDef? {
        // 格式: define [linkage] [visibility] [cconv] <ret_type> @<name>(<params>) [attrs]
        // 示例: define void @"air.vertex_shader"(ptr addrspace(1) %0, ...) #0 {
        // 示例: define <4 x float> @myVertexShader(...) local_unnamed_addr #2 {

        // 查找函数名: @"xxx" 或 @xxx
        guard let atIndex = line.firstIndex(of: "@") else { return nil }
        let afterAt = line[line.index(after: atIndex)...]

        let funcName: String
        let afterName: Substring

        if afterAt.hasPrefix("\"") {
            // 带引号的名字 @"some.name"
            let nameStart = afterAt.index(after: afterAt.startIndex)
            guard let quoteEnd = afterAt[nameStart...].firstIndex(of: "\"") else { return nil }
            funcName = String(afterAt[nameStart..<quoteEnd])
            afterName = afterAt[afterAt.index(after: quoteEnd)...]
        } else {
            // 不带引号的名字 @myFunc
            let nameEnd = afterAt.firstIndex(where: { $0 == "(" || $0 == " " }) ?? afterAt.endIndex
            funcName = String(afterAt[afterAt.startIndex..<nameEnd])
            afterName = afterAt[nameEnd...]
        }

        // 提取参数列表
        guard let parenStart = afterName.firstIndex(of: "(") else { return nil }
        let paramStart = afterName.index(after: parenStart)

        // 找匹配的闭括号（注意嵌套）
        var depth = 1
        var cursor = paramStart
        while cursor < afterName.endIndex && depth > 0 {
            if afterName[cursor] == "(" { depth += 1 }
            else if afterName[cursor] == ")" { depth -= 1 }
            if depth > 0 { cursor = afterName.index(after: cursor) }
        }
        let paramList = String(afterName[paramStart..<cursor])

        // 提取返回类型：在 @name 之前、define 之后
        let beforeAt = line[line.startIndex..<atIndex]
        let returnType = extractReturnType(from: String(beforeAt))

        // 提取属性（#N 标记之后的部分）
        let afterParams = cursor < afterName.endIndex ? String(afterName[cursor...]) : ""

        return IRFunctionDef(
            name: funcName,
            returnType: returnType,
            parameterList: paramList,
            attributes: afterParams,
            fullDefinition: line,
            body: ""  // filled by parseIRFunctions
        )
    }

    /// 从 define 行的前缀中提取返回类型
    private static func extractReturnType(from prefix: String) -> String {
        // prefix 格式: "define [linkage] [visibility] <ret_type> "
        // 常见返回类型: void, <4 x float>, i32, float, { <4 x float>, float }
        var cleaned = prefix
            .replacingOccurrences(of: "define ", with: "")
            .replacingOccurrences(of: "internal ", with: "")
            .replacingOccurrences(of: "external ", with: "")
            .replacingOccurrences(of: "private ", with: "")
            .replacingOccurrences(of: "linkonce_odr ", with: "")
            .replacingOccurrences(of: "weak ", with: "")
            .replacingOccurrences(of: "hidden ", with: "")
            .replacingOccurrences(of: "default ", with: "")
            .replacingOccurrences(of: "dso_local ", with: "")
            .trimmingCharacters(in: .whitespaces)

        // 处理尾部可能存在的 calling convention
        for cc in ["spir_func ", "spir_kernel ", "cc75 ", "cc76 ", "cc77 ", "fastcc "] {
            cleaned = cleaned.replacingOccurrences(of: cc, with: "")
        }

        return cleaned.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Shader Function Identification

    // MARK: E-006b2: Attribute Group & Orphaned Metadata Helpers

    /// 从 IR 文本中解析所有 attributes #N = { ... } 声明，返回 [ref → content] 映射。
    ///
    /// Metal AIR 中 shader 类型信息同时出现在两个位置：
    /// 1. `!air.vertex` / `!air.fragment` / `!air.kernel` 顶层 metadata（最可靠）
    /// 2. `attributes #N = { "air.fragment" ... }` 声明（define 行通过 #N 引用）
    ///
    /// 当顶层 metadata 缺失时（如某些合成 / 裁剪后的 IR），需要回退到 attributes 声明。
    private static func parseAttributeGroupDeclarations(_ irText: String) -> [String: String] {
        var groups: [String: String] = [:]
        for line in irText.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("attributes #") else { continue }
            guard let hashRange = trimmed.range(of: "#") else { continue }
            let afterHash = trimmed[hashRange.upperBound...]
            guard let eqRange = afterHash.range(of: " = ") else { continue }
            let numStr = String(afterHash[afterHash.startIndex..<eqRange.lowerBound])
            guard let openBrace = trimmed.range(of: "{"),
                  let closeBrace = trimmed.range(of: "}", range: openBrace.upperBound..<trimmed.endIndex) else { continue }
            let content = String(trimmed[openBrace.upperBound..<closeBrace.lowerBound])
            groups["#\(numStr)"] = content
        }
        return groups
    }

    /// 从 define 行的 attribute 字符串中提取 #N 引用列表。
    ///
    /// 示例: `local_unnamed_addr #0` → `["#0"]`
    private static func extractAttributeGroupRefs(from attributes: String) -> [String] {
        var refs: [String] = []
        var searchStart = attributes.startIndex
        while searchStart < attributes.endIndex,
              let range = attributes.range(of: "#", range: searchStart..<attributes.endIndex) {
            let afterHash = attributes[range.upperBound...]
            var numEnd = afterHash.startIndex
            while numEnd < afterHash.endIndex, afterHash[numEnd].isNumber {
                numEnd = afterHash.index(after: numEnd)
            }
            if numEnd > afterHash.startIndex {
                refs.append("#" + String(afterHash[afterHash.startIndex..<numEnd]))
            }
            searchStart = range.upperBound
        }
        return refs
    }

    /// 从 attributes 声明内容中检测 shader 类型。
    ///
    /// 在 `attributes #N = { "air.fragment" ... }` 中查找 shader 类型标记。
    private static func shaderTypeFromAttributeContent(_ content: String) -> ShaderType? {
        if content.contains("\"air.fragment\"") { return .fragment }
        if content.contains("\"air.vertex\"") { return .vertex }
        if content.contains("\"air.kernel\"") { return .kernel }
        return nil
    }

    /// 扫描所有 metadata 节点，收集 air.texture / air.sampler 类型的孤立参数信息。
    ///
    /// 某些 IR 中，`!air.vertex` / `!air.fragment` 顶层 metadata 缺失，但 `air.texture` / `air.sampler`
    /// 的参数 metadata 节点仍然存在（只是未被函数 metadata 节点的 args 列表引用）。
    /// 此函数扫描所有 `!N = !{...}` 节点，尝试解析为 MetadataArgInfo，
    /// 并按 `air.arg_name` 构建查找表，供 metadata 缺失时的回退路径使用。
    private static func parseOrphanedMetadataArgLookup(_ irText: String) -> [String: MetadataArgInfo] {
        var lookup: [String: MetadataArgInfo] = [:]
        let lines = irText.components(separatedBy: "\n")
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("!") else { continue }
            guard let eqRange = trimmed.range(of: " = ") else { continue }
            var content = String(trimmed[eqRange.upperBound...])
            if content.hasPrefix("distinct ") {
                content = String(content.dropFirst("distinct ".count))
            }
            guard let argInfo = parseMetadataArgNode(content) else { continue }
            let kind = argInfo.kind
            guard kind == "air.texture" || kind == "air.sampler" else { continue }
            let argName = argInfo.argName
            guard !argName.isEmpty, !argName.hasPrefix("arg") else { continue }
            // 只在同名 key 不存在时写入，避免后面的覆盖前面的
            if lookup[argName] == nil {
                lookup[argName] = argInfo
            }
        }
        return lookup
    }

    /// 结合 IR 函数定义、metallib 元数据和 IR metadata，识别 shader entry，
    /// 并补发射 entry 递归依赖的 internal helper 函数。
    private static func identifyShaderFunctions(
        irFunctions: [IRFunctionDef],
        metallibNames: [String],
        metallibTypes: [String],
        metadataFuncs: [MetadataFuncInfo] = [],
        airBuiltinCalls: [AirBuiltinCall] = [],
        irText: String = ""
    ) -> [ParsedShaderFunction] {
        // 构建 metadata 函数名→信息的映射
        var metadataMap: [String: MetadataFuncInfo] = [:]
        for mf in metadataFuncs {
            metadataMap[mf.name] = mf
        }

        // 构建 metallib 函数名→类型的映射
        var nameToType: [String: ShaderType] = [:]
        for (i, name) in metallibNames.enumerated() {
            if i < metallibTypes.count {
                let typeStr = metallibTypes[i].lowercased()
                if typeStr.contains("vertex") { nameToType[name] = .vertex }
                else if typeStr.contains("fragment") { nameToType[name] = .fragment }
                else if typeStr.contains("kernel") { nameToType[name] = .kernel }
            }
        }

        // E-006b2: 预解析 attributes #N 声明和孤立 texture/sampler metadata 参数
        let attrGroups = !irText.isEmpty ? parseAttributeGroupDeclarations(irText) : [:]
        let orphanedArgLookup = !irText.isEmpty ? parseOrphanedMetadataArgLookup(irText) : [:]
        let irFunctionsByName = Dictionary(uniqueKeysWithValues: irFunctions.map { ($0.name, $0) })

        var parsedFunctions: [ParsedShaderFunction] = []
        var entryNames: Set<String> = []

        for irFunc in irFunctions {
            // 跳过 LLVM 内部函数和 air 运行时函数
            if irFunc.name.hasPrefix("llvm.") || irFunc.name.hasPrefix("air.") { continue }

            guard let type = detectEntryShaderType(
                for: irFunc,
                metadataMap: metadataMap,
                nameToType: nameToType,
                attrGroups: attrGroups,
                metallibNames: metallibNames
            ) else {
                continue
            }

            let params: [ParsedParameter]
            let outputs: [MetadataReturnInfo]
            let isFullyParsed: Bool
            if let metaInfo = metadataMap[irFunc.name] {
                params = buildParametersFromMetadata(
                    metaInfo.args,
                    irParamList: irFunc.parameterList,
                    irBody: irFunc.body,
                    shaderType: type
                )
                outputs = metaInfo.returns
                isFullyParsed = true
            } else {
                params = parseParameters(
                    irFunc.parameterList,
                    irBody: irFunc.body,
                    shaderType: type,
                    orphanedArgLookup: orphanedArgLookup
                )
                outputs = []
                isFullyParsed = false
            }

            let mslReturnType = deriveEntryReturnType(
                irReturnType: irFunc.returnType,
                shaderType: type,
                outputs: outputs,
                functionName: irFunc.name
            )

            parsedFunctions.append(ParsedShaderFunction(
                name: irFunc.name,
                shaderType: type,
                isEntryPoint: true,
                returnType: mslReturnType,
                outputs: outputs,
                parameters: params,
                irSignature: "define \(irFunc.returnType) @\"\(irFunc.name)\"(\(irFunc.parameterList))",
                isFullyParsed: isFullyParsed,
                airBuiltinCalls: airBuiltinCalls,
                irBody: irFunc.body
            ))
            entryNames.insert(irFunc.name)
        }

        // 如果 IR 中没找到匹配的函数，为 metallib 中的每个函数生成 stub
        if parsedFunctions.isEmpty && !metallibNames.isEmpty {
            for (i, name) in metallibNames.enumerated() {
                let type: ShaderType
                if i < metallibTypes.count {
                    let typeStr = metallibTypes[i].lowercased()
                    if typeStr.contains("fragment") { type = .fragment }
                    else if typeStr.contains("kernel") { type = .kernel }
                    else { type = .vertex }
                } else {
                    type = .vertex
                }

                parsedFunctions.append(ParsedShaderFunction(
                    name: name,
                    shaderType: type,
                    isEntryPoint: true,
                    returnType: defaultReturnType(for: type),
                    outputs: [],
                    parameters: [],
                    irSignature: "(metallib-only, no IR match)",
                    isFullyParsed: false,
                    airBuiltinCalls: [],
                    irBody: ""
                ))
                entryNames.insert(name)
            }
        }

        let reachableHelperNames = collectReachableHelperFunctionNames(
            entryNames: entryNames,
            irFunctionsByName: irFunctionsByName
        )

        for irFunc in irFunctions where reachableHelperNames.contains(irFunc.name) {
            let params = parseParameters(
                irFunc.parameterList,
                irBody: irFunc.body,
                shaderType: .helper,
                orphanedArgLookup: [:]
            )
            let mslReturnType = irTypeToMSL(irFunc.returnType, forShaderType: .helper)

            parsedFunctions.append(ParsedShaderFunction(
                name: irFunc.name,
                shaderType: .helper,
                isEntryPoint: false,
                returnType: mslReturnType,
                outputs: [],
                parameters: params,
                irSignature: "define \(irFunc.returnType) @\"\(irFunc.name)\"(\(irFunc.parameterList))",
                isFullyParsed: true,
                airBuiltinCalls: airBuiltinCalls,
                irBody: irFunc.body
            ))
        }

        return parsedFunctions
    }

    private static func detectEntryShaderType(
        for irFunc: IRFunctionDef,
        metadataMap: [String: MetadataFuncInfo],
        nameToType: [String: ShaderType],
        attrGroups: [String: String],
        metallibNames: [String]
    ) -> ShaderType? {
        if let metaInfo = metadataMap[irFunc.name] {
            return metaInfo.shaderType
        }
        if let type = nameToType[irFunc.name] {
            return type
        }
        if let attrType = extractAttributeGroupRefs(from: irFunc.attributes)
            .compactMap({ attrGroups[$0] })
            .compactMap({ shaderTypeFromAttributeContent($0) })
            .first {
            return attrType
        }
        if irFunc.name.contains("vertex") || irFunc.attributes.contains("vertex") {
            return .vertex
        }
        if irFunc.name.contains("fragment") || irFunc.attributes.contains("fragment") {
            return .fragment
        }
        if irFunc.name.contains("kernel") || irFunc.attributes.contains("kernel") {
            return .kernel
        }
        if metallibNames.contains(irFunc.name) {
            return .vertex
        }
        if !metallibNames.isEmpty && metadataMap.isEmpty {
            return nil
        }
        if isLikelyInternalHelperFunction(irFunc) {
            return nil
        }
        return inferShaderType(from: irFunc)
    }

    private static func isLikelyInternalHelperFunction(_ irFunc: IRFunctionDef) -> Bool {
        let fullDefinition = irFunc.fullDefinition
        return fullDefinition.hasPrefix("define internal ") ||
            fullDefinition.contains(" internal ") ||
            fullDefinition.contains(" private ") ||
            fullDefinition.contains(" linkonce_odr ") ||
            fullDefinition.contains(" fastcc ")
    }

    private static func collectReachableHelperFunctionNames(
        entryNames: Set<String>,
        irFunctionsByName: [String: IRFunctionDef]
    ) -> Set<String> {
        guard !entryNames.isEmpty else { return [] }

        var reachableHelpers: Set<String> = []
        var worklist = Array(entryNames)
        var visited: Set<String> = []

        while let current = worklist.popLast() {
            guard visited.insert(current).inserted,
                  let irFunc = irFunctionsByName[current] else {
                continue
            }

            for callee in parseCalledFunctionNames(from: irFunc.body) {
                guard !callee.hasPrefix("air."),
                      !callee.hasPrefix("llvm."),
                      !entryNames.contains(callee),
                      irFunctionsByName[callee] != nil else {
                    continue
                }

                if reachableHelpers.insert(callee).inserted {
                    worklist.append(callee)
                }
            }
        }

        return reachableHelpers
    }

    private static func parseCalledFunctionNames(from irBody: String) -> [String] {
        guard !irBody.isEmpty,
              let regex = try? NSRegularExpression(pattern: #"@(?:\"([^\"]+)\"|([A-Za-z0-9$._]+))\("#) else {
            return []
        }

        let range = NSRange(irBody.startIndex..<irBody.endIndex, in: irBody)
        var names: [String] = []
        var seen: Set<String> = []
        regex.enumerateMatches(in: irBody, options: [], range: range) { match, _, _ in
            guard let match else { return }
            for groupIndex in 1...2 {
                let groupRange = match.range(at: groupIndex)
                guard groupRange.location != NSNotFound,
                      let swiftRange = Range(groupRange, in: irBody) else {
                    continue
                }
                let name = String(irBody[swiftRange])
                if seen.insert(name).inserted {
                    names.append(name)
                }
                break
            }
        }
        return names
    }

    private static func deriveEntryReturnType(
        irReturnType: String,
        shaderType: ShaderType,
        outputs: [MetadataReturnInfo],
        functionName: String
    ) -> String {
        guard shaderType != .kernel else { return "void" }

        if shouldUseEntryOutputStruct(
            irReturnType: irReturnType,
            shaderType: shaderType,
            outputs: outputs,
            functionName: functionName
        ) {
            return entryOutputStructName(for: functionName)
        }

        if let onlyOutput = outputs.first {
            let normalizedType = onlyOutput.typeName
                .replacingOccurrences(of: "\"", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !normalizedType.isEmpty {
                return irScalarTypeToMSL(normalizedType)
            }
        }

        return irTypeToMSL(irReturnType, forShaderType: shaderType)
    }

    private static func shouldUseEntryOutputStruct(
        irReturnType: String,
        shaderType: ShaderType,
        outputs: [MetadataReturnInfo],
        functionName: String
    ) -> Bool {
        guard shaderType != .kernel, !outputs.isEmpty else { return false }
        if outputs.count > 1 { return true }
        guard let onlyOutput = outputs.first else { return false }
        let expectedFieldType = entryOutputFieldType(for: onlyOutput, index: 0)
        guard let unwrappedIRType = unwrapSingleFieldAggregateIRType(irReturnType) else {
            return false
        }
        return irTypeToMSL(unwrappedIRType, forShaderType: shaderType) == expectedFieldType
    }

    private static func unwrapSingleFieldAggregateIRType(_ irType: String) -> String? {
        var current = irType.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !current.isEmpty else { return nil }

        var unwrappedAtLeastOnce = false
        while true {
            let inner: String
            if current.hasPrefix("<{") && current.hasSuffix("}>") {
                inner = String(current.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespacesAndNewlines)
                unwrappedAtLeastOnce = true
            } else if current.hasPrefix("{") && current.hasSuffix("}") {
                inner = String(current.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
                unwrappedAtLeastOnce = true
            } else {
                return unwrappedAtLeastOnce ? current : nil
            }

            let fields = splitIRParameters(inner).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            guard fields.count == 1, let onlyField = fields.first else {
                return nil
            }
            current = onlyField
        }
    }

    private static func entryOutputStructName(for functionName: String) -> String {
        sanitizeTypeName(functionName) + "_Out"
    }

    private static func entryOutputFieldType(
        for output: MetadataReturnInfo,
        index: Int
    ) -> String {
        let rawTypeName = output.typeName.trimmingCharacters(in: .whitespacesAndNewlines)
        if rawTypeName.isEmpty {
            return output.kind == "air.position" ? "float4" : "float"
        }
        return irScalarTypeToMSL(rawTypeName)
    }

    /// 从 IR metadata 参数信息构建 ParsedParameter 列表。
    ///
    /// metadata 提供了精确的 MSL 类型名、参数名、绑定索引和地址空间，
    /// 比从 opaque pointer 参数推断要准确得多。
    ///
    /// 但真实 live / corpus 中经常会遇到 metadata 只覆盖 resource 参数、漏掉普通值参数（如 UV / clamp 输入）的情况。
    /// 这类漏参若不补齐，body lowering 会能解析 `%uv` / `%2`，但函数签名里没有对应声明，最终在 Metal 编译阶段报
    /// `use of undeclared identifier`。因此这里需要在 metadata 参数之外，按 IR define 的原始参数列表把缺失项补回。
    private static func buildParametersFromMetadata(
        _ metaArgs: [MetadataArgInfo],
        irParamList: String,
        irBody: String,
        shaderType: ShaderType
    ) -> [ParsedParameter] {
        let rawIRParams = splitIRParameters(irParamList)
        var params: [ParsedParameter] = []
        var mappedArgIndices: Set<Int> = []

        for meta in metaArgs {
            let fallbackIRAddrSpace: AddressSpace?
            if meta.argIndex >= 0 && meta.argIndex < rawIRParams.count {
                fallbackIRAddrSpace = extractAddressSpace(from: rawIRParams[meta.argIndex])
            } else {
                fallbackIRAddrSpace = nil
            }

            let addrSpace: AddressSpace?
            if let as_ = meta.addressSpace {
                addrSpace = AddressSpace(rawValue: as_)
            } else {
                addrSpace = fallbackIRAddrSpace
            }

            // 根据参数种类确定 attribute 和 pointerInfo
            let attribute: String?
            let ptrInfo: PointerInfo?

            switch meta.kind {
            case "air.buffer":
                attribute = nil
                let space = addrSpace ?? (meta.isReadOnly ? .constant : .device)
                // E-006b9: metal::_atomic → 根据内部字段类型映射为 atomic_int/atomic_uint
                let resolvedTypeName: String
                if meta.typeName == "metal::_atomic" {
                    if let firstField = meta.structFieldInfo.first {
                        // struct_type_info 格式: {offset, size, align, "uint"/"int", "__s"}
                        resolvedTypeName = "atomic_\(firstField.typeName)"
                    } else {
                        resolvedTypeName = "atomic_int"
                    }
                } else {
                    let rawName = meta.typeName.isEmpty ? "uint8_t" : meta.typeName
                    if rawName.first.map({ $0.isLowercase }) == true && !isMSLScalarOrVectorType(rawName) {
                        resolvedTypeName = sanitizeUserTypeName(rawName)
                    } else {
                        resolvedTypeName = rawName
                    }
                }
                ptrInfo = PointerInfo(
                    addressSpace: space,
                    pointedMSLType: resolvedTypeName,
                    isOpaquePointer: true
                )
            case "air.vertex_input":
                // vertex attribute 需要后续在函数签名里聚合成合成的 `stage_in` struct。
                attribute = nil
                ptrInfo = nil
            case "air.fragment_input":
                // fragment varying 需要后续在函数签名里聚合成合成的 `stage_in` struct。
                attribute = nil
                ptrInfo = nil
            case "air.position":
                // fragment position 在无 fragment_input 时可直接作为 builtin；
                // 若存在 fragment_input，则会在签名生成阶段并入合成的 stage_in struct。
                attribute = "[[position]]"
                ptrInfo = nil
            case "air.front_facing":
                // E-006g3a: front-facing 不是 stage_in varying，而是 fragment entry builtin。
                // 必须生成为显式 `[[front_facing]]` 形参，否则函数体里引用 mtl_FrontFace 会未声明。
                attribute = "[[front_facing]]"
                ptrInfo = nil
            case "air.vertex_output":
                continue
            case "air.render_target":
                continue
            case "air.vertex_id":
                attribute = "[[vertex_id]]"
                ptrInfo = nil
            case "air.instance_id":
                attribute = "[[instance_id]]"
                ptrInfo = nil
            case "air.base_vertex":
                attribute = "[[base_vertex]]"
                ptrInfo = nil
            case "air.base_instance":
                attribute = "[[base_instance]]"
                ptrInfo = nil
            case "air.thread_position_in_grid":
                attribute = "[[thread_position_in_grid]]"
                ptrInfo = nil
            case "air.thread_position_in_threadgroup":
                attribute = "[[thread_position_in_threadgroup]]"
                ptrInfo = nil
            case "air.threadgroup_position_in_grid":
                attribute = "[[threadgroup_position_in_grid]]"
                ptrInfo = nil
            case "air.threads_per_threadgroup":
                attribute = "[[threads_per_threadgroup]]"
                ptrInfo = nil
            case "air.thread_index_in_threadgroup":
                attribute = "[[thread_index_in_threadgroup]]"
                ptrInfo = nil
            case "air.texture":
                // texture 参数需要特殊处理
                attribute = meta.locationIndex.map { "[[texture(\($0))]]" }
                ptrInfo = nil
            case "air.sampler":
                attribute = meta.locationIndex.map { "[[sampler(\($0))]]" }
                ptrInfo = nil
            default:
                attribute = nil
                ptrInfo = nil
            }

            params.append(ParsedParameter(
                name: meta.argName,
                irType: meta.typeName,
                addressSpace: addrSpace,
                bufferIndex: meta.locationIndex,
                attribute: attribute,
                pointerInfo: ptrInfo,
                irArgIndex: meta.argIndex,
                kind: meta.kind,
                hasNoAlias: meta.argIndex >= 0 && meta.argIndex < rawIRParams.count && irParameterHasNoAlias(rawIRParams[meta.argIndex]),
                emitAsValueParameter: false
            ))
            mappedArgIndices.insert(meta.argIndex)
        }

        params.append(contentsOf: buildSupplementalParametersFromIR(
            rawIRParams,
            irBody: irBody,
            mappedArgIndices: mappedArgIndices,
            shaderType: shaderType
        ))

        return params.sorted { ($0.irArgIndex ?? .max) < ($1.irArgIndex ?? .max) }
    }

    /// 当 metadata 没有完整覆盖 define 参数列表时，从原始 IR 参数里补齐缺失项。
    ///
    /// 目标：
    /// - 保留 metadata 已知的 resource / builtin 精确信息
    /// - 仅对缺失项做最小保守补齐，优先保证"body 中用到的 SSA 名在签名里确实有声明"
    /// - 对缺失 builtin 的场景，优先按默认 entry builtin 规则推断，而不是把它误当成普通值参数
    private static func buildSupplementalParametersFromIR(
        _ rawIRParams: [String],
        irBody: String,
        mappedArgIndices: Set<Int>,
        shaderType: ShaderType
    ) -> [ParsedParameter] {
        var supplemental: [ParsedParameter] = []
        for (index, rawParam) in rawIRParams.enumerated() where !mappedArgIndices.contains(index) {
            let trimmed = rawParam.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed == "..." {
                continue
            }

            if let inferredBuiltin = inferImplicitEntryBuiltinParameter(
                from: trimmed,
                index: index,
                totalIRParamCount: rawIRParams.count,
                shaderType: shaderType
            ) {
                supplemental.append(inferredBuiltin)
                continue
            }

            let addrSpace = extractAddressSpace(from: trimmed)
            let ptrInfo = extractPointerInfo(from: trimmed, addressSpace: addrSpace)
            let bindingIndex = fallbackBindingIndex(for: rawIRParams, targetIndex: index, addressSpace: addrSpace)
            let cleanedValueType = extractIRValueParameterType(from: trimmed)
            let fallbackName = fallbackIRParameterName(from: trimmed, index: index)

            supplemental.append(ParsedParameter(
                name: fallbackName,
                irType: ptrInfo == nil ? cleanedValueType : trimmed,
                addressSpace: addrSpace,
                bufferIndex: bindingIndex,
                attribute: nil,
                pointerInfo: ptrInfo,
                irArgIndex: index,
                kind: nil,
                hasNoAlias: irParameterHasNoAlias(trimmed),
                emitAsValueParameter: ptrInfo == nil && !cleanedValueType.isEmpty && isIRParameterReferenced(trimmed, in: irBody)
            ))
        }
        return supplemental
    }

    /// metadata 缺失时，按常见 entry 函数布局保守推断默认 builtin 参数。
    private static func inferImplicitEntryBuiltinParameter(
        from rawIRParam: String,
        index: Int,
        totalIRParamCount: Int,
        shaderType: ShaderType
    ) -> ParsedParameter? {
        let cleanedValueType = extractIRValueParameterType(from: rawIRParam)
        guard let builtinIRType = defaultBuiltinIRType(for: shaderType),
              cleanedValueType == builtinIRType else {
            return nil
        }

        let name: String
        let attribute: String
        let kind: String

        switch shaderType {
        case .fragment:
            guard index == 0 else { return nil }
            name = defaultBuiltinParamName(for: .fragment) ?? "position"
            attribute = "[[position]]"
            kind = "air.position"
        case .vertex:
            guard index == totalIRParamCount - 1 else { return nil }
            name = defaultBuiltinParamName(for: .vertex) ?? "vid"
            attribute = "[[vertex_id]]"
            kind = "air.vertex_id"
        case .kernel:
            guard index == totalIRParamCount - 1 else { return nil }
            name = defaultBuiltinParamName(for: .kernel) ?? "tid"
            attribute = "[[thread_position_in_grid]]"
            kind = "air.thread_position_in_grid"
        case .helper:
            return nil
        }

        return ParsedParameter(
            name: name,
            irType: cleanedValueType,
            addressSpace: nil,
            bufferIndex: nil,
            attribute: attribute,
            pointerInfo: nil,
            irArgIndex: index,
            kind: kind,
            hasNoAlias: false,
            emitAsValueParameter: false
        )
    }

    /// 为 metadata 未覆盖的 IR 参数生成稳定可读的参数名。
    ///
    /// - 若 IR 自身有语义化名字（如 `%uv` / `%threshold`），优先保留
    /// - 若只剩数字 SSA（如 `%2`），退回为 `argN`
    private static func fallbackIRParameterName(from rawIRParam: String, index: Int) -> String {
        guard let irName = extractParamName(from: rawIRParam), !irName.isEmpty else {
            return "arg\(index)"
        }
        if irName.allSatisfy({ $0.isNumber }) {
            return "arg\(index)"
        }
        return irName
    }

    /// 从原始 IR 参数字符串里提取"值类型"部分，去掉限定词与参数名。
    ///
    /// 示例：
    /// - `<2 x float> noundef %uv` → `<2 x float>`
    /// - `i32 noundef %3` → `i32`
    /// - `%struct.Foo %arg` → `%struct.Foo`
    private static func extractIRValueParameterType(from rawIRParam: String) -> String {
        let trimmed = rawIRParam.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let candidate: String
        if let percentIndex = trimmed.lastIndex(of: "%") {
            candidate = String(trimmed[..<percentIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            candidate = trimmed
        }
        guard !candidate.isEmpty else { return "" }

        return extractLeadingIRType(from: candidate)
    }

    /// 判断原始 IR 参数是否真的在函数体里被引用。
    ///
    /// 只对 `%name` / `%2` 这种参数 SSA 做精确匹配，避免 `%1` 误命中 `%10`。
    private static func isIRParameterReferenced(_ rawIRParam: String, in irBody: String) -> Bool {
        guard let irName = extractParamName(from: rawIRParam), !irName.isEmpty else {
            return false
        }

        let token = "%\(irName)"
        var searchStart = irBody.startIndex
        while searchStart < irBody.endIndex,
              let range = irBody.range(of: token, range: searchStart..<irBody.endIndex) {
            let after = range.upperBound < irBody.endIndex ? irBody[range.upperBound] : nil
            if after == nil || !(after!.isLetter || after!.isNumber || after! == "_" || after! == ".") {
                return true
            }
            searchStart = range.upperBound
        }
        return false
    }

    /// 从一段参数前缀中抽取最前面的 IR 类型 token，支持向量 / 聚合 / 括号嵌套。
    private static func extractLeadingIRType(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let first = trimmed.first ?? " "
        if first == "<" || first == "{" || first == "(" {
            var angleDepth = 0
            var braceDepth = 0
            var parenDepth = 0
            var inQuotes = false

            for index in trimmed.indices {
                let char = trimmed[index]
                if char == "\"" {
                    inQuotes.toggle()
                } else if !inQuotes {
                    switch char {
                    case "<": angleDepth += 1
                    case ">": angleDepth -= 1
                    case "{": braceDepth += 1
                    case "}": braceDepth -= 1
                    case "(": parenDepth += 1
                    case ")": parenDepth -= 1
                    default: break
                    }
                    if angleDepth == 0 && braceDepth == 0 && parenDepth == 0 {
                        return String(trimmed[...index]).trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
            }
            return trimmed
        }

        let firstToken = trimmed.components(separatedBy: .whitespaces).first ?? trimmed
        return firstToken.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 对缺失 pointer 参数沿用 parseParameters 的顺序绑定规则，避免 buffer/threadgroup 索引错位。
    private static func fallbackBindingIndex(
        for rawIRParams: [String],
        targetIndex: Int,
        addressSpace: AddressSpace?
    ) -> Int? {
        guard let addressSpace else { return nil }

        if addressSpace.isBufferAddressSpace {
            var count = 0
            for i in 0..<rawIRParams.count {
                guard i <= targetIndex else { break }
                if let space = extractAddressSpace(from: rawIRParams[i]), space.isBufferAddressSpace {
                    if i == targetIndex { return count }
                    count += 1
                }
            }
        }

        if addressSpace.isThreadgroupAddressSpace {
            var count = 0
            for i in 0..<rawIRParams.count {
                guard i <= targetIndex else { break }
                if let space = extractAddressSpace(from: rawIRParams[i]), space.isThreadgroupAddressSpace {
                    if i == targetIndex { return count }
                    count += 1
                }
            }
        }

        return targetIndex
    }

    /// 从 IR 函数特征启发式推断 shader 类型
    private static func inferShaderType(from irFunc: IRFunctionDef) -> ShaderType? {
        // 检查 calling convention 标记
        if irFunc.fullDefinition.contains("spir_kernel") || irFunc.fullDefinition.contains("cc76") {
            return .kernel
        }
        // cc75 在 Metal IR 中通常用于 vertex，cc77 用于 fragment
        if irFunc.fullDefinition.contains("cc75") {
            return .vertex
        }
        if irFunc.fullDefinition.contains("cc77") {
            return .fragment
        }

        // 从返回类型推断
        let ret = irFunc.returnType
        if ret == "void" {
            // void 返回通常是 kernel
            return .kernel
        }
        if ret.contains("<4 x float>") || ret.contains("{ <4 x float>") {
            // float4 或包含 float4 的结构体 → 通常是 vertex
            return .vertex
        }

        return nil
    }

    // MARK: - Parameter Parsing

    /// 解析 IR 函数的参数列表
    private static func parseParameters(
        _ paramList: String,
        irBody: String,
        shaderType: ShaderType,
        orphanedArgLookup: [String: MetadataArgInfo] = [:]
    ) -> [ParsedParameter] {
        guard !paramList.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }

        let rawParams = splitIRParameters(paramList)
        var params: [ParsedParameter] = []
        var bufferIdx = 0
        var threadgroupIdx = 0

        for (index, rawParam) in rawParams.enumerated() {
            let trimmed = rawParam.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed == "..." { continue }

            if let inferredBuiltin = inferImplicitEntryBuiltinParameter(
                from: trimmed,
                index: index,
                totalIRParamCount: rawParams.count,
                shaderType: shaderType
            ) {
                params.append(inferredBuiltin)
                continue
            }

            // 提取地址空间
            let addrSpace = extractAddressSpace(from: trimmed)
            let paramName = fallbackIRParameterName(from: trimmed, index: index)

            // E-006b2: 检查孤立 metadata 中是否有 texture/sampler 信息
            if let orphaned = orphanedArgLookup[paramName] {
                let attribute: String?
                let ptrInfo: PointerInfo?
                let irType: String
                switch orphaned.kind {
                case "air.texture":
                    attribute = orphaned.locationIndex.map { "[[texture(\($0))]]" }
                    ptrInfo = nil
                    irType = orphaned.typeName.isEmpty ? "texture2d<float>" : orphaned.typeName
                case "air.sampler":
                    attribute = orphaned.locationIndex.map { "[[sampler(\($0))]]" }
                    ptrInfo = nil
                    irType = "sampler"
                default:
                    attribute = nil
                    ptrInfo = nil
                    irType = ""
                }
                params.append(ParsedParameter(
                    name: orphaned.argName,
                    irType: irType,
                    addressSpace: addrSpace,
                    bufferIndex: orphaned.locationIndex,
                    attribute: attribute,
                    pointerInfo: ptrInfo,
                    irArgIndex: index,
                    kind: orphaned.kind,
                    hasNoAlias: irParameterHasNoAlias(trimmed),
                    emitAsValueParameter: false
                ))
                continue
            }

            // 提取指针信息
            let ptrInfo = extractPointerInfo(from: trimmed, addressSpace: addrSpace)
            let cleanedValueType = extractIRValueParameterType(from: trimmed)

            // 确定 buffer/threadgroup 绑定索引
            let bindingIndex: Int?
            if let space = addrSpace {
                if space.isBufferAddressSpace {
                    bindingIndex = bufferIdx
                    bufferIdx += 1
                } else if space.isThreadgroupAddressSpace {
                    bindingIndex = threadgroupIdx
                    threadgroupIdx += 1
                } else {
                    bindingIndex = index
                }
            } else {
                bindingIndex = index
            }

            params.append(ParsedParameter(
                name: paramName,
                irType: ptrInfo == nil ? cleanedValueType : trimmed,
                addressSpace: addrSpace,
                bufferIndex: bindingIndex,
                attribute: nil,
                pointerInfo: ptrInfo,
                irArgIndex: index,
                kind: nil,
                hasNoAlias: irParameterHasNoAlias(trimmed),
                emitAsValueParameter: ptrInfo == nil && !cleanedValueType.isEmpty && isIRParameterReferenced(trimmed, in: irBody)
            ))
        }

        return params
    }

    /// 将 IR 参数列表按逗号分割，但保持尖括号嵌套（如 <4 x float>）
    private static func splitIRParameters(_ paramList: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0

        for char in paramList {
            if char == "<" || char == "{" || char == "(" || char == "[" { depth += 1 }
            else if char == ">" || char == "}" || char == ")" || char == "]" { depth -= 1 }

            if char == "," && depth == 0 {
                parts.append(current)
                current = ""
            } else {
                current.append(char)
            }
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    /// 从 IR 类型字符串中提取 addrspace(N)
    private static func extractAddressSpace(from irType: String) -> AddressSpace? {
        guard let range = irType.range(of: "addrspace(") else { return nil }
        let afterParen = irType[range.upperBound...]
        guard let closeParen = afterParen.firstIndex(of: ")") else { return nil }
        let numStr = String(afterParen[afterParen.startIndex..<closeParen])
        guard let num = Int(numStr) else { return nil }
        return AddressSpace(rawValue: num)
    }

    private static func irParameterHasNoAlias(_ irParam: String) -> Bool {
        let sanitized = irParam
            .replacingOccurrences(of: ",", with: " ")
            .replacingOccurrences(of: "(", with: " ")
            .replacingOccurrences(of: ")", with: " ")
            .replacingOccurrences(of: "*", with: " ")
        return sanitized.split(whereSeparator: \.isWhitespace).contains { $0 == "noalias" }
    }

    /// 从 IR 参数字符串中提取完整的指针信息（地址空间 + 指向的元素类型）。
    ///
    /// Metal LLVM IR 中指针参数的常见形式：
    /// 1. Opaque pointer (LLVM 15+): `ptr addrspace(1) %buf`
    /// 2. Typed pointer (旧式): `float addrspace(1)* %buf`, `<4 x float> addrspace(1)* %buf`
    /// 3. 结构体指针: `%struct.MyStruct addrspace(1)* %buf`
    private static func extractPointerInfo(
        from irParam: String,
        addressSpace: AddressSpace?
    ) -> PointerInfo? {
        guard let space = addressSpace else { return nil }

        let trimmed = irParam.trimmingCharacters(in: .whitespaces)

        // Case 1: Opaque pointer — `ptr addrspace(N)`
        // LLVM 15+ 默认使用 opaque pointer，不携带元素类型信息
        if trimmed.hasPrefix("ptr ") || trimmed == "ptr" {
            return PointerInfo(
                addressSpace: space,
                pointedMSLType: inferDefaultElementType(for: space),
                isOpaquePointer: true
            )
        }

        // Case 2 & 3: Typed pointer — 提取 addrspace 前面的元素类型
        let pointedType = extractPointedType(from: trimmed)
        let mslType: String
        if let pointed = pointedType {
            mslType = irScalarTypeToMSL(pointed)
        } else {
            mslType = inferDefaultElementType(for: space)
        }

        return PointerInfo(
            addressSpace: space,
            pointedMSLType: mslType,
            isOpaquePointer: false
        )
    }

    /// 从 typed pointer IR 参数中提取指针指向的元素类型。
    ///
    /// 输入示例:
    /// - `float addrspace(1)* %buf` → `float`
    /// - `<4 x float> addrspace(2)* %0` → `<4 x float>`
    /// - `%struct.VertexIn addrspace(1)* %input` → `%struct.VertexIn`
    /// - `i32 addrspace(1)* %idx` → `i32`
    private static func extractPointedType(from irParam: String) -> String? {
        // 查找 "addrspace(" 位置
        guard let addrRange = irParam.range(of: "addrspace(") else { return nil }

        // addrspace 前面的部分就是元素类型
        let beforeAddr = irParam[irParam.startIndex..<addrRange.lowerBound]
            .trimmingCharacters(in: .whitespaces)

        if beforeAddr.isEmpty { return nil }

        // 如果以 "ptr" 开头说明是 opaque pointer，没有元素类型
        if beforeAddr == "ptr" { return nil }

        return beforeAddr
    }

    /// 对于 opaque pointer (LLVM 15+)，无法从 IR 参数中直接获取元素类型，
    /// 根据地址空间推断合理的默认元素类型。
    private static func inferDefaultElementType(for space: AddressSpace) -> String {
        switch space {
        case .device:
            // device buffer 最常见的是 float 或结构体指针，用 uint8_t 作为通用字节指针
            return "uint8_t"
        case .constant:
            // constant buffer 通常是 uniform 数据，用 uint8_t 作为通用字节指针
            return "uint8_t"
        case .threadgroup:
            // threadgroup 共享内存，用 uint8_t
            return "uint8_t"
        case .thread:
            // thread-local 默认 float
            return "float"
        case .threadgroupImageblock:
            return "float"
        case .rayData:
            return "uint8_t"
        case .objectData:
            return "uint8_t"
        }
    }

    /// 将单个 IR 标量/向量类型转换为 MSL 类型（公共方法，供 ParsedParameter 使用）。
    ///
    /// 将 IR 中出现的所有基本类型映射为 MSL 类型：
    /// - 整数: i1→bool, i8→char/uint8_t, i16→short, i32→int, i64→long
    /// - 浮点: half, float, double
    /// - 向量: <4 x float>→float4, <2 x i32>→int2
    /// - 结构体名: %struct.X→X
    /// - metal::_atomic: 需配合 structFieldInfo 确定具体 atomic_int/atomic_uint，
    ///   此处仅做基本映射回退，精确映射在 buildParametersFromMetadata 中完成
    static func irScalarTypeToMSL(_ irType: String) -> String {
        let cleaned = irType.trimmingCharacters(in: .whitespaces)

        // E-006b9: metal::_atomic → atomic_int 默认回退
        // 精确映射（atomic_uint 等）在 buildParametersFromMetadata 中根据 structFieldInfo 完成
        if cleaned == "metal::_atomic" { return "atomic_int" }

        // 基本整数类型
        if cleaned == "i1" { return "bool" }
        if cleaned == "i8" { return "uint8_t" }
        if cleaned == "i16" { return "short" }
        if cleaned == "i32" { return "int" }
        if cleaned == "i64" { return "long" }

        // 无符号整数变体（来自 zext/sext 上下文）
        // LLVM IR 本身无符号区分，但 MSL 需要，此处默认有符号
        if cleaned == "float" { return "float" }
        if cleaned == "half" { return "half" }
        if cleaned == "double" { return "float" } // MSL 不支持 double，降级为 float
        if cleaned == "void" { return "void" }

        // 向量类型: <N x T> → TN
        if cleaned.hasPrefix("<") && cleaned.hasSuffix(">") && cleaned.contains(" x ") {
            let inner = String(cleaned.dropFirst().dropLast())
            let parts = inner.components(separatedBy: " x ")
            if parts.count >= 2 {
                let count = parts[0].trimmingCharacters(in: .whitespaces)
                let elemRaw = parts.dropFirst().joined(separator: " x ").trimmingCharacters(in: .whitespaces)
                // E-006a2e10: i8 向量特殊处理 — MSL 不支持 uint8_tN，必须用 ucharN
                if elemRaw == "i8" {
                    return "uchar\(count)"
                }
                let elemType = irScalarTypeToMSL(elemRaw)
                return "\(elemType)\(count)"
            }
        }

        // 结构体名: %struct.VertexIn → VertexIn, %"class::Name" → class_Name
        if cleaned.hasPrefix("%struct.") {
            let structName = String(cleaned.dropFirst("%struct.".count))
            return sanitizeUserTypeName(structName)
        }
        if cleaned.hasPrefix("%") {
            let typeName = String(cleaned.dropFirst())
                .replacingOccurrences(of: "\"", with: "")
            return sanitizeUserTypeName(typeName)
        }

        // 指针类型 → void* 等效
        if cleaned.contains("*") || cleaned == "ptr" {
            return "uint8_t"
        }

        return cleaned.isEmpty ? "uint8_t" : cleaned
    }

    /// 判断类型名是否为 MSL 标量或向量基本类型（如 float, float2, float4, half, int, uint 等）。
    /// 这些类型在 metadata 中可能出现为 arg_type_name，但不应被 sanitizeTypeName 大写化。
    private static func isMSLScalarOrVectorType(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        let baseTypes: Set<String> = [
            "float", "half", "int", "uint", "short", "ushort", "char", "uchar",
            "bool", "double", "long", "ulong", "size_t", "ptrdiff_t",
            "float4x4", "float3x3", "float2x2", "half4x4", "half3x3", "half2x2",
            "texture1d", "texture2d", "texture3d", "texturecube",
            "texture1d_array", "texture2d_array",
            "sampler",
            "atomic_uint", "atomic_int",
            "thread", "device", "constant",
        ]
        if baseTypes.contains(trimmed) { return true }
        // 匹配 float2, float3, float4, int2, uint4 等向量类型
        let vectorPattern = "^(float|half|int|uint|short|ushort|char|uchar|bool|double|long|ulong)([2-4])$"
        if trimmed.range(of: vectorPattern, options: .regularExpression) != nil { return true }
        return false
    }

    /// 将类型名清理为合法的 MSL 标识符
    private static func sanitizeTypeName(_ name: String) -> String {
        sanitizeIdentifier(name, fallback: "UnknownType", uppercaseFirst: true)
    }

    private static func sanitizeUserTypeName(_ name: String) -> String {
        sanitizeIdentifier(name, fallback: "UnknownType", uppercaseFirst: false)
    }

    private static func sanitizeIdentifier(
        _ name: String,
        fallback: String,
        uppercaseFirst: Bool
    ) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }

        var result = ""
        for (index, char) in trimmed.enumerated() {
            let isAllowed = char.isLetter || char.isNumber || char == "_"
            let normalized: Character = isAllowed ? char : "_"
            if index == 0 && normalized.isNumber {
                result.append("_")
            }
            result.append(normalized)
        }

        if result.isEmpty { return fallback }
        if uppercaseFirst, let first = result.first {
            return String(first).uppercased() + result.dropFirst()
        }
        return result
    }

    /// 从 IR 参数字符串中提取参数名
    private static func extractParamName(from irParam: String) -> String? {
        // 参数名格式: %name 或 %0, %1 等
        guard let percentIndex = irParam.lastIndex(of: "%") else { return nil }
        let afterPercent = irParam[irParam.index(after: percentIndex)...]
        let name = afterPercent.prefix(while: { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." })
        return name.isEmpty ? nil : String(name)
    }

    /// 从 `define ...(<params>)` 形式的 IR 签名里提取纯参数列表。
    private static func extractIRParameterList(from irSignature: String) -> String {
        guard let openParen = irSignature.firstIndex(of: "(") else { return irSignature }
        var depth = 0
        var cursor = openParen
        while cursor < irSignature.endIndex {
            let char = irSignature[cursor]
            if char == "(" { depth += 1 }
            else if char == ")" {
                depth -= 1
                if depth == 0 {
                    let start = irSignature.index(after: openParen)
                    return String(irSignature[start..<cursor])
                }
            }
            cursor = irSignature.index(after: cursor)
        }
        return irSignature
    }

    /// 收集需要强制按指针参数发射的 constant struct buffer 参数。
    ///
    /// 某些 addrspace(2) 结构体参数虽然 metadata 看起来像“单个 uniforms 对象”，
    /// 但函数体里的 GEP 会对它做非零首索引（如 `%buf, i64 %instanceId, ...`），
    /// 这说明它在 IR 语义上其实是数组/指针根，而不是单对象引用。
    /// 这类参数若仍发射成 `constant T&`，后续 lowering 会生成 `buf[idx]` 之类非法 MSL。
    private static func collectArrayIndexedConstantStructBufferArgs(
        params: [ParsedParameter],
        irParamList: String,
        irBody: String
    ) -> Set<Int> {
        let candidateArgIndices = Set(params.compactMap { param -> Int? in
            guard let irArgIndex = param.irArgIndex,
                  let ptr = param.pointerInfo,
                  ptr.addressSpace == .constant,
                  ptr.addressSpace.isBufferAddressSpace,
                  isStructTypeName(ptr.pointedMSLType),
                  !ptr.pointedMSLType.hasPrefix("atomic_") else {
                return nil
            }
            return irArgIndex
        })
        guard !candidateArgIndices.isEmpty else { return [] }

        let rawIRParams = splitIRParameters(irParamList)
        var argIndexBySSAName: [String: Int] = [:]
        for argIndex in candidateArgIndices where argIndex < rawIRParams.count {
            let irName = extractParamName(from: rawIRParams[argIndex]) ?? "\(argIndex)"
            argIndexBySSAName["%\(irName)"] = argIndex
        }
        guard !argIndexBySSAName.isEmpty else { return [] }

        var forcedPointerArgIndices: Set<Int> = []
        for line in irBody.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.contains("getelementptr ") else { continue }

            let rhs: String
            if let equalIndex = trimmed.firstIndex(of: "=") {
                rhs = String(trimmed[trimmed.index(after: equalIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                rhs = trimmed
            }
            guard rhs.hasPrefix("getelementptr ") else { continue }

            var cleaned = rhs.replacingOccurrences(of: "getelementptr ", with: "")
                .trimmingCharacters(in: .whitespaces)
            if cleaned.hasPrefix("inbounds ") {
                cleaned = String(cleaned.dropFirst("inbounds ".count))
            }

            let parts = splitTypedOperands(cleaned, count: 10)
            guard parts.count >= 3 else { continue }

            let baseSSAName = extractSSAName(from: parts[1].value)
            guard let argIndex = argIndexBySSAName[baseSSAName] else { continue }

            let firstIdx = parts[2].value.trimmingCharacters(in: .whitespacesAndNewlines)
            if firstIdx != "0" {
                forcedPointerArgIndices.insert(argIndex)
            }
        }

        return forcedPointerArgIndices
    }

    // MARK: - IR Type → MSL Type Mapping

    /// 将 IR 返回类型转换为 MSL 类型
    private static func irTypeToMSL(_ irType: String, forShaderType shaderType: ShaderType) -> String {
        let cleaned = irType.trimmingCharacters(in: .whitespaces)

        // 基本类型映射
        if cleaned == "void" { return "void" }
        if cleaned == "float" { return "float" }
        if cleaned == "half" { return "half" }
        if cleaned == "i32" { return "int" }
        if cleaned == "i16" { return "short" }
        if cleaned == "i8" { return "char" }
        if cleaned == "i1" { return "bool" }
        if cleaned == "i64" { return "long" }
        if cleaned == "double" { return "double" }

        // packed/anonymous aggregate 返回值（如 fragment 的 <{ <4 x float> }> 或 live 样本中的 <{ <4 x float>, i8 }>）
        // 必须先于向量分支处理，否则会被误识别成 `<N x T>` 并产出类似 `float4{ <4` 的坏签名。
        if cleaned.hasPrefix("<{") || cleaned.hasPrefix("{") || cleaned.hasPrefix("%struct") {
            return defaultReturnType(for: shaderType)
        }

        // 向量类型: <N x T> → TN
        if cleaned.hasPrefix("<") && cleaned.hasSuffix(">") && cleaned.contains(" x ") {
            let inner = String(cleaned.dropFirst().dropLast())  // 去掉 < >
            let parts = inner.components(separatedBy: " x ")
            if parts.count >= 2 {
                let count = parts[0].trimmingCharacters(in: .whitespaces)
                let elemType = irTypeToMSL(
                    parts.dropFirst().joined(separator: " x ").trimmingCharacters(in: .whitespaces),
                    forShaderType: shaderType
                )
                return "\(elemType)\(count)"
            }
        }

        // 指针类型
        if cleaned.contains("ptr") || cleaned.contains("*") {
            return defaultReturnType(for: shaderType)
        }

        return defaultReturnType(for: shaderType)
    }

    /// Shader 类型的默认返回类型
    private static func defaultReturnType(for shaderType: ShaderType) -> String {
        switch shaderType {
        case .vertex: return "float4"
        case .fragment: return "float4"
        case .kernel: return "void"
        case .helper: return "float"
        }
    }

    // MARK: - IR Body Parser (E-004e4a)

    /// SSA 寄存器上下文：追踪 IR SSA 值到 MSL 表达式的映射。
    ///
    /// LLVM IR 使用 SSA（Static Single Assignment）形式，每个值只赋值一次。
    /// 本上下文维护 `%N` / `%name` → MSL 表达式字符串的映射，
    /// 将 IR 指令流翻译为线性的 MSL 语句序列。
    // MARK: - Phi Info (E-004e4b)

    /// 描述一条 phi 指令：来自哪些前驱 BB 取哪些值
    private struct PhiInfo {
        /// phi 的目标 SSA 名（%N）
        let ssaName: String
        /// phi 的 IR 类型
        let irType: String
        /// 分配的 MSL 变量名
        let mslVarName: String
        /// 来源列表：(value 操作数文本, 来源基本块标签)
        let incoming: [(value: String, label: String)]
    }

    /// 描述一条 br 指令
    private enum BranchInfo {
        /// 条件跳转: br i1 %cond, label %trueLabel, label %falseLabel
        case conditional(cond: String, trueLabel: String, falseLabel: String)
        /// 无条件跳转: br label %dest
        case unconditional(dest: String)
    }

    /// 描述一个基本块的预扫描信息
    private struct BasicBlockInfo {
        let label: String
        var phiNodes: [PhiInfo] = []
        var branch: BranchInfo?
        /// 该 BB 的前驱列表
        var predecessors: [String] = []
    }

    private class SSAContext {
        /// %N → MSL 表达式 或 临时变量名
        var values: [String: String] = [:]
        /// %N → MSL 类型（用于需要类型信息的操作）
        var types: [String: String] = [:]
        /// 生成的 MSL 语句（按顺序）
        var statements: [String] = []
        var indentLevel: Int = 0
        /// 下一个临时变量编号
        var nextTemp: Int = 0
        /// 函数参数名映射（IR 参数 %N → MSL 参数名）
        var paramNames: [String: String] = [:]
        /// 函数参数类型映射
        var paramTypes: [String: String] = [:]
        /// 当前函数的 MSL 返回类型
        var functionReturnType: String = ""
        var functionReturnFieldTypes: [String] = []
        /// 指针值集合（IR 参数/GEP/alloca 等会产出"地址"语义的 SSA）
        var pointerValues: Set<String> = []
        /// 指针 SSA → 指向的元素 MSL 类型（如 "uint4"、"int"、"float2"）
        /// 用于 load/store 时检测 signedness mismatch 并插入 as_type<> bitcast
        var pointerElementTypes: [String: String] = [:]

        // ── E-004e4b: CFG + phi 支持 ──

        /// 预扫描的基本块信息（label → info）
        var bbInfo: [String: BasicBlockInfo] = [:]
        /// phi 变量预声明：SSA 名 → MSL 变量名
        var phiVarNames: [String: String] = [:]
        /// 当前正在翻译的基本块标签
        var currentBBLabel: String = "entry"
        /// phi 变量声明语句（插入到函数体最前面）
        var phiDeclarations: [String] = []

        // ── E-004e4c: 结构体类型信息 ──

        /// IR 结构体定义表（%struct.XXX → 字段 IR 类型列表）
        var structTypeDefs: [String: IRStructTypeDef] = [:]
        /// MSL 类型名 → 字段信息（从 metadata air.struct_type_info 获取）
        var structFieldInfo: [String: [StructFieldInfo]] = [:]
        /// insertvalue 链追踪：SSA 名 → 已填充的字段表达式数组
        var insertValueFields: [String: [String]] = [:]
        var insertElementComponents: [String: [String]] = [:]

        // ── E-004e4c: 结构体辅助查找 ──

        /// 根据 IR 结构体类型名（如 "%struct.Particle"）和字段索引，查找字段名。
        /// 先通过 structTypeDefs 获取字段 IR 类型列表确认索引有效，
        /// 再通过 structFieldInfo 匹配字段名。
        func lookupFieldName(irStructType: String, fieldIndex: Int) -> String? {
            // 从 IR 结构体名提取 MSL 类型名："%struct.Particle" → "Particle"
            let mslTypeName = irStructTypeToMSLName(irStructType)
            if let fields = structFieldInfo[mslTypeName],
               fieldIndex < fields.count {
                return fields[fieldIndex].fieldName
            }
            return nil
        }

        /// 根据 IR 结构体类型名（如 "%struct.Particle"）和字段索引，查找字段的 MSL 类型名。
        func lookupFieldType(irStructType: String, fieldIndex: Int) -> String? {
            let mslTypeName = irStructTypeToMSLName(irStructType)
            if let fields = structFieldInfo[mslTypeName],
               fieldIndex < fields.count {
                return fields[fieldIndex].typeName
            }
            // 回退：从 IR 结构体定义查找字段 IR 类型
            if let def = structTypeDefs[irStructType],
               fieldIndex < def.fieldIRTypes.count {
                return IRToMSLConverter.irScalarTypeToMSL(def.fieldIRTypes[fieldIndex])
            }
            return nil
        }

        /// 从 insertvalue 链追踪缓存中读取指定字段值。
        func lookupInsertedFieldValue(aggregateSSA: String, fieldIndex: Int) -> String? {
            let key = aggregateSSA.trimmingCharacters(in: .whitespaces)
            guard let fields = insertValueFields[key], fieldIndex >= 0, fieldIndex < fields.count else {
                return nil
            }
            return fields[fieldIndex]
        }

        func lookupInsertedElementComponent(vectorSSA: String, elementIndex: Int) -> String? {
            let key = vectorSSA.trimmingCharacters(in: .whitespaces)
            guard let components = insertElementComponents[key],
                  elementIndex >= 0,
                  elementIndex < components.count else {
                return nil
            }
            return components[elementIndex]
        }

        /// 将 IR 结构体类型名转换为 MSL 类型名
        private func irStructTypeToMSLName(_ irName: String) -> String {
            // "%struct.Particle" → "Particle"
            // "%struct.metal::matrix" → "metal::matrix"
            // "%\"struct.metal::matrix\"" → "metal::matrix"
            var name = irName
            if name.hasPrefix("%\"") && name.hasSuffix("\"") {
                name = String(name.dropFirst(2).dropLast())
            } else if name.hasPrefix("%") {
                name = String(name.dropFirst())
            }
            if name.hasPrefix("struct.") {
                name = String(name.dropFirst("struct.".count))
            }
            return name
        }

        func freshTemp() -> String {
            let name = "t\(nextTemp)"
            nextTemp += 1
            return name
        }

        /// 查找 SSA 值对应的 MSL 表达式
        func resolve(_ ssaName: String) -> String {
            let name = ssaName.trimmingCharacters(in: .whitespaces)
            if let expr = values[name] { return expr }
            if let pname = paramNames[name] { return pname }
            // 字面量常量
            if name.hasPrefix("splat (") || name.hasPrefix("zeroinitializer") {
                return name
            }
            // undef / poison — 必须统一转为 0，不能泄漏到 MSL
            if name == "undef" || name == "poison" {
                return "0"
            }
            return name
        }

        func markPointer(_ ssaName: String, elementType: String = "") {
            pointerValues.insert(ssaName.trimmingCharacters(in: .whitespaces))
            if !elementType.isEmpty {
                pointerElementTypes[ssaName.trimmingCharacters(in: .whitespaces)] = elementType
            }
        }

        func isPointerLike(_ operand: String) -> Bool {
            let name = operand.trimmingCharacters(in: .whitespaces)
            if pointerValues.contains(name) {
                return true
            }
            if let expr = values[name], IRToMSLConverter.stripAddressOfExpression(expr) != nil {
                return true
            }
            return false
        }

        /// 记录一个 SSA 值的 MSL 表达式和类型
        func define(_ ssaName: String, expr: String, type: String = "") {
            values[ssaName] = expr
            if !type.isEmpty { types[ssaName] = type }
        }

        /// 发射一条 MSL 语句到输出
        func emit(_ stmt: String) {
            let indent = String(repeating: "    ", count: max(0, indentLevel))
            statements.append(indent + stmt)
        }

        /// 为 SSA 值分配临时变量并发射赋值语句
        func emitAssign(_ ssaName: String, type: String, expr: String) {
            let mslType = IRToMSLConverter.irScalarTypeToMSL(type)
            let temp = freshTemp()
            emit("\(mslType) \(temp) = \(expr);")
            define(ssaName, expr: temp, type: mslType)
        }

        /// 简洁版：推断类型时直接用 auto
        func emitAutoAssign(_ ssaName: String, expr: String, knownType: String = "") {
            let temp = freshTemp()
            let typeStr = knownType.isEmpty ? "auto" : knownType
            emit("\(typeStr) \(temp) = \(expr);")
            define(ssaName, expr: temp, type: knownType)
        }
    }

    /// 解析并翻译单个函数体的 IR 指令为 MSL 语句。
    ///
    /// 当前支持的指令类别（E-004e4a）：
    /// - 算术: fadd, fmul, fsub, fneg, add, sub, mul, udiv, sdiv, urem, srem
    /// - 浮点比较/整数比较: fcmp, icmp
    /// - 选择: select
    /// - 向量: shufflevector, extractelement, insertelement, extractvalue, insertvalue
    /// - 内存: load, store, getelementptr
    /// - 类型转换: zext, sext, trunc, fpext, fptrunc, bitcast, freeze
    /// - 控制流: ret, br → if/else 块 (E-004e4b)
    /// - air.* 内建调用: call/tail call @air.*
    /// - LLVM 内建: llvm.lifetime.* (忽略)
    ///
    /// E-004e4b 改进：
    /// - 两遍翻译：第一遍预扫描 phi 和 CFG，第二遍利用预扫描信息翻译
    /// - phi 节点 → 变量预声明 + 在前驱 BB 末尾赋值
    /// - 条件 br → if/else 块结构
    /// - 无条件 br → 忽略（fall-through）
    ///
    /// E-004e4c: 结构体路径还原（已完成）
    /// - extractvalue → 直接透传（匿名聚合）或 `.fieldName`（命名结构体）
    /// - insertvalue → 链式追踪，生成 `{ val0, val1, ... }`
    /// - GEP → 按类型层级解析，结构体字段用 `.fieldName`，数组用 `[idx]`
    private static func translateFunctionBody(
        _ func_: ParsedShaderFunction,
        irParamList: String,
        structTypeDefs: [String: IRStructTypeDef] = [:],
        structFieldInfo: [String: [StructFieldInfo]] = [:],
        forcedPointerArgIndices: Set<Int> = []
    ) -> [String] {
        let ctx = SSAContext()
        ctx.functionReturnType = func_.returnType
        ctx.functionReturnFieldTypes = func_.outputs.enumerated().map { index, output in
            entryOutputFieldType(for: output, index: index)
        }
        // E-004e4c: 传入结构体信息供 extractvalue/insertvalue/GEP 使用
        ctx.structTypeDefs = structTypeDefs
        ctx.structFieldInfo = structFieldInfo

        // 建立参数名映射：IR 的 %0, %1, ... → MSL 参数名
        setupParameterMappings(
            ctx,
            params: func_.parameters,
            irParamList: irParamList,
            shaderType: func_.shaderType,
            forcedPointerArgIndices: forcedPointerArgIndices
        )

        // E-006b6: IR 参数实际类型与 MSL 参数声明的类型不匹配修复
        // 某些 AIR IR 中，builtin 参数（如 thread_position_in_grid）的 IR 实际类型是 float 向量
        // （<3 x float>），但 metadata 的 air.arg_type_name 说是 uint 向量（"uint3"）。
        // 这导致 MSL 中参数声明为 uint3 但函数体内被当作 float3 使用，
        // 传给 sample() 等需要 float 坐标的 API 时会产生类型错误。
        // 修复：检测 IR 实际类型是 float 向量但 MSL 声明是 uint 向量的情况，
        // 在函数体开头插入 floatN(mslParam) 转换，并更新 SSA 映射。
        let rawIRParams = splitIRParameters(irParamList)
        for (i, rawParam) in rawIRParams.enumerated() {
            let typed = splitTypedOperands(rawParam, count: 1)
            guard let first = typed.first, !first.type.isEmpty else { continue }
            let irActualType = first.type
            // 仅处理 IR 实际类型是 float 向量的情况
            guard irActualType.contains("float") || irActualType.contains("half") else { continue }
            let irParamName = extractParamName(from: rawParam)
            guard let name = irParamName else { continue }
            let ssaName = "%\(name)"
            // 检查 MSL 参数类型是否是 uint 向量（来自 metadata 的 air.arg_type_name）
            if let mslParamType = ctx.paramTypes[ssaName],
               (mslParamType.contains("uint") || mslParamType.contains("int")),
               !mslParamType.contains("float") {
                let mslName = ctx.paramNames[ssaName] ?? "param\(i)"
                let floatMSLType = irScalarTypeToMSL(irActualType)
                let convertedName = ctx.freshTemp()
                ctx.emit("\(floatMSLType) \(convertedName) = \(floatMSLType)(\(mslName));")
                ctx.define(ssaName, expr: convertedName, type: irActualType)
            }
        }

        let bodyLines = func_.irBody.components(separatedBy: "\n")

        // ── 第一遍：预扫描 phi 节点和 CFG 结构 (E-004e4b) ──
        prescanPhiAndCFG(bodyLines, ctx: ctx)

        // 发射 phi 变量预声明（在函数体最前面）
        for decl in ctx.phiDeclarations {
            ctx.emit(decl)
        }

        let blockLines = buildBasicBlockLineMap(bodyLines)
        if shouldEmitStructuredCFG(blockLines, ctx: ctx) {
            var emittedBlocks: Set<String> = []
            emitStructuredBasicBlock(
                "entry",
                bodyLines: bodyLines,
                blockLines: blockLines,
                ctx: ctx,
                emittedBlocks: &emittedBlocks
            )
        } else {
            emitLinearizedFunctionBody(bodyLines, ctx: ctx)
        }

        return ctx.statements
    }

    private static func buildBasicBlockLineMap(_ lines: [String]) -> [String: [String]] {
        var blocks: [String: [String]] = ["entry": []]
        var currentLabel = "entry"

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if let label = parseBBLabel(trimmed) {
                currentLabel = label
                if blocks[label] == nil {
                    blocks[label] = []
                }
                continue
            }
            blocks[currentLabel, default: []].append(trimmed)
        }

        return blocks
    }

    private static func shouldEmitStructuredCFG(_ blockLines: [String: [String]], ctx: SSAContext) -> Bool {
        let blocksWithBranches = ctx.bbInfo.values.filter { $0.branch != nil }
        guard !blocksWithBranches.isEmpty else {
            return false
        }

        for block in blocksWithBranches {
            for successor in successorLabels(for: block.label, ctx: ctx) {
                guard blockLines[successor] != nil else {
                    return false
                }
            }
        }

        return true
    }

    private static func emitLinearizedFunctionBody(_ bodyLines: [String], ctx: SSAContext) {
        for line in bodyLines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            if trimmed.hasSuffix(":") && !trimmed.contains(" ") {
                ctx.currentBBLabel = String(trimmed.dropLast())
                ctx.emit("// BB: \(trimmed)")
                continue
            }
            if let colonIdx = trimmed.firstIndex(of: ":"),
               trimmed[trimmed.startIndex..<colonIdx].allSatisfy({ $0.isNumber || $0.isLetter || $0 == "_" }) {
                let labelCandidate = String(trimmed[trimmed.startIndex..<colonIdx])
                let afterColon = trimmed.index(after: colonIdx)
                if afterColon == trimmed.endIndex ||
                   trimmed[afterColon...].trimmingCharacters(in: .whitespaces).isEmpty ||
                   trimmed[afterColon...].trimmingCharacters(in: .whitespaces).hasPrefix(";") {
                    ctx.currentBBLabel = labelCandidate
                    ctx.emit("// BB\(labelCandidate):")
                    continue
                }
            }

            translateInstruction(trimmed, ctx: ctx)
        }
    }

    private static func emitStructuredBasicBlock(
        _ label: String,
        stopBefore stopLabel: String? = nil,
        bodyLines: [String],
        blockLines: [String: [String]],
        ctx: SSAContext,
        emittedBlocks: inout Set<String>
    ) {
        if let stopLabel, label == stopLabel {
            return
        }
        guard !emittedBlocks.contains(label) else { return }
        emittedBlocks.insert(label)
        ctx.currentBBLabel = label

        let lines = blockLines[label] ?? []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if isPhiInstruction(trimmed) {
                translateInstruction(trimmed, ctx: ctx)
                continue
            }
            if trimmed.hasPrefix("br ") {
                if emitStructuredConditionalBranch(
                    trimmed,
                    currentLabel: label,
                    stopBefore: stopLabel,
                    bodyLines: bodyLines,
                    blockLines: blockLines,
                    ctx: ctx,
                    emittedBlocks: &emittedBlocks
                ) {
                    return
                }

                translateBr(trimmed, ctx: ctx)
                if case .unconditional(let dest)? = parseBrInstruction(trimmed) {
                    if let stopLabel, dest == stopLabel {
                        return
                    }
                    if canEagerlyEmitSuccessor(
                        dest,
                        from: label,
                        ctx: ctx,
                        emittedBlocks: emittedBlocks
                    ) {
                        emitStructuredBasicBlock(
                            dest,
                            stopBefore: stopLabel,
                            bodyLines: bodyLines,
                            blockLines: blockLines,
                            ctx: ctx,
                            emittedBlocks: &emittedBlocks
                        )
                    } else {
                        emitBlocksInSourceOrderAfter(
                            label,
                            stopBefore: stopLabel,
                            bodyLines: bodyLines,
                            blockLines: blockLines,
                            ctx: ctx,
                            emittedBlocks: &emittedBlocks
                        )
                    }
                } else if case .conditional? = parseBrInstruction(trimmed) {
                    emitBlocksInSourceOrderAfter(
                        label,
                        stopBefore: stopLabel,
                        bodyLines: bodyLines,
                        blockLines: blockLines,
                        ctx: ctx,
                        emittedBlocks: &emittedBlocks
                    )
                }
                return
            }
            translateInstruction(trimmed, ctx: ctx)
        }
    }

    private static func emitStructuredConditionalBranch(
        _ line: String,
        currentLabel: String,
        stopBefore stopLabel: String? = nil,
        bodyLines: [String],
        blockLines: [String: [String]],
        ctx: SSAContext,
        emittedBlocks: inout Set<String>
    ) -> Bool {
        guard case .conditional(let condValue, let trueLabel, let falseLabel)? = parseBrInstruction(line),
              let shape = findStructuredConditionalShape(
                  currentLabel: currentLabel,
                  trueLabel: trueLabel,
                  falseLabel: falseLabel,
                  stopBefore: stopLabel,
                  ctx: ctx,
                  blockLines: blockLines
              ) else {
            return false
        }

        let cond = resolveIROperand(condValue, ctx: ctx)
        let mergeLabel = shape.mergeLabel

        ctx.emit("if (\(cond)) {")
        ctx.indentLevel += 1
        emitStructuredBranchArm(
            trueLabel,
            from: currentLabel,
            stopBefore: mergeLabel,
            bodyLines: bodyLines,
            blockLines: blockLines,
            ctx: ctx,
            emittedBlocks: &emittedBlocks
        )
        ctx.indentLevel -= 1
        ctx.emit("} else {")
        ctx.indentLevel += 1
        emitStructuredBranchArm(
            falseLabel,
            from: currentLabel,
            stopBefore: mergeLabel,
            bodyLines: bodyLines,
            blockLines: blockLines,
            ctx: ctx,
            emittedBlocks: &emittedBlocks
        )
        ctx.indentLevel -= 1
        ctx.emit("}")

        if stopLabel != mergeLabel,
           canEmitStructuredMerge(
               mergeLabel,
               expectedPredecessors: shape.mergePredecessors,
               ctx: ctx,
               emittedBlocks: emittedBlocks
           ) {
            emitStructuredBasicBlock(
                mergeLabel,
                stopBefore: stopLabel,
                bodyLines: bodyLines,
                blockLines: blockLines,
                ctx: ctx,
                emittedBlocks: &emittedBlocks
            )
        }
        return true
    }

    private static func emitStructuredBranchArm(
        _ label: String,
        from predecessorLabel: String,
        stopBefore stopLabel: String,
        bodyLines: [String],
        blockLines: [String: [String]],
        ctx: SSAContext,
        emittedBlocks: inout Set<String>
    ) {
        if label == stopLabel {
            let phiAssignments = collectPhiAssignments(forTarget: stopLabel, fromPred: predecessorLabel, ctx: ctx)
            for assignment in phiAssignments {
                ctx.emit(assignment)
            }
            return
        }
        guard !emittedBlocks.contains(label) else { return }
        emittedBlocks.insert(label)
        ctx.currentBBLabel = label

        let lines = blockLines[label] ?? []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || isPhiInstruction(trimmed) { continue }
            if trimmed.hasPrefix("br ") {
                if emitStructuredConditionalBranch(
                    trimmed,
                    currentLabel: label,
                    stopBefore: stopLabel,
                    bodyLines: bodyLines,
                    blockLines: blockLines,
                    ctx: ctx,
                    emittedBlocks: &emittedBlocks
                ) {
                    return
                }

                translateBr(trimmed, ctx: ctx)
                if case .unconditional(let dest)? = parseBrInstruction(trimmed) {
                    if dest == stopLabel {
                        return
                    }
                    if canEagerlyEmitSuccessor(
                        dest,
                        from: label,
                        ctx: ctx,
                        emittedBlocks: emittedBlocks
                    ) {
                        emitStructuredBasicBlock(
                            dest,
                            stopBefore: stopLabel,
                            bodyLines: bodyLines,
                            blockLines: blockLines,
                            ctx: ctx,
                            emittedBlocks: &emittedBlocks
                        )
                    } else {
                        emitBlocksInSourceOrderAfter(
                            label,
                            stopBefore: stopLabel,
                            bodyLines: bodyLines,
                            blockLines: blockLines,
                            ctx: ctx,
                            emittedBlocks: &emittedBlocks
                        )
                    }
                } else if case .conditional? = parseBrInstruction(trimmed) {
                    emitBlocksInSourceOrderAfter(
                        label,
                        stopBefore: stopLabel,
                        bodyLines: bodyLines,
                        blockLines: blockLines,
                        ctx: ctx,
                        emittedBlocks: &emittedBlocks
                    )
                }
                return
            }
            translateInstruction(trimmed, ctx: ctx)
        }
    }

    private static func emitBlocksInSourceOrderAfter(
        _ label: String,
        stopBefore stopLabel: String? = nil,
        bodyLines: [String],
        blockLines: [String: [String]],
        ctx: SSAContext,
        emittedBlocks: inout Set<String>
    ) {
        var foundStartLabel = label == "entry"
        var orderedLabels: [String] = []

        for line in bodyLines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, let parsedLabel = parseBBLabel(trimmed) else { continue }

            if !foundStartLabel {
                if parsedLabel == label {
                    foundStartLabel = true
                }
                continue
            }
            if let stopLabel, parsedLabel == stopLabel {
                break
            }
            orderedLabels.append(parsedLabel)
        }

        var pendingLabels = orderedLabels.filter { !emittedBlocks.contains($0) }
        var madeProgress = true
        while madeProgress, !pendingLabels.isEmpty {
            madeProgress = false
            var deferredLabels: [String] = []

            for nextLabel in pendingLabels {
                guard canEmitDeferredBlock(nextLabel, ctx: ctx, emittedBlocks: emittedBlocks) else {
                    deferredLabels.append(nextLabel)
                    continue
                }
                let beforeCount = emittedBlocks.count
                emitStructuredBasicBlock(
                    nextLabel,
                    stopBefore: stopLabel,
                    bodyLines: bodyLines,
                    blockLines: blockLines,
                    ctx: ctx,
                    emittedBlocks: &emittedBlocks
                )
                if emittedBlocks.count > beforeCount {
                    madeProgress = true
                }
            }

            pendingLabels = deferredLabels.filter { !emittedBlocks.contains($0) }
        }

        for nextLabel in pendingLabels where !emittedBlocks.contains(nextLabel) {
            emitStructuredBasicBlock(
                nextLabel,
                stopBefore: stopLabel,
                bodyLines: bodyLines,
                blockLines: blockLines,
                ctx: ctx,
                emittedBlocks: &emittedBlocks
            )
        }
    }

    private static func findStructuredConditionalShape(
        currentLabel: String,
        trueLabel: String,
        falseLabel: String,
        stopBefore stopLabel: String?,
        ctx: SSAContext,
        blockLines: [String: [String]]
    ) -> (mergeLabel: String, mergePredecessors: [String])? {
        guard blockLines[trueLabel] != nil,
              blockLines[falseLabel] != nil else {
            return nil
        }

        let trueDistances = reachableLabelDistances(from: trueLabel, stopBefore: stopLabel, ctx: ctx)
        let falseDistances = reachableLabelDistances(from: falseLabel, stopBefore: stopLabel, ctx: ctx)
        let trueReachable = Set(trueDistances.keys)
        let falseReachable = Set(falseDistances.keys)
        let commonCandidates = trueReachable.intersection(falseReachable).filter { label in
            guard label != currentLabel,
                  blockLines[label] != nil else {
                return false
            }
            if let stopLabel, label == stopLabel {
                return true
            }
            return (ctx.bbInfo[label]?.predecessors.count ?? 0) > 1
        }

        guard !commonCandidates.isEmpty else {
            return nil
        }

        let orderedCandidates = commonCandidates.compactMap { label -> (String, Int, Int)? in
            guard let trueDistance = trueDistances[label],
                  let falseDistance = falseDistances[label] else {
                return nil
            }
            return (label, trueDistance + falseDistance, max(trueDistance, falseDistance))
        }.sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
            if lhs.2 != rhs.2 { return lhs.2 < rhs.2 }
            return lhs.0 < rhs.0
        }

        for (candidate, _, _) in orderedCandidates {
            let mergePredecessors = ctx.bbInfo[candidate]?.predecessors.filter {
                trueReachable.contains($0) || falseReachable.contains($0)
            } ?? []
            if !mergePredecessors.isEmpty {
                return (candidate, mergePredecessors)
            }
        }

        return nil
    }

    private static func reachableLabelDistances(
        from startLabel: String,
        stopBefore stopLabel: String?,
        ctx: SSAContext
    ) -> [String: Int] {
        var distances: [String: Int] = [startLabel: 0]
        var queue: [String] = [startLabel]
        var queueIndex = 0

        while queueIndex < queue.count {
            let label = queue[queueIndex]
            queueIndex += 1
            let nextDistance = (distances[label] ?? 0) + 1

            for successor in successorLabels(for: label, ctx: ctx) {
                if let stopLabel, successor == stopLabel {
                    if distances[successor] == nil || nextDistance < (distances[successor] ?? Int.max) {
                        distances[successor] = nextDistance
                    }
                    continue
                }
                if distances[successor] != nil {
                    continue
                }
                distances[successor] = nextDistance
                queue.append(successor)
            }
        }

        return distances
    }

    private static func successorLabels(for label: String, ctx: SSAContext) -> [String] {
        guard let branch = ctx.bbInfo[label]?.branch else {
            return []
        }
        switch branch {
        case .conditional(_, let trueLabel, let falseLabel):
            return [trueLabel, falseLabel]
        case .unconditional(let dest):
            return [dest]
        }
    }

    private static func canEagerlyEmitSuccessor(
        _ label: String,
        from predecessor: String,
        ctx: SSAContext,
        emittedBlocks: Set<String>
    ) -> Bool {
        guard let bbInfo = ctx.bbInfo[label] else {
            return true
        }
        let pendingPredecessors = bbInfo.predecessors.filter {
            $0 != predecessor && !emittedBlocks.contains($0)
        }
        return pendingPredecessors.isEmpty
    }

    private static func canEmitStructuredMerge(
        _ label: String,
        expectedPredecessors: [String],
        ctx: SSAContext,
        emittedBlocks: Set<String>
    ) -> Bool {
        guard let bbInfo = ctx.bbInfo[label] else {
            return true
        }
        let expected = Set(expectedPredecessors)
        let pendingPredecessors = bbInfo.predecessors.filter {
            !expected.contains($0) && !emittedBlocks.contains($0)
        }
        return pendingPredecessors.isEmpty
    }

    private static func canEmitDeferredBlock(
        _ label: String,
        ctx: SSAContext,
        emittedBlocks: Set<String>
    ) -> Bool {
        guard let bbInfo = ctx.bbInfo[label] else {
            return true
        }
        if bbInfo.predecessors.isEmpty || label == "entry" {
            return true
        }
        return bbInfo.predecessors.allSatisfy { emittedBlocks.contains($0) }
    }

    private static func isPhiInstruction(_ line: String) -> Bool {
        guard let eqRange = line.range(of: " = ") else { return false }
        let rhs = String(line[eqRange.upperBound...]).trimmingCharacters(in: .whitespaces)
        return rhs.hasPrefix("phi ")
    }

    // MARK: - CFG Prescan (E-004e4b)

    /// 第一遍预扫描：收集所有 phi 节点和分支信息，建立 CFG。
    ///
    /// 目的：
    /// 1. 找到所有 phi 节点，为每个 phi 分配 MSL 变量名并预声明
    /// 2. 收集每个 BB 的终止分支信息（条件 br / 无条件 br）
    /// 3. 建立前驱关系，用于在前驱 BB 的 br 处插入 phi 赋值
    private static func prescanPhiAndCFG(_ lines: [String], ctx: SSAContext) {
        var currentLabel = "entry"
        var allBBs: [String: BasicBlockInfo] = [:]
        allBBs["entry"] = BasicBlockInfo(label: "entry")

        // 收集的 phi 信息（后续处理）
        var allPhis: [(bbLabel: String, phi: PhiInfo)] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            // 基本块标签
            if let label = parseBBLabel(trimmed) {
                currentLabel = label
                if allBBs[label] == nil {
                    allBBs[label] = BasicBlockInfo(label: label)
                }
                continue
            }

            // phi 指令：%N = phi <type> [val, %label], [val, %label], ...
            if let eqRange = trimmed.range(of: " = ") {
                let lhs = String(trimmed[trimmed.startIndex..<eqRange.lowerBound])
                    .trimmingCharacters(in: .whitespaces)
                let rhs = String(trimmed[eqRange.upperBound...])
                    .trimmingCharacters(in: .whitespaces)
                if lhs.hasPrefix("%") && rhs.hasPrefix("phi ") {
                    if let phi = parsePhiInstruction(lhs: lhs, rhs: rhs, ctx: ctx) {
                        allPhis.append((bbLabel: currentLabel, phi: phi))
                        allBBs[currentLabel]?.phiNodes.append(phi)
                    }
                    continue
                }
            }

            // br 指令
            if trimmed.hasPrefix("br ") {
                let brInfo = parseBrInstruction(trimmed)
                allBBs[currentLabel]?.branch = brInfo
                // 建立前驱关系
                switch brInfo {
                case .conditional(_, let trueLabel, let falseLabel):
                    if allBBs[trueLabel] == nil {
                        allBBs[trueLabel] = BasicBlockInfo(label: trueLabel)
                    }
                    allBBs[trueLabel]?.predecessors.append(currentLabel)
                    if allBBs[falseLabel] == nil {
                        allBBs[falseLabel] = BasicBlockInfo(label: falseLabel)
                    }
                    allBBs[falseLabel]?.predecessors.append(currentLabel)
                case .unconditional(let dest):
                    if allBBs[dest] == nil {
                        allBBs[dest] = BasicBlockInfo(label: dest)
                    }
                    allBBs[dest]?.predecessors.append(currentLabel)
                case .none:
                    break
                }
            }
        }

        ctx.bbInfo = allBBs

        // 为每个 phi 分配 MSL 变量名并生成预声明
        for (_, phi) in allPhis {
            let varName = phi.mslVarName
            ctx.phiVarNames[phi.ssaName] = varName
            ctx.define(phi.ssaName, expr: varName)

            // 预声明：用 phi 的 IR 类型推断 MSL 类型
            let mslType = irScalarTypeToMSL(phi.irType)
            ctx.phiDeclarations.append("\(mslType) \(varName); // phi pre-decl")
        }
    }

    /// 解析基本块标签，返回标签名或 nil
    private static func parseBBLabel(_ trimmed: String) -> String? {
        // 纯名字+冒号: "entry:" "10:"
        if trimmed.hasSuffix(":") && !trimmed.contains(" ") {
            return String(trimmed.dropLast())
        }
        // 带前驱注释: "10:  ; preds = %7"
        if let colonIdx = trimmed.firstIndex(of: ":") {
            let labelCandidate = String(trimmed[trimmed.startIndex..<colonIdx])
            if labelCandidate.allSatisfy({ $0.isNumber || $0.isLetter || $0 == "_" }) {
                let afterColon = trimmed.index(after: colonIdx)
                if afterColon == trimmed.endIndex ||
                   trimmed[afterColon...].trimmingCharacters(in: .whitespaces).isEmpty ||
                   trimmed[afterColon...].trimmingCharacters(in: .whitespaces).hasPrefix(";") {
                    return labelCandidate
                }
            }
        }
        return nil
    }

    /// 解析 phi 指令，提取类型和来源列表
    /// phi <type> [val1, %label1], [val2, %label2], ...
    private static func parsePhiInstruction(lhs: String, rhs: String, ctx: SSAContext) -> PhiInfo? {
        // rhs = "phi <type> [val, %label], [val, %label], ..."
        var cleaned = rhs
        // 去掉 "phi "
        guard cleaned.hasPrefix("phi ") else { return nil }
        cleaned = String(cleaned.dropFirst(4)).trimmingCharacters(in: .whitespaces)

        // 提取类型：到第一个 '[' 之前
        guard let firstBracket = cleaned.firstIndex(of: "[") else { return nil }
        let irType = String(cleaned[cleaned.startIndex..<firstBracket]).trimmingCharacters(in: .whitespaces)

        // 解析所有 [value, %label] 对
        var incoming: [(value: String, label: String)] = []
        var remaining = String(cleaned[firstBracket...])

        while let openBracket = remaining.firstIndex(of: "["),
              let closeBracket = remaining.firstIndex(of: "]"),
              openBracket < closeBracket {
            let inner = remaining[remaining.index(after: openBracket)..<closeBracket]
            let parts = inner.components(separatedBy: ",")
            if parts.count >= 2 {
                let value = parts[0].trimmingCharacters(in: .whitespaces)
                var label = parts[1].trimmingCharacters(in: .whitespaces)
                // 去掉 % 前缀
                if label.hasPrefix("%") {
                    label = String(label.dropFirst())
                }
                incoming.append((value: value, label: label))
            }
            remaining = String(remaining[remaining.index(after: closeBracket)...])
        }

        guard !incoming.isEmpty else { return nil }

        // 分配 MSL 变量名
        let varName = "phi_\(ctx.nextTemp)"
        ctx.nextTemp += 1

        return PhiInfo(
            ssaName: lhs,
            irType: irType,
            mslVarName: varName,
            incoming: incoming
        )
    }

    /// 解析 br 指令
    private static func parseBrInstruction(_ line: String) -> BranchInfo? {
        let cleaned = line.replacingOccurrences(of: "br ", with: "").trimmingCharacters(in: .whitespaces)

        if cleaned.hasPrefix("i1 ") {
            // 条件跳转: br i1 %cond, label %trueLabel, label %falseLabel
            let parts = cleaned.components(separatedBy: ",")
            guard parts.count >= 3 else { return nil }
            let condStr = parts[0].replacingOccurrences(of: "i1 ", with: "")
                .trimmingCharacters(in: .whitespaces)
            let trueLabel = parts[1].trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "label %", with: "")
                .replacingOccurrences(of: "label ", with: "")
                .trimmingCharacters(in: .whitespaces)
            let falseLabel = parts[2].trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "label %", with: "")
                .replacingOccurrences(of: "label ", with: "")
                .trimmingCharacters(in: .whitespaces)
            return .conditional(cond: condStr, trueLabel: trueLabel, falseLabel: falseLabel)
        } else if cleaned.hasPrefix("label ") {
            // 无条件跳转: br label %dest
            let dest = cleaned.replacingOccurrences(of: "label %", with: "")
                .replacingOccurrences(of: "label ", with: "")
                .trimmingCharacters(in: .whitespaces)
            return .unconditional(dest: dest)
        }

        return nil
    }

    /// 建立 IR 参数（%0, %1, ...）到 MSL 参数名的映射
    private static func setupParameterMappings(
        _ ctx: SSAContext,
        params: [ParsedParameter],
        irParamList: String,
        shaderType: ShaderType,
        forcedPointerArgIndices: Set<Int> = []
    ) {
        let irParams = splitIRParameters(irParamList)
        let usesStageIn = shouldUseStageInStruct(params, shaderType: shaderType)

        // 极小 fragment/kernel/vertex builtin 场景：metadata 可能把唯一 builtin 参数过滤掉，
        // 但 generateAllParams 仍会补默认 builtin 参数；此时把唯一 IR 参数接回默认 builtin 名。
        if params.isEmpty,
           irParams.count == 1,
           let builtinName = defaultBuiltinParamName(for: shaderType),
           let builtinIRType = defaultBuiltinIRType(for: shaderType) {
            let irName = extractParamName(from: irParams[0]) ?? "0"
            let ssaName = "%\(irName)"
            ctx.paramNames[ssaName] = builtinName
            ctx.paramTypes[ssaName] = builtinIRType
            return
        }

        var mappedArgIndices: Set<Int> = []

        for param in params {
            guard let irArgIndex = param.irArgIndex else { continue }
            let ssaName: String
            if irArgIndex < irParams.count {
                let irName = extractParamName(from: irParams[irArgIndex]) ?? "\(irArgIndex)"
                ssaName = "%\(irName)"
            } else {
                ssaName = "%\(irArgIndex)"
            }

            let fallbackName = "arg\(irArgIndex)"
            let resolvedBaseName = sanitizeIdentifier(param.name, fallback: fallbackName, uppercaseFirst: false)
            let resolvedName: String
            if usesStageIn && isStageInParameter(param, shaderType: shaderType) {
                resolvedName = "\(stageInParamName).\(resolvedBaseName)"
            } else {
                resolvedName = resolvedBaseName
            }

            ctx.paramNames[ssaName] = resolvedName
            if !param.irType.isEmpty {
                ctx.paramTypes[ssaName] = param.irType
            }
            if let ptr = param.pointerInfo {
                let emitsReference = ptr.addressSpace == .constant &&
                    ptr.addressSpace.isBufferAddressSpace &&
                    isStructTypeName(ptr.pointedMSLType) &&
                    !forcedPointerArgIndices.contains(irArgIndex)
                if !emitsReference {
                    ctx.markPointer(ssaName, elementType: ptr.pointedMSLType)
                }
            }
            mappedArgIndices.insert(irArgIndex)
        }

        for (i, irParam) in irParams.enumerated() where !mappedArgIndices.contains(i) {
            let irName = extractParamName(from: irParam) ?? "\(i)"
            let ssaName = "%\(irName)"
            ctx.paramNames[ssaName] = "param\(i)"
        }
    }

    private static func defaultBuiltinParamName(for type: ShaderType) -> String? {
        switch type {
        case .vertex:
            return "vid"
        case .fragment:
            return "position"
        case .kernel:
            return "tid"
        case .helper:
            return nil
        }
    }

    private static func defaultBuiltinIRType(for type: ShaderType) -> String? {
        switch type {
        case .vertex:
            return "i32"
        case .fragment:
            return "float4"
        case .kernel:
            return "i32"
        case .helper:
            return nil
        }
    }

    private static let stageInParamName = "stageIn"

    private static func shouldUseStageInStruct(
        _ params: [ParsedParameter],
        shaderType: ShaderType
    ) -> Bool {
        switch shaderType {
        case .vertex:
            return params.contains { $0.kind == "air.vertex_input" }
        case .fragment:
            return params.contains { $0.kind == "air.fragment_input" }
        case .kernel, .helper:
            return false
        }
    }

    private static func isStageInParameter(
        _ param: ParsedParameter,
        shaderType: ShaderType
    ) -> Bool {
        switch shaderType {
        case .vertex:
            return param.kind == "air.vertex_input"
        case .fragment:
            switch param.kind {
            case "air.fragment_input", "air.position":
                return true
            default:
                return false
            }
        case .kernel, .helper:
            return false
        }
    }

    /// 翻译单条 IR 指令
    private static func translateInstruction(_ line: String, ctx: SSAContext) {
        // 忽略 IR 注释和空行
        if line.hasPrefix(";") { return }

        // 忽略 llvm.lifetime 和 llvm.dbg 等内部调用
        if line.contains("@llvm.lifetime") || line.contains("@llvm.dbg") { return }

        // 形如 "%N = ..." 的赋值指令
        if let eqRange = line.range(of: " = ") {
            let lhs = String(line[line.startIndex..<eqRange.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            let rhs = String(line[eqRange.upperBound...])
                .trimmingCharacters(in: .whitespaces)

            if lhs.hasPrefix("%") {
                translateAssignment(lhs: lhs, rhs: rhs, ctx: ctx)
                return
            }
        }

        // 非赋值指令：ret, br, store, call void, tail call void
        if line.hasPrefix("ret ") {
            translateRet(line, ctx: ctx)
        } else if line.hasPrefix("br ") {
            translateBr(line, ctx: ctx)
        } else if line.hasPrefix("store ") {
            translateStore(line, ctx: ctx)
        } else if line.contains("call void @air.") {
            translateVoidAirCall(line, ctx: ctx)
        } else if line.contains("call void @air.") || line.contains("tail call void @air.") {
            translateVoidAirCall(line, ctx: ctx)
        } else {
            // 未识别的指令，作为注释保留
            ctx.emit("// [unhandled] \(line.prefix(120))")
        }
    }

    /// 翻译赋值指令（%N = <opcode> ...）
    private static func translateAssignment(lhs: String, rhs: String, ctx: SSAContext) {
        // 确定操作码
        let parts = rhs.components(separatedBy: " ")
        guard let opcode = parts.first else {
            ctx.emit("// [unknown] \(lhs) = \(rhs.prefix(100))")
            return
        }

        switch opcode {
        // ── 二元浮点算术 ──
        case "fadd", "fmul", "fsub", "fdiv", "frem":
            translateBinaryFP(lhs: lhs, rhs: rhs, opcode: opcode, ctx: ctx)
        // ── fneg ──
        case "fneg":
            translateFNeg(lhs: lhs, rhs: rhs, ctx: ctx)
        // ── 二元整数算术 ──
        case "add", "sub", "mul", "udiv", "sdiv", "urem", "srem",
             "shl", "lshr", "ashr", "and", "or", "xor":
            translateBinaryInt(lhs: lhs, rhs: rhs, opcode: opcode, ctx: ctx)
        // ── 比较 ──
        case "fcmp":
            translateFCmp(lhs: lhs, rhs: rhs, ctx: ctx)
        case "icmp":
            translateICmp(lhs: lhs, rhs: rhs, ctx: ctx)
        // ── 选择 ──
        case "select":
            translateSelect(lhs: lhs, rhs: rhs, ctx: ctx)
        // ── 向量 ──
        case "shufflevector":
            translateShuffleVector(lhs: lhs, rhs: rhs, ctx: ctx)
        case "extractelement":
            translateExtractElement(lhs: lhs, rhs: rhs, ctx: ctx)
        case "insertelement":
            translateInsertElement(lhs: lhs, rhs: rhs, ctx: ctx)
        case "extractvalue":
            translateExtractValue(lhs: lhs, rhs: rhs, ctx: ctx)
        case "insertvalue":
            translateInsertValue(lhs: lhs, rhs: rhs, ctx: ctx)
        // ── 内存 ──
        case "load":
            translateLoad(lhs: lhs, rhs: rhs, ctx: ctx)
        case "getelementptr":
            translateGEP(lhs: lhs, rhs: rhs, ctx: ctx)
        // ── 类型转换 ──
        case "zext", "sext", "trunc", "fpext", "fptrunc", "uitofp", "sitofp", "fptoui", "fptosi":
            translateIntCast(lhs: lhs, rhs: rhs, opcode: opcode, ctx: ctx)
        case "bitcast":
            translateBitcast(lhs: lhs, rhs: rhs, ctx: ctx)
        case "freeze":
            translateFreeze(lhs: lhs, rhs: rhs, ctx: ctx)
        // ── air.* / 其他 call ──
        case "tail", "call", "musttail", "notail":
            translateCall(lhs: lhs, rhs: rhs, ctx: ctx)
        // ── phi (控制流相关，E-004e4b) ──
        case "phi":
            translatePhi(lhs: lhs, rhs: rhs, ctx: ctx)
        // ── alloca ──
        case "alloca":
            translateAlloca(lhs: lhs, rhs: rhs, ctx: ctx)
        default:
            ctx.emit("// [unhandled] \(lhs) = \(rhs.prefix(100))")
        }
    }

    // MARK: - Instruction Translators

    /// 翻译二元浮点运算: fadd/fmul/fsub/fdiv/frem
    private static func translateBinaryFP(lhs: String, rhs: String, opcode: String, ctx: SSAContext) {
        // 格式: fadd [fast] <type> <op1>, <op2>
        let op: String
        switch opcode {
        case "fadd": op = "+"
        case "fmul": op = "*"
        case "fsub": op = "-"
        case "fdiv": op = "/"
        case "frem": op = "/* fmod */"
        default: op = "??"
        }

        let cleaned = rhs.replacingOccurrences(of: "\(opcode) ", with: "", options: .anchored)
        let (type, operands) = parseBinaryOperands(cleaned, skipKeywords: ["fast", "nnan", "ninf", "nsz", "arcp", "contract", "reassoc", "afn"])
        guard operands.count >= 2 else {
            ctx.define(lhs, expr: "/* parse error: \(rhs.prefix(60)) */")
            return
        }

        let a = resolveIROperand(operands[0], ctx: ctx)
        let b = resolveIROperand(operands[1], ctx: ctx)
        let mslType = irScalarTypeToMSL(type)

        if opcode == "frem" {
            ctx.emitAutoAssign(lhs, expr: "fmod(\(a), \(b))", knownType: mslType)
        } else {
            ctx.emitAutoAssign(lhs, expr: "\(a) \(op) \(b)", knownType: mslType)
        }
    }

    /// 翻译 fneg
    private static func translateFNeg(lhs: String, rhs: String, ctx: SSAContext) {
        // fneg [fast] <type> <op>
        let cleaned = stripFastMathFlags(rhs.replacingOccurrences(of: "fneg ", with: ""))
        let parts = cleaned.components(separatedBy: " ")
        let value: String
        if parts.count >= 2 {
            value = resolveIROperand(parts.dropFirst().joined(separator: " "), ctx: ctx)
        } else {
            value = resolveIROperand(cleaned, ctx: ctx)
        }
        ctx.emitAutoAssign(lhs, expr: "-(\(value))")
    }

    /// 翻译二元整数运算
    private static func translateBinaryInt(lhs: String, rhs: String, opcode: String, ctx: SSAContext) {
        let op: String
        switch opcode {
        case "add": op = "+"
        case "sub": op = "-"
        case "mul": op = "*"
        case "udiv", "sdiv": op = "/"
        case "urem", "srem": op = "%"
        case "shl": op = "<<"
        case "lshr", "ashr": op = ">>"
        case "and": op = "&"
        case "or": op = "|"
        case "xor": op = "^"
        default: op = "??"
        }

        let cleaned = rhs.replacingOccurrences(of: "\(opcode) ", with: "", options: .anchored)
        let (type, operands) = parseBinaryOperands(cleaned, skipKeywords: ["nsw", "nuw", "exact"])
        guard operands.count >= 2 else {
            ctx.define(lhs, expr: "/* parse error */")
            return
        }

        let a = resolveIROperand(operands[0], ctx: ctx)
        let b = resolveIROperand(operands[1], ctx: ctx)
        let mslType = irScalarTypeToMSL(type)
        ctx.emitAutoAssign(lhs, expr: "\(a) \(op) \(b)", knownType: mslType)
    }

    /// 翻译 fcmp
    private static func translateFCmp(lhs: String, rhs: String, ctx: SSAContext) {
        // fcmp [fast] <cond> <type> <op1>, <op2>
        let cleaned = stripFastMathFlags(rhs.replacingOccurrences(of: "fcmp ", with: ""))
        let tokens = cleaned.components(separatedBy: " ").filter { !$0.isEmpty }
        guard tokens.count >= 2 else {
            ctx.define(lhs, expr: "/* fcmp parse error */")
            return
        }
        let cond = tokens[0]
        // 剩余部分：<type> <op1>, <op2>
        let rest = tokens.dropFirst().joined(separator: " ")
        let (operandType, operands) = parseBinaryOperands(rest, skipKeywords: [])
        guard operands.count >= 2 else {
            ctx.define(lhs, expr: "/* fcmp operand error */")
            return
        }
        let a = resolveIROperand(operands[0], ctx: ctx)
        let b = resolveIROperand(operands[1], ctx: ctx)
        let mslOp = fcmpCondToMSL(cond)
        // 向量 fcmp 产出 <N x i1> → boolN，标量 fcmp 产出 i1 → bool
        let dim = extractVectorDim(operandType)
        let resultType = dim > 1 ? "bool\(dim)" : "bool"
        ctx.emitAutoAssign(lhs, expr: "\(a) \(mslOp) \(b)", knownType: resultType)
    }

    /// 翻译 icmp
    private static func translateICmp(lhs: String, rhs: String, ctx: SSAContext) {
        let cleaned = rhs.replacingOccurrences(of: "icmp ", with: "")
        let tokens = cleaned.components(separatedBy: " ").filter { !$0.isEmpty }
        guard tokens.count >= 2 else {
            ctx.define(lhs, expr: "/* icmp parse error */")
            return
        }
        let cond = tokens[0]
        let rest = tokens.dropFirst().joined(separator: " ")
        let (operandType, operands) = parseBinaryOperands(rest, skipKeywords: [])
        guard operands.count >= 2 else {
            ctx.define(lhs, expr: "/* icmp operand error */")
            return
        }
        let a = resolveIROperand(operands[0], ctx: ctx)
        let b = resolveIROperand(operands[1], ctx: ctx)
        let mslOp = icmpCondToMSL(cond)
        // 向量 icmp 产出 <N x i1> → boolN，标量 icmp 产出 i1 → bool
        let resultType: String
        let dim = extractVectorDim(operandType)
        if dim > 1 {
            resultType = "bool\(dim)"
        } else {
            resultType = "bool"
        }
        ctx.emitAutoAssign(lhs, expr: "\(a) \(mslOp) \(b)", knownType: resultType)
    }

    /// 翻译 select
    private static func translateSelect(lhs: String, rhs: String, ctx: SSAContext) {
        // select [fast-math-flags] <cond_type> <cond>, <type> <val_true>, <type> <val_false>
        let cleaned = stripFastMathFlags(rhs.replacingOccurrences(of: "select ", with: ""))
        let selectParts = splitTypedOperands(cleaned, count: 3)
        guard selectParts.count >= 3 else {
            ctx.define(lhs, expr: "/* select parse error */")
            return
        }
        let cond = resolveIROperand(selectParts[0].value, ctx: ctx)
        let valTrue = resolveIROperand(selectParts[1].value, ctx: ctx)
        let valFalse = resolveIROperand(selectParts[2].value, ctx: ctx)
        let resultType = irScalarTypeToMSL(selectParts[1].type)
        let condDim = extractVectorDim(selectParts[0].type)

        if condDim > 1 {
            let swizzles = (0..<condDim).map { vectorIndexToSwizzle($0) }
            let trueVector = "\(resultType)(\(valTrue))"
            let falseVector = "\(resultType)(\(valFalse))"
            let components = swizzles.map { swizzle in
                "(\(cond)).\(swizzle) ? (\(trueVector)).\(swizzle) : (\(falseVector)).\(swizzle)"
            }
            ctx.emitAutoAssign(lhs, expr: "\(resultType)(\(components.joined(separator: ", ")))", knownType: resultType)
            return
        }

        ctx.emitAutoAssign(lhs, expr: "\(cond) ? \(valTrue) : \(valFalse)", knownType: resultType)
    }

    /// 翻译 shufflevector
    private static func translateShuffleVector(lhs: String, rhs: String, ctx: SSAContext) {
        // shufflevector <type> <v1>, <type> <v2>, <mask_type> <mask>
        let cleaned = rhs.replacingOccurrences(of: "shufflevector ", with: "")
        let shuffleParts = splitTypedOperands(cleaned, count: 3)
        guard shuffleParts.count >= 3 else {
            ctx.define(lhs, expr: "/* shufflevector parse error */")
            return
        }

        let v1 = resolveIROperand(shuffleParts[0].value, ctx: ctx)
        let mask = shuffleParts[2].value
        let maskDim = extractVectorDim(shuffleParts[2].type)

        // 解析 mask 以确定 swizzle 模式
        let maskIndices = parseVectorConstant(mask, fallbackDim: maskDim)
        let resultDim = maskIndices.isEmpty ? maskDim : maskIndices.count

        // 如果 mask 全相同（broadcast/splat），生成 MSL vector splat
        if !maskIndices.isEmpty && maskIndices.allSatisfy({ $0 == maskIndices[0] }) {
            let idx = maskIndices[0]
            if idx >= 0 {
                let swizzle = vectorIndexToSwizzle(idx)
                let srcType = shuffleParts[0].type
                let outType = vectorTypeWithDim(srcType, dim: resultDim)
                let mslOutType = irScalarTypeToMSL(outType)
                if let cached = ctx.lookupInsertedElementComponent(vectorSSA: shuffleParts[0].value, elementIndex: idx) {
                    ctx.emitAutoAssign(lhs, expr: "\(mslOutType)(\(cached))", knownType: mslOutType)
                    return
                }
                ctx.emitAutoAssign(lhs, expr: "\(mslOutType)(\(v1).\(swizzle))", knownType: mslOutType)
            } else {
                // poison/undef splat
                ctx.define(lhs, expr: v1)
            }
            return
        }

        // 一般 swizzle
        let maxSrcDim = extractVectorDim(shuffleParts[0].type)
        let allFromV1 = maskIndices.allSatisfy { $0 < maxSrcDim }

        if allFromV1 && maskIndices.allSatisfy({ $0 >= 0 }) {
            // 纯 v1 swizzle
            let swizzle = maskIndices.map { vectorIndexToSwizzle($0) }.joined()
            ctx.emitAutoAssign(lhs, expr: "\(v1).\(swizzle)")
        } else {
            // 涉及 v2 或 poison，生成逐元素构造
            let v2 = resolveIROperand(shuffleParts[1].value, ctx: ctx)
            let srcType = shuffleParts[0].type
            let outType = vectorTypeWithDim(srcType, dim: resultDim)
            let mslType = irScalarTypeToMSL(outType)
            if let groupedExpr = groupedShuffleConstructor(
                v1: v1,
                v2: v2,
                srcIRType: srcType,
                resultMSLType: mslType,
                maskIndices: maskIndices,
                maxSrcDim: maxSrcDim
            ) {
                ctx.emitAutoAssign(lhs, expr: groupedExpr, knownType: mslType)
                return
            }
            var elems: [String] = []
            for idx in maskIndices {
                if idx < 0 {
                    elems.append("0")
                } else if idx < maxSrcDim {
                    elems.append("\(v1)[\(idx)]")
                } else {
                    elems.append("\(v2)[\(idx - maxSrcDim)]")
                }
            }
            ctx.emitAutoAssign(lhs, expr: "\(mslType)(\(elems.joined(separator: ", ")))", knownType: mslType)
        }
    }

    /// 翻译 extractelement
    private static func translateExtractElement(lhs: String, rhs: String, ctx: SSAContext) {
        // extractelement <type> <vec>, <idx_type> <idx>
        let cleaned = rhs.replacingOccurrences(of: "extractelement ", with: "")
        let parts = splitTypedOperands(cleaned, count: 2)
        guard parts.count >= 2 else {
            ctx.define(lhs, expr: "/* extractelement error */")
            return
        }
        let vec = resolveIROperand(parts[0].value, ctx: ctx)
        let idx = resolveIROperand(parts[1].value, ctx: ctx)

        // 常量索引用 swizzle
        if let idxNum = Int(idx) {
            if let cached = ctx.lookupInsertedElementComponent(vectorSSA: parts[0].value, elementIndex: idxNum) {
                ctx.define(lhs, expr: cached)
                return
            }
            let swizzle = vectorIndexToSwizzle(idxNum)
            ctx.emitAutoAssign(lhs, expr: "\(vec).\(swizzle)")
        } else {
            ctx.emitAutoAssign(lhs, expr: "\(vec)[\(idx)]")
        }
    }

    /// 翻译 insertelement
    private static func translateInsertElement(lhs: String, rhs: String, ctx: SSAContext) {
        // insertelement <type> <vec>, <elem_type> <elem>, <idx_type> <idx>
        let cleaned = rhs.replacingOccurrences(of: "insertelement ", with: "")
        let parts = splitTypedOperands(cleaned, count: 3)
        guard parts.count >= 3 else {
            ctx.define(lhs, expr: "/* insertelement error */")
            return
        }
        let vec = resolveIROperand(parts[0].value, ctx: ctx)
        let elem = resolveIROperand(parts[1].value, ctx: ctx)
        let idx = resolveIROperand(parts[2].value, ctx: ctx)

        let mslType = irScalarTypeToMSL(parts[0].type)
        let vectorDim = extractVectorDim(parts[0].type)
        if let idxNum = Int(idx), idxNum >= 0, idxNum < vectorDim, vectorDim > 1 {
            let vectorOperand = parts[0].value.trimmingCharacters(in: .whitespaces)
            let componentIRType = vectorElementIRType(parts[0].type)
            let zeroComponent = zeroInitializerExpression(forIRType: componentIRType)
            var components: [String]
            if vectorOperand == "poison" || vectorOperand == "undef" {
                components = Array(repeating: zeroComponent, count: vectorDim)
            } else if let cached = ctx.insertElementComponents[vectorOperand], cached.count == vectorDim {
                components = cached
            } else {
                components = (0..<vectorDim).map { componentIndex in
                    vectorComponentExpression(vectorExpr: vec, index: componentIndex)
                }
            }
            components[idxNum] = elem
            ctx.insertElementComponents[lhs.trimmingCharacters(in: .whitespaces)] = components
            ctx.emitAutoAssign(lhs, expr: "\(mslType)(\(components.joined(separator: ", ")))", knownType: mslType)
            return
        }

        let temp = ctx.freshTemp()
        if vec == "poison" || vec == "undef" {
            ctx.emit("\(mslType) \(temp) = \(mslType)(0);")
        } else {
            ctx.emit("\(mslType) \(temp) = \(vec);")
        }
        if let idxNum = Int(idx) {
            let swizzle = vectorIndexToSwizzle(idxNum)
            ctx.emit("\(temp).\(swizzle) = \(elem);")
        } else {
            ctx.emit("\(temp)[\(idx)] = \(elem);")
        }
        ctx.define(lhs, expr: temp, type: mslType)
    }

    /// 翻译 extractvalue (E-004e4c)
    ///
    /// IR 模式:
    /// - `extractvalue { <4 x float>, i8 } %5, 0` — 从 air.sample 返回值中提取 float4（丢弃 i8 coverage）
    /// - `extractvalue %struct.XXX %val, N` — 从命名结构体中提取字段
    ///
    /// 策略:
    /// 1. 匿名聚合 `{ <4 x float>, i8 }`：air.sample 等返回值 → 直接透传 aggregate 表达式
    ///    （因为 MSL 侧 air.sample 已经直接返回 float4，i8 coverage 被丢弃）
    /// 2. 命名结构体：有 metadata → 生成 `.fieldName`；无 metadata → 生成 `.fieldN`
    private static func translateExtractValue(lhs: String, rhs: String, ctx: SSAContext) {
        // extractvalue <type> <agg>, <idx>, ...
        let cleaned = rhs.replacingOccurrences(of: "extractvalue ", with: "")
        let parts = splitTypedOperands(cleaned, count: 1)
        guard let first = parts.first else {
            ctx.define(lhs, expr: "/* extractvalue error */")
            return
        }
        let aggType = first.type
        let aggregateSSA = first.value.trimmingCharacters(in: .whitespaces)
        let agg = resolveIROperand(first.value, ctx: ctx)
        // 后续索引在逗号后
        let afterFirst = cleaned.dropFirst(first.rawLength)
        let indices = afterFirst.components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .compactMap { Int($0) }

        if indices.count == 1,
           let cachedField = ctx.lookupInsertedFieldValue(aggregateSSA: aggregateSSA, fieldIndex: indices[0]) {
            ctx.define(lhs, expr: resolveIROperand(cachedField, ctx: ctx))
            return
        }

        // 判断是否为匿名聚合类型（花括号开头，非命名结构体）
        let trimmedType = aggType.trimmingCharacters(in: .whitespaces)
        let isAnonymousAggregate = trimmedType.hasPrefix("{") || trimmedType.hasPrefix("<{")
        let isNamedStruct = trimmedType.hasPrefix("%")

        if isAnonymousAggregate && indices.count == 1 && indices[0] == 0 {
            // 模式 1: 从 {<4 x float>, i8} 中提取第一个元素
            // 这是 air.sample 的典型模式：MSL 侧直接返回 float4
            ctx.define(lhs, expr: agg)
        } else if isNamedStruct && indices.count == 1 {
            // 模式 2: 命名结构体字段提取
            let fieldIdx = indices[0]
            if let fieldName = ctx.lookupFieldName(irStructType: trimmedType, fieldIndex: fieldIdx) {
                ctx.define(lhs, expr: "\(agg).\(fieldName)")
            } else if let def = ctx.structTypeDefs[trimmedType], def.fieldIRTypes.count == 1, fieldIdx == 0 {
                // 单字段 wrapper（如 matrix wrapper）直接透传，避免落回非法/无意义的 `.field0`
                ctx.define(lhs, expr: agg)
            } else {
                ctx.define(lhs, expr: "\(agg).field\(fieldIdx)")
            }
        } else if indices.count == 1 {
            // 其他聚合类型，用通用索引
            let fieldIdx = indices[0]
            ctx.define(lhs, expr: "\(agg).field\(fieldIdx)")
        } else {
            // 多级索引（罕见），生成链式访问
            var expr = agg
            for idx in indices {
                expr = "\(expr).field\(idx)"
            }
            ctx.define(lhs, expr: expr)
        }
    }

    /// 翻译 insertvalue (E-004e4c)
    ///
    /// IR 模式:
    /// - `insertvalue <{ <4 x float>, <2 x float> }> undef, <4 x float> %26, 0`  — 初始化第一个字段
    /// - `insertvalue <{ <4 x float>, <2 x float> }> %29, <2 x float> %28, 1`   — 填充后续字段
    ///
    /// 策略:
    /// insertvalue 链式构建返回值结构体。每次 insertvalue 将一个值插入到聚合中的指定位置。
    /// 链的第一步通常是 `insertvalue ... undef, val, 0`（aggregate 初始化为 undef）。
    ///
    /// 在 SSAContext 中，我们追踪每个中间 aggregate 的已填充字段，
    /// 当所有字段都被填充后，生成完整的结构体构造表达式。
    /// 对于部分填充的情况，我们也记录已知字段以备后续链式 insertvalue 使用。
    private static func translateInsertValue(lhs: String, rhs: String, ctx: SSAContext) {
        let cleaned = rhs.replacingOccurrences(of: "insertvalue ", with: "")
        let parts = splitTypedOperands(cleaned, count: 2)
        guard parts.count >= 2 else {
            ctx.define(lhs, expr: "/* insertvalue error */")
            return
        }

        let aggType = parts[0].type
        let aggValue = parts[0].value
        let val = resolveIROperand(parts[1].value, ctx: ctx)

        // 解析尾部索引（在最后一个逗号之后）
        // IR 格式: insertvalue <type> <agg>, <type> <val>, <idx>
        // 索引是最后一个逗号后面的纯数字
        let fieldIdx: Int
        if let lastComma = cleaned.lastIndex(of: ",") {
            let trailing = cleaned[cleaned.index(after: lastComma)...]
                .trimmingCharacters(in: .whitespaces)
            fieldIdx = Int(trailing) ?? 0
        } else {
            fieldIdx = 0
        }

        // 判断聚合类型（匿名 packed struct <{ ... }> 或普通 struct { ... }）
        let trimmedType = aggType.trimmingCharacters(in: .whitespaces)

        // 从类型字符串解析字段数量
        let fieldTypes = aggregateFieldTypes(trimmedType)
        let fieldCount = fieldTypes.count

        func makeAggregatePlaceholders(minimumCount: Int) -> [String] {
            let count = max(fieldCount, minimumCount)
            guard count > 0 else { return [] }
            return (0..<count).map { index in
                guard index < fieldTypes.count else { return "0" }
                return zeroInitializerExpression(forIRType: fieldTypes[index])
            }
        }

        // 判断是否为 undef 基础（链的起点）
        let isUndef = aggValue.trimmingCharacters(in: .whitespaces) == "undef" ||
                      aggValue.trimmingCharacters(in: .whitespaces) == "poison"

        if isUndef {
            // 链起点：记录已知的第一个字段
            var fields = makeAggregatePlaceholders(minimumCount: fieldIdx + 1)
            fields[fieldIdx] = val
            ctx.insertValueFields[lhs] = fields
            // 如果是单字段结构体，直接完成
            if fieldCount == 1 {
                ctx.define(lhs, expr: "{ \(val) }")
            } else {
                // 暂时定义为部分构造（后续 insertvalue 会覆盖）
                ctx.define(lhs, expr: "/* partial aggregate */")
            }
        } else {
            // 链继续：基于前一个 aggregate 追加字段
            var fields: [String]
            if let prevFields = ctx.insertValueFields[aggValue.trimmingCharacters(in: .whitespaces)] {
                fields = prevFields
                // 确保数组够大
                while fields.count <= fieldIdx { fields.append("0") }
                fields[fieldIdx] = val
            } else {
                // 无前驱记录，创建新的
                fields = makeAggregatePlaceholders(minimumCount: fieldIdx + 1)
                fields[fieldIdx] = val
            }
            ctx.insertValueFields[lhs] = fields

            // 检查是否所有字段都已填充（无 "0" 占位符）
            // 生成完整的构造表达式
            let allFilled = fields.count == fieldCount && fieldCount > 0
            if allFilled {
                ctx.define(lhs, expr: "{ \(fields.joined(separator: ", ")) }")
            } else {
                ctx.define(lhs, expr: "/* partial aggregate */")
            }
        }
    }

    /// 统计 IR aggregate 类型中的字段数量
    /// 如 `<{ <4 x float>, <2 x float> }>` → 2
    /// 如 `{ <4 x float>, i8 }` → 2
    private static func countAggregateFields(_ type: String) -> Int {
        aggregateFieldTypes(type).count
    }

    private static func aggregateFieldTypes(_ type: String) -> [String] {
        var body = type.trimmingCharacters(in: .whitespaces)
        // 去掉 packed struct 外层 <{ }>
        if body.hasPrefix("<{") && body.hasSuffix("}>") {
            body = String(body.dropFirst(2).dropLast(2))
        } else if body.hasPrefix("{") && body.hasSuffix("}") {
            body = String(body.dropFirst().dropLast())
        } else {
            return []  // 不是聚合类型
        }
        return splitIRParameters(body).map {
            $0.trimmingCharacters(in: .whitespaces)
        }.filter {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    private static func parseIRArrayType(_ irType: String) -> (count: Int, elementType: String)? {
        let trimmed = irType.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("["), trimmed.hasSuffix("]"), let xRange = trimmed.range(of: " x ") else {
            return nil
        }
        let countStr = String(trimmed[trimmed.index(after: trimmed.startIndex)..<xRange.lowerBound])
            .trimmingCharacters(in: .whitespaces)
        guard let count = Int(countStr) else { return nil }
        let afterX = trimmed[xRange.upperBound...]
        let elementType = String(afterX[..<afterX.index(before: afterX.endIndex)])
            .trimmingCharacters(in: .whitespaces)
        return (count, elementType)
    }

    private static func zeroInitializerExpression(forIRType irType: String) -> String {
        let trimmed = irType.trimmingCharacters(in: .whitespaces)
        if let array = parseIRArrayType(trimmed) {
            let zeroValue = zeroInitializerExpression(forIRType: array.elementType)
            return "{ \(Array(repeating: zeroValue, count: array.count).joined(separator: ", ")) }"
        }

        let fieldTypes = aggregateFieldTypes(trimmed)
        if !fieldTypes.isEmpty {
            return "{ \(fieldTypes.map { zeroInitializerExpression(forIRType: $0) }.joined(separator: ", ")) }"
        }

        if trimmed == "i1" {
            return "false"
        }

        let mslType = irScalarTypeToMSL(trimmed)
        if trimmed.hasPrefix("%") || isStructTypeName(mslType) {
            return "\(mslType)()"
        }
        return "\(mslType)(0)"
    }

    private static func stripAddressOfExpression(_ expr: String) -> String? {
        let trimmed = expr.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("&") else { return nil }

        var inner = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        if inner.hasPrefix("(") && inner.hasSuffix(")") {
            inner = String(inner.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return inner.isEmpty ? nil : inner
    }

    private static func addressExpression(for expr: String) -> String {
        let trimmed = expr.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "&(/* empty */)" }
        if stripAddressOfExpression(trimmed) != nil {
            return trimmed
        }
        return "&(\(trimmed))"
    }

    private static func lvalueExpression(from pointerExpr: String) -> String? {
        stripAddressOfExpression(pointerExpr)
    }

    /// 翻译 load
    private static func translateLoad(lhs: String, rhs: String, ctx: SSAContext) {
        // load <type>, <ptr_type> <ptr>[, align N][, !tbaa ...]
        let cleaned = rhs.replacingOccurrences(of: "load ", with: "")
        // 分割类型和指针，注意 <type> 可能包含逗号（如 <4 x float>）
        let parts = splitTypedOperands(cleaned, count: 2)
        guard parts.count >= 2 else {
            ctx.define(lhs, expr: "/* load error */")
            return
        }
        let loadType = parts[0].type
        let ptrOperand = parts[1].value.trimmingCharacters(in: .whitespaces)
        let ptr = resolveIROperand(ptrOperand, ctx: ctx)
        let mslType = irScalarTypeToMSL(loadType)
        let loadExpr = lvalueExpression(from: ptr) ?? "*(\(ptr))"
        // 从 ptrOperand 中提取纯 SSA 名（去掉 ptr addrspace(N) 等前缀）
        let ptrSSAName = extractSSAName(from: ptrOperand)
        // E-006b5: 检测指针元素类型与 load 类型之间的 signedness mismatch。
        // LLVM IR 的 i32 没有 signedness，但 MSL 的 int4/uint4 是不同类型。
        // 当 load 从 device uint4* 加载但 IR 类型为 <4 x i32>（→int4）时，
        // 需要用 as_type<int4>(uintIn[t0]) 做无符号 bitcast。
        // E-006b7: 扩展检测到 load 类型与指针元素类型大小不同时也需要重解释。
        let ptrElemType = ctx.pointerElementTypes[ptrSSAName] ?? ctx.pointerElementTypes[ptrOperand]
        if let elemType = ptrElemType {
            if needsSignednessBitcast(mslType, ptrElemType: elemType) {
                ctx.emitAutoAssign(lhs, expr: "as_type<\(mslType)>(\(loadExpr))", knownType: mslType)
            } else if needsSizeBitcast(mslType, ptrElemType: elemType) {
                let loadBits = mslTypeBitWidth(mslType)
                let ptrBits = mslTypeBitWidth(elemType)
                if loadBits <= 32 && ptrBits > loadBits {
                    // 标量或小向量从更大向量加载：as_type 取前 32bit 再截取
                    if mslType == "float" || mslType == "int" || mslType == "uint" {
                        // 标量：取 .x 分量（float4[0] → .x）
                        ctx.emitAutoAssign(lhs, expr: "\(loadExpr).x", knownType: mslType)
                    } else if mslType == "half" {
                        ctx.emitAutoAssign(lhs, expr: "as_type<half>(as_type<uint>(\(loadExpr).x) & 0xFFFF)", knownType: mslType)
                    } else {
                        // 小向量（uchar2 等）：通过 uint 中间 bitcast 截取
                        // float → uint (as_type, same 32-bit size) → mask → downcast → as_type
                        // Metal 的 as_type 要求源和目标大小相同，所以中间步骤必须用 uint (32-bit)
                        let intBits = loadBits <= 16 ? 16 : 32
                        let mask: String
                        if intBits == 16 {
                            mask = "0xFFFF"
                        } else {
                            mask = "0xFFFFFFFF"
                        }
                        // 始终用 uint 做中间 bitcast（float → uint 是合法的 same-size as_type）
                        let tempUInt = ctx.freshTemp()
                        ctx.emit("uint \(tempUInt) = as_type<uint>(\(loadExpr).x) & \(mask);")
                        if intBits == 16 {
                            // 16-bit 目标：uint → ushort (显式截断) → as_type<uchar2>
                            let tempShort = ctx.freshTemp()
                            ctx.emit("ushort \(tempShort) = ushort(\(tempUInt));")
                            ctx.emitAutoAssign(lhs, expr: "as_type<\(mslType)>(\(tempShort))", knownType: mslType)
                        } else {
                            // 32-bit 目标：直接 as_type<uint> → as_type<目标类型>
                            ctx.emitAutoAssign(lhs, expr: "as_type<\(mslType)>(\(tempUInt))", knownType: mslType)
                        }
                    }
                } else {
                    // 其他大小不匹配的情况：用 reinterpret_cast 指针类型
                    let ptrTemp = ctx.freshTemp()
                    let addrSpace = inferAddressSpace(ptrOperand, ctx: ctx)
                    ctx.emit("auto \(ptrTemp) = reinterpret_cast<const \(addrSpace)\(mslType)*>(&(\(loadExpr)));")
                    ctx.emitAutoAssign(lhs, expr: "*\(ptrTemp)", knownType: mslType)
                }
            } else {
                ctx.emitAutoAssign(lhs, expr: loadExpr, knownType: mslType)
            }
        } else {
            ctx.emitAutoAssign(lhs, expr: loadExpr, knownType: mslType)
        }
    }

    /// 检测两个 MSL 类型是否在 signedness 上有差异（相同大小不同符号），
    /// 需要用 as_type<> bitcast 而非普通类型转换。
    /// 例如：int4 vs uint4, int2 vs uint2, short vs ushort, int vs uint
    private static func needsSignednessBitcast(_ loadMSLType: String, ptrElemType: String) -> Bool {
        // 提取基础类型名和维度
        let signedToUnsigned: [String: String] = [
            "int": "uint", "int2": "uint2", "int3": "uint3", "int4": "uint4",
            "short": "ushort", "short2": "ushort2", "short3": "ushort3", "short4": "ushort4",
            "long": "ulong", "long2": "ulong2", "long3": "ulong3", "long4": "ulong4",
            "char": "uint8_t",
        ]
        let unsignedToSigned: [String: String] = [
            "uint": "int", "uint2": "int2", "uint3": "int3", "uint4": "int4",
            "ushort": "short", "ushort2": "short2", "ushort3": "ushort3", "ushort4": "short4",
            "ulong": "long", "ulong2": "long2", "ulong3": "long3", "ulong4": "long4",
            "uint8_t": "char",
        ]
        if let equiv = signedToUnsigned[loadMSLType], equiv == ptrElemType { return true }
        if let equiv = unsignedToSigned[loadMSLType], equiv == ptrElemType { return true }
        // 向量维度不匹配的 signedness 差异（如 int4 vs uint2）不需要处理，类型完全不同
        return false
    }

    /// 检测两个 MSL 类型是否在大小（bit width）上不匹配，
    /// 需要 as_type<> 重解释而非直接赋值。
    /// 例如：uchar2 (2 bytes) vs float4 (16 bytes)、float (4 bytes) vs float4 (16 bytes)
    /// 当 load 的 IR 类型比指针元素类型更小时（如从 float4* 加载 uchar2），
    /// MSL 的 subscript 返回指针元素类型（float4），不能直接赋给 load 类型（uchar2）。
    private static func needsSizeBitcast(_ loadMSLType: String, ptrElemType: String) -> Bool {
        let loadBits = mslTypeBitWidth(loadMSLType)
        let ptrBits = mslTypeBitWidth(ptrElemType)
        guard loadBits > 0 && ptrBits > 0 else { return false }
        // 相同大小 → 不需要（signedness 由 needsSignednessBitcast 处理）
        if loadBits == ptrBits { return false }
        // 不同大小 → 需要 as_type 重解释
        // 但只处理 load 比 ptr 小的情况（截断式 bitcast），忽略 load 更大的情况（不太常见）
        return loadBits < ptrBits
    }

    /// 估算 MSL 类型的 bit width
    private static func mslTypeBitWidth(_ mslType: String) -> Int {
        let s = mslType.trimmingCharacters(in: .whitespaces)
        // 标量类型
        let scalarWidths: [String: Int] = [
            "char": 8, "uchar": 8, "uint8_t": 8,
            "short": 16, "ushort": 16,
            "int": 32, "uint": 32, "float": 32, "half": 16,
            "long": 64, "ulong": 64, "double": 64,
            "bool": 1,
        ]
        if let w = scalarWidths[s] { return w }
        // 向量类型：typeN（如 float4, uchar2, int3）
        // 提取末尾的维度数字
        var i = s.count
        while i > 0 && s[s.index(s.startIndex, offsetBy: i - 1)].isNumber { i -= 1 }
        if i < s.count && i > 0 {
            let base = String(s[s.startIndex..<s.index(s.startIndex, offsetBy: i)])
            if let dim = Int(s[s.index(s.startIndex, offsetBy: i)...]),
               let baseW = scalarWidths[base] {
                return baseW * dim
            }
        }
        return 0
    }

    /// 从 IR 操作数的地址空间推断 MSL 地址空间限定符。
    /// IR addrspace(1) → device, addrspace(2) → constant, addrspace(3) → threadgroup, 其他 → device
    private static func inferAddressSpace(_ irOperand: String, ctx: SSAContext) -> String {
        let trimmed = irOperand.trimmingCharacters(in: .whitespaces)
        // 检查 SSA 变量的参数类型（可能包含 addrspace 信息）
        if trimmed.hasPrefix("%") {
            if let paramType = ctx.paramTypes[trimmed] {
                if paramType.contains("addrspace(2)") { return "constant" }
                if paramType.contains("addrspace(3)") { return "threadgroup" }
            }
            // 回退：检查 SSA 表达式是否包含 constant 关键字
            let resolved = ctx.resolve(trimmed)
            if resolved.contains("constant") { return "constant" }
            if resolved.contains("threadgroup") { return "threadgroup" }
        }
        return "device"
    }

    /// 翻译 store
    private static func translateStore(_ line: String, ctx: SSAContext) {
        // store <type> <value>, <ptr_type> <ptr>[, align N]
        let cleaned = line.replacingOccurrences(of: "store ", with: "")
            .trimmingCharacters(in: .whitespaces)
        let parts = splitTypedOperands(cleaned, count: 2)
        guard parts.count >= 2 else {
            ctx.emit("// [store parse error] \(line.prefix(80))")
            return
        }
        let valOperand = parts[0].value.trimmingCharacters(in: .whitespaces)
        let ptrOperand = parts[1].value.trimmingCharacters(in: .whitespaces)
        let val = resolveIROperand(valOperand, ctx: ctx)
        let ptr = resolveIROperand(ptrOperand, ctx: ctx)
        let targetExpr = lvalueExpression(from: ptr) ?? "*(\(ptr))"
        // E-006b5: 检测值类型与指针元素类型之间的 signedness mismatch。
        // LLVM IR 的 i32 无 signedness，MSL 的 int4/uint4 是不同类型。
        // 当 store int4 值到 device uint4* 时，需要 as_type<uint4>(val)。
        let ptrSSAName = extractSSAName(from: ptrOperand)
        let ptrElemType = ctx.pointerElementTypes[ptrSSAName] ?? ctx.pointerElementTypes[ptrOperand]
        if let elemType = ptrElemType,
           let valMSLType = ctx.types[valOperand],
           needsSignednessBitcast(valMSLType, ptrElemType: elemType) {
            ctx.emit("\(targetExpr) = as_type<\(elemType)>(\(val));")
        } else {
            ctx.emit("\(targetExpr) = \(val);")
        }
    }

    /// 翻译 getelementptr (E-004e4c)
    ///
    /// IR 模式:
    /// - `getelementptr inbounds %struct.Particle, ptr addrspace(1) %0, i64 %4, i32 0`
    ///   → `&particles[tid].position`  （数组元素 + 结构体字段）
    /// - `getelementptr inbounds %struct.Uniforms, ptr addrspace(2) %2, i64 0, i32 0, i32 0, i64 0`
    ///   → `&uniforms.modelViewProjection.columns[0]`  （嵌套结构体 + 数组访问）
    /// - `getelementptr inbounds <4 x float>, ptr addrspace(1) %0, i64 %5`
    ///   → `&positions[vid]`  （简单数组索引）
    ///
    /// 策略:
    /// GEP 的第一个索引是基指针的偏移（数组索引），后续索引按类型层级解析：
    /// - 对结构体类型，索引是字段编号（常量 i32）→ 查找字段名
    /// - 对数组类型，索引是元素下标（可以是变量）→ 生成 `[idx]`
    private static func translateGEP(lhs: String, rhs: String, ctx: SSAContext) {
        // getelementptr [inbounds] <type>, <ptr_type> <ptr>, <idx_type> <idx>[, ...]
        var cleaned = rhs.replacingOccurrences(of: "getelementptr ", with: "")
            .trimmingCharacters(in: .whitespaces)
        if cleaned.hasPrefix("inbounds ") {
            cleaned = String(cleaned.dropFirst("inbounds ".count))
        }

        let parts = splitTypedOperands(cleaned, count: 10)
        guard parts.count >= 2 else {
            ctx.define(lhs, expr: "/* GEP error */")
            return
        }

        let pointeeType = parts[0].type.trimmingCharacters(in: .whitespaces)
        let baseOperand = parts[1].value.trimmingCharacters(in: .whitespaces)
        let basePtr = resolveIROperand(baseOperand, ctx: ctx)
        let baseTarget = stripAddressOfExpression(basePtr) ?? basePtr
        let baseIsPointerLike = ctx.isPointerLike(baseOperand) || stripAddressOfExpression(basePtr) != nil

        if parts.count == 2 {
            // 无索引，直接透传
            ctx.define(lhs, expr: basePtr)
            if baseIsPointerLike {
                ctx.markPointer(lhs, elementType: ctx.pointerElementTypes[baseOperand.trimmingCharacters(in: .whitespaces)] ?? "")
            }
            return
        }

        if parts.count == 3 {
            // 简单数组索引: ptr + idx
            let idx = resolveIROperand(parts[2].value, ctx: ctx)
            if idx == "0" {
                ctx.define(lhs, expr: basePtr)
            } else {
                ctx.define(lhs, expr: addressExpression(for: "\(baseTarget)[\(idx)]"))
            }
            ctx.markPointer(lhs, elementType: ctx.pointerElementTypes[baseOperand.trimmingCharacters(in: .whitespaces)] ?? "")
            return
        }

        // 多级索引：parts[2] 是基指针偏移（数组索引），parts[3..] 是类型层级索引
        let firstIdx = resolveIROperand(parts[2].value, ctx: ctx)

        // E-006b9: metal::_atomic GEP 的特殊处理
        // IR: getelementptr %"struct.metal::_atomic", ptr %0, i64 0, i32 0
        // MSL: counter 是 device atomic_int& 引用，直接透传不加 [0] 或 .field0
        let isAtomicGEP = pointeeType.contains("metal::_atomic")

        // 构建表达式。对真正的指针参数先落到合法的下标/解引用语义；
        // 对 constant struct 引用等"值语义入口"则保留原表达式，避免误发射 `ptr.field`。
        var expr: String
        if isAtomicGEP {
            // atomic 类型是引用，不需要下标访问
            expr = baseTarget
        } else if baseIsPointerLike {
            if stripAddressOfExpression(basePtr) != nil {
                expr = baseTarget
                if firstIdx != "0" {
                    expr = "\(expr)[\(firstIdx)]"
                }
            } else {
                expr = "\(baseTarget)[\(firstIdx)]"
            }
        } else {
            expr = baseTarget
            if firstIdx != "0" {
                expr = "\(expr)[\(firstIdx)]"
            }
        }

        // 从第二个索引开始，遍历类型层级
        var currentType = pointeeType

        for i in 3..<parts.count {
            let idxStr = parts[i].value.trimmingCharacters(in: .whitespaces)

            // 判断当前类型层级
            if currentType.hasPrefix("%") {
                // E-006b9: metal::_atomic 是 MSL 内建 atomic 类型的 IR 表示
                // GEP field0 取的是内部 __s 字段指针，但 MSL 中 atomic 变量本身就是原子操作的目标
                // 因此直接透传指针，不加 .field0 / .__s 后缀
                if (currentType.contains("metal::_atomic") || currentType.contains("metal::_atomic.25")) {
                    if let fieldIdx = Int(idxStr), fieldIdx == 0 {
                        // 直接透传 expr，不加任何字段访问
                        if let def = ctx.structTypeDefs[currentType],
                           fieldIdx < def.fieldIRTypes.count {
                            currentType = def.fieldIRTypes[fieldIdx].trimmingCharacters(in: .whitespaces)
                        } else {
                            currentType = ""
                        }
                        continue
                    }
                }

                // 结构体类型 → 字段访问
                if let fieldIdx = Int(idxStr) {
                    if let fieldName = ctx.lookupFieldName(irStructType: currentType, fieldIndex: fieldIdx) {
                        expr = "\(expr).\(fieldName)"
                    } else if let def = ctx.structTypeDefs[currentType],
                              fieldIdx < def.fieldIRTypes.count {
                        // 单字段 wrapper（如 `%\"struct.metal::matrix\" = type { [4 x <4 x float>] }`）
                        // 访问 field0 时直接透传到内部字段，避免继续构造 `%0.field0[...]` 这类坏路径。
                        if !(def.fieldIRTypes.count == 1 && fieldIdx == 0) {
                            expr = "\(expr).field\(fieldIdx)"
                        }
                    } else {
                        expr = "\(expr).field\(fieldIdx)"
                    }
                    // 更新 currentType 为字段的 IR 类型
                    if let def = ctx.structTypeDefs[currentType],
                       fieldIdx < def.fieldIRTypes.count {
                        currentType = def.fieldIRTypes[fieldIdx].trimmingCharacters(in: .whitespaces)
                    } else {
                        currentType = ""
                    }
                } else {
                    // 非常量索引用于结构体（不应该出现，但防御性处理）
                    let resolvedIdx = resolveIROperand(idxStr, ctx: ctx)
                    expr = "\(expr)[\(resolvedIdx)]"
                    currentType = ""
                }
            } else if currentType.hasPrefix("[") {
                // 数组类型 [N x T] → 索引访问
                let resolvedIdx = resolveIROperand(idxStr, ctx: ctx)
                expr = "\(expr)[\(resolvedIdx)]"
                // 提取数组元素类型: "[4 x <4 x float>]" → "<4 x float>"
                if let xRange = currentType.range(of: " x ") {
                    let afterX = currentType[xRange.upperBound...]
                    if let closeBracket = afterX.lastIndex(of: "]") {
                        currentType = String(afterX[afterX.startIndex..<closeBracket])
                            .trimmingCharacters(in: .whitespaces)
                    } else {
                        currentType = ""
                    }
                } else {
                    currentType = ""
                }
            } else {
                // 其他类型（向量、标量、ptr 等）→ 通用索引
                let resolvedIdx = resolveIROperand(idxStr, ctx: ctx)
                if resolvedIdx == "0" && i == parts.count - 1 {
                    // 最后一个索引为 0，通常是无效访问，透传
                } else if currentType.hasPrefix("<") {
                    // E-006b7: IR 向量类型 <N x T> 的 GEP subscript。
                    // GEP 语义是把向量内存视为元素数组做指针 subscript，
                    // 但 expr[field] 对向量值是 component access（返回标量），语义不等价。
                    // 必须先取地址再用指针 subscript：auto tmp = &(expr); tmp[idx]
                    // 保留 currentType（向量元素类型）用于 gepElementType 追踪。
                    let ptrTemp = ctx.freshTemp()
                    ctx.emit("auto \(ptrTemp) = &(\(expr));")
                    var offsetExpr = resolvedIdx
                    var j = i + 1
                    while j < parts.count {
                        let nextIdxStr = parts[j].value.trimmingCharacters(in: .whitespaces)
                        let nextIdx = resolveIROperand(nextIdxStr, ctx: ctx)
                        if !nextIdx.isEmpty && nextIdx != "0" {
                            offsetExpr += " + \(nextIdx)"
                        }
                        j += 1
                    }
                    expr = "\(ptrTemp)[\(offsetExpr)]"
                    // currentType 保持为向量类型（<N x T>），不置空
                    break
                } else if !currentType.isEmpty && !currentType.hasPrefix("ptr") {
                    // E-006a2e14: 标量类型 subscript（float, half, i32 等）
                    // 也处理 MSL 向量类型（float4, uchar2 等）
                    let ptrTemp = ctx.freshTemp()
                    ctx.emit("auto \(ptrTemp) = &(\(expr));")
                    var offsetExpr = resolvedIdx
                    var j = i + 1
                    while j < parts.count {
                        let nextIdxStr = parts[j].value.trimmingCharacters(in: .whitespaces)
                        let nextIdx = resolveIROperand(nextIdxStr, ctx: ctx)
                        if !nextIdx.isEmpty && nextIdx != "0" {
                            offsetExpr += " + \(nextIdx)"
                        }
                        j += 1
                    }
                    expr = "\(ptrTemp)[\(offsetExpr)]"
                    break
                } else {
                    expr = "\(expr)[\(resolvedIdx)]"
                }
                currentType = ""
            }
        }

        ctx.define(lhs, expr: addressExpression(for: expr))
        // 多级 GEP 的元素类型由 currentType 决定；若 currentType 为空则回退到 base 的类型
        let gepElementType = currentType.isEmpty
            ? (ctx.pointerElementTypes[baseOperand.trimmingCharacters(in: .whitespaces)] ?? "")
            : irScalarTypeToMSL(currentType)
        ctx.markPointer(lhs, elementType: gepElementType)
    }

    /// 翻译类型转换: zext/sext/trunc/fpext/fptrunc/uitofp/sitofp/fptoui/fptosi
    private static func translateIntCast(lhs: String, rhs: String, opcode: String, ctx: SSAContext) {
        // <opcode> <src_type> <val> to <dst_type>
        let cleaned = rhs.replacingOccurrences(of: "\(opcode) ", with: "")
        guard let toRange = cleaned.range(of: " to ") else {
            ctx.define(lhs, expr: "/* cast error */")
            return
        }
        let srcPart = String(cleaned[cleaned.startIndex..<toRange.lowerBound])
        let dstType = String(cleaned[toRange.upperBound...]).trimmingCharacters(in: .whitespaces)

        let srcParts = splitTypedOperands(srcPart, count: 1)
        let srcVal = srcParts.isEmpty ? "0" : resolveIROperand(srcParts[0].value, ctx: ctx)

        let mslDstType: String
        switch opcode {
        case "fptoui":
            mslDstType = irIntegerTypeToMSL(dstType, signed: false)
        case "fptosi":
            mslDstType = irIntegerTypeToMSL(dstType, signed: true)
        case "zext":
            mslDstType = irIntegerTypeToMSL(dstType, signed: false)
        case "sext":
            mslDstType = irIntegerTypeToMSL(dstType, signed: true)
        default:
            mslDstType = irScalarTypeToMSL(dstType)
        }

        ctx.emitAutoAssign(lhs, expr: "\(mslDstType)(\(srcVal))", knownType: mslDstType)
    }

    /// 将 IR 整数类型映射到带符号性语义的 MSL 类型。
    ///
    /// 注意：MSL 不支持 `uint8_tN` 等向量类型别名（如 `uint8_t2`），
    /// 无符号 8-bit 整数向量必须使用 `ucharN`（即 `vector<uint8_t, N>`）。
    private static func irIntegerTypeToMSL(_ irType: String, signed: Bool) -> String {
        let cleaned = irType.trimmingCharacters(in: .whitespaces)

        switch cleaned {
        case "i1":
            return "bool"
        case "i8":
            return signed ? "char" : "uint8_t"
        case "i16":
            return signed ? "short" : "ushort"
        case "i32":
            return signed ? "int" : "uint"
        case "i64":
            return signed ? "long" : "ulong"
        default:
            if cleaned.hasPrefix("<") && cleaned.hasSuffix(">") && cleaned.contains(" x ") {
                let inner = String(cleaned.dropFirst().dropLast())
                let parts = inner.components(separatedBy: " x ")
                if parts.count >= 2 {
                    let count = parts[0].trimmingCharacters(in: .whitespaces)
                    let elemType = parts.dropFirst().joined(separator: " x ").trimmingCharacters(in: .whitespaces)
                    // i8 向量：MSL 不支持 uint8_tN，必须用 ucharN
                    if elemType == "i8" {
                        return "uchar\(count)"
                    }
                    let elemMSLType = irIntegerTypeToMSL(elemType, signed: signed)
                    return "\(elemMSLType)\(count)"
                }
            }
            return irScalarTypeToMSL(cleaned)
        }
    }

    /// 翻译 bitcast
    private static func translateBitcast(lhs: String, rhs: String, ctx: SSAContext) {
        let cleaned = rhs.replacingOccurrences(of: "bitcast ", with: "")
        guard let toRange = cleaned.range(of: " to ") else {
            ctx.define(lhs, expr: "/* bitcast error */")
            return
        }
        let srcPart = String(cleaned[cleaned.startIndex..<toRange.lowerBound])
        let dstType = String(cleaned[toRange.upperBound...]).trimmingCharacters(in: .whitespaces)

        let srcParts = splitTypedOperands(srcPart, count: 1)
        let srcVal = srcParts.isEmpty ? "0" : resolveIROperand(srcParts[0].value, ctx: ctx)

        // E-006b9: ptr to ptr bitcast 是 no-op（MSL 中 thread 空间指针类型兼容）
        if dstType == "ptr" && (srcParts.first?.type == "ptr" || srcParts.first?.type.contains("ptr") == true) {
            ctx.define(lhs, expr: srcVal)
            ctx.markPointer(lhs)
            return
        }

        let mslDstType = irScalarTypeToMSL(dstType)
        ctx.emitAutoAssign(lhs, expr: "as_type<\(mslDstType)>(\(srcVal))", knownType: mslDstType)
    }

    /// 翻译 freeze（LLVM poison → 确定值，MSL 中直接透传）
    private static func translateFreeze(lhs: String, rhs: String, ctx: SSAContext) {
        let cleaned = rhs.replacingOccurrences(of: "freeze ", with: "")
        let parts = splitTypedOperands(cleaned, count: 1)
        if let first = parts.first {
            let val = resolveIROperand(first.value, ctx: ctx)
            ctx.define(lhs, expr: val)
        } else {
            ctx.define(lhs, expr: "/* freeze error */")
        }
    }

    /// 翻译 call/tail call（包括 air.*、___metal_* 和普通函数）
    private static func translateCall(lhs: String, rhs: String, ctx: SSAContext) {
        // 检查是否是 air.* 调用
        if rhs.contains("@air.") {
            translateAirCall(lhs: lhs, fullRhs: rhs, ctx: ctx)
            return
        }
        // E-006a2e10: 检查是否是 ___metal_* 内联 intrinsic
        // LLVM Metal 编译器会将部分标准库函数内联为 @___metal_fract_v2float 等形式
        if rhs.contains("@___metal_") {
            translateMetalIntrinsic(lhs: lhs, fullRhs: rhs, ctx: ctx)
            return
        }
        // llvm.* 大多是 IR 级 intrinsic，不应直接发射为普通 MSL 调用。
        if rhs.contains("@llvm.") {
            ctx.define(lhs, expr: "/* call: \(rhs.prefix(80)) */")
            return
        }
        translateRegularCall(lhs: lhs, fullRhs: rhs, ctx: ctx)
    }

    /// 翻译普通函数调用（helper / internal 函数）。
    ///
    /// 这类调用通常已经在同一份生成源码里有对应函数定义，
    /// 例如 `@_Z13_target_floorf`、`@_Z11_target_minff`、`@_ZN11_fract_impl...`。
    /// 直接降成 `callee(args...)` 即可，不能再退回到注释占位符，否则会把 LLVM 语法泄漏进 MSL。
    private static func translateRegularCall(lhs: String, fullRhs: String, ctx: SSAContext) {
        guard let atIndex = fullRhs.firstIndex(of: "@") else {
            ctx.define(lhs, expr: "/* call: \(fullRhs.prefix(80)) */")
            return
        }

        let afterAt = fullRhs[fullRhs.index(after: atIndex)...]
        guard let parenIdx = afterAt.firstIndex(of: "(") else {
            ctx.define(lhs, expr: "/* call: \(fullRhs.prefix(80)) */")
            return
        }

        let rawName = String(afterAt[afterAt.startIndex..<parenIdx]).replacingOccurrences(of: "\"", with: "")
        let calleeName = sanitizeIdentifier(rawName, fallback: "callTarget", uppercaseFirst: false)

        let argsStart = afterAt.index(after: parenIdx)
        var depth = 1
        var cursor = argsStart
        while cursor < afterAt.endIndex && depth > 0 {
            if afterAt[cursor] == "(" { depth += 1 }
            else if afterAt[cursor] == ")" { depth -= 1 }
            if depth > 0 { cursor = afterAt.index(after: cursor) }
        }

        let argsStr = String(afterAt[argsStart..<cursor])
        let argParts = splitTypedOperands(argsStr, count: 20)
        let resolvedArgs = argParts.map { resolveIROperand($0.value, ctx: ctx) }
        ctx.emitAutoAssign(lhs, expr: "\(calleeName)(\(resolvedArgs.joined(separator: ", ")))")
    }

    /// 已知的 ___metal_* intrinsic 映射到 MSL 函数名
    /// 命名规则：___metal_<msl_name>[_<type_suffix>]
    /// 例如：___metal_fract_v2float → fract(), ___metal_fast_sin_v4f32 → sin()
    /// mslArgCount: MSL 函数期望的参数数量（IR intrinsic 可能有额外元数据参数）
    ///
    /// E-006b4: fast_* 变体统一映射到同名标准 MSL 函数（去掉 fast_ 前缀），
    /// 与 air.fast_* 映射行为保持一致。Metal 标准库不提供 fast_sin 等
    /// 无前缀函数，fast-math 语义由编译选项（-ffast-math）控制，
    /// 不应体现在函数名中。
    private static let metalIntrinsicMappings: [(pattern: String, mslFunc: String, mslArgCount: Int)] = {
        var list: [(String, String, Int)] = []
        let unaryMath = [
            "fract", "sin", "cos", "tan", "sqrt", "rsqrt",
            "exp", "exp2", "log", "log2", "floor", "ceil", "round", "trunc",
            "saturate", "sign", "asin", "acos", "atan",
            "sinh", "cosh", "tanh",
        ]
        for name in unaryMath {
            list.append(("___metal_\(name)", name, 1))
            // E-006b4: fast_* 变体映射到同名标准函数（与 air.fast_* 一致）
            list.append(("___metal_fast_\(name)", name, 1))
        }
        let binaryMath = [
            "fmin", "fmax", "pow", "fmod", "atan2", "copysign", "fdim", "step",
            "min", "max",
        ]
        for name in binaryMath {
            list.append(("___metal_\(name)", name, 2))
            list.append(("___metal_fast_\(name)", name, 2))
        }
        let ternaryMath = ["clamp", "mix", "smoothstep", "fma"]
        for name in ternaryMath {
            list.append(("___metal_\(name)", name, 3))
            list.append(("___metal_fast_\(name)", name, 3))
        }
        let unaryVec = ["length", "normalize"]
        for name in unaryVec {
            list.append(("___metal_\(name)", name, 1))
            list.append(("___metal_fast_\(name)", name, 1))
        }
        let binaryVec = ["dot", "cross", "distance", "reflect"]
        for name in binaryVec {
            list.append(("___metal_\(name)", name, 2))
            list.append(("___metal_fast_\(name)", name, 2))
        }
        let ternaryVec = ["refract", "faceforward"]
        for name in ternaryVec {
            list.append(("___metal_\(name)", name, 3))
            list.append(("___metal_fast_\(name)", name, 3))
        }
        list.append(("___metal_abs", "abs", 1))
        list.append(("___metal_fabs", "abs", 1))
        return list
    }()

    /// 翻译 ___metal_* 内联 intrinsic 调用
    /// 从函数名提取 MSL 函数名（去掉类型后缀），解析参数后生成直接 MSL 调用
    private static func translateMetalIntrinsic(lhs: String, fullRhs: String, ctx: SSAContext) {
        // 提取 @___metal_ 后的函数名（到 ( 为止）
        guard let atRange = fullRhs.range(of: "@___metal_") else {
            ctx.define(lhs, expr: "/* metal intrinsic error */")
            return
        }
        let afterAt = fullRhs[fullRhs.index(after: atRange.lowerBound)...]
        guard let parenIdx = afterAt.firstIndex(of: "(") else {
            ctx.define(lhs, expr: "/* metal intrinsic error */")
            return
        }
        let fullName = String(afterAt[afterAt.startIndex..<parenIdx])

        // 从完整名称（含类型后缀）查找 MSL 函数名和期望参数数
        // 例如：fract_v2float → fract(1), fast_sin_v4f32 → sin(1)
        let mapping = lookupMetalIntrinsic(fullName)
        let mslFunc: String
        let mslArgCount: Int
        if let m = mapping {
            mslFunc = m.mslFunc
            mslArgCount = m.mslArgCount
        } else {
            mslFunc = fullName
            mslArgCount = -1
        }

        // 提取参数列表
        let argsStart = afterAt.index(after: parenIdx)
        var depth = 1
        var cursor = argsStart
        while cursor < afterAt.endIndex && depth > 0 {
            if afterAt[cursor] == "(" { depth += 1 }
            else if afterAt[cursor] == ")" { depth -= 1 }
            if depth > 0 { cursor = afterAt.index(after: cursor) }
        }
        let argsStr = String(afterAt[argsStart..<cursor])
        let argParts = splitTypedOperands(argsStr, count: 20)
        let resolvedArgs = argParts.map { resolveIROperand($0.value, ctx: ctx) }

        // E-006a2e11: 仅传递 MSL 函数期望的参数数量
        // IR intrinsic 可能有额外元数据/标志参数（如 fract(x, 0) 的 i32 0）
        let filteredArgs: [String]
        if mslArgCount > 0 && resolvedArgs.count > mslArgCount {
            filteredArgs = Array(resolvedArgs.prefix(mslArgCount))
        } else {
            filteredArgs = resolvedArgs
        }

        ctx.emitAutoAssign(lhs, expr: "\(mslFunc)(\(filteredArgs.joined(separator: ", ")))")
    }

    /// 查找 ___metal_* intrinsic 对应的 MSL 函数名和期望参数数
    /// 支持：___metal_fract_v2float → (fract, 1), ___metal_fast_sin_v4f32 → (sin, 1)
    private static func lookupMetalIntrinsic(_ fullName: String) -> (mslFunc: String, mslArgCount: Int)? {
        // 按模式长度降序匹配，避免 "fast_sin" 被 "sin" 先匹配
        let sorted = metalIntrinsicMappings.sorted { $0.pattern.count > $1.pattern.count }
        for mapping in sorted {
            if fullName == mapping.pattern {
                return (mapping.mslFunc, mapping.mslArgCount)
            }
            if fullName.hasPrefix(mapping.pattern + "_") {
                return (mapping.mslFunc, mapping.mslArgCount)
            }
        }
        return nil
    }

    /// 翻译 air.* 内建调用
    private static func translateAirCall(lhs: String, fullRhs: String, ctx: SSAContext) {
        // 提取 air 函数名
        guard let atRange = fullRhs.range(of: "@air.") else {
            ctx.define(lhs, expr: "/* air call error */")
            return
        }
        let afterAt = fullRhs[fullRhs.index(after: atRange.lowerBound)...]
        guard let parenIdx = afterAt.firstIndex(of: "(") else {
            ctx.define(lhs, expr: "/* air call error */")
            return
        }
        let airName = String(afterAt[afterAt.startIndex..<parenIdx])

        // 提取参数列表
        let argsStart = afterAt.index(after: parenIdx)
        var depth = 1
        var cursor = argsStart
        while cursor < afterAt.endIndex && depth > 0 {
            if afterAt[cursor] == "(" { depth += 1 }
            else if afterAt[cursor] == ")" { depth -= 1 }
            if depth > 0 { cursor = afterAt.index(after: cursor) }
        }
        let argsStr = String(afterAt[argsStart..<cursor])
        let argParts = splitTypedOperands(argsStr, count: 20)
        let resolvedArgs = argParts.map { resolveIROperand($0.value, ctx: ctx) }

        // 查找映射
        let mapping = lookupAirBuiltin(airName)

        if let m = mapping {
            let mslExpr = generateMSLForAirCall(
                mapping: m,
                airName: airName,
                args: resolvedArgs,
                argTypes: argParts.map { $0.type }
            )
            ctx.emitAutoAssign(lhs, expr: mslExpr)
        } else {
            // 未映射的 air 调用
            let argList = resolvedArgs.prefix(4).joined(separator: ", ")
            ctx.emitAutoAssign(lhs, expr: "/* \(airName)(\(argList)) */")
        }
    }

    /// 翻译 void 返回的 air.* 调用（如 barrier、write_texture）
    private static func translateVoidAirCall(_ line: String, ctx: SSAContext) {
        guard let atRange = line.range(of: "@air.") else {
            ctx.emit("// [void air call error] \(line.prefix(80))")
            return
        }
        let afterAt = line[line.index(after: atRange.lowerBound)...]
        guard let parenIdx = afterAt.firstIndex(of: "(") else { return }
        let airName = String(afterAt[afterAt.startIndex..<parenIdx])

        let argsStart = afterAt.index(after: parenIdx)
        var depth = 1
        var cursor = argsStart
        while cursor < afterAt.endIndex && depth > 0 {
            if afterAt[cursor] == "(" { depth += 1 }
            else if afterAt[cursor] == ")" { depth -= 1 }
            if depth > 0 { cursor = afterAt.index(after: cursor) }
        }
        let argsStr = String(afterAt[argsStart..<cursor])
        let argParts = splitTypedOperands(argsStr, count: 20)
        let resolvedArgs = argParts.map { resolveIROperand($0.value, ctx: ctx) }

        let mapping = lookupAirBuiltin(airName)
        if let m = mapping {
            let mslExpr = generateMSLForAirCall(
                mapping: m, airName: airName,
                args: resolvedArgs, argTypes: argParts.map { $0.type }
            )
            ctx.emit("\(mslExpr);")
        } else {
            let argList = resolvedArgs.prefix(4).joined(separator: ", ")
            ctx.emit("/* \(airName)(\(argList)) */;")
        }
    }

    /// 根据 air→MSL 映射生成 MSL 表达式
    private static func generateMSLForAirCall(
        mapping: AirBuiltinMapping,
        airName: String,
        args: [String],
        argTypes: [String]
    ) -> String {
        // 特殊处理: air.convert
        if airName.hasPrefix("air.convert") {
            let srcArg = args.first ?? "0"
            return generateAirConvertMSL(airName: airName, srcArg: srcArg)
        }

        // 纹理方法调用: tex.sample(sampler, coord, ...)
        if mapping.isMethodCall {
            if args.count >= 2 {
                let obj = args[0]
                let methodArgs = Array(args.dropFirst())
                let methodArgTypes = Array(argTypes.dropFirst())

                if mapping.mslFunction == "gather" {
                    return generateTextureGatherMSL(texture: obj, methodArgs: methodArgs, methodArgTypes: methodArgTypes)
                }

                let filtered = filterTextureArgs(methodArgs, argTypes: methodArgTypes, airName: airName)
                var finalArgs = filtered.args

                // E-006a2e8 → E-006a2e13: sample / sample_compare 的 bias/level float 需包装为选项结构
                // Metal 的 sample/sample_compare 都有 bias/level/min_lod_clamp 重载接受 float 参数，
                // 裸传 float 会导致 ambiguous。Air IR 中通过 i1 标志区分：i1 false → bias, i1 true → level(显式LOD)
                //
                // 参数结构（去掉 texture 后）:
                //   air.sample_texture_*:     [sampler, [i32,] coord, [i1_offset, offset,] [i1_bias/level, float_bias/level, float_min_lod, i32]]
                //   air.sample_compare_depth_2d: [sampler, [i32,] coord, float compare_value, [i1_offset, <2xi32>,] [i1_bias/level, float_bias/level, float_min_lod, i32]]
                // 对 sample_compare，compare_value 在 coord 之后，不能被误当作 bias/level 消费
                if (mapping.mslFunction == "sample" || mapping.mslFunction == "sample_compare") && !finalArgs.isEmpty {
                    let lastType = filtered.types.last ?? ""
                    if lastType == "float" || lastType == "half" {
                        // 查找 LOD/bias 标志：原始参数中 i1 紧接 float/half 的位置
                        var useLevel = false
                        var biasLevelArgIdx = -1  // bias/level float 在 methodArgs 中的索引
                        for i in 0..<(methodArgTypes.count - 1) {
                            if methodArgTypes[i] == "i1" &&
                               (methodArgTypes[i + 1] == "float" || methodArgTypes[i + 1] == "half") {
                                if methodArgs[i] == "true" { useLevel = true }
                                biasLevelArgIdx = i + 1
                                break
                            }
                        }
                        if biasLevelArgIdx >= 0 && biasLevelArgIdx < methodArgs.count {
                            let biasLevelVal = methodArgs[biasLevelArgIdx]
                            let biasLevelType = methodArgTypes[biasLevelArgIdx]
                            // 检查 bias/level 的 float 值是否被 filterTextureArgs 过滤掉（零值 float 会被过滤）
                            let isZeroFloat = (biasLevelType == "float" || biasLevelType == "half") &&
                                (biasLevelVal == "0.0" || biasLevelVal == "0.000000e+00")
                            let isFilteredByEmpty = biasLevelVal.isEmpty
                            if isZeroFloat || isFilteredByEmpty {
                                // bias/level 值已被 filterTextureArgs 过滤，不需要包装。
                                // finalArgs 末尾的 float 是 compare_value（sample_compare）或 coord 相关，保留原样
                            } else {
                                // bias/level 值被 filterTextureArgs 保留 → 它出现在 finalArgs 尾部
                                if finalArgs.count >= 2 {
                                    let val = finalArgs.removeLast()
                                    finalArgs.append(useLevel ? "level(\(val))" : "bias(\(val))")
                                }
                            }
                        }
                    }
                }

                // E-006b7: sample_texture_*_grad 的 gradient 参数需要包裹为 gradient2d(dx, dy)
                // Metal 的 sample(gradient2d(float2, float2)) 需要显式包装，
                // 否则裸传两个 float2 会被误解析为 bias/level 等重载导致 ambiguous。
                // 注意：gradient 参数可能是 SSA 变量（float2）或 splat 展开的裸 float 字面量，
                // 后者需要包装为 float2。
                if airName.contains("_grad") && mapping.mslFunction == "sample" {
                    // gradient 参数位于 coord 之后：最终参数中 [sampler, coord, gradX, gradY, ...]
                    // sampler 是 finalArgs[0], coord 是 finalArgs[1], gradX 是 finalArgs[2], gradY 是 finalArgs[3]
                    if finalArgs.count >= 4 {
                        var gradX = finalArgs.remove(at: 2)
                        var gradY = finalArgs.remove(at: 2)  // removeAt(2) again after first removal
                        // 如果 gradient 值是裸 float 字面量（来自 splat 展开），包装为 float2
                        if isFloatLiteral(gradX) { gradX = "float2(\(gradX))" }
                        if isFloatLiteral(gradY) { gradY = "float2(\(gradY))" }
                        finalArgs.insert("gradient2d(\(gradX), \(gradY))", at: 2)
                    }
                }

                // read: AIR 使用有符号整型坐标（常见为 <2 x i32> / <3 x i32>），
                // 但 Metal 的 texture.read(...) 需要 uintN / ushortN 坐标。
                // 若直接输出 intN，会触发 `no matching member function for call to 'read'`。
                if mapping.mslFunction == "read", !finalArgs.isEmpty, let coordType = filtered.types.first {
                    finalArgs[0] = normalizeTextureReadCoordinate(finalArgs[0], irType: coordType)
                }

                // write: AIR 参数顺序是 (texture, coord, color, ...)，
                // Metal 的 write 方法签名是 write(color, coord)，需要交换前两个参数
                if mapping.mslFunction == "write" && finalArgs.count >= 2 {
                    let a = finalArgs[0]
                    let b = finalArgs[1]
                    finalArgs[0] = b
                    finalArgs[1] = a
                    // E-006b8: 坐标参数来自 zeroinitializer 时被 resolveIROperand 解析为裸 "0"，
                    // Metal 的 write(color, coord) 需要 uint2 类型坐标，裸 0 会导致 ambiguous。
                    // 根据类型信息包装为正确的向量类型。
                    if let coordType = filtered.types.first {
                        if finalArgs[1] == "0" && coordType.contains("x i32") {
                            finalArgs[1] = "uint2(0)"
                        }
                    }
                }

                return "\(obj).\(mapping.mslFunction)(\(finalArgs.joined(separator: ", ")))"
            }
            return "\(mapping.mslFunction)(/* args */)"
        }

        // barrier 特殊处理
        if mapping.mslFunction == "threadgroup_barrier" || mapping.mslFunction == "simdgroup_barrier" {
            let flags = args.first ?? "0"
            let flagStr = barrierFlagsToMSL(flags)
            return "\(mapping.mslFunction)(\(flagStr))"
        }

        // E-006b9: atomic 操作特殊处理
        // AIR 原子函数参数格式: (ptr, val, order, scope, volatile)
        // MSL 只需: (obj, val, order) 或 (obj, order) 或 (obj, expected, desired, succ_order, fail_order)
        // 需要过滤掉 scope (i32 2=agent) 和 volatile (i1 true) 参数
        if mapping.category == .atomic {
            return generateAtomicMSL(mapping: mapping, airName: airName, args: args, argTypes: argTypes)
        }

        // 普通函数调用
        let paramCount = mapping.paramCount > 0 ? mapping.paramCount : args.count
        var callArgs = Array(args.prefix(paramCount))
        let callArgTypes = Array(argTypes.prefix(paramCount))

        // E-006a2e4: intrinsic 类型歧义修复
        // 当首个参数是 half 类型（标量或向量）时，FP literal 参数应加 h 后缀
        // 以避免 Metal 的 half/float 重载歧义（如 clamp(half_var, 0.0, 1.0) → ambiguous）
        if (mapping.category == .math) && callArgs.count > 1 && !callArgTypes.isEmpty {
            let firstType = callArgTypes[0]
            let isHalfScalar = firstType == "half"
            let isHalfVector = firstType.contains(" x half")
            if isHalfScalar || isHalfVector {
                for i in 1..<callArgs.count {
                    callArgs[i] = appendHalfSuffixIfFPLiteral(callArgs[i])
                }
            }
        }

        return "\(mapping.mslFunction)(\(callArgs.joined(separator: ", ")))"
    }

    private static func generateTextureGatherMSL(
        texture: String,
        methodArgs: [String],
        methodArgTypes: [String]
    ) -> String {
        guard methodArgs.count >= 2 else {
            return "\(texture).gather(/* args */)"
        }

        let sampler = methodArgs[0]
        let coord = methodArgs[1]
        var offsetExpr: String?
        var componentExpr: String?

        for index in 2..<min(methodArgs.count, methodArgTypes.count) {
            let arg = methodArgs[index]
            let type = methodArgTypes[index]

            if offsetExpr == nil && type.contains("x i32") && arg != "0" && !arg.isEmpty {
                offsetExpr = arg
                continue
            }

            if componentExpr == nil && type == "i32", let componentIndex = Int(arg), (0...3).contains(componentIndex) {
                let componentNames = ["x", "y", "z", "w"]
                if componentIndex != 0 {
                    componentExpr = "component::\(componentNames[componentIndex])"
                }
            }
        }

        var callArgs = [sampler, coord]
        if let offsetExpr {
            callArgs.append(offsetExpr)
        }
        if let componentExpr {
            if offsetExpr == nil {
                callArgs.append("int2(0)")
            }
            callArgs.append(componentExpr)
        }

        return "\(texture).gather(\(callArgs.joined(separator: ", ")))"
    }

    private static func normalizeTextureReadCoordinate(_ expr: String, irType: String) -> String {
        let trimmedType = irType.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedType.isEmpty, !expr.isEmpty else { return expr }

        if trimmedType == "i32" {
            return "uint(\(expr))"
        }
        if trimmedType == "i16" {
            return "ushort(\(expr))"
        }
        if trimmedType.contains("x i32") {
            let dim = max(extractVectorDim(trimmedType), 2)
            return "uint\(dim)(\(expr))"
        }
        if trimmedType.contains("x i16") {
            let dim = max(extractVectorDim(trimmedType), 2)
            return "ushort\(dim)(\(expr))"
        }

        return expr
    }

    /// 翻译 phi 节点（E-004e4b）
    ///
    /// phi 的值在 prescanPhiAndCFG 中已经预声明变量并注册到 ctx.phiVarNames。
    /// 实际赋值在 translateBr 中，在前驱 BB 的分支处插入。
    /// 这里只需确保 SSA 映射指向预声明的变量名。
    private static func translatePhi(lhs: String, rhs: String, ctx: SSAContext) {
        // 预扫描已处理：ctx.define(lhs, expr: phiVarName)
        // 如果预扫描漏了（不应该发生），做 fallback
        if ctx.phiVarNames[lhs] == nil {
            // Fallback: 简化处理，取第一个值
            let cleaned = rhs.replacingOccurrences(of: "phi ", with: "")
            if let bracketStart = cleaned.firstIndex(of: "["),
               let bracketEnd = cleaned.firstIndex(of: "]") {
                let inner = cleaned[cleaned.index(after: bracketStart)..<bracketEnd]
                let phiParts = inner.components(separatedBy: ",")
                if let firstVal = phiParts.first?.trimmingCharacters(in: .whitespaces) {
                    let val = resolveIROperand(firstVal, ctx: ctx)
                    ctx.emitAutoAssign(lhs, expr: val + " /* phi fallback */")
                    return
                }
            }
            ctx.define(lhs, expr: "/* phi: \(rhs.prefix(60)) */")
        }
        // 预扫描已处理，不需要发射额外语句
    }

    /// 翻译 alloca
    private static func translateAlloca(lhs: String, rhs: String, ctx: SSAContext) {
        let cleaned = rhs.replacingOccurrences(of: "alloca ", with: "")
        let typePart = cleaned.components(separatedBy: ",").first ?? cleaned
        let mslType = irScalarTypeToMSL(typePart.trimmingCharacters(in: .whitespaces))
        let temp = ctx.freshTemp()
        ctx.emit("\(mslType) \(temp);")
        ctx.define(lhs, expr: addressExpression(for: temp), type: mslType + "*")
        ctx.markPointer(lhs)
    }

    /// 翻译 ret 指令
    private static func translateRet(_ line: String, ctx: SSAContext) {
        let cleaned = line.replacingOccurrences(of: "ret ", with: "").trimmingCharacters(in: .whitespaces)
        if cleaned == "void" {
            // ret void — 但函数可能是非 void 返回类型（测试 stub 常见）
            // 检查函数声明的返回类型，避免在非 void 函数中生成 return;
            if ctx.functionReturnType.isEmpty || ctx.functionReturnType == "void" {
                ctx.emit("return;")
            } else {
                ctx.emit("return \(ctx.functionReturnType)();")
            }
            return
        }
        // ret <type> <value>
        let parts = splitTypedOperands(cleaned, count: 1)
        if let first = parts.first {
            let val = resolveIROperand(first.value, ctx: ctx)
            let normalizedAggregateReturn = normalizeAggregateReturnExpression(val, ctx: ctx)
            if val.trimmingCharacters(in: .whitespaces).hasPrefix("{"),
               !ctx.functionReturnType.isEmpty,
               ctx.functionReturnType != "void" {
                ctx.emit("return \(ctx.functionReturnType)\(normalizedAggregateReturn ?? val);")
            } else if val == "0" && !ctx.functionReturnType.isEmpty
                        && ctx.functionReturnType != "void"
                        && isStructTypeName(ctx.functionReturnType) {
                // E-006a2e6: undef/poison/zeroinitializer 返回结构体时，
                // "0" 不能隐式转换为结构体类型，使用零初始化构造
                ctx.emit("return \(ctx.functionReturnType)();")
            } else {
                ctx.emit("return \(val);")
            }
        } else {
            ctx.emit("return;")
        }
    }

    private static func normalizeAggregateReturnExpression(_ expression: String, ctx: SSAContext) -> String? {
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), trimmed.hasSuffix("}"), !ctx.functionReturnFieldTypes.isEmpty else {
            return nil
        }

        let inner = String(trimmed.dropFirst().dropLast())
        let parts = splitIRParameters(inner).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard parts.count == ctx.functionReturnFieldTypes.count else {
            return nil
        }

        let normalizedParts = zip(parts, ctx.functionReturnFieldTypes).map { part, targetType in
            coerceExpression(part, toMSLType: targetType)
        }
        return "{ \(normalizedParts.joined(separator: ", ")) }"
    }

    private static func coerceExpression(_ expression: String, toMSLType targetType: String) -> String {
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetType.isEmpty else { return trimmed }
        guard !trimmed.isEmpty else {
            return isStructTypeName(targetType) ? "\(targetType)()" : "\(targetType)(0)"
        }

        if targetType == "bool" {
            return trimmed == "false" ? "false" : "bool(\(trimmed))"
        }
        if isStructTypeName(targetType) {
            return trimmed == "0" ? "\(targetType)()" : "\(targetType)(\(trimmed))"
        }
        return "\(targetType)(\(trimmed))"
    }

    /// 翻译 br 指令（E-004e4b: 条件→if/else + phi 赋值，无条件→phi 赋值+忽略跳转）
    ///
    /// 在 LLVM IR 的 SSA 形式中，phi 节点选择来自不同前驱 BB 的值。
    /// 在 MSL 中，我们将 phi 降级为普通变量：在每个前驱 BB 的分支处
    /// 赋值为该前驱应提供的值。
    ///
    /// 条件 br 翻译为 if/else 结构，可以包含 phi 赋值：
    /// ```
    /// if (cond) {
    ///   phi_0 = val_from_true_path;  // phi 赋值
    /// } else {
    ///   phi_0 = val_from_false_path; // phi 赋值
    /// }
    /// ```
    ///
    /// 无条件 br 处也插入 phi 赋值（如果目标 BB 有 phi 且当前 BB 是其前驱）。
    private static func translateBr(_ line: String, ctx: SSAContext) {
        let cleaned = line.replacingOccurrences(of: "br ", with: "").trimmingCharacters(in: .whitespaces)
        let currentLabel = ctx.currentBBLabel

        if cleaned.hasPrefix("i1 ") {
            // 条件跳转: br i1 %cond, label %trueBB, label %falseBB
            let condParts = cleaned.components(separatedBy: ",")
            guard condParts.count >= 3 else { return }

            let condStr = condParts[0].replacingOccurrences(of: "i1 ", with: "")
                .trimmingCharacters(in: .whitespaces)
            let cond = resolveIROperand(condStr, ctx: ctx)

            let trueLabel = condParts[1].trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "label %", with: "")
                .replacingOccurrences(of: "label ", with: "")
                .trimmingCharacters(in: .whitespaces)
            let falseLabel = condParts[2].trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "label %", with: "")
                .replacingOccurrences(of: "label ", with: "")
                .trimmingCharacters(in: .whitespaces)

            // 收集 true 分支和 false 分支的 phi 赋值
            let truePhiAssigns = collectPhiAssignments(forTarget: trueLabel, fromPred: currentLabel, ctx: ctx)
            let falsePhiAssigns = collectPhiAssignments(forTarget: falseLabel, fromPred: currentLabel, ctx: ctx)

            if truePhiAssigns.isEmpty && falsePhiAssigns.isEmpty {
                // 无 phi 赋值，生成简洁的 if/else 注释
                ctx.emit("if (\(cond)) {")
                ctx.indentLevel += 1
                ctx.emit("// → BB\(trueLabel)")
                ctx.indentLevel -= 1
                ctx.emit("} else {")
                ctx.indentLevel += 1
                ctx.emit("// → BB\(falseLabel)")
                ctx.indentLevel -= 1
                ctx.emit("}")
            } else {
                // 有 phi 赋值：生成包含赋值的 if/else
                ctx.emit("if (\(cond)) {")
                ctx.indentLevel += 1
                for assign in truePhiAssigns {
                    ctx.emit(assign)
                }
                if truePhiAssigns.isEmpty {
                    ctx.emit("// → BB\(trueLabel)")
                }
                ctx.indentLevel -= 1
                ctx.emit("} else {")
                ctx.indentLevel += 1
                for assign in falsePhiAssigns {
                    ctx.emit(assign)
                }
                if falsePhiAssigns.isEmpty {
                    ctx.emit("// → BB\(falseLabel)")
                }
                ctx.indentLevel -= 1
                ctx.emit("}")
            }
        } else if cleaned.hasPrefix("label ") {
            // 无条件跳转: br label %dest
            let dest = cleaned.replacingOccurrences(of: "label %", with: "")
                .replacingOccurrences(of: "label ", with: "")
                .trimmingCharacters(in: .whitespaces)

            // 插入 phi 赋值
            let phiAssigns = collectPhiAssignments(forTarget: dest, fromPred: currentLabel, ctx: ctx)
            for assign in phiAssigns {
                ctx.emit(assign)
            }
            // 无条件跳转本身忽略（fall-through 或已由控制流处理）
        }
    }

    /// 收集当 BB `fromPred` 跳转到 `target` 时需要的 phi 赋值语句
    private static func collectPhiAssignments(forTarget target: String, fromPred pred: String, ctx: SSAContext) -> [String] {
        guard let bbInfo = ctx.bbInfo[target] else { return [] }
        var assignments: [String] = []

        for phi in bbInfo.phiNodes {
            // 找到来自 pred 的值
            for (value, label) in phi.incoming {
                if label == pred {
                    let resolvedValue = resolveIROperand(value, ctx: ctx)
                    assignments.append("\(phi.mslVarName) = \(resolvedValue); // phi from BB\(pred)")
                    break
                }
            }
        }

        return assignments
    }

    // MARK: - IR Parsing Helpers (E-004e4a)

    /// 表示一个带类型的 IR 操作数
    private struct TypedOperand {
        let type: String
        let value: String
        let rawLength: Int
    }

    /// 分割带类型的 IR 操作数列表。
    /// IR 中的操作数格式: <type> <value>, <type> <value>, ...
    /// 其中 type 可能是 <4 x float> 等复合形式。
    private static func splitTypedOperands(_ text: String, count: Int) -> [TypedOperand] {
        var results: [TypedOperand] = []
        var remaining = text.trimmingCharacters(in: .whitespaces)
        var consumed = 0

        for _ in 0..<count {
            if remaining.isEmpty { break }

            // 跳过逗号
            if remaining.hasPrefix(",") {
                remaining = String(remaining.dropFirst()).trimmingCharacters(in: .whitespaces)
                consumed += 1
            }

            // 去掉 metadata 尾巴 (!tbaa !xx, !alias.scope !xx 等)
            if remaining.hasPrefix("!") { break }

            // 去掉 align N
            if remaining.hasPrefix("align ") { break }

            // 解析类型
            let (type, afterType) = parseIRType(remaining)
            if type.isEmpty { break }
            remaining = afterType.trimmingCharacters(in: .whitespaces)

            // 解析值（到下一个逗号、metadata 或结尾）
            let (value, afterValue) = parseIRValue(remaining)
            remaining = afterValue.trimmingCharacters(in: .whitespaces)

            let rawLen = text.count - remaining.count - consumed
            results.append(TypedOperand(type: type, value: value, rawLength: rawLen))
        }

        return results
    }

    /// 解析 IR 类型前缀，返回 (type, remaining)
    private static func parseIRType(_ text: String) -> (String, String) {
        var s = text.trimmingCharacters(in: .whitespaces)

        // 向量类型: <N x T>
        if s.hasPrefix("<") {
            var depth = 0
            var i = s.startIndex
            while i < s.endIndex {
                if s[i] == "<" { depth += 1 }
                else if s[i] == ">" { depth -= 1 }
                i = s.index(after: i)
                if depth == 0 { break }
            }
            let type = String(s[s.startIndex..<i])
            let rest = String(s[i...])
            return (type, rest)
        }

        // 数组类型: [N x T]
        if s.hasPrefix("[") {
            var depth = 0
            var i = s.startIndex
            while i < s.endIndex {
                if s[i] == "[" { depth += 1 }
                else if s[i] == "]" { depth -= 1 }
                i = s.index(after: i)
                if depth == 0 { break }
            }
            let type = String(s[s.startIndex..<i])
            let rest = String(s[i...])
            return (type, rest)
        }

        // 结构体类型: { <4 x float>, i8 }
        if s.hasPrefix("{") {
            var depth = 0
            var i = s.startIndex
            while i < s.endIndex {
                if s[i] == "{" { depth += 1 }
                else if s[i] == "}" { depth -= 1 }
                i = s.index(after: i)
                if depth == 0 { break }
            }
            let type = String(s[s.startIndex..<i])
            let rest = String(s[i...])
            return (type, rest)
        }

        // packed struct: <{ ... }>
        if s.hasPrefix("<{") {
            var depth = 0
            var i = s.startIndex
            while i < s.endIndex {
                if s[i] == "<" && s.index(after: i) < s.endIndex && s[s.index(after: i)] == "{" { depth += 1 }
                else if s[i] == "}" && s.index(after: i) < s.endIndex && s[s.index(after: i)] == ">" { depth -= 1 }
                i = s.index(after: i)
                if depth == 0 { i = s.index(after: i); break }
            }
            let type = String(s[s.startIndex..<i])
            let rest = String(s[i...])
            return (type, rest)
        }

        // ptr addrspace(N)
        if s.hasPrefix("ptr") {
            // 可能是 "ptr addrspace(N)" 或只是 "ptr"
            let words = s.prefix(30)
            if words.contains("addrspace(") {
                if let closeP = s.range(of: ")") {
                    let endIdx = s.index(after: closeP.upperBound)
                    let type = String(s[s.startIndex..<closeP.upperBound])
                    let rest = endIdx < s.endIndex ? String(s[endIdx...]) : ""
                    return (type, rest)
                }
            }
            // 处理 ptr 后面跟的修饰符
            var endIdx = s.index(s.startIndex, offsetBy: 3)
            while endIdx < s.endIndex {
                let c = s[endIdx]
                if c == "%" || c == "@" || c == "-" || c.isNumber ||
                   c == "<" || c == "{" || c == "(" || c == "!" {
                    break
                }
                // 跳过空格和修饰符关键字
                if c == " " || c == "\t" {
                    let afterSpace = String(s[endIdx...]).trimmingCharacters(in: .whitespaces)
                    let modifiers = ["addrspace(", "nocapture", "readonly", "writeonly",
                                     "align ", "dereferenceable(", "nonnull", "captures(",
                                     "\"air-buffer-no-alias\""]
                    var foundMod = false
                    for mod in modifiers {
                        if afterSpace.hasPrefix(mod) {
                            foundMod = true
                            break
                        }
                    }
                    if !foundMod { break }
                }
                endIdx = s.index(after: endIdx)
            }
            let type = String(s[s.startIndex..<endIdx]).trimmingCharacters(in: .whitespaces)
            let rest = String(s[endIdx...])
            return (type, rest)
        }

        // 简单类型: void, float, half, i1, i8, i16, i32, i64, double
        let simpleTypes = ["void", "double", "float", "half", "i64", "i32", "i16", "i8", "i1"]
        for st in simpleTypes {
            if s.hasPrefix(st) {
                let afterType = s.dropFirst(st.count)
                if afterType.isEmpty || afterType.first == " " || afterType.first == "," {
                    // 检查是否有 addrspace 后缀
                    let rest = String(afterType).trimmingCharacters(in: .whitespaces)
                    if rest.hasPrefix("addrspace(") {
                        if let closeP = rest.range(of: ")") {
                            let fullType = st + " " + String(rest[rest.startIndex...closeP.lowerBound])
                            let afterFull = String(rest[closeP.upperBound...])
                            return (fullType, afterFull)
                        }
                    }
                    return (st, String(afterType))
                }
            }
        }

        // %struct.xxx 或 %"xxx"
        if s.hasPrefix("%") {
            let end = s.firstIndex(where: { $0 == " " || $0 == "," }) ?? s.endIndex
            let type = String(s[s.startIndex..<end])
            let rest = String(s[end...])
            return (type, rest)
        }

        // 无法识别
        return ("", s)
    }

    /// 解析 IR 值，到下一个逗号或 metadata 标记为止
    private static func parseIRValue(_ text: String) -> (String, String) {
        var s = text
        // 去掉前导空格
        while s.hasPrefix(" ") || s.hasPrefix("\t") {
            s = String(s.dropFirst())
        }

        var depth = 0
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if c == "<" || c == "(" || c == "{" || c == "[" { depth += 1 }
            else if c == ">" || c == ")" || c == "}" || c == "]" { depth -= 1 }

            // 逗号在顶层表示操作数分隔
            if c == "," && depth == 0 { break }
            // metadata 标记
            if c == "!" && depth == 0 {
                // 确认不是 "!0" 数值型操作数
                let rest = s[i...]
                if rest.hasPrefix("!tbaa") || rest.hasPrefix("!alias") ||
                   rest.hasPrefix("!noalias") || rest.hasPrefix("!range") {
                    break
                }
            }
            i = s.index(after: i)
        }

        let value = String(s[s.startIndex..<i]).trimmingCharacters(in: .whitespaces)
        let remaining = i < s.endIndex ? String(s[i...]) : ""
        return (value, remaining)
    }

    /// 解析二元运算的操作数: [flags] <type> <op1>, <op2>
    private static func parseBinaryOperands(
        _ rhs: String,
        skipKeywords: [String]
    ) -> (String, [String]) {
        var s = rhs
        // 跳过 flags
        var words = s.components(separatedBy: " ").filter { !$0.isEmpty }
        while let first = words.first, skipKeywords.contains(first) {
            words.removeFirst()
        }
        s = words.joined(separator: " ").trimmingCharacters(in: .whitespaces)

        // LLVM 二元算术统一是 `<type> lhs, rhs`，第二个操作数复用前面的类型声明。
        let (type, afterType) = parseIRType(s)
        guard !type.isEmpty else { return ("", []) }

        let afterTypeTrimmed = afterType.trimmingCharacters(in: .whitespaces)
        let (firstOperand, remainderAfterFirst) = parseIRValue(afterTypeTrimmed)
        guard !firstOperand.isEmpty else { return (type, []) }

        var operands: [String] = [firstOperand]
        let remainder = remainderAfterFirst.trimmingCharacters(in: .whitespaces)
        if remainder.hasPrefix(",") {
            let second = String(remainder.dropFirst()).trimmingCharacters(in: .whitespaces)
            if !second.isEmpty {
                operands.append(second)
            }
        }

        return (type, operands)
    }

    /// 分割 select 的三个操作数
    private static func splitSelectOperands(_ text: String) -> [String] {
        let parts = splitTypedOperands(text, count: 3)
        return parts.map { $0.value }
    }

    /// 解析 IR 操作数为 MSL 表达式
    private static func resolveIROperand(_ operand: String, ctx: SSAContext) -> String {
        let s = operand.trimmingCharacters(in: .whitespaces)

        // E-006a2e10 → E-006g3: 处理全局 IR symbols (@...)
        // - `@__air_sampler_state` 等 AIR 内部 symbol 仍映射到对应 sampler 参数
        // - 其他顶层全局常量（如 `@_ZL7ImmCB_0`）则保留为已发射到 MSL 的全局符号名
        if s.hasPrefix("@") {
            if s.contains("sampler") {
                // 优先匹配 addrspace(2)（typed pointer 模式），fallback 再按 sampler 名称匹配
                for (irParam, mslName) in ctx.paramNames {
                    if let irType = ctx.paramTypes[irParam],
                       irType.contains("addrspace(2)") {
                        return mslName
                    }
                }
                for (_, mslName) in ctx.paramNames where mslName.contains("sampler") {
                    return mslName
                }
            }
            let symbolName = String(s.dropFirst())
                .replacingOccurrences(of: "\"", with: "")
            return sanitizeIdentifier(symbolName, fallback: "globalSymbol", uppercaseFirst: false)
        }

        // SSA 名 / SSA 名后缀访问（如 `%1.xyz`、`%0.field3[0]`）
        if s.hasPrefix("%") {
            let direct = ctx.resolve(s)
            if direct != s { return direct }

            for separator in [".", "["] {
                if let range = s.range(of: separator) {
                    let base = String(s[s.startIndex..<range.lowerBound])
                    let suffix = String(s[range.lowerBound...])
                    let resolvedBase = ctx.resolve(base)
                    if resolvedBase != base {
                        return resolvedBase + suffix
                    }
                }
            }
        }

        // 某些 call 参数 value 仍会残留 IR 限定词（如 `nocapture readonly %2`），
        // 这里兜底取最后一个 SSA token 再递归解析，避免 `%N` 直接泄漏到 MSL。
        if s.contains("%") {
            let tailToken = s
                .components(separatedBy: .whitespaces)
                .last { $0.contains("%") }
                .map { String($0) }
            if let tailToken, !tailToken.isEmpty, tailToken != s {
                return resolveIROperand(tailToken, ctx: ctx)
            }
        }

        // E-006a2e10: 同理，全局 symbol 也可能被 IR 限定词包裹
        // （如 `readonly captures(none) @__air_sampler_state`），需提取 @ token 再递归
        if s.contains("@") {
            let tailToken = s
                .components(separatedBy: .whitespaces)
                .last { $0.hasPrefix("@") }
                .map { String($0) }
            if let tailToken, !tailToken.isEmpty, tailToken != s {
                return resolveIROperand(tailToken, ctx: ctx)
            }
        }

        // 布尔常量
        if s == "true" { return "true" }
        if s == "false" { return "false" }

        // 特殊常量
        if s == "zeroinitializer" { return "0" }
        if s == "undef" || s == "poison" { return "0" }
        if s == "null" { return "nullptr" }

        // IR typed constant: "float undef", "half 0xH8000", "i32 42" 等
        // 提取类型后面的实际值并递归处理
        let irScalarTypes: Set<String> = ["void", "half", "float", "double", "i1", "i8", "i16", "i32", "i64", "ptr", "label"]
        let litTokens = s.components(separatedBy: .whitespaces)
        if litTokens.count >= 2 && irScalarTypes.contains(litTokens[0]) {
            return resolveIROperand(litTokens.dropFirst().joined(separator: " "), ctx: ctx)
        }

        // 向量 splat: splat (float 2.000000e+00)
        if s.hasPrefix("splat (") {
            let inner = String(s.dropFirst("splat (".count).dropLast())
            let innerParts = inner.components(separatedBy: " ")
            if innerParts.count >= 2 {
                return formatIRLiteral(innerParts.dropFirst().joined(separator: " "))
            }
            return s
        }

        // 向量常量: <float 1.0, float 0.0, ...>
        if s.hasPrefix("<") && s.hasSuffix(">") && !s.contains(" x ") {
            return parseVectorLiteral(s)
        }

        // 浮点字面量
        if s.contains("e+") || s.contains("e-") || s.contains("0x") {
            return formatIRLiteral(s)
        }

        // 整数字面量
        if s.first?.isNumber == true || (s.first == "-" && s.count > 1) {
            return s
        }

        return s
    }

    /// 检测字符串是否是浮点数字面量（如 "0.1", "1.0", "2.000000e+00" 等）
    private static func isFloatLiteral(_ s: String) -> Bool {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return false }
        // 排除 SSA 引用、函数调用等非字面量
        if trimmed.hasPrefix("%") || trimmed.contains("(") || trimmed.contains(")") ||
           trimmed.contains("/*") || trimmed.contains("//") || trimmed.contains("[") {
            return false
        }
        return Double(trimmed) != nil
    }

    /// 检测类型名是否是 MSL 格式的向量类型（float4, half2, int3, uint2, uchar2, bool4 等）。
    /// IR 格式的向量类型（<4 x float>）由 hasPrefix("<") 处理，此函数处理 MSL 格式。
    private static func isMSLVectorType(_ type: String) -> Bool {
        let s = type.trimmingCharacters(in: .whitespaces)
        guard s.count >= 2, !s.isEmpty else { return false }
        // 向量类型以数字结尾（维度），基础类型是标量类型名
        let lastChar = s.last!
        guard lastChar.isNumber, lastChar != "0" else { return false }
        let base = String(s.dropLast())
        // 已知 MSL 标量类型
        let scalarTypes: Set<String> = [
            "float", "half", "double",
            "int", "uint",
            "short", "ushort",
            "char", "uchar",
            "long", "ulong",
            "bool",
        ]
        return scalarTypes.contains(base)
    }

    /// 从 IR 操作数字符串中提取纯 SSA 名（%N）。
    /// 例如："ptr addrspace(2) %8" → "%8"，"%8" → "%8"，"fg.color" → "fg.color"
    private static func extractSSAName(from operand: String) -> String {
        let trimmed = operand.trimmingCharacters(in: .whitespaces)
        if trimmed.contains("%") {
            if let lastPercent = trimmed.range(of: "%", options: .backwards) {
                let fromPercent = trimmed[lastPercent.lowerBound...]
                // 提取 %N 部分（到空格或结尾）
                let endIdx = fromPercent.firstIndex(where: { $0 == " " || $0 == "," }) ?? fromPercent.endIndex
                return String(fromPercent[..<endIdx])
            }
        }
        return trimmed
    }

    /// 如果参数是纯数字字面量，追加 h 后缀使其成为 half literal。
    /// SSA 引用（%N）、函数调用结果、常量表达式等不受影响。
    /// 整数字面量（如 "3", "0"）会先转为浮点形式（"3.0h", "0.0h"），
    /// 因为 Metal 的 h 后缀只能用于浮点字面量。
    private static func appendHalfSuffixIfFPLiteral(_ arg: String) -> String {
        let s = arg.trimmingCharacters(in: .whitespaces)
        // 跳过 SSA 引用、函数调用、注释、类型转换等
        if s.hasPrefix("%") || s.hasPrefix("(") || s.contains("(") ||
           s.contains("/*") || s.contains("//") || s.contains("?") {
            return arg
        }
        // 已经有 h 后缀就跳过
        if s.hasSuffix("h") { return arg }
        // 检查是否是纯数字字面量（浮点或整数）
        // 浮点: "0.0", "1.0", "-1.0", "0.5", "3.14", 科学计数法等
        // 整数: "0", "1", "3", "-2" 等
        if let d = Double(s) {
            // 如果没有小数点且不是科学计数法，视为整数字面量，先转为浮点形式
            if !s.contains(".") && !s.contains("e") && !s.contains("E") {
                // 确保是纯整数形式（排除 hex 等）
                let stripped = s.hasPrefix("-") ? String(s.dropFirst()) : s
                if stripped.allSatisfy({ $0.isNumber }) {
                    return "\(String(format: "%.1f", d))h"
                }
            }
            return "\(s)h"
        }
        return arg
    }

    /// 格式化 IR 浮点字面量为 MSL
    private static func formatIRLiteral(_ s: String) -> String {
        // undef / poison — 不能泄漏到 MSL
        if s == "undef" || s == "poison" { return "0" }

        if s.hasPrefix("0x") {
            let hex = String(s.dropFirst(2))
            // LLVM IR half-precision hex: 0xH8000 等
            if hex.first?.uppercased() == "H" {
                let hexDigits = String(hex.dropFirst())
                if let bits = UInt16(hexDigits, radix: 16) {
                    return formatHalfIRLiteral(bits)
                }
            }
            // 标准 IEEE-754 十六进制浮点 → Double → 十进制
            if let bits = UInt64(hex, radix: 16) {
                let d = Double(bitPattern: bits)
                if d == 0.0 { return "0.0" }
                return String(format: "%.6g", d)
            }
            return s
        }
        // 科学计数法
        if let d = Double(s) {
            if d == 0.0 { return "0.0" }
            if d == 1.0 { return "1.0" }
            if d == 2.0 { return "2.0" }
            if d == 0.5 { return "0.5" }
            if d == 3.0 { return "3.0" }
            return String(format: "%.6g", d)
        }
        return s
    }

    /// 将 LLVM IR half 精度十六进制立即数 (0xHxxxx) 转换为合法 MSL 表达式
    private static func formatHalfIRLiteral(_ bits: UInt16) -> String {
        // IEEE-754 half: sign(1) | exponent(5) | mantissa(10)
        let sign = bits >> 15
        let exponent = (bits >> 10) & 0x1F
        let mantissa = bits & 0x3FF

        // 特殊值: Inf / NaN — 只能用 bitcast 保留原始 bit pattern
        if exponent == 0x1F {
            return "as_type<half>(ushort(0x\(String(bits, radix: 16).uppercased())))"
        }

        if exponent == 0 && mantissa == 0 { return "half(0.0)" }

        // 正常值 / subnormal: 转为 Float 再格式化
        let floatValue: Float
        if exponent == 0 {
            // Subnormal: implicit leading bit = 0, exponent = -14
            let m = Float(mantissa) / Float(1 << 10)
            floatValue = (sign == 0 ? 1.0 : -1.0) * m * powf(2.0, -14.0)
        } else {
            // Normal: implicit leading bit = 1, exponent = biased - 15
            let m = 1.0 + Float(mantissa) / Float(1 << 10)
            floatValue = (sign == 0 ? 1.0 : -1.0) * m * powf(2.0, Float(Int(exponent) - 15))
        }

        // 尝试简洁的十进制表示
        if floatValue == 0.0 { return "half(0.0)" }
        if floatValue == 1.0 { return "half(1.0)" }
        if floatValue == -1.0 { return "half(-1.0)" }
        if floatValue == 0.5 { return "half(0.5)" }
        if floatValue == -0.5 { return "half(-0.5)" }
        if floatValue == 2.0 { return "half(2.0)" }
        if floatValue == -2.0 { return "half(-2.0)" }

        // 一般值: 输出十进制浮点（MSL 上下文自动匹配 half 类型）
        return "half(\(String(format: "%.6g", Double(floatValue))))"
    }

    /// 解析 IR 向量字面量: <float 1.0, float 0.0, ...> → float4(1.0, 0.0, ...)
    private static func parseVectorLiteral(_ s: String) -> String {
        let inner = String(s.dropFirst().dropLast())
        let elems = inner.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        var values: [String] = []
        for elem in elems {
            let parts = elem.components(separatedBy: " ")
            if parts.count >= 2 {
                values.append(formatIRLiteral(parts.last ?? "0"))
            } else {
                values.append(formatIRLiteral(elem))
            }
        }
        let dim = values.count
        let elemType = elems.first?.components(separatedBy: " ").first ?? "float"
        // E-006a2e12: i8 向量特殊处理 — MSL 不支持 uint8_tN，必须用 ucharN
        if elemType == "i8" {
            return "uchar\(dim)(\(values.joined(separator: ", ")))"
        }
        let mslType = irScalarTypeToMSL(elemType)
        return "\(mslType)\(dim)(\(values.joined(separator: ", ")))"
    }

    private static func vectorElementIRType(_ irType: String) -> String {
        let trimmed = irType.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("<"), trimmed.hasSuffix(">"), trimmed.contains(" x ") else {
            return trimmed
        }
        let inner = String(trimmed.dropFirst().dropLast())
        let parts = inner.components(separatedBy: " x ")
        return parts.last?.trimmingCharacters(in: .whitespaces) ?? trimmed
    }

    private static func vectorComponentExpression(vectorExpr: String, index: Int) -> String {
        if index >= 0 && index < 4 {
            return "\(vectorExpr).\(vectorIndexToSwizzle(index))"
        }
        return "\(vectorExpr)[\(index)]"
    }

    private static func vectorConstructorElementTypeName(_ mslScalarType: String) -> String {
        if mslScalarType == "uint8_t" {
            return "uchar"
        }
        return mslScalarType
    }

    private static func groupedShuffleConstructor(
        v1: String,
        v2: String,
        srcIRType: String,
        resultMSLType: String,
        maskIndices: [Int],
        maxSrcDim: Int
    ) -> String? {
        guard !maskIndices.isEmpty, maskIndices.count <= 4 else { return nil }
        let elementIRType = vectorElementIRType(srcIRType)
        let elementMSLType = irScalarTypeToMSL(elementIRType)
        let vectorElementType = vectorConstructorElementTypeName(elementMSLType)
        let zeroScalar = zeroInitializerExpression(forIRType: elementIRType)

        enum Segment {
            case zero(Int)
            case v1(Int, Int)
            case v2(Int, Int)
        }

        func sourceAndOffset(for index: Int) -> (isV1: Bool, offset: Int)? {
            if index < 0 { return nil }
            if index < maxSrcDim { return (true, index) }
            return (false, index - maxSrcDim)
        }

        var segments: [Segment] = []
        var cursor = 0
        while cursor < maskIndices.count {
            let current = maskIndices[cursor]
            if current < 0 {
                var length = 1
                while cursor + length < maskIndices.count, maskIndices[cursor + length] < 0 {
                    length += 1
                }
                segments.append(.zero(length))
                cursor += length
                continue
            }
            guard let info = sourceAndOffset(for: current) else { return nil }
            var length = 1
            while cursor + length < maskIndices.count,
                  let next = sourceAndOffset(for: maskIndices[cursor + length]),
                  next.isV1 == info.isV1,
                  next.offset == info.offset + length,
                  next.offset < 4 {
                length += 1
            }
            segments.append(info.isV1 ? .v1(info.offset, length) : .v2(info.offset, length))
            cursor += length
        }

        guard segments.count < maskIndices.count, segments.count <= 2 else { return nil }

        func swizzleExpr(vector: String, start: Int, length: Int) -> String {
            if length == 1 {
                return vectorComponentExpression(vectorExpr: vector, index: start)
            }
            let swizzle = (start..<(start + length)).map(vectorIndexToSwizzle).joined()
            return "\(vector).\(swizzle)"
        }

        func zeroExpr(length: Int) -> String {
            if length == 1 { return zeroScalar }
            return "\(vectorElementType)\(length)(\(Array(repeating: zeroScalar, count: length).joined(separator: ", ")) )"
                .replacingOccurrences(of: ") )", with: "))")
        }

        let args = segments.map { segment in
            switch segment {
            case .zero(let length):
                return zeroExpr(length: length)
            case .v1(let start, let length):
                return swizzleExpr(vector: v1, start: start, length: length)
            case .v2(let start, let length):
                return swizzleExpr(vector: v2, start: start, length: length)
            }
        }
        return "\(resultMSLType)(\(args.joined(separator: ", ")) )".replacingOccurrences(of: ") )", with: "))")
    }

    /// 解析向量常量 mask: <i32 0, i32 1, i32 2, i32 poison>
    private static func parseVectorConstant(_ mask: String, fallbackDim: Int? = nil) -> [Int] {
        let inner: String
        if mask.hasPrefix("<") && mask.hasSuffix(">") {
            inner = String(mask.dropFirst().dropLast())
        } else {
            inner = mask
        }

        if inner.contains("zeroinitializer") {
            let dim = max(fallbackDim ?? 4, 1)
            return Array(repeating: 0, count: dim)
        }

        return inner.components(separatedBy: ",").map { part in
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed.contains("poison") || trimmed.contains("undef") { return -1 }
            // "i32 0" → 0
            let numStr = trimmed.components(separatedBy: " ").last ?? trimmed
            return Int(numStr) ?? -1
        }
    }

    /// 向量索引到 swizzle 字符
    private static func vectorIndexToSwizzle(_ idx: Int) -> String {
        switch idx {
        case 0: return "x"
        case 1: return "y"
        case 2: return "z"
        case 3: return "w"
        default: return "[\(idx)]"
        }
    }

    /// 从 IR 向量类型提取维度
    private static func extractVectorDim(_ irType: String) -> Int {
        // <4 x float> → 4
        if irType.hasPrefix("<") && irType.contains(" x ") {
            let inner = irType.dropFirst().prefix(while: { $0 != " " })
            return Int(inner) ?? 4
        }
        return 1
    }

    /// 构造指定维度的向量类型
    private static func vectorTypeWithDim(_ baseType: String, dim: Int) -> String {
        if dim <= 1 { return baseType }
        // 从 <4 x float> 中提取元素类型
        if baseType.hasPrefix("<") && baseType.contains(" x ") {
            let inner = String(baseType.dropFirst().dropLast())
            let parts = inner.components(separatedBy: " x ")
            if parts.count >= 2 {
                let elemType = parts.last?.trimmingCharacters(in: .whitespaces) ?? "float"
                return "<\(dim) x \(elemType)>"
            }
        }
        return baseType
    }

    /// 去掉 fast-math 标志
    private static func stripFastMathFlags(_ s: String) -> String {
        let flags = ["fast", "nnan", "ninf", "nsz", "arcp", "contract", "reassoc", "afn"]
        var result = s
        for flag in flags {
            result = result.replacingOccurrences(of: flag + " ", with: "")
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// fcmp 条件码到 MSL 运算符
    private static func fcmpCondToMSL(_ cond: String) -> String {
        switch cond {
        case "oeq", "ueq": return "=="
        case "one", "une": return "!="
        case "ogt", "ugt": return ">"
        case "oge", "uge": return ">="
        case "olt", "ult": return "<"
        case "ole", "ule": return "<="
        case "ord": return "== /* ordered */"
        case "uno": return "!= /* unordered */"
        case "true": return "== /* always true */"
        case "false": return "!= /* always false */"
        default: return "/* \(cond) */"
        }
    }

    /// icmp 条件码到 MSL 运算符
    private static func icmpCondToMSL(_ cond: String) -> String {
        switch cond {
        case "eq": return "=="
        case "ne": return "!="
        case "ugt", "sgt": return ">"
        case "uge", "sge": return ">="
        case "ult", "slt": return "<"
        case "ule", "sle": return "<="
        default: return "/* \(cond) */"
        }
    }

    /// barrier 标志常量到 MSL mem_flags
    private static func barrierFlagsToMSL(_ flags: String) -> String {
        switch flags {
        case "0": return "mem_flags::mem_none"
        case "1": return "mem_flags::mem_device"
        case "2": return "mem_flags::mem_threadgroup"
        case "3": return "mem_flags::mem_threadgroup | mem_flags::mem_device"
        default: return "mem_flags::mem_threadgroup"
        }
    }

    /// AIR memory_order i32 值映射为 MSL memory_order 枚举
    /// 0=relaxed, 1=acquire, 2=release, 3=acq_rel, 5=seq_cst
    private static func memoryOrderToMSL(_ order: String) -> String {
        switch order.trimmingCharacters(in: .whitespaces) {
        case "0": return "memory_order_relaxed"
        case "1": return "memory_order_acquire"
        case "2": return "memory_order_release"
        case "3": return "memory_order_acq_rel"
        case "5": return "memory_order_seq_cst"
        default: return "memory_order_relaxed"
        }
    }

    /// E-006b9: 为 atomic 操作生成 MSL 调用
    ///
    /// AIR 原子函数参数格式:
    ///   fetch_* / exchange / load:   (ptr, val, order, scope, volatile)
    ///   store:                       (ptr, val, order, scope, volatile)
    ///   cmpxchg:                     (ptr, expected, desired, succ_order, fail_order, scope, volatile)
    ///
    /// MSL 对应签名:
    ///   fetch_* / exchange:          atomic_fetch_*_explicit(obj, val, order)
    ///   load:                        atomic_load_explicit(obj, order)
    ///   store:                       atomic_store_explicit(obj, val, order)
    ///   cmpxchg:                     atomic_compare_exchange_weak_explicit(obj, expected, desired, succ_order, fail_order)
    private static func generateAtomicMSL(
        mapping: AirBuiltinMapping,
        airName: String,
        args: [String],
        argTypes: [String]
    ) -> String {
        let mslFunc = mapping.mslFunction

        // cmpxchg 有 7 个 AIR 参数: (ptr, expected, desired, succ_order, fail_order, scope, volatile)
        if mslFunc.contains("compare_exchange") {
            // AIR: ptr, expected, desired, succ_order(i32), fail_order(i32), scope(i32), volatile(i1)
            // MSL: obj, expected, desired, succ_order, fail_order
            guard args.count >= 5 else {
                return "\(mslFunc)(/* atomic args error */)"
            }
            let obj = args[0]
            let expected = args[1]
            let desired = args[2]
            let succOrder = memoryOrderToMSL(args[3])
            let failOrder = memoryOrderToMSL(args[4])
            return "\(mslFunc)(\(obj), \(expected), \(desired), \(succOrder), \(failOrder))"
        }

        // load: (ptr, order, scope, volatile)
        if mslFunc.contains("atomic_load") {
            guard args.count >= 2 else {
                return "\(mslFunc)(/* atomic args error */)"
            }
            let obj = args[0]
            let order = memoryOrderToMSL(args[1])
            return "\(mslFunc)(\(obj), \(order))"
        }

        // store: (ptr, val, order, scope, volatile)
        if mslFunc.contains("atomic_store") {
            guard args.count >= 3 else {
                return "\(mslFunc)(/* atomic args error */)"
            }
            let obj = args[0]
            let val = args[1]
            let order = memoryOrderToMSL(args[2])
            return "\(mslFunc)(\(obj), \(val), \(order))"
        }

        // fetch_* / exchange: (ptr, val, order, scope, volatile)
        guard args.count >= 3 else {
            return "\(mslFunc)(/* atomic args error */)"
        }
        let obj = args[0]
        let val = args[1]
        let order = memoryOrderToMSL(args[2])
        return "\(mslFunc)(\(obj), \(val), \(order))"
    }

    /// 过滤纹理 air 调用的内部控制参数，只保留用户可见参数
    /// 返回 (filtered_args, filtered_types) 元组，保留类型信息供 bias/level 包装使用
    /// - airName: AIR 内建函数名，用于识别需要保留 i32 参数的变体（如 _2d_array 的 array_index）
    private static func filterTextureArgs(_ args: [String], argTypes: [String], airName: String = "") -> (args: [String], types: [String]) {
        var resultArgs: [String] = []
        var resultTypes: [String] = []
        // E-006b8: 对 _2d_array 变体，coord 后的第一个 i32 是 array_index（语义参数），不能过滤
        let isArrayVariant = airName.contains("_2d_array")
        var firstI32Kept = false
        for (i, arg) in args.enumerated() {
            let type = i < argTypes.count ? argTypes[i] : ""
            // E-006a2e10: 跳过未解析的全局 symbol（resolveIROperand 对 @ 符号返回空）
            if arg.isEmpty { continue }
            // 跳过 i1 (bool 控制标志) 和 i32 控制参数（但保留坐标/颜色）
            if type == "i1" { continue }
            // 跳过零值 i32 控制标志（如 mip level=0, slice=0）
            if type == "i32" && (arg == "0" || arg == "1" || arg == "2") {
                // E-006b8: _2d_array 的第一个 i32 是 array_index，即使值为 0 也要保留
                if isArrayVariant && !firstI32Kept {
                    firstI32Kept = true
                } else {
                    continue
                }
            }
            // 跳过 <N x i32> zeroinitializer（offset 参数）
            // E-006b8: 但 write_texture 的 <2 x i32> 是坐标参数，不能过滤
            if arg == "0" && type.contains("x i32") && !airName.contains("write_texture") { continue }
            // 跳过 "0.0" float 控制参数（如 bias=0 或 min_lod_clamp=0 是无操作）
            if type == "float" && (arg == "0.0" || arg == "0.000000e+00") {
                continue
            }
            resultArgs.append(arg)
            resultTypes.append(type)
        }
        return (resultArgs, resultTypes)
    }

    /// 生成完整的 MSL 源码
    private static func generateMSL(
        functions: [ParsedShaderFunction],
        structTypeDefs: [String: IRStructTypeDef] = [:],
        structFieldInfo: [String: [StructFieldInfo]] = [:],
        globalConstants: [IRGlobalConstant] = [],
        irText: String = ""
    ) -> String {
        var lines: [String] = []

        // Header
        lines.append("//")
        lines.append("// Auto-generated MSL source by PlayTools IRToMSLConverter")
        lines.append("// E-004e: LLVM IR → MSL stub conversion")
        lines.append("// Generated at: \(ISO8601DateFormatter().string(from: Date()))")
        lines.append("// Functions: \(functions.count)")
        lines.append("//")
        lines.append("")
        lines.append("#include <metal_stdlib>")
        lines.append("using namespace metal;")
        lines.append("")

        func parseIRArrayType(_ irType: String) -> (count: Int, elementType: String)? {
            let trimmed = irType.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("["), trimmed.hasSuffix("]"), let xRange = trimmed.range(of: " x ") else {
                return nil
            }
            let countStr = String(trimmed[trimmed.index(after: trimmed.startIndex)..<xRange.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            guard let count = Int(countStr) else { return nil }
            let afterX = trimmed[xRange.upperBound...]
            let elementType = String(afterX[..<afterX.index(before: afterX.endIndex)])
                .trimmingCharacters(in: .whitespaces)
            return (count, elementType)
        }

        func globalConstantDeclaration(irType: String, name: String) -> String {
            if let array = parseIRArrayType(irType) {
                return "\(globalConstantDeclaration(irType: array.elementType, name: name))[\(array.count)]"
            }
            return "\(irScalarTypeToMSL(irType)) \(name)"
        }

        func renderGlobalConstantInitializer(irType: String, initializer: String) -> String {
            let trimmedType = irType.trimmingCharacters(in: .whitespaces)
            let trimmedInit = initializer.trimmingCharacters(in: .whitespaces)

            if let array = parseIRArrayType(trimmedType) {
                if trimmedInit == "zeroinitializer" || trimmedInit == "undef" || trimmedInit == "poison" {
                    let zeroValue = renderGlobalConstantInitializer(irType: array.elementType, initializer: "zeroinitializer")
                    return "{ \(Array(repeating: zeroValue, count: array.count).joined(separator: ", ")) }"
                }
                guard trimmedInit.hasPrefix("["), trimmedInit.hasSuffix("]") else {
                    return trimmedInit
                }
                let inner = String(trimmedInit.dropFirst().dropLast())
                let rawElements = splitIRParameters(inner).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                let renderedElements = rawElements.map { rawElement -> String in
                    let (elementType, afterType) = parseIRType(rawElement)
                    if !elementType.isEmpty {
                        let (elementValue, _) = parseIRValue(afterType)
                        return renderGlobalConstantInitializer(irType: elementType, initializer: elementValue)
                    }
                    return renderGlobalConstantInitializer(irType: array.elementType, initializer: rawElement)
                }
                return "{ \(renderedElements.joined(separator: ", ")) }"
            }

            if trimmedInit == "zeroinitializer" || trimmedInit == "undef" || trimmedInit == "poison" {
                return "\(irScalarTypeToMSL(trimmedType))(0)"
            }
            if trimmedType.hasPrefix("<") {
                return parseVectorLiteral(trimmedInit)
            }
            return resolveIROperand(trimmedInit, ctx: SSAContext())
        }

        if functions.isEmpty {
            lines.append("// No shader functions found in IR")
            return lines.joined(separator: "\n")
        }

        let userStructDefinitions = generateUserStructDefinitions(structFieldInfo, structTypeDefs: structTypeDefs)
        if !userStructDefinitions.isEmpty {
            lines.append(contentsOf: userStructDefinitions)
            lines.append("")
        }

        if !globalConstants.isEmpty {
            let compareSamplerStateGlobals = collectCompareSamplerStateGlobals(irText)
            for global in globalConstants {
                if let samplerDeclaration = renderSamplerStateDeclaration(
                    irName: global.irName,
                    irType: global.irType,
                    initializer: global.initializer,
                    usedBySampleCompare: compareSamplerStateGlobals.contains(global.irName)
                ) {
                    lines.append(samplerDeclaration)
                    continue
                }

                let symbolName = sanitizeIdentifier(
                    String(global.irName.dropFirst()).replacingOccurrences(of: "\"", with: ""),
                    fallback: "globalConstant",
                    uppercaseFirst: false
                )
                let declaration = globalConstantDeclaration(irType: global.irType, name: symbolName)
                let initializer = renderGlobalConstantInitializer(irType: global.irType, initializer: global.initializer)
                lines.append("constant \(declaration) = \(initializer);")
            }
            lines.append("")
        }

        let helperFunctions = functions.filter { !$0.isEntryPoint }
        if !helperFunctions.isEmpty {
            var emittedHelperPrototypes: Set<String> = []
            for helper in helperFunctions {
                let safeName = sanitizeFunctionName(helper.name)
                guard emittedHelperPrototypes.insert(safeName).inserted else { continue }
                let params = generateAllParams(
                    helper.parameters,
                    safeName: safeName,
                    shaderType: .helper,
                    defaultBuiltin: ""
                )
                lines.append("\(helper.returnType) \(safeName)(\(params));")
            }
            lines.append("")
        }

        // 用于去重
        var emittedNames: Set<String> = []
        var emittedAuxiliaryStructs: Set<String> = []

        for (index, func_) in functions.enumerated() {
            // MSL 不允许重复的函数名
            let safeName = sanitizeFunctionName(func_.name)
            if emittedNames.contains(safeName) { continue }
            emittedNames.insert(safeName)

            if let outputStruct = generateEntryOutputStructDefinition(for: func_),
               emittedAuxiliaryStructs.insert(outputStruct.name).inserted {
                lines.append(outputStruct.definition)
                lines.append("")
            }

            if let stageInStruct = generateStageInStructDefinition(for: func_, safeName: safeName),
               emittedAuxiliaryStructs.insert(stageInStruct.name).inserted {
                lines.append(stageInStruct.definition)
                lines.append("")
            }

            lines.append("// [\(index)] \(func_.shaderType.rawValue): \(func_.name)")
            if func_.isEntryPoint && !func_.isFullyParsed {
                lines.append("// (stub — IR signature not fully converted)")
                lines.append("// IR: \(func_.irSignature.prefix(200))")
            }
            // 列出函数体中用到的 air 内建（去重汇总）
            if !func_.airBuiltinCalls.isEmpty {
                var seenBases: Set<String> = []
                var builtinSummary: [String] = []
                for call in func_.airBuiltinCalls {
                    guard seenBases.insert(call.airBaseName).inserted else { continue }
                    if let m = call.mapping {
                        builtinSummary.append("\(call.airBaseName) → \(m.mslFunction)")
                    } else {
                        builtinSummary.append("\(call.airBaseName) → ?")
                    }
                }
                lines.append("// air builtins: \(builtinSummary.joined(separator: ", "))")
            }

            // 生成函数
            let funcCode = generateFunction(
                func_, safeName: safeName,
                structTypeDefs: structTypeDefs,
                structFieldInfo: structFieldInfo
            )
            lines.append(funcCode)
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    private static func generateUserStructDefinitions(
        _ structFieldInfo: [String: [StructFieldInfo]],
        structTypeDefs: [String: IRStructTypeDef] = [:]
    ) -> [String] {
        guard !structFieldInfo.isEmpty else { return [] }

        let knownTypes = Set(structFieldInfo.keys)
        var emitted: Set<String> = []
        var lines: [String] = []

        /// 将 IR 数组类型 [N x T] 转为 MSL 数组声明 "elementType fieldName[N]"
        /// 返回 nil 表示不是数组类型
        func irArrayTypeToMSLField(_ irType: String, fieldName: String) -> String? {
            let trimmed = irType.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("[") && trimmed.hasSuffix("]") else { return nil }
            // 解析 "[N x T]" → (count, elementType)
            guard let xRange = trimmed.range(of: " x ") else { return nil }
            let countStr = String(trimmed[trimmed.index(after: trimmed.startIndex)..<xRange.lowerBound])
            guard let count = Int(countStr.trimmingCharacters(in: .whitespaces)) else { return nil }
            let afterX = trimmed[xRange.upperBound...]
            // 去掉末尾的 ]
            let elementTypeIR = String(afterX[afterX.startIndex..<afterX.index(before: afterX.endIndex)])
                .trimmingCharacters(in: .whitespaces)
            let elementTypeMSL = irScalarTypeToMSL(elementTypeIR)
            return "\(elementTypeMSL) \(fieldName)[\(count)]"
        }

        func emitStruct(named rawTypeName: String) {
            let sanitizedTypeName = sanitizeUserTypeName(rawTypeName)
            guard emitted.insert(sanitizedTypeName).inserted else { return }
            guard let fields = structFieldInfo[rawTypeName], !fields.isEmpty else { return }

            for field in fields {
                if knownTypes.contains(field.typeName) {
                    emitStruct(named: field.typeName)
                }
            }

            // 尝试找到对应的 IR 结构体定义，用于交叉验证字段类型
            let irTypeDef = structTypeDefs.first { key, _ in
                sanitizeUserTypeName(String(key.dropFirst(key.hasPrefix("%") ? 1 : 0)).replacingOccurrences(of: "\"", with: "")) == sanitizedTypeName
            }

            lines.append("struct \(sanitizedTypeName) {")
            for field in fields.sorted(by: { $0.index < $1.index }) {
                let fieldName = sanitizeIdentifier(field.fieldName, fallback: "field\(field.index)", uppercaseFirst: false)

                // E-006c3: 优先使用 air.struct_type_info 的 elementCount（第三个 i32）判断数组字段。
                // elementCount > 1 说明该字段是数组，直接生成 "typeName fieldName[N]"，
                // 比 IR 交叉检查更直接，覆盖 elementCount > 1 但 IR 字段不是 [N x T] 的边缘情况。
                if field.elementCount > 1 {
                    let elementTypeMSL = knownTypes.contains(field.typeName)
                        ? sanitizeUserTypeName(field.typeName)
                        : field.typeName
                    lines.append("    \(elementTypeMSL) \(fieldName)[\(field.elementCount)];")
                    continue
                }

                // E-006c2: 交叉检查 IR 结构体字段类型与 metadata 类型
                // 当 metadata 声明为标量（如 "float"）但 IR 实际为 [N x T] 数组时，
                // 使用 IR 类型生成正确的 MSL 数组声明
                if let irDef = irTypeDef?.value, field.index < irDef.fieldIRTypes.count {
                    let irFieldType = irDef.fieldIRTypes[field.index].trimmingCharacters(in: .whitespaces)
                    if let arrayField = irArrayTypeToMSLField(irFieldType, fieldName: fieldName) {
                        lines.append("    \(arrayField);")
                        continue
                    }
                }

                let fieldType = knownTypes.contains(field.typeName)
                    ? sanitizeUserTypeName(field.typeName)
                    : field.typeName
                lines.append("    \(fieldType) \(fieldName);")
            }
            lines.append("};")
            lines.append("")
        }

        for rawTypeName in structFieldInfo.keys.sorted() {
            // E-006b9: metal::_atomic 是 MSL 内建 atomic 类型，不需要生成 struct 定义
            if rawTypeName == "metal::_atomic" { continue }
            emitStruct(named: rawTypeName)
        }

        if lines.last == "" {
            lines.removeLast()
        }
        return lines
    }

    private static func generateEntryOutputStructDefinition(
        for func_: ParsedShaderFunction
    ) -> (name: String, definition: String)? {
        guard !func_.outputs.isEmpty else { return nil }
        let expectedStructName = entryOutputStructName(for: func_.name)
        guard func_.returnType == expectedStructName else { return nil }

        let structName = func_.returnType
        var lines: [String] = ["struct \(structName) {"]
        for (index, output) in func_.outputs.enumerated() {
            let fieldType = entryOutputFieldType(for: output, index: index)

            let fallbackName: String
            switch output.kind {
            case "air.position":
                fallbackName = "position"
            case "air.render_target":
                fallbackName = "color\(output.locationIndex ?? index)"
            case "air.vertex_output":
                fallbackName = "varying\(index)"
            case "air.depth":
                fallbackName = "depth"
            default:
                // E-006a2e11: heuristic — detect depth output by arg name
                let nameLC = output.argName.lowercased()
                fallbackName = nameLC.contains("depth") ? "depth" : "field\(index)"
            }
            let fieldName = sanitizeIdentifier(output.argName, fallback: fallbackName, uppercaseFirst: false)

            let attribute: String
            switch output.kind {
            case "air.position":
                attribute = output.qualifiers.contains("air.invariant")
                    ? " [[position, invariant]]"
                    : " [[position]]"
            case "air.render_target":
                attribute = " [[color(\(output.locationIndex ?? 0))]]"
            case "air.depth":
                attribute = " [[depth(any)]]"
            default:
                // E-006a2e11: heuristic — detect depth output by field name
                if fieldName.lowercased().contains("depth") {
                    attribute = " [[depth(any)]]"
                } else {
                    attribute = ""
                }
            }

            lines.append("    \(fieldType) \(fieldName)\(attribute);")
        }
        lines.append("};")
        return (structName, lines.joined(separator: "\n"))
    }

    private static func stageInStructName(for safeName: String) -> String {
        sanitizeTypeName(safeName) + "_StageIn"
    }

    private static func generateStageInStructDefinition(
        for func_: ParsedShaderFunction,
        safeName: String
    ) -> (name: String, definition: String)? {
        guard shouldUseStageInStruct(func_.parameters, shaderType: func_.shaderType) else {
            return nil
        }

        let stageParams = func_.parameters
            .filter { isStageInParameter($0, shaderType: func_.shaderType) }
            .sorted { ($0.irArgIndex ?? .min) < ($1.irArgIndex ?? .min) }
        guard !stageParams.isEmpty else { return nil }

        let structName = stageInStructName(for: safeName)
        var lines: [String] = ["struct \(structName) {"]
        for param in stageParams {
            let fieldType = irScalarTypeToMSL(param.irType.isEmpty ? "float" : param.irType)
            let fieldName = sanitizeIdentifier(param.name, fallback: "arg\(param.irArgIndex ?? 0)", uppercaseFirst: false)

            let attribute: String
            switch param.kind {
            case "air.position":
                attribute = " [[position]]"
            case "air.vertex_input":
                if let location = param.bufferIndex {
                    attribute = " [[attribute(\(location))]]"
                } else {
                    attribute = ""
                }
            default:
                attribute = ""
            }

            lines.append("    \(fieldType) \(fieldName)\(attribute);")
        }
        lines.append("};")
        return (structName, lines.joined(separator: "\n"))
    }

    /// 生成单个 shader 函数的 MSL 代码
    private static func generateFunction(
        _ func_: ParsedShaderFunction,
        safeName: String,
        structTypeDefs: [String: IRStructTypeDef] = [:],
        structFieldInfo: [String: [StructFieldInfo]] = [:]
    ) -> String {
        // 如果有函数体 IR，尝试翻译为真实 MSL 语句（E-004e4a）
        if !func_.irBody.isEmpty {
            return generateFunctionWithBody(
                func_, safeName: safeName,
                structTypeDefs: structTypeDefs,
                structFieldInfo: structFieldInfo
            )
        }
        // 回退到 stub 生成
        return generateStubFunction(func_, safeName: safeName)
    }

    /// 生成带真实函数体的 MSL 代码（E-004e4a）
    private static func generateFunctionWithBody(
        _ func_: ParsedShaderFunction,
        safeName: String,
        structTypeDefs: [String: IRStructTypeDef] = [:],
        structFieldInfo: [String: [StructFieldInfo]] = [:]
    ) -> String {
        let irParamList = extractIRParameterList(from: func_.irSignature)
        let forcedPointerArgIndices = collectArrayIndexedConstantStructBufferArgs(
            params: func_.parameters,
            irParamList: irParamList,
            irBody: func_.irBody
        )

        let allParams = generateAllParams(
            func_.parameters,
            safeName: safeName,
            shaderType: func_.shaderType,
            defaultBuiltin: defaultBuiltinParam(for: func_.shaderType),
            fragmentReturnType: func_.shaderType == .kernel ? "" : func_.returnType,
            forcedPointerArgIndices: forcedPointerArgIndices
        )

        let bodyStatements = translateFunctionBody(
            func_, irParamList: irParamList,
            structTypeDefs: structTypeDefs,
            structFieldInfo: structFieldInfo,
            forcedPointerArgIndices: forcedPointerArgIndices
        )

        let shaderQualifier = func_.isEntryPoint ? func_.shaderType.rawValue : ""
        let retType = func_.shaderType == .kernel ? "void" : func_.returnType

        var lines: [String] = []
        if shaderQualifier.isEmpty {
            lines.append("\(retType) \(safeName)(\(allParams)) {")
        } else {
            lines.append("\(shaderQualifier) \(retType) \(safeName)(\(allParams)) {")
        }
        for stmt in bodyStatements {
            lines.append("    \(stmt)")
        }
        // 确保非 void 函数有返回值
        if retType != "void" && !bodyStatements.contains(where: { $0.hasPrefix("return ") }) {
            lines.append("    return \(defaultReturnValue(for: retType));")
        }
        lines.append("}")
        return lines.joined(separator: "\n")
    }

    /// 生成 stub 函数（回退路径）
    private static func generateStubFunction(
        _ func_: ParsedShaderFunction,
        safeName: String
    ) -> String {
        switch func_.shaderType {
        case .vertex:
            return generateVertexFunction(func_, safeName: safeName)
        case .fragment:
            return generateFragmentFunction(func_, safeName: safeName)
        case .kernel:
            return generateKernelFunction(func_, safeName: safeName)
        case .helper:
            return generateHelperFunction(func_, safeName: safeName)
        }
    }

    /// shader 类型对应的默认内置参数
    private static func defaultBuiltinParam(for type: ShaderType) -> String {
        switch type {
        case .vertex: return "uint vid [[vertex_id]]"
        case .fragment: return ""
        case .kernel: return "uint tid [[thread_position_in_grid]]"
        case .helper: return ""
        }
    }

    /// 生成 vertex shader stub
    private static func generateVertexFunction(
        _ func_: ParsedShaderFunction,
        safeName: String
    ) -> String {
        let allParams = generateAllParams(
            func_.parameters,
            safeName: safeName,
            shaderType: .vertex,
            defaultBuiltin: "uint vid [[vertex_id]]"
        )

        return """
        vertex \(func_.returnType) \(safeName)(\(allParams)) {
            return \(defaultReturnValue(for: func_.returnType));
        }
        """
    }

    /// 生成 fragment shader stub
    private static func generateFragmentFunction(
        _ func_: ParsedShaderFunction,
        safeName: String
    ) -> String {
        let allParams = generateAllParams(
            func_.parameters,
            safeName: safeName,
            shaderType: .fragment,
            defaultBuiltin: "",
            fragmentReturnType: func_.returnType
        )

        return """
        fragment \(func_.returnType) \(safeName)(\(allParams)) {
            return \(defaultReturnValue(for: func_.returnType));
        }
        """
    }

    /// 生成 kernel (compute) shader stub
    private static func generateKernelFunction(
        _ func_: ParsedShaderFunction,
        safeName: String
    ) -> String {
        let allParams = generateAllParams(
            func_.parameters,
            safeName: safeName,
            shaderType: .kernel,
            defaultBuiltin: "uint tid [[thread_position_in_grid]]"
        )

        return """
        kernel void \(safeName)(\(allParams)) {
            // stub kernel
        }
        """
    }

    /// 生成普通 helper 函数 stub
    private static func generateHelperFunction(
        _ func_: ParsedShaderFunction,
        safeName: String
    ) -> String {
        let allParams = generateAllParams(
            func_.parameters,
            safeName: safeName,
            shaderType: .helper,
            defaultBuiltin: ""
        )

        if func_.returnType == "void" {
            return """
            void \(safeName)(\(allParams)) {
                // stub helper
            }
            """
        }

        return """
        \(func_.returnType) \(safeName)(\(allParams)) {
            return \(defaultReturnValue(for: func_.returnType));
        }
        """
    }

    /// 生成完整的参数列表，包括 buffer 参数、texture/sampler 参数和内置属性参数。
    ///
    /// 如果 metadata 提供了精确参数信息，使用它们；否则使用 defaultBuiltin 作为回退。
    private static func generateAllParams(
        _ params: [ParsedParameter],
        safeName: String,
        shaderType: ShaderType,
        defaultBuiltin: String,
        fragmentReturnType: String = "",
        forcedPointerArgIndices: Set<Int> = []
    ) -> String {
        var mslParams: [String] = []
        let usesStageIn = shouldUseStageInStruct(params, shaderType: shaderType)
        var hasEntryInput = usesStageIn
        // E-006b2: fragment shader 中无 attribute 的 value 参数需要 [[color(N)]]
        // 当 fragment 返回非 void 标量/向量类型时，Metal 编译器隐式将返回值绑定到 [[color(0)]]，
        // 此时输入 value 参数的 color index 必须从 1 开始以避免冲突。
        var colorInputIdx: Int
        if shaderType == .fragment && fragmentReturnType != "void" && fragmentReturnType != "" {
            colorInputIdx = 1
        } else {
            colorInputIdx = 0
        }

        let stageInType = usesStageIn ? stageInStructName(for: safeName) : ""
        var didEmitStageInParam = false

        for param in params {
            if usesStageIn && isStageInParameter(param, shaderType: shaderType) {
                if !didEmitStageInParam {
                    mslParams.append("\(stageInType) \(stageInParamName) [[stage_in]]")
                    didEmitStageInParam = true
                }
                continue
            }

            let emittedName = sanitizeIdentifier(
                param.name,
                fallback: "arg\(param.irArgIndex ?? 0)",
                uppercaseFirst: false
            )

            // 有 pointerInfo 的是 buffer/threadgroup 参数
            if let ptr = param.pointerInfo {
                let qualifier = ptr.addressSpace.mslQualifier
                guard !qualifier.isEmpty else { continue }

                let elemType = ptr.pointedMSLType
                let constPrefix = ptr.addressSpace.isReadOnly ? "const " : ""
                let restrictPrefix = param.hasNoAlias ? "__restrict " : ""

                if ptr.addressSpace.isBufferAddressSpace {
                    let idx = param.bufferIndex ?? 0
                    // E-006b9: atomic 类型在 MSL 中是引用类型，使用 & 而非 *
                    let isAtomicType = elemType.hasPrefix("atomic_")
                    let shouldKeepReference = isStructTypeName(elemType) &&
                        ptr.addressSpace == .constant &&
                        !isAtomicType &&
                        !forcedPointerArgIndices.contains(param.irArgIndex ?? -1)
                    if shouldKeepReference {
                        // 仅当 IR 没把它当数组/指针根使用时，constant struct 才保留 `constant Uniforms& uniforms` 形式。
                        mslParams.append("\(constPrefix)\(qualifier) \(elemType)& \(restrictPrefix)\(emittedName) [[buffer(\(idx))]]")
                    } else if isAtomicType {
                        // MSL 中 atomic 类型作为 buffer 参数使用引用: device atomic_uint& counter
                        mslParams.append("\(qualifier) \(elemType)& \(restrictPrefix)\(emittedName) [[buffer(\(idx))]]")
                    } else {
                        mslParams.append("\(constPrefix)\(qualifier) \(elemType)* \(restrictPrefix)\(emittedName) [[buffer(\(idx))]]")
                    }
                } else if ptr.addressSpace.isThreadgroupAddressSpace {
                    let idx = param.bufferIndex ?? 0
                    mslParams.append("threadgroup \(elemType)* \(emittedName) [[threadgroup(\(idx))]]")
                } else {
                    mslParams.append("\(qualifier) \(elemType)* \(emittedName)")
                }
                continue
            }

            // 有 attribute 的是内置属性 或 texture/sampler
            if let attr = param.attribute {
                let rawTypeName = param.irType.isEmpty ? "uint" : param.irType.replacingOccurrences(of: "\"", with: "")

                if attr.hasPrefix("[[texture(") || rawTypeName.hasPrefix("texture") {
                    let cleanedTexType = cleanTextureTypeName(rawTypeName)
                    mslParams.append("\(cleanedTexType) \(emittedName) \(attr)")
                } else if attr.hasPrefix("[[sampler(") || rawTypeName == "sampler" {
                    mslParams.append("sampler \(emittedName) \(attr)")
                } else {
                    hasEntryInput = true
                    let emittedType = irScalarTypeToMSL(rawTypeName)
                    mslParams.append("\(emittedType) \(emittedName) \(attr)")
                }
                continue
            }

            if param.emitAsValueParameter {
                let rawTypeName = param.irType.isEmpty ? "float" : param.irType.replacingOccurrences(of: "\"", with: "")
                let emittedType = irScalarTypeToMSL(rawTypeName)
                // E-006b2: fragment shader 的 value 参数必须带 [[color(N)]]，否则 Metal 编译器报
                // "invalid implicit color input declarations"
                let colorAttr: String
                if shaderType == .fragment {
                    colorAttr = " [[color(\(colorInputIdx))]]"
                    colorInputIdx += 1
                    hasEntryInput = true
                } else {
                    colorAttr = ""
                }
                mslParams.append("\(emittedType) \(emittedName)\(colorAttr)")
                continue
            }

            // 回退：有地址空间但没有详细信息
            if let addrSpace = param.addressSpace {
                let qualifier = addrSpace.mslQualifier
                if qualifier.isEmpty { continue }
                let idx = param.bufferIndex ?? 0
                let constPrefix = addrSpace.isReadOnly ? "const " : ""
                let restrictPrefix = param.hasNoAlias ? "__restrict " : ""
                if addrSpace.isBufferAddressSpace {
                    mslParams.append("\(constPrefix)\(qualifier) uint8_t* \(restrictPrefix)\(emittedName) [[buffer(\(idx))]]")
                } else if addrSpace.isThreadgroupAddressSpace {
                    mslParams.append("threadgroup uint8_t* \(emittedName) [[threadgroup(\(idx))]]")
                }
            }
        }

        // 如果没有从 metadata 获取入口输入参数，添加默认的 builtin。
        if !hasEntryInput && !defaultBuiltin.isEmpty {
            mslParams.insert(defaultBuiltin, at: 0)
        }

        return mslParams.joined(separator: ", ")
    }

    /// 判断类型名是否像是用户定义结构体。
    ///
    /// 这里不能只看首字母是否大写：真实 shader 中常见的 constant buffer 结构体名还会出现
    /// `_ScreenSpaceShadowParams_Type`、`cb_SSAOBlur_Type` 这类前导下划线 / 小写前缀形式。
    /// 只要它不是 MSL 标量/向量/纹理等内建类型，且呈现典型用户类型命名特征，
    /// 都应视为结构体，以便在 constant buffer 上优先保留 `const constant T&`，
    /// 让 round-trip 后的 AIR 继续保留 `dereferenceable(N)`。
    private static func isStructTypeName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard !isMSLScalarOrVectorType(trimmed) else { return false }
        guard trimmed != "sampler", !trimmed.hasPrefix("texture"), !trimmed.hasPrefix("atomic_") else {
            return false
        }
        if trimmed.hasSuffix("_Type") {
            return true
        }
        guard let firstLetter = trimmed.first(where: { $0.isLetter }) else { return false }
        return firstLetter.isUppercase
    }

    /// 清理 texture 类型名，将 AIR access 限定符映射为 Metal 格式
    /// "texture2d<float, sample>"      → "texture2d<float>"          (默认，省略)
    /// "texture2d<float, read>"       → "texture2d<float, access::read>"
    /// "texture2d<float, write>"      → "texture2d<float, access::write>"
    /// "texture2d<float, read_write>" → "texture2d<float, access::read_write>"
    private static func cleanTextureTypeName(_ name: String) -> String {
        let normalizedName = name.replacingOccurrences(of: "\"", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let ltIdx = normalizedName.firstIndex(of: "<"),
              let gtIdx = normalizedName.lastIndex(of: ">") else {
            return normalizedName
        }
        let innerContent = normalizedName[normalizedName.index(after: ltIdx)..<gtIdx]
        let parts = innerContent.components(separatedBy: ",")
        let elemType = parts[0].trimmingCharacters(in: .whitespaces)
        let prefix = String(normalizedName[normalizedName.startIndex...ltIdx])
        if parts.count > 1 {
            let access = parts[1].trimmingCharacters(in: .whitespaces)
            switch access {
            case "sample":
                // 默认 access，省略
                return "\(prefix)\(elemType)>"
            case "read":
                return "\(prefix)\(elemType), access::read>"
            case "write":
                return "\(prefix)\(elemType), access::write>"
            case "read_write":
                return "\(prefix)\(elemType), access::read_write>"
            default:
                // 未知 access 限定符，原样保留
                return "\(prefix)\(elemType), \(access)>"
            }
        }
        return normalizedName
    }

    /// 生成给定类型的默认返回值
    private static func defaultReturnValue(for mslType: String) -> String {
        if mslType == "void" { return "" }
        if mslType == "float4" { return "float4(0.0)" }
        if mslType == "float3" { return "float3(0.0)" }
        if mslType == "float2" { return "float2(0.0)" }
        if mslType == "half4" { return "half4(0.0h)" }
        if mslType == "float" { return "0.0" }
        if mslType == "half" { return "0.0h" }
        if mslType == "int" { return "0" }
        if mslType == "uint" { return "0u" }
        if mslType == "bool" { return "false" }
        // 对于未知的复合类型，返回空初始化
        return "\(mslType)()"
    }

    /// 将函数名清理为合法的 MSL 标识符
    private static func sanitizeFunctionName(_ name: String) -> String {
        // MSL 函数名只能包含字母、数字、下划线
        var result = ""
        for char in name {
            if char.isLetter || char.isNumber || char == "_" {
                result.append(char)
            } else {
                result.append("_")
            }
        }
        // 确保不以数字开头
        if let first = result.first, first.isNumber {
            result = "_" + result
        }
        return result.isEmpty ? "_unnamed" : result
    }
}
