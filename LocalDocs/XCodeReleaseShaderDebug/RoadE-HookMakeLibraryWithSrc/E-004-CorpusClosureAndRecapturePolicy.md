## E-004 / E-006：失败样本闭环与 re-capture 策略参考

## 作用

本文档用于承接从 `00-Dashboard.md` 主体下沉的流程性说明：当新的 live `compile_failed` 样本只进入 `ShaderSourceDiagnostics/`、尚未进入 `ShaderCorpus/` 时，后续 agent 应如何判断"是否真的闭环"。

> ⚠️ **这不是新的目标分支，而是对现有 corpus-driven / offline-first 工作流的补充约束。** 当前主线与最新优先级仍以 `00-Dashboard.md` 为准。

## 当前事实

截至 `2026-04-04`（`E-004f4` 落地后）：

- **成功路径**：`attemptLibraryReplacement(...)` 成功时，样本会进入 `ShaderCorpus/<bundleId>/modules/<moduleKey>/`，稳定落盘 `module.bc`、`module.ll`、`module.generated.metal`、`module.meta.json` 与 `manifest.jsonl`
- **失败路径（`compile_failed` / `preflight_rejected`）**：样本进入 `ShaderSourceDiagnostics/<bundleId>/`，保存聚合 `.metal + .txt`，**同时**在 `<baseName>_modules/<moduleKey>/` 子目录下落盘每个模块的 `module.bc`、`module.ll`、`module.generated.metal` 与 `module.meta.json`
- **异常路径**：当 `LLVMDisassembler.disassemble()` 或 `IRToMSLConverter.convert()` 抛出异常时，在 `ShaderSourceDiagnostics/<bundleId>/` 下落盘所有模块的 `.bc`，以及已成功准备的模块的 `.ll`、`.metal`
- **直接后果**：`ShaderCorpus/` 仍是离线回归主入口；`ShaderSourceDiagnostics/` 中的失败样本现在**携带可离线 replay 的原始产物**

## 为什么这是工作流缺口（历史背景）

> ⚠️ 此节描述的是 `E-004f4` 落地前的问题状态。`E-004f4` 已通过失败路径导出实现了**路径 B 闭环**，新样本不再只停留在 diagnostics。

此前存在一个常见误判：

```text
fresh live 暴露新 blocker
  ↓
样本只落在 ShaderSourceDiagnostics/
  ↓
修复 IRToMSLConverter
  ↓
对 test-data + 现有 ShaderCorpus 回归全绿
  ↓
误以为"这个新 blocker 已闭环"
```

这里的问题在于：

- test-data 只能证明最小模式已覆盖
- 现有 `ShaderCorpus/` 只能证明**此前已经成功入库的样本**没有退化
- 如果新 blocker 对应的 live 样本从未进入 `ShaderCorpus/`，那么"现有 corpus 全绿"并不能证明该 live 样本现在已经可被成功替换

## 闭环判定规则

当一个 blocker **首次来源于 `ShaderSourceDiagnostics/`**，且对应样本**尚未进入 `ShaderCorpus/`** 时，必须满足以下至少一条：

### 路径 A：post-fix fresh capture 闭环

1. 部署修复后的 PlayTools / PlayCover
2. 执行最小 fresh capture
3. 确认该样本**不再只停留在 `ShaderSourceDiagnostics/`**
4. 若样本命中成功路径，应进入 `ShaderCorpus/`（新增 module 或命中 `conflict_preserved` / `reused`）
5. 再进行后续 `.gputrace` 最终确认

### 路径 B：失败路径导出闭环（✅ 已实现，`E-004f4`）

`E-004f4` 已为失败路径实现了 `.bc/.ll` 导出，以下替代闭环已可使用：

1. `compile_failed` / `preflight_rejected` 样本在失败时已自动保存原始 `module.bc` / `module.ll` / `module.generated.metal` / `module.meta.json` 到 `ShaderSourceDiagnostics/<bundleId>/<baseName>_modules/<moduleKey>/`
2. 修复 `IRToMSLConverter` 后，可直接对失败样本目录中的 `.ll` 做离线 replay + Metal compile
3. 该样本从"只能 live 重现"转为"可进入离线主路径"
4. 可通过 `corpus_replay_runner.py --ll <path_to_module.ll> --compile` 验证

**注意**：失败路径的 `module.meta.json` 中 `compileStatus` 为 `"compile_failed"` / `"preflight_rejected"` / `"exception"`，`captureSource` 为 `"failure_path"` / `"partial_failure_path"`，与成功路径（`compileStatus: "success"`）不同。

## Agent 执行策略

后续 agent 在处理类似任务时，建议按以下顺序判断：

1. **先问：这个 blocker 的样本是否已经在 `ShaderCorpus/` 中？**
   - 若是：优先离线 replay / compile / baseline diff
   - 若否：继续第 2 步
2. **若样本只在 `ShaderSourceDiagnostics/` 中（`E-004f4` 后已有模块级产物）**：
   - 检查是否有 `<baseName>_modules/` 子目录（`E-004f4` 后的样本应有）
   - 若有：直接对该目录中的 `.ll` 做离线 replay + compile 验证修复效果
   - 若无（历史旧样本）：需要 post-fix fresh capture 或手工补充
3. **若要宣告任务完成**：
   - 优先：对失败路径样本做离线 replay + compile 验证
   - 备选：补一次 post-fix fresh capture 确认

## 失败路径导出的目录结构（`E-004f4`）

```
ShaderSourceDiagnostics/<bundleId>/
  ├── 2026-04-04T15:13:34Z_newLibraryWithData:error:_compile_failed.metal
  ├── 2026-04-04T15:13:34Z_newLibraryWithData:error:_compile_failed.txt
  └── 2026-04-04T15:13:34Z_newLibraryWithData:error:_compile_failed_modules/
      ├── <sha256_of_module_bc>/
      │   ├── module.bc                   # 原始 bitcode
      │   ├── module.ll                   # LLVM IR
      │   ├── module.generated.metal      # 单模块 MSL
      │   └── module.meta.json            # 最小元数据
      └── <sha256_of_another_module_bc>/
          └── ...
```

`module.meta.json` 关键字段：

```json
{
  "schemaVersion": 2,
  "bundleId": "com.example.app",
  "moduleKey": "sha256hex...",
  "moduleKeyStrategy": "sha256(module.bc)",
  "selector": "newLibraryWithData:error:",
  "functionNames": ["main0"],
  "functionTypes": ["fragment"],
  "generatedFunctionNames": ["main0"],
  "generatedFunctionTypes": ["fragment"],
  "llvmDisStatus": "success",
  "converterStatus": "success",
  "compileStatus": "compile_failed",
  "captureSource": "failure_path",
  ...
}
```

## 当前已知案例

### `2026-04-04` 原神 `_MainLightClipPlaneAlphas` 样本

- fresh capture 的 `manifest.jsonl` 只新增了 43 条 `conflict_preserved` 复用事件
- 同时 `ShaderSourceDiagnostics/` 新增了 1 份 `compile_failed` live 样本
- 该样本暴露的根因是：metadata 中字段被写成标量 `"float"`，IR 结构体定义实际为 `[4 x float]`
- `E-006c2` 已修复 `generateUserStructDefinitions` 的数组字段发射逻辑
- **该 live 样本是在修复部署前捕获的，因此它没有 `_modules` 子目录（历史样本）；但 `E-004f4` 之后的同类失败样本将自动携带可离线 replay 的产物**

## 与其他文档的关系

- 当前主线 / TODO / 最新结论：`00-Dashboard.md`
- corpus 主实现与导出能力：`E-004-MetallibSourceExtraction.md`
- 离线 replay / compile / diff 能力：`E-005-OfflineReplayBatchCompileDiff.md`
- 更早的 live blocker 时间线：`00-Dashboard-Archive.md`
