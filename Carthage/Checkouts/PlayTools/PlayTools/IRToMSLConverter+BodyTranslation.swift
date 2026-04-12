import Foundation

extension IRToMSLConverter {
    // MARK: - IR Body Parser (E-004e4a)

    /// SSA 寄存器上下文：追踪 IR SSA 值到 MSL 表达式的映射。
    ///
    /// LLVM IR 使用 SSA（Static Single Assignment）形式，每个值只赋值一次。
    /// 本上下文维护 `%N` / `%name` → MSL 表达式字符串的映射，
    /// 将 IR 指令流翻译为线性的 MSL 语句序列。
    // MARK: - Phi Info (E-004e4b)

    /// 描述一条 phi 指令：来自哪些前驱 BB 取哪些值
    struct PhiInfo {
        /// phi 的目标 SSA 名（%N）
        let ssaName: String
        /// phi 的 IR 类型
        let irType: String
        /// 分配的 MSL 变量名
        let mslVarName: String
        /// 来源列表：(value 操作数文本, 来源基本块标签)
        let incoming: [(value: String, label: String)]
    }

    /// 描述一条 br 指令
    enum BranchInfo {
        /// 条件跳转: br i1 %cond, label %trueLabel, label %falseLabel
        case conditional(cond: String, trueLabel: String, falseLabel: String)
        /// 无条件跳转: br label %dest
        case unconditional(dest: String)
    }

    /// 描述一个基本块的预扫描信息
    struct BasicBlockInfo {
        let label: String
        var phiNodes: [PhiInfo] = []
        var branch: BranchInfo?
        /// 该 BB 的前驱列表
        var predecessors: [String] = []
    }

    class SSAContext {
        /// %N → MSL 表达式 或 临时变量名
        var values: [String: String] = [:]
        /// %N → MSL 类型（用于需要类型信息的操作）
        var types: [String: String] = [:]
        /// 生成的 MSL 语句（按顺序）
        var statements: [String] = []
        var indentLevel: Int = 0
        /// 下一个临时变量编号
        var nextTemp: Int = 0
        /// 函数参数名映射（IR 参数 %N → MSL 参数名）
        var paramNames: [String: String] = [:]
        /// 函数参数类型映射
        var paramTypes: [String: String] = [:]
        var emittedSamplerStateGlobals: Set<String> = []
        /// 当前函数的 MSL 返回类型
        var functionReturnType: String = ""
        var functionReturnFieldTypes: [String] = []
        /// 指针值集合（IR 参数/GEP/alloca 等会产出"地址"语义的 SSA）
        var pointerValues: Set<String> = []
        /// 指针 SSA → 指向的元素 MSL 类型（如 "uint4"、"int"、"float2"）
        /// 用于 load/store 时检测 signedness mismatch 并插入 as_type<> bitcast
        var pointerElementTypes: [String: String] = [:]
        /// SSA 结果的直接消费者 opcode 集合，用于极窄的 lowering 判定。
        var immediateUserOpcodes: [String: Set<String>] = [:]

        // ── E-004e4b: CFG + phi 支持 ──

        /// 预扫描的基本块信息（label → info）
        var bbInfo: [String: BasicBlockInfo] = [:]
        /// phi 变量预声明：SSA 名 → MSL 变量名
        var phiVarNames: [String: String] = [:]
        /// 当前正在翻译的基本块标签
        var currentBBLabel: String = "entry"
        /// phi 变量声明语句（插入到函数体最前面）
        var phiDeclarations: [String] = []

        // ── E-004e4c: 结构体类型信息 ──

        /// IR 结构体定义表（%struct.XXX → 字段 IR 类型列表）
        var structTypeDefs: [String: IRStructTypeDef] = [:]
        /// MSL 类型名 → 字段信息（从 metadata air.struct_type_info 获取）
        var structFieldInfo: [String: [StructFieldInfo]] = [:]
        /// insertvalue 链追踪：SSA 名 → 已填充的字段表达式数组
        var insertValueFields: [String: [String]] = [:]
        var insertElementComponents: [String: [String]] = [:]

        // ── E-004e4c: 结构体辅助查找 ──

        /// 根据 IR 结构体类型名（如 "%struct.Particle"）和字段索引，查找字段名。
        /// 先通过 structTypeDefs 获取字段 IR 类型列表确认索引有效，
        /// 再通过 structFieldInfo 匹配字段名。
        func lookupFieldName(irStructType: String, fieldIndex: Int) -> String? {
            // 从 IR 结构体名提取 MSL 类型名："%struct.Particle" → "Particle"
            let mslTypeName = irStructTypeToMSLName(irStructType)
            if let fields = structFieldInfo[mslTypeName],
               fieldIndex < fields.count {
                return fields[fieldIndex].fieldName
            }
            return nil
        }

        /// 根据 IR 结构体类型名（如 "%struct.Particle"）和字段索引，查找字段的 MSL 类型名。
        func lookupFieldType(irStructType: String, fieldIndex: Int) -> String? {
            let mslTypeName = irStructTypeToMSLName(irStructType)
            if let fields = structFieldInfo[mslTypeName],
               fieldIndex < fields.count {
                return fields[fieldIndex].typeName
            }
            // 回退：从 IR 结构体定义查找字段 IR 类型
            if let def = structTypeDefs[irStructType],
               fieldIndex < def.fieldIRTypes.count {
                return IRToMSLConverter.irScalarTypeToMSL(def.fieldIRTypes[fieldIndex])
            }
            return nil
        }

        /// 从 insertvalue 链追踪缓存中读取指定字段值。
        func lookupInsertedFieldValue(aggregateSSA: String, fieldIndex: Int) -> String? {
            let key = aggregateSSA.trimmingCharacters(in: .whitespaces)
            guard let fields = insertValueFields[key], fieldIndex >= 0, fieldIndex < fields.count else {
                return nil
            }
            return fields[fieldIndex]
        }

        func lookupInsertedElementComponent(vectorSSA: String, elementIndex: Int) -> String? {
            let key = vectorSSA.trimmingCharacters(in: .whitespaces)
            guard let components = insertElementComponents[key],
                  elementIndex >= 0,
                  elementIndex < components.count else {
                return nil
            }
            return components[elementIndex]
        }

        /// 将 IR 结构体类型名转换为 MSL 类型名
        func irStructTypeToMSLName(_ irName: String) -> String {
            // "%struct.Particle" → "Particle"
            // "%struct.metal::matrix" → "metal::matrix"
            // "%\"struct.metal::matrix\"" → "metal::matrix"
            var name = irName
            if name.hasPrefix("%\"") && name.hasSuffix("\"") {
                name = String(name.dropFirst(2).dropLast())
            } else if name.hasPrefix("%") {
                name = String(name.dropFirst())
            }
            if name.hasPrefix("struct.") {
                name = String(name.dropFirst("struct.".count))
            }
            return name
        }

        func freshTemp() -> String {
            let name = "t\(nextTemp)"
            nextTemp += 1
            return name
        }

        /// 查找 SSA 值对应的 MSL 表达式
        func resolve(_ ssaName: String) -> String {
            let name = ssaName.trimmingCharacters(in: .whitespaces)
            if let expr = values[name] { return expr }
            if let pname = paramNames[name] { return pname }
            // 字面量常量
            if name.hasPrefix("splat (") || name.hasPrefix("zeroinitializer") {
                return name
            }
            // undef / poison — 必须统一转为 0，不能泄漏到 MSL
            if name == "undef" || name == "poison" {
                return "0"
            }
            return name
        }

        func markPointer(_ ssaName: String, elementType: String = "") {
            pointerValues.insert(ssaName.trimmingCharacters(in: .whitespaces))
            if !elementType.isEmpty {
                pointerElementTypes[ssaName.trimmingCharacters(in: .whitespaces)] = elementType
            }
        }

        func isPointerLike(_ operand: String) -> Bool {
            let name = operand.trimmingCharacters(in: .whitespaces)
            if pointerValues.contains(name) {
                return true
            }
            if let expr = values[name], IRToMSLConverter.stripAddressOfExpression(expr) != nil {
                return true
            }
            return false
        }

        func recordImmediateUse(of ssaName: String, by opcode: String) {
            let key = ssaName.trimmingCharacters(in: .whitespaces)
            guard key.hasPrefix("%"), !opcode.isEmpty else { return }
            immediateUserOpcodes[key, default: []].insert(opcode)
        }

        func immediateUsers(of ssaName: String) -> Set<String> {
            immediateUserOpcodes[ssaName.trimmingCharacters(in: .whitespaces)] ?? []
        }

        /// 记录一个 SSA 值的 MSL 表达式和类型
        func define(_ ssaName: String, expr: String, type: String = "") {
            values[ssaName] = expr
            if !type.isEmpty { types[ssaName] = type }
        }

        /// 发射一条 MSL 语句到输出
        func emit(_ stmt: String) {
            let indent = String(repeating: "    ", count: max(0, indentLevel))
            statements.append(indent + stmt)
        }

        /// 为 SSA 值分配临时变量并发射赋值语句
        func emitAssign(_ ssaName: String, type: String, expr: String) {
            let mslType = IRToMSLConverter.irScalarTypeToMSL(type)
            let temp = freshTemp()
            emit("\(mslType) \(temp) = \(expr);")
            define(ssaName, expr: temp, type: mslType)
        }

        /// 简洁版：推断类型时直接用 auto
        func emitAutoAssign(_ ssaName: String, expr: String, knownType: String = "") {
            let temp = freshTemp()
            let typeStr = knownType.isEmpty ? "auto" : knownType
            emit("\(typeStr) \(temp) = \(expr);")
            define(ssaName, expr: temp, type: knownType)
        }
    }

    /// 解析并翻译单个函数体的 IR 指令为 MSL 语句。
    ///
    /// 当前支持的指令类别（E-004e4a）：
    /// - 算术: fadd, fmul, fsub, fneg, add, sub, mul, udiv, sdiv, urem, srem
    /// - 浮点比较/整数比较: fcmp, icmp
    /// - 选择: select
    /// - 向量: shufflevector, extractelement, insertelement, extractvalue, insertvalue
    /// - 内存: load, store, getelementptr
    /// - 类型转换: zext, sext, trunc, fpext, fptrunc, bitcast, freeze
    /// - 控制流: ret, br → if/else 块 (E-004e4b)
    /// - air.* 内建调用: call/tail call @air.*
    /// - LLVM 内建: llvm.lifetime.* (忽略)
    ///
    /// E-004e4b 改进：
    /// - 两遍翻译：第一遍预扫描 phi 和 CFG，第二遍利用预扫描信息翻译
    /// - phi 节点 → 变量预声明 + 在前驱 BB 末尾赋值
    /// - 条件 br → if/else 块结构
    /// - 无条件 br → 忽略（fall-through）
    ///
    /// E-004e4c: 结构体路径还原（已完成）
    /// - extractvalue → 直接透传（匿名聚合）或 `.fieldName`（命名结构体）
    /// - insertvalue → 链式追踪，生成 `{ val0, val1, ... }`
    /// - GEP → 按类型层级解析，结构体字段用 `.fieldName`，数组用 `[idx]`
    static func translateFunctionBody(
        _ func_: ParsedShaderFunction,
        irParamList: String,
        structTypeDefs: [String: IRStructTypeDef] = [:],
        structFieldInfo: [String: [StructFieldInfo]] = [:],
        forcedPointerArgIndices: Set<Int> = [],
        emittedSamplerStateGlobals: Set<String> = []
    ) -> [String] {
        let ctx = SSAContext()
        ctx.emittedSamplerStateGlobals = emittedSamplerStateGlobals
        ctx.functionReturnType = func_.returnType
        ctx.functionReturnFieldTypes = func_.outputs.enumerated().map { index, output in
            entryOutputFieldType(for: output, index: index)
        }
        // E-004e4c: 传入结构体信息供 extractvalue/insertvalue/GEP 使用
        ctx.structTypeDefs = structTypeDefs
        ctx.structFieldInfo = structFieldInfo

        // 建立参数名映射：IR 的 %0, %1, ... → MSL 参数名
        setupParameterMappings(
            ctx,
            params: func_.parameters,
            irParamList: irParamList,
            shaderType: func_.shaderType,
            forcedPointerArgIndices: forcedPointerArgIndices
        )

        // E-006b6: IR 参数实际类型与 MSL 参数声明的类型不匹配修复
        // 某些 AIR IR 中，builtin 参数（如 thread_position_in_grid）的 IR 实际类型是 float 向量
        // （<3 x float>），但 metadata 的 air.arg_type_name 说是 uint 向量（"uint3"）。
        // 这导致 MSL 中参数声明为 uint3 但函数体内被当作 float3 使用，
        // 传给 sample() 等需要 float 坐标的 API 时会产生类型错误。
        // 修复：检测 IR 实际类型是 float 向量但 MSL 声明是 uint 向量的情况，
        // 在函数体开头插入 floatN(mslParam) 转换，并更新 SSA 映射。
        let rawIRParams = splitIRParameters(irParamList)
        for (i, rawParam) in rawIRParams.enumerated() {
            let typed = splitTypedOperands(rawParam, count: 1)
            guard let first = typed.first, !first.type.isEmpty else { continue }
            let irActualType = first.type
            // 仅处理 IR 实际类型是 float 向量的情况
            guard irActualType.contains("float") || irActualType.contains("half") else { continue }
            let irParamName = extractParamName(from: rawParam)
            guard let name = irParamName else { continue }
            let ssaName = "%\(name)"
            // 检查 MSL 参数类型是否是 uint 向量（来自 metadata 的 air.arg_type_name）
            if let mslParamType = ctx.paramTypes[ssaName],
               (mslParamType.contains("uint") || mslParamType.contains("int")),
               !mslParamType.contains("float") {
                let mslName = ctx.paramNames[ssaName] ?? "param\(i)"
                let floatMSLType = irScalarTypeToMSL(irActualType)
                let convertedName = ctx.freshTemp()
                ctx.emit("\(floatMSLType) \(convertedName) = \(floatMSLType)(\(mslName));")
                ctx.define(ssaName, expr: convertedName, type: irActualType)
            }
        }

        let bodyLines = func_.irBody.components(separatedBy: "\n")

        // ── 第一遍：预扫描 phi 节点和 CFG 结构 (E-004e4b) ──
        prescanPhiAndCFG(bodyLines, ctx: ctx)
        prescanImmediateUsers(bodyLines, ctx: ctx)

        // 发射 phi 变量预声明（在函数体最前面）
        for decl in ctx.phiDeclarations {
            ctx.emit(decl)
        }

        let blockLines = buildBasicBlockLineMap(bodyLines)
        if shouldEmitStructuredCFG(blockLines, ctx: ctx) {
            var emittedBlocks: Set<String> = []
            emitStructuredBasicBlock(
                "entry",
                bodyLines: bodyLines,
                blockLines: blockLines,
                ctx: ctx,
                emittedBlocks: &emittedBlocks
            )
        } else {
            emitLinearizedFunctionBody(bodyLines, ctx: ctx)
        }

        return ctx.statements
    }

    static func buildBasicBlockLineMap(_ lines: [String]) -> [String: [String]] {
        var blocks: [String: [String]] = ["entry": []]
        var currentLabel = "entry"

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if let label = parseBBLabel(trimmed) {
                currentLabel = label
                if blocks[label] == nil {
                    blocks[label] = []
                }
                continue
            }
            blocks[currentLabel, default: []].append(trimmed)
        }

        return blocks
    }

    static func shouldEmitStructuredCFG(_ blockLines: [String: [String]], ctx: SSAContext) -> Bool {
        let blocksWithBranches = ctx.bbInfo.values.filter { $0.branch != nil }
        guard !blocksWithBranches.isEmpty else {
            return false
        }

        for block in blocksWithBranches {
            for successor in successorLabels(for: block.label, ctx: ctx) {
                guard blockLines[successor] != nil else {
                    return false
                }
            }
        }

        return true
    }

    static func emitLinearizedFunctionBody(_ bodyLines: [String], ctx: SSAContext) {
        for line in bodyLines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            if trimmed.hasSuffix(":") && !trimmed.contains(" ") {
                ctx.currentBBLabel = String(trimmed.dropLast())
                ctx.emit("// BB: \(trimmed)")
                continue
            }
            if let colonIdx = trimmed.firstIndex(of: ":"),
               trimmed[trimmed.startIndex..<colonIdx].allSatisfy({ $0.isNumber || $0.isLetter || $0 == "_" }) {
                let labelCandidate = String(trimmed[trimmed.startIndex..<colonIdx])
                let afterColon = trimmed.index(after: colonIdx)
                if afterColon == trimmed.endIndex ||
                   trimmed[afterColon...].trimmingCharacters(in: .whitespaces).isEmpty ||
                   trimmed[afterColon...].trimmingCharacters(in: .whitespaces).hasPrefix(";") {
                    ctx.currentBBLabel = labelCandidate
                    ctx.emit("// BB\(labelCandidate):")
                    continue
                }
            }

            translateInstruction(trimmed, ctx: ctx)
        }
    }

    static func emitStructuredBasicBlock(
        _ label: String,
        stopBefore stopLabel: String? = nil,
        bodyLines: [String],
        blockLines: [String: [String]],
        ctx: SSAContext,
        emittedBlocks: inout Set<String>
    ) {
        if let stopLabel, label == stopLabel {
            return
        }
        guard !emittedBlocks.contains(label) else { return }
        emittedBlocks.insert(label)
        ctx.currentBBLabel = label

        let lines = blockLines[label] ?? []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if isPhiInstruction(trimmed) {
                translateInstruction(trimmed, ctx: ctx)
                continue
            }
            if trimmed.hasPrefix("br ") {
                if emitStructuredConditionalBranch(
                    trimmed,
                    currentLabel: label,
                    stopBefore: stopLabel,
                    bodyLines: bodyLines,
                    blockLines: blockLines,
                    ctx: ctx,
                    emittedBlocks: &emittedBlocks
                ) {
                    return
                }

                translateBr(trimmed, ctx: ctx)
                if case .unconditional(let dest)? = parseBrInstruction(trimmed) {
                    if let stopLabel, dest == stopLabel {
                        return
                    }
                    if canEagerlyEmitSuccessor(
                        dest,
                        from: label,
                        ctx: ctx,
                        emittedBlocks: emittedBlocks
                    ) {
                        emitStructuredBasicBlock(
                            dest,
                            stopBefore: stopLabel,
                            bodyLines: bodyLines,
                            blockLines: blockLines,
                            ctx: ctx,
                            emittedBlocks: &emittedBlocks
                        )
                    } else {
                        emitBlocksInSourceOrderAfter(
                            label,
                            stopBefore: stopLabel,
                            bodyLines: bodyLines,
                            blockLines: blockLines,
                            ctx: ctx,
                            emittedBlocks: &emittedBlocks
                        )
                    }
                } else if case .conditional? = parseBrInstruction(trimmed) {
                    emitBlocksInSourceOrderAfter(
                        label,
                        stopBefore: stopLabel,
                        bodyLines: bodyLines,
                        blockLines: blockLines,
                        ctx: ctx,
                        emittedBlocks: &emittedBlocks
                    )
                }
                return
            }
            translateInstruction(trimmed, ctx: ctx)
        }
    }

    static func emitStructuredConditionalBranch(
        _ line: String,
        currentLabel: String,
        stopBefore stopLabel: String? = nil,
        bodyLines: [String],
        blockLines: [String: [String]],
        ctx: SSAContext,
        emittedBlocks: inout Set<String>
    ) -> Bool {
        guard case .conditional(let condValue, let trueLabel, let falseLabel)? = parseBrInstruction(line),
              let shape = findStructuredConditionalShape(
                  currentLabel: currentLabel,
                  trueLabel: trueLabel,
                  falseLabel: falseLabel,
                  stopBefore: stopLabel,
                  ctx: ctx,
                  blockLines: blockLines
              ) else {
            return false
        }

        let cond = resolveIROperand(condValue, ctx: ctx)
        let mergeLabel = shape.mergeLabel

        ctx.emit("if (\(cond)) {")
        ctx.indentLevel += 1
        emitStructuredBranchArm(
            trueLabel,
            from: currentLabel,
            stopBefore: mergeLabel,
            bodyLines: bodyLines,
            blockLines: blockLines,
            ctx: ctx,
            emittedBlocks: &emittedBlocks
        )
        ctx.indentLevel -= 1
        ctx.emit("} else {")
        ctx.indentLevel += 1
        emitStructuredBranchArm(
            falseLabel,
            from: currentLabel,
            stopBefore: mergeLabel,
            bodyLines: bodyLines,
            blockLines: blockLines,
            ctx: ctx,
            emittedBlocks: &emittedBlocks
        )
        ctx.indentLevel -= 1
        ctx.emit("}")

        if stopLabel != mergeLabel,
           canEmitStructuredMerge(
               mergeLabel,
               expectedPredecessors: shape.mergePredecessors,
               ctx: ctx,
               emittedBlocks: emittedBlocks
           ) {
            emitStructuredBasicBlock(
                mergeLabel,
                stopBefore: stopLabel,
                bodyLines: bodyLines,
                blockLines: blockLines,
                ctx: ctx,
                emittedBlocks: &emittedBlocks
            )
        }
        return true
    }

    static func emitStructuredBranchArm(
        _ label: String,
        from predecessorLabel: String,
        stopBefore stopLabel: String,
        bodyLines: [String],
        blockLines: [String: [String]],
        ctx: SSAContext,
        emittedBlocks: inout Set<String>
    ) {
        if label == stopLabel {
            let phiAssignments = collectPhiAssignments(forTarget: stopLabel, fromPred: predecessorLabel, ctx: ctx)
            for assignment in phiAssignments {
                ctx.emit(assignment)
            }
            return
        }
        guard !emittedBlocks.contains(label) else { return }
        emittedBlocks.insert(label)
        ctx.currentBBLabel = label

        let lines = blockLines[label] ?? []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || isPhiInstruction(trimmed) { continue }
            if trimmed.hasPrefix("br ") {
                if emitStructuredConditionalBranch(
                    trimmed,
                    currentLabel: label,
                    stopBefore: stopLabel,
                    bodyLines: bodyLines,
                    blockLines: blockLines,
                    ctx: ctx,
                    emittedBlocks: &emittedBlocks
                ) {
                    return
                }

                translateBr(trimmed, ctx: ctx)
                if case .unconditional(let dest)? = parseBrInstruction(trimmed) {
                    if dest == stopLabel {
                        return
                    }
                    if canEagerlyEmitSuccessor(
                        dest,
                        from: label,
                        ctx: ctx,
                        emittedBlocks: emittedBlocks
                    ) {
                        emitStructuredBasicBlock(
                            dest,
                            stopBefore: stopLabel,
                            bodyLines: bodyLines,
                            blockLines: blockLines,
                            ctx: ctx,
                            emittedBlocks: &emittedBlocks
                        )
                    } else {
                        emitBlocksInSourceOrderAfter(
                            label,
                            stopBefore: stopLabel,
                            bodyLines: bodyLines,
                            blockLines: blockLines,
                            ctx: ctx,
                            emittedBlocks: &emittedBlocks
                        )
                    }
                } else if case .conditional? = parseBrInstruction(trimmed) {
                    emitBlocksInSourceOrderAfter(
                        label,
                        stopBefore: stopLabel,
                        bodyLines: bodyLines,
                        blockLines: blockLines,
                        ctx: ctx,
                        emittedBlocks: &emittedBlocks
                    )
                }
                return
            }
            translateInstruction(trimmed, ctx: ctx)
        }
    }

    static func emitBlocksInSourceOrderAfter(
        _ label: String,
        stopBefore stopLabel: String? = nil,
        bodyLines: [String],
        blockLines: [String: [String]],
        ctx: SSAContext,
        emittedBlocks: inout Set<String>
    ) {
        var foundStartLabel = label == "entry"
        var orderedLabels: [String] = []

        for line in bodyLines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, let parsedLabel = parseBBLabel(trimmed) else { continue }

            if !foundStartLabel {
                if parsedLabel == label {
                    foundStartLabel = true
                }
                continue
            }
            if let stopLabel, parsedLabel == stopLabel {
                break
            }
            orderedLabels.append(parsedLabel)
        }

        var pendingLabels = orderedLabels.filter { !emittedBlocks.contains($0) }
        var madeProgress = true
        while madeProgress, !pendingLabels.isEmpty {
            madeProgress = false
            var deferredLabels: [String] = []

            for nextLabel in pendingLabels {
                guard canEmitDeferredBlock(nextLabel, ctx: ctx, emittedBlocks: emittedBlocks) else {
                    deferredLabels.append(nextLabel)
                    continue
                }
                let beforeCount = emittedBlocks.count
                emitStructuredBasicBlock(
                    nextLabel,
                    stopBefore: stopLabel,
                    bodyLines: bodyLines,
                    blockLines: blockLines,
                    ctx: ctx,
                    emittedBlocks: &emittedBlocks
                )
                if emittedBlocks.count > beforeCount {
                    madeProgress = true
                }
            }

            pendingLabels = deferredLabels.filter { !emittedBlocks.contains($0) }
        }

        for nextLabel in pendingLabels where !emittedBlocks.contains(nextLabel) {
            emitStructuredBasicBlock(
                nextLabel,
                stopBefore: stopLabel,
                bodyLines: bodyLines,
                blockLines: blockLines,
                ctx: ctx,
                emittedBlocks: &emittedBlocks
            )
        }
    }

    static func findStructuredConditionalShape(
        currentLabel: String,
        trueLabel: String,
        falseLabel: String,
        stopBefore stopLabel: String?,
        ctx: SSAContext,
        blockLines: [String: [String]]
    ) -> (mergeLabel: String, mergePredecessors: [String])? {
        guard blockLines[trueLabel] != nil,
              blockLines[falseLabel] != nil else {
            return nil
        }

        let trueDistances = reachableLabelDistances(from: trueLabel, stopBefore: stopLabel, ctx: ctx)
        let falseDistances = reachableLabelDistances(from: falseLabel, stopBefore: stopLabel, ctx: ctx)
        let trueReachable = Set(trueDistances.keys)
        let falseReachable = Set(falseDistances.keys)
        let commonCandidates = trueReachable.intersection(falseReachable).filter { label in
            guard label != currentLabel,
                  blockLines[label] != nil else {
                return false
            }
            if let stopLabel, label == stopLabel {
                return true
            }
            return (ctx.bbInfo[label]?.predecessors.count ?? 0) > 1
        }

        guard !commonCandidates.isEmpty else {
            return nil
        }

        let orderedCandidates = commonCandidates.compactMap { label -> (String, Int, Int)? in
            guard let trueDistance = trueDistances[label],
                  let falseDistance = falseDistances[label] else {
                return nil
            }
            return (label, trueDistance + falseDistance, max(trueDistance, falseDistance))
        }.sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
            if lhs.2 != rhs.2 { return lhs.2 < rhs.2 }
            return lhs.0 < rhs.0
        }

        for (candidate, _, _) in orderedCandidates {
            let mergePredecessors = ctx.bbInfo[candidate]?.predecessors.filter {
                trueReachable.contains($0) || falseReachable.contains($0)
            } ?? []
            if !mergePredecessors.isEmpty {
                return (candidate, mergePredecessors)
            }
        }

        return nil
    }

    static func reachableLabelDistances(
        from startLabel: String,
        stopBefore stopLabel: String?,
        ctx: SSAContext
    ) -> [String: Int] {
        var distances: [String: Int] = [startLabel: 0]
        var queue: [String] = [startLabel]
        var queueIndex = 0

        while queueIndex < queue.count {
            let label = queue[queueIndex]
            queueIndex += 1
            let nextDistance = (distances[label] ?? 0) + 1

            for successor in successorLabels(for: label, ctx: ctx) {
                if let stopLabel, successor == stopLabel {
                    if distances[successor] == nil || nextDistance < (distances[successor] ?? Int.max) {
                        distances[successor] = nextDistance
                    }
                    continue
                }
                if distances[successor] != nil {
                    continue
                }
                distances[successor] = nextDistance
                queue.append(successor)
            }
        }

        return distances
    }

    static func successorLabels(for label: String, ctx: SSAContext) -> [String] {
        guard let branch = ctx.bbInfo[label]?.branch else {
            return []
        }
        switch branch {
        case .conditional(_, let trueLabel, let falseLabel):
            return [trueLabel, falseLabel]
        case .unconditional(let dest):
            return [dest]
        }
    }

    static func canEagerlyEmitSuccessor(
        _ label: String,
        from predecessor: String,
        ctx: SSAContext,
        emittedBlocks: Set<String>
    ) -> Bool {
        guard let bbInfo = ctx.bbInfo[label] else {
            return true
        }
        let pendingPredecessors = bbInfo.predecessors.filter {
            $0 != predecessor && !emittedBlocks.contains($0)
        }
        return pendingPredecessors.isEmpty
    }

    static func canEmitStructuredMerge(
        _ label: String,
        expectedPredecessors: [String],
        ctx: SSAContext,
        emittedBlocks: Set<String>
    ) -> Bool {
        guard let bbInfo = ctx.bbInfo[label] else {
            return true
        }
        let expected = Set(expectedPredecessors)
        let pendingPredecessors = bbInfo.predecessors.filter {
            !expected.contains($0) && !emittedBlocks.contains($0)
        }
        return pendingPredecessors.isEmpty
    }

    static func canEmitDeferredBlock(
        _ label: String,
        ctx: SSAContext,
        emittedBlocks: Set<String>
    ) -> Bool {
        guard let bbInfo = ctx.bbInfo[label] else {
            return true
        }
        if bbInfo.predecessors.isEmpty || label == "entry" {
            return true
        }
        return bbInfo.predecessors.allSatisfy { emittedBlocks.contains($0) }
    }

    static func isPhiInstruction(_ line: String) -> Bool {
        guard let eqRange = line.range(of: " = ") else { return false }
        let rhs = String(line[eqRange.upperBound...]).trimmingCharacters(in: .whitespaces)
        return rhs.hasPrefix("phi ")
    }

    // MARK: - CFG Prescan (E-004e4b)

    /// 第一遍预扫描：收集所有 phi 节点和分支信息，建立 CFG。
    ///
    /// 目的：
    /// 1. 找到所有 phi 节点，为每个 phi 分配 MSL 变量名并预声明
    /// 2. 收集每个 BB 的终止分支信息（条件 br / 无条件 br）
    /// 3. 建立前驱关系，用于在前驱 BB 的 br 处插入 phi 赋值
    static func prescanPhiAndCFG(_ lines: [String], ctx: SSAContext) {
        var currentLabel = "entry"
        var allBBs: [String: BasicBlockInfo] = [:]
        allBBs["entry"] = BasicBlockInfo(label: "entry")

        // 收集的 phi 信息（后续处理）
        var allPhis: [(bbLabel: String, phi: PhiInfo)] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            // 基本块标签
            if let label = parseBBLabel(trimmed) {
                currentLabel = label
                if allBBs[label] == nil {
                    allBBs[label] = BasicBlockInfo(label: label)
                }
                continue
            }

            // phi 指令：%N = phi <type> [val, %label], [val, %label], ...
            if let eqRange = trimmed.range(of: " = ") {
                let lhs = String(trimmed[trimmed.startIndex..<eqRange.lowerBound])
                    .trimmingCharacters(in: .whitespaces)
                let rhs = String(trimmed[eqRange.upperBound...])
                    .trimmingCharacters(in: .whitespaces)
                if lhs.hasPrefix("%") && rhs.hasPrefix("phi ") {
                    if let phi = parsePhiInstruction(lhs: lhs, rhs: rhs, ctx: ctx) {
                        allPhis.append((bbLabel: currentLabel, phi: phi))
                        allBBs[currentLabel]?.phiNodes.append(phi)
                    }
                    continue
                }
            }

            // br 指令
            if trimmed.hasPrefix("br ") {
                let brInfo = parseBrInstruction(trimmed)
                allBBs[currentLabel]?.branch = brInfo
                // 建立前驱关系
                switch brInfo {
                case .conditional(_, let trueLabel, let falseLabel):
                    if allBBs[trueLabel] == nil {
                        allBBs[trueLabel] = BasicBlockInfo(label: trueLabel)
                    }
                    allBBs[trueLabel]?.predecessors.append(currentLabel)
                    if allBBs[falseLabel] == nil {
                        allBBs[falseLabel] = BasicBlockInfo(label: falseLabel)
                    }
                    allBBs[falseLabel]?.predecessors.append(currentLabel)
                case .unconditional(let dest):
                    if allBBs[dest] == nil {
                        allBBs[dest] = BasicBlockInfo(label: dest)
                    }
                    allBBs[dest]?.predecessors.append(currentLabel)
                case .none:
                    break
                }
            }
        }

        ctx.bbInfo = allBBs

        // 为每个 phi 分配 MSL 变量名并生成预声明
        for (_, phi) in allPhis {
            let varName = phi.mslVarName
            ctx.phiVarNames[phi.ssaName] = varName
            ctx.define(phi.ssaName, expr: varName)

            // 预声明：用 phi 的 IR 类型推断 MSL 类型
            let mslType = irScalarTypeToMSL(phi.irType)
            ctx.phiDeclarations.append("\(mslType) \(varName); // phi pre-decl")
        }
    }

    static func prescanImmediateUsers(_ lines: [String], ctx: SSAContext) {
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            guard let eqRange = trimmed.range(of: " = ") else { continue }
            let rhs = String(trimmed[eqRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            let opcode = instructionOpcodeForPrescan(rhs)
            guard !opcode.isEmpty else { continue }
            for operand in referencedSSAOperandsForPrescan(rhs) {
                ctx.recordImmediateUse(of: operand, by: opcode)
            }
        }
    }

    static func instructionOpcodeForPrescan(_ rhs: String) -> String {
        let tokens = rhs.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard let first = tokens.first else { return "" }
        switch first {
        case "tail", "musttail", "notail":
            return tokens.dropFirst().first ?? first
        default:
            return first
        }
    }

    static func referencedSSAOperandsForPrescan(_ text: String) -> [String] {
        let source = String(text.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        guard let regex = try? NSRegularExpression(pattern: "%(?:\\\"[^\\\"]+\\\"|[-A-Za-z0-9_.$]+)") else {
            return []
        }

        let nsSource = source as NSString
        var seen: Set<String> = []
        var results: [String] = []
        for match in regex.matches(in: source, range: NSRange(location: 0, length: nsSource.length)) {
            let value = nsSource.substring(with: match.range)
            if seen.insert(value).inserted {
                results.append(value)
            }
        }
        return results
    }

    /// 解析基本块标签，返回标签名或 nil
    static func parseBBLabel(_ trimmed: String) -> String? {
        // 纯名字+冒号: "entry:" "10:"
        if trimmed.hasSuffix(":") && !trimmed.contains(" ") {
            return String(trimmed.dropLast())
        }
        // 带前驱注释: "10:  ; preds = %7"
        if let colonIdx = trimmed.firstIndex(of: ":") {
            let labelCandidate = String(trimmed[trimmed.startIndex..<colonIdx])
            if labelCandidate.allSatisfy({ $0.isNumber || $0.isLetter || $0 == "_" }) {
                let afterColon = trimmed.index(after: colonIdx)
                if afterColon == trimmed.endIndex ||
                   trimmed[afterColon...].trimmingCharacters(in: .whitespaces).isEmpty ||
                   trimmed[afterColon...].trimmingCharacters(in: .whitespaces).hasPrefix(";") {
                    return labelCandidate
                }
            }
        }
        return nil
    }

    /// 解析 phi 指令，提取类型和来源列表
    /// phi <type> [val1, %label1], [val2, %label2], ...
    static func parsePhiInstruction(lhs: String, rhs: String, ctx: SSAContext) -> PhiInfo? {
        // rhs = "phi <type> [val, %label], [val, %label], ..."
        var cleaned = rhs
        // 去掉 "phi "
        guard cleaned.hasPrefix("phi ") else { return nil }
        cleaned = String(cleaned.dropFirst(4)).trimmingCharacters(in: .whitespaces)

        // 提取类型：到第一个 '[' 之前
        guard let firstBracket = cleaned.firstIndex(of: "[") else { return nil }
        let irType = String(cleaned[cleaned.startIndex..<firstBracket]).trimmingCharacters(in: .whitespaces)

        // 解析所有 [value, %label] 对
        var incoming: [(value: String, label: String)] = []
        var remaining = String(cleaned[firstBracket...])

        while let openBracket = remaining.firstIndex(of: "["),
              let closeBracket = remaining.firstIndex(of: "]"),
              openBracket < closeBracket {
            let inner = remaining[remaining.index(after: openBracket)..<closeBracket]
            let parts = inner.components(separatedBy: ",")
            if parts.count >= 2 {
                let value = parts[0].trimmingCharacters(in: .whitespaces)
                var label = parts[1].trimmingCharacters(in: .whitespaces)
                // 去掉 % 前缀
                if label.hasPrefix("%") {
                    label = String(label.dropFirst())
                }
                incoming.append((value: value, label: label))
            }
            remaining = String(remaining[remaining.index(after: closeBracket)...])
        }

        guard !incoming.isEmpty else { return nil }

        // 分配 MSL 变量名
        let varName = "phi_\(ctx.nextTemp)"
        ctx.nextTemp += 1

        return PhiInfo(
            ssaName: lhs,
            irType: irType,
            mslVarName: varName,
            incoming: incoming
        )
    }

    /// 解析 br 指令
    static func parseBrInstruction(_ line: String) -> BranchInfo? {
        let cleaned = line.replacingOccurrences(of: "br ", with: "").trimmingCharacters(in: .whitespaces)

        if cleaned.hasPrefix("i1 ") {
            // 条件跳转: br i1 %cond, label %trueLabel, label %falseLabel
            let parts = cleaned.components(separatedBy: ",")
            guard parts.count >= 3 else { return nil }
            let condStr = parts[0].replacingOccurrences(of: "i1 ", with: "")
                .trimmingCharacters(in: .whitespaces)
            let trueLabel = parts[1].trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "label %", with: "")
                .replacingOccurrences(of: "label ", with: "")
                .trimmingCharacters(in: .whitespaces)
            let falseLabel = parts[2].trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "label %", with: "")
                .replacingOccurrences(of: "label ", with: "")
                .trimmingCharacters(in: .whitespaces)
            return .conditional(cond: condStr, trueLabel: trueLabel, falseLabel: falseLabel)
        } else if cleaned.hasPrefix("label ") {
            // 无条件跳转: br label %dest
            let dest = cleaned.replacingOccurrences(of: "label %", with: "")
                .replacingOccurrences(of: "label ", with: "")
                .trimmingCharacters(in: .whitespaces)
            return .unconditional(dest: dest)
        }

        return nil
    }

    /// 建立 IR 参数（%0, %1, ...）到 MSL 参数名的映射
    static func setupParameterMappings(
        _ ctx: SSAContext,
        params: [ParsedParameter],
        irParamList: String,
        shaderType: ShaderType,
        forcedPointerArgIndices: Set<Int> = []
    ) {
        let irParams = splitIRParameters(irParamList)
        let usesStageIn = shouldUseStageInStruct(params, shaderType: shaderType)

        // 极小 fragment/kernel/vertex builtin 场景：metadata 可能把唯一 builtin 参数过滤掉，
        // 但 generateAllParams 仍会补默认 builtin 参数；此时把唯一 IR 参数接回默认 builtin 名。
        if params.isEmpty,
           irParams.count == 1,
           let builtinName = defaultBuiltinParamName(for: shaderType),
           let builtinIRType = defaultBuiltinIRType(for: shaderType) {
            let irName = extractParamName(from: irParams[0]) ?? "0"
            let ssaName = "%\(irName)"
            ctx.paramNames[ssaName] = builtinName
            ctx.paramTypes[ssaName] = builtinIRType
            return
        }

        var mappedArgIndices: Set<Int> = []

        for param in params {
            guard let irArgIndex = param.irArgIndex else { continue }
            let ssaName: String
            if irArgIndex < irParams.count {
                let irName = extractParamName(from: irParams[irArgIndex]) ?? "\(irArgIndex)"
                ssaName = "%\(irName)"
            } else {
                ssaName = "%\(irArgIndex)"
            }

            let fallbackName = "arg\(irArgIndex)"
            let resolvedBaseName = sanitizeIdentifier(param.name, fallback: fallbackName, uppercaseFirst: false)
            let resolvedName: String
            if usesStageIn && isStageInParameter(param, shaderType: shaderType) {
                resolvedName = "\(stageInParamName).\(resolvedBaseName)"
            } else {
                resolvedName = resolvedBaseName
            }

            ctx.paramNames[ssaName] = resolvedName
            if !param.irType.isEmpty {
                ctx.paramTypes[ssaName] = param.irType
            }
            if let ptr = param.pointerInfo {
                let emitsReference = ptr.addressSpace == .constant &&
                    ptr.addressSpace.isBufferAddressSpace &&
                    isStructTypeName(ptr.pointedMSLType) &&
                    !forcedPointerArgIndices.contains(irArgIndex)
                if !emitsReference {
                    ctx.markPointer(ssaName, elementType: ptr.pointedMSLType)
                }
            }
            mappedArgIndices.insert(irArgIndex)
        }

        for (i, irParam) in irParams.enumerated() where !mappedArgIndices.contains(i) {
            let irName = extractParamName(from: irParam) ?? "\(i)"
            let ssaName = "%\(irName)"
            ctx.paramNames[ssaName] = "param\(i)"
        }
    }

    static func defaultBuiltinParamName(for type: ShaderType) -> String? {
        switch type {
        case .vertex:
            return "vid"
        case .fragment:
            return "position"
        case .kernel:
            return "tid"
        case .helper:
            return nil
        }
    }

    static func defaultBuiltinIRType(for type: ShaderType) -> String? {
        switch type {
        case .vertex:
            return "i32"
        case .fragment:
            return "float4"
        case .kernel:
            return "i32"
        case .helper:
            return nil
        }
    }

    static let stageInParamName = "stageIn"

    static func shouldUseStageInStruct(
        _ params: [ParsedParameter],
        shaderType: ShaderType
    ) -> Bool {
        switch shaderType {
        case .vertex:
            return params.contains { $0.kind == "air.vertex_input" }
        case .fragment:
            return params.contains { $0.kind == "air.fragment_input" }
        case .kernel, .helper:
            return false
        }
    }

    static func isStageInParameter(
        _ param: ParsedParameter,
        shaderType: ShaderType
    ) -> Bool {
        switch shaderType {
        case .vertex:
            return param.kind == "air.vertex_input"
        case .fragment:
            switch param.kind {
            case "air.fragment_input", "air.position":
                return true
            default:
                return false
            }
        case .kernel, .helper:
            return false
        }
    }

    /// 翻译单条 IR 指令
    static func translateInstruction(_ line: String, ctx: SSAContext) {
        // 忽略 IR 注释和空行
        if line.hasPrefix(";") { return }

        // 忽略 llvm.lifetime 和 llvm.dbg 等内部调用
        if line.contains("@llvm.lifetime") || line.contains("@llvm.dbg") { return }

        // 形如 "%N = ..." 的赋值指令
        if let eqRange = line.range(of: " = ") {
            let lhs = String(line[line.startIndex..<eqRange.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            let rhs = String(line[eqRange.upperBound...])
                .trimmingCharacters(in: .whitespaces)

            if lhs.hasPrefix("%") {
                translateAssignment(lhs: lhs, rhs: rhs, ctx: ctx)
                return
            }
        }

        // 非赋值指令：ret, br, store, call void, tail call void
        if line.hasPrefix("ret ") {
            translateRet(line, ctx: ctx)
        } else if line.hasPrefix("br ") {
            translateBr(line, ctx: ctx)
        } else if line.hasPrefix("store ") {
            translateStore(line, ctx: ctx)
        } else if line.contains("call void @air.") {
            translateVoidAirCall(line, ctx: ctx)
        } else if line.contains("call void @air.") || line.contains("tail call void @air.") {
            translateVoidAirCall(line, ctx: ctx)
        } else {
            // 未识别的指令，作为注释保留
            ctx.emit("// [unhandled] \(line.prefix(120))")
        }
    }

    /// 翻译赋值指令（%N = <opcode> ...）
    static func translateAssignment(lhs: String, rhs: String, ctx: SSAContext) {
        // 确定操作码
        let parts = rhs.components(separatedBy: " ")
        guard let opcode = parts.first else {
            ctx.emit("// [unknown] \(lhs) = \(rhs.prefix(100))")
            return
        }

        switch opcode {
        // ── 二元浮点算术 ──
        case "fadd", "fmul", "fsub", "fdiv", "frem":
            translateBinaryFP(lhs: lhs, rhs: rhs, opcode: opcode, ctx: ctx)
        // ── fneg ──
        case "fneg":
            translateFNeg(lhs: lhs, rhs: rhs, ctx: ctx)
        // ── 二元整数算术 ──
        case "add", "sub", "mul", "udiv", "sdiv", "urem", "srem",
             "shl", "lshr", "ashr", "and", "or", "xor":
            translateBinaryInt(lhs: lhs, rhs: rhs, opcode: opcode, ctx: ctx)
        // ── 比较 ──
        case "fcmp":
            translateFCmp(lhs: lhs, rhs: rhs, ctx: ctx)
        case "icmp":
            translateICmp(lhs: lhs, rhs: rhs, ctx: ctx)
        // ── 选择 ──
        case "select":
            translateSelect(lhs: lhs, rhs: rhs, ctx: ctx)
        // ── 向量 ──
        case "shufflevector":
            translateShuffleVector(lhs: lhs, rhs: rhs, ctx: ctx)
        case "extractelement":
            translateExtractElement(lhs: lhs, rhs: rhs, ctx: ctx)
        case "insertelement":
            translateInsertElement(lhs: lhs, rhs: rhs, ctx: ctx)
        case "extractvalue":
            translateExtractValue(lhs: lhs, rhs: rhs, ctx: ctx)
        case "insertvalue":
            translateInsertValue(lhs: lhs, rhs: rhs, ctx: ctx)
        // ── 内存 ──
        case "load":
            translateLoad(lhs: lhs, rhs: rhs, ctx: ctx)
        case "getelementptr":
            translateGEP(lhs: lhs, rhs: rhs, ctx: ctx)
        // ── 类型转换 ──
        case "zext", "sext", "trunc", "fpext", "fptrunc", "uitofp", "sitofp", "fptoui", "fptosi":
            translateIntCast(lhs: lhs, rhs: rhs, opcode: opcode, ctx: ctx)
        case "bitcast":
            translateBitcast(lhs: lhs, rhs: rhs, ctx: ctx)
        case "freeze":
            translateFreeze(lhs: lhs, rhs: rhs, ctx: ctx)
        // ── air.* / 其他 call ──
        case "tail", "call", "musttail", "notail":
            translateCall(lhs: lhs, rhs: rhs, ctx: ctx)
        // ── phi (控制流相关，E-004e4b) ──
        case "phi":
            translatePhi(lhs: lhs, rhs: rhs, ctx: ctx)
        // ── alloca ──
        case "alloca":
            translateAlloca(lhs: lhs, rhs: rhs, ctx: ctx)
        default:
            ctx.emit("// [unhandled] \(lhs) = \(rhs.prefix(100))")
        }
    }
}
