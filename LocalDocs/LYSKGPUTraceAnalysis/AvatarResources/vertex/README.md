# Draw 69 (SkinMakeupNew) 顶点数据

> **来源**: LYSK trace `capture_20260518_110050.gputrace`, Draw 69 (RPS 496, `Papegame/SkinMakeupNew`)
> **导出工具**: `vertex-info` R14
> **导出时间**: 2026-06-02
> **Mesh**: 5077 顶点, 27894 索引 (indexed draw, triangles)

## 通道映射（vertex_descriptor 权威数据）

| 通道 | location | format | buffer_index | resource_id | stride | offset | 文件 |
|------|----------|--------|-------------|-------------|--------|--------|------|
| **POSITION** | 0 | Float3 (12B) | 3 | 100 | 40 | 0 | `draw69_POSITION_rid100.bin` |
| **NORMAL** | 1 | Float3 (12B) | 3 | 100 | 40 | 12 | `draw69_NORMAL_rid100.bin` |
| **TANGENT** | 2 | Float4 (16B) | 3 | 100 | 40 | 24 | `draw69_TANGENT_rid100.bin` |
| **TEXCOORD0** | 3 | Float2 (8B) | 4 | 83 | 8 | 0 | `draw69_TEXCOORD0_rid83.bin` |
| **TEXCOORD1** | 4 | Float2 (8B) | 5 | 84 | 8 | 0 | `draw69_TEXCOORD1_rid84.bin` |
| **TEXCOORD2** | 5 | Float2 (8B) | 6 | 85 | 8 | 0 | `draw69_TEXCOORD2_rid85.bin` |
| **TEXCOORD3** | 6 | Float2 (8B) | 7 | 86 | 8 | 0 | `draw69_TEXCOORD3_rid86.bin` |

## 存储布局

### 交错 buffer (rid 100, 203080 bytes)

POSITION / NORMAL / TANGENT 三个通道**交错存储在同一个 buffer** 中：

```
Vertex N layout (40 bytes total):
  [0..11]   POSITION  — float3 (x, y, z)
  [12..23]  NORMAL    — float3 (nx, ny, nz)
  [24..39]  TANGENT   — float4 (tx, ty, tz, tw)  // tw = handedness sign
```

**注意**：`draw69_POSITION_rid100.bin` / `draw69_NORMAL_rid100.bin` / `draw69_TANGENT_rid100.bin` 是**同一份 buffer 文件**（内容完全相同），需要根据各通道的 offset 从中读取对应片段。

### 独立 UV buffers (rid 83–86, 各 40616 bytes)

TEXCOORD0–3 各自独立存储，stride=8（紧凑 Float2），直接按顺序读即可。

## 读取示例

```python
import struct
import numpy as np

# 读取交错 buffer
data = open('draw69_POSITION_rid100.bin', 'rb').read()
n_verts = len(data) // 40  # = 5077

positions = np.zeros((n_verts, 3), dtype=np.float32)
normals   = np.zeros((n_verts, 3), dtype=np.float32)
tangents  = np.zeros((n_verts, 4), dtype=np.float32)

for i in range(n_verts):
    off = i * 40
    positions[i] = struct.unpack_from('<fff', data, off + 0)
    normals[i]   = struct.unpack_from('<fff', data, off + 12)
    tangents[i]  = struct.unpack_from('<ffff', data, off + 24)

# 读取 UV（独立 buffer，紧凑）
uv0 = np.frombuffer(open('draw69_TEXCOORD0_rid83.bin', 'rb').read(),
                    dtype=np.float32).reshape(-1, 2)
```

## 验证数据（前 3 顶点）

```
v[0]: P=(-0.5541, 0.0789, 0.0000)  N=(0.3277,-0.9445,-0.0013)  T=(0.2068, 0.0733,-0.9755,-1.0000)
v[1]: P=(-0.5527, 0.0794, 0.0000)  N=(0.6239,-0.7815,-0.0007)  T=(0.1866, 0.1499,-0.9709,-1.0000)
v[2]: P=(-0.5529, 0.0795, 0.0022)  N=(0.6422,-0.7666,-0.0004)  T=(0.2091, 0.1756,-0.9620,-1.0000)

TEXCOORD0[0] = (0.8803, 0.9864)  — 主 UV
TEXCOORD1[0] = (0.0610, 0.9889)  — lightmap UV
TEXCOORD2[0] = (0.0236, 0.9865)
TEXCOORD3[0] = (0.0547, 0.9660)
```

## 之前错误的映射（已修正）

旧版文件的 resource_id 映射存在两位偏移错误：
- ~~`normal_rid83.bin`~~ → 实际 rid 83 是 TEXCOORD0
- ~~`tangent_rid84.bin`~~ → 实际 rid 84 是 TEXCOORD1
- ~~`texcoord0_rid85.bin`~~ → 实际 rid 85 是 TEXCOORD2

根因：IR metadata 中的函数参数顺序不等于 vertex_descriptor 中的 attribute location 映射。正确做法是通过 `vertex-info` 命令查询 vertex_descriptor，获得 attribute→buffer_index→resource_id 的权威映射。
