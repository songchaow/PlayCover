## buffer-noalias 对齐小任务进展

## 目标

围绕以下问题做一次面向落地的调查：

- 能否让 round-trip 后的 alias / `noalias` 表达更接近原始 IR
- 可行路径是改 `compare`、改反编译后的 MSL 发射，还是改重编译姿势
- 哪条路径成本最低、收益最高、最容易验证

## 当前进度

### 已完成

- 建立工作目录：`LocalDocs/XCodeReleaseShaderDebug/SemanticsValidation/difference-analysis/buffer-noalias/`
- 明确目标 case：`91c46448ca24983b29716a9fe2c28a7930c10b81802758ded6977907bf01ae9b`
- 启动两路并行调查：
  - 本地实现搜索：查找 `IRToMSLConverter` / compare / 编译脚本中的可改点
  - 外部线索搜索：查找 Metal / AIR 中 alias 表达与编译姿势相关证据

### 已完成

- 设计并执行最小 Metal 编译实验
- 在真实 shader 副本上验证 `__restrict` 能把第一个 constant buffer 参数从 `"air-buffer-no-alias"` 拉回参数级 `noalias`
- 在 `IRToMSLConverter.swift` 中实现了基于原始 IR 参数 `noalias` 的定向 `__restrict` 回放
- 在真实 case 上完成一次 end-to-end replay + Metal 重编译 + canonical compare 复测
- 收集本地可改点：
  - `Carthage/Checkouts/PlayTools/PlayTools/IRToMSLConverter.swift`
  - `Scripts/ir_canonical_compare.py`
  - `Scripts/ir_to_msl_smoketest.sh`
- 收集外部线索：
  - MSL 没有明确公开成文的“buffer alias 对齐”专用姿势
  - 当前最强可控因子仍然是 MSL 参数写法本身，尤其是 `__restrict`

### 当前判断

- `compare` 归一化：最适合先做
- emitted MSL 定向加 `__restrict`：技术上已实现并验证可行，但语义风险仍高于只改 compare
- 仅调 compile posture：当前证据最弱，不适合作为第一优先级
- 参数 alias 语义建模：适合作为中期能力建设

### 最新结果

- 真实 case 的 regenerated MSL 已成功把第一个 buffer 参数发射为：
  - `const constant FGlobals_Type& __restrict FGlobals [[buffer(0)]]`
- 真实 case 的 regenerated LLVM IR 已成功把第一个参数恢复为参数级 `noalias`
- canonical compare 风险等级已从原先的 `L3` 降到 `L2`
- 当前已不再出现 `entry 参数类型摘要变化`
- 仍剩余 `entry 参数语义摘要变化`，其根因是 regenerated 侧的第一个 buffer 语义仍显式带 `addrspace=2`
- 已完成两条 full-batch canonical compare 复跑：
  - `shader-corpus-batch-after-noalias`
  - `shader-source-diagnostics-batch-after-noalias`
- 全量结果表明：整体 `L3` 数量继续下降，且在共有样本上没有出现新增 `L3`

## 输出文件

- `01-experiment-results.md`：最小样本与真实样本实验结果
- `02-alignment-options.md`：可行方案、成本与风险排序
- `03-external-clues.md`：外部资料与对实验设计的启发
- `04-implementation-result.md`：代码实现与单个真实 case 验证结果
- `05-full-batch-compare.md`：full-batch canonical compare 复跑结果
