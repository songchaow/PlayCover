## resource-type-name-preservation：实现结果

## 本轮分析的差异类型

本轮处理的是 `CC-003.2` 里剩余的一类 `L2`：

- `entry 参数语义摘要变化`
- `entry 资源语义摘要变化`

下钻代表 case 后，发现它并不是 buffer 绑定、地址空间、access 或 struct layout 真变了，而是同一条 buffer 资源的 `air.arg_type_name` 在 round-trip 后被改写了大小写：

- original：`unity_Builtins0Array_Type`
- regenerated：`Unity_Builtins0Array_Type`

## 单 case 证据

目标 case：

- `build/semantics-validation/roundtrip/20260410-014309-f66c9eb1/com.tencent.tmgp.speedmobile.db/modules/c66b9d4a60df030991dd90f8ed9e58368df846eeed70022fb8a0f402b4bbcd7b/original.ll`
- `build/semantics-validation/roundtrip/20260410-014309-f66c9eb1/com.tencent.tmgp.speedmobile.db/modules/c66b9d4a60df030991dd90f8ed9e58368df846eeed70022fb8a0f402b4bbcd7b/regenerated.ll`

修复前，这个样本的 canonical compare 只在一处 resource type name 上不一致：

- `argSemantics` 中 buffer(2) 的 `type=unity_Builtins0Array_Type -> Unity_Builtins0Array_Type`
- `resourceSemantics` 中同一条记录也发生了相同漂移

这说明问题更像：

- `IRToMSLConverter` 在生成 MSL 时把 metadata 提供的用户类型名做了首字母大写化

而不是：

- compare 把完全一致的资源语义误判成不同

## 本轮实现内容

已在：

- `Carthage/Checkouts/PlayTools/PlayTools/IRToMSLConverter.swift`

做一次最小 converter 修正：

- 保留 synthetic 名称（如 output / stage-in struct）原有的首字母大写策略
- 对 metadata / IR 中的用户自定义类型名，只做合法标识符清理，不再主动改写大小写
- 同步让 buffer 参数声明、IR 结构体类型映射、用户 struct 定义里的类型引用都走同一套 preserve-case 规则

这样处理后：

- MSL 仍然能正常生成和编译
- regenerated AIR metadata 能继续保留 original 中的 `unity_Builtins0Array_Type`
- compare 不需要额外新增一条“忽略类型名大小写”的降噪规则

## 单 case 验证结果

先对单样本重放：

- `python3 Scripts/corpus_replay_runner.py --ll build/semantics-validation/roundtrip/20260410-014309-f66c9eb1/com.tencent.tmgp.speedmobile.db/modules/c66b9d4a60df030991dd90f8ed9e58368df846eeed70022fb8a0f402b4bbcd7b/original.ll --output-file build/semantics-validation/roundtrip/manual-c66b9d4-type-name-fix/generated.metal`

结果确认：

- 生成的 `generated.metal` 中 struct 名与 buffer 参数类型都已恢复为 `unity_Builtins0Array_Type`
- full round-trip 后，该 case 的 compare 结果从 `L2` 降为 `L1`
- 消失的差异：
  - `entry 参数语义摘要变化`
  - `entry 资源语义摘要变化`
- 剩余差异只剩：
  - `指令族统计变化`
  - `模块元数据 targetTriple 变化`

## 相关验证

已执行：

- `python3 Scripts/test_ir_canonical_compare.py`
- `python3 Scripts/test_ir_semantics_roundtrip_runner.py`

两组脚本均通过。

同时，`lsp_diagnostics` 对 `IRToMSLConverter.swift` 没有新增 error；只剩两个与本轮无关的既有 warning。

## 当前结论

本轮已经可以明确下结论：

- `CC-003.2` 里至少有一类残留 `entry 资源语义摘要变化` 并不是 compare 口径问题
- 它的根因是 converter 在用户类型名上引入了不必要的大小写漂移
- 这类问题更适合在 `IRToMSLConverter` 修，而不是继续放宽 `ir_canonical_compare.py`

## 下一步建议

在这类 entry/resource type-name 漂移被收掉后，下一步更值得继续分析的是：

- `模块级 addrspace 分布变化`
- `模块级 air intrinsic 使用变化`
- `函数内 air intrinsic 调用统计变化`

也就是当前 diagnostics 剩余两个 `L2` 和 corpus 里仍重复出现的那组更像结构差异的残留模式。
