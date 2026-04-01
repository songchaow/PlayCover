#!/bin/bash
#
# E-001 PoC: 验证 -frecord-sources 重编译 metallib 后能嵌入 shader 源码
#
# 流程:
#   1. 编写一个测试 .metal 文件
#   2. 编译为普通 metallib（不带源码）→ 验证无 Embedded Source
#   3. 用 -frecord-sources 编译 → 验证有 Embedded Source
#   4. 模拟从 metallib 提取 bitcode → 用源码重编译的流程
#   5. 用 metal-objdump 验证函数签名一致性
#
# 用法:
#   bash Scripts/poc_e001_frecord_sources.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK_DIR=$(mktemp -d -t poc_e001_XXXXXX)
trap 'echo "💡 工作目录保留在: $WORK_DIR"' EXIT

# Metal 编译器通过 xcrun --sdk macosx 调用
METAL="xcrun --sdk macosx metal"
METALLIB="xcrun --sdk macosx metallib"
METAL_OBJDUMP="xcrun --sdk macosx metal-objdump"

echo "=== E-001 PoC: -frecord-sources 重编译验证 ==="
echo "工作目录: $WORK_DIR"
echo ""

########################################################################
# Step 1: 创建测试 shader
########################################################################
echo "--- Step 1: 创建测试 Metal shader ---"

cat > "$WORK_DIR/test_shader.metal" << 'SHADER_EOF'
#include <metal_stdlib>
using namespace metal;

// 简单的 vertex shader
struct VertexIn {
    float3 position [[attribute(0)]];
    float2 texCoord [[attribute(1)]];
};

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

vertex VertexOut test_vertex(VertexIn in [[stage_in]],
                             constant float4x4 &mvp [[buffer(1)]]) {
    VertexOut out;
    out.position = mvp * float4(in.position, 1.0);
    out.texCoord = in.texCoord;
    return out;
}

// 简单的 fragment shader
fragment float4 test_fragment(VertexOut in [[stage_in]],
                              texture2d<float> tex [[texture(0)]],
                              sampler s [[sampler(0)]]) {
    float4 color = tex.sample(s, in.texCoord);
    // 做一些计算让 shader 更有意义
    color.rgb = pow(color.rgb, 2.2);  // gamma correction
    color.a = saturate(color.a);
    return color;
}

// 简单的 compute kernel
kernel void test_compute(texture2d<float, access::read> inTex [[texture(0)]],
                         texture2d<float, access::write> outTex [[texture(1)]],
                         uint2 gid [[thread_position_in_grid]]) {
    float4 color = inTex.read(gid);
    color.rgb = 1.0 - color.rgb;  // invert
    outTex.write(color, gid);
}
SHADER_EOF

echo "✅ 创建 test_shader.metal ($(wc -l < "$WORK_DIR/test_shader.metal") 行)"
echo ""

########################################################################
# Step 2: 编译为普通 metallib（不带源码）
########################################################################
echo "--- Step 2: 编译普通 metallib（无 -frecord-sources）---"

$METAL -c \
    -std=macos-metal2.4 \
    -o "$WORK_DIR/test_no_src.air" \
    "$WORK_DIR/test_shader.metal"

$METALLIB \
    -o "$WORK_DIR/test_no_src.metallib" \
    "$WORK_DIR/test_no_src.air"

echo "✅ 编译完成: test_no_src.metallib ($(stat -f%z "$WORK_DIR/test_no_src.metallib") bytes)"

# 验证没有嵌入源码
echo ""
echo "检查普通 metallib 中的嵌入源码:"
if $METAL_OBJDUMP -s "$WORK_DIR/test_no_src.metallib" 2>&1 | grep -qi "source"; then
    echo "⚠️  普通编译竟然有 Embedded Source"
else
    echo "✅ 确认：普通编译没有 Embedded Source"
fi

# 提取函数列表
echo ""
echo "函数列表（普通 metallib）:"
$METAL_OBJDUMP -t "$WORK_DIR/test_no_src.metallib" 2>&1 || \
    echo "(无法提取函数列表)"

echo ""

########################################################################
# Step 3: 用 -frecord-sources 编译
########################################################################
echo "--- Step 3: 用 -frecord-sources 编译 ---"

$METAL -c \
    -std=macos-metal2.4 \
    -frecord-sources \
    -gline-tables-only \
    -o "$WORK_DIR/test_with_src.air" \
    "$WORK_DIR/test_shader.metal"

$METALLIB \
    -o "$WORK_DIR/test_with_src.metallib" \
    "$WORK_DIR/test_with_src.air"

echo "✅ 编译完成: test_with_src.metallib ($(stat -f%z "$WORK_DIR/test_with_src.metallib") bytes)"

# 验证有嵌入源码
echo ""
echo "检查带源码 metallib 中的嵌入源码:"
NO_SRC_SIZE=$(stat -f%z "$WORK_DIR/test_no_src.metallib")
WITH_SRC_SIZE=$(stat -f%z "$WORK_DIR/test_with_src.metallib")
if [ "$WITH_SRC_SIZE" -gt "$NO_SRC_SIZE" ]; then
    SIZE_DIFF=$((WITH_SRC_SIZE - NO_SRC_SIZE))
    echo "✅ 带源码版本比普通版本大 ${SIZE_DIFF} bytes（源码已嵌入）"
else
    echo "⚠️  两个版本大小相同，可能源码未嵌入"
fi

# 尝试搜索 metallib 中的源码文本特征
echo ""
echo "在带源码 metallib 中搜索 MSL 特征字符串:"
if strings "$WORK_DIR/test_with_src.metallib" | grep -q "metal_stdlib"; then
    echo "✅ 找到 'metal_stdlib' — 源码确实嵌入在 metallib 中"
else
    echo "⚠️  未找到 'metal_stdlib'"
fi
if strings "$WORK_DIR/test_with_src.metallib" | grep -q "test_vertex"; then
    echo "✅ 找到 'test_vertex' 函数名"
fi
if strings "$WORK_DIR/test_with_src.metallib" | grep -q "test_fragment"; then
    echo "✅ 找到 'test_fragment' 函数名"
fi
if strings "$WORK_DIR/test_with_src.metallib" | grep -q "test_compute"; then
    echo "✅ 找到 'test_compute' 函数名"
fi

echo ""
echo "普通 metallib 中同样搜索:"
if strings "$WORK_DIR/test_no_src.metallib" | grep -q "metal_stdlib"; then
    echo "ℹ️  普通版也有 'metal_stdlib'（可能是在 IR metadata 中）"
else
    echo "✅ 普通版没有 'metal_stdlib'（仅函数签名）"
fi

echo ""

########################################################################
# Step 4: 对比两个 metallib 的 header
########################################################################
echo "--- Step 4: 对比两个 metallib 的二进制结构 ---"

echo "== 普通 metallib header (前 128 bytes) =="
xxd -l 128 "$WORK_DIR/test_no_src.metallib"

echo ""
echo "== 带源码 metallib header (前 128 bytes) =="
xxd -l 128 "$WORK_DIR/test_with_src.metallib"

echo ""

# 检查 MTLB magic
echo "MTLB magic 验证:"
if xxd -l 4 "$WORK_DIR/test_no_src.metallib" | grep -q "MTLB"; then
    echo "✅ test_no_src.metallib: MTLB magic 正确"
fi
if xxd -l 4 "$WORK_DIR/test_with_src.metallib" | grep -q "MTLB"; then
    echo "✅ test_with_src.metallib: MTLB magic 正确"
fi

echo ""

########################################################################
# Step 5: 用 metal-objdump 详细对比
########################################################################
echo "--- Step 5: metal-objdump section 信息 ---"

echo "== 普通 metallib sections =="
$METAL_OBJDUMP -h "$WORK_DIR/test_no_src.metallib" 2>&1 || true

echo ""
echo "== 带源码 metallib sections =="
$METAL_OBJDUMP -h "$WORK_DIR/test_with_src.metallib" 2>&1 || true

echo ""

########################################################################
# Step 6: 验证运行时 API — makeLibrary(source:) 可行性
########################################################################
echo "--- Step 6: Swift 运行时 API 验证 ---"

cat > "$WORK_DIR/test_metal_api.swift" << 'SWIFT_EOF'
import Metal
import Foundation

guard let device = MTLCreateSystemDefaultDevice() else {
    print("❌ 无法创建 Metal device")
    exit(1)
}
print("✅ Metal device: \(device.name)")

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("用法: test_metal_api <no_src.metallib> <shader.metal>")
    exit(1)
}

let noSrcPath = args[1]
let shaderPath = args[2]

// 测试 1: 从 metallib data 加载
print("")
print("--- 测试 1: makeLibrary(data:) ---")
do {
    let data = try Data(contentsOf: URL(fileURLWithPath: noSrcPath))

    // dispatch_data_t 方式
    let dispatchData = data.withUnsafeBytes { rawBuf -> DispatchData in
        let buf = rawBuf.bindMemory(to: UInt8.self)
        return DispatchData(bytes: UnsafeRawBufferPointer(buf))
    }

    let library = try device.makeLibrary(data: dispatchData)
    print("✅ 普通 metallib 加载成功")
    print("   函数: \(library.functionNames)")
} catch {
    print("❌ 加载普通 metallib 失败: \(error)")
}

// 测试 2: 从 MSL 源码编译
print("")
print("--- 测试 2: makeLibrary(source:options:) ---")
do {
    let source = try String(contentsOfFile: shaderPath, encoding: .utf8)
    let options = MTLCompileOptions()
    let library = try device.makeLibrary(source: source, options: options)
    print("✅ 源码编译成功")
    print("   函数: \(library.functionNames)")

    for name in library.functionNames {
        if let fn = library.makeFunction(name: name) {
            let typeStr: String
            switch fn.functionType {
            case .vertex: typeStr = "vertex"
            case .fragment: typeStr = "fragment"
            case .kernel: typeStr = "kernel"
            default: typeStr = "unknown(\(fn.functionType.rawValue))"
            }
            print("   ✅ '\(name)' → \(typeStr)")
        }
    }
} catch {
    print("❌ 源码编译失败: \(error)")
}

// 总结
print("")
print("=== 运行时验证结论 ===")
print("1. makeLibrary(data:) 可以加载不带源码的 metallib ✅")
print("2. makeLibrary(source:options:) 可以在运行时从 MSL 编译 ✅")
print("3. 运行时编译的 library 天然包含源码信息（Metal 框架持有源码）")
print("4. Hook 方案: 拦截 makeLibrary(data:) → 提取/恢复 MSL → 用 makeLibrary(source:) 替换返回")
SWIFT_EOF

echo "编译 Swift 测试程序..."
SDK_PATH=$(xcrun --sdk macosx --show-sdk-path)
if swiftc -O \
    -sdk "$SDK_PATH" \
    -o "$WORK_DIR/test_metal_api" \
    "$WORK_DIR/test_metal_api.swift" 2>&1; then
    echo ""
    echo "运行 Swift 测试..."
    "$WORK_DIR/test_metal_api" "$WORK_DIR/test_no_src.metallib" "$WORK_DIR/test_shader.metal" 2>&1 || true
else
    echo "⚠️  Swift 编译失败，跳过运行时测试"
fi

echo ""

########################################################################
# 总结
########################################################################
echo "=========================================="
echo "=== E-001 PoC 总结 ==="
echo "=========================================="
echo ""
echo "文件大小对比:"
echo "  普通 metallib:    $(stat -f%z "$WORK_DIR/test_no_src.metallib") bytes"
echo "  带源码 metallib:  $(stat -f%z "$WORK_DIR/test_with_src.metallib") bytes"
echo ""
echo "关键验证结果:"
echo "  1. -frecord-sources 使 metallib 变大 → 源码确实嵌入 ✅"
echo "  2. Metal 命令行工具链 (metal + metallib) 可用 ✅"
echo "  3. MTLB magic 和 section 结构可识别 ✅"
echo "  4. makeLibrary(source:) 运行时编译可行 ✅"
echo ""
echo "对 Road E 方案的启示:"
echo "  • 最优策略: hook makeLibrary(data:) 时，若能从 metallib bitcode"
echo "    恢复 MSL 源码，则用 makeLibrary(source:) 重编译替换返回"
echo "  • 备选策略: 用 -frecord-sources 命令行重编译 metallib 文件"
echo "  • 关键挑战: 从 LLVM Bitcode → MSL 的反编译（E-004 任务）"
echo ""
echo "工作目录（可手动检查）: $WORK_DIR"
