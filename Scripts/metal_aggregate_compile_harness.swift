import Foundation
import Metal

private struct CompileReport: Encodable {
    let success: Bool
    let error: String?
    let functionNames: [String]
    let functionCount: Int
    let usesExplicitCompileOptions: Bool
    let fastMathEnabled: Bool?
}

private enum HarnessError: LocalizedError {
    case missingArgument(String)
    case invalidFastMathMode(String)
    case metalUnavailable

    var errorDescription: String? {
        switch self {
        case .missingArgument(let name):
            return "missing required argument: \(name)"
        case .invalidFastMathMode(let value):
            return "invalid fast math mode: \(value)"
        case .metalUnavailable:
            return "failed to create system default Metal device"
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
                success: false,
                error: error.localizedDescription,
                functionNames: [],
                functionCount: 0,
                usesExplicitCompileOptions: false,
                fastMathEnabled: nil
            )
            try? writeReport(report, to: reportPath)
        }
        fputs("error: \(error.localizedDescription)\n", stderr)
        exit(2)
    }

    private struct Arguments {
        let sourcePath: String
        let reportPath: String
        let fastMathMode: FastMathMode
    }

    private static func parseArguments(_ arguments: [String]) throws -> Arguments {
        var sourcePath: String?
        var reportPath: String?
        var fastMathMode: FastMathMode = .default
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
            case "--fast-math-mode":
                index += 1
                guard index < arguments.count else { throw HarnessError.missingArgument("--fast-math-mode") }
                guard let parsed = FastMathMode(rawValue: arguments[index]) else {
                    throw HarnessError.invalidFastMathMode(arguments[index])
                }
                fastMathMode = parsed
            default:
                break
            }
            index += 1
        }

        guard let sourcePath else { throw HarnessError.missingArgument("--source") }
        guard let reportPath else { throw HarnessError.missingArgument("--report") }
        return Arguments(sourcePath: sourcePath, reportPath: reportPath, fastMathMode: fastMathMode)
    }

    private static func parsedReportPath(_ arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: "--report"), index + 1 < arguments.count else {
            return nil
        }
        return arguments[index + 1]
    }

    private static func compileSource(_ arguments: Arguments) throws -> CompileReport {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw HarnessError.metalUnavailable
        }

        let source = try String(contentsOfFile: arguments.sourcePath, encoding: .utf8)
        let options: MTLCompileOptions?
        switch arguments.fastMathMode {
        case .default:
            options = nil
        case .enable, .disable:
            let compileOptions = MTLCompileOptions()
            compileOptions.fastMathEnabled = arguments.fastMathMode.fastMathEnabled ?? false
            options = compileOptions
        }

        do {
            let library = try device.makeLibrary(source: source, options: options)
            return CompileReport(
                success: true,
                error: nil,
                functionNames: library.functionNames.sorted(),
                functionCount: library.functionNames.count,
                usesExplicitCompileOptions: arguments.fastMathMode.usesExplicitCompileOptions,
                fastMathEnabled: arguments.fastMathMode.fastMathEnabled
            )
        } catch {
            return CompileReport(
                success: false,
                error: error.localizedDescription,
                functionNames: [],
                functionCount: 0,
                usesExplicitCompileOptions: arguments.fastMathMode.usesExplicitCompileOptions,
                fastMathEnabled: arguments.fastMathMode.fastMathEnabled
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
