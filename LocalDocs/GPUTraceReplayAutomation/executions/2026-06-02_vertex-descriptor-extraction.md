# Bridge 改进：提取 MTLVertexDescriptor（attribute→buffer 映射）

> **日期**: 2026-06-02
> **触发**: 在导出 RPS 496 (SkinMakeupNew) 的顶点数据时，因缺少 vertex descriptor 信息，将 buffer slot→attribute 的映射搞错（偏移了两位），导致 UV 数据被错误标注。
> **修改文件**: `.codebuddy/skills/gpu-trace-analysis/scripts/gputrace_replay_bridge.m`

---

## 1. 问题背景

之前导出 Draw 69 (SkinMakeupNew) 的 vertex buffer 时，仅依据 IR metadata 中的函数参数顺序推断 buffer 映射：

```
slot 3 → POSITION0
slot 4 → NORMAL0     ← 实际是 TEXCOORD0！
slot 5 → TANGENT0    ← 实际是 TEXCOORD1！
slot 6 → TEXCOORD0   ← 实际是 TEXCOORD2！
slot 7 → TEXCOORD1   ← 实际是 TEXCOORD3！
```

这个推断是错误的。Metal 中 vertex shader 的 `[[attribute(N)]]` location 通过 `MTLVertexDescriptor` 映射到具体的 buffer slot + offset，而不是简单地按参数顺序对应。

实际的 vertex descriptor（通过 Xcode GPU Debugger 确认）：

| attribute location | buffer_index | offset | 含义 |
|---|---|---|---|
| 0 (POSITION0) | 3 | 0 | rid 100, 40B stride |
| 1 (NORMAL0) | 3 | 12 | rid 100 内部交错 |
| 2 (TANGENT0) | 3 | 24 | rid 100 内部交错 |
| **3 (TEXCOORD0)** | **4** | 0 | **rid 83**, 8B stride |
| 4 (TEXCOORD1) | 5 | 0 | rid 84, 8B stride |
| 5 (TEXCOORD2) | 6 | 0 | rid 85, 8B stride |
| 6 (TEXCOORD3) | 7 | 0 | rid 86, 8B stride |

关键发现：POSITION、NORMAL、TANGENT 全部交错存储在 rid 100 (40B stride) 中，而 UV0~UV3 分别独立存储在 rid 83~86 中。

---

## 2. 根因

Bridge 的 `pipeline` 子命令在 swizzle 捕获 `MTLRenderPipelineDescriptor` 时，提取了 vertex/fragment function、color attachments、depth/stencil format，**但没有提取 `vertexDescriptor` 属性**。因此无法获得 attribute location → buffer slot 的权威映射。

---

## 3. 修改内容

### 3.1 新增数据结构

```c
typedef struct {
    int        location;     // attribute index (vertex shader location)
    NSUInteger format;       // MTLVertexFormat enum
    NSUInteger offset;       // byte offset within the buffer
    NSUInteger buffer_index; // which vertex buffer slot this reads from
} RPSVertexAttributeInfo;

typedef struct {
    int        index;        // buffer layout index
    NSUInteger stride;
    NSUInteger step_function; // MTLVertexStepFunction
    NSUInteger step_rate;
} RPSVertexLayoutInfo;
```

在 `RPSCaptureEntry` 中新增：

```c
int   vtx_attr_count;
RPSVertexAttributeInfo vtx_attrs[RPS_MAX_VTX_ATTR];   // max 31
int   vtx_layout_count;
RPSVertexLayoutInfo    vtx_layouts[RPS_MAX_VTX_LAYOUT]; // max 31
```

### 3.2 提取逻辑 (`rps_capture_descriptor`)

在 `rasterSampleCount` 之后新增：

1. 获取 `desc.vertexDescriptor`
2. 遍历 `vertexDescriptor.attributes[0..30]`，跳过 `format == MTLVertexFormatInvalid (0)` 的空位
3. 对每个有效 attribute 记录 `location`（循环变量 i）、`format`、`offset`、`bufferIndex`
4. 遍历 `vertexDescriptor.layouts[0..30]`，跳过 `stride == 0` 的空位
5. 对每个有效 layout 记录 `index`、`stride`、`stepFunction`、`stepRate`

### 3.3 JSON 输出 (`pipeline` 子命令)

在 `raster_sample_count` 之后输出 `vertex_descriptor` 对象：

```json
{
  "vertex_descriptor": {
    "attributes": [
      {"location": 0, "format": 30, "offset": 0, "buffer_index": 3},
      {"location": 3, "format": 29, "offset": 0, "buffer_index": 4},
      ...
    ],
    "layouts": [
      {"index": 3, "stride": 40, "step_function": 1, "step_rate": 1},
      {"index": 4, "stride": 8, "step_function": 1, "step_rate": 1},
      ...
    ]
  }
}
```

---

## 4. 验证结果

对 LYSK trace 的 RPS 496 运行 `pipeline` 子命令：

```
Attributes:
  location=0: buffer_index=3, offset=0,  format=30  (Float4)
  location=1: buffer_index=3, offset=12, format=30  (Float4? — 实为 float3 pad)
  location=2: buffer_index=3, offset=24, format=31  (Float4)
  location=3: buffer_index=4, offset=0,  format=29  (Float2) ← TEXCOORD0 = slot 4 = rid 83
  location=4: buffer_index=5, offset=0,  format=29  (Float2) ← TEXCOORD1 = slot 5 = rid 84
  location=5: buffer_index=6, offset=0,  format=29  (Float2) ← TEXCOORD2 = slot 6 = rid 85
  location=6: buffer_index=7, offset=0,  format=29  (Float2) ← TEXCOORD3 = slot 7 = rid 86

Layouts:
  buffer[3]: stride=40, step_fn=1, step_rate=1
  buffer[4]: stride=8,  step_fn=1, step_rate=1
  buffer[5]: stride=8,  step_fn=1, step_rate=1
  buffer[6]: stride=8,  step_fn=1, step_rate=1
  buffer[7]: stride=8,  step_fn=1, step_rate=1
```

与 Xcode GPU Debugger 中 TEXCOORD0 显示的值 (0.880, 0.986) 完美匹配 rid 83 的数据。

---

## 5. 使用方法

以后导出顶点数据时的正确流程：

```bash
# 1. 获取 vertex descriptor（权威 attribute→buffer 映射）
$BRIDGE pipeline "$TRACE" /tmp/pipelines | \
  python3 -c "import json,sys; [print(json.dumps(r['vertex_descriptor'],indent=2)) \
    for r in json.load(sys.stdin)['render_pipeline_states'] if r['key']==TARGET_RPS]"

# 2. 结合 frame-list 的 binding 表确定每个 attribute 的实际 resource_id
#    attribute[location=N].buffer_index → setVertexBuffer slot → resource_id

# 3. 结合 IR metadata 确定 attribute 的语义名
#    IR: {i32 PARAM_IDX, "air.vertex_input", "air.location_index", i32 LOCATION, ...}
```

---

## 6. MTLVertexFormat 常见值参考

| 值 | 名称 | 说明 |
|---|---|---|
| 28 | Float | 1×float32 |
| 29 | Float2 | 2×float32 |
| 30 | Float3 | 3×float32 |
| 31 | Float4 | 4×float32 |
| 25 | Half2 | 2×float16 |
| 26 | Half3 | 3×float16 |
| 27 | Half4 | 4×float16 |
