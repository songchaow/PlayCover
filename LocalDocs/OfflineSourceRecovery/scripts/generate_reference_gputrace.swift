#!/usr/bin/env swift
//
// generate_reference_gputrace.swift
//
// 使用 Metal Capture API 生成一个"已知结构"的最小 gputrace。
// 包含两种 library 创建路径：
//   1. makeLibrary(source:) — Xcode 会记录源码
//   2. makeLibrary(data:)   — Xcode 不会记录源码（我们要注入的目标）
//
// 用法:
//   swift generate_reference_gputrace.swift [output_dir]
//   默认输出到 ~/Desktop/
//
// 注意: 此脚本需要在 macOS 上运行，需要 Metal 支持的 GPU。
//

import Foundation
import Metal
import MetalKit

// MARK: - Shader Sources

/// 通过 makeLibrary(source:) 编译的 shader — Xcode 会保存其源码
let sourceShaderCode = """
#include <metal_stdlib>
using namespace metal;

// PlayCover Reference Shader (Source Path)
// This shader is created via makeLibrary(source:) and Xcode WILL record its source.
kernel void reference_source_kernel(
    device float *input  [[buffer(0)]],
    device float *output [[buffer(1)]],
    uint tid [[thread_position_in_grid]]
) {
    output[tid] = input[tid] * 2.0 + 1.0;
}
"""

/// 第二个 source shader，用于验证多个 source library 的情况
let sourceShaderCode2 = """
#include <metal_stdlib>
using namespace metal;

// PlayCover Reference Shader 2 (Source Path)
kernel void reference_source_kernel2(
    device float *data [[buffer(0)]],
    uint tid [[thread_position_in_grid]]
) {
    data[tid] = sqrt(data[tid]);
}
"""

/// 通过 makeLibrary(data:) 加载的 shader — Xcode 不会记录源码
/// 我们先编译为 metallib，再从 data 加载
let dataShaderCode = """
#include <metal_stdlib>
using namespace metal;

// PlayCover Reference Shader (Data Path)
// This shader is created via makeLibrary(data:) and Xcode will NOT record its source.
kernel void reference_data_kernel(
    device float *input  [[buffer(0)]],
    device float *output [[buffer(1)]],
    uint tid [[thread_position_in_grid]]
) {
    output[tid] = input[tid] * 3.0 - 1.0;
}
"""

// MARK: - Main

func main() throws {
    let args = CommandLine.arguments
    let outputDir: String
    if args.count > 1 {
        outputDir = args[1]
    } else {
        outputDir = NSHomeDirectory() + "/Desktop"
    }

    guard let device = MTLCreateSystemDefaultDevice() else {
        fatalError("No Metal device available")
    }
    print("Using device: \(device.name)")

    // --- Step 1: Create libraries via both paths ---

    // Path A: makeLibrary(source:)
    print("\n[1/5] Creating libraries via makeLibrary(source:)...")
    let sourceLibrary1: MTLLibrary
    do {
        sourceLibrary1 = try device.makeLibrary(source: sourceShaderCode, options: nil)
        print("  ✓ sourceLibrary1 created: \(sourceLibrary1.functionNames)")
    } catch {
        fatalError("Failed to compile source shader 1: \(error)")
    }

    let sourceLibrary2: MTLLibrary
    do {
        sourceLibrary2 = try device.makeLibrary(source: sourceShaderCode2, options: nil)
        print("  ✓ sourceLibrary2 created: \(sourceLibrary2.functionNames)")
    } catch {
        fatalError("Failed to compile source shader 2: \(error)")
    }

    // Path B: makeLibrary(data:) — first compile to metallib, then reload from data
    print("\n[2/5] Creating library via makeLibrary(data:)...")
    let dataLibrary: MTLLibrary
    do {
        // 先编译得到 library
        let tempLib = try device.makeLibrary(source: dataShaderCode, options: nil)
        
        // 使用 metallib 文件方式: 将源码编译后的 metallib 导出再重新加载
        // 由于 MTLLibrary 没有直接导出 data 的 API，我们用另一种方式：
        // 通过 xcrun metal + metallib 命令行编译
        let tempDir = FileManager.default.temporaryDirectory
        let metalFile = tempDir.appendingPathComponent("data_shader.metal")
        let airFile = tempDir.appendingPathComponent("data_shader.air")
        let metallibFile = tempDir.appendingPathComponent("data_shader.metallib")
        
        try dataShaderCode.write(to: metalFile, atomically: true, encoding: .utf8)
        
        // Compile .metal -> .air
        let compileProcess = Process()
        compileProcess.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        compileProcess.arguments = ["metal", "-c", metalFile.path, "-o", airFile.path]
        try compileProcess.run()
        compileProcess.waitUntilExit()
        guard compileProcess.terminationStatus == 0 else {
            fatalError("metal compilation failed")
        }
        
        // Link .air -> .metallib
        let linkProcess = Process()
        linkProcess.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        linkProcess.arguments = ["metallib", airFile.path, "-o", metallibFile.path]
        try linkProcess.run()
        linkProcess.waitUntilExit()
        guard linkProcess.terminationStatus == 0 else {
            fatalError("metallib link failed")
        }
        
        // Load from data
        let metallibData = try Data(contentsOf: metallibFile)
        print("  Metallib size: \(metallibData.count) bytes")
        
        // 使用 dispatch_data_t
        let dispatchData = metallibData.withUnsafeBytes { ptr in
            DispatchData(bytes: UnsafeRawBufferPointer(
                start: ptr.baseAddress,
                count: metallibData.count
            ))
        }
        
        dataLibrary = try device.makeLibrary(data: dispatchData as __DispatchData)
        print("  ✓ dataLibrary created via makeLibrary(data:): \(dataLibrary.functionNames)")
        
        // Cleanup temp files
        try? FileManager.default.removeItem(at: metalFile)
        try? FileManager.default.removeItem(at: airFile)
        try? FileManager.default.removeItem(at: metallibFile)
        
        _ = tempLib // suppress unused warning
    } catch {
        fatalError("Failed to create data library: \(error)")
    }

    // --- Step 2: Create compute pipelines ---
    print("\n[3/5] Creating compute pipeline states...")

    let sourcePipeline1: MTLComputePipelineState
    do {
        let fn = sourceLibrary1.makeFunction(name: "reference_source_kernel")!
        sourcePipeline1 = try device.makeComputePipelineState(function: fn)
        print("  ✓ sourcePipeline1 (reference_source_kernel)")
    } catch {
        fatalError("Failed to create pipeline 1: \(error)")
    }

    let sourcePipeline2: MTLComputePipelineState
    do {
        let fn = sourceLibrary2.makeFunction(name: "reference_source_kernel2")!
        sourcePipeline2 = try device.makeComputePipelineState(function: fn)
        print("  ✓ sourcePipeline2 (reference_source_kernel2)")
    } catch {
        fatalError("Failed to create pipeline 2: \(error)")
    }

    let dataPipeline: MTLComputePipelineState
    do {
        let fn = dataLibrary.makeFunction(name: "reference_data_kernel")!
        dataPipeline = try device.makeComputePipelineState(function: fn)
        print("  ✓ dataPipeline (reference_data_kernel)")
    } catch {
        fatalError("Failed to create pipeline 3: \(error)")
    }

    // --- Step 3: Create buffers ---
    let elementCount = 256
    let bufferSize = elementCount * MemoryLayout<Float>.stride

    let inputBuffer = device.makeBuffer(length: bufferSize, options: .storageModeShared)!
    let outputBuffer1 = device.makeBuffer(length: bufferSize, options: .storageModeShared)!
    let outputBuffer2 = device.makeBuffer(length: bufferSize, options: .storageModeShared)!
    let outputBuffer3 = device.makeBuffer(length: bufferSize, options: .storageModeShared)!

    // Fill input
    let inputPtr = inputBuffer.contents().bindMemory(to: Float.self, capacity: elementCount)
    for i in 0..<elementCount {
        inputPtr[i] = Float(i)
    }

    // --- Step 4: Setup capture ---
    print("\n[4/5] Setting up Metal capture...")

    let captureManager = MTLCaptureManager.shared()
    
    let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        .replacingOccurrences(of: ":", with: "")
        .replacingOccurrences(of: " ", with: "_")
    let traceFileName = "reference_\(timestamp).gputrace"
    let traceURL = URL(fileURLWithPath: outputDir).appendingPathComponent(traceFileName)

    let captureDescriptor = MTLCaptureDescriptor()
    captureDescriptor.captureObject = device
    captureDescriptor.destination = .gpuTraceDocument
    captureDescriptor.outputURL = traceURL

    do {
        try captureManager.startCapture(with: captureDescriptor)
        print("  ✓ Capture started -> \(traceURL.path)")
    } catch {
        fatalError("Failed to start capture: \(error)")
    }

    // --- Step 5: Dispatch compute work ---
    print("\n[5/5] Dispatching compute work...")

    let commandQueue = device.makeCommandQueue()!
    let commandBuffer = commandQueue.makeCommandBuffer()!
    commandBuffer.label = "ReferenceCapture"

    let encoder = commandBuffer.makeComputeCommandEncoder()!
    encoder.label = "ReferenceEncoder"

    // Dispatch 1: source shader 1
    encoder.pushDebugGroup("SourceShader1")
    encoder.setComputePipelineState(sourcePipeline1)
    encoder.setBuffer(inputBuffer, offset: 0, index: 0)
    encoder.setBuffer(outputBuffer1, offset: 0, index: 1)
    encoder.dispatchThreads(
        MTLSizeMake(elementCount, 1, 1),
        threadsPerThreadgroup: MTLSizeMake(64, 1, 1)
    )
    encoder.popDebugGroup()

    // Dispatch 2: source shader 2
    encoder.pushDebugGroup("SourceShader2")
    encoder.setComputePipelineState(sourcePipeline2)
    encoder.setBuffer(outputBuffer2, offset: 0, index: 0)
    encoder.dispatchThreads(
        MTLSizeMake(elementCount, 1, 1),
        threadsPerThreadgroup: MTLSizeMake(64, 1, 1)
    )
    encoder.popDebugGroup()

    // Dispatch 3: data shader (no source will be captured)
    encoder.pushDebugGroup("DataShader_NoSource")
    encoder.setComputePipelineState(dataPipeline)
    encoder.setBuffer(inputBuffer, offset: 0, index: 0)
    encoder.setBuffer(outputBuffer3, offset: 0, index: 1)
    encoder.dispatchThreads(
        MTLSizeMake(elementCount, 1, 1),
        threadsPerThreadgroup: MTLSizeMake(64, 1, 1)
    )
    encoder.popDebugGroup()

    encoder.endEncoding()
    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()

    // Stop capture
    captureManager.stopCapture()

    print("\n✅ Capture complete!")
    print("   Output: \(traceURL.path)")
    print("\nNext steps:")
    print("  1. Open the .gputrace in Xcode to verify:")
    print("     - reference_source_kernel and reference_source_kernel2 should show source")
    print("     - reference_data_kernel should show 'Shader source not found'")
    print("  2. Run the analysis script to dump MTSP records:")
    print("     python3 analyze_reference_gputrace.py \(traceURL.path)")
}

do {
    try main()
} catch {
    fatalError("Error: \(error)")
}
