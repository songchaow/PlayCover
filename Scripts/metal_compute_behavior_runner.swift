#!/usr/bin/env swift

import Foundation
import Metal
import simd

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
    let threadCount: Int
    let buffers: [BufferSpec]
    let comparisons: [ComparisonSpec]
}

struct BufferSpec: Decodable {
    let index: Int
    let name: String
    let role: String
    let elementType: String
    let elementCount: Int
    let values: [Double]?
}

struct ComparisonSpec: Decodable {
    let bufferIndex: Int
    let mode: String
    let absTolerance: Double?
    let relTolerance: Double?
}

struct ComparisonResult: Encodable {
    let bufferIndex: Int
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
    let threadCount: Int
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
    case encoderUnavailable
    case bufferCreationFailed(String)

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
        case .encoderUnavailable:
            return "Unable to create MTLComputeCommandEncoder"
        case .bufferCreationFailed(let message):
            return message
        }
    }
}

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
        throw HarnessError.usage("Usage: swift metal_compute_behavior_runner.swift --spec <spec.json> --result <result.json>")
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

func vectorWidth(for elementType: String) throws -> Int {
    switch elementType {
    case "float", "half", "int", "uint":
        return 1
    case "float4", "int4", "uint4":
        return 4
    default:
        throw HarnessError.invalidSpec("Unsupported elementType: \(elementType)")
    }
}

func bufferLength(for spec: BufferSpec) throws -> Int {
    switch spec.elementType {
    case "float":
        return spec.elementCount * MemoryLayout<Float>.stride
    case "half":
        return spec.elementCount * MemoryLayout<Float16>.stride
    case "int":
        return spec.elementCount * MemoryLayout<Int32>.stride
    case "uint":
        return spec.elementCount * MemoryLayout<UInt32>.stride
    case "float4":
        return spec.elementCount * MemoryLayout<SIMD4<Float>>.stride
    case "int4":
        return spec.elementCount * MemoryLayout<SIMD4<Int32>>.stride
    case "uint4":
        return spec.elementCount * MemoryLayout<SIMD4<UInt32>>.stride
    default:
        throw HarnessError.invalidSpec("Unsupported elementType: \(spec.elementType)")
    }
}

func encodeBufferData(for spec: BufferSpec) throws -> Data {
    if spec.role == "output" {
        return Data(count: try bufferLength(for: spec))
    }

    guard let rawValues = spec.values else {
        throw HarnessError.invalidSpec("Input buffer \(spec.name) is missing values")
    }

    let expectedScalarCount = spec.elementCount * (try vectorWidth(for: spec.elementType))
    guard rawValues.count == expectedScalarCount else {
        throw HarnessError.invalidSpec(
            "Input buffer \(spec.name) expects \(expectedScalarCount) scalar values, got \(rawValues.count)"
        )
    }

    switch spec.elementType {
    case "float":
        let values = rawValues.map(Float.init)
        return values.withUnsafeBytes { Data($0) }
    case "half":
        let values = rawValues.map { Float16($0) }
        return values.withUnsafeBytes { Data($0) }
    case "int":
        let values = rawValues.map { Int32($0) }
        return values.withUnsafeBytes { Data($0) }
    case "uint":
        let values = rawValues.map { UInt32($0) }
        return values.withUnsafeBytes { Data($0) }
    case "float4":
        var values: [SIMD4<Float>] = []
        values.reserveCapacity(spec.elementCount)
        for base in stride(from: 0, to: rawValues.count, by: 4) {
            values.append(
                SIMD4<Float>(
                    Float(rawValues[base]),
                    Float(rawValues[base + 1]),
                    Float(rawValues[base + 2]),
                    Float(rawValues[base + 3])
                )
            )
        }
        return values.withUnsafeBytes { Data($0) }
    case "int4":
        var values: [SIMD4<Int32>] = []
        values.reserveCapacity(spec.elementCount)
        for base in stride(from: 0, to: rawValues.count, by: 4) {
            values.append(
                SIMD4<Int32>(
                    Int32(rawValues[base]),
                    Int32(rawValues[base + 1]),
                    Int32(rawValues[base + 2]),
                    Int32(rawValues[base + 3])
                )
            )
        }
        return values.withUnsafeBytes { Data($0) }
    case "uint4":
        var values: [SIMD4<UInt32>] = []
        values.reserveCapacity(spec.elementCount)
        for base in stride(from: 0, to: rawValues.count, by: 4) {
            values.append(
                SIMD4<UInt32>(
                    UInt32(rawValues[base]),
                    UInt32(rawValues[base + 1]),
                    UInt32(rawValues[base + 2]),
                    UInt32(rawValues[base + 3])
                )
            )
        }
        return values.withUnsafeBytes { Data($0) }
    default:
        throw HarnessError.invalidSpec("Unsupported elementType: \(spec.elementType)")
    }
}

func makeBuffer(device: MTLDevice, spec: BufferSpec) throws -> MTLBuffer {
    let data = try encodeBufferData(for: spec)
    if let buffer = device.makeBuffer(bytes: (data as NSData).bytes, length: data.count, options: .storageModeShared) {
        return buffer
    }
    throw HarnessError.bufferCreationFailed("Unable to create buffer for \(spec.name)")
}

func readBufferValues(buffer: MTLBuffer, spec: BufferSpec) throws -> [Double] {
    switch spec.elementType {
    case "float":
        let pointer = buffer.contents().bindMemory(to: Float.self, capacity: spec.elementCount)
        return (0..<spec.elementCount).map { Double(pointer[$0]) }
    case "half":
        let pointer = buffer.contents().bindMemory(to: Float16.self, capacity: spec.elementCount)
        return (0..<spec.elementCount).map { Double(pointer[$0]) }
    case "int":
        let pointer = buffer.contents().bindMemory(to: Int32.self, capacity: spec.elementCount)
        return (0..<spec.elementCount).map { Double(pointer[$0]) }
    case "uint":
        let pointer = buffer.contents().bindMemory(to: UInt32.self, capacity: spec.elementCount)
        return (0..<spec.elementCount).map { Double(pointer[$0]) }
    case "float4":
        let pointer = buffer.contents().bindMemory(to: SIMD4<Float>.self, capacity: spec.elementCount)
        return (0..<spec.elementCount).flatMap { index in
            let value = pointer[index]
            return [Double(value.x), Double(value.y), Double(value.z), Double(value.w)]
        }
    case "int4":
        let pointer = buffer.contents().bindMemory(to: SIMD4<Int32>.self, capacity: spec.elementCount)
        return (0..<spec.elementCount).flatMap { index in
            let value = pointer[index]
            return [Double(value.x), Double(value.y), Double(value.z), Double(value.w)]
        }
    case "uint4":
        let pointer = buffer.contents().bindMemory(to: SIMD4<UInt32>.self, capacity: spec.elementCount)
        return (0..<spec.elementCount).flatMap { index in
            let value = pointer[index]
            return [Double(value.x), Double(value.y), Double(value.z), Double(value.w)]
        }
    default:
        throw HarnessError.invalidSpec("Unsupported elementType: \(spec.elementType)")
    }
}

func makeLibrary(device: MTLDevice, sourcePath: String) throws -> MTLLibrary {
    let url = URL(fileURLWithPath: sourcePath).standardizedFileURL
    guard FileManager.default.fileExists(atPath: url.path) else {
        throw HarnessError.fileMissing("Source file not found: \(url.path)")
    }
    let source = try String(contentsOf: url, encoding: .utf8)
    let options = MTLCompileOptions()
    do {
        return try device.makeLibrary(source: source, options: options)
    } catch {
        throw HarnessError.compileFailed("Failed to compile Metal source \(url.lastPathComponent): \(error.localizedDescription)")
    }
}

func runCase(device: MTLDevice, library: MTLLibrary, behaviorCase: BehaviorCase) throws -> [Int: [Double]] {
    guard let function = library.makeFunction(name: behaviorCase.entryPoint) else {
        throw HarnessError.functionMissing("Function not found: \(behaviorCase.entryPoint)")
    }
    let pipeline = try device.makeComputePipelineState(function: function)

    guard let commandQueue = device.makeCommandQueue() else {
        throw HarnessError.commandQueueUnavailable
    }
    guard let commandBuffer = commandQueue.makeCommandBuffer() else {
        throw HarnessError.commandBufferUnavailable
    }
    guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
        throw HarnessError.encoderUnavailable
    }

    encoder.setComputePipelineState(pipeline)

    var buffersByIndex: [Int: MTLBuffer] = [:]
    var bufferSpecsByIndex: [Int: BufferSpec] = [:]
    for spec in behaviorCase.buffers.sorted(by: { $0.index < $1.index }) {
        let buffer = try makeBuffer(device: device, spec: spec)
        buffersByIndex[spec.index] = buffer
        bufferSpecsByIndex[spec.index] = spec
        encoder.setBuffer(buffer, offset: 0, index: spec.index)
    }

    let threadCount = max(1, behaviorCase.threadCount)
    let width = min(threadCount, max(1, pipeline.threadExecutionWidth))
    let threadsPerGroup = MTLSize(width: max(1, width), height: 1, depth: 1)
    let threads = MTLSize(width: threadCount, height: 1, depth: 1)
    encoder.dispatchThreads(threads, threadsPerThreadgroup: threadsPerGroup)
    encoder.endEncoding()
    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()

    if let error = commandBuffer.error {
        throw HarnessError.compileFailed("Command buffer failed for \(behaviorCase.entryPoint): \(error.localizedDescription)")
    }

    var outputs: [Int: [Double]] = [:]
    for comparison in behaviorCase.comparisons {
        guard let buffer = buffersByIndex[comparison.bufferIndex], let spec = bufferSpecsByIndex[comparison.bufferIndex] else {
            throw HarnessError.invalidSpec("Comparison references unknown buffer index \(comparison.bufferIndex)")
        }
        outputs[comparison.bufferIndex] = try readBufferValues(buffer: buffer, spec: spec)
    }
    return outputs
}

func compareOutputs(
    reference: [Double],
    candidate: [Double],
    comparison: ComparisonSpec
) -> ComparisonResult {
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
        bufferIndex: comparison.bufferIndex,
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
            let referenceOutputs = try runCase(device: device, library: referenceLibrary, behaviorCase: behaviorCase)
            let candidateOutputs = try runCase(device: device, library: candidateLibrary, behaviorCase: behaviorCase)
            let comparisons = behaviorCase.comparisons.map { comparison in
                compareOutputs(
                    reference: referenceOutputs[comparison.bufferIndex] ?? [],
                    candidate: candidateOutputs[comparison.bufferIndex] ?? [],
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
                    threadCount: behaviorCase.threadCount,
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
                    threadCount: behaviorCase.threadCount,
                    status: "error",
                    reason: error.localizedDescription,
                    comparisons: []
                )
            )
        }
    }

    let passedCount = caseResults.filter { $0.status == "pass" }.count
    let summary = "passed \(passedCount) / \(caseResults.count) compute cases"
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
    fputs("behavior harness \(result.status): \(result.sampleKey)\n", stderr)
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
    fputs("behavior harness error: \(error.localizedDescription)\n", stderr)
    exit(1)
}
