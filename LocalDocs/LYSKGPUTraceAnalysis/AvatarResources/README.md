# AvatarResources — RPS 496 (Draw 69) 美术资源导出

> **来源 trace**: `~/Library/Containers/com.papegames.lysk/Data/Documents/Captures/capture_20260518_110050.gputrace`
> **RPS**: 496 (`Papegame/SkinMakeupNew`)
> **Draw**: CB1 / E13 / draw_in_encoder=5 / draw_index_global=69 / call_index=989
> **导出时间**: 2026-05-22

Uniform buffer 数据见 [`../08-rps496-binding-truth.md`](../08-rps496-binding-truth.md)。

**Vertex Shader 分析与 Unity 导入指南见 [`VERTEX_SHADER_ANALYSIS.md`](VERTEX_SHADER_ANALYSIS.md)**。

**验证用 OBJ 文件**: `PL_Head_decoded.obj`（已解码 position + octahedral normals + UV0）。

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

| 文件 | rid | 大小 | slot | IR `arg_name` | stride | 说明 |
|---|---|---|---|---|---|---|
| `vertex/position_rid100.bin` | 100 | 203,080 B | 3 | `POSITION0` (float4) | 40 B | 交错流：前 12B 为 position |
| `vertex/normal_rid83.bin` | 83 | 40,616 B | 4 | `NORMAL0` (half3) | 8 B | float32×2 ∈ [0,1]，2D 编码法线 |
| `vertex/tangent_rid84.bin` | 84 | 40,616 B | 5 | `TANGENT0` (half4) | 8 B | float32×2 ∈ [0,1]，2D 编码切线 |
| `vertex/texcoord0_rid85.bin` | 85 | 40,616 B | 6 | `TEXCOORD0` (float2) | 8 B | UV0 主贴图坐标 ✅ |
| `vertex/texcoord1_rid86.bin` | 86 | 40,616 B | 7 | `TEXCOORD1` (float2) | 8 B | UV1 二次坐标 ✅ |
| `vertex/texcoord2_rid87.bin` | 87 | 81,232 B | 8 | `TEXCOORD2` (float2) | 16 B | 稀疏数据，shader 仅读前 8B |
| `vertex/texcoord3_rid134.bin` | 134 | 203,080 B | 9 | `TEXCOORD3` (float2) | 40 B | 前一帧 position（motion vector） |

### 关键数据特征

- **5,077 顶点** = 40,616 B ÷ 8 B/vtx = index max + 1
- **Slot 3 (rid 100)** 和 **Slot 9 (rid 134)**：40B 交错流。前 16B (float4) 为 position（xyz 为局部坐标，w 为 blend weight ∈ [-1,1]）。Bytes 16-35 为 skinning 附加数据。Bytes 36-39 恒 = -1.0（tangent sign）。Rid 134 是前一帧 skinned position（diff < 0.00026）。
- **Slot 4/5 (rid 83/84)**：float32×2 ∈ [0,1]，Metal 以 Float2 格式交给 shader，自动 pad 为 half3(x,y,0) / half4(x,y,0,1)。经 WTO/OTW 矩阵变换后产生 3D 世界法线/切线。
- **Slot 8 (rid 87)**：16B stride，大部分值为 0，shader 仅读前 8B。

### Metal Vertex Format 与 Shader 类型的关系

IR 中的类型（float4/half3/half4/float2）是 shader 从 vertex descriptor 读到的**转换后**类型，不等于 buffer 存储格式。Metal 硬件在读取时自动做格式转换和 padding。

---

## 3. Textures（美术资产）

| 文件 | rid | IR slot | `arg_name` | 分辨率 | 格式 | mip | 说明 |
|---|---|---|---|---|---|---|---|
| `textures/MainTexRT_rid222.bin` | 222 | frag 2 | `_MainTex` | 512×512 | RGBA8Unorm_sRGB | 1 | 皮肤主贴图 |
| `textures/PL_Head_R_rid197.bin` | 197 | frag 3 | `_SpecularTex` | 512×512 | ASTC | 10 | 高光/粗糙度 |
| `textures/PL_Head_MU_N_rid194.bin` | 194 | frag 4 | `_NormalTex` | 512×512 | RGBA8Unorm | 10 | 法线贴图 |
| `textures/PL_Makeup_Eyebrow_12_D_rid195.bin` | 195 | frag 5 | `_EyebrowTex` | 1024×1024 | ASTC | 11 | 眉毛 |
| `textures/PL_Makeup_Eyeshadow_06_01_D_rid213.bin` | 213 | frag 6 | `_EyeshadowTex` | 512×512 | ASTC | 10 | 眼影 |
| `textures/PL_Makeup_Eyeliner_06_D_rid214.bin` | 214 | frag 7 | `_EyelinerTex` | 512×512 | ASTC | 10 | 眼线 |
| `textures/PL_Makeup_Blush_02_D_rid217.bin` | 217 | frag 8 | `_BlusherTex` | 512×512 | ASTC | 10 | 腮红 |
| `textures/PL_Makeup_Lip_02_D_rid200.bin` | 200 | frag 9 | `_LipTex` | 512×512 | ASTC | 10 | 唇部 |
| `textures/PL_Makeup_Head_ID_UNCOMPRESSED_rid196.bin` | 196 | frag 12 | `_MorphPartTex` | 1024×1024 | RGBA8Unorm | 11 | 面部 ID（morph 分区掩码） |
| `textures/PL_Makeup_Eyelid_07_D_rid193.bin` | 193 | frag 13 | `_EyelidTex` | 512×512 | ASTC | 10 | 眼睑 |

---

## 4. Textures（运行时 Render Target）

前序 pass 产出的中间贴图，被 RPS 496 作为输入采样：

| 文件 | rid | IR slot | `arg_name` | 分辨率 | 格式 | 说明 |
|---|---|---|---|---|---|---|
| `textures/LightIndexMap_rid145.bin` | 145 | frag 1 | `_LightIndexMap` | 128×128 | RGBA8Unorm | Cluster lighting 索引（compute） |
| `textures/SSSSkinTexture_rid232.bin` | 232 | frag 14 | `_SSSSkinTexture` | 583×835 | RG11B10Float | SSS vertical-blur (E12) |
| `textures/ScreenShadowTexture_rid236.bin` | 236 | frag 15 | `_ScreenShadowTexture` | 583×835 | RGBA8Unorm | 屏幕空间阴影 (E9) |

---

## 5. 未导出的资源

| rid | label | IR slot | 说明 | 原因 |
|---|---|---|---|---|
| 142 | `UnityBlackCube` | frag 0 (`unity_SpecCube0`) | 1×1 黑色 cubemap | 占位贴图 |
| 141 | `UnityBlack` | frag 10, 11 | 4×4 黑色 2D | 占位（无装饰） |
| 171 | `fx_normal_wenli04` | vtx tex 0 | 256×256 | Shader 不采样，sticky 残留 |

---

## 6. 读取指南

### Index Buffer
```python
import numpy as np
indices = np.fromfile("index/index_buffer_rid88.bin", dtype=np.uint16)
# shape = (27894,), 每 3 个 = 1 三角形 → 9298 三角形
```

### Vertex Buffers
```python
import numpy as np

# Position (40B stride, 取前 float3)
pos_raw = np.fromfile("vertex/position_rid100.bin", dtype=np.uint8).reshape(5077, 40)
positions = np.frombuffer(pos_raw[:, :12].tobytes(), dtype=np.float32).reshape(-1, 3)

# Normal / Tangent (float32×2, 2D 编码 — 不建议直接作为标准法线使用)
normal_2d = np.fromfile("vertex/normal_rid83.bin", dtype=np.float32).reshape(-1, 2)
tangent_2d = np.fromfile("vertex/tangent_rid84.bin", dtype=np.float32).reshape(-1, 2)

# UV0 / UV1
uv0 = np.fromfile("vertex/texcoord0_rid85.bin", dtype=np.float32).reshape(-1, 2)
uv1 = np.fromfile("vertex/texcoord1_rid86.bin", dtype=np.float32).reshape(-1, 2)

# UV2 (16B stride, 仅前 8B)
uv2_raw = np.fromfile("vertex/texcoord2_rid87.bin", dtype=np.uint8).reshape(5077, 16)
uv2 = np.frombuffer(uv2_raw[:, :8].tobytes(), dtype=np.float32).reshape(-1, 2)
```

### Textures (RGBA8)
```python
# MainTexRT: 512×512 RGBA8
tex = np.fromfile("textures/MainTexRT_rid222.bin", dtype=np.uint8).reshape(512, 512, 4)
```

### Textures (ASTC)
ASTC 贴图（pixelFormat 186/204）存储 GPU 压缩数据，导出的 `.bin` 包含所有 mip level 拼接（mip 0 起始）。解压需 ASTC 解码器（如 `astcenc`）。

---

## 7. 数据完整性

| 资源类型 | 文件数 | 总大小 |
|---|---|---|
| Index | 1 | 55,788 B |
| Vertex | 7 | 649,856 B |
| Texture (美术) | 10 | 17,825,792 B |
| Texture (RT) | 3 | 3,959,976 B |
| **总计** | **21** | **~21.5 MB** |
