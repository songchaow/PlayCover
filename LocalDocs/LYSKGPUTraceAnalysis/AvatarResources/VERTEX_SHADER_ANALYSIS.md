# Vertex Shader 分析与 Unity 导入指南

> **目标**：分析 RPS 496 (SkinMakeupNew) vertex shader 的输入/输出逻辑，确定每个 vertex buffer 的精确解码方式，指导 Unity 引擎还原。
>
> **Vertex Shader**：`library_408` / `function_key=409` / `xlatMtlMain`
> **IR 来源**：`LocalDocs/OfflineSourceRecovery/gputracebinaryreplacement/SkinMakeupNew_vertex.ll`
>
> **关键结论**：Normal/Tangent buffer 存储 **float32×2 ∈ [0,1]**，Metal vertex format 为 `Float2`，GPU 自动 pad 到 `half3(x,y,0)` / `half4(x,y,0,1)`。Vertex shader 用 `WorldToObject` / `ObjectToWorld^T` 的非平凡旋转将 2D 输入投射为 3D 法线/切线。对于 Unity 导入，**不需要 octahedral/hemisphere decode**——直接用 `RecalculateNormals()` + `RecalculateTangents()` 重建标准 TBN。

---

## 1. Vertex Shader 功能总结

RPS 496 的 vertex shader 不含 skinning 或 morph 计算（已在 CPU/Compute 端完成），仅执行：

1. **Position → Clip Space**：`positionOS.xyz` × `ObjectToWorld` → `positionWS` → 减 `_WorldSpaceRelativeCameraPos` → × `_ViewProjMatrix` → `positionCS`
2. **Normal → World Space**：`normalOS(x,y,0)` × `WorldToObject_3x3` → normalize → `worldNormal`
3. **Tangent → World Space**：`tangentOS(x,y,0)` × `ObjectToWorld_3x3^T` → normalize → `worldTangent`
4. **Bitangent**：`cross(worldNormal, worldTangent) × tangentOS.w(=1.0) × unity_WorldTransformParams.w(=1.0)`
5. **UV 直通**：`TEXCOORD0~3` pack 到 output varying
6. **ViewDir**：`_WorldSpaceCameraPos - positionWS`，分量嵌入 TBN 各行的 w 分量

---

## 2. ObjectToWorld 矩阵

```
ObjectToWorld 3×3 (from trace cbuffer):
  Row 0: (  0.000, -1.000,  0.000 )   ← OS X → World -Y
  Row 1: (  0.603,  0.000,  0.798 )   ← OS Y → World XZ (~53°)
  Row 2: ( -0.798,  0.000,  0.603 )   ← OS Z → World XZ
  Row 3: ( -0.003,  0.950, -0.005, 1) ← Translation

WorldToObject 3×3:
  Row 0: (  0.000,  0.603, -0.798 )
  Row 1: ( -1.000,  0.000,  0.000 )
  Row 2: (  0.000,  0.798,  0.603 )
  Row 3: (  0.950,  0.006,  0.000, 1)

Determinant = 1.0 (pure rotation, no scale)
unity_WorldTransformParams.w = 1.0
OTW^T ≡ WTO (orthogonal matrix property)
```

OS Y 轴映射到 world XZ 平面（角色朝向），OS X 轴映射到 world -Y（向下）。由于矩阵为纯旋转，`OTW^T = WTO`，因此 normal 变换（`WTO * n`）和 tangent 变换（`OTW^T * t`）使用的是同一矩阵。

---

## 3. Vertex Buffer 解码方案

### 3.1 Index Buffer (rid 88)

| 项目 | 值 |
|---|---|
| 文件 | `index/index_buffer_rid88.bin` |
| 格式 | `uint16` little-endian |
| 元素数 | 27,894 (= 9,298 三角形) |
| Max index | 5,076 |

**Unity**：`mesh.SetIndices(indices, MeshTopology.Triangles, 0)`

---

### 3.2 Slot 3: POSITION0 (rid 100) — 40B 交错流

| 项目 | 值 |
|---|---|
| 文件 | `vertex/position_rid100.bin` |
| Stride | 40 B/vtx |
| 顶点数 | 5,077 |
| IR 类型 | `float4` (POSITION0, location 0) |

**数据布局**（每 40 字节）：

| Offset | Size | 含义 | Shader 读取 |
|--------|------|------|-------------|
| 0 | 16 B | Position float4 (仅用 XYZ) | ✅ |
| 16 | 20 B | Skinning 相关数据 | ❌ |
| 36 | 4 B | Tangent sign，恒 = **-1.0** | ❌ |

- `xyz`: Object-space 坐标，X∈[-0.72, -0.49], Y∈[-0.06, 0.11], Z∈[-0.08, 0.08]
- `w`: 连续 blend weight ∈ [-1, 1]，约 4713 个 unique 值，本 shader 不读取

**Unity**：只取前 12 字节 (float3)。

---

### 3.3 Slot 4: NORMAL0 (rid 83) — 2D 法线

| 项目 | 值 |
|---|---|
| 文件 | `vertex/normal_rid83.bin` |
| Stride | 8 B/vtx |
| Buffer 格式 | **float32×2**，值域 [0.007, 0.997] |
| Metal Vertex Format | `Float2` (MTLVertexFormatFloat2) |
| Shader 接收类型 | `half3` → GPU delivers `half3(x, y, 0)` |

**工作原理**：

```
worldNormal = normalize( WTO_3x3 × normalOS(x,y,0) )
```

WTO 含非平凡旋转，2D 输入经矩阵投射后产生有效的 3D 世界法线。这是 **bandwidth 优化**：8B（2×float32）替代 12B（3×float32），靠刚性变换矩阵隐式补全第三维。

**Unity**：**不直接使用**。应 `mesh.RecalculateNormals()` 重建。

---

### 3.4 Slot 5: TANGENT0 (rid 84) — 2D 切线

| 项目 | 值 |
|---|---|
| 文件 | `vertex/tangent_rid84.bin` |
| Stride | 8 B/vtx |
| Buffer 格式 | **float32×2**，值域 [0.012, 0.990] |
| Metal Vertex Format | `Float2` |
| Shader 接收类型 | `half4` → GPU delivers `half4(x, y, 0, **1**)` |

Metal w-padding 规则：缺失的 xyz 补 0，**w 补 1**。因此 `tangent.w = 1.0`。

**Unity**：**不直接使用**。应 `mesh.RecalculateTangents()` 重建。手动设置时 tangent.w = **-1.0**（从 slot 3 bytes 36-39 确认的坐标系 handedness）。

---

### 3.5 Slot 6: TEXCOORD0 (rid 85) — 主 UV ✅

| 项目 | 值 |
|---|---|
| 文件 | `vertex/texcoord0_rid85.bin` |
| 格式 | float32×2，值域 [0.006, 0.991] |
| 用途 | 主贴图坐标（`_MainTex` 等化妆贴图共用） |

**Unity**：`mesh.uv = ReadFloat2Array()`

---

### 3.6 Slot 7: TEXCOORD1 (rid 86) — 第二 UV ✅

| 项目 | 值 |
|---|---|
| 文件 | `vertex/texcoord1_rid86.bin` |
| 格式 | float32×2，值域 [0.004, 0.996] |
| 用途 | 二次 UV（lightmap 或特效映射） |

**Unity**：`mesh.uv2 = ReadFloat2Array()`

---

### 3.7 Slot 8: TEXCOORD2 (rid 87) — 16B 稀疏数据

| 项目 | 值 |
|---|---|
| 文件 | `vertex/texcoord2_rid87.bin` |
| Stride | 16 B/vtx |
| IR 类型 | `float2` (TEXCOORD2, location 5) |

16B stride 但 shader 只读前 8B（float2）。大部分值为 0 或极小噪声，少数顶点有非零数据。Fragment shader 中用于 sparkle UV 或 morph blend shape 权重。

**Unity**：

```csharp
Vector2[] uv3 = new Vector2[5077];
for (int i = 0; i < 5077; i++)
    uv3[i] = new Vector2(ReadFloat(raw, i*16), ReadFloat(raw, i*16 + 4));
mesh.uv3 = uv3;
```

---

### 3.8 Slot 9: TEXCOORD3 (rid 134) — 前一帧位置

与 slot 3 结构相同（40B 交错流），position max diff = 0.000131。用于 motion vector / temporal AA。

**Unity**：静态还原时忽略。

---

## 4. N·T 退化分析

由于 OTW^T ≡ WTO（正交矩阵性质），normal 和 tangent 经过**同一矩阵**变换：

```
worldNormal  = normalize(WTO × normalOS(x,y,0))
worldTangent = normalize(OTW^T × tangentOS(x,y,0)) = normalize(WTO × tangentOS(x,y,0))
```

正交变换保角，因此 world-space N·T 夹角 = object-space 2D 向量 (nx,ny) 与 (tx,ty) 的夹角。

**实测统计**：

| 指标 | 值 |
|------|-----|
| N·T 平均夹角 | 3.9° |
| N·T 最小夹角 | 0.0° |
| N·T 最大夹角 | 39.6° |
| N·T 平均 dot | 0.992 |
| Bitangent 平均长度 | 0.067 |
| Bitangent < 0.1 的顶点比例 | 84.1% |
| Bitangent < 0.3 的顶点比例 | 96.8% |

这意味着法线贴图的 bitangent 方向效果被严重弱化（84% 顶点几乎无 bitangent 贡献）。这是 2D 编码 + z=0 + 相同矩阵变换的数学必然结果。游戏实际渲染正常，原因是法线贴图的主要效果来自 tangent 和 normal 方向的扰动，bitangent 方向的细节损失可接受。

**结论**：导出的 normal/tangent 不适合直接用于任何引擎导入。

---

## 5. Vertex Shader 输出映射

| Output | IR Type | Varying | 含义 |
|--------|---------|---------|------|
| [0] | float4 | SV_POSITION | Clip-space position |
| [1] | half4 | TEXCOORD0 | (UV0.xy, UV1.xy) |
| [2] | half4 | TEXCOORD1 | (UV2.xy, UV3.xy) |
| [3] | float3 | TEXCOORD2 | World-space position |
| [4] | half4 | TEXCOORD3 | (worldNormal.xyz, viewDir.x) |
| [5] | half4 | TEXCOORD4 | (worldTangent.xyz, viewDir.y) |
| [6] | half4 | TEXCOORD5 | (bitangent.xyz, viewDir.z) |
| [7] | float4 | TEXCOORD6 | Clip position（同 SV_POSITION，用于 screen UV） |

---

## 6. Unity 导入完整工作流

```csharp
Mesh mesh = new Mesh();
mesh.indexFormat = IndexFormat.UInt16;

// Position (40B stride, 前 12 字节)
mesh.vertices = DecodePositions("vertex/position_rid100.bin", 5077, stride: 40);

// UV（直接可用）
mesh.uv  = ReadFloat2("vertex/texcoord0_rid85.bin", 5077);   // Main UV
mesh.uv2 = ReadFloat2("vertex/texcoord1_rid86.bin", 5077);   // Secondary UV
mesh.uv3 = ReadFloat2Stride16("vertex/texcoord2_rid87.bin", 5077); // Sparse

// Index
mesh.SetIndices(ReadUInt16("index/index_buffer_rid88.bin", 27894),
                MeshTopology.Triangles, 0);

// TBN：几何重建（推荐）
mesh.RecalculateNormals();
mesh.RecalculateTangents();
mesh.RecalculateBounds();
```

**不直接使用 normal/tangent buffer 的原因**：导出的 slot 4/5 是 pre-skinned 的 2D 编码值（float2 ∈ [0,1]），与本帧 ObjectToWorld 矩阵耦合。GPU 自动 pad 为 half3/half4，shader 用 WTO/OTW^T 矩阵投射后 normalize。由于 OTW^T ≡ WTO（纯旋转矩阵），N 和 T 经同一矩阵变换，导致 world-space 夹角 = 2D 向量夹角（平均仅 3.9°），TBN 严重退化。这是 runtime skinning bandwidth 优化的中间产物，不适合静态 mesh 导入。

### 辅助函数

```csharp
static Vector3[] DecodePositions(string path, int count, int stride) {
    byte[] raw = File.ReadAllBytes(path);
    var result = new Vector3[count];
    for (int i = 0; i < count; i++) {
        int off = i * stride;
        result[i] = new Vector3(
            BitConverter.ToSingle(raw, off),
            BitConverter.ToSingle(raw, off + 4),
            BitConverter.ToSingle(raw, off + 8));
    }
    return result;
}

static Vector2[] ReadFloat2(string path, int count) {
    byte[] raw = File.ReadAllBytes(path);
    var result = new Vector2[count];
    for (int i = 0; i < count; i++)
        result[i] = new Vector2(
            BitConverter.ToSingle(raw, i * 8),
            BitConverter.ToSingle(raw, i * 8 + 4));
    return result;
}

static Vector2[] ReadFloat2Stride16(string path, int count) {
    byte[] raw = File.ReadAllBytes(path);
    var result = new Vector2[count];
    for (int i = 0; i < count; i++)
        result[i] = new Vector2(
            BitConverter.ToSingle(raw, i * 16),
            BitConverter.ToSingle(raw, i * 16 + 4));
    return result;
}

static int[] ReadUInt16(string path, int count) {
    byte[] raw = File.ReadAllBytes(path);
    var result = new int[count];
    for (int i = 0; i < count; i++)
        result[i] = BitConverter.ToUInt16(raw, i * 2);
    return result;
}
```

### 注意事项

1. **坐标系**：Metal 与 Unity 均为左手系。若导入后镜像，尝试 flip X 或 Z。
2. **Pre-skinned**：Position 是 skinned 后的瞬时状态，非 bind-pose。动画需另获 bind-pose + bone weights。
3. **Tangent W**：`RecalculateTangents()` 自动确定 handedness。手动设置时用 `w = -1.0f`。
4. **UV2 (slot 8)**：16B stride 仅前 8B 被 shader 读取。
5. **Motion Vector (rid 134)**：前一帧位置，导入时忽略。

---

## 7. 贴图资源状态

| 贴图 | 格式 | Unity 可用 | 备注 |
|------|------|------------|------|
| MainTexRT (rid 222) | RGBA8 sRGB | ✅ | 512×512 |
| PL_Head_R (rid 197) | ASTC | ⚠️ 需 `astcenc` 解压 | 高光/粗糙度 |
| PL_Head_MU_N (rid 194) | RGBA8 Unorm | ✅ | 法线贴图 |
| PL_Makeup_* | ASTC | ⚠️ 需解压 | 化妆贴图 |
| PL_Makeup_Head_ID (rid 196) | RGBA8 Unorm | ✅ | Morph 分区掩码 |
| LightIndexMap (rid 145) | RGBA8 | ⏭️ RT | 运行时生成 |
| SSSSkinTexture (rid 232) | RG11B10F | ⏭️ RT | SSS pass 产物 |
| ScreenShadowTexture (rid 236) | RGBA8 | ⏭️ RT | 阴影 pass 产物 |

---

## 8. 数据完整性

| 资源 | 大小 | 格式 | Unity 导入 |
|------|------|------|------------|
| Index | 55,788 B | uint16×27894 | 直接读取 |
| Position | 203,080 B | float3 (40B stride) | 直接读取 |
| Normal | 40,616 B | float2 [0,1] 编码 | ⚠ RecalculateNormals() |
| Tangent | 40,616 B | float2 [0,1] 编码 | ⚠ RecalculateTangents() |
| UV0 | 40,616 B | float2 | 直接读取 |
| UV1 | 40,616 B | float2 | 直接读取 |
| UV2 | 81,232 B | float2 (16B stride) | 直接读取 |
| MotionVec | 203,080 B | 前一帧位置 | 跳过 |
| 美术贴图 ×10 | ~17.8 MB | ASTC/RGBA8 | astcenc 解压 |
| RT 贴图 ×3 | ~4.0 MB | 运行时生成 | 不导入 |
