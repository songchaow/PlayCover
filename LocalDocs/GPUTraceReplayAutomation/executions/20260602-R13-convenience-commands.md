# R13: Convenience Commands — find-draws, draw-info, dump-uniforms --by-name

**执行时间**: 2026-06-02 01:04–01:30
**目标**: 实现 cli-reference.md 文档中描述但未实现的三个核心便捷命令，使 uniform 查询"一条命令搞定"。

## 问题背景

cli-reference.md 宣称 "80%+ 调查只需 3 条命令"：
1. `find-draws --by-label` — 按 shader 名搜 draw
2. `draw-info` — 合并 IR + bindings + uniforms 视图
3. `dump-uniforms --by-name` — 按字段名直接查值

但实际 CLI 只有 11 个子命令，这 3 个核心命令的 argparse 入口**未注册**。

## 实现内容

### 1. `find-draws` CLI 子命令
- `--by-label <SUBSTR>` / `--by-shader-name <SUBSTR>` — 大小写不敏感子串匹配 rps_label
- `--show-first` — 对首个命中展开 shader-of-drawcall
- `--with-ir` / `--with-uniforms` — 与 --show-first 联用
- 内部复用 `frame_list()` 一次调用

### 2. `draw-info` CLI 子命令
- 合并 shader-of-drawcall + with-ir + with-uniforms
- 额外注入 `size_check` 和顶层 `value_health_summary`
- `--no-uniforms` 可关闭 uniform 解码

### 3. `dump-uniforms --by-name`
- **无需指定 bind_slot**（argparse 中 bind_slot 改为 `nargs='?'`）
- 自动遍历该 draw 的所有 buffer slot
- 匹配 binding_name 或 decoded 字段名（大小写不敏感子串）
- `--field <SUBSTR>` 可进一步过滤字段
- 匹配结果不存在时 exit 11

### 4. 内部重构
- 抽取 `_shader_of_drawcall_to_payload()` 消除 CLI handler 与新方法间的序列化重复
- 新方法放在 `# R13:` 注释区块，位于 `dump_uniforms()` 和 `diagnose()` 之间

## 测试验证（LYSK trace）

| 测试 | 命令 | 结果 |
|------|------|------|
| A: 按字段名查值 | `dump-uniforms 69 --by-name "_CharShadowIntensity"` | ✅ `value=1, half, slot=4, Character_Param` |
| B: binding名+field过滤 | `dump-uniforms 69 --by-name "Character_Param" --field "_CharMainLightColor"` | ✅ `value=[2.51, 2.26, 2.43, 3.14], half4` |
| C: find-draws 搜索 | `find-draws --by-label "SkinMakeupNew"` | ✅ 14 draws found |
| D: draw-info 合并视图 | `draw-info 69` | ✅ 7 slots OK, NaN=0, has_ir=True |
| E: 不存在字段 | `dump-uniforms 69 --by-name "NonExistent"` | ✅ match_count=0, exit 11 |
| F: 回归 — 老方式 by-slot | `dump-uniforms 69 4 --stage fragment` | ✅ 与改动前一致 |
| G: 回归 — shader-of-drawcall | `shader-of-drawcall 69 --with-uniforms` | ✅ 7 slots OK |

## 使用体验对比

### 改进前（查 `_CharShadowIntensity`）
```
1. shader-of-drawcall 69 --with-uniforms → 大 JSON
2. 人工/脚本从 7 个 slot 的 decoded 字典里搜索字段名
```
需要 agent 解析大量 JSON，容易出错。

### 改进后
```bash
dump-uniforms "$TRACE" 69 --by-name "_CharShadowIntensity"
# → {"match_count":1, "matches":[{"bind_slot":4, "binding_name":"Character_Param", 
#    "fields":{"_CharShadowIntensity":{"offset":50,"data_type":"half","value":1}}}]}
```
一条命令，结果精确，不会出错。

## 文件变更

| 文件 | 变更 |
|------|------|
| `.codebuddy/skills/gpu-trace-analysis/scripts/gputrace_replay_wrapper.py` | +3 module methods, +2 argparse subparsers, dump-uniforms bind_slot 改 optional, --by-name/--field 参数 |
| `.codebuddy/skills/gpu-trace-analysis/SKILL.md` | 决策树更新 --by-name 语法 |
| `.codebuddy/skills/gpu-trace-analysis/references/cli-reference.md` | find-draws/draw-info/dump-uniforms 文档与实际一致 |
| `LocalDocs/GPUTraceReplayAutomation/executions/20260602-R13-convenience-commands.md` | 本文件 |
