import Foundation

struct SharedCompilePlannerManifest: Decodable {
    let schemaVersion: Int
    let fastMath: SharedCompilePlannerFastMathOptions
    let replacementSourceValidationRules: [SharedCompilePlannerValidationRule]
}

struct SharedCompilePlannerFastMathOptions: Decodable {
    let enableOption: String
    let disableOption: String
}

struct SharedCompilePlannerValidationRule: Decodable {
    let reason: String
    let pattern: String
}

enum SharedCompilePlannerBackend: String, Codable {
    case mtlDevice = "mtl-device"
    case xcrun
}

enum SharedCompilePlannerFastMathMode: String, Codable {
    case enable
    case disable

    var fastMathEnabled: Bool {
        switch self {
        case .enable:
            return true
        case .disable:
            return false
        }
    }

    var metalArgument: String {
        switch self {
        case .enable:
            return "-ffast-math"
        case .disable:
            return "-fno-fast-math"
        }
    }
}

struct SharedCompilePlannerInput: Codable {
    let originalIRTexts: [String]
    let userMetalArgs: [String]
    let requestedBackend: SharedCompilePlannerBackend

    init(
        originalIRTexts: [String],
        userMetalArgs: [String] = [],
        requestedBackend: SharedCompilePlannerBackend
    ) {
        self.originalIRTexts = originalIRTexts
        self.userMetalArgs = userMetalArgs
        self.requestedBackend = requestedBackend
    }
}

struct SharedCompilePlannerDecision: Codable {
    let fastMathMode: SharedCompilePlannerFastMathMode?
    let fastMathDecision: String
    let usesExplicitCompileOptions: Bool
    let compileOptionsFastMathEnabled: Bool?
    let explicitOverrideSource: String?
    let reason: String
}

struct SharedCompilePlannerMTLCompileOptionsPayload: Codable {
    let fastMathEnabled: Bool
}

struct SharedCompilePlannerPlan: Codable {
    let requestedBackend: SharedCompilePlannerBackend
    let decision: SharedCompilePlannerDecision
    let inferredMetalArgs: [String]
    let effectiveMetalArgs: [String]
    let mtlCompileOptionsPayload: SharedCompilePlannerMTLCompileOptionsPayload?
}

enum SharedCompilePlanner {
    private static let explicitFastMathMetalArgs: Set<String> = ["-ffast-math", "-fno-fast-math"]

    private static let sharedCompileDecisionManifestJSON = #"""
    {
      "schemaVersion": 1,
      "fastMath": {
        "enableOption": "air.compile.fast_math_enable",
        "disableOption": "air.compile.fast_math_disable"
      },
      "replacementSourceValidationRules": [
        {
          "reason": "LLVM vector syntax leaked into generated MSL",
          "pattern": "<\\s*\\d+\\s+x\\s+"
        },
        {
          "reason": "LLVM opaque pointer token leaked into generated MSL",
          "pattern": "(^|[^A-Za-z0-9_])ptr([^A-Za-z0-9_]|$)"
        },
        {
          "reason": "LLVM addrspace token leaked into generated MSL",
          "pattern": "addrspace\\s*\\("
        },
        {
          "reason": "LLVM SSA or struct token leaked into generated MSL",
          "pattern": "%[A-Za-z0-9_\\.\\\"]+"
        },
        {
          "reason": "LLVM raw integer type leaked into generated MSL",
          "pattern": "(^|[^A-Za-z0-9_])(i1|i8|i16|i32|i64)([^A-Za-z0-9_]|$)"
        },
        {
          "reason": "LLVM symbol token leaked into generated MSL",
          "pattern": "@[A-Za-z0-9_\\.\\\"]+"
        },
        {
          "reason": "LLVM placeholder token leaked into generated MSL",
          "pattern": "\\b(?:undef|poison|zeroinitializer)\\b"
        }
      ]
    }
    """#

    static let sharedCompileDecisionManifest: SharedCompilePlannerManifest = {
        guard let data = sharedCompileDecisionManifestJSON.data(using: .utf8) else {
            fatalError("[PlayTools] SharedCompilePlanner: failed to encode shared compile decision manifest")
        }
        do {
            return try JSONDecoder().decode(SharedCompilePlannerManifest.self, from: data)
        } catch {
            fatalError("[PlayTools] SharedCompilePlanner: failed to decode shared compile decision manifest — \(error)")
        }
    }()

    static func makePlan(input: SharedCompilePlannerInput) -> SharedCompilePlannerPlan {
        if let overrideMode = resolveUserFastMathOverride(in: input.userMetalArgs) {
            return makePlan(
                requestedBackend: input.requestedBackend,
                fastMathMode: overrideMode,
                reason: "user_override",
                explicitOverrideSource: "user_metal_args",
                inferredMetalArgs: [],
                effectiveMetalArgs: input.userMetalArgs
            )
        }

        let inferredModes = input.originalIRTexts.map(inferFastMathMode(from:))
        let knownModes = inferredModes.compactMap { $0 }
        guard let firstKnownMode = knownModes.first else {
            return makePlan(
                requestedBackend: input.requestedBackend,
                fastMathMode: nil,
                reason: "fast_math_unavailable",
                explicitOverrideSource: nil,
                inferredMetalArgs: [],
                effectiveMetalArgs: input.userMetalArgs
            )
        }
        guard knownModes.allSatisfy({ $0 == firstKnownMode }) else {
            return makePlan(
                requestedBackend: input.requestedBackend,
                fastMathMode: nil,
                reason: "fast_math_conflict",
                explicitOverrideSource: nil,
                inferredMetalArgs: [],
                effectiveMetalArgs: input.userMetalArgs
            )
        }
        guard knownModes.count == inferredModes.count else {
            return makePlan(
                requestedBackend: input.requestedBackend,
                fastMathMode: nil,
                reason: "fast_math_partial",
                explicitOverrideSource: nil,
                inferredMetalArgs: [],
                effectiveMetalArgs: input.userMetalArgs
            )
        }

        let inferredMetalArgs = [firstKnownMode.metalArgument]
        return makePlan(
            requestedBackend: input.requestedBackend,
            fastMathMode: firstKnownMode,
            reason: "fast_math_aligned",
            explicitOverrideSource: nil,
            inferredMetalArgs: inferredMetalArgs,
            effectiveMetalArgs: inferredMetalArgs + input.userMetalArgs
        )
    }

    static func inferFastMathMode(from originalIRText: String) -> SharedCompilePlannerFastMathMode? {
        let hasDisable = originalIRText.contains(sharedCompileDecisionManifest.fastMath.disableOption)
        let hasEnable = originalIRText.contains(sharedCompileDecisionManifest.fastMath.enableOption)
        if hasDisable && !hasEnable {
            return .disable
        }
        if hasEnable && !hasDisable {
            return .enable
        }
        return nil
    }

    private static func resolveUserFastMathOverride(in metalArgs: [String]) -> SharedCompilePlannerFastMathMode? {
        var overrideMode: SharedCompilePlannerFastMathMode?
        for arg in metalArgs {
            guard explicitFastMathMetalArgs.contains(arg) else {
                continue
            }
            if arg == "-ffast-math" {
                overrideMode = .enable
            } else if arg == "-fno-fast-math" {
                overrideMode = .disable
            }
        }
        return overrideMode
    }

    private static func makePlan(
        requestedBackend: SharedCompilePlannerBackend,
        fastMathMode: SharedCompilePlannerFastMathMode?,
        reason: String,
        explicitOverrideSource: String?,
        inferredMetalArgs: [String],
        effectiveMetalArgs: [String]
    ) -> SharedCompilePlannerPlan {
        let compileOptionsFastMathEnabled = fastMathMode?.fastMathEnabled
        let decision = SharedCompilePlannerDecision(
            fastMathMode: fastMathMode,
            fastMathDecision: reason,
            usesExplicitCompileOptions: compileOptionsFastMathEnabled != nil,
            compileOptionsFastMathEnabled: compileOptionsFastMathEnabled,
            explicitOverrideSource: explicitOverrideSource,
            reason: reason
        )
        let optionsPayload = compileOptionsFastMathEnabled.map {
            SharedCompilePlannerMTLCompileOptionsPayload(fastMathEnabled: $0)
        }
        return SharedCompilePlannerPlan(
            requestedBackend: requestedBackend,
            decision: decision,
            inferredMetalArgs: inferredMetalArgs,
            effectiveMetalArgs: effectiveMetalArgs,
            mtlCompileOptionsPayload: optionsPayload
        )
    }
}
