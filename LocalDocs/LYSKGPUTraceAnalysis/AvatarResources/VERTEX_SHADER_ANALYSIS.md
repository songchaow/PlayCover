# Vertex Shader 分析与资源解码指南

> **目标**：分析 RPS 496 (SkinMakeupNew) vertex shader 的输入/输出逻辑，为 Unity 引擎还原确定每个 vertex buffer 的精确解码方式。
>
> **Vertex Shader**：`library_408` / `function_key=409` / `xlatMtlMain`
> **IR 来源**：`LocalDocs/OfflineSourceRecovery/gputracebinaryreplacement/SkinMakeupNew_vertex.ll`
>
> **⚠️ 关键结论**：Normal/Tangent buffer 存储的是 **float32×2 in [0,1]**，Metal vertex format 为 `Float2`。GPU 按 Metal 规范 pad 到 `half3(x,y,0)` / `half4(x,y,0,1)` 后送入 shader。tangent.w = **1.0**（Metal 的 w-pad 规则）。Vertex shader 依赖 `ObjectToWorld`/`WorldToObject` 的**非平凡旋转**将 2D 输入投射为 3D 世界法线/切线，然后 normalize。对于 Unity 导入，**不需要 octahedral/hemisphere decode**——直接用 `RecalculateNormals()` + `RecalculateTangents()` 重建标准 TBN 即可。

---

## 1. Vertex Shader 功能总结

RPS 496 的 vertex shader 非常简单——不含任何 skinning 或 morph 计算（这些已在 CPU/Compute 端完成），仅执行：

1. **Position → Clip Space**：`positionOS.xyz` × `ObjectToWorld` → `positionWS` → `positionWS - _WorldSpaceRelativeCameraPos` → × `_ViewProjMatrix` → `positionCS`
2. **Normal → World Space**：`normalOS(x,y,0)` × `WorldToObject^T` → normalize → `worldNormal`
3. **Tangent → World Space**：`tangentOS(x,y,0)` × `ObjectToWorld_3x3` → normalize → `worldTangent`
4. **Bitangent 计算**：`cross(worldNormal, worldTangent) * tangentOS.w(=1.0) * unity_WorldTransformParams.w(=1.0)`
5. **UV 直通**：`TEXCOORD0~3` 直接 pack 到 output TEXCOORD0/TEXCOORD1
6. **ViewDir 计算**：`_WorldSpaceCameraPos - positionWS` → 分量拆入 TBN row 的 w 分量

---

## 2. 关键发现：ObjectToWorld 含非平凡旋转

```
ObjectToWorld 3×3:
  Row 0: (  0.000, -1.000,  0.000 )   ← OS X 轴 → World -Y
  Row 1: (  0.603,  0.000,  0.798 )   ← OS Y 轴 → World XZ 平面（约 53°）
  Row 2: ( -0.798,  0.000,  0.603 )   ← OS Z 轴 → World XZ 平面
  Row 3: ( -0.003,  0.950, -0.005, 1) ← Translation

Determinant = 1.0 (pure rotation, no scale)
```

**结论**：这不是 identity 变换。OS Y 轴映射到 world 的 XZ 平面（角色朝向），OS X 轴映射到 world -Y（向下）。法线/切线变换依赖此矩阵的正确值。

---

## 3. 各 Vertex Buffer 解码方案

### 3.1 Index Buffer (rid 88) ✅ 可直接使用

| 项目 | 值 |
|---|---|
| 文件 | `index/index_buffer_rid88.bin` |
| 格式 | `uint16` little-endian |
| 元素数 | 27,894 (= 9,298 三角形) |
| Max index | 5,076 |

**Unity 导入**：直接 `mesh.SetIndices(indices, MeshTopology.Triangles, 0)`

---

### 3.2 Slot 3: POSITION0 (rid 100) — 40B 交错流

| 项目 | 值 |
|---|---|
| 文件 | `vertex/position_rid100.bin` |
| Stride | 40 B/vtx |
| 顶点数 | 5,077 |
| IR 类型 | `float4` (POSITION0, vertex_input location 0) |

**数据布局**（每 40 字节）：

| Offset | Size | 类型 | 含义 | Shader 是否读取 |
|--------|------|------|------|-----------------|
| 0 | 16 B | float4 | Position XYZ + W | ✅ 仅用 XYZ |
| 16 | 24 B | ? | 额外数据（skinning 相关） | ❌ 本 draw 不读 |

**Position 字段分析**：
- `xyz`: Object-space 局部坐标，范围 X∈[-0.72, -0.49], Y∈[-0.06, 0.11], Z∈[-0.08, 0.08]
- `w`: 连续值 ∈ [-1.0, 1.0]，3970 个 unique 值 — **skinning blend weight**，本 shader 不读取

**Bytes 16-39 解读**：
- Bytes 16-31 (float4): 值域 ~[-1, 1]，可能是**前一帧的 skinned normal** 或 bone weights/indices
- Bytes 32-39 (float2): 第一个值 ~[-0.97, -0.94]，第二个值恒 = -1.0 — 可能是 tangent.w 或 flag

**Unity 导入**：
```csharp
// 只需前 12 字节 (float3 position)
Vector3[] positions = new Vector3[5077];
for (int i = 0; i < 5077; i++) {
    positions[i] = new Vector3(
        ReadFloat(raw, i*40 + 0),
        ReadFloat(raw, i*40 + 4),
        ReadFloat(raw, i*40 + 8)
    );
}
mesh.vertices = positions;
```

---

### 3.3 Slot 4: NORMAL0 (rid 83) — 2D 编码法线

| 项目 | 值 |
|---|---|
| 文件 | `vertex/normal_rid83.bin` |
| Stride | 8 B/vtx |
| Buffer 格式 | **float32 × 2**，值域 [0.007, 0.997] |
| Metal Vertex Format | `Float2` (MTLVertexFormatFloat2) |
| Shader 接收类型 | `half3` → GPU delivers `half3(half(x), half(y), 0.0h)` |
| IR 声明 | `air.vertex_input`, location_index=1, `half3`, `NORMAL0` |

**工作原理**：

shader 接收 `normalOS = (x, y, 0)` 后做：
```
worldNormal = normalize(normalOS × WorldToObject^T)
```
由于 WTO 3×3 部分含非平凡旋转（det=1 的正交变换），即使 z=0 的 2D 输入，经矩阵投射后也能得到有效的 3D 世界法线。这是一种**引擎特化的 bandwidth 优化**：用 8B（2×float32）替代 12B（3×float32），靠已知的刚性变换矩阵隐式补全第三维。

**验证**：
- 不做 decode（raw [0,1], z=0, WTO 变换）→ 所有法线朝同一半球 ← **这就是 shader 的实际行为**
- 在本帧中，ObjectToWorld 把 OS 面朝 -X 的面部映射到世界空间中面朝前方（Z+），由于面部网格的法线在 OS 中大多朝向 -X，经过 WTO 旋转后确实会分布在合理的方向上

**⚠️ 核心问题：N 和 T 经变换后几乎平行（夹角 ~7.4°）**

这导致 `cross(worldN, worldT)` 产生的 bitangent 长度只有 ~6.6%。TBN 矩阵是退化的（condition number 很大），法线贴图的 bitangent 方向几乎不起作用。

**可能的解释**：
1. 这是 pre-skinned 后的瞬时状态，skinning 动画改变了 N/T 的相对方向
2. 引擎 fragment shader 中的法线重建实际上主要依赖 normal map 的 XZ 分量（tangent + normal 方向），Y 分量（bitangent 方向）被引擎设计为弱化
3. 法线贴图本身已经预处理为适配此退化 TBN 的形式

**Unity 导入方案**：

由于 N/T 的 2D 编码与特定 ObjectToWorld 矩阵耦合（pre-skinned data），**不应直接使用这些编码值作为 Unity mesh 的 normal/tangent**。正确做法：

```csharp
// 方案 A（推荐）：用几何重建标准 TBN
mesh.vertices = positions;  // from slot 3
mesh.uv = uv0;              // from slot 6
mesh.triangles = indices;   // from index buffer
mesh.RecalculateNormals();  // 从几何计算法线
mesh.RecalculateTangents(); // 从 UV 梯度计算切线

// 方案 B：如果需要精确匹配 trace 中的渲染结果
// 需要在自定义 shader 中复刻完整的 WTO/OTW 变换逻辑
```

---

### 3.4 Slot 5: TANGENT0 (rid 84) — 2D 编码切线

| 项目 | 值 |
|---|---|
| 文件 | `vertex/tangent_rid84.bin` |
| Stride | 8 B/vtx |
| Buffer 格式 | **float32 × 2**，值域 [0.012, 0.990] |
| Metal Vertex Format | `Float2` |
| Shader 接收类型 | `half4` → GPU delivers `half4(half(x), half(y), 0.0h, 1.0h)` |
| IR 声明 | `air.vertex_input`, location_index=2, `half4`, `TANGENT0` |

**⚠️ Metal w-padding 规则**：当 vertex format 提供的分量少于 shader 期望时：
- x, y, z 分量：默认补 **0.0**
- **w 分量：默认补 1.0**

因此 `tangent.w = 1.0`，bitangent 计算为：
```
bitangent = cross(worldNormal, worldTangent) * 1.0 * unity_WorldTransformParams.w(=1.0)
```

**Unity 导入**：同法线 — 使用 `mesh.RecalculateTangents()` 重建。

---

### 3.4.1 Slot 3 Bytes 36-39：Tangent Sign 确认

在 40B 交错流 (rid 100) 中：
- **Bytes 36-39**: float32 恒等于 **-1.0**（所有 5077 个顶点）

这与 `unity_WorldTransformParams.w` 的含义一致：表示网格使用的坐标系 handedness。但由于 vertex shader 已经在其计算中使用了 `unity_WorldTransformParams.w`（从 cbuffer 读取，值=1.0），bytes 36-39 的 -1.0 并不直接参与本 draw call。

对于 Unity 导入，tangent.w 应设为 **-1.0**（左手坐标系，与多数 Unity 内置 shader 兼容）。

---

### 3.5 Slot 6: TEXCOORD0 (rid 85) — 主 UV ✅ 可直接使用

| 项目 | 值 |
|---|---|
| 文件 | `vertex/texcoord0_rid85.bin` |
| 格式 | float32 × 2 |
| 值域 | [0.0057, 0.9912] |
| 用途 | 主贴图坐标（`_MainTex` 等化妆贴图共用） |

**Unity 导入**：`mesh.uv = ReadFloat2Array()`

---

### 3.6 Slot 7: TEXCOORD1 (rid 86) — 第二 UV ✅ 可直接使用

| 项目 | 值 |
|---|---|
| 文件 | `vertex/texcoord1_rid86.bin` |
| 格式 | float32 × 2 |
| 值域 | [0.0036, 0.9963] |
| 用途 | 二次 UV（lightmap 或特殊效果映射） |

**Unity 导入**：`mesh.uv2 = ReadFloat2Array()`

---

### 3.7 Slot 8: TEXCOORD2 (rid 87) — 16B 特殊数据

| 项目 | 值 |
|---|---|
| 文件 | `vertex/texcoord2_rid87.bin` |
| Stride | 16 B/vtx |
| IR 类型 | `float2` (TEXCOORD2, vertex_input location 5) |

**数据特征**：
- 大部分值为 0
- 非零值分布不规则，包含极大值 (>10^18) 和小值
- 86.2% 的元素非零（但大部分是 float 表示中的微小噪声）

**Shader 使用**：vertex shader 仅将 TEXCOORD2 (float2) pack 到输出 varying 中直通到 fragment。在 fragment shader 中用于 sparkle UV 或 morph blend shape 权重。

**⚠ 注意**：16B stride 但 IR 只声明 float2 → shader 只读取前 8 字节，后 8 字节不被本 draw 使用。

**Unity 导入**：
```csharp
// 读取每 16 字节的前 8 字节作为 float2
Vector2[] uv3 = new Vector2[5077];
for (int i = 0; i < 5077; i++) {
    uv3[i] = new Vector2(
        ReadFloat(raw, i*16 + 0),
        ReadFloat(raw, i*16 + 4)
    );
}
mesh.uv3 = uv3;
```

---

### 3.8 Slot 9: TEXCOORD3 (rid 134) — 前一帧位置

| 项目 | 值 |
|---|---|
| 文件 | `vertex/texcoord3_rid134.bin` |
| Stride | 40 B/vtx |
| IR 类型 | `float2` (TEXCOORD3, vertex_input location 6) |

**分析结果**：
- 与 slot 3 (rid 100) 结构相同（40B 交错流）
- 前 16 字节的 position 与 rid 100 的 diff < 0.00026（亚毫米级别）
- **这是前一帧的 skinned position**（用于 motion vector / temporal AA）

**Unity 导入**：对于静态还原，**可以忽略此 buffer**。Motion vector 计算在 Unity 中自动处理。

---

## 4. Vertex Shader 输出 → Fragment 输入映射

| Output | IR Type | Varying | 含义 |
|--------|---------|---------|------|
| [0] | float4 | SV_POSITION | Clip-space position |
| [1] | half4 | TEXCOORD0 | (UV0.xy, UV1.xy) — mainUV + blusherUV |
| [2] | half4 | TEXCOORD1 | (UV2.xy, UV3.xy) — extraUV pack |
| [3] | float3 | TEXCOORD2 | World-space position |
| [4] | half4 | TEXCOORD3 | (worldNormal.xyz, viewDir.x) |
| [5] | half4 | TEXCOORD4 | (worldTangent.xyz, viewDir.y) |
| [6] | half4 | TEXCOORD5 | (bitangent.xyz, viewDir.z) |
| [7] | float4 | TEXCOORD6 | NDC position (for screen UV) |

---

## 5. Unity 导入完整工作流

### 步骤 1：导入 Mesh

```csharp
Mesh mesh = new Mesh();
mesh.indexFormat = IndexFormat.UInt16;

// Positions (first 12 bytes of each 40-byte record)
mesh.vertices = DecodePositions("vertex/position_rid100.bin", 5077, stride: 40);

// UVs (直接可用)
mesh.uv  = ReadFloat2("vertex/texcoord0_rid85.bin", 5077);  // Main UV
mesh.uv2 = ReadFloat2("vertex/texcoord1_rid86.bin", 5077);  // Secondary UV
mesh.uv3 = ReadFloat2Stride16("vertex/texcoord2_rid87.bin", 5077);  // Sparse data

// Indices
mesh.SetIndices(ReadUInt16("index/index_buffer_rid88.bin", 27894), 
                MeshTopology.Triangles, 0);

// Normal & Tangent: 使用几何重建（推荐）
mesh.RecalculateNormals();
mesh.RecalculateTangents();

mesh.RecalculateBounds();
```

**为什么不直接使用导出的 normal/tangent buffer？**

导出的 slot 4/5 数据是 pre-skinned 状态下的 **2D 编码法线/切线**（float2 ∈ [0,1]），与特定帧的 ObjectToWorld 旋转矩阵耦合。它的工作方式是：
1. GPU 以 Float2 format 读取 → 交给 shader 为 `half3(x,y,0)` / `half4(x,y,0,1)`
2. Vertex shader 用非平凡的 WTO/OTW 矩阵将 2D 投射到 3D
3. Normalize 后得到世界空间法线/切线（但 N·T 夹角仅 ~7.4°，TBN 严重退化）

这种编码是 runtime skinning 的中间产物，不适合作为 Unity mesh 的静态法线。正确做法是从几何重建，确保标准正交 TBN。

### 步骤 2：辅助解码函数

```csharp
static Vector3[] DecodePositions(string path, int count, int stride) {
    byte[] raw = File.ReadAllBytes(path);
    Vector3[] result = new Vector3[count];
    for (int i = 0; i < count; i++) {
        int offset = i * stride;
        result[i] = new Vector3(
            BitConverter.ToSingle(raw, offset),
            BitConverter.ToSingle(raw, offset + 4),
            BitConverter.ToSingle(raw, offset + 8)
        );
    }
    return result;
}

static Vector2[] ReadFloat2(string path, int count) {
    byte[] raw = File.ReadAllBytes(path);
    Vector2[] result = new Vector2[count];
    for (int i = 0; i < count; i++) {
        result[i] = new Vector2(
            BitConverter.ToSingle(raw, i * 8),
            BitConverter.ToSingle(raw, i * 8 + 4)
        );
    }
    return result;
}

static Vector2[] ReadFloat2Stride16(string path, int count) {
    byte[] raw = File.ReadAllBytes(path);
    Vector2[] result = new Vector2[count];
    for (int i = 0; i < count; i++) {
        result[i] = new Vector2(
            BitConverter.ToSingle(raw, i * 16),
            BitConverter.ToSingle(raw, i * 16 + 4)
        );
    }
    return result;
}

static int[] ReadUInt16(string path, int count) {
    byte[] raw = File.ReadAllBytes(path);
    int[] result = new int[count];
    for (int i = 0; i < count; i++)
        result[i] = BitConverter.ToUInt16(raw, i * 2);
    return result;
}
```

### 步骤 3：注意事项

1. **坐标系**：导出数据是 Metal 左手坐标系。Unity 也用左手，但如果导入后模型镜像，尝试 flip X 或 Z。
2. **Pre-skinned data**：位置是 skinned 后的瞬时状态（特定帧/pose），不是 bind-pose。如需动画，需从其他来源获取 bind-pose 和 bone weights。
3. **Tangent W**：`mesh.RecalculateTangents()` 会自动确定 handedness。如果手动设置，使用 `w = -1.0f`（从 slot 3 bytes 36-39 确认）。
4. **UV2 (slot 8)**：16B stride 中只有前 8B 被 shader 读取为 float2，后 8B 不使用。
5. **Motion Vector buffer (rid 134)**：前一帧位置，仅用于 temporal 效果，导入时可忽略。

---

## 6. 贴图资源解码状态

| 贴图 | 格式 | 可直接用于 Unity? | 备注 |
|------|------|-------------------|------|
| MainTexRT (rid 222) | RGBA8 Unorm sRGB | ✅ | 512×512，直接导入为 Texture2D |
| PL_Head_R (rid 197) | ASTC | ⚠️ 需解压 | 需 `astcenc` 解压为 RGBA |
| PL_Head_MU_N (rid 194) | RGBA8 Unorm | ✅ | 法线贴图，设置为 Normal Map |
| PL_Makeup_* | ASTC | ⚠️ 需解压 | 所有化妆贴图需解压 |
| PL_Makeup_Head_ID (rid 196) | RGBA8 Unorm | ✅ | Morph 分区掩码 |
| LightIndexMap (rid 145) | RGBA8 Unorm | ⚠️ RT | 运行时生成，不需要作为资产导入 |
| SSSSkinTexture (rid 232) | RG11B10F | ⚠️ RT | 运行时 SSS pass 产物 |
| ScreenShadowTexture (rid 236) | RGBA8 | ⚠️ RT | 运行时阴影 pass 产物 |

---

## 7. 已解决的关键歧义

| 问题 | 结论 | 证据 |
|------|------|------|
| Normal/Tangent buffer 是什么格式？ | **float32×2 in [0,1]**，Metal vertex format = Float2 | 8B/vtx，float32 解读值域合理；Half4/10_10_10_2/SNorm16 均产生 garbage |
| GPU 如何 deliver half3/half4？ | Float2 → `half3(x,y,0)` / `half4(x,y,0,**1**)` | Metal spec: 缺失的 xyz pad 0, **w pad 1** |
| tangent.w 是什么值？ | **1.0**（Metal w-padding） | 不是来自 buffer，而是 GPU 自动 pad |
| bitangent 是否为零？ | **不是**。= cross(N,T) × 1.0 × 1.0，长度 ~6.6% | unity_WorldTransformParams.w = 1.0 (from trace) |
| N·T 为什么几乎平行？| 2D 编码 + z=0 + 相似矩阵变换 → 变换后方向相近 | N·T mean dot = 0.9916, 夹角 ~7.4° |
| 为什么 TBN 仍然有效？ | Fragment shader normalize 最终法线；法线贴图 Y 通道效果被弱化但非零 | 游戏实际渲染效果正常 |
| Bytes 36-39 (slot 3) 是什么？ | **恒为 -1.0**，tangent sign / coordinate handedness | 5077 个顶点全部 = -1.000000 |
| Position.w 是什么？ | **连续 blend weight** ∈ [-1, 1]，3970 unique 值 | 本 shader 不读取 |
| 对 Unity 导入的建议？ | **用 RecalculateNormals() + RecalculateTangents()** | 2D 编码与特定帧 OTW 矩阵耦合，不适合静态 mesh 导入 |

---

## 8. 数据完整性确认

| 资源 | 文件 | 大小 | 解码状态 | Unity 导入方式 |
|------|------|------|----------|---------------|
| Index | ✅ | 55,788 B | uint16 × 27894 | 直接读取 |
| Position | ✅ | 203,080 B | float3 (40B stride 前 12B) | 直接读取 |
| Normal | ✅ | 40,616 B | float2 [0,1] 编码 | **⚠ 不直接用，RecalculateNormals()** |
| Tangent | ✅ | 40,616 B | float2 [0,1] 编码 | **⚠ 不直接用，RecalculateTangents()** |
| UV0 | ✅ | 40,616 B | float2 | 直接读取 |
| UV1 | ✅ | 40,616 B | float2 | 直接读取 |
| UV2 | ✅ | 81,232 B | float2 (16B stride 前 8B) | 直接读取 |
| UV3/MotionVec | ⏭️ | 203,080 B | 前一帧位置 | 跳过 |
| 美术贴图 ×10 | ⚠️ | ~17.8 MB | ASTC 需解压，RGBA8 直接可用 | astcenc 解压 |
| RT 贴图 ×3 | ⏭️ | ~4.0 MB | 运行时生成 | 不导入 |
