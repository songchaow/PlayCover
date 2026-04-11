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
        /// `stage_in` 字段上的语义标注（如 `user(TEXCOORD0)`）
        let stageInAttribute: String?
        /// AIR metadata 中记录的参数 qualifier（如 `air.flat` / `air.center` / `air.perspective`）
        let qualifiers: [String]
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

}
