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
- 收集本地可改点：
  - `Carthage/Checkouts/PlayTools/PlayTools/IRToMSLConverter.swift`
  - `Scripts/ir_canonical_compare.py`
  - `Scripts/ir_to_msl_smoketest.sh`
- 收集外部线索：
  - MSL 没有明确公开成文的“buffer alias 对齐”专用姿势
  - 当前最强可控因子仍然是 MSL 参数写法本身，尤其是 `__restrict`

### 当前判断

- `compare` 归一化：最适合先做
- emitted MSL 定向加 `__restrict`：技术上可行，但语义风险更高
- 仅调 compile posture：当前证据最弱，不适合作为第一优先级
- 参数 alias 语义建模：适合作为中期能力建设

## 输出文件

- `01-experiment-results.md`：最小样本与真实样本实验结果
- `02-alignment-options.md`：可行方案、成本与风险排序
- `03-external-clues.md`：外部资料与对实验设计的启发
