## E-006d：原神同一界面重复启动时的随机渲染异常调查

## 状态：TODO

## 当前已完成子项

- **E-006d1（✅ DONE）**：新增 `Scripts/compare_capture_runs.py`，用于对比两轮采集的 `manifest.jsonl` 与 `modules/` 快照，直接输出：
  - 哪些 `moduleKey` 仅出现在单边
  - 共享 `moduleKey` 在 `module.bc` / `module.ll` / `module.generated.metal` / `module.meta.json` 上是否有 hash 或尺寸差异
  - `functionNames` / `functionTypes` / `generatedFunctionNames` / `generatedFunctionTypes` / `selector` / `captureAction` / compile 状态摘要是否一致
- 这一步优先服务于第 2、3、4 个核心问题：**输入是否相同 / 输出是否相同 / 同 key 模块的离线产物是否稳定**

## 现象

- 当前现象：用 PlayCover 打开原神，按既有 Road E 流程会执行 `metal IR 提取 -> 反编译为 MSL -> makeLibrary(source:) 重编译替换`；即使停留在**同一个界面**，多次启动后画面表现也会不完全一样
- 已知边界：当前观察到的是**mesh 没有变化**，但局部渲染结果会随机异常；这说明异常不一定来自几何体本身，但也**还不能直接实锤是 shader 改坏**
- 新增判断：由于原神是延迟管线，base pass 对比看起来也可能类似，因此异常也可能出现在后处理、着色阶段，或更上层的 render pipeline 顺序 / 配置，而不一定只在 `IR -> MSL -> makeLibrary(source:)` 这条链路
- 当前最保守结论：在现阶段，最稳定的复现对照不是“证明哪一段 shader 错了”，而是**进行了反编译/重编译替换**与**完全不做替换**时，最终效果确实不一样

## 目标

`E-006d` 的目标不是继续证明“源码可见”或“compile 通过”，而是回答下面四个问题：

1. **“替换”与“不替换”时，最终效果差异是否稳定存在？**
2. **同一界面重复启动时，进入 shader 链路的输入是否相同？**
3. **若输入相同，生成出的单模块 MSL / 聚合 MSL / compile 结果是否完全一致？**
4. **若生成结果也相同，运行时是否稳定使用了替换后的 library，还是问题出在更后续的着色 / 后处理 / render pipeline 阶段？**

## 优先排查顺序

### 1. 先固定复现条件

- 尽量固定 app 版本、账号状态、停留界面、画质设置、注入步骤和启动顺序
- 同一条件下至少做 `2~3` 轮重复启动
- 增加一组**完全不做替换**的对照运行，作为最低风险基线
- 每轮都保存：
  - `manifest.jsonl` 增量
  - `ShaderCorpus/` 新增模块目录
  - `ShaderSourceDiagnostics/` 新文件
  - 单模块 `module.bc` / `module.ll` / `module.generated.metal`
  - 聚合 MSL
  - 对应 `.gputrace`

### 2. 先确认“替换 vs 不替换”差异是否稳定

- 在相同界面、相同设置下，对比：
  - 正常执行替换链路
  - 完全不做替换
- 若两者最终效果稳定不同，说明问题至少与“替换开启后引入的变化”有关；但这仍不足以直接证明根因就是某一段 shader lowering
- 若差异并不稳定，则需先回到更基础的 live 条件控制，避免把运行条件波动误判为链路问题

### 3. 再比较“输入是否相同”

- 比较每轮新增或命中的 `moduleKey`
- 比较 `functionNames` / `functionTypes`
- 比较 `module.bc` / `module.ll` 哈希
- 若这里已经不同，先不要直接归咎于 converter；应继续追踪是 app 本身输入变了，还是拦截 / 导出路径在不同轮次拿到了不同 metallib/module
- 推荐先保存每轮 `manifest.jsonl` 与 `modules/` 快照后，运行：

```bash
python3 Scripts/compare_capture_runs.py \
  --run-a /path/to/run-a/com.miHoYo.Yuanshen \
  --run-b /path/to/run-b/com.miHoYo.Yuanshen \
  --output build/e006d-run-diff.json
```

- 若报告中的 `onlyInRunA` / `onlyInRunB` 非空，说明同一界面重复启动时，至少进入 corpus 的 `moduleKey` 集合还不稳定

### 4. 再比较“输出是否相同”

- 对相同 `moduleKey` 比较：
  - `module.generated.metal`
  - 聚合后的 MSL 源码
  - `xcrun metal` / `makeLibrary(source:)` 编译结果
- 若同一 `.ll` 产生不同 `.metal`，优先排查：
  - `IRToMSLConverter` 是否存在依赖遍历顺序的发射逻辑
  - 聚合阶段是否存在函数顺序 / 去重 / struct emission 顺序不稳定
  - 日志 / diagnostics / baseline 是否把同一模块的不同版本混在一起
- `Scripts/compare_capture_runs.py` 会对共享 `moduleKey` 直接比较 `.bc/.ll/.metal/.meta` 的 sha256；如果 `module.ll` 一致而 `module.generated.metal` 不一致，可优先怀疑 converter / 聚合稳定性，而不是先回到 live 侧猜测

### 5. 最后比较“替换与实际使用是否相同”

- 确认每轮 `attemptLibraryReplacement(...)` 是否都进入成功路径
- 对照是否出现 silent fallback、部分模块跳过、聚合失败后回退原始 library
- 结合 `.gputrace` 确认最终被 draw call 使用的 library 是否稳定来自 PlayTools 注入源码
- 若 base pass 对比看起来接近，则继续检查更后续的着色 / 后处理 / render pipeline 行为，不要在这一步过早停在“shader 本身没问题”或“shader 一定有问题”的二选一

## 当前工作假设

- **假设 A：输入并不稳定**
  - 同一界面看似相同，但真实命中的 metallib/module 集合并不完全一致
- **假设 B：输入相同，但 `IR -> MSL` 结果不稳定**
  - 同一 `.ll` 在不同运行中生成了不同的 MSL 或聚合顺序不同
- **假设 C：源码生成稳定，但 runtime 替换或 pipeline 实际使用不稳定**
  - 例如聚合后部分替换、静默 fallback、或最终 draw call 并未稳定使用替换后的 library
- **假设 D：源码与替换都稳定，但问题出在更后续的着色 / 后处理 / render pipeline 阶段**
  - 这能解释“base pass 看起来类似，但最终画面仍然不一样”
- **假设 E：源码与替换都稳定，但当前 MSL 只是“可编译”而非“语义等价”**
  - 这会表现为 `compile green`、`.gputrace` 也可见源码，但真实渲染结果仍然漂移或局部错误

## 完成标准

- 至少形成一组**可重复复现**的对照样本
- 至少形成一组**替换 vs 不替换**的稳定对照样本
- 能明确将问题归到以下某一层：
  - 替换开启后引入的稳定差异（但根因层级未定）
  - 输入差异
  - `IRToMSLConverter` 非确定性 / 错误 lowering
  - 聚合 MSL / replacement 链路问题
  - runtime 实际使用阶段问题
  - 更后续的着色 / 后处理 / render pipeline 顺序或配置问题
- 若定位到具体 blocker，需要把它转化为可离线 replay / compile / diff 的样本或规则，而不是继续只停留在 live 观察层面

## 当前建议执行顺序

1. 固定 live 条件，分别保留两轮 `manifest.jsonl` 与 `modules/` 快照
2. 先用 `Scripts/compare_capture_runs.py` 对比 run-vs-run，确认输入/输出是否已经漂移
3. 只有在离线差异已经收敛到具体 `moduleKey` 或具体产物差异后，才继续下钻到 `.gputrace`、实际替换命中情况、以及更后续的 pass / pipeline 行为

## 从 dashboard 下沉的细粒度技术备注

- **Metal IR 的 shader 类型信息出现在三个位置，需要按优先级回退**：① `!air.vertex` / `!air.fragment` / `!air.kernel` 顶层 metadata（最可靠）② `attributes #N = { "air.fragment" ... }` 声明（某些合成/裁剪后的 IR 只有这个）③ 函数名/`inferShaderType` 启发式（最不可靠）
- **孤立 metadata arg 节点可以通过 `air.arg_name` 做 fallback 匹配**：某些 IR 中 `air.texture` / `air.sampler` 的 metadata arg 节点存在但未被函数 args 列表引用；按 IR 参数名与 `air.arg_name` 做 name-based lookup 可以恢复 texture/sampler 类型
- **fragment shader 的无 attribute value 参数必须带 `[[color(N)]]`**：fragment 返回非 void 标量/向量类型时，隐式输出占用 `[[color(0)]]`，输入 value 参数的 color index 应从 1 开始
- **texture access qualifier 不能一刀切删除**：`texture2d<float, write/read/read_write>` 的 access qualifier 若丢失，会让 `write()` / `read()` 编译失败
- **AIR 的 `write_texture_*` 参数顺序与 Metal 不同**：AIR 为 `(texture_ptr, coord, color, ...)`，Metal 为 `write(color, coord)`
- **`___metal_fast_*` 与 `air.fast_*` 的 MSL 映射必须统一去掉 `fast_` 前缀**：fast-math 语义属于编译选项，而不是生成的顶级函数名
- **LLVM IR 的 `i32` 无 signedness，但 MSL 的 `int4` / `uint4` 是不同类型**：vector load/store 需结合 pointer element type 做 signedness 修正
- **AIR IR 中 builtin 参数的 IR 实际类型可能与 metadata 声明不一致**：如 metadata 声明为 `uint3`，IR 实际却是 `float3`，必要时需在函数体开头插入显式转换
- **`filterTextureArgs` 不能盲目过滤所有零值 `i32` / `<N x i32>`**：某些变体中这些值是语义参数或真实坐标，误删会造成错误 lowering
- **compile blocker 修复后可能暴露下一个预存在 blocker**：数值统计不变并不代表本轮修复无效
- **`metal::_atomic` 在 MSL 中是 `atomic_int` / `atomic_uint` 引用类型，不是结构体**；AIR 原子函数中的 `scope` / `volatile` 等内部控制参数需过滤
- **`bitcast ptr to ptr` 在 MSL 中通常是 no-op**：不应误发射为数值 `as_type<>()`
- **真实 corpus compile 通过不等于 `.gputrace` 源码可见，更不等于真实渲染正确**：这三层验证必须分开
- **延迟管线下，base pass 看起来类似并不能排除后续阶段问题**：若当前观察主要来自最终画面差异，就必须把后处理、着色阶段与 render pipeline 顺序 / 配置一起纳入排查范围
- **“替换 vs 不替换”是当前最低风险的稳定比较基线**：在根因层级未明确前，先确认开启替换后是否稳定引入了最终效果差异，再继续往具体 stage / pass 下钻
- **`air.struct_type_info` 第三个 `i32` 是 `elementCount`，不是 alignment**：数组字段若被错当标量，会直接造成 subscript 类 compile blocker
- **结构体类型名要在参数声明和结构体定义两处保持一致**：尤其是首字母小写的用户类型名，需要与 `sanitizeTypeName` 策略统一
- **`check_gputrace_sources.py` 需要识别注释开头的注入 MSL**：PlayTools 生成源码常以 `// Auto-generated ...` 开头
- **多模块 metallib 的重复函数名是 Unity shader 的典型特征**：聚合编译前必须去重，否则会在单个 MSL 文件内产生重名函数
- **`throw` + 静默 `catch` 回退是 runtime hook 的危险反模式**：会把关键 blocker 隐藏为“看似正常但实际回退原始 library”
- **`air.struct_type_info` metadata 的字段类型可能与 IR 结构体定义不一致**：必要时要用 IR 结构体定义交叉校正 metadata 字段信息
- **失败路径导出是闭环的关键一环**：`ShaderSourceDiagnostics/<baseName>_modules/` 让失败样本也能进入离线 replay 主路径
- **异常路径中 `preparedModules` 可能部分填充**：导出时应区分“所有模块的 `.bc`”与“已成功准备模块的 `.ll/.metal`”

## 与其他文档的关系

- 当前主线 / 优先级 / TODO：`00-Dashboard.md`
- 历史 live blocker 时间线：`00-Dashboard-Archive.md`
- 失败样本闭环 / re-capture 策略：`E-004-CorpusClosureAndRecapturePolicy.md`
- corpus replay / batch compile / diff：`E-005-OfflineReplayBatchCompileDiff.md`
