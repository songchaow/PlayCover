# Papegame/SkinMakeupNew Vertex Shader — 完整实现分析

## 基本信息

| 属性 | 值 |
|------|------|
| **Shader 名称** | `Papegame/SkinMakeupNew` |
| **着色器类型** | Vertex shader |
| **入口函数** | `@xlatMtlMain` |
| **Target** | `air64_v24-apple-ios15.0.0` (Apple GPU IR / AIR) |
| **IR 文件** | `SkinMakeupNew_vertex_lib0x7b12cf580.ll` (253 行) |
| **源 bitcode** | `ShaderDebugInfo/com.papegames.lysk/C2F2D89403D39FBF_7593/modules/0aae7e0986955774b1126afa4878163b49fe0e39c7b8e3b212e08aa9613b4477/module.bc` |
| **Pipeline Address** | `0x7b12cf580` |
| **Pipeline Hex ID** | `C2F2D89403D39FBF` |
| **精度策略** | 空间变换用 `float` (FP32)，法线/切线用 `half` (FP16) |
| **Metal 版本** | Apple metal version 32023.830 (metalfe-32023.830.2) |
| **Metal 语言版本** | Metal 2.3.0 |

---

## 总体架构

这是一个经典的 **skinned mesh vertex shader**，负责：
1. 顶点位置从模型空间变换到裁剪空间（MVP）
2. 计算世界空间位置（传递给 fragment shader 做光照）
3. 法线/切线从模型空间变换到世界空间，构建 TBN 矩阵
4. 传递 UV 坐标
5. 计算 view direction 分量并打包到输出 varying 的 `.w` 通道

注意：**此 shader 无骨骼蒙皮（skinning）计算**。从输入只有 `POSITION0` 而无 `BLENDWEIGHT`/`BLENDINDICES` 来看，这个 shader 针对的是**已完成 GPU Skinning 或在 CPU 侧完成骨骼变换**后的顶点数据。

---

## 输入资源绑定

### Constant Buffers (3 个)

| 参数索引 | 类型名 | 参数名 | 大小 | 用途 |
|----------|--------|--------|------|------|
| 0 | `UnityPerCamera_Type` | `UnityPerCamera` | 320B | 相机参数 |
| 1 | `UnityPerDraw_Type` | `UnityPerDraw` | 320B | 物体变换矩阵 |
| 2 | `UnityPerPass_Type` | `UnityPerPass` | 592B | VP 矩阵等 |

### Vertex Inputs (7 个)

| 参数索引 | 语义 | 类型 | 说明 |
|----------|------|------|------|
| 3 | `POSITION0` | `float4` | 模型空间顶点位置 |
| 4 | `NORMAL0` | `half3` | 模型空间法线 |
| 5 | `TANGENT0` | `half4` | 模型空间切线 (.w = handedness sign) |
| 6 | `TEXCOORD0` | `float2` | 主 UV 坐标 |
| 7 | `TEXCOORD1` | `float2` | 第二 UV 坐标 |
| 8 | `TEXCOORD2` | `float2` | 第三 UV 坐标 |
| 9 | `TEXCOORD3` | `float2` | 第四 UV 坐标 |

### Vertex Outputs (8 个)

| 索引 | 语义 | 类型 | 内容 |
|------|------|------|------|
| 0 | `SV_POSITION` (air.position) | `float4` | 裁剪空间位置（带 depth bias） |
| 1 | `TEXCOORD0` | `half4` | UV0.xy + UV1.xy (打包) |
| 2 | `TEXCOORD1` | `half4` | UV2.xy + UV3.xy (打包) |
| 3 | `TEXCOORD2` | `float3` | 世界空间位置 |
| 4 | `TEXCOORD3` | `half4` | 世界空间法线.xyz + viewDir.x |
| 5 | `TEXCOORD4` | `half4` | 世界空间切线.xyz + viewDir.y |
| 6 | `TEXCOORD5` | `half4` | 世界空间副切线.xyz + viewDir.z |
| 7 | `TEXCOORD6` | `float4` | 原始裁剪空间位置（无 depth bias） |

---

## Constant Buffer 结构详解

### UnityPerCamera_Type (320 bytes)

| 偏移 | 类型 | 名称 | 用途 |
|------|------|------|------|
| 0 | float4 | `_Time` | 时间参数 |
| 16 | float4 | `_SinTime` | sin(time) |
| 32 | float4 | `_CosTime` | cos(time) |
| 48 | float4 | `_TimeParameters` | 时间参数 |
| 64 | float4 | `unity_DeltaTime` | 帧间隔 |
| 80 | float3 | `_WorldSpaceRelativeCameraPos` | **相对相机位置** |
| 96 | float | `_EyeAdaptionExposure` | 曝光 |
| 112 | float3 | `_WorldSpaceCameraPos` | **绝对相机位置** |
| 128 | float | `_EyeAdaptionInverseExposure` | 逆曝光 |
| 144 | float3 | `_WorldSpaceCameraDir` | 相机朝向 |
| 160 | float4 | `_ProjectionParams` | 投影参数 |
| 176 | float4 | `_ScreenParams` | 屏幕参数 |
| 192 | float4 | `_ZBufferParams` | 深度缓冲参数 |
| 208 | float4 | `unity_OrthoParams` | 正交投影参数 |
| 224 | float3 | `_PrevCameraPos` | 前帧相机位置 |
| 240 | float | `_ReflectNormalBias` | 反射法线偏差 |
| 256 | float4 | `_PrevTime` | 前帧时间 |
| 272 | float4 | `_SRPTime` | SRP 时间 |
| 288 | float4 | `_PaperUnscaledTime` | 未缩放时间 |
| 304 | uint | `_FrameCount8` | 帧计数(mod 8) |

### UnityPerDraw_Type (320 bytes)

| 偏移 | 类型 | 名称 | 用途 |
|------|------|------|------|
| 0 | float4×4 | `hlslcc_mtx4x4unity_ObjectToWorld` | **M 矩阵 (模型→世界)** |
| 64 | float4×4 | `hlslcc_mtx4x4unity_WorldToObject` | **逆 M 矩阵 (世界→模型)** |
| 128 | float4 | `unity_WorldTransformParams` | 变换参数 (.w = sign) |
| 144 | float4 | `unity_SpecCube0_HDR` | HDR 参数 |
| 160 | float4×4 | `hlslcc_mtx4x4unity_MatrixPreviousM` | 前帧 M 矩阵 |
| 224 | float4×4 | `hlslcc_mtx4x4unity_MatrixPreviousMI` | 前帧逆 M 矩阵 |
| 288 | float4 | `unity_MotionVectorsParams` | 运动向量参数 |
| 304 | uint | `Pape_SpecCubeArrayMaxMip` | Cubemap mip 数 |

### UnityPerPass_Type (592 bytes)

| 偏移 | 类型 | 名称 | 用途 |
|------|------|------|------|
| 0 | float4×4 | `hlslcc_mtx4x4_PrevViewProjMatrix` | 前帧 VP 矩阵 |
| 64 | float4×4 | `hlslcc_mtx4x4_ViewProjMatrix` | **当前帧 VP 矩阵** |
| 128 | float4×4 | `hlslcc_mtx4x4_NonJitteredViewProjMatrix` | 无抖动 VP 矩阵 |
| 192 | float4×4 | `hlslcc_mtx4x4_ViewMatrix` | V 矩阵 |
| 256 | float4×4 | `hlslcc_mtx4x4_ProjMatrix` | P 矩阵 |
| 320 | float4×4 | `hlslcc_mtx4x4_InvViewProjMatrix` | 逆 VP 矩阵 |
| 384 | float4×4 | `hlslcc_mtx4x4_InvViewMatrix` | 逆 V 矩阵 |
| 448 | float4×4 | `hlslcc_mtx4x4_InvProjMatrix` | 逆 P 矩阵 |
| 512 | float4 | `_InvProjParam` | 逆投影参数 |
| 528 | half4 | `_ScreenSize` | 屏幕尺寸 |
| 536 | half4 | `_HDRSize` | HDR buffer 尺寸 |
| 544 | half4×6 | `_FrustumPlanes` | 视锥体平面 |

---

## 计算流程分析

整个 vertex shader 可以分为 **5 个阶段**：

### 阶段 1: 模型空间 → 世界空间位置变换 (IR Line 12–30)

使用 `unity_ObjectToWorld` 矩阵（4×4）将顶点位置从模型空间变换到世界空间。

#### IR 逻辑（逐行解析）

```hlsl
// 提取 POSITION0.yyy (广播 y 分量到 vec3)
float3 posY = POSITION0.yyy;                        // %11 = shufflevector %3, <1,1,1>

// 加载 ObjectToWorld 矩阵第 1 列 (column 1)
float4 M_col1 = unity_ObjectToWorld[1];             // %13 = load GEP [1][0][1]
float3 M_col1_xyz = M_col1.xyz;                    // %14 = shufflevector <0,1,2>

// posY * M_col1.xyz
float3 acc = posY * M_col1_xyz;                    // %15 = fmul %11, %14

// 加载 ObjectToWorld 矩阵第 0 列 (column 0)
float4 M_col0 = unity_ObjectToWorld[0];             // %17 = load GEP [1][0][0]
float3 M_col0_xyz = M_col0.xyz;                    // %18 = shufflevector <0,1,2>

// posX * M_col0.xyz + acc  (FMA)
float3 posX = POSITION0.xxx;                        // %19 = shufflevector %3, <0,0,0>
acc = fma(M_col0_xyz, posX, acc);                   // %20 = air.fma.v3f32

// 加载 ObjectToWorld 矩阵第 2 列 (column 2)
float4 M_col2 = unity_ObjectToWorld[2];             // %22 = load GEP [1][0][2]
float3 M_col2_xyz = M_col2.xyz;                    // %23 = shufflevector <0,1,2>

// posZ * M_col2.xyz + acc
float3 posZ = POSITION0.zzz;                        // %24 = shufflevector %3, <2,2,2>
acc = fma(M_col2_xyz, posZ, acc);                   // %25 = air.fma.v3f32

// 加载 ObjectToWorld 矩阵第 3 列 (column 3, 平移部分)
float4 M_col3 = unity_ObjectToWorld[3];             // %27 = load GEP [1][0][3]
float3 M_col3_xyz = M_col3.xyz;                    // %28 = shufflevector <0,1,2>

// 最终世界空间位置 = acc + M_col3.xyz (相当于 w=1 的齐次变换)
float3 worldPos = acc + M_col3_xyz;                 // %29 = fadd %25, %28
```

#### 等价 HLSL

```hlsl
float3 worldPos = mul(unity_ObjectToWorld, float4(POSITION0.xyz, 1.0)).xyz;
```

**注意**：这里利用了 `POSITION0.w` 隐含为 1.0 的假设，直接将平移列加上而非乘以 w 分量。矩阵以**列主序**存储（`[col_index]`），与 HLSL `mul(M, v)` 的行展开一致。

---

### 阶段 2: 相对世界位置 → 裁剪空间变换 (IR Line 31–56)

此引擎使用了**相机相对渲染 (Camera-Relative Rendering)** 技术：世界空间位置先减去相机位置，再乘以 ViewProjection 矩阵。

#### 2.1 相机相对位置

```hlsl
// 加载 _WorldSpaceRelativeCameraPos (UnityPerCamera offset 80)
float3 relativeCamPos = _WorldSpaceRelativeCameraPos;   // %31 = load GEP [0][5]

// 相对位置 = worldPos - relativeCamPos
float3 relativePos = worldPos - relativeCamPos;          // %32 = fsub %29, %31
```

**为什么用 `_WorldSpaceRelativeCameraPos` 而不是 `_WorldSpaceCameraPos`**？

这是 Papegame 自定义的 Camera-Relative Rendering 方案：
- `_WorldSpaceRelativeCameraPos` 是用于裁剪空间计算的参考点（可能与 `_WorldSpaceCameraPos` 略有偏移以支持双精度大世界）
- `_WorldSpaceCameraPos` 则用于实际光照计算中的 view direction

#### 2.2 ViewProjection 矩阵变换

```hlsl
// relativePos.yyy 广播
float4 vpY = relativePos.yyyy;                           // %33 = shufflevector <1,1,1,1>

// VP 矩阵第 1 行
float4 VP_row1 = _ViewProjMatrix[1];                     // %35 = load GEP [2][1][1]
float4 acc4 = VP_row1 * vpY;                             // %36 = fmul %35, %33

// VP 矩阵第 0 行 + fma
float4 VP_row0 = _ViewProjMatrix[0];                     // %38 = load GEP [2][1][0]
float4 vpX = relativePos.xxxx;                           // %39 = shufflevector <0,0,0,0>
acc4 = fma(VP_row0, vpX, acc4);                          // %40 = air.fma.v4f32

// VP 矩阵第 2 行 + fma
float4 VP_row2 = _ViewProjMatrix[2];                     // %42 = load GEP [2][1][2]
float4 vpZ = relativePos.zzzz;                           // %43 = shufflevector <2,2,2,2>
acc4 = fma(VP_row2, vpZ, acc4);                          // %44 = air.fma.v4f32

// VP 矩阵第 3 行 (常量项)
float4 VP_row3 = _ViewProjMatrix[3];                     // %46 = load GEP [2][1][3]
float4 clipPos = acc4 + VP_row3;                         // %47 = fadd %44, %46
```

等价于：
```hlsl
float4 clipPos = mul(_ViewProjMatrix, float4(relativePos, 1.0));
```

#### 2.3 Depth Bias (反向 Z 深度偏移)

```hlsl
// 取裁剪空间 w 分量的绝对值
float absW = abs(clipPos.w);                             // %49 = air.fast_fabs.f32(%48)

// 取裁剪空间 z 分量
float clipZ = clipPos.z;                                 // %50 = extractelement %47, 2

// z' = fma(abs(w), 0x3F4A36E2E0000000, z)
// 0x3F4A36E2E0000000 ≈ 8.0e-4 (实际为 float 0.000800...)
float biasedZ = fma(absW, 8.0e-4, clipZ);               // %51 = air.fma.f32

// 构造最终 SV_POSITION = float4(clipPos.x, clipPos.y, biasedZ, clipPos.w)
float4 sv_position = float4(clipPos.xy, biasedZ, clipPos.w);  // %52–%55
```

**Depth Bias 的目的**：
- 这是一个**微小的正向 Z 偏移**（约 0.0008 × |w|），用于：
  - 避免自阴影（shadow acne）
  - 或确保皮肤模型在深度排序中略微偏前（减少 Z-fighting）
- 偏移量与 `|w|`（即深度距离）成正比，保证在不同深度下偏移效果一致
- 这个值非常小（NDC 空间约 0.08%），肉眼不可见

#### 2.4 两个位置输出

Shader 输出了两个版本的裁剪空间位置：
- **`SV_POSITION`** (output 0): 带 depth bias 的版本 → 用于光栅化
- **`TEXCOORD6`** (output 7): 原始未修改版本 → fragment shader 用于计算屏幕空间 UV

```hlsl
output.SV_POSITION = float4(clipPos.xy, biasedZ, clipPos.w);  // 光栅化用
output.TEXCOORD6   = clipPos;                                   // 屏幕 UV 计算用
```

---

### 阶段 3: UV 坐标打包传递 (IR Line 57–60)

将 4 组 `float2` UV 坐标打包为 2 个 `half4`：

```hlsl
// UV0 (float2) + UV1 (float2) → half4
float4 uv01 = float4(TEXCOORD0.xy, TEXCOORD1.xy);       // %56 = shufflevector %6, %7
half4 output_TEXCOORD0 = (half4)uv01;                    // %57 = air.convert.f.v4f16.f.v4f32

// UV2 (float2) + UV3 (float2) → half4
float4 uv23 = float4(TEXCOORD2.xy, TEXCOORD3.xy);       // %58 = shufflevector %8, %9
half4 output_TEXCOORD1 = (half4)uv23;                    // %59 = air.convert.f.v4f16.f.v4f32
```

**精度降低说明**：UV 坐标从 `float` 转为 `half` 传递给 fragment shader。对于标准 0~1 范围的 UV，half 精度（~3 位有效小数）已足够用于纹理寻址。但如果有 tiling/offset 导致 UV > 2048，则可能出现精度问题。

---

### 阶段 4: 法线/切线变换到世界空间 (IR Line 61–149)

这是 vertex shader 中最复杂的部分，将输入的法线和切线变换到世界空间并构建 TBN 矩阵。

#### 4.1 View Direction 计算

```hlsl
// _WorldSpaceCameraPos (offset 112 in UnityPerCamera)
float3 cameraPos = _WorldSpaceCameraPos;                 // %61 = load GEP [0][7]

// viewVec = cameraPos - worldPos (世界空间中从顶点指向相机的向量)
float3 viewVec = cameraPos - worldPos;                   // %62 = fsub %61, %29

// 提取 viewDir 各分量（后面打包进输出的 .w 通道）
half viewDirX = (half)viewVec.x;                         // %64 = fptrunc %63
half viewDirY = (half)viewVec.y;                         // %92 = fptrunc %91
half viewDirZ = (half)viewVec.z;                         // %94 = fptrunc %93
```

**注意**：view direction 在 vertex shader 中**未归一化**。这是一个常见的优化：
- 在 vertex shader 中计算未归一化的 view vector
- 在 fragment shader 中插值后再归一化
- 这样避免了在 vertex shader 中做不必要的 `rsqrt`，且插值后重新归一化更准确

#### 4.2 法线变换（Normal → World Space）

法线变换使用的是 `unity_WorldToObject` 矩阵（逆 M 矩阵）的转置。在这个实现中，shader 通过 dot product 的方式完成了转置乘法：

```hlsl
// 将 half3 法线转为 float3
float3 normalOS = (float3)NORMAL0;                       // %65 = air.convert.f.v3f32.f.v3f16

// 加载 WorldToObject 矩阵的行 0, 1, 2 (它们的 .xyz 是逆 M 矩阵的列)
float4 WtO_row0 = unity_WorldToObject[0];                // %67 = load GEP [1][1][0]
float4 WtO_row1 = unity_WorldToObject[1];                // %73 = load GEP [1][1][1]
float4 WtO_row2 = unity_WorldToObject[2];                // %79 = load GEP [1][1][2]

// 世界法线各分量 = dot(normalOS, WtO_row_i.xyz)
// 这等价于 mul((float3x3)transpose(unity_WorldToObject), normalOS)
half normalWS_x = (half)dot(normalOS, WtO_row0.xyz);    // %69–%70
half normalWS_y = (half)dot(normalOS, WtO_row1.xyz);    // %75–%76
half normalWS_z = (half)dot(normalOS, WtO_row2.xyz);    // %81–%82

half3 normalWS = half3(normalWS_x, normalWS_y, normalWS_z);  // %71,%77,%83
```

**数学原理**：
- 法线变换需要使用 **(M⁻¹)ᵀ** 而非 M 本身
- `unity_WorldToObject` = M⁻¹
- `dot(normal, WorldToObject[i].xyz)` = 对 M⁻¹ 的第 i 行做点积 = (M⁻¹)ᵀ 的第 i 列 × normal
- 这正是法线的正确世界空间变换

#### 4.3 法线归一化

```hlsl
// 计算法线长度平方
half lenSq = dot(normalWS, normalWS);                    // %84 = air.dot.v3f16

// 求逆平方根 (rsqrt)
half invLen = rsqrt(lenSq);                              // %85 = air.rsqrt.f16

// 归一化
half3 normalWS_normalized = normalWS * invLen;           // %88 = fmul %83, splat(%85)
```

#### 4.4 切线变换（Tangent → World Space）

切线使用 **ObjectToWorld 矩阵**（不是逆转置！）进行变换。这与法线不同——切线是方向向量，直接用 M 矩阵变换即可（对于均匀缩放或正交矩阵）：

```hlsl
// 提取 ObjectToWorld 矩阵的转置行（从列中取出对应分量组成行）
// row_x = (M[0].x, M[1].x, M[2].x)  ← 即 M 矩阵第 0 行
float3 M_rowX = float3(M_col0.x, M_col1.x, M_col2.x);  // %95–%100

// 将 TANGENT0.xyz 转为 float3
float3 tangentOS = (float3)TANGENT0.xyz;                 // %102 = air.convert.f.v3f32.f.v3f16

// tangentWS 各分量 = dot(M_row_i, tangentOS)
half tangentWS_x = (half)dot(M_rowX, tangentOS);         // %103–%104
half tangentWS_y = (half)dot(M_rowY, tangentOS);         // %112–%113
half tangentWS_z = (half)dot(M_rowZ, tangentOS);         // %121–%122

half3 tangentWS = half3(tangentWS_x, tangentWS_y, tangentWS_z);  // %105,%114,%123
```

等价于：
```hlsl
float3 tangentWS = mul((float3x3)unity_ObjectToWorld, TANGENT0.xyz);
```

**这里的实现细节**：
- IR 中先从 M 的各列（`M_col0`, `M_col1`, `M_col2`）中抽取对应分量来构造行向量
- 如 `M_rowX = (M_col0[0], M_col1[0], M_col2[0])` 即矩阵第 0 行
- 然后对每行做 dot product，等价于矩阵-向量乘法

#### 4.5 切线归一化

```hlsl
half lenSq_T = dot(tangentWS, tangentWS);                // %124 = air.dot.v3f16
half invLen_T = rsqrt(lenSq_T);                          // %125 = air.rsqrt.f16
half3 tangentWS_normalized = tangentWS * invLen_T;       // %128 = fmul %123, splat(%125)
```

#### 4.6 副切线计算（Bitangent via Cross Product）

副切线通过 **法线 × 切线** 的叉积计算，并乘以 handedness sign：

```hlsl
// cross(normal, tangent) 展开为标量运算：
// bitangent = normal.zxy * tangent.yzx - normal.yzx * tangent.zxy
half3 N_zxy = normalWS_normalized.zxy;                   // %131 = shufflevector <2,0,1>
half3 T_yzx = tangentWS_normalized.yzx;                  // %132 = shufflevector <1,2,0>
half3 N_yzx = normalWS_normalized.yzx;                   // %133 = shufflevector <1,2,0>
half3 T_zxy = tangentWS_normalized.zxy;                  // %134 = shufflevector <2,0,1>

// -N_zxy (取负)
half3 neg_N_zxy = -N_zxy;                                // %135 = fsub 0x8000, %131

// T_yzx * (-N_zxy) → 中间结果
half3 part1 = T_yzx * neg_N_zxy;                         // %136 = fmul %132, %135

// N_yzx * T_zxy + part1 → cross product result
half3 bitangent_raw = fma(N_yzx, T_zxy, part1);          // %137 = air.fma.v3f16
```

等价于：
```hlsl
half3 bitangent_raw = cross(normalWS_normalized, tangentWS_normalized);
```

#### 4.7 Handedness Sign 应用

```hlsl
// 从 TANGENT0.w 取 sign (handedness)
half tangentSign = TANGENT0.w;                           // %138 = extractelement %5, 3

// 从 unity_WorldTransformParams.w 取全局翻转 sign
// (用于处理负缩放的物体)
float flipSign = unity_WorldTransformParams.w;           // %142 = extractelement %141, 3

// 最终 sign = TANGENT0.w * unity_WorldTransformParams.w
float finalSign = flipSign * (float)tangentSign;         // %143 = fmul %142, %139
half finalSign_h = (half)finalSign;                      // %144 = fptrunc

// 将 sign 广播为 vec3 并乘以原始 bitangent
half3 bitangentWS = bitangent_raw * finalSign_h;         // %147 = fmul %137, splat(%144)
```

**Handedness sign 的作用**：
- `TANGENT0.w` 为 +1 或 -1，决定 UV 空间的方向性（右手/左手坐标系）
- `unity_WorldTransformParams.w` 补偿物体有负缩放时的法线翻转
- 两者相乘确保副切线方向始终正确

---

### 阶段 5: 输出组装 (IR Line 150–159)

将所有计算结果打包为最终的 vertex output 结构体：

```hlsl
// Output 结构体定义:
// <{ float4, half4, half4, float3, half4, half4, half4, float4 }>

output[0] = sv_position;         // float4: 带 depth bias 的裁剪空间位置
output[1] = half4(UV0, UV1);     // half4:  TEXCOORD0 + TEXCOORD1 打包
output[2] = half4(UV2, UV3);     // half4:  TEXCOORD2 + TEXCOORD3 打包
output[3] = worldPos;            // float3: 世界空间位置 (全精度)
output[4] = half4(normalWS_normalized.xyz, viewDirX);   // 法线 + viewDir.x
output[5] = half4(tangentWS_normalized.xyz, viewDirY);  // 切线 + viewDir.y
output[6] = half4(bitangentWS.xyz, viewDirZ);           // 副切线 + viewDir.z
output[7] = clipPos;             // float4: 原始裁剪空间位置 (无 bias)
```

**打包策略分析**：
- View direction 的 3 个分量被分散到 TEXCOORD3/4/5 的 `.w` 通道中
- 这是一种常见的 varying 打包优化：利用 TBN 矩阵 3 个向量各自的第 4 分量来"免费"传递额外数据
- 世界空间位置保持 `float3` 全精度（避免光照计算中的精度问题）
- UV 坐标降为 half 精度（对纹理采样足够）

---

## 输出与 Fragment Shader 输入的对应关系

| Vertex Output | Fragment Input | 内容 | 精度 |
|---------------|----------------|------|------|
| `SV_POSITION` | (光栅器使用) | 裁剪空间位置(带 depth bias) | float4 |
| `TEXCOORD0` | `TEXCOORD0` | mainUV (.xy) + auxUV1 (.zw) | half4 |
| `TEXCOORD1` | `TEXCOORD1` | auxUV2 (.xy) + auxUV3 (.zw) | half4 |
| `TEXCOORD2` | `TEXCOORD2` | 世界空间位置 | float3 |
| `TEXCOORD3` | `TEXCOORD3` | normalWS.xyz + viewDir.x | half4 |
| `TEXCOORD4` | `TEXCOORD4` | tangentWS.xyz + viewDir.y | half4 |
| `TEXCOORD5` | `TEXCOORD5` | bitangentWS.xyz + viewDir.z | half4 |
| `TEXCOORD6` | `TEXCOORD6` | 原始 clipPos (屏幕 UV 用) | float4 |

---

## 关键实现特征总结

| 特性 | 实现方式 | 备注 |
|------|----------|------|
| **坐标系** | Camera-Relative Rendering | `worldPos - _WorldSpaceRelativeCameraPos` 后才乘 VP |
| **MVP 分解** | M + VP 分离 | M 在 vertex shader 显式执行，VP 作为整体矩阵 |
| **法线变换** | (M⁻¹)ᵀ via dot products | 数学正确的法线变换方式 |
| **切线变换** | M via dot products | 方向向量直接用 M 变换 |
| **副切线** | cross(N, T) × sign | 运行时计算而非存储，节省 vertex buffer |
| **Depth Bias** | z' = z + |w| × 8e-4 | 微小正向偏移，防止自阴影/Z-fighting |
| **Varying 打包** | viewDir 分散在 TBN.w | 利用第4分量传递额外数据 |
| **精度策略** | 位置/VP 用 float，法线/UV 用 half | 平衡精度与带宽 |
| **骨骼蒙皮** | 无 | 此 shader 假设输入已是最终位置 |
| **归一化** | vertex 中归一化 N 和 T | fragment 中还会重新归一化（因插值）|

---

## 数据流图

```
POSITION0 (float4)
    │
    ▼
┌─────────────────────────────────┐
│ unity_ObjectToWorld (4×4)       │── worldPos (float3) ──┬── output.TEXCOORD2
│ (模型空间 → 世界空间)            │                       │
└─────────────────────────────────┘                       │
                                                          ▼
                                              ┌─────────────────────┐
                                              │ worldPos -           │
                                              │ _WorldSpaceRelative  │
                                              │ CameraPos            │
                                              └──────────┬──────────┘
                                                         │
                                                         ▼ relativePos
                                              ┌─────────────────────┐
                                              │ _ViewProjMatrix(4×4) │
                                              └──────────┬──────────┘
                                                         │
                                                         ▼ clipPos (float4)
                                              ┌─────────────────────┐
                                              │ Depth Bias:          │
                                              │ z += |w| × 8e-4     │
                                              └──────────┬──────────┘
                                                         │
                                                         ├── output.SV_POSITION (biased)
                                                         └── output.TEXCOORD6 (original)

NORMAL0 (half3)                              TANGENT0 (half4)
    │                                             │
    ▼                                             ▼
┌─────────────────┐                   ┌────────────────────┐
│(WorldToObject)ᵀ │                   │ ObjectToWorld(3×3) │
│ (法线正确变换)    │                   │ (方向向量变换)       │
└────────┬────────┘                   └─────────┬──────────┘
         │                                      │
         ▼                                      ▼
    normalize(N_ws)                        normalize(T_ws)
         │                                      │
         ├──────────┐                           │
         │          ▼                           │
         │    cross(N, T) × sign ──── B_ws      │
         │                              │       │
         ▼                              ▼       ▼
    output.TEXCOORD3.xyz         TEXCOORD5.xyz  TEXCOORD4.xyz

_WorldSpaceCameraPos - worldPos = viewVec
         │
         ├── viewVec.x ── output.TEXCOORD3.w
         ├── viewVec.y ── output.TEXCOORD4.w
         └── viewVec.z ── output.TEXCOORD5.w

TEXCOORD0..3 (float2 × 4)
         │
         ▼ convert to half4 pairs
    output.TEXCOORD0 = half4(UV0, UV1)
    output.TEXCOORD1 = half4(UV2, UV3)
```

---

## 性能特征估算

| 指标 | 值 | 说明 |
|------|------|------|
| **ALU 指令** | ~60 条 | FMA/mul/add/dot/rsqrt/cross |
| **纹理采样** | 0 | 纯计算 shader |
| **内存读取** | 3 buffer loads | UnityPerCamera + UnityPerDraw + UnityPerPass |
| **输出 varying** | 8 个 | 4×float4 + 4×half4 ≈ 96 bytes/vertex |
| **寄存器压力** | 低 | 数据流基本线性，无复杂分支 |
| **主要瓶颈** | 带宽 (varying 写入) | 96 bytes/vertex 的 varying 在高多边形场景下有带宽压力 |
| **分支** | 0 | 完全无分支，线性执行 |

---

## 与 Fragment Shader 的协作关系

1. **TBN 矩阵用途**：Fragment shader 将 tangent-space normal map 通过 TBN 矩阵变换到世界空间
2. **View Direction 重建**：Fragment shader 从 TEXCOORD3/4/5 的 `.w` 分量重建 `viewDir = half3(.w, .w, .w)` 并归一化
3. **屏幕空间 UV**：Fragment shader 用 TEXCOORD6 (原始 clipPos) 计算 `screenUV = clipPos.xy / clipPos.w * 0.5 + 0.5`
4. **世界空间位置**：TEXCOORD2 (float3) 用于附加光源的距离衰减和方向计算

---

## 与标准 Unity URP Vertex Shader 的差异

| 方面 | Unity URP Lit | SkinMakeupNew |
|------|--------------|---------------|
| Camera-Relative | 可选（URP 默认关闭） | 始终启用 |
| Depth Bias | 通常在 shadow pass 中 | 在 base pass 中直接应用 |
| Varying 打包 | viewDir 单独输出 | viewDir 分散在 TBN.w 中 |
| 副切线 | 通常 vertex 中计算 | 同（cross × sign） |
| UV 精度 | 通常保持 float | 降为 half |
| Skinning | 支持 4 骨骼 | 无（外部完成） |
| Fog/SH | vertex 中预计算 | 无（全在 fragment 中） |

---

## 编译选项与优化标志

从 IR 属性可以看到：

```
attributes #0 = {
    nounwind optsize memory(none)
    "approx-func-fp-math"="true"      → 允许近似数学函数
    "no-infs-fp-math"="true"          → 假设无 ±∞
    "no-nans-fp-math"="true"          → 假设无 NaN
    "no-signed-zeros-fp-math"="true"  → 忽略 -0.0
    "no-trapping-math"="true"         → 无浮点异常
}
```

同时全局编译选项：
- `air.compile.denorms_disable` → 非规格化数视为 0
- `air.compile.fast_math_disable` → 关闭 Metal fast math（但 LLVM 级别的 fast math 仍启用）
- `air.compile.framebuffer_fetch_enable` → 启用 framebuffer fetch（虽然 VS 不用）
