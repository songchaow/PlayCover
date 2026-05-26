# R12: 错误恢复与 Agent 自诊断能力

**时间**: 2026-05-26 22:15
**状态**: ✅ 完成

## 概述

R12 目标：让 gpu-trace-analysis skill 在 agent 使用过程中更不容易出错，具体通过三个子项实现：

1. **R12.1**: SKILL.md 新增 "Troubleshooting & Recovery" 章节
2. **R12.2**: wrapper 增加 `diagnose` 子命令
3. **R12.3**: 每个 Pattern 末尾增加 "⚠️ Common Mistakes" 子段

## R12.1: Troubleshooting & Recovery 章节

**位置**: `.codebuddy/skills/gpu-trace-analysis/SKILL.md` → "Troubleshooting & Recovery" 节（在 "Known Blind Spots" 前）

**覆盖 6 种失败模式**:

| # | 失败模式 | 症状 | 关键修复步骤 |
|---|---------|------|-------------|
| 1 | Setup/编译失败 | `setup.sh` exit 非零 | 检查 clang + GPUToolsReplay.framework |
| 2 | Trace 路径不存在或损坏 | FileNotFoundError | 验证路径 + bundle 结构 |
| 3 | Replay 崩溃/超时 | exit 10 / TimeoutError | --bounds 最小测试 → 二分 playto |
| 4 | Export 返回全零 | export_verification.all_zero | memoryless检查 / playto 定位 |
| 5 | Bridge 非零 exit code | BridgeError | 按 exit code 表分类处理 |
| 6 | Python wrapper ImportError | ModuleNotFoundError | 需 Python 3.9+ / 仅 stdlib |

每种给出：症状识别 → 诊断命令 → 修复步骤 → 若无法修复则报告模板。

## R12.2: `diagnose` 子命令

**文件修改**:
- `.codebuddy/skills/gpu-trace-analysis/scripts/gputrace_replay_wrapper.py` — 新增 `ReplayBridge.diagnose()` 方法 + CLI `diagnose` 子命令
- `.codebuddy/skills/gpu-trace-analysis/references/cli-reference.md` — 新增 diagnose 文档

**检查项**（顺序执行，任一失败则停止并报告）:
1. bridge 二进制存在且可执行
2. bridge `help` 能正常返回（签名 + framework 加载正常）
3. trace 路径存在且为 .gputrace bundle
4. replay 基本可达
5. resource 计数
6. bridge 版本 hash（sha256 前 16 位，用于一致性校验）

**输出 JSON schema**:
```json
{
  "bridge_ok": true,
  "bridge_path": "/path/to/bridge",
  "bridge_version_hash": "07eef8c00878c370",
  "bridge_help_ok": true,
  "trace_path": "/path/to/trace.gputrace",
  "trace_exists": true,
  "trace_is_bundle": true,
  "replay_ok": true,
  "replay_elapsed_ms": 11.537,
  "resource_count": 247,
  "total_call_count": 3425,
  "errors": []
}
```

**SKILL.md Setup 节更新**: 建议在 setup 后自动执行一次 diagnose。

## R12.3: Pattern Common Mistakes

在 SKILL.md 的三个关键 Pattern 末尾各添加了 "⚠️ Common Mistakes" 子段：

### Pattern 1 (Black Screen):
- 不检查 `export_verification` 就直接分析全零数据
- 导出错误 resource（depth 误当 color）
- 忘记用 `--playto` 进行二分定位

### Pattern 2 (Wrong Colors):
- 混淆 slot index 与 IR location_index（应用 draw-info）
- 忽略 `value_health_summary` 的 NaN/inf 警报
- 跳过 `uniforms_summary.slot_failed` 检查

### Pattern 5 (Missing/Wrong Texture):
- 对压缩纹理直接用 `getBytes`（必须用 `--export`）
- 忽略 `.meta.json` sidecar（不猜测 dimensions）
- 忘记检查 `compressed` 标志

## 验证

### diagnose 正确路径测试:
```
$ python3 wrapper.py diagnose <LYSK_TRACE> --pretty
→ bridge_ok=true, replay_ok=true, resource_count=247, errors=[]
```

### diagnose 错误路径测试:
```
$ python3 wrapper.py diagnose /tmp/nonexistent.gputrace --pretty
→ trace_exists=false, errors=["trace path not found: ..."], exit=1
```

### Python 语法验证:
```
$ python3 -c "import ast; ast.parse(open('wrapper.py').read())"
→ ✅ Syntax OK
```

## 变更文件清单

| 文件 | 变更类型 | 内容 |
|------|---------|------|
| `.codebuddy/skills/gpu-trace-analysis/SKILL.md` | 修改 | +Setup diagnose 建议 +Troubleshooting 章节 +3 Pattern pitfalls |
| `.codebuddy/skills/gpu-trace-analysis/scripts/gputrace_replay_wrapper.py` | 修改 | +diagnose() 方法 +CLI diagnose 子命令 |
| `.codebuddy/skills/gpu-trace-analysis/references/cli-reference.md` | 修改 | +diagnose 命令文档 +TOC 更新 |
| `LocalDocs/GPUTraceReplayAutomation/executions/20260526-R12-error-recovery-and-self-diagnosis.md` | 新增 | 本文档 |
