# R14: vertex-info — 一条命令查询与导出顶点数据通道

**执行时间**: 2026-06-02 19:52–20:20
**目标**: 将顶点数据的通道查询和导出操作固化到代码中，消除 agent 多步骤手动解析 vertex descriptor 的心智负担。

## 问题背景

之前提取 draw call 的顶点数据（如 UV/Position）需要 agent 执行多个步骤：

1. `frame-list` 获取 draw 的 `rps_key` 和 vertex binding table（哪些 buffer 被绑定到哪个 slot）
2. `pipeline` 获取该 RPS 的 `vertex_descriptor`（attribute location → buffer_index + offset + format）
3. 手动交叉对照，推算出每个语义通道（POSITION/NORMAL/TEXCOORD0）对应的 resource_id
4. `replay --export <rid> <path>` 导出对应 buffer
5. 根据 stride/offset 手动计算如何从二进制中提取该通道的数据

这个流程容易出错（如之前的 buffer slot 偏移两位事件），且 agent 每次都要从头推理整个映射链。

## 设计原则

**渐进披露**：
- 默认只展示最关键信息（通道名、格式、resource_id）
- 附带 hints 告诉用户如何进一步操作（导出特定通道）
- `--export-channel` 进一步展开：包含导出路径 + python 读取代码片段

**防呆**：
- 所有步骤内部完成，用户只需提供 draw_index
- channel 名不存在时，返回所有可用 channel 列表
- 自动处理交错/非交错 buffer 的区别

## 实现内容

### 1. `VERTEX_FORMAT_TABLE` 模块级常量

MTLVertexFormat enum → (name, byte_size, component_count) 查找表，覆盖所有 Metal 支持的顶点格式（54 种）。

### 2. `vertex_info()` 方法

核心逻辑：
1. `frame_list()` → 找目标 draw → 获取 rps_key + vertex buffer binding map
2. `pipeline()` → 找目标 RPS → 获取 vertex_descriptor (attributes + layouts)
3. 合并产出通道表：semantic_name, format, resource_id, buffer_index, offset, stride
4. 生成 hints（如何导出各通道）
5. 如指定 `--export-channel`，自动调用 `replay --export` 导出并附带解读

### 3. `_export_vertex_channel()` 内部方法

- 按语义名（POSITION/TEXCOORD0）或 `location:N` 匹配通道
- 调用 `replay --export` 导出 buffer 原始字节
- 计算数据解读参数（stride, offset, vertex count）
- 生成 Python 代码片段用于读取数据

### 4. CLI 子命令注册

```bash
python3 "$WRAPPER" vertex-info <trace> <draw_index> \
    [--export-channel <SEMANTIC|location:N>] \
    [--output-dir DIR]
```

## 测试验证（LYSK trace, Draw 69 = SkinMakeupNew）

| 测试 | 操作 | 结果 |
|------|------|------|
| A: 查询所有通道 | `vertex-info 69` | ✅ 7 channels: POSITION(Float3), NORMAL(Float3), TANGENT(Float4), TEXCOORD0-3(Float2) |
| B: 导出 TEXCOORD0 | `vertex-info 69 --export-channel TEXCOORD0` | ✅ rid 83, 40616 bytes, vertex[0]=(0.8803, 0.9864) 匹配 Xcode |
| C: 导出 POSITION | `vertex-info 69 --export-channel POSITION` | ✅ rid 100, 203080 bytes (interleaved stride=40), 数据合理 |
| D: 无效通道 | `vertex-info 69 --export-channel INVALID` | ✅ 返回 available_channels 列表 |
| E: location 语法 | `vertex-info 69 --export-channel "location:3"` | ✅ 正确定位到 TEXCOORD0 |

### 数据验证

TEXCOORD0 (rid 83):
- 总字节数 40616 ÷ stride 8 = 5077 顶点 ✓
- vertex[0] UV = (0.8803, 0.9864) — 与 Xcode GPU Debugger 中的 (0.880, 0.986) 完美匹配 ✓

POSITION (rid 100, interleaved with NORMAL/TANGENT):
- 总字节数 203080 ÷ stride 40 = 5077 顶点 ✓
- vertex[0] pos = (-0.5541, 0.0789, 0.0000) — 合理的模型空间坐标 ✓
- vertex[0] normal = (0.3277, -0.9445, -0.0013) — 归一化 ✓

## 使用体验对比

### 改进前（查询 TEXCOORD0 通道数据）
```bash
# 1. frame-list 获取 draw 69 的 bindings
python3 $WRAPPER frame-list $TRACE | jq '...'
# 2. pipeline 获取 vertex_descriptor
python3 $WRAPPER pipeline $TRACE | jq '...'
# 3. 手动交叉对照 attribute location=3 → buffer_index=4 → resource_id=83
# 4. 导出 buffer
python3 $WRAPPER replay $TRACE --export 83 /tmp/uv.bin
# 5. 手动计算 stride=8, offset=0 来读取数据
python3 -c "import struct; data=open('/tmp/uv.bin','rb').read(); ..."
```
需要 5 步，容易出错（如搞混 buffer_index 和 location）。

### 改进后
```bash
python3 $WRAPPER vertex-info $TRACE 69 --export-channel TEXCOORD0 --output-dir /tmp/vtx
# → 一条命令完成所有步骤，输出包含完整解读 + python 代码片段
```
1 步完成，零出错风险。

## 文件变更

| 文件 | 变更 |
|------|------|
| `.codebuddy/skills/gpu-trace-analysis/scripts/gputrace_replay_wrapper.py` | +VERTEX_FORMAT_TABLE, +vertex_info(), +_export_vertex_channel(), +CLI 子命令注册 |
| `.codebuddy/skills/gpu-trace-analysis/SKILL.md` | 决策树新增 vertex-info 入口，核心命令表 3→4 |
| `.codebuddy/skills/gpu-trace-analysis/references/cli-reference.md` | 新增 vertex-info 完整文档，重编号 Supporting Commands |
| `LocalDocs/GPUTraceReplayAutomation/README.md` | 完成度/能力表/TODO 更新 |
| `LocalDocs/GPUTraceReplayAutomation/executions/20260602-R14-vertex-info.md` | 本文件 |
