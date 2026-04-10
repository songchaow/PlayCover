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
    let explicitOverrideSource: String?
    let inferredMetalArgs: [String]
    let effectiveMetalArgs: [String]
}

private enum HarnessError: LocalizedError {
    case missingArgument(String)
    case unexpectedArgument(String)
    case unsupportedMetalArgument(String)
    case metalUnavailable

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
                explicitOverrideSource: nil,
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
        let originalIRPaths: [String]
        let metalArgs: [String]
    }

    private static func parseArguments(_ arguments: [String]) throws -> Arguments {
        var sourcePath: String?
        var reportPath: String?
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
        return Arguments(
            sourcePath: sourcePath,
            reportPath: reportPath,
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

    private static func validateSupportedMetalArgs(_ metalArgs: [String]) throws {
        for arg in metalArgs {
            guard explicitFastMathMetalArgs.contains(arg) else {
                throw HarnessError.unsupportedMetalArgument(arg)
            }
        }
    }

    private static func loadOriginalIRTexts(from originalIRPaths: [String]) -> [String] {
        originalIRPaths.map { originalIRPath in
            guard FileManager.default.fileExists(atPath: originalIRPath),
                  let text = try? String(contentsOfFile: originalIRPath, encoding: .utf8) else {
                return ""
            }
            return text
        }
    }

    // runtime-like compile posture 宿主：参数校验保留在 harness，真正的 compile posture 与 `MTLCompileOptions`
    // 决策统一委托给 SharedCompilePlanner，保持与真实 runtime 主路径一致。
    private static func resolveCompilePlan(_ arguments: Arguments) throws -> SharedCompilePlannerPlan {
        try validateSupportedMetalArgs(arguments.metalArgs)
        let input = SharedCompilePlannerInput(
            originalIRTexts: loadOriginalIRTexts(from: arguments.originalIRPaths),
            userMetalArgs: arguments.metalArgs,
            requestedBackend: .mtlDevice
        )
        return SharedCompilePlanner.makePlan(input: input)
    }

    private static func compileOptions(from compilePlan: SharedCompilePlannerPlan) -> MTLCompileOptions? {
        guard let payload = compilePlan.mtlCompileOptionsPayload else {
            return nil
        }
        let options = MTLCompileOptions()
        options.fastMathEnabled = payload.fastMathEnabled
        return options
    }

    private static func compileSource(_ arguments: Arguments) throws -> CompileReport {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw HarnessError.metalUnavailable
        }

        let source = try String(contentsOfFile: arguments.sourcePath, encoding: .utf8)
        let compilePlan = try resolveCompilePlan(arguments)
        let options = compileOptions(from: compilePlan)

        do {
            let library = try device.makeLibrary(source: source, options: options)
            return CompileReport(
                schemaVersion: 1,
                success: true,
                error: nil,
                functionNames: library.functionNames.sorted(),
                functionCount: library.functionNames.count,
                usesExplicitCompileOptions: compilePlan.decision.usesExplicitCompileOptions,
                fastMathEnabled: compilePlan.decision.compileOptionsFastMathEnabled,
                fastMathMode: compilePlan.decision.fastMathMode?.rawValue,
                fastMathDecision: compilePlan.decision.fastMathDecision,
                explicitOverrideSource: compilePlan.decision.explicitOverrideSource,
                inferredMetalArgs: compilePlan.inferredMetalArgs,
                effectiveMetalArgs: compilePlan.effectiveMetalArgs
            )
        } catch {
            return CompileReport(
                schemaVersion: 1,
                success: false,
                error: error.localizedDescription,
                functionNames: [],
                functionCount: 0,
                usesExplicitCompileOptions: compilePlan.decision.usesExplicitCompileOptions,
                fastMathEnabled: compilePlan.decision.compileOptionsFastMathEnabled,
                fastMathMode: compilePlan.decision.fastMathMode?.rawValue,
                fastMathDecision: compilePlan.decision.fastMathDecision,
                explicitOverrideSource: compilePlan.decision.explicitOverrideSource,
                inferredMetalArgs: compilePlan.inferredMetalArgs,
                effectiveMetalArgs: compilePlan.effectiveMetalArgs
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

@main
private struct MetalAggregateCompileHarnessEntry {
    static func main() {
        do {
            exit(try MetalAggregateCompileHarnessMain.run())
        } catch {
            MetalAggregateCompileHarnessMain.writeFailureReportAndExit(error)
        }
    }
}
