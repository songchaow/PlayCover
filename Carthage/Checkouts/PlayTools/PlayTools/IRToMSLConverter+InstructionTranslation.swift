import Foundation

extension IRToMSLConverter {
    // MARK: - Instruction Translators

    /// 翻译二元浮点运算: fadd/fmul/fsub/fdiv/frem
    static func translateBinaryFP(lhs: String, rhs: String, opcode: String, ctx: SSAContext) {
        // 格式: fadd [fast] <type> <op1>, <op2>
        let op: String
        switch opcode {
        case "fadd": op = "+"
        case "fmul": op = "*"
        case "fsub": op = "-"
        case "fdiv": op = "/"
        case "frem": op = "/* fmod */"
        default: op = "??"
        }

        let cleaned = rhs.replacingOccurrences(of: "\(opcode) ", with: "", options: .anchored)
        let (type, operands) = parseBinaryOperands(cleaned, skipKeywords: ["fast", "nnan", "ninf", "nsz", "arcp", "contract", "reassoc", "afn"])
        guard operands.count >= 2 else {
            ctx.define(lhs, expr: "/* parse error: \(rhs.prefix(60)) */")
            return
        }

        let a = resolveIROperand(operands[0], ctx: ctx)
        let b = resolveIROperand(operands[1], ctx: ctx)
        let mslType = irScalarTypeToMSL(type)

        if opcode == "frem" {
            ctx.emitAutoAssign(lhs, expr: "fmod(\(a), \(b))", knownType: mslType)
        } else {
            ctx.emitAutoAssign(lhs, expr: "\(a) \(op) \(b)", knownType: mslType)
        }
    }

    /// 翻译 fneg
    static func translateFNeg(lhs: String, rhs: String, ctx: SSAContext) {
        // fneg [fast] <type> <op>
        let cleaned = stripFastMathFlags(rhs.replacingOccurrences(of: "fneg ", with: ""))
        let parts = cleaned.components(separatedBy: " ")
        let value: String
        if parts.count >= 2 {
            value = resolveIROperand(parts.dropFirst().joined(separator: " "), ctx: ctx)
        } else {
            value = resolveIROperand(cleaned, ctx: ctx)
        }
        ctx.emitAutoAssign(lhs, expr: "-(\(value))")
    }

    /// 翻译二元整数运算
    static func translateBinaryInt(lhs: String, rhs: String, opcode: String, ctx: SSAContext) {
        let op: String
        switch opcode {
        case "add": op = "+"
        case "sub": op = "-"
        case "mul": op = "*"
        case "udiv", "sdiv": op = "/"
        case "urem", "srem": op = "%"
        case "shl": op = "<<"
        case "lshr", "ashr": op = ">>"
        case "and": op = "&"
        case "or": op = "|"
        case "xor": op = "^"
        default: op = "??"
        }

        let cleaned = rhs.replacingOccurrences(of: "\(opcode) ", with: "", options: .anchored)
        let (type, operands) = parseBinaryOperands(cleaned, skipKeywords: ["nsw", "nuw", "exact"])
        guard operands.count >= 2 else {
            ctx.define(lhs, expr: "/* parse error */")
            return
        }

        let a = resolveIROperand(operands[0], ctx: ctx)
        let b = resolveIROperand(operands[1], ctx: ctx)
        let mslType = irScalarTypeToMSL(type)
        ctx.emitAutoAssign(lhs, expr: "\(a) \(op) \(b)", knownType: mslType)
    }

    /// 翻译 fcmp
    static func translateFCmp(lhs: String, rhs: String, ctx: SSAContext) {
        // fcmp [fast] <cond> <type> <op1>, <op2>
        let cleaned = stripFastMathFlags(rhs.replacingOccurrences(of: "fcmp ", with: ""))
        let tokens = cleaned.components(separatedBy: " ").filter { !$0.isEmpty }
        guard tokens.count >= 2 else {
            ctx.define(lhs, expr: "/* fcmp parse error */")
            return
        }
        let cond = tokens[0]
        // 剩余部分：<type> <op1>, <op2>
        let rest = tokens.dropFirst().joined(separator: " ")
        let (operandType, operands) = parseBinaryOperands(rest, skipKeywords: [])
        guard operands.count >= 2 else {
            ctx.define(lhs, expr: "/* fcmp operand error */")
            return
        }
        let a = resolveIROperand(operands[0], ctx: ctx)
        let b = resolveIROperand(operands[1], ctx: ctx)
        let mslOp = fcmpCondToMSL(cond)
        // 向量 fcmp 产出 <N x i1> → boolN，标量 fcmp 产出 i1 → bool
        let dim = extractVectorDim(operandType)
        let resultType = dim > 1 ? "bool\(dim)" : "bool"
        ctx.emitAutoAssign(lhs, expr: "\(a) \(mslOp) \(b)", knownType: resultType)
    }

    /// 翻译 icmp
    static func translateICmp(lhs: String, rhs: String, ctx: SSAContext) {
        let cleaned = rhs.replacingOccurrences(of: "icmp ", with: "")
        let tokens = cleaned.components(separatedBy: " ").filter { !$0.isEmpty }
        guard tokens.count >= 2 else {
            ctx.define(lhs, expr: "/* icmp parse error */")
            return
        }
        let cond = tokens[0]
        let rest = tokens.dropFirst().joined(separator: " ")
        let (operandType, operands) = parseBinaryOperands(rest, skipKeywords: [])
        guard operands.count >= 2 else {
            ctx.define(lhs, expr: "/* icmp operand error */")
            return
        }
        let a = resolveIROperand(operands[0], ctx: ctx)
        let b = resolveIROperand(operands[1], ctx: ctx)
        let mslOp = icmpCondToMSL(cond)
        // 向量 icmp 产出 <N x i1> → boolN，标量 icmp 产出 i1 → bool
        let resultType: String
        let dim = extractVectorDim(operandType)
        if dim > 1 {
            resultType = "bool\(dim)"
        } else {
            resultType = "bool"
        }
        ctx.emitAutoAssign(lhs, expr: "\(a) \(mslOp) \(b)", knownType: resultType)
    }

    /// 翻译 select
    static func translateSelect(lhs: String, rhs: String, ctx: SSAContext) {
        // select [fast-math-flags] <cond_type> <cond>, <type> <val_true>, <type> <val_false>
        let cleaned = stripFastMathFlags(rhs.replacingOccurrences(of: "select ", with: ""))
        let selectParts = splitTypedOperands(cleaned, count: 3)
        guard selectParts.count >= 3 else {
            ctx.define(lhs, expr: "/* select parse error */")
            return
        }
        let cond = resolveIROperand(selectParts[0].value, ctx: ctx)
        let valTrue = resolveIROperand(selectParts[1].value, ctx: ctx)
        let valFalse = resolveIROperand(selectParts[2].value, ctx: ctx)
        let resultType = irScalarTypeToMSL(selectParts[1].type)
        let condDim = extractVectorDim(selectParts[0].type)

        if condDim > 1 {
            let trueVector = "\(resultType)(\(valTrue))"
            let falseVector = "\(resultType)(\(valFalse))"
            ctx.emitAutoAssign(lhs, expr: "select(\(falseVector), \(trueVector), \(cond))", knownType: resultType)
            return
        }

        ctx.emitAutoAssign(lhs, expr: "\(cond) ? \(valTrue) : \(valFalse)", knownType: resultType)
    }

    /// 翻译 shufflevector
    static func translateShuffleVector(lhs: String, rhs: String, ctx: SSAContext) {
        // shufflevector <type> <v1>, <type> <v2>, <mask_type> <mask>
        let cleaned = rhs.replacingOccurrences(of: "shufflevector ", with: "")
        let shuffleParts = splitTypedOperands(cleaned, count: 3)
        guard shuffleParts.count >= 3 else {
            ctx.define(lhs, expr: "/* shufflevector parse error */")
            return
        }

        let v1 = resolveIROperand(shuffleParts[0].value, ctx: ctx)
        let mask = shuffleParts[2].value
        let maskDim = extractVectorDim(shuffleParts[2].type)

        // 解析 mask 以确定 swizzle 模式
        let maskIndices = parseVectorConstant(mask, fallbackDim: maskDim)
        let resultDim = maskIndices.isEmpty ? maskDim : maskIndices.count

        // 如果 mask 全相同（broadcast/splat），生成 MSL vector splat
        if !maskIndices.isEmpty && maskIndices.allSatisfy({ $0 == maskIndices[0] }) {
            let idx = maskIndices[0]
            if idx >= 0 {
                let swizzle = vectorIndexToSwizzle(idx)
                let srcType = shuffleParts[0].type
                let outType = vectorTypeWithDim(srcType, dim: resultDim)
                let mslOutType = irScalarTypeToMSL(outType)
                if let cached = ctx.lookupInsertedElementComponent(vectorSSA: shuffleParts[0].value, elementIndex: idx) {
                    ctx.emitAutoAssign(lhs, expr: "\(mslOutType)(\(cached))", knownType: mslOutType)
                    return
                }
                ctx.emitAutoAssign(lhs, expr: "\(mslOutType)(\(v1).\(swizzle))", knownType: mslOutType)
            } else {
                // poison/undef splat
                ctx.define(lhs, expr: v1)
            }
            return
        }

        // 一般 swizzle
        let maxSrcDim = extractVectorDim(shuffleParts[0].type)
        let allFromV1 = maskIndices.allSatisfy { $0 < maxSrcDim }

        if allFromV1 && maskIndices.allSatisfy({ $0 >= 0 }) {
            // 纯 v1 swizzle
            let swizzle = maskIndices.map { vectorIndexToSwizzle($0) }.joined()
            ctx.emitAutoAssign(lhs, expr: "\(v1).\(swizzle)")
        } else {
            // 涉及 v2 或 poison，生成逐元素构造
            let v2 = resolveIROperand(shuffleParts[1].value, ctx: ctx)
            let srcType = shuffleParts[0].type
            let outType = vectorTypeWithDim(srcType, dim: resultDim)
            let mslType = irScalarTypeToMSL(outType)
            if let groupedExpr = groupedShuffleConstructor(
                v1: v1,
                v2: v2,
                srcIRType: srcType,
                resultMSLType: mslType,
                maskIndices: maskIndices,
                maxSrcDim: maxSrcDim
            ) {
                ctx.emitAutoAssign(lhs, expr: groupedExpr, knownType: mslType)
                return
            }
            var elems: [String] = []
            for idx in maskIndices {
                if idx < 0 {
                    elems.append("0")
                } else if idx < maxSrcDim {
                    elems.append("\(v1)[\(idx)]")
                } else {
                    elems.append("\(v2)[\(idx - maxSrcDim)]")
                }
            }
            ctx.emitAutoAssign(lhs, expr: "\(mslType)(\(elems.joined(separator: ", ")))", knownType: mslType)
        }
    }

    /// 翻译 extractelement
    static func translateExtractElement(lhs: String, rhs: String, ctx: SSAContext) {
        // extractelement <type> <vec>, <idx_type> <idx>
        let cleaned = rhs.replacingOccurrences(of: "extractelement ", with: "")
        let parts = splitTypedOperands(cleaned, count: 2)
        guard parts.count >= 2 else {
            ctx.define(lhs, expr: "/* extractelement error */")
            return
        }
        let vec = resolveIROperand(parts[0].value, ctx: ctx)
        let idx = resolveIROperand(parts[1].value, ctx: ctx)

        // 常量索引用 swizzle
        if let idxNum = Int(idx) {
            if let cached = ctx.lookupInsertedElementComponent(vectorSSA: parts[0].value, elementIndex: idxNum) {
                ctx.define(lhs, expr: cached)
                return
            }
            let swizzle = vectorIndexToSwizzle(idxNum)
            ctx.emitAutoAssign(lhs, expr: "\(vec).\(swizzle)")
        } else {
            ctx.emitAutoAssign(lhs, expr: "\(vec)[\(idx)]")
        }
    }

    /// 翻译 insertelement
    static func translateInsertElement(lhs: String, rhs: String, ctx: SSAContext) {
        // insertelement <type> <vec>, <elem_type> <elem>, <idx_type> <idx>
        let cleaned = rhs.replacingOccurrences(of: "insertelement ", with: "")
        let parts = splitTypedOperands(cleaned, count: 3)
        guard parts.count >= 3 else {
            ctx.define(lhs, expr: "/* insertelement error */")
            return
        }
        let vec = resolveIROperand(parts[0].value, ctx: ctx)
        let elem = resolveIROperand(parts[1].value, ctx: ctx)
        let idx = resolveIROperand(parts[2].value, ctx: ctx)

        let mslType = irScalarTypeToMSL(parts[0].type)
        let vectorDim = extractVectorDim(parts[0].type)
        if let idxNum = Int(idx), idxNum >= 0, idxNum < vectorDim, vectorDim > 1 {
            let vectorOperand = parts[0].value.trimmingCharacters(in: .whitespaces)
            let componentIRType = vectorElementIRType(parts[0].type)
            let zeroComponent = zeroInitializerExpression(forIRType: componentIRType)
            var components: [String]
            if vectorOperand == "poison" || vectorOperand == "undef" {
                components = Array(repeating: zeroComponent, count: vectorDim)
            } else if let cached = ctx.insertElementComponents[vectorOperand], cached.count == vectorDim {
                components = cached
            } else {
                components = (0..<vectorDim).map { componentIndex in
                    vectorComponentExpression(vectorExpr: vec, index: componentIndex)
                }
            }
            components[idxNum] = elem
            ctx.insertElementComponents[lhs.trimmingCharacters(in: .whitespaces)] = components
            ctx.emitAutoAssign(lhs, expr: "\(mslType)(\(components.joined(separator: ", ")))", knownType: mslType)
            return
        }

        let temp = ctx.freshTemp()
        if vec == "poison" || vec == "undef" {
            ctx.emit("\(mslType) \(temp) = \(mslType)(0);")
        } else {
            ctx.emit("\(mslType) \(temp) = \(vec);")
        }
        if let idxNum = Int(idx) {
            let swizzle = vectorIndexToSwizzle(idxNum)
            ctx.emit("\(temp).\(swizzle) = \(elem);")
        } else {
            ctx.emit("\(temp)[\(idx)] = \(elem);")
        }
        ctx.define(lhs, expr: temp, type: mslType)
    }

    /// 翻译 extractvalue (E-004e4c)
    ///
    /// IR 模式:
    /// - `extractvalue { <4 x float>, i8 } %5, 0` — 从 air.sample 返回值中提取 float4（丢弃 i8 coverage）
    /// - `extractvalue %struct.XXX %val, N` — 从命名结构体中提取字段
    ///
    /// 策略:
    /// 1. 匿名聚合 `{ <4 x float>, i8 }`：air.sample 等返回值 → 直接透传 aggregate 表达式
    ///    （因为 MSL 侧 air.sample 已经直接返回 float4，i8 coverage 被丢弃）
    /// 2. 命名结构体：有 metadata → 生成 `.fieldName`；无 metadata → 生成 `.fieldN`
    static func translateExtractValue(lhs: String, rhs: String, ctx: SSAContext) {
        // extractvalue <type> <agg>, <idx>, ...
        let cleaned = rhs.replacingOccurrences(of: "extractvalue ", with: "")
        let parts = splitTypedOperands(cleaned, count: 1)
        guard let first = parts.first else {
            ctx.define(lhs, expr: "/* extractvalue error */")
            return
        }
        let aggType = first.type
        let aggregateSSA = first.value.trimmingCharacters(in: .whitespaces)
        let agg = resolveIROperand(first.value, ctx: ctx)
        // 后续索引在逗号后
        let afterFirst = cleaned.dropFirst(first.rawLength)
        let indices = afterFirst.components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .compactMap { Int($0) }

        if indices.count == 1,
           let cachedField = ctx.lookupInsertedFieldValue(aggregateSSA: aggregateSSA, fieldIndex: indices[0]) {
            ctx.define(lhs, expr: resolveIROperand(cachedField, ctx: ctx))
            return
        }

        // 判断是否为匿名聚合类型（花括号开头，非命名结构体）
        let trimmedType = aggType.trimmingCharacters(in: .whitespaces)
        let isAnonymousAggregate = trimmedType.hasPrefix("{") || trimmedType.hasPrefix("<{")
        let isNamedStruct = trimmedType.hasPrefix("%")

        if isAnonymousAggregate && indices.count == 1 && indices[0] == 0 {
            // 模式 1: 从 {<4 x float>, i8} 中提取第一个元素
            // 这是 air.sample 的典型模式：MSL 侧直接返回 float4
            ctx.define(lhs, expr: agg)
        } else if isNamedStruct && indices.count == 1 {
            // 模式 2: 命名结构体字段提取
            let fieldIdx = indices[0]
            if let fieldName = ctx.lookupFieldName(irStructType: trimmedType, fieldIndex: fieldIdx) {
                ctx.define(lhs, expr: "\(agg).\(fieldName)")
            } else if let def = ctx.structTypeDefs[trimmedType], def.fieldIRTypes.count == 1, fieldIdx == 0 {
                // 单字段 wrapper（如 matrix wrapper）直接透传，避免落回非法/无意义的 `.field0`
                ctx.define(lhs, expr: agg)
            } else {
                ctx.define(lhs, expr: "\(agg).field\(fieldIdx)")
            }
        } else if indices.count == 1 {
            // 其他聚合类型，用通用索引
            let fieldIdx = indices[0]
            ctx.define(lhs, expr: "\(agg).field\(fieldIdx)")
        } else {
            // 多级索引（罕见），生成链式访问
            var expr = agg
            for idx in indices {
                expr = "\(expr).field\(idx)"
            }
            ctx.define(lhs, expr: expr)
        }
    }

    /// 翻译 insertvalue (E-004e4c)
    ///
    /// IR 模式:
    /// - `insertvalue <{ <4 x float>, <2 x float> }> undef, <4 x float> %26, 0`  — 初始化第一个字段
    /// - `insertvalue <{ <4 x float>, <2 x float> }> %29, <2 x float> %28, 1`   — 填充后续字段
    ///
    /// 策略:
    /// insertvalue 链式构建返回值结构体。每次 insertvalue 将一个值插入到聚合中的指定位置。
    /// 链的第一步通常是 `insertvalue ... undef, val, 0`（aggregate 初始化为 undef）。
    ///
    /// 在 SSAContext 中，我们追踪每个中间 aggregate 的已填充字段，
    /// 当所有字段都被填充后，生成完整的结构体构造表达式。
    /// 对于部分填充的情况，我们也记录已知字段以备后续链式 insertvalue 使用。
    static func translateInsertValue(lhs: String, rhs: String, ctx: SSAContext) {
        let cleaned = rhs.replacingOccurrences(of: "insertvalue ", with: "")
        let parts = splitTypedOperands(cleaned, count: 2)
        guard parts.count >= 2 else {
            ctx.define(lhs, expr: "/* insertvalue error */")
            return
        }

        let aggType = parts[0].type
        let aggValue = parts[0].value
        let val = resolveIROperand(parts[1].value, ctx: ctx)

        // 解析尾部索引（在最后一个逗号之后）
        // IR 格式: insertvalue <type> <agg>, <type> <val>, <idx>
        // 索引是最后一个逗号后面的纯数字
        let fieldIdx: Int
        if let lastComma = cleaned.lastIndex(of: ",") {
            let trailing = cleaned[cleaned.index(after: lastComma)...]
                .trimmingCharacters(in: .whitespaces)
            fieldIdx = Int(trailing) ?? 0
        } else {
            fieldIdx = 0
        }

        // 判断聚合类型（匿名 packed struct <{ ... }> 或普通 struct { ... }）
        let trimmedType = aggType.trimmingCharacters(in: .whitespaces)

        // 从类型字符串解析字段数量
        let fieldTypes = aggregateFieldTypes(trimmedType)
        let fieldCount = fieldTypes.count

        func makeAggregatePlaceholders(minimumCount: Int) -> [String] {
            let count = max(fieldCount, minimumCount)
            guard count > 0 else { return [] }
            return (0..<count).map { index in
                guard index < fieldTypes.count else { return "0" }
                return zeroInitializerExpression(forIRType: fieldTypes[index])
            }
        }

        // 判断是否为 undef 基础（链的起点）
        let isUndef = aggValue.trimmingCharacters(in: .whitespaces) == "undef" ||
                      aggValue.trimmingCharacters(in: .whitespaces) == "poison"

        if isUndef {
            // 链起点：记录已知的第一个字段
            var fields = makeAggregatePlaceholders(minimumCount: fieldIdx + 1)
            fields[fieldIdx] = val
            ctx.insertValueFields[lhs] = fields
            // 如果是单字段结构体，直接完成
            if fieldCount == 1 {
                ctx.define(lhs, expr: "{ \(val) }")
            } else {
                // 暂时定义为部分构造（后续 insertvalue 会覆盖）
                ctx.define(lhs, expr: "/* partial aggregate */")
            }
        } else {
            // 链继续：基于前一个 aggregate 追加字段
            var fields: [String]
            if let prevFields = ctx.insertValueFields[aggValue.trimmingCharacters(in: .whitespaces)] {
                fields = prevFields
                // 确保数组够大
                while fields.count <= fieldIdx { fields.append("0") }
                fields[fieldIdx] = val
            } else {
                // 无前驱记录，创建新的
                fields = makeAggregatePlaceholders(minimumCount: fieldIdx + 1)
                fields[fieldIdx] = val
            }
            ctx.insertValueFields[lhs] = fields

            // 检查是否所有字段都已填充（无 "0" 占位符）
            // 生成完整的构造表达式
            let allFilled = fields.count == fieldCount && fieldCount > 0
            if allFilled {
                ctx.define(lhs, expr: "{ \(fields.joined(separator: ", ")) }")
            } else {
                ctx.define(lhs, expr: "/* partial aggregate */")
            }
        }
    }

    /// 统计 IR aggregate 类型中的字段数量
    /// 如 `<{ <4 x float>, <2 x float> }>` → 2
    /// 如 `{ <4 x float>, i8 }` → 2
    static func countAggregateFields(_ type: String) -> Int {
        aggregateFieldTypes(type).count
    }

    static func aggregateFieldTypes(_ type: String) -> [String] {
        var body = type.trimmingCharacters(in: .whitespaces)
        // 去掉 packed struct 外层 <{ }>
        if body.hasPrefix("<{") && body.hasSuffix("}>") {
            body = String(body.dropFirst(2).dropLast(2))
        } else if body.hasPrefix("{") && body.hasSuffix("}") {
            body = String(body.dropFirst().dropLast())
        } else {
            return []  // 不是聚合类型
        }
        return splitIRParameters(body).map {
            $0.trimmingCharacters(in: .whitespaces)
        }.filter {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    static func parseIRArrayType(_ irType: String) -> (count: Int, elementType: String)? {
        let trimmed = irType.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("["), trimmed.hasSuffix("]"), let xRange = trimmed.range(of: " x ") else {
            return nil
        }
        let countStr = String(trimmed[trimmed.index(after: trimmed.startIndex)..<xRange.lowerBound])
            .trimmingCharacters(in: .whitespaces)
        guard let count = Int(countStr) else { return nil }
        let afterX = trimmed[xRange.upperBound...]
        let elementType = String(afterX[..<afterX.index(before: afterX.endIndex)])
            .trimmingCharacters(in: .whitespaces)
        return (count, elementType)
    }

    static func zeroInitializerExpression(forIRType irType: String) -> String {
        let trimmed = irType.trimmingCharacters(in: .whitespaces)
        if let array = parseIRArrayType(trimmed) {
            let zeroValue = zeroInitializerExpression(forIRType: array.elementType)
            return "{ \(Array(repeating: zeroValue, count: array.count).joined(separator: ", ")) }"
        }

        let fieldTypes = aggregateFieldTypes(trimmed)
        if !fieldTypes.isEmpty {
            return "{ \(fieldTypes.map { zeroInitializerExpression(forIRType: $0) }.joined(separator: ", ")) }"
        }

        if trimmed == "i1" {
            return "false"
        }

        let mslType = irScalarTypeToMSL(trimmed)
        if trimmed.hasPrefix("%") || isStructTypeName(mslType) {
            return "\(mslType)()"
        }
        return "\(mslType)(0)"
    }

    static func stripAddressOfExpression(_ expr: String) -> String? {
        let trimmed = expr.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("&") else { return nil }

        var inner = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        if inner.hasPrefix("(") && inner.hasSuffix(")") {
            inner = String(inner.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return inner.isEmpty ? nil : inner
    }

    static func addressExpression(for expr: String) -> String {
        let trimmed = expr.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "&(/* empty */)" }
        if stripAddressOfExpression(trimmed) != nil {
            return trimmed
        }
        return "&(\(trimmed))"
    }

    static func lvalueExpression(from pointerExpr: String) -> String? {
        stripAddressOfExpression(pointerExpr)
    }

    /// 翻译 load
    static func translateLoad(lhs: String, rhs: String, ctx: SSAContext) {
        // load <type>, <ptr_type> <ptr>[, align N][, !tbaa ...]
        let cleaned = rhs.replacingOccurrences(of: "load ", with: "")
        // 分割类型和指针，注意 <type> 可能包含逗号（如 <4 x float>）
        let parts = splitTypedOperands(cleaned, count: 2)
        guard parts.count >= 2 else {
            ctx.define(lhs, expr: "/* load error */")
            return
        }
        let loadType = parts[0].type
        let ptrOperand = parts[1].value.trimmingCharacters(in: .whitespaces)
        let ptr = resolveIROperand(ptrOperand, ctx: ctx)
        let mslType = irScalarTypeToMSL(loadType)
        let loadExpr = lvalueExpression(from: ptr) ?? "*(\(ptr))"
        // 从 ptrOperand 中提取纯 SSA 名（去掉 ptr addrspace(N) 等前缀）
        let ptrSSAName = extractSSAName(from: ptrOperand)
        // E-006b5: 检测指针元素类型与 load 类型之间的 signedness mismatch。
        // LLVM IR 的 i32 没有 signedness，但 MSL 的 int4/uint4 是不同类型。
        // 当 load 从 device uint4* 加载但 IR 类型为 <4 x i32>（→int4）时，
        // 需要用 as_type<int4>(uintIn[t0]) 做无符号 bitcast。
        // E-006b7: 扩展检测到 load 类型与指针元素类型大小不同时也需要重解释。
        let ptrElemType = ctx.pointerElementTypes[ptrSSAName] ?? ctx.pointerElementTypes[ptrOperand]
        if let elemType = ptrElemType {
            if needsSignednessBitcast(mslType, ptrElemType: elemType) {
                ctx.emitAutoAssign(lhs, expr: "as_type<\(mslType)>(\(loadExpr))", knownType: mslType)
            } else if needsSizeBitcast(mslType, ptrElemType: elemType) {
                let loadBits = mslTypeBitWidth(mslType)
                let ptrBits = mslTypeBitWidth(elemType)
                if loadBits <= 32 && ptrBits > loadBits {
                    // 标量或小向量从更大向量加载：as_type 取前 32bit 再截取
                    if mslType == "float" || mslType == "int" || mslType == "uint" {
                        // 标量：取 .x 分量（float4[0] → .x）
                        ctx.emitAutoAssign(lhs, expr: "\(loadExpr).x", knownType: mslType)
                    } else if mslType == "half" {
                        ctx.emitAutoAssign(lhs, expr: "as_type<half>(as_type<uint>(\(loadExpr).x) & 0xFFFF)", knownType: mslType)
                    } else {
                        // 小向量（uchar2 等）：通过 uint 中间 bitcast 截取
                        // float → uint (as_type, same 32-bit size) → mask → downcast → as_type
                        // Metal 的 as_type 要求源和目标大小相同，所以中间步骤必须用 uint (32-bit)
                        let intBits = loadBits <= 16 ? 16 : 32
                        let mask: String
                        if intBits == 16 {
                            mask = "0xFFFF"
                        } else {
                            mask = "0xFFFFFFFF"
                        }
                        // 始终用 uint 做中间 bitcast（float → uint 是合法的 same-size as_type）
                        let tempUInt = ctx.freshTemp()
                        ctx.emit("uint \(tempUInt) = as_type<uint>(\(loadExpr).x) & \(mask);")
                        if intBits == 16 {
                            // 16-bit 目标：uint → ushort (显式截断) → as_type<uchar2>
                            let tempShort = ctx.freshTemp()
                            ctx.emit("ushort \(tempShort) = ushort(\(tempUInt));")
                            ctx.emitAutoAssign(lhs, expr: "as_type<\(mslType)>(\(tempShort))", knownType: mslType)
                        } else {
                            // 32-bit 目标：直接 as_type<uint> → as_type<目标类型>
                            ctx.emitAutoAssign(lhs, expr: "as_type<\(mslType)>(\(tempUInt))", knownType: mslType)
                        }
                    }
                } else {
                    // 其他大小不匹配的情况：用 reinterpret_cast 指针类型
                    let ptrTemp = ctx.freshTemp()
                    let addrSpace = inferAddressSpace(ptrOperand, ctx: ctx)
                    ctx.emit("auto \(ptrTemp) = reinterpret_cast<const \(addrSpace)\(mslType)*>(&(\(loadExpr)));")
                    ctx.emitAutoAssign(lhs, expr: "*\(ptrTemp)", knownType: mslType)
                }
            } else {
                ctx.emitAutoAssign(lhs, expr: loadExpr, knownType: mslType)
            }
        } else {
            ctx.emitAutoAssign(lhs, expr: loadExpr, knownType: mslType)
        }
    }

    /// 检测两个 MSL 类型是否在 signedness 上有差异（相同大小不同符号），
    /// 需要用 as_type<> bitcast 而非普通类型转换。
    /// 例如：int4 vs uint4, int2 vs uint2, short vs ushort, int vs uint
    static func needsSignednessBitcast(_ loadMSLType: String, ptrElemType: String) -> Bool {
        // 提取基础类型名和维度
        let signedToUnsigned: [String: String] = [
            "int": "uint", "int2": "uint2", "int3": "uint3", "int4": "uint4",
            "short": "ushort", "short2": "ushort2", "short3": "ushort3", "short4": "ushort4",
            "long": "ulong", "long2": "ulong2", "long3": "ulong3", "long4": "ulong4",
            "char": "uint8_t",
        ]
        let unsignedToSigned: [String: String] = [
            "uint": "int", "uint2": "int2", "uint3": "int3", "uint4": "int4",
            "ushort": "short", "ushort2": "short2", "ushort3": "ushort3", "ushort4": "short4",
            "ulong": "long", "ulong2": "long2", "ulong3": "long3", "ulong4": "long4",
            "uint8_t": "char",
        ]
        if let equiv = signedToUnsigned[loadMSLType], equiv == ptrElemType { return true }
        if let equiv = unsignedToSigned[loadMSLType], equiv == ptrElemType { return true }
        // 向量维度不匹配的 signedness 差异（如 int4 vs uint2）不需要处理，类型完全不同
        return false
    }

    /// 检测两个 MSL 类型是否在大小（bit width）上不匹配，
    /// 需要 as_type<> 重解释而非直接赋值。
    /// 例如：uchar2 (2 bytes) vs float4 (16 bytes)、float (4 bytes) vs float4 (16 bytes)
    /// 当 load 的 IR 类型比指针元素类型更小时（如从 float4* 加载 uchar2），
    /// MSL 的 subscript 返回指针元素类型（float4），不能直接赋给 load 类型（uchar2）。
    static func needsSizeBitcast(_ loadMSLType: String, ptrElemType: String) -> Bool {
        let loadBits = mslTypeBitWidth(loadMSLType)
        let ptrBits = mslTypeBitWidth(ptrElemType)
        guard loadBits > 0 && ptrBits > 0 else { return false }
        // 相同大小 → 不需要（signedness 由 needsSignednessBitcast 处理）
        if loadBits == ptrBits { return false }
        // 不同大小 → 需要 as_type 重解释
        // 但只处理 load 比 ptr 小的情况（截断式 bitcast），忽略 load 更大的情况（不太常见）
        return loadBits < ptrBits
    }

    /// 估算 MSL 类型的 bit width
    static func mslTypeBitWidth(_ mslType: String) -> Int {
        let s = mslType.trimmingCharacters(in: .whitespaces)
        // 标量类型
        let scalarWidths: [String: Int] = [
            "char": 8, "uchar": 8, "uint8_t": 8,
            "short": 16, "ushort": 16,
            "int": 32, "uint": 32, "float": 32, "half": 16,
            "long": 64, "ulong": 64, "double": 64,
            "bool": 1,
        ]
        if let w = scalarWidths[s] { return w }
        // 向量类型：typeN（如 float4, uchar2, int3）
        // 提取末尾的维度数字
        var i = s.count
        while i > 0 && s[s.index(s.startIndex, offsetBy: i - 1)].isNumber { i -= 1 }
        if i < s.count && i > 0 {
            let base = String(s[s.startIndex..<s.index(s.startIndex, offsetBy: i)])
            if let dim = Int(s[s.index(s.startIndex, offsetBy: i)...]),
               let baseW = scalarWidths[base] {
                return baseW * dim
            }
        }
        return 0
    }

    /// 从 IR 操作数的地址空间推断 MSL 地址空间限定符。
    /// IR addrspace(1) → device, addrspace(2) → constant, addrspace(3) → threadgroup, 其他 → device
    static func inferAddressSpace(_ irOperand: String, ctx: SSAContext) -> String {
        let trimmed = irOperand.trimmingCharacters(in: .whitespaces)
        // 检查 SSA 变量的参数类型（可能包含 addrspace 信息）
        if trimmed.hasPrefix("%") {
            if let paramType = ctx.paramTypes[trimmed] {
                if paramType.contains("addrspace(2)") { return "constant" }
                if paramType.contains("addrspace(3)") { return "threadgroup" }
            }
            // 回退：检查 SSA 表达式是否包含 constant 关键字
            let resolved = ctx.resolve(trimmed)
            if resolved.contains("constant") { return "constant" }
            if resolved.contains("threadgroup") { return "threadgroup" }
        }
        return "device"
    }

    /// 翻译 store
    static func translateStore(_ line: String, ctx: SSAContext) {
        // store <type> <value>, <ptr_type> <ptr>[, align N]
        let cleaned = line.replacingOccurrences(of: "store ", with: "")
            .trimmingCharacters(in: .whitespaces)
        let parts = splitTypedOperands(cleaned, count: 2)
        guard parts.count >= 2 else {
            ctx.emit("// [store parse error] \(line.prefix(80))")
            return
        }
        let valOperand = parts[0].value.trimmingCharacters(in: .whitespaces)
        let ptrOperand = parts[1].value.trimmingCharacters(in: .whitespaces)
        let val = resolveIROperand(valOperand, ctx: ctx)
        let ptr = resolveIROperand(ptrOperand, ctx: ctx)
        let targetExpr = lvalueExpression(from: ptr) ?? "*(\(ptr))"
        // E-006b5: 检测值类型与指针元素类型之间的 signedness mismatch。
        // LLVM IR 的 i32 无 signedness，MSL 的 int4/uint4 是不同类型。
        // 当 store int4 值到 device uint4* 时，需要 as_type<uint4>(val)。
        let ptrSSAName = extractSSAName(from: ptrOperand)
        let ptrElemType = ctx.pointerElementTypes[ptrSSAName] ?? ctx.pointerElementTypes[ptrOperand]
        if let elemType = ptrElemType,
           let valMSLType = ctx.types[valOperand],
           needsSignednessBitcast(valMSLType, ptrElemType: elemType) {
            ctx.emit("\(targetExpr) = as_type<\(elemType)>(\(val));")
        } else {
            ctx.emit("\(targetExpr) = \(val);")
        }
    }

    /// 翻译 getelementptr (E-004e4c)
    ///
    /// IR 模式:
    /// - `getelementptr inbounds %struct.Particle, ptr addrspace(1) %0, i64 %4, i32 0`
    ///   → `&particles[tid].position`  （数组元素 + 结构体字段）
    /// - `getelementptr inbounds %struct.Uniforms, ptr addrspace(2) %2, i64 0, i32 0, i32 0, i64 0`
    ///   → `&uniforms.modelViewProjection.columns[0]`  （嵌套结构体 + 数组访问）
    /// - `getelementptr inbounds <4 x float>, ptr addrspace(1) %0, i64 %5`
    ///   → `&positions[vid]`  （简单数组索引）
    ///
    /// 策略:
    /// GEP 的第一个索引是基指针的偏移（数组索引），后续索引按类型层级解析：
    /// - 对结构体类型，索引是字段编号（常量 i32）→ 查找字段名
    /// - 对数组类型，索引是元素下标（可以是变量）→ 生成 `[idx]`
    static func translateGEP(lhs: String, rhs: String, ctx: SSAContext) {
        // getelementptr [inbounds] <type>, <ptr_type> <ptr>, <idx_type> <idx>[, ...]
        var cleaned = rhs.replacingOccurrences(of: "getelementptr ", with: "")
            .trimmingCharacters(in: .whitespaces)
        if cleaned.hasPrefix("inbounds ") {
            cleaned = String(cleaned.dropFirst("inbounds ".count))
        }

        let parts = splitTypedOperands(cleaned, count: 10)
        guard parts.count >= 2 else {
            ctx.define(lhs, expr: "/* GEP error */")
            return
        }

        let pointeeType = parts[0].type.trimmingCharacters(in: .whitespaces)
        let baseOperand = parts[1].value.trimmingCharacters(in: .whitespaces)
        let basePtr = resolveIROperand(baseOperand, ctx: ctx)
        let baseTarget = stripAddressOfExpression(basePtr) ?? basePtr
        let baseIsPointerLike = ctx.isPointerLike(baseOperand) || stripAddressOfExpression(basePtr) != nil

        if parts.count == 2 {
            // 无索引，直接透传
            ctx.define(lhs, expr: basePtr)
            if baseIsPointerLike {
                ctx.markPointer(lhs, elementType: ctx.pointerElementTypes[baseOperand.trimmingCharacters(in: .whitespaces)] ?? "")
            }
            return
        }

        if parts.count == 3 {
            // 简单数组索引: ptr + idx
            let idx = resolveIROperand(parts[2].value, ctx: ctx)
            if idx == "0" {
                ctx.define(lhs, expr: basePtr)
            } else {
                ctx.define(lhs, expr: addressExpression(for: "\(baseTarget)[\(idx)]"))
            }
            ctx.markPointer(lhs, elementType: ctx.pointerElementTypes[baseOperand.trimmingCharacters(in: .whitespaces)] ?? "")
            return
        }

        // 多级索引：parts[2] 是基指针偏移（数组索引），parts[3..] 是类型层级索引
        let firstIdx = resolveIROperand(parts[2].value, ctx: ctx)

        // E-006b9: metal::_atomic GEP 的特殊处理
        // IR: getelementptr %"struct.metal::_atomic", ptr %0, i64 0, i32 0
        // MSL: counter 是 device atomic_int& 引用，直接透传不加 [0] 或 .field0
        let isAtomicGEP = pointeeType.contains("metal::_atomic")

        // 构建表达式。对真正的指针参数先落到合法的下标/解引用语义；
        // 对 constant struct 引用等"值语义入口"则保留原表达式，避免误发射 `ptr.field`。
        var expr: String
        if isAtomicGEP {
            // atomic 类型是引用，不需要下标访问
            expr = baseTarget
        } else if baseIsPointerLike {
            if stripAddressOfExpression(basePtr) != nil {
                expr = baseTarget
                if firstIdx != "0" {
                    expr = "\(expr)[\(firstIdx)]"
                }
            } else {
                expr = "\(baseTarget)[\(firstIdx)]"
            }
        } else {
            expr = baseTarget
            if firstIdx != "0" {
                expr = "\(expr)[\(firstIdx)]"
            }
        }

        // 从第二个索引开始，遍历类型层级
        var currentType = pointeeType

        for i in 3..<parts.count {
            let idxStr = parts[i].value.trimmingCharacters(in: .whitespaces)

            // 判断当前类型层级
            if currentType.hasPrefix("%") {
                // E-006b9: metal::_atomic 是 MSL 内建 atomic 类型的 IR 表示
                // GEP field0 取的是内部 __s 字段指针，但 MSL 中 atomic 变量本身就是原子操作的目标
                // 因此直接透传指针，不加 .field0 / .__s 后缀
                if (currentType.contains("metal::_atomic") || currentType.contains("metal::_atomic.25")) {
                    if let fieldIdx = Int(idxStr), fieldIdx == 0 {
                        // 直接透传 expr，不加任何字段访问
                        if let def = ctx.structTypeDefs[currentType],
                           fieldIdx < def.fieldIRTypes.count {
                            currentType = def.fieldIRTypes[fieldIdx].trimmingCharacters(in: .whitespaces)
                        } else {
                            currentType = ""
                        }
                        continue
                    }
                }

                // 结构体类型 → 字段访问
                if let fieldIdx = Int(idxStr) {
                    if let fieldName = ctx.lookupFieldName(irStructType: currentType, fieldIndex: fieldIdx) {
                        expr = "\(expr).\(fieldName)"
                    } else if let def = ctx.structTypeDefs[currentType],
                              fieldIdx < def.fieldIRTypes.count {
                        // 单字段 wrapper（如 `%\"struct.metal::matrix\" = type { [4 x <4 x float>] }`）
                        // 访问 field0 时直接透传到内部字段，避免继续构造 `%0.field0[...]` 这类坏路径。
                        if !(def.fieldIRTypes.count == 1 && fieldIdx == 0) {
                            expr = "\(expr).field\(fieldIdx)"
                        }
                    } else {
                        expr = "\(expr).field\(fieldIdx)"
                    }
                    // 更新 currentType 为字段的 IR 类型
                    if let def = ctx.structTypeDefs[currentType],
                       fieldIdx < def.fieldIRTypes.count {
                        currentType = def.fieldIRTypes[fieldIdx].trimmingCharacters(in: .whitespaces)
                    } else {
                        currentType = ""
                    }
                } else {
                    // 非常量索引用于结构体（不应该出现，但防御性处理）
                    let resolvedIdx = resolveIROperand(idxStr, ctx: ctx)
                    expr = "\(expr)[\(resolvedIdx)]"
                    currentType = ""
                }
            } else if currentType.hasPrefix("[") {
                // 数组类型 [N x T] → 索引访问
                let resolvedIdx = resolveIROperand(idxStr, ctx: ctx)
                expr = "\(expr)[\(resolvedIdx)]"
                // 提取数组元素类型: "[4 x <4 x float>]" → "<4 x float>"
                if let xRange = currentType.range(of: " x ") {
                    let afterX = currentType[xRange.upperBound...]
                    if let closeBracket = afterX.lastIndex(of: "]") {
                        currentType = String(afterX[afterX.startIndex..<closeBracket])
                            .trimmingCharacters(in: .whitespaces)
                    } else {
                        currentType = ""
                    }
                } else {
                    currentType = ""
                }
            } else {
                // 其他类型（向量、标量、ptr 等）→ 通用索引
                let resolvedIdx = resolveIROperand(idxStr, ctx: ctx)
                if resolvedIdx == "0" && i == parts.count - 1 {
                    // 最后一个索引为 0，通常是无效访问，透传
                } else if currentType.hasPrefix("<") {
                    // E-006b7: IR 向量类型 <N x T> 的 GEP subscript。
                    // GEP 语义是把向量内存视为元素数组做指针 subscript，
                    // 但 expr[field] 对向量值是 component access（返回标量），语义不等价。
                    // 必须先取地址再用指针 subscript：auto tmp = &(expr); tmp[idx]
                    // 保留 currentType（向量元素类型）用于 gepElementType 追踪。
                    let ptrTemp = ctx.freshTemp()
                    ctx.emit("auto \(ptrTemp) = &(\(expr));")
                    var offsetExpr = resolvedIdx
                    var j = i + 1
                    while j < parts.count {
                        let nextIdxStr = parts[j].value.trimmingCharacters(in: .whitespaces)
                        let nextIdx = resolveIROperand(nextIdxStr, ctx: ctx)
                        if !nextIdx.isEmpty && nextIdx != "0" {
                            offsetExpr += " + \(nextIdx)"
                        }
                        j += 1
                    }
                    expr = "\(ptrTemp)[\(offsetExpr)]"
                    // currentType 保持为向量类型（<N x T>），不置空
                    break
                } else if !currentType.isEmpty && !currentType.hasPrefix("ptr") {
                    // E-006a2e14: 标量类型 subscript（float, half, i32 等）
                    // 也处理 MSL 向量类型（float4, uchar2 等）
                    let ptrTemp = ctx.freshTemp()
                    ctx.emit("auto \(ptrTemp) = &(\(expr));")
                    var offsetExpr = resolvedIdx
                    var j = i + 1
                    while j < parts.count {
                        let nextIdxStr = parts[j].value.trimmingCharacters(in: .whitespaces)
                        let nextIdx = resolveIROperand(nextIdxStr, ctx: ctx)
                        if !nextIdx.isEmpty && nextIdx != "0" {
                            offsetExpr += " + \(nextIdx)"
                        }
                        j += 1
                    }
                    expr = "\(ptrTemp)[\(offsetExpr)]"
                    break
                } else {
                    expr = "\(expr)[\(resolvedIdx)]"
                }
                currentType = ""
            }
        }

        ctx.define(lhs, expr: addressExpression(for: expr))
        // 多级 GEP 的元素类型由 currentType 决定；若 currentType 为空则回退到 base 的类型
        let gepElementType = currentType.isEmpty
            ? (ctx.pointerElementTypes[baseOperand.trimmingCharacters(in: .whitespaces)] ?? "")
            : irScalarTypeToMSL(currentType)
        ctx.markPointer(lhs, elementType: gepElementType)
    }

    /// 翻译类型转换: zext/sext/trunc/fpext/fptrunc/uitofp/sitofp/fptoui/fptosi
    static func translateIntCast(lhs: String, rhs: String, opcode: String, ctx: SSAContext) {
        // <opcode> <src_type> <val> to <dst_type>
        let cleaned = rhs.replacingOccurrences(of: "\(opcode) ", with: "")
        guard let toRange = cleaned.range(of: " to ") else {
            ctx.define(lhs, expr: "/* cast error */")
            return
        }
        let srcPart = String(cleaned[cleaned.startIndex..<toRange.lowerBound])
        let dstType = String(cleaned[toRange.upperBound...]).trimmingCharacters(in: .whitespaces)

        let srcParts = splitTypedOperands(srcPart, count: 1)
        let srcOperand = srcParts.first
        let srcVal = srcOperand.map { resolveIROperand($0.value, ctx: ctx) } ?? "0"

        let mslDstType: String
        switch opcode {
        case "fptoui":
            mslDstType = irIntegerTypeToMSL(dstType, signed: false)
        case "fptosi":
            mslDstType = irIntegerTypeToMSL(dstType, signed: true)
        case "zext":
            mslDstType = irIntegerTypeToMSL(dstType, signed: false)
        case "sext":
            mslDstType = irIntegerTypeToMSL(dstType, signed: true)
        default:
            mslDstType = irScalarTypeToMSL(dstType)
        }

        if opcode == "zext",
           let srcType = srcOperand?.type,
           shouldUseSelectForVectorBoolZExt(lhs: lhs, srcIRType: srcType, dstIRType: dstType, ctx: ctx) {
            ctx.emitAutoAssign(
                lhs,
                expr: "select(\(mslDstType)(0), \(mslDstType)(1), \(srcVal))",
                knownType: mslDstType
            )
            return
        }

        ctx.emitAutoAssign(lhs, expr: "\(mslDstType)(\(srcVal))", knownType: mslDstType)
    }

    static func shouldUseSelectForVectorBoolZExt(lhs: String, srcIRType: String, dstIRType: String, ctx: SSAContext) -> Bool {
        let srcType = srcIRType.trimmingCharacters(in: .whitespaces)
        let dstType = dstIRType.trimmingCharacters(in: .whitespaces)
        let srcDim = extractVectorDim(srcType)
        guard srcDim > 1,
              srcDim == extractVectorDim(dstType),
              vectorElementIRType(srcType) == "i1",
              vectorElementIRType(dstType) == "i8" else {
            return false
        }

        let immediateUsers = ctx.immediateUsers(of: lhs)
        return immediateUsers.count == 1 && immediateUsers.contains("shufflevector")
    }

    /// 将 IR 整数类型映射到带符号性语义的 MSL 类型。
    ///
    /// 注意：MSL 不支持 `uint8_tN` 等向量类型别名（如 `uint8_t2`），
    /// 无符号 8-bit 整数向量必须使用 `ucharN`（即 `vector<uint8_t, N>`）。
    static func irIntegerTypeToMSL(_ irType: String, signed: Bool) -> String {
        let cleaned = irType.trimmingCharacters(in: .whitespaces)

        switch cleaned {
        case "i1":
            return "bool"
        case "i8":
            return signed ? "char" : "uint8_t"
        case "i16":
            return signed ? "short" : "ushort"
        case "i32":
            return signed ? "int" : "uint"
        case "i64":
            return signed ? "long" : "ulong"
        default:
            if cleaned.hasPrefix("<") && cleaned.hasSuffix(">") && cleaned.contains(" x ") {
                let inner = String(cleaned.dropFirst().dropLast())
                let parts = inner.components(separatedBy: " x ")
                if parts.count >= 2 {
                    let count = parts[0].trimmingCharacters(in: .whitespaces)
                    let elemType = parts.dropFirst().joined(separator: " x ").trimmingCharacters(in: .whitespaces)
                    // i8 向量：MSL 不支持 uint8_tN，必须用 ucharN
                    if elemType == "i8" {
                        return "uchar\(count)"
                    }
                    let elemMSLType = irIntegerTypeToMSL(elemType, signed: signed)
                    return "\(elemMSLType)\(count)"
                }
            }
            return irScalarTypeToMSL(cleaned)
        }
    }

    /// 翻译 bitcast
    static func translateBitcast(lhs: String, rhs: String, ctx: SSAContext) {
        let cleaned = rhs.replacingOccurrences(of: "bitcast ", with: "")
        guard let toRange = cleaned.range(of: " to ") else {
            ctx.define(lhs, expr: "/* bitcast error */")
            return
        }
        let srcPart = String(cleaned[cleaned.startIndex..<toRange.lowerBound])
        let dstType = String(cleaned[toRange.upperBound...]).trimmingCharacters(in: .whitespaces)

        let srcParts = splitTypedOperands(srcPart, count: 1)
        let srcVal = srcParts.isEmpty ? "0" : resolveIROperand(srcParts[0].value, ctx: ctx)

        // E-006b9: ptr to ptr bitcast 是 no-op（MSL 中 thread 空间指针类型兼容）
        if dstType == "ptr" && (srcParts.first?.type == "ptr" || srcParts.first?.type.contains("ptr") == true) {
            ctx.define(lhs, expr: srcVal)
            ctx.markPointer(lhs)
            return
        }

        let mslDstType = irScalarTypeToMSL(dstType)
        ctx.emitAutoAssign(lhs, expr: "as_type<\(mslDstType)>(\(srcVal))", knownType: mslDstType)
    }

    /// 翻译 freeze（LLVM poison → 确定值，MSL 中直接透传）
    static func translateFreeze(lhs: String, rhs: String, ctx: SSAContext) {
        let cleaned = rhs.replacingOccurrences(of: "freeze ", with: "")
        let parts = splitTypedOperands(cleaned, count: 1)
        if let first = parts.first {
            let val = resolveIROperand(first.value, ctx: ctx)
            ctx.define(lhs, expr: val)
        } else {
            ctx.define(lhs, expr: "/* freeze error */")
        }
    }

    /// 翻译 call/tail call（包括 air.*、___metal_* 和普通函数）
    static func translateCall(lhs: String, rhs: String, ctx: SSAContext) {
        // 检查是否是 air.* 调用
        if rhs.contains("@air.") {
            translateAirCall(lhs: lhs, fullRhs: rhs, ctx: ctx)
            return
        }
        // E-006a2e10: 检查是否是 ___metal_* 内联 intrinsic
        // LLVM Metal 编译器会将部分标准库函数内联为 @___metal_fract_v2float 等形式
        if rhs.contains("@___metal_") {
            translateMetalIntrinsic(lhs: lhs, fullRhs: rhs, ctx: ctx)
            return
        }
        // llvm.* 大多是 IR 级 intrinsic，不应直接发射为普通 MSL 调用。
        if rhs.contains("@llvm.") {
            ctx.define(lhs, expr: "/* call: \(rhs.prefix(80)) */")
            return
        }
        translateRegularCall(lhs: lhs, fullRhs: rhs, ctx: ctx)
    }

    /// 翻译普通函数调用（helper / internal 函数）。
    ///
    /// 这类调用通常已经在同一份生成源码里有对应函数定义，
    /// 例如 `@_Z13_target_floorf`、`@_Z11_target_minff`、`@_ZN11_fract_impl...`。
    /// 直接降成 `callee(args...)` 即可，不能再退回到注释占位符，否则会把 LLVM 语法泄漏进 MSL。
    static func translateRegularCall(lhs: String, fullRhs: String, ctx: SSAContext) {
        guard let atIndex = fullRhs.firstIndex(of: "@") else {
            ctx.define(lhs, expr: "/* call: \(fullRhs.prefix(80)) */")
            return
        }

        let afterAt = fullRhs[fullRhs.index(after: atIndex)...]
        guard let parenIdx = afterAt.firstIndex(of: "(") else {
            ctx.define(lhs, expr: "/* call: \(fullRhs.prefix(80)) */")
            return
        }

        let rawName = String(afterAt[afterAt.startIndex..<parenIdx]).replacingOccurrences(of: "\"", with: "")
        let calleeName = sanitizeIdentifier(rawName, fallback: "callTarget", uppercaseFirst: false)

        let argsStart = afterAt.index(after: parenIdx)
        var depth = 1
        var cursor = argsStart
        while cursor < afterAt.endIndex && depth > 0 {
            if afterAt[cursor] == "(" { depth += 1 }
            else if afterAt[cursor] == ")" { depth -= 1 }
            if depth > 0 { cursor = afterAt.index(after: cursor) }
        }

        let argsStr = String(afterAt[argsStart..<cursor])
        let argParts = splitTypedOperands(argsStr, count: 20)
        let resolvedArgs = argParts.map { resolveIROperand($0.value, ctx: ctx) }
        ctx.emitAutoAssign(lhs, expr: "\(calleeName)(\(resolvedArgs.joined(separator: ", ")))")
    }

    /// 已知的 ___metal_* intrinsic 映射到 MSL 函数名
    /// 命名规则：___metal_<msl_name>[_<type_suffix>]
    /// 例如：___metal_fract_v2float → fract(), ___metal_fast_sin_v4f32 → sin()
    /// mslArgCount: MSL 函数期望的参数数量（IR intrinsic 可能有额外元数据参数）
    ///
    /// E-006b4: fast_* 变体统一映射到同名标准 MSL 函数（去掉 fast_ 前缀），
    /// 与 air.fast_* 映射行为保持一致。Metal 标准库不提供 fast_sin 等
    /// 无前缀函数，fast-math 语义由编译选项（-ffast-math）控制，
    /// 不应体现在函数名中。
    static let metalIntrinsicMappings: [(pattern: String, mslFunc: String, mslArgCount: Int)] = {
        var list: [(String, String, Int)] = []
        let unaryMath = [
            "fract", "sin", "cos", "tan", "sqrt", "rsqrt",
            "exp", "exp2", "log", "log2", "floor", "ceil", "round", "trunc",
            "saturate", "sign", "asin", "acos", "atan",
            "sinh", "cosh", "tanh",
        ]
        for name in unaryMath {
            list.append(("___metal_\(name)", name, 1))
            // E-006b4: fast_* 变体映射到同名标准函数（与 air.fast_* 一致）
            list.append(("___metal_fast_\(name)", name, 1))
        }
        let binaryMath = [
            "fmin", "fmax", "pow", "fmod", "atan2", "copysign", "fdim", "step",
            "min", "max",
        ]
        for name in binaryMath {
            list.append(("___metal_\(name)", name, 2))
            list.append(("___metal_fast_\(name)", name, 2))
        }
        let ternaryMath = ["clamp", "mix", "smoothstep", "fma"]
        for name in ternaryMath {
            list.append(("___metal_\(name)", name, 3))
            list.append(("___metal_fast_\(name)", name, 3))
        }
        let unaryVec = ["length", "normalize"]
        for name in unaryVec {
            list.append(("___metal_\(name)", name, 1))
            list.append(("___metal_fast_\(name)", name, 1))
        }
        let binaryVec = ["dot", "cross", "distance", "reflect"]
        for name in binaryVec {
            list.append(("___metal_\(name)", name, 2))
            list.append(("___metal_fast_\(name)", name, 2))
        }
        let ternaryVec = ["refract", "faceforward"]
        for name in ternaryVec {
            list.append(("___metal_\(name)", name, 3))
            list.append(("___metal_fast_\(name)", name, 3))
        }
        list.append(("___metal_abs", "abs", 1))
        list.append(("___metal_fabs", "abs", 1))
        return list
    }()

    /// 翻译 ___metal_* 内联 intrinsic 调用
    /// 从函数名提取 MSL 函数名（去掉类型后缀），解析参数后生成直接 MSL 调用
    static func translateMetalIntrinsic(lhs: String, fullRhs: String, ctx: SSAContext) {
        // 提取 @___metal_ 后的函数名（到 ( 为止）
        guard let atRange = fullRhs.range(of: "@___metal_") else {
            ctx.define(lhs, expr: "/* metal intrinsic error */")
            return
        }
        let afterAt = fullRhs[fullRhs.index(after: atRange.lowerBound)...]
        guard let parenIdx = afterAt.firstIndex(of: "(") else {
            ctx.define(lhs, expr: "/* metal intrinsic error */")
            return
        }
        let fullName = String(afterAt[afterAt.startIndex..<parenIdx])

        // 从完整名称（含类型后缀）查找 MSL 函数名和期望参数数
        // 例如：fract_v2float → fract(1), fast_sin_v4f32 → sin(1)
        let mapping = lookupMetalIntrinsic(fullName)
        let mslFunc: String
        let mslArgCount: Int
        if let m = mapping {
            mslFunc = m.mslFunc
            mslArgCount = m.mslArgCount
        } else {
            mslFunc = fullName
            mslArgCount = -1
        }

        // 提取参数列表
        let argsStart = afterAt.index(after: parenIdx)
        var depth = 1
        var cursor = argsStart
        while cursor < afterAt.endIndex && depth > 0 {
            if afterAt[cursor] == "(" { depth += 1 }
            else if afterAt[cursor] == ")" { depth -= 1 }
            if depth > 0 { cursor = afterAt.index(after: cursor) }
        }
        let argsStr = String(afterAt[argsStart..<cursor])
        let argParts = splitTypedOperands(argsStr, count: 20)
        let resolvedArgs = argParts.map { resolveIROperand($0.value, ctx: ctx) }

        // E-006a2e11: 仅传递 MSL 函数期望的参数数量
        // IR intrinsic 可能有额外元数据/标志参数（如 fract(x, 0) 的 i32 0）
        let filteredArgs: [String]
        if mslArgCount > 0 && resolvedArgs.count > mslArgCount {
            filteredArgs = Array(resolvedArgs.prefix(mslArgCount))
        } else {
            filteredArgs = resolvedArgs
        }

        ctx.emitAutoAssign(lhs, expr: "\(mslFunc)(\(filteredArgs.joined(separator: ", ")))")
    }

    /// 查找 ___metal_* intrinsic 对应的 MSL 函数名和期望参数数
    /// 支持：___metal_fract_v2float → (fract, 1), ___metal_fast_sin_v4f32 → (sin, 1)
    static func lookupMetalIntrinsic(_ fullName: String) -> (mslFunc: String, mslArgCount: Int)? {
        // 按模式长度降序匹配，避免 "fast_sin" 被 "sin" 先匹配
        let sorted = metalIntrinsicMappings.sorted { $0.pattern.count > $1.pattern.count }
        for mapping in sorted {
            if fullName == mapping.pattern {
                return (mapping.mslFunc, mapping.mslArgCount)
            }
            if fullName.hasPrefix(mapping.pattern + "_") {
                return (mapping.mslFunc, mapping.mslArgCount)
            }
        }
        return nil
    }

    /// 翻译 air.* 内建调用
    static func translateAirCall(lhs: String, fullRhs: String, ctx: SSAContext) {
        // 提取 air 函数名
        guard let atRange = fullRhs.range(of: "@air.") else {
            ctx.define(lhs, expr: "/* air call error */")
            return
        }
        let afterAt = fullRhs[fullRhs.index(after: atRange.lowerBound)...]
        guard let parenIdx = afterAt.firstIndex(of: "(") else {
            ctx.define(lhs, expr: "/* air call error */")
            return
        }
        let airName = String(afterAt[afterAt.startIndex..<parenIdx])

        // 提取参数列表
        let argsStart = afterAt.index(after: parenIdx)
        var depth = 1
        var cursor = argsStart
        while cursor < afterAt.endIndex && depth > 0 {
            if afterAt[cursor] == "(" { depth += 1 }
            else if afterAt[cursor] == ")" { depth -= 1 }
            if depth > 0 { cursor = afterAt.index(after: cursor) }
        }
        let argsStr = String(afterAt[argsStart..<cursor])
        let argParts = splitTypedOperands(argsStr, count: 20)
        let resolvedArgs = argParts.map { resolveIROperand($0.value, ctx: ctx) }

        // 查找映射
        let mapping = lookupAirBuiltin(airName)

        if let m = mapping {
            let mslExpr = generateMSLForAirCall(
                mapping: m,
                airName: airName,
                args: resolvedArgs,
                argTypes: argParts.map { $0.type }
            )
            ctx.emitAutoAssign(lhs, expr: mslExpr)
        } else {
            // 未映射的 air 调用
            let argList = resolvedArgs.prefix(4).joined(separator: ", ")
            ctx.emitAutoAssign(lhs, expr: "/* \(airName)(\(argList)) */")
        }
    }

    /// 翻译 void 返回的 air.* 调用（如 barrier、write_texture）
    static func translateVoidAirCall(_ line: String, ctx: SSAContext) {
        guard let atRange = line.range(of: "@air.") else {
            ctx.emit("// [void air call error] \(line.prefix(80))")
            return
        }
        let afterAt = line[line.index(after: atRange.lowerBound)...]
        guard let parenIdx = afterAt.firstIndex(of: "(") else { return }
        let airName = String(afterAt[afterAt.startIndex..<parenIdx])

        let argsStart = afterAt.index(after: parenIdx)
        var depth = 1
        var cursor = argsStart
        while cursor < afterAt.endIndex && depth > 0 {
            if afterAt[cursor] == "(" { depth += 1 }
            else if afterAt[cursor] == ")" { depth -= 1 }
            if depth > 0 { cursor = afterAt.index(after: cursor) }
        }
        let argsStr = String(afterAt[argsStart..<cursor])
        let argParts = splitTypedOperands(argsStr, count: 20)
        let resolvedArgs = argParts.map { resolveIROperand($0.value, ctx: ctx) }

        let mapping = lookupAirBuiltin(airName)
        if let m = mapping {
            let mslExpr = generateMSLForAirCall(
                mapping: m, airName: airName,
                args: resolvedArgs, argTypes: argParts.map { $0.type }
            )
            ctx.emit("\(mslExpr);")
        } else {
            let argList = resolvedArgs.prefix(4).joined(separator: ", ")
            ctx.emit("/* \(airName)(\(argList)) */;")
        }
    }

    /// 根据 air→MSL 映射生成 MSL 表达式
    static func generateMSLForAirCall(
        mapping: AirBuiltinMapping,
        airName: String,
        args: [String],
        argTypes: [String]
    ) -> String {
        // 特殊处理: air.convert
        if airName.hasPrefix("air.convert") {
            let srcArg = args.first ?? "0"
            return generateAirConvertMSL(airName: airName, srcArg: srcArg)
        }

        // 纹理方法调用: tex.sample(sampler, coord, ...)
        if mapping.isMethodCall {
            if args.count >= 2 {
                let obj = args[0]
                let methodArgs = Array(args.dropFirst())
                let methodArgTypes = Array(argTypes.dropFirst())

                if mapping.mslFunction == "gather" {
                    return generateTextureGatherMSL(texture: obj, methodArgs: methodArgs, methodArgTypes: methodArgTypes)
                }

                let filtered = filterTextureArgs(methodArgs, argTypes: methodArgTypes, airName: airName)
                var finalArgs = filtered.args

                // E-006a2e8 → E-006a2e13: sample / sample_compare 的 bias/level float 需包装为选项结构
                // Metal 的 sample/sample_compare 都有 bias/level/min_lod_clamp 重载接受 float 参数，
                // 裸传 float 会导致 ambiguous。Air IR 中通过 i1 标志区分：i1 false → bias, i1 true → level(显式LOD)
                //
                // 参数结构（去掉 texture 后）:
                //   air.sample_texture_*:     [sampler, [i32,] coord, [i1_offset, offset,] [i1_bias/level, float_bias/level, float_min_lod, i32]]
                //   air.sample_compare_depth_2d: [sampler, [i32,] coord, float compare_value, [i1_offset, <2xi32>,] [i1_bias/level, float_bias/level, float_min_lod, i32]]
                // 对 sample_compare，compare_value 在 coord 之后，不能被误当作 bias/level 消费
                if (mapping.mslFunction == "sample" || mapping.mslFunction == "sample_compare") && !finalArgs.isEmpty {
                    let lastType = filtered.types.last ?? ""
                    if lastType == "float" || lastType == "half" {
                        // 查找 LOD/bias 标志：原始参数中 i1 紧接 float/half 的位置
                        var useLevel = false
                        var biasLevelArgIdx = -1  // bias/level float 在 methodArgs 中的索引
                        for i in 0..<(methodArgTypes.count - 1) {
                            if methodArgTypes[i] == "i1" &&
                               (methodArgTypes[i + 1] == "float" || methodArgTypes[i + 1] == "half") {
                                if methodArgs[i] == "true" { useLevel = true }
                                biasLevelArgIdx = i + 1
                                break
                            }
                        }
                        if biasLevelArgIdx >= 0 && biasLevelArgIdx < methodArgs.count {
                            let biasLevelVal = methodArgs[biasLevelArgIdx]
                            let biasLevelType = methodArgTypes[biasLevelArgIdx]
                            // 检查 bias/level 的 float 值是否被 filterTextureArgs 过滤掉（零值 float 会被过滤）
                            let isZeroFloat = (biasLevelType == "float" || biasLevelType == "half") &&
                                (biasLevelVal == "0.0" || biasLevelVal == "0.000000e+00")
                            let isFilteredByEmpty = biasLevelVal.isEmpty
                            if isZeroFloat || isFilteredByEmpty {
                                // bias/level 值已被 filterTextureArgs 过滤，不需要包装。
                                // finalArgs 末尾的 float 是 compare_value（sample_compare）或 coord 相关，保留原样
                            } else {
                                // bias/level 值被 filterTextureArgs 保留 → 它出现在 finalArgs 尾部
                                if finalArgs.count >= 2 {
                                    let val = finalArgs.removeLast()
                                    finalArgs.append(useLevel ? "level(\(val))" : "bias(\(val))")
                                }
                            }
                        }
                    }
                }

                // E-006b7: sample_texture_*_grad 的 gradient 参数需要包裹为 gradient2d(dx, dy)
                // Metal 的 sample(gradient2d(float2, float2)) 需要显式包装，
                // 否则裸传两个 float2 会被误解析为 bias/level 等重载导致 ambiguous。
                // 注意：gradient 参数可能是 SSA 变量（float2）或 splat 展开的裸 float 字面量，
                // 后者需要包装为 float2。
                if airName.contains("_grad") && mapping.mslFunction == "sample" {
                    // gradient 参数位于 coord 之后：最终参数中 [sampler, coord, gradX, gradY, ...]
                    // sampler 是 finalArgs[0], coord 是 finalArgs[1], gradX 是 finalArgs[2], gradY 是 finalArgs[3]
                    if finalArgs.count >= 4 {
                        var gradX = finalArgs.remove(at: 2)
                        var gradY = finalArgs.remove(at: 2)  // removeAt(2) again after first removal
                        // 如果 gradient 值是裸 float 字面量（来自 splat 展开），包装为 float2
                        if isFloatLiteral(gradX) { gradX = "float2(\(gradX))" }
                        if isFloatLiteral(gradY) { gradY = "float2(\(gradY))" }
                        finalArgs.insert("gradient2d(\(gradX), \(gradY))", at: 2)
                    }
                }

                // read: AIR 使用有符号整型坐标（常见为 <2 x i32> / <3 x i32>），
                // 但 Metal 的 texture.read(...) 需要 uintN / ushortN 坐标。
                // 若直接输出 intN，会触发 `no matching member function for call to 'read'`。
                if mapping.mslFunction == "read", !finalArgs.isEmpty, let coordType = filtered.types.first {
                    finalArgs[0] = normalizeTextureReadCoordinate(finalArgs[0], irType: coordType)
                }

                // write: AIR 参数顺序是 (texture, coord, color, ...)，
                // Metal 的 write 方法签名是 write(color, coord)，需要交换前两个参数
                if mapping.mslFunction == "write" && finalArgs.count >= 2 {
                    let a = finalArgs[0]
                    let b = finalArgs[1]
                    finalArgs[0] = b
                    finalArgs[1] = a
                    // E-006b8: 坐标参数来自 zeroinitializer 时被 resolveIROperand 解析为裸 "0"，
                    // Metal 的 write(color, coord) 需要 uint2 类型坐标，裸 0 会导致 ambiguous。
                    // 根据类型信息包装为正确的向量类型。
                    if let coordType = filtered.types.first {
                        if finalArgs[1] == "0" && coordType.contains("x i32") {
                            finalArgs[1] = "uint2(0)"
                        }
                    }
                }

                return "\(obj).\(mapping.mslFunction)(\(finalArgs.joined(separator: ", ")))"
            }
            return "\(mapping.mslFunction)(/* args */)"
        }

        // barrier 特殊处理
        if mapping.mslFunction == "threadgroup_barrier" || mapping.mslFunction == "simdgroup_barrier" {
            let flags = args.first ?? "0"
            let flagStr = barrierFlagsToMSL(flags)
            return "\(mapping.mslFunction)(\(flagStr))"
        }

        // E-006b9: atomic 操作特殊处理
        // AIR 原子函数参数格式: (ptr, val, order, scope, volatile)
        // MSL 只需: (obj, val, order) 或 (obj, order) 或 (obj, expected, desired, succ_order, fail_order)
        // 需要过滤掉 scope (i32 2=agent) 和 volatile (i1 true) 参数
        if mapping.category == .atomic {
            return generateAtomicMSL(mapping: mapping, airName: airName, args: args, argTypes: argTypes)
        }

        // 普通函数调用
        let paramCount = mapping.paramCount > 0 ? mapping.paramCount : args.count
        var callArgs = Array(args.prefix(paramCount))
        let callArgTypes = Array(argTypes.prefix(paramCount))

        // E-006a2e4: intrinsic 类型歧义修复
        // 当首个参数是 half 类型（标量或向量）时，FP literal 参数应加 h 后缀
        // 以避免 Metal 的 half/float 重载歧义（如 clamp(half_var, 0.0, 1.0) → ambiguous）
        if (mapping.category == .math) && callArgs.count > 1 && !callArgTypes.isEmpty {
            let firstType = callArgTypes[0]
            let isHalfScalar = firstType == "half"
            let isHalfVector = firstType.contains(" x half")
            if isHalfScalar || isHalfVector {
                for i in 1..<callArgs.count {
                    callArgs[i] = appendHalfSuffixIfFPLiteral(callArgs[i])
                }
            }
        }

        return "\(mapping.mslFunction)(\(callArgs.joined(separator: ", ")))"
    }

    static func generateTextureGatherMSL(
        texture: String,
        methodArgs: [String],
        methodArgTypes: [String]
    ) -> String {
        guard methodArgs.count >= 2 else {
            return "\(texture).gather(/* args */)"
        }

        let sampler = methodArgs[0]
        let coord = methodArgs[1]
        var offsetExpr: String?
        var componentExpr: String?

        for index in 2..<min(methodArgs.count, methodArgTypes.count) {
            let arg = methodArgs[index]
            let type = methodArgTypes[index]

            if offsetExpr == nil && type.contains("x i32") && arg != "0" && !arg.isEmpty {
                offsetExpr = arg
                continue
            }

            if componentExpr == nil && type == "i32", let componentIndex = Int(arg), (0...3).contains(componentIndex) {
                let componentNames = ["x", "y", "z", "w"]
                if componentIndex != 0 {
                    componentExpr = "component::\(componentNames[componentIndex])"
                }
            }
        }

        var callArgs = [sampler, coord]
        if let offsetExpr {
            callArgs.append(offsetExpr)
        }
        if let componentExpr {
            if offsetExpr == nil {
                callArgs.append("int2(0)")
            }
            callArgs.append(componentExpr)
        }

        return "\(texture).gather(\(callArgs.joined(separator: ", ")))"
    }

    static func normalizeTextureReadCoordinate(_ expr: String, irType: String) -> String {
        let trimmedType = irType.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedType.isEmpty, !expr.isEmpty else { return expr }

        if trimmedType == "i32" {
            return "uint(\(expr))"
        }
        if trimmedType == "i16" {
            return "ushort(\(expr))"
        }
        if trimmedType.contains("x i32") {
            let dim = max(extractVectorDim(trimmedType), 2)
            return "uint\(dim)(\(expr))"
        }
        if trimmedType.contains("x i16") {
            let dim = max(extractVectorDim(trimmedType), 2)
            return "ushort\(dim)(\(expr))"
        }

        return expr
    }

    /// 翻译 phi 节点（E-004e4b）
    ///
    /// phi 的值在 prescanPhiAndCFG 中已经预声明变量并注册到 ctx.phiVarNames。
    /// 实际赋值在 translateBr 中，在前驱 BB 的分支处插入。
    /// 这里只需确保 SSA 映射指向预声明的变量名。
    static func translatePhi(lhs: String, rhs: String, ctx: SSAContext) {
        // 预扫描已处理：ctx.define(lhs, expr: phiVarName)
        // 如果预扫描漏了（不应该发生），做 fallback
        if ctx.phiVarNames[lhs] == nil {
            // Fallback: 简化处理，取第一个值
            let cleaned = rhs.replacingOccurrences(of: "phi ", with: "")
            if let bracketStart = cleaned.firstIndex(of: "["),
               let bracketEnd = cleaned.firstIndex(of: "]") {
                let inner = cleaned[cleaned.index(after: bracketStart)..<bracketEnd]
                let phiParts = inner.components(separatedBy: ",")
                if let firstVal = phiParts.first?.trimmingCharacters(in: .whitespaces) {
                    let val = resolveIROperand(firstVal, ctx: ctx)
                    ctx.emitAutoAssign(lhs, expr: val + " /* phi fallback */")
                    return
                }
            }
            ctx.define(lhs, expr: "/* phi: \(rhs.prefix(60)) */")
        }
        // 预扫描已处理，不需要发射额外语句
    }

    /// 翻译 alloca
    static func translateAlloca(lhs: String, rhs: String, ctx: SSAContext) {
        let cleaned = rhs.replacingOccurrences(of: "alloca ", with: "")
        let typePart = cleaned.components(separatedBy: ",").first ?? cleaned
        let mslType = irScalarTypeToMSL(typePart.trimmingCharacters(in: .whitespaces))
        let temp = ctx.freshTemp()
        ctx.emit("\(mslType) \(temp);")
        ctx.define(lhs, expr: addressExpression(for: temp), type: mslType + "*")
        ctx.markPointer(lhs)
    }

    /// 翻译 ret 指令
    static func translateRet(_ line: String, ctx: SSAContext) {
        let cleaned = line.replacingOccurrences(of: "ret ", with: "").trimmingCharacters(in: .whitespaces)
        if cleaned == "void" {
            // ret void — 但函数可能是非 void 返回类型（测试 stub 常见）
            // 检查函数声明的返回类型，避免在非 void 函数中生成 return;
            if ctx.functionReturnType.isEmpty || ctx.functionReturnType == "void" {
                ctx.emit("return;")
            } else {
                ctx.emit("return \(ctx.functionReturnType)();")
            }
            return
        }
        // ret <type> <value>
        let parts = splitTypedOperands(cleaned, count: 1)
        if let first = parts.first {
            let val = resolveIROperand(first.value, ctx: ctx)
            let normalizedAggregateReturn = normalizeAggregateReturnExpression(val, ctx: ctx)
            if val.trimmingCharacters(in: .whitespaces).hasPrefix("{"),
               !ctx.functionReturnType.isEmpty,
               ctx.functionReturnType != "void" {
                ctx.emit("return \(ctx.functionReturnType)\(normalizedAggregateReturn ?? val);")
            } else if val == "0" && !ctx.functionReturnType.isEmpty
                        && ctx.functionReturnType != "void"
                        && isStructTypeName(ctx.functionReturnType) {
                // E-006a2e6: undef/poison/zeroinitializer 返回结构体时，
                // "0" 不能隐式转换为结构体类型，使用零初始化构造
                ctx.emit("return \(ctx.functionReturnType)();")
            } else {
                ctx.emit("return \(val);")
            }
        } else {
            ctx.emit("return;")
        }
    }

    static func normalizeAggregateReturnExpression(_ expression: String, ctx: SSAContext) -> String? {
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), trimmed.hasSuffix("}"), !ctx.functionReturnFieldTypes.isEmpty else {
            return nil
        }

        let inner = String(trimmed.dropFirst().dropLast())
        let parts = splitIRParameters(inner).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard parts.count == ctx.functionReturnFieldTypes.count else {
            return nil
        }

        let normalizedParts = zip(parts, ctx.functionReturnFieldTypes).map { part, targetType in
            coerceExpression(part, toMSLType: targetType)
        }
        return "{ \(normalizedParts.joined(separator: ", ")) }"
    }

    static func coerceExpression(_ expression: String, toMSLType targetType: String) -> String {
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetType.isEmpty else { return trimmed }
        guard !trimmed.isEmpty else {
            return isStructTypeName(targetType) ? "\(targetType)()" : "\(targetType)(0)"
        }

        if targetType == "bool" {
            return trimmed == "false" ? "false" : "bool(\(trimmed))"
        }
        if isStructTypeName(targetType) {
            return trimmed == "0" ? "\(targetType)()" : "\(targetType)(\(trimmed))"
        }
        return "\(targetType)(\(trimmed))"
    }

    /// 翻译 br 指令（E-004e4b: 条件→if/else + phi 赋值，无条件→phi 赋值+忽略跳转）
    ///
    /// 在 LLVM IR 的 SSA 形式中，phi 节点选择来自不同前驱 BB 的值。
    /// 在 MSL 中，我们将 phi 降级为普通变量：在每个前驱 BB 的分支处
    /// 赋值为该前驱应提供的值。
    ///
    /// 条件 br 翻译为 if/else 结构，可以包含 phi 赋值：
    /// ```
    /// if (cond) {
    ///   phi_0 = val_from_true_path;  // phi 赋值
    /// } else {
    ///   phi_0 = val_from_false_path; // phi 赋值
    /// }
    /// ```
    ///
    /// 无条件 br 处也插入 phi 赋值（如果目标 BB 有 phi 且当前 BB 是其前驱）。
    static func translateBr(_ line: String, ctx: SSAContext) {
        let cleaned = line.replacingOccurrences(of: "br ", with: "").trimmingCharacters(in: .whitespaces)
        let currentLabel = ctx.currentBBLabel

        if cleaned.hasPrefix("i1 ") {
            // 条件跳转: br i1 %cond, label %trueBB, label %falseBB
            let condParts = cleaned.components(separatedBy: ",")
            guard condParts.count >= 3 else { return }

            let condStr = condParts[0].replacingOccurrences(of: "i1 ", with: "")
                .trimmingCharacters(in: .whitespaces)
            let cond = resolveIROperand(condStr, ctx: ctx)

            let trueLabel = condParts[1].trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "label %", with: "")
                .replacingOccurrences(of: "label ", with: "")
                .trimmingCharacters(in: .whitespaces)
            let falseLabel = condParts[2].trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "label %", with: "")
                .replacingOccurrences(of: "label ", with: "")
                .trimmingCharacters(in: .whitespaces)

            // 收集 true 分支和 false 分支的 phi 赋值
            let truePhiAssigns = collectPhiAssignments(forTarget: trueLabel, fromPred: currentLabel, ctx: ctx)
            let falsePhiAssigns = collectPhiAssignments(forTarget: falseLabel, fromPred: currentLabel, ctx: ctx)

            if truePhiAssigns.isEmpty && falsePhiAssigns.isEmpty {
                // 无 phi 赋值，生成简洁的 if/else 注释
                ctx.emit("if (\(cond)) {")
                ctx.indentLevel += 1
                ctx.emit("// → BB\(trueLabel)")
                ctx.indentLevel -= 1
                ctx.emit("} else {")
                ctx.indentLevel += 1
                ctx.emit("// → BB\(falseLabel)")
                ctx.indentLevel -= 1
                ctx.emit("}")
            } else {
                // 有 phi 赋值：生成包含赋值的 if/else
                ctx.emit("if (\(cond)) {")
                ctx.indentLevel += 1
                for assign in truePhiAssigns {
                    ctx.emit(assign)
                }
                if truePhiAssigns.isEmpty {
                    ctx.emit("// → BB\(trueLabel)")
                }
                ctx.indentLevel -= 1
                ctx.emit("} else {")
                ctx.indentLevel += 1
                for assign in falsePhiAssigns {
                    ctx.emit(assign)
                }
                if falsePhiAssigns.isEmpty {
                    ctx.emit("// → BB\(falseLabel)")
                }
                ctx.indentLevel -= 1
                ctx.emit("}")
            }
        } else if cleaned.hasPrefix("label ") {
            // 无条件跳转: br label %dest
            let dest = cleaned.replacingOccurrences(of: "label %", with: "")
                .replacingOccurrences(of: "label ", with: "")
                .trimmingCharacters(in: .whitespaces)

            // 插入 phi 赋值
            let phiAssigns = collectPhiAssignments(forTarget: dest, fromPred: currentLabel, ctx: ctx)
            for assign in phiAssigns {
                ctx.emit(assign)
            }
            // 无条件跳转本身忽略（fall-through 或已由控制流处理）
        }
    }

    /// 收集当 BB `fromPred` 跳转到 `target` 时需要的 phi 赋值语句
    static func collectPhiAssignments(forTarget target: String, fromPred pred: String, ctx: SSAContext) -> [String] {
        guard let bbInfo = ctx.bbInfo[target] else { return [] }
        var assignments: [String] = []

        for phi in bbInfo.phiNodes {
            // 找到来自 pred 的值。LLVM 可能把隐式 entry block 记成数值标签（如 `%3`），
            // 而发射阶段当前块仍叫 `entry`，这里做一次别名匹配。
            for (value, label) in phi.incoming {
                let isEntryAliasMatch = pred == "entry" && ctx.entryBlockAliases.contains(label)
                if label == pred || isEntryAliasMatch {
                    let resolvedValue = resolveIROperand(value, ctx: ctx)
                    let commentPred = isEntryAliasMatch ? label : pred
                    assignments.append("\(phi.mslVarName) = \(resolvedValue); // phi from BB\(commentPred)")
                    break
                }
            }
        }

        return assignments
    }

    // MARK: - IR Parsing Helpers (E-004e4a)

    /// 表示一个带类型的 IR 操作数
    struct TypedOperand {
        let type: String
        let value: String
        let rawLength: Int
    }

    /// 分割带类型的 IR 操作数列表。
    /// IR 中的操作数格式: <type> <value>, <type> <value>, ...
    /// 其中 type 可能是 <4 x float> 等复合形式。
    static func splitTypedOperands(_ text: String, count: Int) -> [TypedOperand] {
        var results: [TypedOperand] = []
        var remaining = text.trimmingCharacters(in: .whitespaces)
        var consumed = 0

        for _ in 0..<count {
            if remaining.isEmpty { break }

            // 跳过逗号
            if remaining.hasPrefix(",") {
                remaining = String(remaining.dropFirst()).trimmingCharacters(in: .whitespaces)
                consumed += 1
            }

            // 去掉 metadata 尾巴 (!tbaa !xx, !alias.scope !xx 等)
            if remaining.hasPrefix("!") { break }

            // 去掉 align N
            if remaining.hasPrefix("align ") { break }

            // 解析类型
            let (type, afterType) = parseIRType(remaining)
            if type.isEmpty { break }
            remaining = afterType.trimmingCharacters(in: .whitespaces)

            // 解析值（到下一个逗号、metadata 或结尾）
            let (value, afterValue) = parseIRValue(remaining)
            remaining = afterValue.trimmingCharacters(in: .whitespaces)

            let rawLen = text.count - remaining.count - consumed
            results.append(TypedOperand(type: type, value: value, rawLength: rawLen))
        }

        return results
    }

    /// 解析 IR 类型前缀，返回 (type, remaining)
    static func parseIRType(_ text: String) -> (String, String) {
        var s = text.trimmingCharacters(in: .whitespaces)

        // 向量类型: <N x T>
        if s.hasPrefix("<") {
            var depth = 0
            var i = s.startIndex
            while i < s.endIndex {
                if s[i] == "<" { depth += 1 }
                else if s[i] == ">" { depth -= 1 }
                i = s.index(after: i)
                if depth == 0 { break }
            }
            let type = String(s[s.startIndex..<i])
            let rest = String(s[i...])
            return (type, rest)
        }

        // 数组类型: [N x T]
        if s.hasPrefix("[") {
            var depth = 0
            var i = s.startIndex
            while i < s.endIndex {
                if s[i] == "[" { depth += 1 }
                else if s[i] == "]" { depth -= 1 }
                i = s.index(after: i)
                if depth == 0 { break }
            }
            let type = String(s[s.startIndex..<i])
            let rest = String(s[i...])
            return (type, rest)
        }

        // 结构体类型: { <4 x float>, i8 }
        if s.hasPrefix("{") {
            var depth = 0
            var i = s.startIndex
            while i < s.endIndex {
                if s[i] == "{" { depth += 1 }
                else if s[i] == "}" { depth -= 1 }
                i = s.index(after: i)
                if depth == 0 { break }
            }
            let type = String(s[s.startIndex..<i])
            let rest = String(s[i...])
            return (type, rest)
        }

        // packed struct: <{ ... }>
        if s.hasPrefix("<{") {
            var depth = 0
            var i = s.startIndex
            while i < s.endIndex {
                if s[i] == "<" && s.index(after: i) < s.endIndex && s[s.index(after: i)] == "{" { depth += 1 }
                else if s[i] == "}" && s.index(after: i) < s.endIndex && s[s.index(after: i)] == ">" { depth -= 1 }
                i = s.index(after: i)
                if depth == 0 { i = s.index(after: i); break }
            }
            let type = String(s[s.startIndex..<i])
            let rest = String(s[i...])
            return (type, rest)
        }

        // ptr addrspace(N)
        if s.hasPrefix("ptr") {
            // 可能是 "ptr addrspace(N)" 或只是 "ptr"
            let words = s.prefix(30)
            if words.contains("addrspace(") {
                if let closeP = s.range(of: ")") {
                    let endIdx = s.index(after: closeP.upperBound)
                    let type = String(s[s.startIndex..<closeP.upperBound])
                    let rest = endIdx < s.endIndex ? String(s[endIdx...]) : ""
                    return (type, rest)
                }
            }
            // 处理 ptr 后面跟的修饰符
            var endIdx = s.index(s.startIndex, offsetBy: 3)
            while endIdx < s.endIndex {
                let c = s[endIdx]
                if c == "%" || c == "@" || c == "-" || c.isNumber ||
                   c == "<" || c == "{" || c == "(" || c == "!" {
                    break
                }
                // 跳过空格和修饰符关键字
                if c == " " || c == "\t" {
                    let afterSpace = String(s[endIdx...]).trimmingCharacters(in: .whitespaces)
                    let modifiers = ["addrspace(", "nocapture", "readonly", "writeonly",
                                     "align ", "dereferenceable(", "nonnull", "captures(",
                                     "\"air-buffer-no-alias\""]
                    var foundMod = false
                    for mod in modifiers {
                        if afterSpace.hasPrefix(mod) {
                            foundMod = true
                            break
                        }
                    }
                    if !foundMod { break }
                }
                endIdx = s.index(after: endIdx)
            }
            let type = String(s[s.startIndex..<endIdx]).trimmingCharacters(in: .whitespaces)
            let rest = String(s[endIdx...])
            return (type, rest)
        }

        // 简单类型: void, float, half, i1, i8, i16, i32, i64, double
        let simpleTypes = ["void", "double", "float", "half", "i64", "i32", "i16", "i8", "i1"]
        for st in simpleTypes {
            if s.hasPrefix(st) {
                let afterType = s.dropFirst(st.count)
                if afterType.isEmpty || afterType.first == " " || afterType.first == "," {
                    // 检查是否有 addrspace 后缀
                    let rest = String(afterType).trimmingCharacters(in: .whitespaces)
                    if rest.hasPrefix("addrspace(") {
                        if let closeP = rest.range(of: ")") {
                            let fullType = st + " " + String(rest[rest.startIndex...closeP.lowerBound])
                            let afterFull = String(rest[closeP.upperBound...])
                            return (fullType, afterFull)
                        }
                    }
                    return (st, String(afterType))
                }
            }
        }

        // %struct.xxx 或 %"xxx"
        if s.hasPrefix("%") {
            let end = s.firstIndex(where: { $0 == " " || $0 == "," }) ?? s.endIndex
            let type = String(s[s.startIndex..<end])
            let rest = String(s[end...])
            return (type, rest)
        }

        // 无法识别
        return ("", s)
    }

    /// 解析 IR 值，到下一个逗号或 metadata 标记为止
    static func parseIRValue(_ text: String) -> (String, String) {
        var s = text
        // 去掉前导空格
        while s.hasPrefix(" ") || s.hasPrefix("\t") {
            s = String(s.dropFirst())
        }

        var depth = 0
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if c == "<" || c == "(" || c == "{" || c == "[" { depth += 1 }
            else if c == ">" || c == ")" || c == "}" || c == "]" { depth -= 1 }

            // 逗号在顶层表示操作数分隔
            if c == "," && depth == 0 { break }
            // metadata 标记
            if c == "!" && depth == 0 {
                // 确认不是 "!0" 数值型操作数
                let rest = s[i...]
                if rest.hasPrefix("!tbaa") || rest.hasPrefix("!alias") ||
                   rest.hasPrefix("!noalias") || rest.hasPrefix("!range") {
                    break
                }
            }
            i = s.index(after: i)
        }

        let value = String(s[s.startIndex..<i]).trimmingCharacters(in: .whitespaces)
        let remaining = i < s.endIndex ? String(s[i...]) : ""
        return (value, remaining)
    }

    /// 解析二元运算的操作数: [flags] <type> <op1>, <op2>
    static func parseBinaryOperands(
        _ rhs: String,
        skipKeywords: [String]
    ) -> (String, [String]) {
        var s = rhs
        // 跳过 flags
        var words = s.components(separatedBy: " ").filter { !$0.isEmpty }
        while let first = words.first, skipKeywords.contains(first) {
            words.removeFirst()
        }
        s = words.joined(separator: " ").trimmingCharacters(in: .whitespaces)

        // LLVM 二元算术统一是 `<type> lhs, rhs`，第二个操作数复用前面的类型声明。
        let (type, afterType) = parseIRType(s)
        guard !type.isEmpty else { return ("", []) }

        let afterTypeTrimmed = afterType.trimmingCharacters(in: .whitespaces)
        let (firstOperand, remainderAfterFirst) = parseIRValue(afterTypeTrimmed)
        guard !firstOperand.isEmpty else { return (type, []) }

        var operands: [String] = [firstOperand]
        let remainder = remainderAfterFirst.trimmingCharacters(in: .whitespaces)
        if remainder.hasPrefix(",") {
            let second = String(remainder.dropFirst()).trimmingCharacters(in: .whitespaces)
            if !second.isEmpty {
                operands.append(second)
            }
        }

        return (type, operands)
    }

    /// 分割 select 的三个操作数
    static func splitSelectOperands(_ text: String) -> [String] {
        let parts = splitTypedOperands(text, count: 3)
        return parts.map { $0.value }
    }

    /// 解析 IR 操作数为 MSL 表达式
    static func resolveIROperand(_ operand: String, ctx: SSAContext) -> String {
        let s = operand.trimmingCharacters(in: .whitespaces)

        // E-006a2e10 → E-006g3: 处理全局 IR symbols (@...)
        // - 其他顶层全局常量（如 `@_ZL7ImmCB_0`）则保留为已发射到 MSL 的全局符号名
        if s.hasPrefix("@") {
            if s.contains("sampler") && !ctx.emittedSamplerStateGlobals.contains(s) {
                // 优先匹配 addrspace(2)（typed pointer 模式），fallback 再按 sampler 名称匹配
                for (irParam, mslName) in ctx.paramNames {
                    if let irType = ctx.paramTypes[irParam],
                       irType.contains("addrspace(2)") {
                        return mslName
                    }
                }
                for (_, mslName) in ctx.paramNames where mslName.contains("sampler") {
                    return mslName
                }
            }
            let symbolName = String(s.dropFirst())
                .replacingOccurrences(of: "\"", with: "")
            return sanitizeIdentifier(symbolName, fallback: "globalSymbol", uppercaseFirst: false)
        }

        // SSA 名 / SSA 名后缀访问（如 `%1.xyz`、`%0.field3[0]`）
        if s.hasPrefix("%") {
            let direct = ctx.resolve(s)
            if direct != s { return direct }

            for separator in [".", "["] {
                if let range = s.range(of: separator) {
                    let base = String(s[s.startIndex..<range.lowerBound])
                    let suffix = String(s[range.lowerBound...])
                    let resolvedBase = ctx.resolve(base)
                    if resolvedBase != base {
                        return resolvedBase + suffix
                    }
                }
            }
        }

        // 某些 call 参数 value 仍会残留 IR 限定词（如 `nocapture readonly %2`），
        // 这里兜底取最后一个 SSA token 再递归解析，避免 `%N` 直接泄漏到 MSL。
        if s.contains("%") {
            let tailToken = s
                .components(separatedBy: .whitespaces)
                .last { $0.contains("%") }
                .map { String($0) }
            if let tailToken, !tailToken.isEmpty, tailToken != s {
                return resolveIROperand(tailToken, ctx: ctx)
            }
        }

        // E-006a2e10: 同理，全局 symbol 也可能被 IR 限定词包裹
        // （如 `readonly captures(none) @__air_sampler_state`），需提取 @ token 再递归
        if s.contains("@") {
            let tailToken = s
                .components(separatedBy: .whitespaces)
                .last { $0.hasPrefix("@") }
                .map { String($0) }
            if let tailToken, !tailToken.isEmpty, tailToken != s {
                return resolveIROperand(tailToken, ctx: ctx)
            }
        }

        // 布尔常量
        if s == "true" { return "true" }
        if s == "false" { return "false" }

        // 特殊常量
        if s == "zeroinitializer" { return "0" }
        if s == "undef" || s == "poison" { return "0" }
        if s == "null" { return "nullptr" }

        // IR typed constant: "float undef", "half 0xH8000", "i32 42" 等
        // 提取类型后面的实际值并递归处理
        let irScalarTypes: Set<String> = ["void", "half", "float", "double", "i1", "i8", "i16", "i32", "i64", "ptr", "label"]
        let litTokens = s.components(separatedBy: .whitespaces)
        if litTokens.count >= 2 && irScalarTypes.contains(litTokens[0]) {
            return resolveIROperand(litTokens.dropFirst().joined(separator: " "), ctx: ctx)
        }

        // 向量 splat: splat (float 2.000000e+00)
        if s.hasPrefix("splat (") {
            let inner = String(s.dropFirst("splat (".count).dropLast())
            let innerParts = inner.components(separatedBy: " ")
            if innerParts.count >= 2 {
                return formatIRLiteral(innerParts.dropFirst().joined(separator: " "))
            }
            return s
        }

        // 向量常量: <float 1.0, float 0.0, ...>
        if s.hasPrefix("<") && s.hasSuffix(">") && !s.contains(" x ") {
            return parseVectorLiteral(s)
        }

        // 浮点字面量
        if s.contains("e+") || s.contains("e-") || s.contains("0x") {
            return formatIRLiteral(s)
        }

        // 整数字面量
        if s.first?.isNumber == true || (s.first == "-" && s.count > 1) {
            return s
        }

        return s
    }

    /// 检测字符串是否是浮点数字面量（如 "0.1", "1.0", "2.000000e+00" 等）
    static func isFloatLiteral(_ s: String) -> Bool {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return false }
        // 排除 SSA 引用、函数调用等非字面量
        if trimmed.hasPrefix("%") || trimmed.contains("(") || trimmed.contains(")") ||
           trimmed.contains("/*") || trimmed.contains("//") || trimmed.contains("[") {
            return false
        }
        return Double(trimmed) != nil
    }

    /// 检测类型名是否是 MSL 格式的向量类型（float4, half2, int3, uint2, uchar2, bool4 等）。
    /// IR 格式的向量类型（<4 x float>）由 hasPrefix("<") 处理，此函数处理 MSL 格式。
    static func isMSLVectorType(_ type: String) -> Bool {
        let s = type.trimmingCharacters(in: .whitespaces)
        guard s.count >= 2, !s.isEmpty else { return false }
        // 向量类型以数字结尾（维度），基础类型是标量类型名
        let lastChar = s.last!
        guard lastChar.isNumber, lastChar != "0" else { return false }
        let base = String(s.dropLast())
        // 已知 MSL 标量类型
        let scalarTypes: Set<String> = [
            "float", "half", "double",
            "int", "uint",
            "short", "ushort",
            "char", "uchar",
            "long", "ulong",
            "bool",
        ]
        return scalarTypes.contains(base)
    }

    /// 从 IR 操作数字符串中提取纯 SSA 名（%N）。
    /// 例如："ptr addrspace(2) %8" → "%8"，"%8" → "%8"，"fg.color" → "fg.color"
    static func extractSSAName(from operand: String) -> String {
        let trimmed = operand.trimmingCharacters(in: .whitespaces)
        if trimmed.contains("%") {
            if let lastPercent = trimmed.range(of: "%", options: .backwards) {
                let fromPercent = trimmed[lastPercent.lowerBound...]
                // 提取 %N 部分（到空格或结尾）
                let endIdx = fromPercent.firstIndex(where: { $0 == " " || $0 == "," }) ?? fromPercent.endIndex
                return String(fromPercent[..<endIdx])
            }
        }
        return trimmed
    }

    /// 如果参数是纯数字字面量，追加 h 后缀使其成为 half literal。
    /// SSA 引用（%N）、函数调用结果、常量表达式等不受影响。
    /// 整数字面量（如 "3", "0"）会先转为浮点形式（"3.0h", "0.0h"），
    /// 因为 Metal 的 h 后缀只能用于浮点字面量。
    static func appendHalfSuffixIfFPLiteral(_ arg: String) -> String {
        let s = arg.trimmingCharacters(in: .whitespaces)
        // 跳过 SSA 引用、函数调用、注释、类型转换等
        if s.hasPrefix("%") || s.hasPrefix("(") || s.contains("(") ||
           s.contains("/*") || s.contains("//") || s.contains("?") {
            return arg
        }
        // 已经有 h 后缀就跳过
        if s.hasSuffix("h") { return arg }
        // 检查是否是纯数字字面量（浮点或整数）
        // 浮点: "0.0", "1.0", "-1.0", "0.5", "3.14", 科学计数法等
        // 整数: "0", "1", "3", "-2" 等
        if let d = Double(s) {
            // 如果没有小数点且不是科学计数法，视为整数字面量，先转为浮点形式
            if !s.contains(".") && !s.contains("e") && !s.contains("E") {
                // 确保是纯整数形式（排除 hex 等）
                let stripped = s.hasPrefix("-") ? String(s.dropFirst()) : s
                if stripped.allSatisfy({ $0.isNumber }) {
                    return "\(String(format: "%.1f", d))h"
                }
            }
            return "\(s)h"
        }
        return arg
    }

    /// 格式化 IR 浮点字面量为 MSL
    static func formatIRLiteral(_ s: String) -> String {
        // undef / poison — 不能泄漏到 MSL
        if s == "undef" || s == "poison" { return "0" }

        if s.hasPrefix("0x") {
            let hex = String(s.dropFirst(2))
            // LLVM IR half-precision hex: 0xH8000 等
            if hex.first?.uppercased() == "H" {
                let hexDigits = String(hex.dropFirst())
                if let bits = UInt16(hexDigits, radix: 16) {
                    return formatHalfIRLiteral(bits)
                }
            }
            // 标准 IEEE-754 十六进制浮点 → Double → 十进制
            if let bits = UInt64(hex, radix: 16) {
                let d = Double(bitPattern: bits)
                if d == 0.0 { return "0.0" }
                return String(format: "%.6g", d)
            }
            return s
        }
        // 科学计数法
        if let d = Double(s) {
            if d == 0.0 { return "0.0" }
            if d == 1.0 { return "1.0" }
            if d == 2.0 { return "2.0" }
            if d == 0.5 { return "0.5" }
            if d == 3.0 { return "3.0" }
            return String(format: "%.6g", d)
        }
        return s
    }

    /// 将 LLVM IR half 精度十六进制立即数 (0xHxxxx) 转换为合法 MSL 表达式
    static func formatHalfIRLiteral(_ bits: UInt16) -> String {
        // IEEE-754 half: sign(1) | exponent(5) | mantissa(10)
        let sign = bits >> 15
        let exponent = (bits >> 10) & 0x1F
        let mantissa = bits & 0x3FF

        // 特殊值: Inf / NaN — 只能用 bitcast 保留原始 bit pattern
        if exponent == 0x1F {
            return "as_type<half>(ushort(0x\(String(bits, radix: 16).uppercased())))"
        }

        if exponent == 0 && mantissa == 0 { return "half(0.0)" }

        // 正常值 / subnormal: 转为 Float 再格式化
        let floatValue: Float
        if exponent == 0 {
            // Subnormal: implicit leading bit = 0, exponent = -14
            let m = Float(mantissa) / Float(1 << 10)
            floatValue = (sign == 0 ? 1.0 : -1.0) * m * powf(2.0, -14.0)
        } else {
            // Normal: implicit leading bit = 1, exponent = biased - 15
            let m = 1.0 + Float(mantissa) / Float(1 << 10)
            floatValue = (sign == 0 ? 1.0 : -1.0) * m * powf(2.0, Float(Int(exponent) - 15))
        }

        // 尝试简洁的十进制表示
        if floatValue == 0.0 { return "half(0.0)" }
        if floatValue == 1.0 { return "half(1.0)" }
        if floatValue == -1.0 { return "half(-1.0)" }
        if floatValue == 0.5 { return "half(0.5)" }
        if floatValue == -0.5 { return "half(-0.5)" }
        if floatValue == 2.0 { return "half(2.0)" }
        if floatValue == -2.0 { return "half(-2.0)" }

        // 一般值: 输出十进制浮点（MSL 上下文自动匹配 half 类型）
        return "half(\(String(format: "%.6g", Double(floatValue))))"
    }

    /// 解析 IR 向量字面量: <float 1.0, float 0.0, ...> → float4(1.0, 0.0, ...)
    static func parseVectorLiteral(_ s: String) -> String {
        let inner = String(s.dropFirst().dropLast())
        let elems = inner.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        var values: [String] = []
        for elem in elems {
            let parts = elem.components(separatedBy: " ")
            if parts.count >= 2 {
                values.append(formatIRLiteral(parts.last ?? "0"))
            } else {
                values.append(formatIRLiteral(elem))
            }
        }
        let dim = values.count
        let elemType = elems.first?.components(separatedBy: " ").first ?? "float"
        // E-006a2e12: i8 向量特殊处理 — MSL 不支持 uint8_tN，必须用 ucharN
        if elemType == "i8" {
            return "uchar\(dim)(\(values.joined(separator: ", ")))"
        }
        let mslType = irScalarTypeToMSL(elemType)
        return "\(mslType)\(dim)(\(values.joined(separator: ", ")))"
    }

    static func vectorElementIRType(_ irType: String) -> String {
        let trimmed = irType.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("<"), trimmed.hasSuffix(">"), trimmed.contains(" x ") else {
            return trimmed
        }
        let inner = String(trimmed.dropFirst().dropLast())
        let parts = inner.components(separatedBy: " x ")
        return parts.last?.trimmingCharacters(in: .whitespaces) ?? trimmed
    }

    static func vectorComponentExpression(vectorExpr: String, index: Int) -> String {
        if index >= 0 && index < 4 {
            return "\(vectorExpr).\(vectorIndexToSwizzle(index))"
        }
        return "\(vectorExpr)[\(index)]"
    }

    static func vectorConstructorElementTypeName(_ mslScalarType: String) -> String {
        if mslScalarType == "uint8_t" {
            return "uchar"
        }
        return mslScalarType
    }

    static func groupedShuffleConstructor(
        v1: String,
        v2: String,
        srcIRType: String,
        resultMSLType: String,
        maskIndices: [Int],
        maxSrcDim: Int
    ) -> String? {
        guard !maskIndices.isEmpty, maskIndices.count <= 4 else { return nil }
        let elementIRType = vectorElementIRType(srcIRType)
        let elementMSLType = irScalarTypeToMSL(elementIRType)
        let vectorElementType = vectorConstructorElementTypeName(elementMSLType)
        let zeroScalar = zeroInitializerExpression(forIRType: elementIRType)

        enum Segment {
            case zero(Int)
            case v1(Int, Int)
            case v2(Int, Int)
        }

        func sourceAndOffset(for index: Int) -> (isV1: Bool, offset: Int)? {
            if index < 0 { return nil }
            if index < maxSrcDim { return (true, index) }
            return (false, index - maxSrcDim)
        }

        var segments: [Segment] = []
        var cursor = 0
        while cursor < maskIndices.count {
            let current = maskIndices[cursor]
            if current < 0 {
                var length = 1
                while cursor + length < maskIndices.count, maskIndices[cursor + length] < 0 {
                    length += 1
                }
                segments.append(.zero(length))
                cursor += length
                continue
            }
            guard let info = sourceAndOffset(for: current) else { return nil }
            var length = 1
            while cursor + length < maskIndices.count,
                  let next = sourceAndOffset(for: maskIndices[cursor + length]),
                  next.isV1 == info.isV1,
                  next.offset == info.offset + length,
                  next.offset < 4 {
                length += 1
            }
            segments.append(info.isV1 ? .v1(info.offset, length) : .v2(info.offset, length))
            cursor += length
        }

        guard segments.count < maskIndices.count, segments.count <= 2 else { return nil }

        func swizzleExpr(vector: String, start: Int, length: Int) -> String {
            if length == 1 {
                return vectorComponentExpression(vectorExpr: vector, index: start)
            }
            let swizzle = (start..<(start + length)).map(vectorIndexToSwizzle).joined()
            return "\(vector).\(swizzle)"
        }

        func zeroExpr(length: Int) -> String {
            if length == 1 { return zeroScalar }
            return "\(vectorElementType)\(length)(\(Array(repeating: zeroScalar, count: length).joined(separator: ", ")) )"
                .replacingOccurrences(of: ") )", with: "))")
        }

        let args = segments.map { segment in
            switch segment {
            case .zero(let length):
                return zeroExpr(length: length)
            case .v1(let start, let length):
                return swizzleExpr(vector: v1, start: start, length: length)
            case .v2(let start, let length):
                return swizzleExpr(vector: v2, start: start, length: length)
            }
        }
        return "\(resultMSLType)(\(args.joined(separator: ", ")) )".replacingOccurrences(of: ") )", with: "))")
    }

    /// 解析向量常量 mask: <i32 0, i32 1, i32 2, i32 poison>
    static func parseVectorConstant(_ mask: String, fallbackDim: Int? = nil) -> [Int] {
        let inner: String
        if mask.hasPrefix("<") && mask.hasSuffix(">") {
            inner = String(mask.dropFirst().dropLast())
        } else {
            inner = mask
        }

        if inner.contains("zeroinitializer") {
            let dim = max(fallbackDim ?? 4, 1)
            return Array(repeating: 0, count: dim)
        }

        return inner.components(separatedBy: ",").map { part in
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed.contains("poison") || trimmed.contains("undef") { return -1 }
            // "i32 0" → 0
            let numStr = trimmed.components(separatedBy: " ").last ?? trimmed
            return Int(numStr) ?? -1
        }
    }

    /// 向量索引到 swizzle 字符
    static func vectorIndexToSwizzle(_ idx: Int) -> String {
        switch idx {
        case 0: return "x"
        case 1: return "y"
        case 2: return "z"
        case 3: return "w"
        default: return "[\(idx)]"
        }
    }

    /// 从 IR 向量类型提取维度
    static func extractVectorDim(_ irType: String) -> Int {
        // <4 x float> → 4
        if irType.hasPrefix("<") && irType.contains(" x ") {
            let inner = irType.dropFirst().prefix(while: { $0 != " " })
            return Int(inner) ?? 4
        }
        return 1
    }

    /// 构造指定维度的向量类型
    static func vectorTypeWithDim(_ baseType: String, dim: Int) -> String {
        if dim <= 1 { return baseType }
        // 从 <4 x float> 中提取元素类型
        if baseType.hasPrefix("<") && baseType.contains(" x ") {
            let inner = String(baseType.dropFirst().dropLast())
            let parts = inner.components(separatedBy: " x ")
            if parts.count >= 2 {
                let elemType = parts.last?.trimmingCharacters(in: .whitespaces) ?? "float"
                return "<\(dim) x \(elemType)>"
            }
        }
        return baseType
    }

    /// 去掉 fast-math 标志
    static func stripFastMathFlags(_ s: String) -> String {
        let flags = ["fast", "nnan", "ninf", "nsz", "arcp", "contract", "reassoc", "afn"]
        var result = s
        for flag in flags {
            result = result.replacingOccurrences(of: flag + " ", with: "")
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// fcmp 条件码到 MSL 运算符
    static func fcmpCondToMSL(_ cond: String) -> String {
        switch cond {
        case "oeq", "ueq": return "=="
        case "one", "une": return "!="
        case "ogt", "ugt": return ">"
        case "oge", "uge": return ">="
        case "olt", "ult": return "<"
        case "ole", "ule": return "<="
        case "ord": return "== /* ordered */"
        case "uno": return "!= /* unordered */"
        case "true": return "== /* always true */"
        case "false": return "!= /* always false */"
        default: return "/* \(cond) */"
        }
    }

    /// icmp 条件码到 MSL 运算符
    static func icmpCondToMSL(_ cond: String) -> String {
        switch cond {
        case "eq": return "=="
        case "ne": return "!="
        case "ugt", "sgt": return ">"
        case "uge", "sge": return ">="
        case "ult", "slt": return "<"
        case "ule", "sle": return "<="
        default: return "/* \(cond) */"
        }
    }

    /// barrier 标志常量到 MSL mem_flags
    static func barrierFlagsToMSL(_ flags: String) -> String {
        switch flags {
        case "0": return "mem_flags::mem_none"
        case "1": return "mem_flags::mem_device"
        case "2": return "mem_flags::mem_threadgroup"
        case "3": return "mem_flags::mem_threadgroup | mem_flags::mem_device"
        default: return "mem_flags::mem_threadgroup"
        }
    }

    /// AIR memory_order i32 值映射为 MSL memory_order 枚举
    /// 0=relaxed, 1=acquire, 2=release, 3=acq_rel, 5=seq_cst
    static func memoryOrderToMSL(_ order: String) -> String {
        switch order.trimmingCharacters(in: .whitespaces) {
        case "0": return "memory_order_relaxed"
        case "1": return "memory_order_acquire"
        case "2": return "memory_order_release"
        case "3": return "memory_order_acq_rel"
        case "5": return "memory_order_seq_cst"
        default: return "memory_order_relaxed"
        }
    }

    /// E-006b9: 为 atomic 操作生成 MSL 调用
    ///
    /// AIR 原子函数参数格式:
    ///   fetch_* / exchange / load:   (ptr, val, order, scope, volatile)
    ///   store:                       (ptr, val, order, scope, volatile)
    ///   cmpxchg:                     (ptr, expected, desired, succ_order, fail_order, scope, volatile)
    ///
    /// MSL 对应签名:
    ///   fetch_* / exchange:          atomic_fetch_*_explicit(obj, val, order)
    ///   load:                        atomic_load_explicit(obj, order)
    ///   store:                       atomic_store_explicit(obj, val, order)
    ///   cmpxchg:                     atomic_compare_exchange_weak_explicit(obj, expected, desired, succ_order, fail_order)
    static func generateAtomicMSL(
        mapping: AirBuiltinMapping,
        airName: String,
        args: [String],
        argTypes: [String]
    ) -> String {
        let mslFunc = mapping.mslFunction

        // cmpxchg 有 7 个 AIR 参数: (ptr, expected, desired, succ_order, fail_order, scope, volatile)
        if mslFunc.contains("compare_exchange") {
            // AIR: ptr, expected, desired, succ_order(i32), fail_order(i32), scope(i32), volatile(i1)
            // MSL: obj, expected, desired, succ_order, fail_order
            guard args.count >= 5 else {
                return "\(mslFunc)(/* atomic args error */)"
            }
            let obj = args[0]
            let expected = args[1]
            let desired = args[2]
            let succOrder = memoryOrderToMSL(args[3])
            let failOrder = memoryOrderToMSL(args[4])
            return "\(mslFunc)(\(obj), \(expected), \(desired), \(succOrder), \(failOrder))"
        }

        // load: (ptr, order, scope, volatile)
        if mslFunc.contains("atomic_load") {
            guard args.count >= 2 else {
                return "\(mslFunc)(/* atomic args error */)"
            }
            let obj = args[0]
            let order = memoryOrderToMSL(args[1])
            return "\(mslFunc)(\(obj), \(order))"
        }

        // store: (ptr, val, order, scope, volatile)
        if mslFunc.contains("atomic_store") {
            guard args.count >= 3 else {
                return "\(mslFunc)(/* atomic args error */)"
            }
            let obj = args[0]
            let val = args[1]
            let order = memoryOrderToMSL(args[2])
            return "\(mslFunc)(\(obj), \(val), \(order))"
        }

        // fetch_* / exchange: (ptr, val, order, scope, volatile)
        guard args.count >= 3 else {
            return "\(mslFunc)(/* atomic args error */)"
        }
        let obj = args[0]
        let val = args[1]
        let order = memoryOrderToMSL(args[2])
        return "\(mslFunc)(\(obj), \(val), \(order))"
    }

    /// 过滤纹理 air 调用的内部控制参数，只保留用户可见参数
    /// 返回 (filtered_args, filtered_types) 元组，保留类型信息供 bias/level 包装使用
    /// - airName: AIR 内建函数名，用于识别需要保留 i32 参数的变体（如 _2d_array 的 array_index）
    static func filterTextureArgs(_ args: [String], argTypes: [String], airName: String = "") -> (args: [String], types: [String]) {
        var resultArgs: [String] = []
        var resultTypes: [String] = []
        // E-006b8: 对 _2d_array 变体，coord 后的第一个 i32 是 array_index（语义参数），不能过滤
        let isArrayVariant = airName.contains("_2d_array")
        var firstI32Kept = false
        for (i, arg) in args.enumerated() {
            let type = i < argTypes.count ? argTypes[i] : ""
            // E-006a2e10: 跳过未解析的全局 symbol（resolveIROperand 对 @ 符号返回空）
            if arg.isEmpty { continue }
            // 跳过 i1 (bool 控制标志) 和 i32 控制参数（但保留坐标/颜色）
            if type == "i1" { continue }
            // 跳过零值 i32 控制标志（如 mip level=0, slice=0）
            if type == "i32" && (arg == "0" || arg == "1" || arg == "2") {
                // E-006b8: _2d_array 的第一个 i32 是 array_index，即使值为 0 也要保留
                if isArrayVariant && !firstI32Kept {
                    firstI32Kept = true
                } else {
                    continue
                }
            }
            // 跳过 <N x i32> zeroinitializer（offset 参数）
            // E-006b8: 但 write_texture 的 <2 x i32> 是坐标参数，不能过滤
            if arg == "0" && type.contains("x i32") && !airName.contains("write_texture") { continue }
            // 跳过 "0.0" float 控制参数（如 bias=0 或 min_lod_clamp=0 是无操作）
            if type == "float" && (arg == "0.0" || arg == "0.000000e+00") {
                continue
            }
            resultArgs.append(arg)
            resultTypes.append(type)
        }
        return (resultArgs, resultTypes)
    }
}
