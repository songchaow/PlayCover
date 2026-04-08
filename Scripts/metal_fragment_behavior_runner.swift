#!/usr/bin/env swift

import Foundation
import Metal

struct BehaviorSpec: Decodable {
    let schemaVersion: Int
    let sampleKey: String
    let referenceSourcePath: String
    let candidateSourcePath: String
    let cases: [BehaviorCase]
}

struct BehaviorCase: Decodable {
    let name: String
    let entryPoint: String
    let renderTarget: RenderTargetSpec
    let comparisons: [ComparisonSpec]
}

struct RenderTargetSpec: Decodable {
    let width: Int
    let height: Int
    let pixelFormat: String
}

struct ComparisonSpec: Decodable {
    let attachmentIndex: Int
    let mode: String
    let absTolerance: Double?
    let relTolerance: Double?
}

struct ComparisonResult: Encodable {
    let attachmentIndex: Int
    let mode: String
    let status: String
    let scalarCount: Int
    let mismatchCount: Int
    let maxAbsDiff: Double
    let maxRelDiff: Double
    let absTolerance: Double?
    let relTolerance: Double?
    let firstMismatchIndex: Int?
    let firstReferenceValue: Double?
    let firstCandidateValue: Double?
    let referenceValues: [Double]
    let candidateValues: [Double]
}

struct CaseResult: Encodable {
    let name: String
    let entryPoint: String
    let renderTargetWidth: Int
    let renderTargetHeight: Int
    let status: String
    let reason: String?
    let comparisons: [ComparisonResult]
}

struct SampleResult: Encodable {
    let schemaVersion: Int
    let sampleKey: String
    let status: String
    let summary: String
    let deviceName: String?
    let cases: [CaseResult]
}

enum HarnessError: Error, LocalizedError {
    case usage(String)
    case invalidSpec(String)
    case fileMissing(String)
    case noDevice
    case compileFailed(String)
    case functionMissing(String)
    case commandQueueUnavailable
    case commandBufferUnavailable
    case renderEncoderUnavailable
    case pipelineStateUnavailable(String)
    case textureCreationFailed(String)
    case unsupportedPixelFormat(String)

    var errorDescription: String? {
        switch self {
        case .usage(let message):
            return message
        case .invalidSpec(let message):
            return message
        case .fileMissing(let message):
            return message
        case .noDevice:
            return "No Metal device available on this machine"
        case .compileFailed(let message):
            return message
        case .functionMissing(let message):
            return message
        case .commandQueueUnavailable:
            return "Unable to create MTLCommandQueue"
        case .commandBufferUnavailable:
            return "Unable to create MTLCommandBuffer"
        case .renderEncoderUnavailable:
            return "Unable to create MTLRenderCommandEncoder"
        case .pipelineStateUnavailable(let message):
            return message
        case .textureCreationFailed(let message):
            return message
        case .unsupportedPixelFormat(let pixelFormat):
            return "Unsupported render target pixel format: \(pixelFormat)"
        }
    }
}

let helperShaderSource = """
using namespace metal;

vertex float4 sv_behavior_fullscreen_vertex(uint vertexID [[vertex_id]]) {
    constexpr float4 positions[3] = {
        float4(-1.0, -1.0, 0.0, 1.0),
        float4( 3.0, -1.0, 0.0, 1.0),
        float4(-1.0,  3.0, 0.0, 1.0),
    };
    return positions[vertexID];
}
"""

func parseArguments() throws -> (specPath: URL, resultPath: URL) {
    let arguments = CommandLine.arguments
    var specPath: URL?
    var resultPath: URL?
    var index = 1
    while index < arguments.count {
        let argument = arguments[index]
        switch argument {
        case "--spec":
            index += 1
            guard index < arguments.count else {
                throw HarnessError.usage("Missing value for --spec")
            }
            specPath = URL(fileURLWithPath: arguments[index]).standardizedFileURL
        case "--result":
            index += 1
            guard index < arguments.count else {
                throw HarnessError.usage("Missing value for --result")
            }
            resultPath = URL(fileURLWithPath: arguments[index]).standardizedFileURL
        default:
            throw HarnessError.usage("Unknown argument: \(argument)")
        }
        index += 1
    }

    guard let resolvedSpec = specPath, let resolvedResult = resultPath else {
        throw HarnessError.usage("Usage: swift metal_fragment_behavior_runner.swift --spec <spec.json> --result <result.json>")
    }
    return (resolvedSpec, resolvedResult)
}

func readSpec(from path: URL) throws -> BehaviorSpec {
    guard FileManager.default.fileExists(atPath: path.path) else {
        throw HarnessError.fileMissing("Spec file not found: \(path.path)")
    }
    let data = try Data(contentsOf: path)
    return try JSONDecoder().decode(BehaviorSpec.self, from: data)
}

func pixelFormat(for name: String) throws -> MTLPixelFormat {
    switch name {
    case "rgba16Float":
        return .rgba16Float
    default:
        throw HarnessError.unsupportedPixelFormat(name)
    }
}

func readSource(path: String) throws -> String {
    let url = URL(fileURLWithPath: path).standardizedFileURL
    guard FileManager.default.fileExists(atPath: url.path) else {
        throw HarnessError.fileMissing("Source file not found: \(url.path)")
    }
    return try String(contentsOf: url, encoding: .utf8)
}

func makeLibrary(device: MTLDevice, sourcePath: String) throws -> MTLLibrary {
    let source = try readSource(path: sourcePath)
    let mergedSource = source + "\n\n" + helperShaderSource
    let options = MTLCompileOptions()
    do {
        return try device.makeLibrary(source: mergedSource, options: options)
    } catch {
        let url = URL(fileURLWithPath: sourcePath).standardizedFileURL
        throw HarnessError.compileFailed("Failed to compile Metal source \(url.lastPathComponent): \(error.localizedDescription)")
    }
}

func makeRenderTexture(device: MTLDevice, spec: RenderTargetSpec) throws -> MTLTexture {
    let pixelFormat = try pixelFormat(for: spec.pixelFormat)
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: pixelFormat,
        width: max(1, spec.width),
        height: max(1, spec.height),
        mipmapped: false
    )
    descriptor.usage = [.renderTarget]
    descriptor.storageMode = .shared
    guard let texture = device.makeTexture(descriptor: descriptor) else {
        throw HarnessError.textureCreationFailed("Unable to create render target \(spec.width)x\(spec.height) \(spec.pixelFormat)")
    }
    return texture
}

func readTextureValues(texture: MTLTexture, pixelFormatName: String) throws -> [Double] {
    let width = texture.width
    let height = texture.height
    switch pixelFormatName {
    case "rgba16Float":
        let scalarCount = width * height * 4
        var raw = [UInt16](repeating: 0, count: scalarCount)
        raw.withUnsafeMutableBytes { rawBytes in
            let region = MTLRegionMake2D(0, 0, width, height)
            texture.getBytes(rawBytes.baseAddress!, bytesPerRow: width * 8, from: region, mipmapLevel: 0)
        }
        return raw.map { Double(Float16(bitPattern: $0)) }
    default:
        throw HarnessError.unsupportedPixelFormat(pixelFormatName)
    }
}

func renderCase(device: MTLDevice, library: MTLLibrary, behaviorCase: BehaviorCase) throws -> [Int: [Double]] {
    let renderTarget = try makeRenderTexture(device: device, spec: behaviorCase.renderTarget)
    guard let vertexFunction = library.makeFunction(name: "sv_behavior_fullscreen_vertex") else {
        throw HarnessError.functionMissing("Helper vertex function not found: sv_behavior_fullscreen_vertex")
    }
    guard let fragmentFunction = library.makeFunction(name: behaviorCase.entryPoint) else {
        throw HarnessError.functionMissing("Function not found: \(behaviorCase.entryPoint)")
    }

    let descriptor = MTLRenderPipelineDescriptor()
    descriptor.vertexFunction = vertexFunction
    descriptor.fragmentFunction = fragmentFunction
    descriptor.colorAttachments[0].pixelFormat = try pixelFormat(for: behaviorCase.renderTarget.pixelFormat)

    let pipelineState: MTLRenderPipelineState
    do {
        pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
    } catch {
        throw HarnessError.pipelineStateUnavailable(
            "Failed to create render pipeline for \(behaviorCase.entryPoint): \(error.localizedDescription)"
        )
    }

    guard let commandQueue = device.makeCommandQueue() else {
        throw HarnessError.commandQueueUnavailable
    }
    guard let commandBuffer = commandQueue.makeCommandBuffer() else {
        throw HarnessError.commandBufferUnavailable
    }

    let renderPassDescriptor = MTLRenderPassDescriptor()
    renderPassDescriptor.colorAttachments[0].texture = renderTarget
    renderPassDescriptor.colorAttachments[0].loadAction = .clear
    renderPassDescriptor.colorAttachments[0].storeAction = .store
    renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 0.0)

    guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
        throw HarnessError.renderEncoderUnavailable
    }

    encoder.setViewport(
        MTLViewport(
            originX: 0,
            originY: 0,
            width: Double(renderTarget.width),
            height: Double(renderTarget.height),
            znear: 0,
            zfar: 1
        )
    )
    encoder.setRenderPipelineState(pipelineState)
    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    encoder.endEncoding()

    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()
    if let error = commandBuffer.error {
        throw HarnessError.compileFailed("Command buffer failed for \(behaviorCase.entryPoint): \(error.localizedDescription)")
    }

    var outputs: [Int: [Double]] = [:]
    for comparison in behaviorCase.comparisons {
        outputs[comparison.attachmentIndex] = try readTextureValues(
            texture: renderTarget,
            pixelFormatName: behaviorCase.renderTarget.pixelFormat
        )
    }
    return outputs
}

func compareOutputs(reference: [Double], candidate: [Double], comparison: ComparisonSpec) -> ComparisonResult {
    let scalarCount = min(reference.count, candidate.count)
    let absTolerance = comparison.absTolerance
    let relTolerance = comparison.relTolerance

    var mismatchCount = 0
    var maxAbsDiff = 0.0
    var maxRelDiff = 0.0
    var firstMismatchIndex: Int?
    var firstReferenceValue: Double?
    var firstCandidateValue: Double?

    for index in 0..<scalarCount {
        let lhs = reference[index]
        let rhs = candidate[index]
        let absDiff = abs(lhs - rhs)
        let relBase = max(abs(lhs), abs(rhs), 1.0)
        let relDiff = absDiff / relBase
        maxAbsDiff = max(maxAbsDiff, absDiff)
        maxRelDiff = max(maxRelDiff, relDiff)

        let matches: Bool
        if comparison.mode == "exact" {
            matches = lhs == rhs
        } else {
            let allowedAbs = absTolerance ?? 0.0
            let allowedRel = relTolerance ?? 0.0
            matches = absDiff <= allowedAbs || relDiff <= allowedRel
        }

        if !matches {
            mismatchCount += 1
            if firstMismatchIndex == nil {
                firstMismatchIndex = index
                firstReferenceValue = lhs
                firstCandidateValue = rhs
            }
        }
    }

    return ComparisonResult(
        attachmentIndex: comparison.attachmentIndex,
        mode: comparison.mode,
        status: mismatchCount == 0 && reference.count == candidate.count ? "pass" : "fail",
        scalarCount: scalarCount,
        mismatchCount: mismatchCount + max(0, abs(reference.count - candidate.count)),
        maxAbsDiff: maxAbsDiff,
        maxRelDiff: maxRelDiff,
        absTolerance: absTolerance,
        relTolerance: relTolerance,
        firstMismatchIndex: firstMismatchIndex,
        firstReferenceValue: firstReferenceValue,
        firstCandidateValue: firstCandidateValue,
        referenceValues: reference,
        candidateValues: candidate
    )
}

func run(spec: BehaviorSpec) throws -> SampleResult {
    guard let device = MTLCreateSystemDefaultDevice() else {
        throw HarnessError.noDevice
    }

    let referenceLibrary = try makeLibrary(device: device, sourcePath: spec.referenceSourcePath)
    let candidateLibrary = try makeLibrary(device: device, sourcePath: spec.candidateSourcePath)

    var caseResults: [CaseResult] = []
    var hasFailure = false

    for behaviorCase in spec.cases {
        do {
            let referenceOutputs = try renderCase(device: device, library: referenceLibrary, behaviorCase: behaviorCase)
            let candidateOutputs = try renderCase(device: device, library: candidateLibrary, behaviorCase: behaviorCase)
            let comparisons = behaviorCase.comparisons.map { comparison in
                compareOutputs(
                    reference: referenceOutputs[comparison.attachmentIndex] ?? [],
                    candidate: candidateOutputs[comparison.attachmentIndex] ?? [],
                    comparison: comparison
                )
            }
            let status = comparisons.allSatisfy { $0.status == "pass" } ? "pass" : "fail"
            if status != "pass" {
                hasFailure = true
            }
            caseResults.append(
                CaseResult(
                    name: behaviorCase.name,
                    entryPoint: behaviorCase.entryPoint,
                    renderTargetWidth: behaviorCase.renderTarget.width,
                    renderTargetHeight: behaviorCase.renderTarget.height,
                    status: status,
                    reason: nil,
                    comparisons: comparisons
                )
            )
        } catch {
            hasFailure = true
            caseResults.append(
                CaseResult(
                    name: behaviorCase.name,
                    entryPoint: behaviorCase.entryPoint,
                    renderTargetWidth: behaviorCase.renderTarget.width,
                    renderTargetHeight: behaviorCase.renderTarget.height,
                    status: "error",
                    reason: error.localizedDescription,
                    comparisons: []
                )
            )
        }
    }

    let passedCount = caseResults.filter { $0.status == "pass" }.count
    let summary = "passed \(passedCount) / \(caseResults.count) fragment cases"
    return SampleResult(
        schemaVersion: 1,
        sampleKey: spec.sampleKey,
        status: hasFailure ? "fail" : "pass",
        summary: summary,
        deviceName: device.name,
        cases: caseResults
    )
}

func writeResult(_ result: SampleResult, to path: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(result)
    try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: path)
}

do {
    let arguments = try parseArguments()
    let spec = try readSpec(from: arguments.specPath)
    let result = try run(spec: spec)
    try writeResult(result, to: arguments.resultPath)
    fputs("fragment behavior harness \(result.status): \(result.sampleKey)\n", stderr)
    exit(result.status == "pass" ? 0 : 1)
} catch {
    let payload = SampleResult(
        schemaVersion: 1,
        sampleKey: "<unknown>",
        status: "error",
        summary: error.localizedDescription,
        deviceName: nil,
        cases: []
    )
    if let parsedArguments = try? parseArguments() {
        try? writeResult(payload, to: parsedArguments.resultPath)
    }
    fputs("fragment behavior harness error: \(error.localizedDescription)\n", stderr)
    exit(1)
}
