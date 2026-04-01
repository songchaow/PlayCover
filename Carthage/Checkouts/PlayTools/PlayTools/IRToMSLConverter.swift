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
//    · 扩展 AddressSpace 枚举覆盖 Metal 2+ 地址空间 (0-6)
//    · 解析 IR metadata (!air.vertex/!air.fragment/!air.kernel) 获取精确参数信息
//    · 从 metadata 提取: air.arg_type_name, air.arg_name, air.location_index,
//      air.address_space, air.read/air.read_write, air.buffer/air.texture/air.sampler
//    · 生成正确的 MSL 参数声明 (地址空间 + 精确元素类型 + 属性标注)
//    · 支持 const/non-const 推断 (constant + air.read → const constant)
//    · 区分 buffer/threadgroup/texture/sampler/vertex_input 等参数类型
//  - E-004e3: air.* 内建 → MSL 等效调用映射 ✅
//    · AirBuiltinMapping 映射表：覆盖 84+ 个实际 air.* 内建函数
//      (纹理采样/读写、同步屏障、类型转换、数学运算(fast_/non-fast)、
//       整数位操作、SIMD/quad-group、原子操作、片段导数、pack/unpack)
//    · AirBuiltinCategory 分类枚举 (10 种分类)
//    · airStripTypeSuffix() 去掉类型后缀 (v4f32/i32 等) 得到函数基础名
//    · lookupAirBuiltin() 查询映射表，支持精确匹配和最长前缀匹配
//    · parseAirBuiltinCalls() 从 IR 函数体中提取 call @air.* 指令
//    · parseAirConvertTargetType() 从 air.convert 名称解析目标 MSL 类型
//    · airTypeSuffixToMSL() 将 air 类型后缀转为 MSL 类型 (v4f32→float4)
//    · 映射信息集成到 ParsedShaderFunction.airBuiltinCalls，
//      并在生成的 MSL 注释中汇总，供 E-004e4 函数体转换使用
//    · 验证数据来源: test-data/test_builtins.metal → .air → llvm-dis → .ll
//
//  后续阶段将逐步提升转换保真度：
//  - E-004e4: 完整函数体转换
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
        /// 属性标注（如 [[stage_in]], [[position]] 等）
        let attribute: String?
        /// 指针信息（如果参数是指针类型）
        let pointerInfo: PointerInfo?

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
        let parameters: [ParsedParameter]
        /// 从 IR metadata 中提取的原始函数签名
        let irSignature: String
        /// 是否成功解析了完整签名
        let isFullyParsed: Bool
        /// 函数体中使用的 air.* 内建调用（E-004e3）
        let airBuiltinCalls: [AirBuiltinCall]
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
    static func airTypeSuffixToMSL(_ suffix: String) -> String {
        // 向量类型：vNtBB → typeN (如 v4f32 → float4)
        if suffix.hasPrefix("v") {
            let chars = Array(suffix.dropFirst())
            // 提取维度数字
            var i = 0
            while i < chars.count && chars[i].isNumber { i += 1 }
            let dim = String(chars[0..<i])
            let scalarSuffix = String(chars[i...])
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
    }

    /// 从 IR metadata 中解析出的函数信息
    struct MetadataFuncInfo {
        /// 函数名
        let name: String
        /// shader 类型
        let shaderType: ShaderType
        /// 参数列表（按 argIndex 排序）
        let args: [MetadataArgInfo]
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

        // 找到参数列表引用（第三个 !N 引用）
        let refs = parseMetadataRefList(content)
        guard refs.count >= 3 else {
            // 至少需要 函数指针 + 返回描述 + 参数列表
            return MetadataFuncInfo(name: funcName, shaderType: shaderType, args: [])
        }

        let argsNodeId = refs[2]  // 第三个引用是参数列表
        guard let argsContent = nodes[argsNodeId] else {
            return MetadataFuncInfo(name: funcName, shaderType: shaderType, args: [])
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

        return MetadataFuncInfo(name: funcName, shaderType: shaderType, args: args)
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
            isReadOnly: isReadOnly
        )
    }

    /// 分割 metadata 节点内容为 token 列表。
    /// 处理逗号分割，但保持 !{} 嵌套。
    private static func splitMetadataTokens(_ content: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var depth = 0

        for char in content {
            if char == "{" || char == "(" || char == "[" { depth += 1 }
            else if char == "}" || char == ")" || char == "]" { depth -= 1 }

            if char == "," && depth == 0 {
                let trimmed = current.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { tokens.append(trimmed) }
                current = ""
            } else {
                current.append(char)
            }
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

        // 4. 生成 MSL 源码
        let mslSource = generateMSL(functions: shaderFunctions)

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
    }

    /// 解析 IR 文本中的所有函数定义。
    /// 返回 (解析的函数列表, 总函数定义数)
    private static func parseIRFunctions(_ irText: String) -> ([IRFunctionDef], Int) {
        var functions: [IRFunctionDef] = []

        // LLVM IR 函数定义格式：
        // define <return_type> @<name>(<params>) #N { ... }
        // 或 declare <return_type> @<name>(<params>)
        //
        // Metal shader 函数通常是 define，有 body
        let lines = irText.components(separatedBy: "\n")
        var totalDefines = 0

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // 匹配 define 行
            guard trimmed.hasPrefix("define ") else { continue }
            totalDefines += 1

            // 提取函数名：@"function_name" 或 @function_name
            guard let funcDef = parseDefineLine(trimmed) else { continue }
            functions.append(funcDef)
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
            fullDefinition: line
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
            let isFullyParsed: Bool
            if let metaInfo = metadataMap[irFunc.name] {
                params = buildParametersFromMetadata(metaInfo.args, irParamList: irFunc.parameterList)
                isFullyParsed = true
            } else {
                params = parseParameters(irFunc.parameterList, shaderType: type)
                isFullyParsed = false
            }

            // 推断 MSL 返回类型
            let mslReturnType = irTypeToMSL(irFunc.returnType, forShaderType: type)

            shaderFunctions.append(ParsedShaderFunction(
                name: irFunc.name,
                shaderType: type,
                returnType: mslReturnType,
                parameters: params,
                irSignature: "define \(irFunc.returnType) @\"\(irFunc.name)\"(\(irFunc.parameterList))",
                isFullyParsed: isFullyParsed,
                airBuiltinCalls: airBuiltinCalls
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
                    parameters: [],
                    irSignature: "(metallib-only, no IR match)",
                    isFullyParsed: false,
                    airBuiltinCalls: []
                ))
            }
        }

        return shaderFunctions
    }

    /// 从 IR metadata 参数信息构建 ParsedParameter 列表。
    ///
    /// metadata 提供了精确的 MSL 类型名、参数名、绑定索引和地址空间，
    /// 比从 opaque pointer 参数推断要准确得多。
    private static func buildParametersFromMetadata(
        _ metaArgs: [MetadataArgInfo],
        irParamList: String
    ) -> [ParsedParameter] {
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
            case "air.vertex_input", "air.fragment_input":
                // stage_in 参数在 IR 层被展平为值传递，不生成 MSL 参数
                continue
            case "air.position":
                // 内置位置输出/输入，不生成 MSL 参数
                continue
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
                pointerInfo: ptrInfo
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
                pointerInfo: ptrInfo
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
                let elemType = irScalarTypeToMSL(
                    parts.dropFirst().joined(separator: " x ").trimmingCharacters(in: .whitespaces)
                )
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
        var result = ""
        for char in name {
            if char.isLetter || char.isNumber || char == "_" {
                result.append(char)
            } else {
                result.append("_")
            }
        }
        return result.isEmpty ? "UnknownType" : result
    }

    /// 从 IR 参数字符串中提取参数名
    private static func extractParamName(from irParam: String) -> String? {
        // 参数名格式: %name 或 %0, %1 等
        guard let percentIndex = irParam.lastIndex(of: "%") else { return nil }
        let afterPercent = irParam[irParam.index(after: percentIndex)...]
        let name = afterPercent.prefix(while: { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." })
        return name.isEmpty ? nil : String(name)
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

        // 向量类型: <N x T> → TN
        if cleaned.hasPrefix("<") && cleaned.contains(" x ") {
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

        // 结构体类型 → 使用默认
        if cleaned.hasPrefix("{") || cleaned.hasPrefix("%struct") {
            return defaultReturnType(for: shaderType)
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

    // MARK: - MSL Generation

    /// 生成完整的 MSL 源码
    private static func generateMSL(functions: [ParsedShaderFunction]) -> String {
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

        // 用于去重
        var emittedNames: Set<String> = []

        for (index, func_) in functions.enumerated() {
            // MSL 不允许重复的函数名
            let safeName = sanitizeFunctionName(func_.name)
            if emittedNames.contains(safeName) { continue }
            emittedNames.insert(safeName)

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
            let funcCode = generateFunction(func_, safeName: safeName)
            lines.append(funcCode)
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    /// 生成单个 shader 函数的 MSL 代码
    private static func generateFunction(
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

    /// 生成 vertex shader stub
    private static func generateVertexFunction(
        _ func_: ParsedShaderFunction,
        safeName: String
    ) -> String {
        let allParams = generateAllParams(func_.parameters, defaultBuiltin: "uint vid [[vertex_id]]")

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
        let allParams = generateAllParams(func_.parameters, defaultBuiltin: "float4 position [[position]]")

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
        let allParams = generateAllParams(func_.parameters, defaultBuiltin: "uint tid [[thread_position_in_grid]]")

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
        defaultBuiltin: String
    ) -> String {
        var mslParams: [String] = []
        var hasBuiltin = false

        for param in params {
            // 有 pointerInfo 的是 buffer/threadgroup 参数
            if let ptr = param.pointerInfo {
                let qualifier = ptr.addressSpace.mslQualifier
                guard !qualifier.isEmpty else { continue }

                let elemType = ptr.pointedMSLType
                let constPrefix = ptr.addressSpace.isReadOnly ? "const " : ""

                if ptr.addressSpace.isBufferAddressSpace {
                    let idx = param.bufferIndex ?? 0
                    // 检查类型名是否像是结构体（大写开头且不是 MSL 基本类型）
                    if isStructTypeName(elemType) {
                        // 结构体引用: constant Uniforms& name [[buffer(N)]]
                        mslParams.append("\(constPrefix)\(qualifier) \(elemType)& \(param.name) [[buffer(\(idx))]]")
                    } else {
                        mslParams.append("\(constPrefix)\(qualifier) \(elemType)* \(param.name) [[buffer(\(idx))]]")
                    }
                } else if ptr.addressSpace.isThreadgroupAddressSpace {
                    let idx = param.bufferIndex ?? 0
                    mslParams.append("threadgroup \(elemType)* \(param.name) [[threadgroup(\(idx))]]")
                } else {
                    mslParams.append("\(qualifier) \(elemType)* \(param.name)")
                }
                continue
            }

            // 有 attribute 的是内置属性 或 texture/sampler
            if let attr = param.attribute {
                hasBuiltin = true
                let typeName = param.irType.isEmpty ? "uint" : param.irType

                if param.irType.hasPrefix("texture") {
                    // texture2d<float, sample> → texture2d<float>
                    let cleanedTexType = cleanTextureTypeName(typeName)
                    mslParams.append("\(cleanedTexType) \(param.name) \(attr)")
                } else if param.irType == "sampler" {
                    mslParams.append("sampler \(param.name) \(attr)")
                } else {
                    mslParams.append("\(typeName) \(param.name) \(attr)")
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
                    mslParams.append("\(constPrefix)\(qualifier) uint8_t* \(param.name) [[buffer(\(idx))]]")
                } else if addrSpace.isThreadgroupAddressSpace {
                    mslParams.append("threadgroup uint8_t* \(param.name) [[threadgroup(\(idx))]]")
                }
            }
        }

        // 如果没有从 metadata 获取内置属性，添加默认的
        if !hasBuiltin && !defaultBuiltin.isEmpty {
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
        // 从 metadata 拿到的类型名可能是 "texture2d<float, sample>"
        guard let ltIdx = name.firstIndex(of: "<"),
              let gtIdx = name.lastIndex(of: ">") else {
            return name
        }
        let innerContent = name[name.index(after: ltIdx)..<gtIdx]
        let parts = innerContent.components(separatedBy: ",")
        if parts.count > 1 {
            // 只保留元素类型，去掉 access
            let elemType = parts[0].trimmingCharacters(in: .whitespaces)
            let prefix = String(name[name.startIndex...ltIdx])
            return "\(prefix)\(elemType)>"
        }
        return name
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
