import Foundation
import Metal

// `mtl-device` backend 的标准 compile report contract。
// Python orchestration 应消费这份 Swift report，再归一化为 aggregate summary；不要在 Python 侧重建一份 runtime-like posture 决策。
private struct CompileReport: Encodable {
    let schemaVersion: Int
    let success: Bool
    let error: String?
    let functionNames: [String]
    let functionCount: Int
    let usesExplicitCompileOptions: Bool
    let fastMathEnabled: Bool?
    let fastMathMode: String?
    let fastMathDecision: String
    let inferredMetalArgs: [String]
    let effectiveMetalArgs: [String]
}

private struct SharedCompileDecisionManifest: Decodable {
    let schemaVersion: Int
    let fastMath: SharedFastMathOptions
}

private struct SharedFastMathOptions: Decodable {
    let enableOption: String
    let disableOption: String
}

private struct CompileDecision {
    let fastMathMode: FastMathMode
    let fastMathDecision: String
    let inferredMetalArgs: [String]
    let effectiveMetalArgs: [String]

    var usesExplicitCompileOptions: Bool {
        fastMathMode.usesExplicitCompileOptions
    }

    var fastMathEnabled: Bool? {
        fastMathMode.fastMathEnabled
    }
}

private enum HarnessError: LocalizedError {
    case missingArgument(String)
    case unexpectedArgument(String)
    case unsupportedMetalArgument(String)
    case metalUnavailable
    case failedToReadSharedManifestSource(String)
    case sharedManifestJSONNotFound(String)
    case invalidSharedManifestJSON(String)

    var errorDescription: String? {
        switch self {
        case .missingArgument(let name):
            return "missing required argument: \(name)"
        case .unexpectedArgument(let value):
            return "unexpected argument: \(value)"
        case .unsupportedMetalArgument(let value):
            return "unsupported metal arg for mtl-device backend: \(value)"
        case .metalUnavailable:
            return "failed to create system default Metal device"
        case .failedToReadSharedManifestSource(let path):
            return "failed to read shared compile decision manifest source: \(path)"
        case .sharedManifestJSONNotFound(let path):
            return "shared compile decision manifest JSON not found in \(path)"
        case .invalidSharedManifestJSON(let path):
            return "invalid shared compile decision manifest JSON in \(path)"
        }
    }
}

private enum FastMathMode: String {
    case `default`
    case enable
    case disable

    var usesExplicitCompileOptions: Bool {
        switch self {
        case .default:
            return false
        case .enable, .disable:
            return true
        }
    }

    var fastMathEnabled: Bool? {
        switch self {
        case .default:
            return nil
        case .enable:
            return true
        case .disable:
            return false
        }
    }
}

private extension JSONEncoder {
    static func prettySorted() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private enum MetalAggregateCompileHarnessMain {
    private static let sharedManifestStartMarker = "private static let sharedCompileDecisionManifestJSON = #\"\"\""
    private static let sharedManifestEndMarker = "\"\"\"#"
    private static let explicitFastMathMetalArgs: Set<String> = ["-ffast-math", "-fno-fast-math"]

    static func run() throws -> Int32 {
        let arguments = try parseArguments(Array(CommandLine.arguments.dropFirst()))
        let report = try compileSource(arguments)
        try writeReport(report, to: arguments.reportPath)
        return report.success ? 0 : 1
    }

    static func writeFailureReportAndExit(_ error: Error) -> Never {
        let fallbackPath = parsedReportPath(Array(CommandLine.arguments.dropFirst()))
        if let reportPath = fallbackPath {
            let report = CompileReport(
                schemaVersion: 1,
                success: false,
                error: error.localizedDescription,
                functionNames: [],
                functionCount: 0,
                usesExplicitCompileOptions: false,
                fastMathEnabled: nil,
                fastMathMode: nil,
                fastMathDecision: "unresolved",
                inferredMetalArgs: [],
                effectiveMetalArgs: []
            )
            try? writeReport(report, to: reportPath)
        }
        fputs("error: \(error.localizedDescription)\n", stderr)
        exit(2)
    }

    private struct Arguments {
        let sourcePath: String
        let reportPath: String
        let manifestSourcePath: String
        let originalIRPaths: [String]
        let metalArgs: [String]
    }

    private static func parseArguments(_ arguments: [String]) throws -> Arguments {
        var sourcePath: String?
        var reportPath: String?
        var manifestSourcePath: String?
        var originalIRPaths: [String] = []
        var metalArgs: [String] = []
        var index = 0

        while index < arguments.count {
            switch arguments[index] {
            case "--source":
                index += 1
                guard index < arguments.count else { throw HarnessError.missingArgument("--source") }
                sourcePath = arguments[index]
            case "--report":
                index += 1
                guard index < arguments.count else { throw HarnessError.missingArgument("--report") }
                reportPath = arguments[index]
            case "--manifest-source":
                index += 1
                guard index < arguments.count else { throw HarnessError.missingArgument("--manifest-source") }
                manifestSourcePath = arguments[index]
            case "--original-ir":
                index += 1
                guard index < arguments.count else { throw HarnessError.missingArgument("--original-ir") }
                originalIRPaths.append(arguments[index])
            case "--metal-arg":
                index += 1
                guard index < arguments.count else { throw HarnessError.missingArgument("--metal-arg") }
                metalArgs.append(arguments[index])
            default:
                throw HarnessError.unexpectedArgument(arguments[index])
            }
            index += 1
        }

        guard let sourcePath else { throw HarnessError.missingArgument("--source") }
        guard let reportPath else { throw HarnessError.missingArgument("--report") }
        guard let manifestSourcePath else { throw HarnessError.missingArgument("--manifest-source") }
        return Arguments(
            sourcePath: sourcePath,
            reportPath: reportPath,
            manifestSourcePath: manifestSourcePath,
            originalIRPaths: originalIRPaths,
            metalArgs: metalArgs
        )
    }

    private static func parsedReportPath(_ arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: "--report"), index + 1 < arguments.count else {
            return nil
        }
        return arguments[index + 1]
    }

    private static func loadSharedCompileDecisionManifest(from manifestSourcePath: String) throws -> SharedCompileDecisionManifest {
        let sourceText: String
        do {
            sourceText = try String(contentsOfFile: manifestSourcePath, encoding: .utf8)
        } catch {
            throw HarnessError.failedToReadSharedManifestSource(manifestSourcePath)
        }

        guard let startRange = sourceText.range(of: sharedManifestStartMarker) else {
            throw HarnessError.sharedManifestJSONNotFound(manifestSourcePath)
        }
        let payloadStart = startRange.upperBound
        guard let endRange = sourceText.range(of: sharedManifestEndMarker, range: payloadStart..<sourceText.endIndex) else {
            throw HarnessError.sharedManifestJSONNotFound(manifestSourcePath)
        }

        let payload = String(sourceText[payloadStart..<endRange.lowerBound])
        guard let data = payload.data(using: .utf8) else {
            throw HarnessError.invalidSharedManifestJSON(manifestSourcePath)
        }

        do {
            return try JSONDecoder().decode(SharedCompileDecisionManifest.self, from: data)
        } catch {
            throw HarnessError.invalidSharedManifestJSON(manifestSourcePath)
        }
    }

    private static func resolveUserFastMathOverride(_ metalArgs: [String]) throws -> FastMathMode? {
        var overrideMode: FastMathMode?
        for arg in metalArgs {
            guard explicitFastMathMetalArgs.contains(arg) else {
                throw HarnessError.unsupportedMetalArgument(arg)
            }
            if arg == "-ffast-math" {
                overrideMode = .enable
            } else if arg == "-fno-fast-math" {
                overrideMode = .disable
            }
        }
        return overrideMode
    }

    private static func inferOriginalIRFastMathMode(
        at originalIRPath: String,
        manifest: SharedCompileDecisionManifest
    ) -> FastMathMode? {
        guard FileManager.default.fileExists(atPath: originalIRPath) else {
            return nil
        }

        guard let text = try? String(contentsOfFile: originalIRPath, encoding: .utf8) else {
            return nil
        }

        let hasDisable = text.contains(manifest.fastMath.disableOption)
        let hasEnable = text.contains(manifest.fastMath.enableOption)
        if hasDisable && !hasEnable {
            return .disable
        }
        if hasEnable && !hasDisable {
            return .enable
        }
        return nil
    }

    // runtime-like compile posture 宿主：除显式 fast-math override 外，其余决策都在 Swift 内完成，
    // 保持与真实 runtime 对 `MTLCompileOptions` 的拥有权一致。
    private static func resolveCompileDecision(_ arguments: Arguments) throws -> CompileDecision {
        if let overrideMode = try resolveUserFastMathOverride(arguments.metalArgs) {
            return CompileDecision(
                fastMathMode: overrideMode,
                fastMathDecision: "user_override",
                inferredMetalArgs: [],
                effectiveMetalArgs: arguments.metalArgs
            )
        }

        let manifest = try loadSharedCompileDecisionManifest(from: arguments.manifestSourcePath)
        let inferredModes = arguments.originalIRPaths.map {
            inferOriginalIRFastMathMode(at: $0, manifest: manifest)
        }
        let knownModes = inferredModes.compactMap { $0 }
        guard let firstKnownMode = knownModes.first else {
            return CompileDecision(
                fastMathMode: .default,
                fastMathDecision: "fast_math_unavailable",
                inferredMetalArgs: [],
                effectiveMetalArgs: arguments.metalArgs
            )
        }
        guard knownModes.allSatisfy({ $0 == firstKnownMode }) else {
            return CompileDecision(
                fastMathMode: .default,
                fastMathDecision: "fast_math_conflict",
                inferredMetalArgs: [],
                effectiveMetalArgs: arguments.metalArgs
            )
        }
        guard knownModes.count == inferredModes.count else {
            return CompileDecision(
                fastMathMode: .default,
                fastMathDecision: "fast_math_partial",
                inferredMetalArgs: [],
                effectiveMetalArgs: arguments.metalArgs
            )
        }

        let inferredArgs = [firstKnownMode == .enable ? "-ffast-math" : "-fno-fast-math"]
        return CompileDecision(
            fastMathMode: firstKnownMode,
            fastMathDecision: "fast_math_aligned",
            inferredMetalArgs: inferredArgs,
            effectiveMetalArgs: inferredArgs + arguments.metalArgs
        )
    }

    private static func compileSource(_ arguments: Arguments) throws -> CompileReport {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw HarnessError.metalUnavailable
        }

        let source = try String(contentsOfFile: arguments.sourcePath, encoding: .utf8)
        let compileDecision = try resolveCompileDecision(arguments)
        let options: MTLCompileOptions?
        if compileDecision.usesExplicitCompileOptions {
            let compileOptions = MTLCompileOptions()
            compileOptions.fastMathEnabled = compileDecision.fastMathEnabled ?? false
            options = compileOptions
        } else {
            options = nil
        }

        do {
            let library = try device.makeLibrary(source: source, options: options)
            return CompileReport(
                schemaVersion: 1,
                success: true,
                error: nil,
                functionNames: library.functionNames.sorted(),
                functionCount: library.functionNames.count,
                usesExplicitCompileOptions: compileDecision.usesExplicitCompileOptions,
                fastMathEnabled: compileDecision.fastMathEnabled,
                fastMathMode: compileDecision.fastMathMode == .default ? nil : compileDecision.fastMathMode.rawValue,
                fastMathDecision: compileDecision.fastMathDecision,
                inferredMetalArgs: compileDecision.inferredMetalArgs,
                effectiveMetalArgs: compileDecision.effectiveMetalArgs
            )
        } catch {
            return CompileReport(
                schemaVersion: 1,
                success: false,
                error: error.localizedDescription,
                functionNames: [],
                functionCount: 0,
                usesExplicitCompileOptions: compileDecision.usesExplicitCompileOptions,
                fastMathEnabled: compileDecision.fastMathEnabled,
                fastMathMode: compileDecision.fastMathMode == .default ? nil : compileDecision.fastMathMode.rawValue,
                fastMathDecision: compileDecision.fastMathDecision,
                inferredMetalArgs: compileDecision.inferredMetalArgs,
                effectiveMetalArgs: compileDecision.effectiveMetalArgs
            )
        }
    }

    private static func writeReport(_ report: CompileReport, to reportPath: String) throws {
        let reportURL = URL(fileURLWithPath: reportPath)
        let data = try JSONEncoder.prettySorted().encode(report)
        try FileManager.default.createDirectory(
            at: reportURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: reportURL, options: .atomic)
    }
}

do {
    exit(try MetalAggregateCompileHarnessMain.run())
} catch {
    MetalAggregateCompileHarnessMain.writeFailureReportAndExit(error)
}
