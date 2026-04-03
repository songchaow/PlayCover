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

        /// 生成该参数的 MSL 声明字符串
        var mslDeclaration: String? {
            // 有指针信息时生成精确声明
            if let ptr = pointerInfo {
                let qualifier = ptr.addressSpace.mslQualifier
                guard !qualifier.isEmpty else { return nil }

                let elemType = ptr.pointedMSLType
                let constPrefix = ptr.addressSpace.isReadOnly ? "const " : ""

                if ptr.addressSpace.isBufferAddressSpace {
                    let idx = bufferIndex ?? 0
                    return "\(constPrefix)\(qualifier) \(elemType)* \(name) [[buffer(\(idx))]]"
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

    /// 从 IR 中解析出的 shader 函数
    struct ParsedShaderFunction {
        let name: String
        let shaderType: ShaderType
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
            ("round", "round"), ("trunc", "trunc"), ("fract", "fract"),
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

    /// 从 air.convert 函数名中解析转换的目标 MSL 类型。
    ///
    /// 命名规则：`air.convert.<dst_kind>.<dst_type>.<src_kind>.<src_type>`
    /// - kind: f=float, s=signed, u=unsigned
    /// - type: v4f32, v4i32, f32, i32, v4f16 等
    ///
    /// 示例：
    /// - `air.convert.f.v4f32.s.v4i32` → `float4` (int4 → float4)
    /// - `air.convert.s.v4i32.f.v4f32` → `int4` (float4 → int4)
    /// - `air.convert.f.v4f16.f.v4f32` → `half4` (float4 → half4)
    static func parseAirConvertTargetType(_ airFuncName: String) -> String? {
        // 去掉 "air.convert." 前缀
        guard airFuncName.hasPrefix("air.convert.") else { return nil }
        let rest = String(airFuncName.dropFirst("air.convert.".count))
        let parts = rest.components(separatedBy: ".")
        // parts[0] = dst_kind (f/s/u), parts[1] = dst_type (v4f32, i32, etc.)
        guard parts.count >= 2 else { return nil }

        let dstType = parts[1]
        return airTypeSuffixToMSL(dstType)
    }

    /// 将 air 类型后缀转换为 MSL 类型名。
    ///
    /// - `v4f32` → `float4`, `v3f32` → `float3`, `v2f32` → `float2`
    /// - `v4f16` → `half4`, `v4i32` → `int4`, `v2i32` → `int2`
    /// - `f32` → `float`, `f16` → `half`, `i32` → `int`, `i16` → `short`
    /// - `vNi8` → `ucharN` (E-006a2e12: MSL 不支持 uint8_tN)
    static func airTypeSuffixToMSL(_ suffix: String) -> String {
        // 向量类型：vNtBB → typeN (如 v4f32 → float4)
        if suffix.hasPrefix("v") {
            let chars = Array(suffix.dropFirst())
            // 提取维度数字
            var i = 0
            while i < chars.count && chars[i].isNumber { i += 1 }
            let dim = String(chars[0..<i])
            let scalarSuffix = String(chars[i...])
            // E-006a2e12: i8/u8 向量特殊处理 — MSL 不支持 uint8_tN，必须用 ucharN
            if scalarSuffix == "i8" || scalarSuffix == "u8" {
                return "uchar\(dim)"
            }
            let scalarMSL = airScalarSuffixToMSL(scalarSuffix)
            return "\(scalarMSL)\(dim)"
        }
        // 标量类型
        return airScalarSuffixToMSL(suffix)
    }

    /// 将 air 标量类型后缀转换为 MSL 标量类型
    private static func airScalarSuffixToMSL(_ suffix: String) -> String {
        switch suffix {
        case "f32": return "float"
        case "f16": return "half"
        case "f64": return "float"  // MSL 不支持 double
        case "i1": return "bool"
        case "i8": return "uint8_t"
        case "i16": return "short"
        case "i32": return "int"
        case "i64": return "long"
        case "u8": return "uint8_t"
        case "u16": return "ushort"
        case "u32": return "uint"
        case "u64": return "ulong"
        default: return suffix
        }
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
        /// "air.thread_position_in_grid" 等
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
    /// 格式: !{ptr @test_vertex, !10, !14}
    /// - 第一个元素: 函数指针 (ptr @name)
    /// - 第二个元素: 返回值描述引用
    /// - 第三个元素: 参数列表引用
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

        // 找到返回/参数列表引用。
        // `parseMetadataRefList(...)` 只会返回 `!N` 引用，不会把开头的 `ptr @func` 算进去；
        // 因此这里的 refs 实际是 `[返回描述引用, 参数列表引用]`。
        let refs = parseMetadataRefList(content)
        guard refs.count >= 2 else {
            return MetadataFuncInfo(name: funcName, shaderType: shaderType, returns: [], args: [])
        }

        let returns: [MetadataReturnInfo]
        if let returnsContent = nodes[refs[0]] {
            returns = parseMetadataReturnListNode(returnsContent, nodes: nodes)
        } else {
            returns = []
        }

        let argsNodeId = refs[1]
        guard let argsContent = nodes[argsNodeId] else {
            return MetadataFuncInfo(name: funcName, shaderType: shaderType, returns: returns, args: [])
        }

        // 解析参数列表: !{!15, !16, !17, !18, !20, !21}
        let argNodeIds = parseMetadataRefList(argsContent)
        var args: [MetadataArgInfo] = []

        for argNodeId in argNodeIds {
            guard let argContent = nodes[argNodeId] else { continue }
            if let argInfo = parseMetadataArgNode(argContent) {
                args.append(argInfo)
            }
        }

        return MetadataFuncInfo(name: funcName, shaderType: shaderType, returns: returns, args: args)
    }

    private static func parseMetadataReturnListNode(
        _ content: String,
        nodes: [String: String]
    ) -> [MetadataReturnInfo] {
        let returnNodeIds = parseMetadataRefList(content)
        var returns: [MetadataReturnInfo] = []
        for returnNodeId in returnNodeIds {
            guard let returnContent = nodes[returnNodeId] else { continue }
            if let returnInfo = parseMetadataReturnNode(returnContent) {
                returns.append(returnInfo)
            }
        }
        return returns
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
            locationIndex: locationIndex
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

        // 每个字段由 5 个 token 组成: i32 offset, i32 size, i32 align, !"typeName", !"fieldName"
        while i + 4 < tokens.count {
            let offset = parseMetadataInt(tokens[i]) ?? 0
            let size = parseMetadataInt(tokens[i + 1]) ?? 0
            // tokens[i+2] = alignment (跳过)
            let typeName = unquoteMetadataString(tokens[i + 3])
            let fieldName = unquoteMetadataString(tokens[i + 4])

            fields.append(StructFieldInfo(
                index: fieldIndex,
                typeName: typeName,
                fieldName: fieldName,
                offset: offset,
                size: size
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
            airBuiltinCalls: allAirCalls
        )

        // 5. 生成 MSL 源码（传入结构体信息用于 GEP/extractvalue/insertvalue）
        let mslSource = generateMSL(
            functions: shaderFunctions,
            structTypeDefs: structTypeDefs,
            structFieldInfo: structFieldInfo
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
        for cc in ["spir_func ", "spir_kernel ", "cc75 ", "cc76 ", "cc77 "] {
            cleaned = cleaned.replacingOccurrences(of: cc, with: "")
        }

        return cleaned.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Shader Function Identification

    /// 结合 IR 函数定义、metallib 元数据和 IR metadata，识别 shader 函数并推断其类型。
    private static func identifyShaderFunctions(
        irFunctions: [IRFunctionDef],
        metallibNames: [String],
        metallibTypes: [String],
        metadataFuncs: [MetadataFuncInfo] = [],
        airBuiltinCalls: [AirBuiltinCall] = []
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

        var shaderFunctions: [ParsedShaderFunction] = []

        for irFunc in irFunctions {
            // 跳过 LLVM 内部函数和 air 运行时函数
            if irFunc.name.hasPrefix("llvm.") { continue }

            // 判断是否是 shader 入口函数
            let shaderType: ShaderType?

            // 优先使用 IR metadata（最可靠的来源）
            if let metaInfo = metadataMap[irFunc.name] {
                shaderType = metaInfo.shaderType
            }
            // 其次使用 metallib 元数据中的类型信息
            else if let type = nameToType[irFunc.name] {
                shaderType = type
            } else if irFunc.name.contains("vertex") || irFunc.attributes.contains("vertex") {
                shaderType = .vertex
            } else if irFunc.name.contains("fragment") || irFunc.attributes.contains("fragment") {
                shaderType = .fragment
            } else if irFunc.name.contains("kernel") || irFunc.attributes.contains("kernel") {
                shaderType = .kernel
            } else if metallibNames.contains(irFunc.name) {
                shaderType = .vertex
            } else if irFunc.name.hasPrefix("air.") {
                continue
            } else {
                if !metallibNames.isEmpty && metadataMap.isEmpty { continue }
                shaderType = inferShaderType(from: irFunc)
            }

            guard let type = shaderType else { continue }

            // 解析参数：优先使用 metadata 信息
            let params: [ParsedParameter]
            let outputs: [MetadataReturnInfo]
            let isFullyParsed: Bool
            if let metaInfo = metadataMap[irFunc.name] {
                params = buildParametersFromMetadata(metaInfo.args, irParamList: irFunc.parameterList)
                outputs = metaInfo.returns
                isFullyParsed = true
            } else {
                params = parseParameters(irFunc.parameterList, shaderType: type)
                outputs = []
                isFullyParsed = false
            }

            // 推断 MSL 返回类型
            let mslReturnType = deriveEntryReturnType(
                irReturnType: irFunc.returnType,
                shaderType: type,
                outputs: outputs,
                functionName: irFunc.name
            )

            shaderFunctions.append(ParsedShaderFunction(
                name: irFunc.name,
                shaderType: type,
                returnType: mslReturnType,
                outputs: outputs,
                parameters: params,
                irSignature: "define \(irFunc.returnType) @\"\(irFunc.name)\"(\(irFunc.parameterList))",
                isFullyParsed: isFullyParsed,
                airBuiltinCalls: airBuiltinCalls,
                irBody: irFunc.body
            ))
        }

        // 如果 IR 中没找到匹配的函数，为 metallib 中的每个函数生成 stub
        if shaderFunctions.isEmpty && !metallibNames.isEmpty {
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

                shaderFunctions.append(ParsedShaderFunction(
                    name: name,
                    shaderType: type,
                    returnType: defaultReturnType(for: type),
                    outputs: [],
                    parameters: [],
                    irSignature: "(metallib-only, no IR match)",
                    isFullyParsed: false,
                    airBuiltinCalls: [],
                    irBody: ""
                ))
            }
        }

        return shaderFunctions
    }

    private static func deriveEntryReturnType(
        irReturnType: String,
        shaderType: ShaderType,
        outputs: [MetadataReturnInfo],
        functionName: String
    ) -> String {
        guard shaderType != .kernel else { return "void" }

        if outputs.count > 1 {
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

    private static func entryOutputStructName(for functionName: String) -> String {
        sanitizeTypeName(functionName) + "_Out"
    }

    /// 从 IR metadata 参数信息构建 ParsedParameter 列表。
    ///
    /// metadata 提供了精确的 MSL 类型名、参数名、绑定索引和地址空间，
    /// 比从 opaque pointer 参数推断要准确得多。
    private static func buildParametersFromMetadata(
        _ metaArgs: [MetadataArgInfo],
        irParamList: String
    ) -> [ParsedParameter] {
        _ = irParamList
        var params: [ParsedParameter] = []

        for meta in metaArgs {
            let addrSpace: AddressSpace?
            if let as_ = meta.addressSpace {
                addrSpace = AddressSpace(rawValue: as_)
            } else {
                addrSpace = nil
            }

            // 根据参数种类确定 attribute 和 pointerInfo
            let attribute: String?
            let ptrInfo: PointerInfo?

            switch meta.kind {
            case "air.buffer":
                attribute = nil
                let space = addrSpace ?? .device
                ptrInfo = PointerInfo(
                    addressSpace: space,
                    pointedMSLType: meta.typeName.isEmpty ? "uint8_t" : meta.typeName,
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
                kind: meta.kind
            ))
        }

        return params
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
        shaderType: ShaderType
    ) -> [ParsedParameter] {
        guard !paramList.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }

        let rawParams = splitIRParameters(paramList)
        var params: [ParsedParameter] = []
        var bufferIdx = 0
        var threadgroupIdx = 0

        for (index, rawParam) in rawParams.enumerated() {
            let trimmed = rawParam.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed == "..." { continue }

            // 提取地址空间
            let addrSpace = extractAddressSpace(from: trimmed)

            // 提取参数名（%name 或 %N）
            let paramName = extractParamName(from: trimmed) ?? "param\(index)"

            // 提取指针信息
            let ptrInfo = extractPointerInfo(from: trimmed, addressSpace: addrSpace)

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
                irType: trimmed,
                addressSpace: addrSpace,
                bufferIndex: bindingIndex,
                attribute: nil,
                pointerInfo: ptrInfo,
                irArgIndex: index,
                kind: nil
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
            if char == "<" || char == "{" || char == "(" { depth += 1 }
            else if char == ">" || char == "}" || char == ")" { depth -= 1 }

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
    /// 处理 IR 中出现的所有基本类型：
    /// - 整数: i1→bool, i8→char/uint8_t, i16→short, i32→int, i64→long
    /// - 浮点: half, float, double
    /// - 向量: <4 x float>→float4, <2 x i32>→int2
    /// - 结构体名: %struct.X→X
    static func irScalarTypeToMSL(_ irType: String) -> String {
        let cleaned = irType.trimmingCharacters(in: .whitespaces)

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
            return sanitizeTypeName(structName)
        }
        if cleaned.hasPrefix("%") {
            let typeName = String(cleaned.dropFirst())
                .replacingOccurrences(of: "\"", with: "")
            return sanitizeTypeName(typeName)
        }

        // 指针类型 → void* 等效
        if cleaned.contains("*") || cleaned == "ptr" {
            return "uint8_t"
        }

        return cleaned.isEmpty ? "uint8_t" : cleaned
    }

    /// 将类型名清理为合法的 MSL 标识符
    private static func sanitizeTypeName(_ name: String) -> String {
        sanitizeIdentifier(name, fallback: "UnknownType", uppercaseFirst: true)
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
        /// 下一个临时变量编号
        var nextTemp: Int = 0
        /// 函数参数名映射（IR 参数 %N → MSL 参数名）
        var paramNames: [String: String] = [:]
        /// 函数参数类型映射
        var paramTypes: [String: String] = [:]
        /// 当前函数的 MSL 返回类型
        var functionReturnType: String = ""
        /// 指针值集合（IR 参数/GEP/alloca 等会产出“地址”语义的 SSA）
        var pointerValues: Set<String> = []

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

        func markPointer(_ ssaName: String) {
            pointerValues.insert(ssaName.trimmingCharacters(in: .whitespaces))
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
            statements.append(stmt)
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
        structFieldInfo: [String: [StructFieldInfo]] = [:]
    ) -> [String] {
        let ctx = SSAContext()
        ctx.functionReturnType = func_.returnType
        // E-004e4c: 传入结构体信息供 extractvalue/insertvalue/GEP 使用
        ctx.structTypeDefs = structTypeDefs
        ctx.structFieldInfo = structFieldInfo

        // 建立参数名映射：IR 的 %0, %1, ... → MSL 参数名
        setupParameterMappings(ctx, params: func_.parameters, irParamList: irParamList, shaderType: func_.shaderType)

        let bodyLines = func_.irBody.components(separatedBy: "\n")

        // ── 第一遍：预扫描 phi 节点和 CFG 结构 (E-004e4b) ──
        prescanPhiAndCFG(bodyLines, ctx: ctx)

        // 发射 phi 变量预声明（在函数体最前面）
        for decl in ctx.phiDeclarations {
            ctx.emit(decl)
        }

        // ── 第二遍：逐行翻译函数体 ──
        for line in bodyLines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            // 基本块标签（纯名字:）
            if trimmed.hasSuffix(":") && !trimmed.contains(" ") {
                ctx.currentBBLabel = String(trimmed.dropLast())
                ctx.emit("// BB: \(trimmed)")
                // 发射 phi 赋值（当前 BB 的 phi 节点从各前驱来的值，
                // 由 translateBr 在前驱 BB 处理）
                continue
            }
            // 带前驱注释的基本块标签: "10:  ; preds = %7"
            if let colonIdx = trimmed.firstIndex(of: ":"),
               trimmed[trimmed.startIndex..<colonIdx].allSatisfy({ $0.isNumber || $0.isLetter || $0 == "_" }) {
                let labelCandidate = String(trimmed[trimmed.startIndex..<colonIdx])
                // 确保冒号后面是空格或分号（注释），不是 IR 指令
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

        return ctx.statements
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
        shaderType: ShaderType
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
                let emitsReference = ptr.addressSpace == .constant && ptr.addressSpace.isBufferAddressSpace && isStructTypeName(ptr.pointedMSLType)
                if !emitsReference {
                    ctx.markPointer(ssaName)
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
        case .kernel:
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
        case .kernel:
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
        // select <cond_type> <cond>, <type> <val_true>, <type> <val_false>
        let cleaned = rhs.replacingOccurrences(of: "select ", with: "")
        let selectParts = splitSelectOperands(cleaned)
        guard selectParts.count >= 3 else {
            ctx.define(lhs, expr: "/* select parse error */")
            return
        }
        let cond = resolveIROperand(selectParts[0], ctx: ctx)
        let valTrue = resolveIROperand(selectParts[1], ctx: ctx)
        let valFalse = resolveIROperand(selectParts[2], ctx: ctx)
        ctx.emitAutoAssign(lhs, expr: "\(cond) ? \(valTrue) : \(valFalse)")
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
            let srcType = shuffleParts[0].type
            let outType = vectorTypeWithDim(srcType, dim: resultDim)
            let mslType = irScalarTypeToMSL(outType)
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

        let temp = ctx.freshTemp()
        let mslType = irScalarTypeToMSL(parts[0].type)
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
        let fieldCount = countAggregateFields(trimmedType)

        // 判断是否为 undef 基础（链的起点）
        let isUndef = aggValue.trimmingCharacters(in: .whitespaces) == "undef" ||
                      aggValue.trimmingCharacters(in: .whitespaces) == "poison"

        if isUndef {
            // 链起点：记录已知的第一个字段
            var fields = Array(repeating: "0", count: max(fieldCount, fieldIdx + 1))
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
                fields = Array(repeating: "0", count: max(fieldCount, fieldIdx + 1))
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
        var body = type.trimmingCharacters(in: .whitespaces)
        // 去掉 packed struct 外层 <{ }>
        if body.hasPrefix("<{") && body.hasSuffix("}>") {
            body = String(body.dropFirst(2).dropLast(2))
        } else if body.hasPrefix("{") && body.hasSuffix("}") {
            body = String(body.dropFirst().dropLast())
        } else {
            return 0  // 不是聚合类型
        }
        return splitIRParameters(body).filter {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }.count
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
        let ptr = resolveIROperand(parts[1].value, ctx: ctx)
        let mslType = irScalarTypeToMSL(loadType)
        let loadExpr = lvalueExpression(from: ptr) ?? "*(\(ptr))"
        ctx.emitAutoAssign(lhs, expr: loadExpr, knownType: mslType)
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
        let val = resolveIROperand(parts[0].value, ctx: ctx)
        let ptr = resolveIROperand(parts[1].value, ctx: ctx)
        let targetExpr = lvalueExpression(from: ptr) ?? "*(\(ptr))"
        ctx.emit("\(targetExpr) = \(val);")
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
                ctx.markPointer(lhs)
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
            ctx.markPointer(lhs)
            return
        }

        // 多级索引：parts[2] 是基指针偏移（数组索引），parts[3..] 是类型层级索引
        let firstIdx = resolveIROperand(parts[2].value, ctx: ctx)

        // 构建表达式。对真正的指针参数先落到合法的下标/解引用语义；
        // 对 constant struct 引用等“值语义入口”则保留原表达式，避免误发射 `ptr.field`。
        var expr: String
        if baseIsPointerLike {
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
                    // 向量类型 → 直接 subscript（MSL 支持向量下标）
                    expr = "\(expr)[\(resolvedIdx)]"
                } else if !currentType.isEmpty && !currentType.hasPrefix("ptr") {
                    // E-006a2e14: 标量类型 subscript（float, half, i32 等）
                    // IR GEP with opaque pointer 允许对 scalar field 做 array-like index
                    // （将 scalar 地址视为数组首元素地址），但 MSL 不允许 scalar subscript
                    // Fix: 取字段地址放入 temp 变量，然后通过 pointer subscript
                    let ptrTemp = ctx.freshTemp()
                    ctx.emit("auto \(ptrTemp) = &(\(expr));")
                    // 后续剩余索引也做 pointer offset 累加
                    // （after scalar type, remaining indices are all scalar arithmetic）
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
                    currentType = ""
                    break
                } else {
                    expr = "\(expr)[\(resolvedIdx)]"
                }
                currentType = ""
            }
        }

        ctx.define(lhs, expr: addressExpression(for: expr))
        ctx.markPointer(lhs)
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
        // 其他函数调用（包括 @llvm.* 等）
        ctx.define(lhs, expr: "/* call: \(rhs.prefix(80)) */")
    }

    /// 已知的 ___metal_* intrinsic 映射到 MSL 函数名
    /// 命名规则：___metal_<msl_name>[_<type_suffix>]
    /// 例如：___metal_fract_v2float → fract(), ___metal_fast_sin_v4f32 → fast_sin()
    /// mslArgCount: MSL 函数期望的参数数量（IR intrinsic 可能有额外元数据参数）
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
            list.append(("___metal_fast_\(name)", "fast_\(name)", 1))
        }
        let binaryMath = [
            "fmin", "fmax", "pow", "fmod", "atan2", "copysign", "fdim", "step",
            "min", "max",
        ]
        for name in binaryMath {
            list.append(("___metal_\(name)", name, 2))
            list.append(("___metal_fast_\(name)", "fast_\(name)", 2))
        }
        let ternaryMath = ["clamp", "mix", "smoothstep", "fma"]
        for name in ternaryMath {
            list.append(("___metal_\(name)", name, 3))
            list.append(("___metal_fast_\(name)", "fast_\(name)", 3))
        }
        let unaryVec = ["length", "normalize"]
        for name in unaryVec {
            list.append(("___metal_\(name)", name, 1))
            list.append(("___metal_fast_\(name)", "fast_\(name)", 1))
        }
        let binaryVec = ["dot", "cross", "distance", "reflect"]
        for name in binaryVec {
            list.append(("___metal_\(name)", name, 2))
            list.append(("___metal_fast_\(name)", "fast_\(name)", 2))
        }
        let ternaryVec = ["refract", "faceforward"]
        for name in ternaryVec {
            list.append(("___metal_\(name)", name, 3))
            list.append(("___metal_fast_\(name)", "fast_\(name)", 3))
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
        // 例如：fract_v2float → fract(1), fast_sin_v4f32 → fast_sin(1)
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
    /// 支持：___metal_fract_v2float → (fract, 1), ___metal_fast_sin_v4f32 → (fast_sin, 1)
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
            let targetType = parseAirConvertTargetType(airName) ?? "float"
            let srcArg = args.first ?? "0"
            return "\(targetType)(\(srcArg))"
        }

        // 纹理方法调用: tex.sample(sampler, coord, ...)
        if mapping.isMethodCall {
            if args.count >= 2 {
                let obj = args[0]
                let methodArgs = Array(args.dropFirst())
                let methodArgTypes = Array(argTypes.dropFirst())
                let filtered = filterTextureArgs(methodArgs, argTypes: methodArgTypes)
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
            ctx.emit("return;")
            return
        }
        // ret <type> <value>
        let parts = splitTypedOperands(cleaned, count: 1)
        if let first = parts.first {
            let val = resolveIROperand(first.value, ctx: ctx)
            if val.trimmingCharacters(in: .whitespaces).hasPrefix("{"),
               !ctx.functionReturnType.isEmpty,
               ctx.functionReturnType != "void" {
                ctx.emit("return \(ctx.functionReturnType)\(val);")
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
                ctx.emit("    // → BB\(trueLabel)")
                ctx.emit("} else {")
                ctx.emit("    // → BB\(falseLabel)")
                ctx.emit("}")
            } else {
                // 有 phi 赋值：生成包含赋值的 if/else
                ctx.emit("if (\(cond)) {")
                for assign in truePhiAssigns {
                    ctx.emit("    \(assign)")
                }
                if truePhiAssigns.isEmpty {
                    ctx.emit("    // → BB\(trueLabel)")
                }
                ctx.emit("} else {")
                for assign in falsePhiAssigns {
                    ctx.emit("    \(assign)")
                }
                if falsePhiAssigns.isEmpty {
                    ctx.emit("    // → BB\(falseLabel)")
                }
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

        // E-006a2e10 → E-006a2e13: 全局 IR symbols (@...) 不应出现在 MSL 中
        // @__air_sampler_state 等 AIR 内部 symbol 需映射到对应的 MSL sampler 参数
        if s.hasPrefix("@") {
            // 尝试映射到 sampler 参数
            // 优先匹配 addrspace(2)（typed pointer 模式），
            // fallback 匹配 MSL 属性为 [[sampler(N)]] 的参数（opaque pointer 模式）
            for (irParam, mslName) in ctx.paramNames {
                if let irType = ctx.paramTypes[irParam],
                   irType.contains("addrspace(2)") {
                    return mslName
                }
            }
            // Opaque pointer fallback：查找 MSL 属性包含 sampler 的参数
            for (irParam, mslName) in ctx.paramNames {
                if mslName.contains("sampler") {
                    return mslName
                }
            }
            // 未识别的全局 symbol — 不应泄漏到 MSL，返回空由调用方过滤
            return ""
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

        if exponent == 0 && mantissa == 0 {
            // ±zero — 返回 0.0（上下文类型决定 half/float）
            return "0.0"
        }

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
        if floatValue == 0.0 { return "0.0" }
        if floatValue == 1.0 { return "1.0" }
        if floatValue == -1.0 { return "-1.0" }
        if floatValue == 0.5 { return "0.5" }
        if floatValue == -0.5 { return "-0.5" }
        if floatValue == 2.0 { return "2.0" }
        if floatValue == -2.0 { return "-2.0" }

        // 一般值: 输出十进制浮点（MSL 上下文自动匹配 half 类型）
        return String(format: "%.6g", Double(floatValue))
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

    /// 过滤纹理 air 调用的内部控制参数，只保留用户可见参数
    /// 返回 (filtered_args, filtered_types) 元组，保留类型信息供 bias/level 包装使用
    private static func filterTextureArgs(_ args: [String], argTypes: [String]) -> (args: [String], types: [String]) {
        var resultArgs: [String] = []
        var resultTypes: [String] = []
        for (i, arg) in args.enumerated() {
            let type = i < argTypes.count ? argTypes[i] : ""
            // E-006a2e10: 跳过未解析的全局 symbol（resolveIROperand 对 @ 符号返回空）
            if arg.isEmpty { continue }
            // 跳过 i1 (bool 控制标志) 和 i32 控制参数（但保留坐标/颜色）
            if type == "i1" { continue }
            // 跳过零值 i32 控制标志（如 mip level=0, slice=0）
            if type == "i32" && (arg == "0" || arg == "1" || arg == "2") {
                continue
            }
            // 跳过 <N x i32> zeroinitializer（offset 参数）
            if arg == "0" && type.contains("x i32") { continue }
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
        structFieldInfo: [String: [StructFieldInfo]] = [:]
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

        if functions.isEmpty {
            lines.append("// No shader functions found in IR")
            return lines.joined(separator: "\n")
        }

        let userStructDefinitions = generateUserStructDefinitions(structFieldInfo)
        if !userStructDefinitions.isEmpty {
            lines.append(contentsOf: userStructDefinitions)
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
            if !func_.isFullyParsed {
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
        _ structFieldInfo: [String: [StructFieldInfo]]
    ) -> [String] {
        guard !structFieldInfo.isEmpty else { return [] }

        let knownTypes = Set(structFieldInfo.keys)
        var emitted: Set<String> = []
        var lines: [String] = []

        func emitStruct(named rawTypeName: String) {
            let sanitizedTypeName = sanitizeTypeName(rawTypeName)
            guard emitted.insert(sanitizedTypeName).inserted else { return }
            guard let fields = structFieldInfo[rawTypeName], !fields.isEmpty else { return }

            for field in fields {
                if knownTypes.contains(field.typeName) {
                    emitStruct(named: field.typeName)
                }
            }

            lines.append("struct \(sanitizedTypeName) {")
            for field in fields.sorted(by: { $0.index < $1.index }) {
                let fieldType = knownTypes.contains(field.typeName)
                    ? sanitizeTypeName(field.typeName)
                    : field.typeName
                let fieldName = sanitizeIdentifier(field.fieldName, fallback: "field\(field.index)", uppercaseFirst: false)
                lines.append("    \(fieldType) \(fieldName);")
            }
            lines.append("};")
            lines.append("")
        }

        for rawTypeName in structFieldInfo.keys.sorted() {
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
        guard func_.outputs.count > 1 else { return nil }

        let structName = func_.returnType
        var lines: [String] = ["struct \(structName) {"]
        for (index, output) in func_.outputs.enumerated() {
            let rawTypeName = output.typeName.trimmingCharacters(in: .whitespacesAndNewlines)
            let fieldType: String
            if rawTypeName.isEmpty {
                fieldType = output.kind == "air.position" ? "float4" : "float"
            } else {
                fieldType = irScalarTypeToMSL(rawTypeName)
            }

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
                attribute = " [[position]]"
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
        let allParams = generateAllParams(
            func_.parameters,
            safeName: safeName,
            shaderType: func_.shaderType,
            defaultBuiltin: defaultBuiltinParam(for: func_.shaderType)
        )

        let bodyStatements = translateFunctionBody(
            func_, irParamList: extractIRParameterList(from: func_.irSignature),
            structTypeDefs: structTypeDefs,
            structFieldInfo: structFieldInfo
        )

        let shaderQualifier = func_.shaderType.rawValue
        let retType = func_.shaderType == .kernel ? "void" : func_.returnType

        var lines: [String] = []
        lines.append("\(shaderQualifier) \(retType) \(safeName)(\(allParams)) {")
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
        }
    }

    /// shader 类型对应的默认内置参数
    private static func defaultBuiltinParam(for type: ShaderType) -> String {
        switch type {
        case .vertex: return "uint vid [[vertex_id]]"
        case .fragment: return "float4 position [[position]]"
        case .kernel: return "uint tid [[thread_position_in_grid]]"
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
            defaultBuiltin: "float4 position [[position]]"
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

    /// 生成完整的参数列表，包括 buffer 参数、texture/sampler 参数和内置属性参数。
    ///
    /// 如果 metadata 提供了精确参数信息，使用它们；否则使用 defaultBuiltin 作为回退。
    private static func generateAllParams(
        _ params: [ParsedParameter],
        safeName: String,
        shaderType: ShaderType,
        defaultBuiltin: String
    ) -> String {
        var mslParams: [String] = []
        let usesStageIn = shouldUseStageInStruct(params, shaderType: shaderType)
        var hasEntryInput = usesStageIn

        if usesStageIn {
            let stageInType = stageInStructName(for: safeName)
            mslParams.append("\(stageInType) \(stageInParamName) [[stage_in]]")
        }

        for param in params {
            if usesStageIn && isStageInParameter(param, shaderType: shaderType) {
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

                if ptr.addressSpace.isBufferAddressSpace {
                    let idx = param.bufferIndex ?? 0
                    if isStructTypeName(elemType) && ptr.addressSpace == .constant {
                        // constant struct 往往是单个 uniforms 对象，更贴近 `constant Uniforms& uniforms`。
                        mslParams.append("\(constPrefix)\(qualifier) \(elemType)& \(emittedName) [[buffer(\(idx))]]")
                    } else {
                        mslParams.append("\(constPrefix)\(qualifier) \(elemType)* \(emittedName) [[buffer(\(idx))]]")
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

            // 回退：有地址空间但没有详细信息
            if let addrSpace = param.addressSpace {
                let qualifier = addrSpace.mslQualifier
                if qualifier.isEmpty { continue }
                let idx = param.bufferIndex ?? 0
                let constPrefix = addrSpace.isReadOnly ? "const " : ""
                if addrSpace.isBufferAddressSpace {
                    mslParams.append("\(constPrefix)\(qualifier) uint8_t* \(emittedName) [[buffer(\(idx))]]")
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

    /// 判断类型名是否像是结构体（大写开头且不是 MSL 标准类型）
    private static func isStructTypeName(_ name: String) -> Bool {
        guard let first = name.first else { return false }
        if !first.isUppercase { return false }
        // 排除 MSL 标准类型
        let standardTypes: Set<String> = [
            "Float", "Half", "Int", "UInt", "Short", "UShort", "Char", "UChar", "Bool"
        ]
        return !standardTypes.contains(name)
    }

    /// 清理 texture 类型名：去掉 access 限定
    /// "texture2d<float, sample>" → "texture2d<float>"
    private static func cleanTextureTypeName(_ name: String) -> String {
        // 从 metadata 拿到的类型名可能是 `texture2d<float, sample>`，
        // 若上游 token 里夹了残余引号，也一并去掉。
        let normalizedName = name.replacingOccurrences(of: "\"", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let ltIdx = normalizedName.firstIndex(of: "<"),
              let gtIdx = normalizedName.lastIndex(of: ">") else {
            return normalizedName
        }
        let innerContent = normalizedName[normalizedName.index(after: ltIdx)..<gtIdx]
        let parts = innerContent.components(separatedBy: ",")
        if parts.count > 1 {
            // 只保留元素类型，去掉 access
            let elemType = parts[0].trimmingCharacters(in: .whitespaces)
            let prefix = String(normalizedName[normalizedName.startIndex...ltIdx])
            return "\(prefix)\(elemType)>"
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
