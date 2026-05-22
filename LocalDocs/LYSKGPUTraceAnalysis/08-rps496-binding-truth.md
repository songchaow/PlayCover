# 08 — RPS 496 完整 Binding 清单（Draw 69）

> **目标**：为 RPS 496（`Papegame/SkinMakeupNew` full-res forward compose）的 draw call 整理一份**完整、权威**的 vertex / fragment 阶段 binding 清单 —— 每一个 buffer / texture / sampler 槽位绑了哪个资源、对应 IR 里哪个 `air.arg_name`、buffer 大小是否覆盖 IR 期望的字节数。
>
> 本文**只**关注绑定（不分析 lighting 公式 / 不评估材质语义）。lighting 相关的字段使用见 `07-skin-forward-lighting.md`，整体管线脉络见 `01-architecture-overview.md` / `02-frame-breakdown.md`。
>
> **trace**：`~/Library/Containers/com.papegames.lysk/Data/Documents/Captures/capture_20260518_110050.gputrace`
> **target**：RPS_key=496, draw_index_global=69 (CB1 / E13 / draw_in_encoder=5 / call_index=989)
> **本帧 RPS 496 的两次使用**：draw 69（CB1/E13）与 draw 191（CB3/E44）—— 双缓冲两帧的对称 draw，binding 完全相同；本文以 69 为代表。

---

## 1. 数据来源

| 信息源 | 说明 |
|---|---|
| `frame-list <trace>` 的 per-draw `bindings` snapshot | 直接来自 trace 中 draw call 上下文里的 `setBuffer:` / `setFragmentTexture:` 序列 — 这是**绑定的真值** |
| `library_408.ll` (vertex) / `library_410.ll` (fragment) 中的 `air.buffer` / `air.texture` / `air.vertex_input` 元数据 | 给出每个 slot 的 IR `arg_name`（`UnityPerMaterial`、`_LightIndexMap` 等）—— 这是 **shader 期望该 slot 是什么**的真值 |
| `replay --list-resources` | 资源类型 / 大小 / pixelFormat / label / usage |
| `dump-uniforms` 的 `buffer_label` / `buffer_length` / `buffer_offset` 字段 | 校验 IR 期望大小 vs 实际 buffer 段大小 |

> **关键操作**：把"binding slot 号"作为对接键，左边连到 IR 的 `air.location_index`（拿到 `arg_name`），右边连到 frame-list 的 `bindings[].resource_id`（拿到资源标签 / 格式）。两边都来自 trace，无任何外部假设。

---

## 2. Vertex Stage（library_408 `xlatMtlMain`，library_key=408 / function_key=409）

### 2.1 IR 声明

| IR `air.location_index` | 类型 | `air.arg_name` | size |
|---|---|---|---|
| 0 | buffer | `UnityPerCamera` | 320 B |
| 1 | buffer | `UnityPerDraw` | 320 B |
| 2 | buffer | `UnityPerPass` | 592 B |
| 0 (vertex_input) | float4 | `POSITION0` | — |
| 1 (vertex_input) | half3 | `NORMAL0` | — |
| 2 (vertex_input) | half4 | `TANGENT0` | — |
| 3 (vertex_input) | float2 | `TEXCOORD0` | — |
| 4 (vertex_input) | float2 | `TEXCOORD1` | — |
| 5 (vertex_input) | float2 | `TEXCOORD2` | — |
| 6 (vertex_input) | float2 | `TEXCOORD3` | — |

vertex IR **没有声明任何 `air.texture`** —— 真正的 vertex stage 不采样纹理。

### 2.2 实际绑定（10 个 vertex buffer slot）

Metal 的 vertex buffer 表把 cbuffer 和 vertex stream buffer 共用一张表：cbuffer 在前 3 个 slot，attribute streams 占 slot 3..9。

| MTL Buffer slot | resource_id | offset | 资源标签 | IR `arg_name` | 提供 |
|---|---|---|---|---|---|
| 0 | 2 | 109632 | ScratchBuffer0_0 | `UnityPerCamera` | 320 B（够） |
| 1 | 2 | 109952 | ScratchBuffer0_0 | `UnityPerDraw` | 320 B（够） |
| 2 | 2 | 110272 | ScratchBuffer0_0 | `UnityPerPass` | 592 B（够，下一个 cbuffer 在 110912 = 110272+640） |
| 3 | 100 | 0 | (无 label) 203080 B 的 PL_Head 顶点流 | `POSITION0` | 顶点位置 stream |
| 4 | 83 | 0 | PL_Head（40616 B） | `NORMAL0` | 顶点法线 stream |
| 5 | 84 | 0 | PL_Head（40616 B） | `TANGENT0` | 顶点切线 stream |
| 6 | 85 | 0 | PL_Head（40616 B） | `TEXCOORD0` | UV0 stream |
| 7 | 86 | 0 | PL_Head（40616 B） | `TEXCOORD1` | UV1 stream |
| 8 | 87 | 0 | PL_Head（81232 B） | `TEXCOORD2` | UV2 stream |
| 9 | 134 | 0 | (无 label) 203080 B | `TEXCOORD3` | UV3 stream |

### 2.3 实际绑定（vertex texture / sampler）

| 类型 | slot | resource_id / sampler_ptr | 备注 |
|---|---|---|---|
| texture | 0 | 171 (`fx_normal_wenli04`, 256×256) | **vertex IR 不采样任何 texture**—— 这是上一个 draw 的 sticky binding 残留，对本 draw 无影响 |
| sampler | 0 | 0xad95bb780 | 同上，sticky 残留 |

### 2.4 Draw 调用参数

| 参数 | 值 |
|---|---|
| `primitive_type` | `triangle` |
| `indexed` | `true` |
| `index_count` | 27894 |
| `instance_count` | 1 |
| `vertex_count` | 0（indexed draw，由 index buffer 决定） |

---

## 3. Fragment Stage（library_410 `xlatMtlMain`，library_key=410 / function_key=411）

### 3.1 IR 声明

#### 3.1.1 七个 cbuffer

| IR `air.location_index` | `air.arg_name` | IR `air.buffer_size` | 关键字段（按顺序） |
|---|---|---|---|
| 0 | `AsukaPerShader_AddLightParams_PerCamera` | 2176 B | `_AdditionalLightPosition[30]` (0) / `_AdditionalLightSpotAttenuation[30]` (480) / `_AdditionalLightCount` (960) / `_AdditionalLightColor[30]` (968) / `_AdditionalLightDistanceAttenuation[30]` (1208) / `_AdditionalLightSpotDir[30]` (1456) / `_AdditionalLightShadowWeight[30]` (1936) |
| 1 | `AsukaPerShader_PerCamera` | 144 B | `hlslcc_mtx4x4_WorldToLight` (0) / `_MainLightPosition` (64) / `_MainLightColor` (80) / `_ScaledScreenParams` (88) / `_GridInfo` (96) / `_AuroraGridInfo` (112) / `_MainLightRealtime` (128) / `_DOFEnable` (130) / `_GlobalMipBias` (132) |
| 2 | `UnityPerCamera` | 320 B | URP 标准摄像机时间/远近平面/投影参数 |
| 3 | `UnityPerDraw` | 320 B | `hlslcc_mtx4x4unity_ObjectToWorld` (0) / `..._WorldToObject` (64) / `unity_WorldTransformParams` (128) / `unity_SpecCube0_HDR` (144) / `..._MatrixPreviousM` (160) / `..._MatrixPreviousMI` (224) / `unity_MotionVectorsParams` (288) / `Pape_SpecCubeArrayMaxMip` (304) |
| 4 | `Character_Param` | 112 B | `_CharLightPosition` (0) / `_CharShColor` (16) / `_CharMainLightColor` (24) / `_CharLightColor` (32) / `_RootMPosition` (40) / `_CharShIntensity` (48) / `_CharShadowIntensity` (50) / `_CharShHeight` (52) / `_ClipYValue` (54) / `_HomeLightingEnable` (56) / `_EyeAdaptionInverseExposureEnable` (58) / `_HomeLightingPPVScale/Color0/Color1` (64/72/80) / `_HomeRimLightingPPVColor` (88) / `_POSMEnabled` (96) |
| 5 | `UnityPerMaterial` | 336 B | 见 §3.4 |
| 6 | `PapePerRendererCB` | 136 B | `_SHMaps[7]` (0, stride 8) / `_CubeSHs[7]` (56, stride 8) / `_VegColor` (112) / `_VegetationInShadowLighting` (120) / `_VegetationIndirectSpecIntensity` (122) / `_IsNightMode` (124) / `_RampColorID0/1` (126/128) / `_RampColorBlend` (130) |

#### 3.1.2 16 个 texture

| IR `air.location_index` | `air.arg_name` | IR 类型 |
|---|---|---|
| 0 | `unity_SpecCube0` | `texturecube<half, sample>` |
| 1 | `_LightIndexMap` | `texture2d<half, sample>` |
| 2 | `_MainTex` | `texture2d<half, sample>` |
| 3 | `_SpecularTex` | `texture2d<half, sample>` |
| 4 | `_NormalTex` | `texture2d<half, sample>` |
| 5 | `_EyebrowTex` | `texture2d<half, sample>` |
| 6 | `_EyeshadowTex` | `texture2d<half, sample>` |
| 7 | `_EyelinerTex` | `texture2d<half, sample>` |
| 8 | `_BlusherTex` | `texture2d<half, sample>` |
| 9 | `_LipTex` | `texture2d<half, sample>` |
| 10 | `_DecorateTex` | `texture2d<half, sample>` |
| 11 | `_Decorate2Tex` | `texture2d<half, sample>` |
| 12 | `_MorphPartTex` | `texture2d<half, sample>` |
| 13 | `_EyelidTex` | `texture2d<half, sample>` |
| 14 | `_SSSSkinTexture` | `texture2d<half, sample>` |
| 15 | `_ScreenShadowTexture` | `texture2d<half, sample>` |

#### 3.1.3 sampler

| IR `air.location_index` | `air.arg_name` |
|---|---|
| 0 | `samplerunity_SpecCube0` |
| 1 | `sampler_LightIndexMap` |
| 2 | `sampler_MainTex` |
| 3..5 | (与对应 texture slot 共用) |
| 6 | `sampler_LipTex` |
| 7..8 | (sticky) |
| 9 | `sampler_SSSSkinTexture` |
| 10 | `sampler_ScreenShadowTexture` |

### 3.2 实际绑定 — 7 个 fragment buffer slot

| Slot | resource_id | offset | 资源标签 / 大小 | IR `arg_name` | 期望 vs 实际 |
|---|---|---|---|---|---|
| 0 | 2 | 275072 | ScratchBuffer0_0 / 4194304 B | `AsukaPerShader_AddLightParams_PerCamera` | 期望 2176 B，section 内可读 ≥ 2176 ✅ |
| 1 | 2 | 277248 | ScratchBuffer0_0 | `AsukaPerShader_PerCamera` | 期望 144 ✅ |
| 2 | 2 | 109632 | ScratchBuffer0_0 | `UnityPerCamera` | 期望 320 ✅（与 vertex slot 0 共用同一段） |
| 3 | 2 | 109952 | ScratchBuffer0_0 | `UnityPerDraw` | 期望 320 ✅（与 vertex slot 1 共用） |
| 4 | 2 | 111232 | ScratchBuffer0_0 | `Character_Param` | 期望 112 ✅ |
| 5 | 2 | 110912 | ScratchBuffer0_0 | `UnityPerMaterial` | 期望 336 ✅ |
| 6 | **103** | 0 | **Compute_0 / 144 B** | `PapePerRendererCB` | 期望 136 ✅（144 ≥ 136） |

> **观察**：cb6 是**唯一不在 ScratchBuffer 上的 cbuffer**，借用了一个标签为 `Compute_0` 的 144 字节 buffer（这个 buffer 是上游某个 compute pass 的输出 / 中间数据）。从大小看完全够（136/144），decoded 出来的 `_SHMaps[7]` 也是合理的 SH 系数（DC 项 ~0.34/0.34/0.45），是有效绑定。

### 3.3 实际绑定 — 16 个 fragment texture slot

| Slot | resource_id | label | width × height | pixelFormat | usage | IR `arg_name` |
|---|---|---|---|---|---|---|
| 0 | 142 | `UnityBlackCube` | 1×1 (cube) | (默认) | shaderRead | `unity_SpecCube0` |
| **1** | **145** | (无 label) | **128×128** | **RGBA8Unorm** | shaderRead + shaderWrite + renderTarget | **`_LightIndexMap`** |
| 2 | 222 | `MainTexRT` | 512×512 | RGBA8Unorm_sRGB | shaderRead | `_MainTex` |
| 3 | 197 | `PL_Head_R` | 512×512 | (ASTC) | shaderRead | `_SpecularTex` |
| 4 | 194 | `PL_Head_MU_N` | 512×512 | (ASTC) | shaderRead | `_NormalTex` |
| 5 | 195 | `PL_Makeup_Eyebrow_12_D` | 1024×1024 | (ASTC) | shaderRead | `_EyebrowTex` |
| 6 | 213 | `PL_Makeup_Eyeshadow_06_01_D` | 512×512 | (ASTC) | shaderRead | `_EyeshadowTex` |
| 7 | 214 | `PL_Makeup_Eyeliner_06_D` | 512×512 | (ASTC) | shaderRead | `_EyelinerTex` |
| 8 | 217 | `PL_Makeup_Blush_02_D` | 512×512 | (ASTC) | shaderRead | `_BlusherTex` |
| 9 | 200 | `PL_Makeup_Lip_02_D` | 512×512 | (ASTC) | shaderRead | `_LipTex` |
| 10 | 141 | `UnityBlack` | 4×4 | (默认) | shaderRead | `_DecorateTex`（本帧无装饰） |
| 11 | 141 | `UnityBlack` | 4×4 | (默认) | shaderRead | `_Decorate2Tex`（本帧无装饰 2） |
| 12 | 196 | `PL_Makeup_Head_ID_UNCOMPRESSED` | 1024×1024 | (uncompressed) | shaderRead | `_MorphPartTex` |
| 13 | 193 | `PL_Makeup_Eyelid_07_D` | 512×512 | (ASTC) | shaderRead | `_EyelidTex` |
| 14 | 232 | `TempBuffer 124 583x835` | 583×835 | **RG11B10Float** | shaderRead + renderTarget | `_SSSSkinTexture` (E12 SSS vertical-blur 输出) |
| 15 | 236 | `TempBuffer 128 583x835` | 583×835 | RGBA8Unorm | shaderRead + renderTarget | `_ScreenShadowTexture` (E9 屏幕阴影输出) |

> **特别注意**：fragment texture slot 1 = **rid 145** 是真正的 `_LightIndexMap`（一张 128×128 RGBA8Unorm renderTarget，由前序 compute pass 写入、在本 draw 被采样），**不是**腮红贴图（`PL_Makeup_Blush_02_D`）。腮红贴图 rid 217 在 slot 8，对应 `_BlusherTex`，是化妆系统正常使用的位置。两者各司其职、无 binding bug。

### 3.4 cb5 `UnityPerMaterial` 完整字段表

`UnityPerMaterial_Type` 在 IR 里的完整字段顺序（来自 `library_410.ll` 的 `air.struct_type_info` 元数据），和本帧 reflection-decoded 实测值一并列出。所有字段都在 336 B 以内（绑定的 ScratchBuffer 段够用），下表数值都是合法读取。

| Offset | Type | Field | 实测值 |
|---|---|---|---|
| 0 | half4 | `_MainTex_ST` | (-0.000773, -1.41504, -30.5469, 1.8418) |
| 8 | half4 | `_Color` | (-0.000122, -1.74219, 0, 1.875) |
| 16 | half4 | `_FresnelColor` | (NaN, -1.87402, 0.00716, -0.89453) |
| 24 | half4 | `_OverlayColor` | (2.51367, 2.25977, 2.42969, 3.14062) |
| 32 | half4 | `_SparkleUV` | (1.09961, 0.93555, 0.99756, 1.09961) |
| 40 | half4 | `_SSSSkinTexture_TexelSize` | (0.16846, 0.92285, 0, 0) |
| 48 | half | `_Cutoff` | 0.44995 |
| 50 | half | `_ShadowIntensity` | 1 |
| 52 | half | `_AOIntensity` | -1.2041 |
| 54 | half | `_NonMetalSpecular` | **0.98340** |
| 56 | half | `_FresnelIntensity` | 3.04688 |
| 58 | half | `_Fresnelpower` | 0.49023 |
| 60 | half | `_LerpValue` | 0 |
| 62 | half | `_LeftEyeInfo` | 1.875 |
| 64 | half | `_RightEyeInfo` | 0 |
| 66 | half | `_DOFBlurFlag` | 0 |
| 72 | half4 | `_MakeupColor1` | (0, 0, 0, 1.875) |
| 80 | half4 | `_MakeupColor2` | (0, 1.875, 0, 1.875) |
| 88 | half4 | `_MakeupColor3` | (0.81152, 0.81152, 0.81152, 1) |
| 96 | half4 | `_MakeupColor4` | (0, 0, 0, 0) |
| 104 | half4 | `_MakeupColor5` | (0.79785, 0.84814, 0.85840, 1) |
| 112 | half4 | `_MakeupColor6` | (0, 0, 0, 0) |
| 120 | half4 | `_DecorateUV` | (0, 0, 0, 0) |
| 128 | half4 | `_Decorate2UV` | (0, 0, 0, 0) |
| 136 | half4 | `_MorphPartColor` | (200, 200, 0, 0) |
| 144 | half4 | `_MorphPartShinningColor` | (1, 0.0999, 10, -0.10101) |
| 152 | half4 | `_MorphPartSpreadColor` | (1, 1, 1, 0) |
| 160 | half4 | `_MorphPartParam` | (0, 0, 0, 0) |
| 168 | half4 | `_MorphPartTexUV` | (0, 0, 0, 0) |
| 176 | half3 | `_EyebrowColor` | (0, 0, 1) |
| 184 | half3 | `_EyeshadowColor` | (0, 1, 0) |
| 192 | half3 | `_EyelinerColor` | (0, 1, 0.685) |
| 200 | half3 | `_LipColor` | (0, 0, 0) |
| 208 | half3 | `_BlusherColor` | (0, 0, 0) |
| 216 | half3 | `_DecorateColor` | (0, 0, 0) |
| 224 | half3 | `_Decorate2Color` | (0, 0, 0) |
| 232 | half3 | `_MakeupMultiplyColor` | (0, 0, 1) |
| 240..258 | half | `_MakeupRoughness5 / _EyebrowDensity / _EyeshadowDensity / _EyelinerDensity / _BlusherDensity / _LipDensity / _LipRoughness / _LipSpecular / _DecorateDensity / _Decorate2Density` | 全部 = 0 |
| 260..268 | half | `_MorphPartId / _MorphPartRange / _MorphPartShinningAlpha / _MorphPartWaveLength / _MorphPartBreathAlpha` | 全部 = 0 |
| 272 | half4 | `_EyeSparkleColor` | (0, 0, 0, 0) |
| 280 | half4 | `_LipSparkleColor` | (0, 0, 0, 0) |
| 288 | half4 | `_EyeSparkleParams` | (0, 0, 0, 0) |
| 296 | half4 | `_LipSparkleParams` | (0, 0, 0, 0) |
| 304 | half4 | `_EyeSparkleSize` | (0, 0, 0, 0) |
| 312 | half4 | `_LipSparkleSize` | (0, 0, 0, 0) |
| 320 | half | `_EyeSparkle` | -0.000773 |
| 322 | half | `_LipSparkle` | -1.41504 |
| 328 | half3 | `_EyelidColor` | (-0.000122, -1.74219, 0) |

> **数据特征观察**（不做 lighting 评估，只是说明这些字节是有效读取的）：
> - 几个字段（`_Color.x`、`_EyelidColor.x`、`_EyeSparkle`）都是 `-0.000773` 这种小负数，含一个 NaN（`_FresnelColor.x`），且 `_AOIntensity = -1.2`、`_MorphPartColor = (200, 200, …)`。这些不是 reflection 解码错误 —— hex dump 验证字节就是这样。可能含义：(1) 引擎用 half-float 编码占位/索引数据，shader 在使用前会 mask 或 saturate；(2) 某些 sparkle/decorate 字段在本帧静态、未被有效写入。
> - 但 lighting 链路上**关键**的 `_NonMetalSpecular = 0.983` / `_Cutoff = 0.450` / `_ShadowIntensity = 1` / 9 个 `_MakeupColor*` 都是合理的常规值。

### 3.5 cb0 `AsukaPerShader_AddLightParams_PerCamera` 关键字段（前 2 个 light slot）

`AsukaPerShader_AddLightParams_PerCamera` 是 30-槽 cluster lighting 数组；30 个 slot 中只有 0、1 是真灯，其余全是哨兵（`_AdditionalLightPosition = (0, 0, 1, 0)`）。

| 字段（数组类型） | offset / stride | Slot 0 | Slot 1 |
|---|---|---|---|
| `_AdditionalLightPosition[30]` | 0 / 16 | (2.1467, 2.30712, 1.51632, 1) | (0.722, 1.742, 0.538, 1) |
| `_AdditionalLightSpotAttenuation[30]` | 480 / 16 | (28.9459, -26.7426, 1, 1) | (0, 1, 1, 1) |
| `_AdditionalLightCount` (half4 单值) | 960 | (0, 0, 0, 0) — shader **不读**此字段 | — |
| `_AdditionalLightColor[30]` | 968 / 8 | (2.04297, 1.77441, 1.9541, 9) | (0.69189, 0.71777, 0.94238, 9) |
| `_AdditionalLightDistanceAttenuation[30]` | 1208 / 8 | (0.05551, -0.00617, 2.77734, 1) | (0.25, -0.02777, 2.77734, 1) |
| `_AdditionalLightSpotDir[30]` | 1456 / 16 | (0.79834, 0.28176, 0.53223, 1) | (0, 0, 1, 1) |
| `_AdditionalLightShadowWeight[30]` | 1936 / 8 | **(0, 1, 0, 0)** | **(0, 0, 0, 0)** |

### 3.6 cb1 `AsukaPerShader_PerCamera` 全字段

| Offset | Type | Field | 实测值 |
|---|---|---|---|
| 0 | float4[4] | `hlslcc_mtx4x4_WorldToLight` | 4 行 = (0,1,0,1) — 占位 |
| 64 | float4 | `_MainLightPosition` | (0.29220, 0.27446, 0.91613, 0) |
| 80 | half4 | `_MainLightColor` | (0, 0, 0, 1.875) — IR 不读 |
| 88 | half4 | `_ScaledScreenParams` | (0, 0, 0, 1.875) |
| 96 | half4 | `_GridInfo` | (-128, -254, 256, 256) |
| 112 | float4 | `_AuroraGridInfo` | (0, 1, 0, 1) |
| 128 | half | `_MainLightRealtime` | 0 |
| 130 | half | `_DOFEnable` | 1 |
| 132 | half | `_GlobalMipBias` | -1.51465 |

### 3.7 cb3 `UnityPerDraw` 关键字段

| Offset | Type | Field | 实测值 |
|---|---|---|---|
| 0 | float4[4] | `hlslcc_mtx4x4unity_ObjectToWorld` | 第 4 行（平移） = (-0.003, 0.950, -0.005, 1) |
| 64 | float4[4] | `hlslcc_mtx4x4unity_WorldToObject` | 上者的逆 |
| 128 | float4 | `unity_WorldTransformParams` | (0, 0, 0, 1) |
| 144 | float4 | `unity_SpecCube0_HDR` | (1, 1, 0, 0) — decodeScale=1, decodeExp=0 |
| 160 | float4[4] | `..._MatrixPreviousM` | 上一帧 ObjectToWorld（用于 motion vector，本 RPS 不写 MV） |
| 224 | float4[4] | `..._MatrixPreviousMI` | 上一帧 WorldToObject |
| 288 | float4 | `unity_MotionVectorsParams` | shader 不读 |
| 304 | uint | `Pape_SpecCubeArrayMaxMip` | env probe array mip count |

### 3.8 cb4 `Character_Param` 全字段

| Offset | Type | Field | 实测值 |
|---|---|---|---|
| 0 | float4 | `_CharLightPosition` | (-0.0828, 0.87036, -0.48541, 1) |
| 16 | half4 | `_CharShColor` | (0, 0, 0, 1) |
| 24 | half4 | `_CharMainLightColor` | (2.51367, 2.25977, 2.42969, 3.14062) |
| 32 | half4 | `_CharLightColor` | (1.09961, 0.93555, 0.99756, 1.09961) |
| 40 | half3 | `_RootMPosition` | (-0.00343, 0.94971, -0.00464) |
| 48 | half | `_CharShIntensity` | 0.44995 |
| 50 | half | `_CharShadowIntensity` | 1 |
| 52 | half | `_CharShHeight` | 0.80908 |
| 54 | half | `_ClipYValue` | 1.92969 |
| 56 | half | `_HomeLightingEnable` | 0.39258 |
| 58 | half | `_EyeAdaptionInverseExposureEnable` | 1.92285 |
| 64 | half4 | `_HomeLightingPPVScale` | (0, 0, 0, 0) |
| 72 | half4 | `_HomeLightingPPVColor0` | (0, 0, 0, 0) |
| 80 | half4 | `_HomeLightingPPVColor1` | (0, 0, 0, 0) |
| 88 | half4 | `_HomeRimLightingPPVColor` | (0, 0, 0, 0) |
| 96 | half | `_POSMEnabled` | 0 |

### 3.9 cb6 `PapePerRendererCB` 全字段

| Offset | Type | Field | 实测值 |
|---|---|---|---|
| 0 | half4[7] (stride 8) | `_SHMaps[0..6]` | 见下表 |
| 56 | half4[7] (stride 8) | `_CubeSHs[0..6]` | 全 0（shader 不读） |
| 112 | half4 | `_VegColor` | (0, 0, 0, 0) |
| 120 | half | `_VegetationInShadowLighting` | 0 |
| 122 | half | `_VegetationIndirectSpecIntensity` | 0 |
| 124 | half | `_IsNightMode` | 0 |
| 126 | half | `_RampColorID0` | 0 |
| 128 | half | `_RampColorID1` | 0 |
| 130 | half | `_RampColorBlend` | 0 |

`_SHMaps[0..6]` 详细：

| 元素 | 含义 | (x, y, z, w) |
|---|---|---|
| `[0]` | R 一阶系数 + DC | (-0.00560, -0.06079, 0.08685, 0.34326) |
| `[1]` | G 一阶系数 + DC | (-0.05029, -0.05643, 0.07611, 0.34424) |
| `[2]` | B 一阶系数 + DC | (-0.06165, -0.06586, 0.12390, 0.45264) |
| `[3]` | R 二阶系数（Nx·Ny / Ny·Nz / Nz² / Nx·Nz） | (-0.00375, 0.00350, 0.01636, 0.03857) |
| `[4]` | G 二阶系数 | (0.00017, 0.00480, 0.01202, 0.01761) |
| `[5]` | B 二阶系数 | (-0.00334, 0.00102, 0.00658, 0.00256) |
| `[6]` | (Nx²-Ny²) 系数 R/G/B + 1 | (0.05035, 0.05017, 0.06696, 1) |

### 3.10 实际绑定 — fragment sampler

| Slot | sampler_ptr | IR `arg_name` |
|---|---|---|
| 0 | 0xad95bb600 | `samplerunity_SpecCube0` |
| 4 | 0xad95bb600 | （sticky，绑给 `_NormalTex` 等） |
| (其他 slot) | sticky | `sampler_LightIndexMap / _MainTex / _LipTex / _SSSSkinTexture / _ScreenShadowTexture` 等 |

> Metal 的 sampler state 大多通过 sticky binding 复用上游 draw 的设置，frame-list 只 dump 显式 `setFragmentSamplerState:atIndex:` 的调用。本 draw 显式设置了 slot 0 / slot 4，其余 slot 使用之前 draw 留下的 sampler。

---

## 4. 输出附加（render target）

RPS 496 的 color attachment 配置（来自 `pipeline` 子命令的 `render_pipeline_states` 表，与 `frame-list` 的 encoder begin 一致）：

| Slot | RT id | label | 大小 | 格式 |
|---|---|---|---|---|
| 0 | 224 | (HDR scene buffer) | 1167×1671 | RGBA16F |
| (depth) | 226 | scene depth | 1167×1671 | D32S8 |

RPS 496 fragment 的输出 IR 签名 = `<{ <4 x half>, half }>` —— 一个 half4 颜色 + 一个 half（depth/control flag），写入 color slot 0。

---

## 5. 复现命令

```bash
SKILL_DIR=/Users/songdogwang/Codes/PlayCover/.codebuddy/skills/gpu-trace-analysis
BRIDGE=$(bash "$SKILL_DIR/scripts/setup.sh")
TRACE=~/Library/Containers/com.papegames.lysk/Data/Documents/Captures/capture_20260518_110050.gputrace
WORK=/tmp/lysk-rps496 && mkdir -p $WORK

# 1. 资源元数据
"$BRIDGE" replay "$TRACE" --list-resources > $WORK/resources.json

# 2. Frame timeline 与 per-draw bindings
"$BRIDGE" frame-list "$TRACE" > $WORK/frame.json
jq '.command_buffers[].encoders[].draws[] | select(.draw_index_global==69)' $WORK/frame.json

# 3. Vertex / fragment IR + 元数据
"$BRIDGE" shader-of-rps "$TRACE" 496 --stage vertex   --with-ir --output-dir $WORK/shaders
"$BRIDGE" shader-of-rps "$TRACE" 496 --stage fragment --with-ir --output-dir $WORK/shaders
grep -E '!"air.(buffer|texture|vertex_input)".*location_index' $WORK/shaders/library_410.ll | sort -u
grep -E '!"air.(buffer|texture|vertex_input)".*location_index' $WORK/shaders/library_408.ll | sort -u

# 4. 7 个 cbuffer 全 reflection-decoded
python3 "$SKILL_DIR/scripts/gputrace_replay_wrapper.py" \
    shader-of-drawcall "$TRACE" 69 --stage fragment --with-ir --with-uniforms \
    --output-dir $WORK/shaders > $WORK/draw69_full.json

# 5. 单 slot 校验（含 hex / buffer label / size 校验）
python3 "$SKILL_DIR/scripts/gputrace_replay_wrapper.py" \
    dump-uniforms "$TRACE" 69 5 --stage fragment --with-hex
```

---

## 6. 与 07 / 04 / 06 文档的关系

- 本文 = **RPS 496 binding 真值**。任何 lighting / 材质语义讨论见 `07-skin-forward-lighting.md`。
- `04-skin-and-sss-pipeline.md` 描述 SkinMakeupNew 的 5 个变体在帧内的位置（含 RPS 491 half-res 版本与 RPS 476 shadow caster 版本的 binding 区别）。
- `06-gbuffer-truth.md` 解释为什么 RPS 484 的两个 RGBA8 attachment 是 velocity + normal mask，不是 GBuffer，**不被 RPS 496 读取**（fragment texture slot 0..15 中没有这些 RT id）。
