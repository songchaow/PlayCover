# R9 Execution: Skill 引导层优化

**日期**: 2026-05-22
**执行者**: agent
**状态**: 完成

## 目标

让 agent 面对渲染问题时能"无脑"选对命令。纯文档层改动，不改代码实现。

## 执行内容

### R9.A: SKILL.md 精简 + 决策树重构

**改动**: 完全重写 `SKILL.md`（从 256 行叙述式 → ~150 行决策树式）

主要变化：
1. 新增 **Decision Tree** 段落：if-then-else 结构，agent 在 10 秒内找到正确入口
2. 突出 **核心 3 命令**：
   - `find-draws --by-label <name> --show-first --with-ir --with-uniforms`（从名字到完整上下文）
   - `draw-info <draw_index> --with-uniforms`（合并视图 + IR metadata + size_check）
   - `dump-uniforms --by-name <NAME>`（直接按名查值）
3. 删除冗长的 worked example 段落（已在 investigation-playbook.md）
4. 删除 12 段重复的 jq 管道示例（不再需要手工 join）

### R9.B: 5 个最常见 bug 模式速查模板

**改动**: 在 SKILL.md 中新增 "5 Bug Pattern Quick-Reference" 段落

| # | Pattern | 核心命令 | 判断标准 |
|---|---------|---------|---------|
| 1 | 黑屏/空白 | replay --list-resources → --export → --playto bisect | non-zero% = 0 |
| 2 | 颜色错/材质错 | find-draws --show-first --with-uniforms | uniforms_summary + value_health_summary |
| 3 | Crash/Validation | config enableValidation=1 → playto bisect | validation stderr messages |
| 4 | NaN/异常值 | shader-of-drawcall --with-uniforms | value_health_summary.nan_count > 0 |
| 5 | 纹理缺失/错误 | draw-info → export suspect texture | resource_id mismatch / blank texture |

每个模式包含：可直接复制的命令模板 + 预期输出字段 + 判断标准。

### R9.C: cli-reference 层级化

**改动**: 完全重写 `references/cli-reference.md`（从 1124 行扁平 → ~280 行层级化）

结构变化：
1. **Core Commands**（完整文档）: find-draws / draw-info / dump-uniforms — 包含用法、输出 schema、失败模式、Python API
2. **Supporting Commands**（精简参考）: shader-of-drawcall / replay / pipeline / frame-list / shader-of-rps / disasm / shader / config — 各 10-20 行，核心 flags + 一句话说明
3. 删除大量重复的 "Implementation notes" 段落（已在 architecture.md）
4. 保留 Python module mode 核心 API 签名表

### Skill Description 优化

按照 skill-creator 指导的"pushy"原则扩展 description 覆盖面：
- 新增触发词：uniform/cbuffer values, pipeline state inspection, draw call analysis, render pass debugging
- 新增自然语言触发短语："check the shader", "what's bound to this draw", "why is this material wrong", "decode the constant buffer"
- 强化最终规则："If you see any path ending in .gputrace... load this skill immediately"

## 设计原则

- 不改变任何代码实现（bridge / wrapper / test 均零变更）
- 从"叙述式文档"到"决策树 + 模板"——agent 不需要阅读全文即可选对命令
- 核心 3 命令在 SKILL.md 正文中就有完整用法，无需跳转 cli-reference
- cli-reference 保留为"详细手册"角色，但默认只看 Core Commands 段
- investigation-playbook 保留为"完整 worked example"角色，按需参考

## 验证

该任务为纯文档层改动，无需代码测试。功能验证依赖现有 148/148 集成测试基线不变。

文档结构验证：
- SKILL.md: 决策树 → 5 patterns → exploration → guardrails → references（线性阅读流畅）
- cli-reference.md: Core 3 → Supporting → Reference（渐进式展开）
- 所有子命令名、flag、JSON 字段名与实际代码保持一致

## 影响文件

| 文件 | 动作 |
|------|------|
| `.codebuddy/skills/gpu-trace-analysis/SKILL.md` | 重写 |
| `.codebuddy/skills/gpu-trace-analysis/references/cli-reference.md` | 重写 |
| `LocalDocs/GPUTraceReplayAutomation/executions/20260522-R9-skill-optimization.md` | 新增（本文件） |
