import Foundation

extension IRToMSLConverter {
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
        m.append(AirBuiltinMapping(
            airPattern: "air.discard_fragment",
            mslFunction: "discard_fragment",
            category: .misc,
            paramCount: 0,
            isMethodCall: false,
            description: "discard_fragment()"
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
    static func isTypeSuffix(_ s: String) -> Bool {
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

    struct AirConvertSignature {
        let destinationKind: String
        let destinationTypeSuffix: String
        let sourceKind: String
        let sourceTypeSuffix: String
    }

    /// 解析 `air.convert.<dst_kind>.<dst_type>.<src_kind>.<src_type>` 的语义签名。
    static func parseAirConvertSignature(_ airFuncName: String) -> AirConvertSignature? {
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
    static func airScalarSuffixToMSL(_ suffix: String, integerKind: String? = nil) -> String {
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
    static func generateAirConvertMSL(airName: String, srcArg: String) -> String {
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
}
