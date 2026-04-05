## E-006d：绘制内容差异（draw call / render pass / pipeline）对比参考

## 作用

本文档承接 `E-006d` 中“更后续 render pipeline / post-processing 可能有问题”的专项分析方法。它不替代 `00-Dashboard.md` 的主线控制面，也不替代 `E-006d-GenshinRenderingNondeterminism.md` 的判断顺序；作用是把 **draw call / Render Encoder / Pipeline State / 关键 pass** 级别的检查方法集中到一个地方，避免 dashboard 主体继续膨胀。

> ⚠️ **这是一条重要但有前提的专项分析分支。** 若当前环境已经具备 Xcode、Accessibility 权限与 `cliclick`，agent 可以通过脚本自动驱动；若环境不满足，这条线就只能保留为专项分析手段，**不能**升级为当前日常默认 gate，更不能默认要求用户人工协助。

## 当前结论

- 当前已经确认：`replacement=off / on` 的 **corpus / aggregate / trace** 对照还没有形成“跨模式稳定不同”的稳定证据，因此不能只靠 shader 文本、哈希或 replacement attempt 数量就提前定性
- 当前还没有完成：对**当前代表性截帧对**做正式的绘制内容结构化 diff。现阶段最适合优先下钻的是：
  - **未替换**：`replacement-off-run1`
  - **替换成功且带 `.gputrace`**：`replacement-on-run5`
- `replacement-on-run6` 虽然是最新 live 基线，但当前没有新的 `.gputrace`，因此它更适合继续承接 session / capture / trace 覆盖率问题，而不是直接拿来做 draw content 结构对比

## 为什么这条线不能漏

- 当前现象是：**mesh 不变，但局部渲染结果异常**。这天然说明问题不一定只在几何输入或 shader 文本本身
- 原神当前链路是**延迟渲染 + 后处理**，base pass 看起来接近，并不能排除 Deferred Shading、TAA、Bloom、Uber、UI 合成等更后续阶段
- 因此，`E-006d` 若只停留在：
  - `module.bc/.ll/.metal` 是否一致
  - `aggregate.generated.metal` 是否一致
  - `.gputrace` 里是否能看到源码
  这些都还不够；还必须补上 **draw call / Render Encoder / Pipeline State / attachment / key pass** 这一层证据

## 现有自动化能力

当前仓库里已经有可直接复用的 Xcode GUI 自动化工具：

- `../../../Scripts/e006d_render_diff.py`
  - 新的标准专项入口，负责把 `build/e006d-run-snapshots/<label>/<bundle-id>` 下的标准 run 快照，接到本目录现有 GUI 自动化脚本
  - 支持按 run label 自动解析 `.gputrace`、顺序导出 `frame_dump/`、`cb_data.json`、可选 `key_pass_details.json`，并生成 `comparison.json + summary.txt`
  - 默认先做首轮结构 diff；只有需要下钻关键 pass 时，再显式加 `--include-re-details`

- `../../XCodeOperation/xcode_gpu_ops.py`
  - 支持 `open` / `status` / `dump` / `summary` / `walk`
  - 可自动完成：打开 `.gputrace`、点击 Replay、导出 Navigator / Pipeline State 视图、读取当前 draw call summary
- `../../XCodeOperation/collect_cbs.py`
  - 批量导出每个 `Command Buffer` 的子节点列表
  - 适合快速比较 **CB 数量** 与 **每个 CB 下有哪些 Render Encoder / presentDrawable**
- `../../XCodeOperation/collect_re_details.py`
  - 步进 draw call，按 `Render Encoder` 收集 `pipeline_state`、`vertex/fragment resources`、`attachments` 等结构化摘要
  - 适合下钻 **关键 pass** 是否真的不同
- `../../XCodeOperation/renderanalysistask/06-final-render-pipeline.md`
  - 已经给出原神历史单帧的结构化基线：**26 个 Render Encoder、约 5,300 个 draw call、约 50 个 pipeline state**

## 推荐执行顺序（代表性 off/on 对照）

先比较结构，再决定是否需要逐步遍历 draw call：

### 0. 优先走统一 runner（推荐默认入口）

```bash
python3 Scripts/e006d_render_diff.py collect-pair \
  --bundle-id com.miHoYo.Yuanshen \
  --run-a replacement-off-run1 \
  --run-b replacement-on-run5
```

默认产物位置：

- `build/e006d-render-diff/com.miHoYo.Yuanshen/replacement-off-run1/`
- `build/e006d-render-diff/com.miHoYo.Yuanshen/replacement-on-run5/`
- `build/e006d-render-diff/replacement-off-run1-vs-replacement-on-run5/comparison.json`
- `build/e006d-render-diff/replacement-off-run1-vs-replacement-on-run5/summary.txt`

若首轮结构对比还不够，再补：

```bash
python3 Scripts/e006d_render_diff.py collect-pair \
  --bundle-id com.miHoYo.Yuanshen \
  --run-a replacement-off-run1 \
  --run-b replacement-on-run5 \
  --include-re-details \
  --force
```

### 1. 打开 `.gputrace` 并导出整帧摘要

```bash
OPS=/Users/songdogwang/Codes/PlayCover/LocalDocs/XCodeOperation

python3 $OPS/xcode_gpu_ops.py open /abs/path/to/replacement-off-run1.gputrace --no-analysis
python3 $OPS/xcode_gpu_ops.py dump -o build/e006d-render-diff/off1/frame_dump

python3 $OPS/xcode_gpu_ops.py open /abs/path/to/replacement-on-run5.gputrace --no-analysis
python3 $OPS/xcode_gpu_ops.py dump -o build/e006d-render-diff/on5/frame_dump
```

优先比较：
- `navigator_api_call.json`
- `navigator_pipeline_state.json`
- `memory_info.txt`

### 2. 收集 `Command Buffer` → 子节点列表

```bash
python3 $OPS/xcode_gpu_ops.py open /abs/path/to/replacement-off-run1.gputrace --no-analysis
python3 $OPS/collect_cbs.py -o build/e006d-render-diff/off1/cb_data.json

python3 $OPS/xcode_gpu_ops.py open /abs/path/to/replacement-on-run5.gputrace --no-analysis
python3 $OPS/collect_cbs.py -o build/e006d-render-diff/on5/cb_data.json
```

这一层先回答：
- 哪边 `Command Buffer` 更多/更少
- 哪边某个 `CB` 下多了/少了 `Render Encoder`
- 哪边更早出现 `presentDrawable`

### 3. 对关键 `Render Encoder` 收集详细 summary

```bash
python3 $OPS/xcode_gpu_ops.py open /abs/path/to/replacement-off-run1.gputrace
python3 $OPS/collect_re_details.py -o build/e006d-render-diff/off1/key_pass_details.json --re-count 26

python3 $OPS/xcode_gpu_ops.py open /abs/path/to/replacement-on-run5.gputrace
python3 $OPS/collect_re_details.py -o build/e006d-render-diff/on5/key_pass_details.json --re-count 26
```

这一层重点看：
- `pipeline_state`
- `vertex_function` / `fragment_function`
- `attachments`
- 哪些关键 pass 的 summary 发生变化

### 4. 必要时再进入逐步遍历 / 截图

若前面三层已经看到明显结构差异，再决定是否继续用：

```bash
python3 $OPS/xcode_gpu_ops.py walk -o build/e006d-render-diff/off1/walk -n 100
```

这一步成本高，只在需要锁定**具体 draw call 区间**时使用。

## 优先比较的指标

建议按下面顺序出结论：

1. **CB 数量是否相同**
2. **每个 CB 下的 RE 列表是否相同**
3. **Pipeline State 分组和出现次数是否相同**
4. **关键 RE 的 attachment / pipeline / shader function 是否相同**
5. **若前四层仍一致，再继续怀疑 shader 语义等价、runtime 实际使用、或 trace 可见性不足**

## 结论判定建议

- **若 CB / RE / Pipeline State 数量已经不同**：优先怀疑 render pipeline / pass 结构本身就不同，先不要把根因过早压回 shader lowering
- **若数量相同，但关键 RE summary 不同**：优先怀疑更后续的 pass 配置、attachments、资源绑定或 pipeline 使用路径
- **若结构层也完全相同**：再回到 `E-006d` 主文档，继续比较 replacement 是否真正被使用、以及当前 MSL 是否只是“可编译”但未必语义等价

## 当前限制

- `.gputrace` 的 `device-resources` / `unsorted-capture` 当前是私有 `MTSP` 结构，仓库里**没有**稳定的纯离线解析器来直接回答 draw call 数或 render pass 数
- 因此现阶段最稳的做法仍是：**Xcode 打开 `.gputrace` + GUI 自动化脚本采集结构化结果**
- `collect_re_details.py` 成本较高，整帧可能需要 `15~20` 分钟；默认应先跑 `dump` 和 `collect_cbs.py`
- `Scripts/e006d_render_diff.py` 只负责把现有 Xcode GUI 自动化工具接成统一 runner；它不会绕过 Xcode / Accessibility / `cliclick` 前提，也不能替代最终人工打开 `.gputrace` 做视觉确认
- 若环境缺少 Accessibility 权限或 `cliclick`，这条线只能作为专项分析能力记录，**不能**写成当前日常默认 gate

## 与其他文档的关系

- 当前主线 / TODO：`00-Dashboard.md`
- `E-006d` 判断顺序与完成标准：`E-006d-GenshinRenderingNondeterminism.md`
- Xcode GUI 自动化工具说明：`../../XCodeOperation/README.md`
- 原神历史单帧渲染结构基线：`../../XCodeOperation/renderanalysistask/06-final-render-pipeline.md`
- `.gputrace` 私有结构边界：`../Research/02-gputrace内部结构分析.md`
