# AvatarResources — RPS 496 (Draw 69) 美术资源导出

> **来源 trace**: `~/Library/Containers/com.papegames.lysk/Data/Documents/Captures/capture_20260518_110050.gputrace`
> **RPS**: 496 (`Papegame/SkinMakeupNew`)
> **Draw**: CB1 / E13 / draw_in_encoder=5 / draw_index_global=69 / call_index=989
> **导出时间**: 2026-05-22

Uniform buffer 数据见 [`../08-rps496-binding-truth.md`](../08-rps496-binding-truth.md)。

---

## 1. Index Buffer

| 文件 | resource_id | 大小 | 格式 | 说明 |
|---|---|---|---|---|
| `index/index_buffer_rid88.bin` | 88 | 55,788 B | uint16 × 27894 | PL_Head 三角面索引 |

- **index_count** = 27894，**primitive_type** = triangle
- 每个 index 为 2 字节 little-endian unsigned short

---

## 2. Vertex Buffers

Draw 69 使用 7 个 vertex attribute stream（Metal vertex buffer slot 3..9），共 **5,077 个顶点**（由 index buffer max_index=5076 确认）。

| 文件 | resource_id | 大小 | slot | IR `arg_name` | stride | 说明 |
|---|---|---|---|---|---|---|
| `vertex/position_rid100.bin` | 100 | 203,080 B | 3 | `POSITION0` (float4) | 40 B | 交错顶点流（见下方分析） |
| `vertex/normal_rid83.bin` | 83 | 40,616 B | 4 | `NORMAL0` (half3) | 8 B | 实测为 float2 [0,1] 范围 — 可能是 packed 法线或 UV |
| `vertex/tangent_rid84.bin` | 84 | 40,616 B | 5 | `TANGENT0` (half4) | 8 B | 实测为 float2 [0,1] 范围 |
| `vertex/texcoord0_rid85.bin` | 85 | 40,616 B | 6 | `TEXCOORD0` (float2) | 8 B | UV0 主贴图坐标 [0,1] ✓ |
| `vertex/texcoord1_rid86.bin` | 86 | 40,616 B | 7 | `TEXCOORD1` (float2) | 8 B | UV1 二次坐标 [0,1] ✓ |
| `vertex/texcoord2_rid87.bin` | 87 | 81,232 B | 8 | `TEXCOORD2` (float2) | 16 B | 稀疏数据（多数为 0） |
| `vertex/texcoord3_rid134.bin` | 134 | 203,080 B | 9 | `TEXCOORD3` (float2) | 40 B | 交错顶点流（结构同 rid 100） |

### 关键数据观察

- **5,077 顶点** = 40,616 B ÷ 8 B/vtx（slot 4-7 的 buffer）= index max + 1
- **slot 3 (rid 100)** 和 **slot 9 (rid 134)**：均为 203,080 B = 5,077 × 40 B/vtx。这是 **interleaved vertex stream**，40 字节包含多个属性。前 16 字节 (float4) 的 xyz 分量为 [-0.6, 0.6] 范围的局部空间坐标，w 分量在 [0,1]。后 24 字节包含额外数据（可能是 skinning 权重 / bone indices / 上一帧位置用于 motion vector）。Rid 134 的数据与 rid 100 几乎相同（前一帧的 skinned position，用于 motion vector 计算）。
- **slot 4-7 (rid 83-86)**：均为 float2 ∈ [0, 1]。IR 声明的 `NORMAL0` / `TANGENT0` 类型通过 Metal vertex descriptor 的 `format` 字段来做硬件格式转换（如 Float2 → Half3），或者引擎通过 UV channel 传递 packed 数据供 shader 后续解码。
- **slot 8 (rid 87)**：16 B/vtx，绝大多数值为 0，仅少数顶点有非零数据（用途待确认，可能是 morph/blend shape 权重）。

### 实际 Vertex Descriptor 的格式

精确的 per-attribute format、offset、bufferIndex 定义在 RPS 496 的 `MTLVertexDescriptor` 中。本次导出的是 **raw buffer 内容**，需要配合 RPS vertex descriptor 来正确解读每个属性在 buffer 内的确切位置和格式。

> **注意**：IR 中的类型（float4/half3/half4/float2）是 shader 从 vertex descriptor 读到的**转换后**类型，不一定等于 buffer 中的存储格式。

---

## 3. Textures（美术资产贴图）

| 文件 | resource_id | IR slot | `arg_name` | 分辨率 | 像素格式 | mip 层级 | 说明 |
|---|---|---|---|---|---|---|---|
| `textures/MainTexRT_rid222.bin` | 222 | frag 2 | `_MainTex` | 512×512 | RGBA8Unorm_sRGB | 1 | 皮肤主贴图（RT blit 结果） |
| `textures/PL_Head_R_rid197.bin` | 197 | frag 3 | `_SpecularTex` | 512×512 | ASTC (format 204) | 10 | 高光/粗糙度贴图 |
| `textures/PL_Head_MU_N_rid194.bin` | 194 | frag 4 | `_NormalTex` | 512×512 | RGBA8Unorm | 10 | 法线贴图 |
| `textures/PL_Makeup_Eyebrow_12_D_rid195.bin` | 195 | frag 5 | `_EyebrowTex` | 1024×1024 | ASTC (format 186) | 11 | 眉毛贴图 |
| `textures/PL_Makeup_Eyeshadow_06_01_D_rid213.bin` | 213 | frag 6 | `_EyeshadowTex` | 512×512 | ASTC (format 186) | 10 | 眼影贴图 |
| `textures/PL_Makeup_Eyeliner_06_D_rid214.bin` | 214 | frag 7 | `_EyelinerTex` | 512×512 | ASTC (format 186) | 10 | 眼线贴图 |
| `textures/PL_Makeup_Blush_02_D_rid217.bin` | 217 | frag 8 | `_BlusherTex` | 512×512 | ASTC (format 186) | 10 | 腮红贴图 |
| `textures/PL_Makeup_Lip_02_D_rid200.bin` | 200 | frag 9 | `_LipTex` | 512×512 | ASTC (format 186) | 10 | 唇部贴图 |
| `textures/PL_Makeup_Head_ID_UNCOMPRESSED_rid196.bin` | 196 | frag 12 | `_MorphPartTex` | 1024×1024 | RGBA8Unorm | 11 | 面部 ID 贴图（morph 分区掩码） |
| `textures/PL_Makeup_Eyelid_07_D_rid193.bin` | 193 | frag 13 | `_EyelidTex` | 512×512 | ASTC (format 204) | 10 | 眼睑贴图 |

---

## 4. Textures（运行时 Render Target）

这些是前序 pass 产出的中间贴图，被 RPS 496 作为输入采样：

| 文件 | resource_id | IR slot | `arg_name` | 分辨率 | 像素格式 | 说明 |
|---|---|---|---|---|---|---|
| `textures/LightIndexMap_rid145.bin` | 145 | frag 1 | `_LightIndexMap` | 128×128 | RGBA8Unorm | Cluster lighting 索引贴图（compute pass 写入） |
| `textures/SSSSkinTexture_rid232.bin` | 232 | frag 14 | `_SSSSkinTexture` | 583×835 | RG11B10Float | SSS vertical-blur 输出 (E12) |
| `textures/ScreenShadowTexture_rid236.bin` | 236 | frag 15 | `_ScreenShadowTexture` | 583×835 | RGBA8Unorm | 屏幕空间阴影 (E9) |

---

## 5. 未导出的资源（占位 / 无效绑定）

| resource_id | label | IR slot | 说明 | 不导出原因 |
|---|---|---|---|---|
| 142 | `UnityBlackCube` | frag 0 (`unity_SpecCube0`) | 1×1 黑色 cubemap | 占位贴图，无美术内容 |
| 141 | `UnityBlack` | frag 10, 11 (`_DecorateTex`, `_Decorate2Tex`) | 4×4 黑色 2D | 占位贴图，本帧无装饰 |
| 171 | `fx_normal_wenli04` | vtx tex 0 | 256×256 | Vertex IR 不采样，sticky 残留 |

---

## 6. 读取指南

### Index Buffer
```python
import numpy as np
indices = np.fromfile("index/index_buffer_rid88.bin", dtype=np.uint16)
# indices.shape = (27894,), 每 3 个组成一个三角形 → 9298 三角形
```

### Vertex Buffers
```python
import numpy as np

# Position stream (interleaved 40 B/vtx): first float4 = position
pos_raw = np.fromfile("vertex/position_rid100.bin", dtype=np.uint8).reshape(5077, 40)
positions = np.frombuffer(pos_raw[:, :16].tobytes(), dtype=np.float32).reshape(-1, 4)
# positions[:,0:3] = xyz local-space coords, positions[:,3] = w (packed data)

# Slot 4-7 buffers: each is 5077 × float2
normal_data = np.fromfile("vertex/normal_rid83.bin", dtype=np.float32).reshape(-1, 2)   # slot 4
tangent_data = np.fromfile("vertex/tangent_rid84.bin", dtype=np.float32).reshape(-1, 2) # slot 5
uv0 = np.fromfile("vertex/texcoord0_rid85.bin", dtype=np.float32).reshape(-1, 2)        # slot 6
uv1 = np.fromfile("vertex/texcoord1_rid86.bin", dtype=np.float32).reshape(-1, 2)        # slot 7

# UV2 (slot 8): 16 B/vtx
uv2_raw = np.fromfile("vertex/texcoord2_rid87.bin", dtype=np.float32).reshape(-1, 4)
```

### Textures (uncompressed RGBA8)
```python
import numpy as np
# MainTexRT: 512×512 RGBA8Unorm_sRGB (mip 0 only)
tex = np.fromfile("textures/MainTexRT_rid222.bin", dtype=np.uint8).reshape(512, 512, 4)
```

### Textures (ASTC compressed)
ASTC 格式的贴图（pixelFormat 186/204）存储的是 GPU 压缩数据。导出的 `.bin` 包含 mip chain 的**所有 mip level** 拼接在一起（从 mip 0 开始）。解压需要 ASTC 解码器（如 `astcenc`）。

---

## 7. 数据完整性校验

| 资源类型 | 文件数 | 总大小 |
|---|---|---|
| Index | 1 | 55,788 B |
| Vertex | 7 | 649,856 B |
| Texture (美术) | 10 | 17,825,792 B |
| Texture (RT) | 3 | 3,959,976 B |
| **总计** | **21** | **22,491,412 B (~21.5 MB)** |
