# Papegame/SkinMakeupNew Fragment Shader — 着色模型完整分析

## 基本信息

| 属性 | 值 |
|------|------|
| **Shader 名称** | `Papegame/SkinMakeupNew` |
| **着色器类型** | Fragment (pixel) shader |
| **入口函数** | `@xlatMtlMain` |
| **Target** | `air64_v24-apple-ios15.0.0` (Apple GPU IR / AIR) |
| **IR 文件** | `SkinMakeupNew_fragment.ll` (1890 行) |
| **源 bitcode** | `ShaderDebugInfo/com.papegames.lysk/61F4807E5636D024_28097/modules/21b9a2299bb9dac99a7a20d403db700be3c80095ce28596ab02955d4d4c3bf5b/module.bc` |
| **Pipeline Address** | `0x7b12d6000` |
| **Pipeline Hex ID** | `C8BD90CE2E67E660` |
| **精度策略** | 大量 `half` (FP16)，仅关键路径使用 `float` (FP32) |

---

## 总体架构

这是一个**角色皮肤 + 化妆系统**的 fragment shader，采用 **修改版 PBR（基于物理的渲染）+ SSS（次表面散射近似）+ 多层化妆叠加** 的混合着色模型。

### 输出

- **SV_TARGET0** (`half4`): `{ finalColor.rgb, alpha }`
- **SV_TARGET1** (`half`): `alpha`（DOF 标记，同 TARGET0.a）

### 计算流程 7 大阶段

1. 纹理采样与化妆层合成
2. 法线重建（Normal Mapping）
3. 视角相关计算
4. 主光源着色（Scene Main Light GGX）
5. 附加光源循环（最多 4 盏）
6. 间接光照 / IBL + 角色专用光
7. 最终合成与输出

---

## 输入资源绑定

### Constant Buffers (7 个)

| 索引 | 类型名 | 参数名 | 大小 | 用途 |
|------|--------|--------|------|------|
| 0 | `AsukaPerShader_AddLightParams_PerCamera_Type` | `AsukaPerShader_AddLightParams_PerCamera` | 2176B | 附加光源数组（最多30盏） |
| 1 | `AsukaPerShader_PerCamera_Type` | `AsukaPerShader_PerCamera` | 144B | 场景主光方向/颜色、全局参数 |
| 2 | `UnityPerCamera_Type` | `UnityPerCamera` | 320B | 相机参数、时间、投影参数 |
| 3 | `UnityPerDraw_Type` | `UnityPerDraw` | 320B | 物体变换矩阵、HDR 参数 |
| 4 | `Character_Param_Type` | `Character_Param` | 112B | 角色专用光照参数 |
| 5 | `UnityPerMaterial_Type` | `UnityPerMaterial` | 336B | 材质参数（化妆颜色/密度等） |
| 6 | `PapePerRendererCB_Type` | `PapePerRendererCB` | 136B | SH 系数、渲染器级别参数 |

### Textures (16 个 texture2d + 1 个 texturecube)

| 索引 | 名称 | 用途 |
|------|------|------|
| 0 | `unity_SpecCube0` | 环境反射 cubemap (IBL) |
| 1 | `_LightIndexMap` | 附加光源索引图 |
| 2 | `_MainTex` | 基础漫射贴图 |
| 3 | `_SpecularTex` | 高光贴图（R=perceptualRoughness, B=specular强度, A=遮罩） |
| 4 | `_NormalTex` | 法线贴图 |
| 5 | `_EyebrowTex` | 眉毛贴图 |
| 6 | `_EyeshadowTex` | 眼影贴图 |
| 7 | `_EyelinerTex` | 眼线贴图 |
| 8 | `_BlusherTex` | 腮红贴图 |
| 9 | `_LipTex` | 口红贴图 |
| 10 | `_DecorateTex` | 装饰贴纸 1 |
| 11 | `_Decorate2Tex` | 装饰贴纸 2 |
| 12 | `_MorphPartTex` | 变形部位贴图 |
| 13 | `_EyelidTex` | 眼睑法线贴图 |
| 14 | `_SSSSkinTexture` | SSS 预积分 LUT |
| 15 | `_ScreenShadowTexture` | 屏幕空间阴影 |

### Samplers (11 个)

`samplerunity_SpecCube0`, `sampler_LightIndexMap`, `sampler_MainTex`, `sampler_SpecularTex`, `sampler_NormalTex`, `sampler_EyeshadowTex`, `sampler_LipTex`, `sampler_MorphPartTex`, `sampler_EyelidTex`, `sampler_SSSSkinTexture`, `sampler_ScreenShadowTexture`

### Fragment Inputs (Varyings)

| 语义 | 类型 | 用途 |
|------|------|------|
| `TEXCOORD0` | `half4` | 主 UV (.xy) + 辅助 UV (.zw) |
| `TEXCOORD1` | `half4` | 腮红 UV (.xy) + 眼线/眼影 UV (.zw) |
| `TEXCOORD2` | `float3` | 世界空间位置 |
| `TEXCOORD3` | `half4` | TBN 矩阵行 1 (tangent, .w = tangent sign) |
| `TEXCOORD4` | `half4` | TBN 矩阵行 2 (bitangent, .w = bitangent sign) |
| `TEXCOORD5` | `half4` | TBN 矩阵行 3 (normal, .w = normal sign) |
| `TEXCOORD6` | `float4` | Clip space position (用于屏幕空间 UV) |

---

## 阶段 1: 纹理采样与化妆层合成 (IR Line 16–315)

### 1.1 基础 UV 坐标

```
mainUV     = TEXCOORD0.xy   → _MainTex, _SpecularTex, _NormalTex, _EyebrowTex 等
auxUV1     = TEXCOORD0.zw   → 腮红 UV
auxUV2     = TEXCOORD1.xy   → 眼影/眼线 UV
auxUV3     = TEXCOORD1.zw   → 另一组辅助 UV
```

### 1.2 化妆层逐层叠加

采用 **Over-blend (Alpha 混合)** 模式，每一层公式：

```hlsl
result = lerp(base, makeupColor * makeupTexture.rgb, makeupTexture.a * density)
// 等价于: result = base + (makeupColor * tex.rgb - base) * tex.a * density
```

#### 叠加层顺序（从底到上）

| 层序 | 纹理 | 颜色参数 | 密度参数 | UV | 说明 |
|------|------|----------|----------|-----|------|
| 0 | `_MainTex` × `_Color` | — | — | mainUV | 基础皮肤色 |
| 1 | `_EyebrowTex` | `_EyebrowColor` (half3) | `_EyebrowDensity` | mainUV | 眉毛 |
| 2 | `_EyeshadowTex` | `_EyeshadowColor` (half3) | `_EyeshadowDensity` | auxUV2 | 眼影 |
| 3 | `_EyelinerTex` | `_EyelinerColor` (half3) | `_EyelinerDensity` | auxUV2 | 眼线 |
| 4 | `_BlusherTex` | `_BlusherColor` (half3) | `_BlusherDensity` | auxUV1 | 腮红 |
| 5 | `_LipTex` | `_LipColor` (half3) | `_LipDensity` | mainUV | 口红 |
| 6 | `_DecorateTex` | `_DecorateColor` (half3) | `_DecorateDensity` | decorateUV | 装饰贴纸1 |
| 7 | `_Decorate2Tex` | `_Decorate2Color` (half3) | `_Decorate2Density` | decorate2UV | 装饰贴纸2 |

#### 口红层的特殊性

口红不仅叠加颜色，还会**修改材质属性**：
- `_LipRoughness` → 覆盖粗糙度
- `_LipSpecular` → 覆盖高光强度
- 这使得嘴唇可以有独立于皮肤的光泽度

#### 装饰贴纸的 UV 变换

```hlsl
decorateUV = mainUV * _DecorateUV.xy + _DecorateUV.zw  // ST 变换
decorate2UV = mainUV * _Decorate2UV.xy + _Decorate2UV.zw
```

### 1.3 MorphPart（变形部位特效）

通过 `_MorphPartTex` + `_MorphPartColor` + `_MorphPartShinningColor` + `_MorphPartSpreadColor` 实现**带呼吸/波浪动画的装饰特效**（如闪烁贴纸、发光纹身等）：

```hlsl
// 球面范围检测
float dist = length(mainUV - _MorphPartTexUV.xy) - _MorphPartTexUV.z;
float mask = smoothstep(0, _MorphPartRange, _MorphPartRange - abs(dist));
// mask 使用 smoothstep: t² * (3 - 2t)

// 最终混合
morphColor = lerp(_MorphPartColor, _MorphPartShinningColor, breathAnim);
result = lerp(result, morphColor, mask * _MorphPartId_control);
```

### 1.4 闪片效果 / Sparkle (IR Line 166–315)

实现**程序化闪片**（用于眼影和口红的 glitter 效果）：

#### 算法流程

```hlsl
// 1. 计算 tile 坐标
float2 tileCoord = UV * sparkleSize;  // sparkleSize 来自 _EyeSparkleSize / _LipSparkleSize
float2 tileFloor = floor(tileCoord);
float2 tileFract = fract(tileCoord);

// 2. 对 4 个相邻 tile 生成随机点位置
for each neighbor tile (i,j) in {(0,0),(1,0),(0,1),(1,1)}:
    // Hash 函数生成伪随机数
    float2 hash_input = tileFloor + float2(i,j);
    float hash = fract((hash_input.x * hash_input.y * 0.4 + (hash_input.x + hash_input.y) * 0.6)
                       * 2627.19 + 5.381);
    float randomOffset = fract(hash * 63.97);

    // 3. 计算到随机点的距离
    float2 delta = tileFract - float2(i,j) - randomOffset;
    float dist2 = dot(delta, delta);

    // 4. 半径检测: sparkleParams.x 是最大半径
    if (sparkleParams.x >= randomOffset):
        // 5. Falloff 计算
        float falloff = max(0, 1 - dist2 * 4);  // 二次衰减
        sparkleAccum += falloff;

// 6. 最终闪片贡献
sparkleColor = sparkleAccum * _MakeupMultiplyColor;
```

#### 闪片参数

| 参数 | 说明 |
|------|------|
| `_EyeSparkleColor` (half4) | 眼部闪片颜色 |
| `_LipSparkleColor` (half4) | 唇部闪片颜色 |
| `_EyeSparkleParams` (half4) | 眼部闪片参数 (.x=半径, .y=密度, .z=?, .w=?) |
| `_LipSparkleParams` (half4) | 唇部闪片参数 |
| `_EyeSparkleSize` (half4) | 眼部闪片 tile 大小 |
| `_LipSparkleSize` (half4) | 唇部闪片 tile 大小 |
| `_EyeSparkle` (half) | 眼部闪片开关/强度 |
| `_LipSparkle` (half) | 唇部闪片开关/强度 |

---

## 阶段 2: 法线重建 (IR Line 318–375)

### 2.1 Normal Map 解码

从 `_NormalTex` 和 `_EyelidTex` 分别读取法线并解码：

```hlsl
// _NormalTex 解码（标准 2-channel normal map）
half2 normalXY = normalTex.xy * 2.0 - 1.0;  // [0,1] → [-1,1]
half normalZ = sqrt(1.0 - saturate(dot(normalXY, normalXY)));
half3 normalA = half3(normalXY, normalZ);

// _NormalTex 的另外两个通道 (.zw) 也解码为第二组法线
half2 normalXY_B = normalTex.zw * 2.0 - 1.0;
half normalZ_B = sqrt(1.0 - saturate(dot(normalXY_B, normalXY_B)));
half3 normalB = half3(normalXY_B, normalZ_B);

// _EyelidTex 解码
half2 eyelidXY = eyelidTex.xy * 2.0 - 1.0;
half eyelidZ = sqrt(1.0 - saturate(dot(eyelidXY, eyelidXY)));
half3 eyelidNormal = half3(eyelidXY, eyelidZ);
```

### 2.2 法线混合

三组法线基于权重混合：

```hlsl
// 第一次 lerp: normalA ↔ eyelidNormal，权重 = eyelidTex.a
half3 blended1 = lerp(normalA, eyelidNormal, eyelidTex.a);

// 第二次 lerp: blended1 ↔ normalB，权重 = _LerpValue（基于眼睛区域检测）
half3 finalTangentNormal = lerp(blended1, normalB, _LerpValue_factor);
```

`_LerpValue` 的确定：
```hlsl
// 基于 TEXCOORD0.x 判断左/右眼区域
float eyeRegionSelect = (TEXCOORD0.x >= 0.5) ? 1.0 : 0.0;
half lerpFactor = _LeftEyeInfo * eyeRegionSelect + _RightEyeInfo * (1 - eyeRegionSelect);
```

### 2.3 TBN 变换（切线空间 → 世界空间）

```hlsl
// 构建 TBN 矩阵
half3 T = normalize(half3(TEXCOORD3.w, TEXCOORD4.w, TEXCOORD5.w));  // tangent
half3 B = TEXCOORD5.xyz;  // bitangent (= normal)
half3 N = TEXCOORD4.xyz;  // stored differently in this shader

// 世界空间法线
half3 worldNormal = normalize(
    finalTangentNormal.x * TEXCOORD4.xyz +   // tangent row
    finalTangentNormal.y * TEXCOORD5.xyz +   // bitangent row
    finalTangentNormal.z * TEXCOORD3.xyz     // normal row
);
```

---

## 阶段 3: 视角相关计算 (IR Line 376–448)

### 3.1 屏幕空间 UV

从 clip space position 重建屏幕 UV：

```hlsl
float2 screenUV;
screenUV.x = TEXCOORD6.x / TEXCOORD6.w;
screenUV.y = TEXCOORD6.y * _ProjectionParams.x / TEXCOORD6.w;  // 翻转 Y
screenUV = screenUV * 0.5 + 0.5;
```

用于采样：
- `_SSSSkinTexture`（皮肤 SSS LUT）
- `_ScreenShadowTexture`（屏幕空间阴影）

### 3.2 View Direction

视线方向从 `TEXCOORD3.w`, `TEXCOORD4.w`, `TEXCOORD5.w` 和 `TEXCOORD2`（世界空间位置）相关数据推导，最终得到归一化的 viewDir。

### 3.3 核心点积

```hlsl
// N·L (主光)
float NdotL_main = max(dot(worldNormal, _MainLightPosition.xyz), epsilon);

// Half vector (主光)
float3 H_main = normalize(_MainLightPosition.xyz + viewDir);
float NdotH_main = dot(worldNormal, H_main);

// N·V
float NdotV = max(dot(worldNormal, viewDir), 0);
```

### 3.4 Roughness 计算（已从 IR 精确验证）

粗糙度来自 `_SpecularTex.r`（高光贴图红通道），并受口红层调制：

```hlsl
// === 步骤 1: 从 _SpecularTex 采样 ===
half4 specTex = sample(_SpecularTex, mainUV);
// specTex.r = perceptualRoughness 基础值
// specTex.b = specular 基础值

// === 步骤 2: 口红层对粗糙度的修改 ===
// lipTex.a 是口红遮罩，_LipRoughness 是口红区域的目标粗糙度
half lipRoughnessBlend = lipTex.a * (_LipRoughness - 1.0) + 1.0;
// 等价于: lerp(1.0, _LipRoughness, lipTex.a)
// 非嘴唇区域 lipTex.a=0 → 乘数=1.0（不变）
// 嘴唇区域 lipTex.a=1 → 乘数=_LipRoughness

// 同理，specular 也被口红修改:
half lipSpecularBlend = lipTex.a * (_LipSpecular - 1.0) + 1.0;

// === 步骤 3: 最终 perceptualRoughness ===
half perceptualRoughness = specTex.r * lipRoughnessBlend;
perceptualRoughness = max(perceptualRoughness, 0.001);  // epsilon clamp (0xH211F ≈ 0.001)

// === 步骤 4: perceptual → linear roughness (α² = perceptualRoughness²) ===
half alpha2 = perceptualRoughness * perceptualRoughness;
alpha2 = max(alpha2, 0.001);  // 再次 clamp

// 注意：GGX 还用了第二个 clamp: max(alpha2, 0.05) 用于 Visibility term
half alpha2_forV = max(alpha2, 0.05);  // 0xH2E66 ≈ 0.05

// === 步骤 5: GGX D term 的分母参数 ===
float invAlpha2 = 1.0 / alpha2;
float roughnessDiff = alpha2 - invAlpha2;  // 用于 D = 1/(NdotH² * roughnessDiff + invAlpha2)
```

**IR 证据** (Line 78–85, 437–447):
```
%103 = load _LipRoughness        (field 43)
%106 = load _LipSpecular         (field 44)
%108 = fadd <_LipRoughness, _LipSpecular>, <-1.0, -1.0>
%109 = splat lipTex.a
%110 = fma(%109, %108, <1.0, 1.0>)    // lerp(1, lipParam, lipAlpha)
%111 = specTex.xz * %110              // half2(roughness, specular)

%463 = %447[0] = max(roughnessBase, 0.001)   // perceptualRoughness
%464 = %463 * %463                            // α²
%469 = max(%464, 0.001)                       // clamped α²
%470 = 1.0 / %469                             // 1/α²
%473 = %469 - %470                            // α² - 1/α² = roughnessDiff
```

**总结**: `_SpecularTex.r` 存储的是皮肤的 perceptual roughness，口红通过 `_LipRoughness × lipTex.a` 对嘴唇区域进行局部修改，使嘴唇可以有独立于皮肤其余部分的光泽度。

---

## 阶段 4: 主光源着色 — Scene Main Light (IR Line 448–530)

### 光源数据来源

来自 `AsukaPerShader_PerCamera` (buffer index 1):
- `_MainLightPosition` (float4, offset 64): 方向光的方向向量
- `_MainLightColor` (half4, offset 80): 光源颜色

### 4.1 GGX Specular Distribution (D term)

```hlsl
// 简化 GGX NDF
float NdotH_clamped = min(NdotH, 0.9999);  // 防止除零
float NdotH2 = NdotH_clamped * NdotH_clamped;

// D = 1 / (NdotH² * (α² - 1/α²) + 1/α²)
float d = NdotH2 * roughnessDiff + invRoughness2;
float D_raw = 1.0 / d;
float D = min(D_raw, 10.0);  // 能量夹紧

// 最终 NDF 贡献
float specNDF = D * D * 0.318;  // 0.318 ≈ 1/π
```

### 4.2 Fresnel (Schlick 近似)

```hlsl
float VdotH = max(dot(viewDir, halfVec), 0.0);
float oneMinusVdotH = 1.0 - VdotH;
float fresnel5 = pow(oneMinusVdotH, 5);  // (1-VdotH)^5

// F = _NonMetalSpecular * (1 - fresnel5) + _FresnelIntensity * fresnel5
// 等价于: F = lerp(_NonMetalSpecular, 1, fresnel5) * intensity_factor
float F = _NonMetalSpecular * (1.0 - fresnel5) + _FresnelIntensity * fresnel5;
```

- `_NonMetalSpecular` = 非金属 F0（通常 0.04 左右）
- `_FresnelIntensity` = 边缘反射强度

### 4.3 Geometry / Visibility Term (Smith-Hammon 近似)

```hlsl
// V = 0.5 / ((NdotL * (1-α²) + α²) * (NdotV * (1-α²) + α²) + epsilon)
float gv1 = NdotL_main * (1.0 - roughness2) + roughness2;
float gv2 = NdotV * (1.0 - roughness2) + roughness2;
float G_denom = gv1 * gv2 + 1e-5;
float V = 0.5 / G_denom;
V = min(V, 10.0);
```

### 4.4 SSS 阴影采样

```hlsl
// 从 _ScreenShadowTexture 采样屏幕空间阴影
half4 shadowTex = sample(_ScreenShadowTexture, screenUV);

// 阴影衰减
half shadowAtten = lerp(1.0, shadowTex.r, _CharShadowIntensity * (1.0 - shadowTex.a));
```

### 4.5 主光源最终着色

```hlsl
// Diffuse
half3 mainDiffuse = NdotL_main * _MainLightColor.rgb * shadowAtten;

// Specular
float specular = specNDF * F * V;
half3 mainSpecular = specular * _MainLightColor.rgb * shadowAtten;
```

---

## 阶段 5: 附加光源循环 (IR Line 529–1129)

### 5.1 光源索引读取

```hlsl
// 从 _LightIndexMap 采样（屏幕空间阴影图）
half4 lightIndexTex = sample(_LightIndexMap, screenUV_adjusted);

// 解码为整数索引 (0-254 有效, 255 = 无光)
float4 lightIndices = floor(lightIndexTex * 255.0 + 0.5);
```

最多 **4 盏附加光源**（RGBA 四个通道各编码一个索引）。

### 5.2 Shadow Weight 预读取

```hlsl
// 从 AddLightParams 的 shadowWeight 数组读取
// 用于衰减阴影中的附加光贡献
half4 shadowWeights;
for each lightIndex i:
    if (lightIndex < 30):
        half4 sw = _AdditionalLightShadowWeight[lightIndex];
        shadowWeights[i] = dot(1.0 - shadowTex, sw);  // 投影到阴影权重
    else:
        shadowWeights[i] = 1.0;  // 无阴影
```

### 5.3 逐光计算（对每盏光重复）

每盏光的完整 BRDF 计算：

```hlsl
// === 光源方向和衰减 ===
float4 lightPosData = _AdditionalLightPosition[idx];
float3 lightVec = lightPosData.xyz + worldPos * lightPosData.w;  // w=0 方向光, w=1 点光
float dist2 = dot(lightVec, lightVec);
float3 lightDir = lightVec * rsqrt(max(dist2, 1e-35));

// 距离衰减
half4 distAtten = _AdditionalLightDistanceAttenuation[idx];
float rangeFactor = dist2 * distAtten.x + 1.0;  // range falloff
float distFalloff = saturate(dist2 * distAtten.y + distAtten.z);  // smooth falloff

// 聚光灯衰减
float3 spotDir = _AdditionalLightSpotDir[idx].xyz;
float spotDot = dot(spotDir, lightDir);
float4 spotAtten = _AdditionalLightSpotAttenuation[idx];
float spotFalloff = saturate(spotDot * spotAtten.x + spotAtten.y);
spotFalloff *= spotFalloff;  // 平方使边缘更锐利

// 最终光照衰减
float lightAtten = distFalloff * spotFalloff / rangeFactor;

// === Diffuse ===
half NdotL_add = max(dot(worldNormal, lightDir), 0.0);
half3 addDiffuse = NdotL_add * _AdditionalLightColor[idx].rgb * lightAtten;

// === Specular (同主光 GGX) ===
float3 H_add = normalize(lightDir + viewDir);
float NdotH_add = max(dot(worldNormal, H_add), 0.0);
float D_add = GGX_D(NdotH_add, roughness);
float F_add = Fresnel_Schlick(VdotH_add, _NonMetalSpecular);
half3 addSpecular = D_add * F_add * _NonMetalSpecular * _AdditionalLightColor[idx].rgb * lightAtten;

// === Sparkle 高光（条件性） ===
if (_AdditionalLightColor[idx].w == -1.0):
    // 这盏光有闪片效果
    float NdotH_sparkle = dot(worldNormal, H_add) * 0.5 + 0.5;
    // 用阶段1中的 sparkle mask 做各向异性高光
    half sparkleSpec = computeSparkleGGX(NdotH_sparkle, sparkleMask, sparkleParams);
    addSpecular += sparkleSpec * _MakeupMultiplyColor * _AdditionalLightColor[idx].rgb;
```

### 5.4 累加与阴影调制

```hlsl
// 每盏光的贡献乘以阴影权重后累加
addLightResult += (addDiffuse + addSpecular) * shadowWeights[i];
```

---

## 阶段 6: 间接光照 / IBL + 角色光 (IR Line 1131–1440)

### 6.1 间接漫射（Spherical Harmonics）

使用 `PapePerRendererCB` 中的 **SH 系数**（`_SHMaps[0..6]` + `_CubeSHs[0..6]`）：

```hlsl
// L0 + L1 项
half3 sh_linear;
sh_linear.x = dot(_SHMaps[0], half4(normal, 1.0));
sh_linear.y = dot(_SHMaps[1], half4(normal, 1.0));
sh_linear.z = dot(_SHMaps[2], half4(normal, 1.0));

// L2 项（球谐的二次项）
half4 normalProducts = half4(normal.y * normal.x, normal.y * normal.z,
                             normal.z * normal.z, normal.x * normal.z);  // 不完全标准
half3 sh_quadratic;
sh_quadratic.x = dot(_SHMaps[3], normalProducts);
sh_quadratic.y = dot(_SHMaps[4], normalProducts);
sh_quadratic.z = dot(_SHMaps[5], normalProducts);

// 合成 + VegColor 修正
half3 irradiance = sh_linear + sh_quadratic;
irradiance += _SHMaps[6].rgb * (normal.x² + normal.y * (normal.y - 1));  // L2 额外项
irradiance = max(irradiance, 0);
```

### 6.2 间接镜面反射（Cubemap IBL）

```hlsl
// 1. 反射方向
half3 reflDir = reflect(-viewDir, worldNormal);

// 2. Mip level（基于粗糙度）
half perceptualRoughness = 1.0 - NdotL;  // 简化映射
half mipLevel = perceptualRoughness * (1.0 - perceptualRoughness * 0.1) * 6.0 + 
                perceptualRoughness² * 6.0;

// 3. 采样 cubemap
half4 envSample = sampleCube(unity_SpecCube0, reflDir, mipLevel);

// 4. HDR 解码 (unity_SpecCube0_HDR)
half alpha_minus_1 = envSample.a - 1.0;
half decoded_exp = max(unity_SpecCube0_HDR.w * alpha_minus_1 + 1.0, 0.0);
half exp_result = exp2(unity_SpecCube0_HDR.y * log2(decoded_exp));
half3 envColor = envSample.rgb * unity_SpecCube0_HDR.x * exp_result;

// 5. 乘以 Fresnel 和阴影因子
half3 indirectSpecular = envColor * _NonMetalSpecular * envBRDF_factor;
```

### 6.3 角色专用光 (Character Light)

**注意：这和阶段4的场景主光源是不同的光！**

数据来源：`Character_Param` (buffer index 4):
- `_CharLightPosition` (float4, offset 0): 角色光方向
- `_CharLightColor` (half4, offset 32): 角色光颜色
- `_CharMainLightColor` (half4, offset 24): 角色主光颜色（区别于场景主光）

```hlsl
// 角色光的 NdotL
float3 charLightDir = _CharLightPosition.xyz;
half charNdotL = max(dot(worldNormal, charLightDir), 0.0);

// 角色光 Diffuse
half3 charDiffuse = charNdotL * _CharLightColor.rgb;

// 角色光 Specular（同样的 GGX）
float3 H_char = normalize(charLightDir + viewDir);
float charNdotH = max(dot(worldNormal, H_char), 0.0);
float charD = GGX_D(charNdotH, roughness);
float charF = Fresnel_Schlick(VdotH_char, _NonMetalSpecular);
half3 charSpecular = charD * charF * _CharMainLightColor.rgb;

// 角色阴影 (SH-based)
half charShadow = lerp(1.0, charShadowFactor, _CharShadowIntensity);
```

这一盏灯的目的是**保证角色（特别是面部和妆容）在任何场景环境下都有稳定美观的打光**，是一种常见的"美术补光"技术。

---

## 阶段 7: 最终合成与输出 (IR Line 1380–1452)

### 7.1 最终颜色合成公式

```hlsl
// 各项贡献
half3 finalColor = 
    // 1. 附加光源贡献（已含 diffuse + specular + sparkle）
    addLightContribution
    
    // 2. 主光 diffuse（含 SSS 色调转移）
    + baseAlbedo * mainLightDiffuse * SSSfactor
    
    // 3. 主光 specular
    + mainSpecular * shadowMask
    
    // 4. 间接漫射
    + irradiance * charShadowColor * albedo
    
    // 5. 间接镜面（IBL 反射）
    + indirectSpecular * envBRDF * _CharShIntensity
    
    // 6. 角色专用光
    + charLightContribution * charShadow
    
    // 7. 闪片高光（主光方向的闪片贡献）
    + sparkleHighlight * shadowMask;
```

### 7.2 SSS / 皮肤次表面散射

SSS 通过预积分的 `_SSSSkinTexture` 实现：

```hlsl
// 从 _SSSSkinTexture 采样（使用屏幕空间 UV）
half4 sssTex = sample(_SSSSkinTexture, screenUV);

// SSS 修正：在阴影区域让颜色偏暖（模拟血液散射）
half3 sssAdjustedAlbedo = baseAlbedo * sssColor_blend;

// sssColor 混合因子由 _ShadowIntensity 控制
half3 shadowedColor = lerp(albedo, albedo * _CharShColor.rgb, _ShadowIntensity);
```

### 7.3 DOF Alpha 输出

```hlsl
// DOF 标记写入 alpha
half dofAlpha = (_DOFBlurFlag - 1.0) * _DOFEnable + 1.0;
// 当 _DOFEnable = 0 时, alpha = 1（不模糊）
// 当 _DOFEnable = 1 时, alpha = _DOFBlurFlag（控制模糊程度）
```

### 7.4 最终输出

```hlsl
output.SV_TARGET0 = half4(finalColor.rgb, dofAlpha);
output.SV_TARGET1 = dofAlpha;  // 同一值写入第二个 RT
```

---

## 着色模型特性总结

| 特性 | 实现方式 | 备注 |
|------|----------|------|
| **BRDF 模型** | 简化 Cook-Torrance (D·F·V) | 非完整版，省略了部分归一化 |
| **Roughness 来源** | `_SpecularTex.r` × lip blend | 口红通过 `_LipRoughness × lipTex.a` 局部修改 |
| **NDF (D)** | GGX 分布，clamped | `D = 1/(NdotH²*(α²-1/α²)+1/α²)`, clamp to 10 |
| **Geometry (G/V)** | Smith-Hammon 近似 | `V = 0.5 / ((NdotL*(1-α²)+α²) * (NdotV*(1-α²)+α²))` |
| **Fresnel (F)** | Schlick 5 次幂 | `F = F0 + (1-F0) * (1-VdotH)^5` |
| **漫射** | Lambertian (NdotL) | 无 Disney diffuse / Oren-Nayar |
| **SSS** | 预积分 LUT (screen-space) | `_SSSSkinTexture` |
| **IBL 漫射** | Spherical Harmonics (L0+L1+L2) | 自定义 SH 系数 from `PapePerRendererCB` |
| **IBL 镜面** | Cubemap + HDR 解码 | `unity_SpecCube0` + `unity_SpecCube0_HDR` |
| **阴影** | 屏幕空间阴影 + 逐光阴影权重 | `_ScreenShadowTexture` + `_AdditionalLightShadowWeight[]` |
| **化妆系统** | 8 层 alpha blend over | 逐层叠加，口红层额外修改材质属性（roughness + specular） |
| **闪片** | 程序化 tile-based 4-sample | Voronoi 近似，hash + 距离衰减 |
| **附加光** | 最多 4 盏，完整 PBR | 支持点光/聚光/方向光 + 距离/角度衰减 |
| **角色光** | 独立于场景的专用补光 | `_CharLightPosition` / `_CharLightColor` |
| **精度** | 大量 half (FP16) | 仅矩阵运算和关键中间结果使用 float |
| **法线混合** | 3 组法线 lerp 混合 | normal + eyelid + secondary，基于眼部区域 |

---

## 光源层次结构

```
最终颜色 = 
  ┌── 直接光照 ──────────────────────────────────────┐
  │  ├─ 场景主光 (_MainLightPosition)                │
  │  │   ├─ Diffuse: NdotL × lightColor × shadow    │
  │  │   └─ Specular: GGX × Fresnel × lightColor    │
  │  │                                                │
  │  ├─ 附加光 ×4 (_AdditionalLight*)                 │
  │  │   ├─ Diffuse + Specular (同上 BRDF)            │
  │  │   ├─ 距离衰减 + 聚光衰减                       │
  │  │   └─ Sparkle 高光（条件性）                     │
  │  │                                                │
  │  └─ 角色光 (_CharLightPosition)                   │
  │      ├─ Diffuse: charNdotL × _CharLightColor     │
  │      └─ Specular: GGX × _CharMainLightColor     │
  └───────────────────────────────────────────────────┘
  
  ┌── 间接光照 ──────────────────────────────────────┐
  │  ├─ SH 漫射 (PapePerRendererCB._SHMaps)         │
  │  └─ Cubemap 镜面 (unity_SpecCube0 + HDR)         │
  └───────────────────────────────────────────────────┘
  
  ┌── 皮肤特效 ──────────────────────────────────────┐
  │  ├─ SSS (_SSSSkinTexture, 暖色阴影)              │
  │  └─ 闪片 (程序化 sparkle)                        │
  └───────────────────────────────────────────────────┘
```

---

## 与标准 Unity URP 的差异

| 方面 | Unity URP 标准 | SkinMakeupNew |
|------|---------------|---------------|
| BRDF | 完整 Cook-Torrance | 简化版（D clamp, 省略部分归一化） |
| 漫射 | Disney / Lambertian | 纯 Lambertian |
| IBL | Unity 内置 | 自定义 SH (Pape) + 标准 cubemap |
| SSS | 无（需自定义） | 有，基于屏幕空间 LUT |
| 化妆 | 无 | 8 层叠加 + 闪片系统 |
| 附加光 | URP light loop | 自定义 index map + 固定 4 盏 |
| 角色光 | 无 | 专用 Character_Param 补光 |
| 精度 | 混合 | 大量 half，针对移动端优化 |

---

## 性能特征估算

- **纹理采样**: 约 20+ 次（16 个不同纹理，部分采样多次）
- **ALU 密集度**: 高（多次 GGX 计算、SH 评估、闪片 hash）
- **分支**: 有条件分支（光源 index < 30 判断、sparkle 开关）
- **寄存器压力**: 高（大量 varying + 中间结果）
- **适合平台**: 移动端高端 GPU (Apple A12+)，FP16 优化明显
