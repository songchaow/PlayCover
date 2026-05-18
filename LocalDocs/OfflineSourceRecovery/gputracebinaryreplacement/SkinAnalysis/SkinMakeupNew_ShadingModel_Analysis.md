# SkinMakeupNew fragment shader 分析

> 输入文件：`LocalDocs/OfflineSourceRecovery/gputracebinaryreplacement/SkinMakeupNew_fragment.ll`  
> 重点元数据：`SkinMakeupNew_fragment.ll:1798` 的 `UnityPerMaterial_Type` 布局  
> 分析对象：`xlatMtlMain` fragment 函数，Metal AIR LLVM IR 形式

## 1. 结论概览

`SkinMakeupNew_fragment.ll` 不是原始 HLSL/MSL，而是 Metal AIR LLVM IR。`1798` 行本身不是 shader 主逻辑，而是 `UnityPerMaterial_Type` 的反射/布局元数据，描述材质常量缓冲区里各个属性的名称、偏移、类型和数组信息。真正的片元着色逻辑位于 `xlatMtlMain`，大约从 `15` 行到 `1452` 行。

这个 shader 是一个高度定制的角色皮肤 shader，整体 shading model 不是简单的 Unity Standard，也不是严格物理皮肤 BSSRDF，而是一个面向角色渲染的混合模型：

1. 基础色：`_MainTex * _Color`。
2. 妆容：眉毛、眼影、眼线、腮红、唇妆、装饰贴花、额外装饰贴花逐层合成。
3. 法线：`_NormalTex` 与 `_EyelidTex` 解码并混合，然后通过 TBN 转到 world space。
4. 直接光：主角色光 + 由 `_LightIndexMap` 索引的最多 4 个 additional lights。
5. 阴影：`_ScreenShadowTexture` 屏幕空间阴影贴图参与主光和额外光阴影衰减。
6. 漫反射/皮肤柔化：`_SSSSkinTexture` 以 screen UV 采样，用于皮肤散射/柔光后的 diffuse 调制。
7. 高光：GGX microfacet NDF + Schlick Fresnel，roughness/specular 由 `_SpecularTex`、唇部参数、非金属 specular 参数调制。
8. 间接光：SH/Probe 风格环境漫反射 + `unity_SpecCube0` cubemap 环境反射。
9. 特效：eye/lip sparkle，morph part wave/breath/shining，decorate 贴花。
10. 输出：`SV_TARGET0 = half4(finalColor.rgb, dofMask)`，`SV_TARGET1 = dofMask`。

可以用一个高层公式概括：

\[
C_{final}
=
C_{additionalLights}
+
C_{mainCharLight}
+
C_{indirectDiffuse}
+
C_{envSpecular}
+
C_{SSS/diffuse}
+
C_{sparkle/morph}
\]

其中皮肤的“肉感”主要不是在 fragment 内做真实多层随机游走或 dipole diffusion，而是依赖 `_SSSSkinTexture` 这类屏幕空间/预计算贴图，将柔化后的皮肤光照或散射结果乘回到合成后的皮肤 albedo 上。

---

## 2. 文件与入口函数

IR 开头显示这是 `xlatMtlMain` 编译产物：

- `source_filename = "xlatMtlMain"`
- `target triple = "air64_v24-apple-ios15.0.0"`
- `!air.fragment = !{!14}`
- `!14 = !{ptr @xlatMtlMain, ...}`

入口函数签名返回：

```llvm
<{ <4 x half>, half }>
```

这说明 fragment 输出两个 render target：

- 第一个：`half4`，对应 `SV_TARGET0`。
- 第二个：`half`，对应 `SV_TARGET1`。

元数据中也明确了：

- `SV_TARGET0`: `half4`
- `SV_TARGET1`: `half`

最后返回处：

```llvm
%1416 = insertvalue <{ <4 x half>, half }> undef, <4 x half> %1415, 0
%1417 = insertvalue <{ <4 x half>, half }> %1416, half %1414, 1
ret <{ <4 x half>, half }> %1417
```

其中：

- `%1415` 是最终 `half4` 颜色。
- `%1414` 同时写入 `SV_TARGET0.a` 与 `SV_TARGET1`，看起来是 DOF/后处理 mask，不是普通透明度。

---

## 3. 重要 uniform buffer 与资源

### 3.1 `AsukaPerShader_AddLightParams_PerCamera`

元数据 `!20` 描述 additional light 数据：

- `_AdditionalLightPosition`
- `_AdditionalLightSpotAttenuation`
- `_AdditionalLightCount`
- `_AdditionalLightColor`
- `_AdditionalLightDistanceAttenuation`
- `_AdditionalLightSpotDir`
- `_AdditionalLightShadowWeight`

该 buffer 被用于 `_LightIndexMap` 解出的 light index，从数组里取每盏灯的位置、颜色、距离衰减、spot 参数和 shadow 权重。

### 3.2 `AsukaPerShader_PerCamera`

元数据 `!22` 包含：

- `hlslcc_mtx4x4_WorldToLight`
- `_MainLightPosition`
- `_MainLightColor`
- `_ScaledScreenParams`
- `_GridInfo`
- `_AuroraGridInfo`
- `_MainLightRealtime`
- `_DOFEnable`
- `_GlobalMipBias`

这里的 `_MainLightPosition` / `_MainLightColor` 参与主角色光；`_DOFEnable` 参与最终 alpha/第二 render target；`_GlobalMipBias` 用于部分纹理采样 mip bias。

### 3.3 `UnityPerCamera`

包含常见 Unity 相机参数：

- `_WorldSpaceCameraPos`
- `_WorldSpaceCameraDir`
- `_ProjectionParams`
- `_ScreenParams`
- `_ZBufferParams`
- `_EyeAdaptionExposure`
- `_EyeAdaptionInverseExposure`
- `_ReflectNormalBias`
- `_FrameCount8`

其中 `_ScreenParams` / clip position 用于 screen UV；相机位置/方向用于 view vector 和 Fresnel/specular。

### 3.4 `UnityPerDraw`

包含：

- `unity_ObjectToWorld`
- `unity_WorldToObject`
- `unity_SpecCube0_HDR`
- previous matrix
- `Pape_SpecCubeArrayMaxMip`

其中 `unity_SpecCube0_HDR` 用于 decode cubemap 反射；`Pape_SpecCubeArrayMaxMip` 或相关参数参与 roughness 到 mip 的映射。

### 3.5 `Character_Param`

包含角色全局光照参数：

- `_CharLightPosition`
- `_CharShColor`
- `_CharMainLightColor`
- `_CharLightColor`
- `_RootMPosition`
- `_CharShIntensity`
- `_CharShadowIntensity`
- `_CharShHeight`
- `_ClipYValue`
- `_HomeLightingEnable`
- `_EyeAdaptionInverseExposureEnable`
- `_HomeLightingPPVScale`
- `_HomeLightingPPVColor0`
- `_HomeLightingPPVColor1`
- `_HomeRimLightingPPVColor`
- `_POSMEnabled`

这些不是标准 Unity Lit 参数，而是角色/场景定制的角色光、阴影、home lighting、PPV 色彩调制等。

### 3.6 `UnityPerMaterial`

`1798` 行的核心内容就是材质参数布局。按功能分组如下。

#### 基础贴图/颜色

- `_MainTex_ST`
- `_Color`
- `_FresnelColor`
- `_OverlayColor`
- `_SparkleUV`
- `_SSSSkinTexture_TexelSize`

#### 基础 shading 参数

- `_Cutoff`
- `_ShadowIntensity`
- `_AOIntensity`
- `_NonMetalSpecular`
- `_FresnelIntensity`
- `_Fresnelpower`
- `_LerpValue`
- `_LeftEyeInfo`
- `_RightEyeInfo`
- `_DOFBlurFlag`

注意：某些参数存在于布局中，但在当前编译变体里可能没有被实际使用，或者被优化折叠。例如 `_FresnelColor`、`_FresnelIntensity`、`_Fresnelpower` 在当前 IR 主逻辑中没有明显直接读取路径。

#### 妆容颜色

- `_MakeupColor1` 到 `_MakeupColor6`
- `_EyebrowColor`
- `_EyeshadowColor`
- `_EyelinerColor`
- `_LipColor`
- `_BlusherColor`
- `_DecorateColor`
- `_Decorate2Color`
- `_MakeupMultiplyColor`
- `_EyelidColor`

#### 妆容强度与唇部 specular

- `_MakeupRoughness5`
- `_EyebrowDensity`
- `_EyeshadowDensity`
- `_EyelinerDensity`
- `_BlusherDensity`
- `_LipDensity`
- `_LipRoughness`
- `_LipSpecular`
- `_DecorateDensity`
- `_Decorate2Density`

#### morph part 特效

- `_DecorateUV`
- `_Decorate2UV`
- `_MorphPartColor`
- `_MorphPartShinningColor`
- `_MorphPartSpreadColor`
- `_MorphPartParam`
- `_MorphPartTexUV`
- `_MorphPartId`
- `_MorphPartRange`
- `_MorphPartShinningAlpha`
- `_MorphPartWaveLength`
- `_MorphPartBreathAlpha`

#### sparkle 特效

- `_EyeSparkleColor`
- `_LipSparkleColor`
- `_EyeSparkleParams`
- `_LipSparkleParams`
- `_EyeSparkleSize`
- `_LipSparkleSize`
- `_EyeSparkle`
- `_LipSparkle`

---

## 4. 纹理资源

元数据列出的纹理：

1. `unity_SpecCube0`：环境反射 cubemap。
2. `_LightIndexMap`：屏幕空间/cluster 风格 light index map。
3. `_MainTex`：基础皮肤颜色。
4. `_SpecularTex`：roughness/specular mask 数据。
5. `_NormalTex`：法线贴图，疑似 packed normal。
6. `_EyebrowTex`：眉毛妆容。
7. `_EyeshadowTex`：眼影。
8. `_EyelinerTex`：眼线。
9. `_BlusherTex`：腮红。
10. `_LipTex`：唇妆。
11. `_DecorateTex`：装饰贴花。
12. `_Decorate2Tex`：第二装饰贴花。
13. `_MorphPartTex`：morph part 特效贴图。
14. `_EyelidTex`：眼睑贴图，参与 normal/颜色。
15. `_SSSSkinTexture`：屏幕空间皮肤散射/柔化结果。
16. `_ScreenShadowTexture`：屏幕空间阴影贴图。

这些资源说明 shader 的核心不是单一 BRDF，而是“贴图分层 + 屏幕空间光照缓存 + 定制 PBR specular”的组合。

---

## 5. Varying / fragment input 推断

元数据列出：

- `TEXCOORD0`: `half4`
- `TEXCOORD1`: `half4`
- `TEXCOORD2`: `float3`
- `TEXCOORD3`: `half4`
- `TEXCOORD4`: `half4`
- `TEXCOORD5`: `half4`
- `TEXCOORD6`: `float4`

结合使用方式推断：

- `TEXCOORD0.xy`：主 UV。
- `TEXCOORD0.zw`：额外 UV 或 normal/makeup UV。
- `TEXCOORD1.xy/zw`：妆容 UV、decorate/morph UV。
- `TEXCOORD2`：world position 或 view/light 计算用 position。
- `TEXCOORD3-5`：TBN basis 或 tangent/world normal 打包。
- `TEXCOORD6`：clip/screen position，用于 `_LightIndexMap`、`_SSSSkinTexture`、`_ScreenShadowTexture`。

---

## 6. 基础采样与早期参数处理

函数开头采样 `_SpecularTex`、`_MainTex` 与若干妆容贴图。

### 6.1 `_SpecularTex`

`_SpecularTex` 以 `TEXCOORD0.xy` 采样，之后取了 r/b 两个通道：

- `r`：roughness-like。
- `b`：specular mask-like。

这两个通道后续会被唇部参数调制。

### 6.2 `_MainTex`

`_MainTex` 以主 UV 采样，并与 `_Color` 相乘。可抽象为：

```c
half4 mainTex = _MainTex.Sample(sampler_MainTex, uv);
half3 base = mainTex.rgb * _Color.rgb;
```

### 6.3 左右眼/眼睑控制

开头有对 `TEXCOORD0.x`、`TEXCOORD0.y` 与 `_LeftEyeInfo`、`_RightEyeInfo` 的判断和插值。大致表现为：

- 根据输入坐标判断当前 fragment 是否处于某个眼部区域。
- 选择 `_LeftEyeInfo` 或 `_RightEyeInfo`。
- 该值后续影响眼睑 normal 或眼部相关混合。

---

## 7. 妆容层合成

妆容合成集中在中后段，大致可拆成以下层：

1. 眉毛 `_EyebrowTex`
2. 眼影 `_EyeshadowTex`
3. 眼线 `_EyelinerTex`
4. 腮红 `_BlusherTex`
5. 唇妆 `_LipTex`
6. 装饰 `_DecorateTex`
7. 第二装饰 `_Decorate2Tex`
8. morph part `_MorphPartTex`
9. eyelid `_EyelidTex`

整体合成模式大量使用 `fma`，对应 HLSL/MSL 中常见的：

```c
result = lerp(a, b, mask);
// 编译后常变成：fma(mask, b - a, a)
```

### 7.1 典型 layer 公式

对于多数彩妆层，形式类似：

\[
C_{out} = lerp(C_{in}, C_{layer}, mask)
\]

其中：

\[
mask = Texture.a \times Density
\]

\[
C_{layer} = Texture.rgb \times LayerColor
\]

某些层还会乘 `_MakeupMultiplyColor` 或使用基础 skin 色作为 blend base。

### 7.2 眉毛

眉毛贴图 `_EyebrowTex` 使用对应 UV 采样，颜色由 `_EyebrowColor` 调制，alpha 与 `_EyebrowDensity` 形成混合权重：

\[
mask_{eyebrow}=EyebrowTex.a\cdot \_EyebrowDensity
\]

\[
C=lerp(C, EyebrowTex.rgb\cdot \_EyebrowColor, mask_{eyebrow})
\]

### 7.3 眼影

眼影 `_EyeshadowTex` 类似，但常见地会使用 `_MakeupMultiplyColor` 做统一妆容色调乘法：

\[
mask_{eyeshadow}=EyeshadowTex.a\cdot \_EyeshadowDensity
\]

\[
C=lerp(C, EyeshadowTex.rgb\cdot \_EyeshadowColor\cdot \_MakeupMultiplyColor, mask_{eyeshadow})
\]

### 7.4 眼线

眼线 `_EyelinerTex` 与 `_EyelinerColor`、`_EyelinerDensity` 合成：

\[
C=lerp(C, EyelinerTex.rgb\cdot \_EyelinerColor, EyelinerTex.a\cdot \_EyelinerDensity)
\]

### 7.5 腮红

腮红有更明显的 tint/multiply 特征。可近似理解为：

\[
blushTint = lerp(1, BlusherTex.rgb\cdot \_BlusherColor, BlusherTex.a\cdot \_BlusherDensity)
\]

\[
C = C \cdot blushTint
\]

也可能在 IR 中被写成嵌套 `fma`，但视觉上相当于用腮红贴图对皮肤进行颜色染色，而不是完全覆盖。

### 7.6 唇妆

唇妆 `_LipTex` 不仅影响 albedo，还会影响 specular 参数：

\[
mask_{lip}=LipTex.a\cdot \_LipDensity
\]

\[
C=lerp(C, LipTex.rgb\cdot \_LipColor\cdot \_MakeupMultiplyColor, mask_{lip})
\]

同时：

\[
roughness = SpecularTex.r \cdot lerp(1, \_LipRoughness, mask_{lip})
\]

\[
specMask = SpecularTex.b \cdot lerp(1, \_LipSpecular, mask_{lip})
\]

这意味着嘴唇可以拥有独立于皮肤的高光强度和粗糙度，使唇部更湿润或更亮。

### 7.7 Decorate / Decorate2

`_DecorateTex` 与 `_Decorate2Tex` 由 `_DecorateUV`、`_Decorate2UV` 控制 UV 变换，使用各自 color 和 density 混合：

\[
C=lerp(C, DecorateTex.rgb\cdot \_DecorateColor, DecorateTex.a\cdot \_DecorateDensity)
\]

\[
C=lerp(C, Decorate2Tex.rgb\cdot \_Decorate2Color, Decorate2Tex.a\cdot \_Decorate2Density)
\]

### 7.8 MorphPart

Morph part 比普通贴花复杂。它有：

- `_MorphPartId`：部位 ID。
- `_MorphPartRange`：ID/range 容差或影响范围。
- `_MorphPartShinningAlpha`：闪耀 alpha。
- `_MorphPartWaveLength`：波长。
- `_MorphPartBreathAlpha`：呼吸动画强度。
- `_MorphPartColor` / `_MorphPartShinningColor` / `_MorphPartSpreadColor`。

IR 中能看到：

- 对 `MorphPartTex` 采样。
- 对某个通道与 `_MorphPartId` 做差，再取绝对值。
- 与 `_MorphPartRange` 比较形成 mask。
- 使用 smoothstep-like 多项式：

\[
t^2(3-2t)
\]

对应 IR 中的 `t*t` 与 `t * (-2t + 3)`。

这说明 morph part 是一个带区域选择、边缘平滑、扩散/波动/闪烁的局部特效层，而不是简单 albedo 贴花。

---

## 8. Normal 计算

normal 主要来自 `_NormalTex` 与 `_EyelidTex`。

### 8.1 贴图 normal 解码

典型过程：

```c
half2 xy = tex.rg * 2 - 1;
half z = sqrt(1 - saturate(dot(xy, xy)));
half3 n = half3(xy, z);
```

IR 中有：

- `tex.rg * 2 - 1`
- `dot(xy, xy)`
- `min(..., 1)`
- `sqrt(1 - dot)`

说明 normal 是从两个通道重建 z。

### 8.2 `_NormalTex` packed normal

`_NormalTex` 的 `xy` 与 `zw` 都被解码成 normal：

- `normalA = decode(_NormalTex.xy)`
- `normalB = decode(_NormalTex.zw)`

然后通过 eye/eyelid 相关参数混合。

### 8.3 `_EyelidTex` normal

`_EyelidTex.rg` 也被解码成 normal，并根据 `_EyelidTex.a` 与左右眼信息混入。

### 8.4 TBN 到 world normal

IR 中从 `TEXCOORD3`、`TEXCOORD4`、`TEXCOORD5` 取出三组向量，构成类似 TBN 的 basis，然后执行：

\[
N_{world}=normalize(TBN\cdot N_{tangent})
\]

最终得到 world normal `%401` 一类变量，后续用于：

- `NdotL`
- `NdotV`
- `NdotH`
- reflection vector
- SH/probe lighting

---

## 9. View vector 与 screen UV

### 9.1 View vector

shader 从 varyings 和/或相机参数构造 view direction，并归一化：

\[
V=normalize(cameraPos-worldPos)
\]

IR 中大量 `dot`、`rsqrt`、`fmul` 是 normalize 的典型编译形态。

### 9.2 Screen UV

`TEXCOORD6` 是 `float4`，用于从 clip position 推导 screen UV：

\[
screenUV = clip.xy / clip.w \cdot 0.5 + 0.5
\]

并结合 `_ScreenParams` 或投影参数修正 y/scale。

该 screen UV 用于：

- `_LightIndexMap`
- `_ScreenShadowTexture`
- `_SSSSkinTexture`

这非常关键：皮肤 SSS 和阴影不是 mesh UV 贴图，而是屏幕空间贴图。

---

## 10. Specular model 详细分析

这是 shader 的核心 shading model 之一。

### 10.1 Roughness 与 specular mask

基础来自 `_SpecularTex`：

- `SpecularTex.r`：roughness-like。
- `SpecularTex.b`：specular intensity/mask-like。

唇部会覆盖/调制：

\[
roughness = SpecularTex.r \cdot lerp(1, \_LipRoughness, lipMask)
\]

\[
specMask = SpecularTex.b \cdot lerp(1, \_LipSpecular, lipMask)
\]

`_NonMetalSpecular` 也参与整体 specular 强度：

\[
F_0 \approx 0.08 \cdot \_NonMetalSpecular \cdot specMask
\]

这里的 `0.08` 是常见 dielectric specular 反射率尺度，但 shader 也可能用 half 常量和经验系数做了变体。

### 10.2 Half vector

每盏灯都会计算：

\[
H=normalize(L+V)
\]

IR 形态：

- `L + V`
- `dot(H,H)`
- `rsqrt`
- `H *= rsqrt`

### 10.3 GGX NDF

能看到典型 GGX 分母结构：

\[
D_{GGX}
=
\frac{a^2}{\pi\left((N\cdot H)^2(a^2-1)+1\right)^2}
\]

IR 中常见形式：

1. `roughness` 平方得到 `a` 或 `a2`。
2. `NdotH` clamp。
3. 计算：

\[
denom=(NdotH^2\cdot(a^2-1)+1)
\]

4. reciprocal。
5. square。
6. 乘近似 `1/pi`。
7. `min(..., 10)` 防止高光过曝。

这说明 shader 的 specular 不是 Blinn-Phong，而是 GGX microfacet。

### 10.4 Fresnel：Schlick pow5

IR 中有典型五次方：

```c
float x = 1 - saturate(VdotH);
float x2 = x * x;
float x5 = x2 * x2 * x;
F = F0 + (F90 - F0) * x5;
```

也就是 Schlick Fresnel：

\[
F = F_0 + (F_{90}-F_0)(1-V\cdot H)^5
\]

其中 `F90`/grazing term 被一些经验参数、shadow/spec factor、skin-specific 值调制。

### 10.5 Geometry/visibility 项

IR 中不是非常清晰地呈现完整 Smith GGX `G` 项，但有多个类似：

\[
\frac{1}{NdotL\cdot(1-k)+k}
\]

或经验 denominator 形式，例如：

- `fma(NdotL, something, something)`
- reciprocal
- 乘 `0.5` 或 `1/pi`

整体更像 Unity/移动端优化版的 GGX visibility，而不是严格完整公式。

---

## 11. Additional lights 计算

shader 使用 `_LightIndexMap` 读取最多 4 个 light index。

### 11.1 Light index map

过程：

1. 用 screen UV 采样 `_LightIndexMap`。
2. `rgba * 255 + 0.5`。
3. `floor` 转为整数 index。
4. 每个通道如果 `< 255`，说明有有效 light。
5. 用 index 访问 `_AdditionalLight*` 数组。

这相当于 mobile/cluster/tiled lighting 的一种简化形式：每个像素从 light index map 中找到相关灯光。

### 11.2 每盏 additional light 的通用流程

对每个 light index：

```c
float4 lightPos = _AdditionalLightPosition[index];
float3 Lraw = lightPos.xyz - worldPos * lightPos.w;
float dist2 = dot(Lraw, Lraw);
float3 L = Lraw * rsqrt(max(dist2, epsilon));
```

如果 `lightPos.w == 0`，接近 directional light；如果 `w == 1`，接近 point/spot light。

距离衰减来自 `_AdditionalLightDistanceAttenuation`，spot 衰减来自 `_AdditionalLightSpotDir` 与 `_AdditionalLightSpotAttenuation`。

大致：

\[
atten_{dist}=f(dist^2, distanceAtten)
\]

\[
atten_{spot}=saturate(dot(spotDir,L)\cdot a+b)^2
\]

\[
atten=atten_{dist}\cdot atten_{spot}\cdot shadow
\]

### 11.3 屏幕阴影权重

`_ScreenShadowTexture` 被采样成 `screenShadow`。对 each light：

\[
shadowRaw = dot(1-screenShadow, AdditionalLightShadowWeight[index])
\]

\[
shadow = 1 - CharShadowIntensity \cdot shadowRaw
\]

也就是每个 additional light 可以有独立的 RGBA shadow weight。

### 11.4 diffuse 与 specular

每盏灯的 diffuse：

\[
diffuse_i = albedo\cdot lightColor_i\cdot max(N\cdot L_i,0)\cdot atten_i
\]

specular：

\[
spec_i = lightColor_i\cdot F\cdot D_{GGX}\cdot Vis\cdot atten_i\cdot specMask
\]

最终：

\[
C_{additionalLights}=\sum_i(diffuse_i+spec_i)
\]

### 11.5 特殊 sparkle 分支

IR 中有判断：

```llvm
fcmp oeq lightColor.w, -1
```

如果某盏灯的 color alpha/w 等于 `-1`，会走特殊 sparkle 分支，重新用 procedural pattern 计算一组 sparkle specular，并与普通 specular 组合。

这说明：

- additional light 的 `w` 被重载为标志位。
- `-1` 可能表示这个 light 是角色 sparkle/高光触发器，而不是普通照明。

---

## 12. 主角色光计算

除了 additional lights，还有 `Character_Param` 与 `AsukaPerShader_PerCamera` 中的主角色光。

涉及：

- `_CharLightPosition`
- `_CharMainLightColor`
- `_CharLightColor`
- `_CharShColor`
- `_CharShIntensity`
- `_CharShadowIntensity`
- `_MainLightPosition`
- `_MainLightColor`
- `_MainLightRealtime`

主角色光也使用类似：

\[
NdotL = max(dot(N,L),0)
\]

\[
H=normalize(L+V)
\]

\[
spec=GGX(N,V,L,roughness,F0)
\]

但和 additional lights 不同，它还混合角色专用 shadow、SSS、home lighting 和 PPV 参数。

---

## 13. `_SSSSkinTexture` 与皮肤散射

`_SSSSkinTexture` 是本 shader 皮肤感的关键。

它用 screen UV 采样，而不是 mesh UV。这说明它不是普通 skin albedo，而是某种屏幕空间皮肤散射/柔化 pass 的结果。

可能流程：

1. 前面某个 pass 生成皮肤 diffuse/SSS buffer。
2. 当前 fragment 使用 screen UV 采样 `_SSSSkinTexture`。
3. 将妆容合成后的 albedo 与 SSS texture 相乘或混合。

近似：

\[
C_{sss}=C_{makeupAlbedo}\cdot SSSSkinTexture.rgb
\]

也可能额外乘：

- `_CharShadowIntensity`
- `_AOIntensity`
- `_ShadowIntensity`
- `_CharMainLightColor`
- `_EyeAdaptionExposure`

从 IR 使用方式看，`_SSSSkinTexture` 更像光照/散射结果贴图，而不是颜色贴图。它为皮肤提供柔化、半透明、低频扩散的效果。

---

## 14. `_ScreenShadowTexture` 阴影模型

`_ScreenShadowTexture` 同样是 screen UV 采样。

用途：

1. additional light shadow attenuation。
2. main/character light 阴影衰减。
3. 可能调制 SSS 或 diffuse/specular。

基本形式：

\[
shadow = lerp(1, screenShadow, shadowIntensity)
\]

或对 additional lights：

\[
shadow_i = 1 - \_CharShadowIntensity\cdot dot(1-screenShadow, shadowWeight_i)
\]

这类屏幕空间 shadow texture 允许 shader 避免每个角色 fragment 做昂贵 shadow map 查询，而是使用预先生成/聚合的阴影图。

---

## 15. 间接光与环境反射

### 15.1 Reflection cubemap

shader 计算 reflection vector：

\[
R=reflect(-V,N)
\]

然后用 roughness 推导 mip：

\[
mip=f(roughness)\cdot maxMip
\]

采样：

```c
unity_SpecCube0.SampleLevel(samplerunity_SpecCube0, R, mip)
```

然后用 `unity_SpecCube0_HDR` decode HDR：

\[
envSpec = DecodeHDREnvironment(sample, unity\_SpecCube0\_HDR)
\]

IR 中可见 `log2`、`exp2`、HDR 参数乘法，这正是 Unity 风格 reflection probe decode 的典型形态。

### 15.2 SH / probe diffuse

`PapePerRendererCB` 中有：

- `_SHMaps[7]`
- `_CubeSHs[7]`

IR 中对 normal 构造了：

- `half4(N, 1)` dot 若干 SH 系数。
- 二阶项如 `N.yxzz * N.xyz...` dot 若干系数。
- 最后 `max(..., 0)`。

这对应低阶 spherical harmonics / probe diffuse：

\[
E(N)=SH_0+SH_1(N)+SH_2(N)
\]

间接漫反射：

\[
C_{indirectDiffuse}=albedo\cdot E(N)
\]

---

## 16. Eye/Lip sparkle

材质中有大量 sparkle 参数：

- `_EyeSparkleColor`
- `_LipSparkleColor`
- `_EyeSparkleParams`
- `_LipSparkleParams`
- `_EyeSparkleSize`
- `_LipSparkleSize`
- `_EyeSparkle`
- `_LipSparkle`
- `_SparkleUV`

IR 里能看到大量 `fract`、`floor`、hash-like 常量和 cell/grid 计算。这说明 sparkle 不是简单纹理采样，而是 procedural cell/hash pattern：

1. 根据 UV 与 sparkle size 计算网格坐标。
2. 用 `fract` 和若干常量生成伪随机点。
3. 计算 fragment 到 sparkle cell center 的距离。
4. 用阈值/二次衰减得到 sparkle mask。
5. 与高光方向、`NdotH`、specular 项组合。

近似：

\[
mask_{sparkle}=HashGridSparkle(uv, size, params)
\]

\[
C_{sparkle}=mask_{sparkle}\cdot sparkleColor\cdot SpecularLikeTerm
\]

lip sparkle 和 eye sparkle 可能使用相似逻辑，但分别由唇部/眼部 mask 与颜色控制。

---

## 17. Alpha / DOF 输出

最终 alpha：

```llvm
%1411 = _DOFBlurFlag - 1
%1414 = fma(_DOFEnable, %1411, 1)
```

等价：

\[
alpha = 1 + \_DOFEnable\cdot(\_DOFBlurFlag-1)
\]

也就是：

\[
alpha = lerp(1, \_DOFBlurFlag, \_DOFEnable)
\]

这个值同时写到：

- `SV_TARGET0.a`
- `SV_TARGET1`

因此它不是传统透明度，而是给后处理/DOF 使用的 mask 或权重。

---

## 18. 近似伪代码重建

下面是根据 IR 还原的高层伪代码。变量名称不一定等同原始 HLSL，但表达计算结构。

```c
FragmentOut xlatMtlMain(...) {
    float2 uv = TEXCOORD0.xy;
    float2 screenUV = TEXCOORD6.xy / TEXCOORD6.w * 0.5 + 0.5;

    half4 specTex = _SpecularTex.Sample(sampler_SpecularTex, uv);
    half4 mainTex = _MainTex.SampleBias(sampler_MainTex, uv, _GlobalMipBias);

    half3 albedo = mainTex.rgb * _Color.rgb;

    // --- makeup ---
    half4 eyebrow = _EyebrowTex.Sample(...);
    albedo = lerp(albedo, eyebrow.rgb * _EyebrowColor, eyebrow.a * _EyebrowDensity);

    half4 eyeshadow = _EyeshadowTex.Sample(...);
    albedo = lerp(albedo,
                  eyeshadow.rgb * _EyeshadowColor * _MakeupMultiplyColor,
                  eyeshadow.a * _EyeshadowDensity);

    half4 eyeliner = _EyelinerTex.Sample(...);
    albedo = lerp(albedo,
                  eyeliner.rgb * _EyelinerColor * _MakeupMultiplyColor,
                  eyeliner.a * _EyelinerDensity);

    half4 blusher = _BlusherTex.Sample(...);
    albedo *= lerp(1,
                   blusher.rgb * _BlusherColor,
                   blusher.a * _BlusherDensity);

    half4 lip = _LipTex.Sample(...);
    half lipMask = lip.a * _LipDensity;
    albedo = lerp(albedo,
                  lip.rgb * _LipColor * _MakeupMultiplyColor,
                  lipMask);

    half4 decorate = _DecorateTex.Sample(...);
    albedo = lerp(albedo,
                  decorate.rgb * _DecorateColor,
                  decorate.a * _DecorateDensity);

    half4 decorate2 = _Decorate2Tex.Sample(...);
    albedo = lerp(albedo,
                  decorate2.rgb * _Decorate2Color,
                  decorate2.a * _Decorate2Density);

    albedo = ApplyMorphPart(albedo, _MorphPartTex, _MorphPartColor,
                            _MorphPartShinningColor, _MorphPartSpreadColor,
                            _MorphPartId, _MorphPartRange,
                            _MorphPartWaveLength, _MorphPartBreathAlpha);

    // --- material spec params ---
    half roughness = specTex.r * lerp(1, _LipRoughness, lipMask);
    half specMask  = specTex.b * lerp(1, _LipSpecular, lipMask);
    half F0 = specMask * _NonMetalSpecular * 0.08h;

    // --- normal ---
    half3 n0 = DecodeNormalRG(_NormalTex.Sample(...).xy);
    half3 n1 = DecodeNormalRG(_NormalTex.Sample(...).zw);
    half3 eyelidN = DecodeNormalRG(_EyelidTex.Sample(...).xy);
    half3 tangentN = BlendNormals(n0, n1, eyelidN, eyeInfo, eyelidMask);
    float3 N = normalize(TBN * tangentN);
    float3 V = normalize(cameraPos - worldPos);

    // --- screen textures ---
    half4 screenShadow = _ScreenShadowTexture.Sample(sampler_ScreenShadowTexture, screenUV);
    half4 sssSkin = _SSSSkinTexture.Sample(sampler_SSSSkinTexture, screenUV);

    // --- additional lights ---
    half3 addLightColor = 0;
    half4 lightIndices = floor(_LightIndexMap.Sample(..., screenUV) * 255 + 0.5);
    for each channel in lightIndices {
        if (index < 255) {
            LightData light = LoadAdditionalLight(index);
            float3 L = ComputeLightDir(light, worldPos);
            float atten = ComputeDistanceSpotAtten(light, L, worldPos);
            atten *= ComputeScreenShadow(screenShadow, light.shadowWeight, _CharShadowIntensity);

            half NdotL = saturate(dot(N, L));
            half3 diffuse = albedo * light.color.rgb * NdotL;
            half3 spec = GGXSpecular(N, V, L, roughness, F0) * light.color.rgb;

            if (light.color.w == -1)
                spec += ProceduralSparkle(...);

            addLightColor += (diffuse + spec) * atten;
        }
    }

    // --- main/character light ---
    half3 mainLight = ComputeCharacterMainLight(
        albedo, N, V, roughness, F0,
        _CharLightPosition, _CharMainLightColor,
        screenShadow, sssSkin
    );

    // --- indirect ---
    half3 indirectDiffuse = albedo * EvaluateSH(N, _SHMaps, _CubeSHs);
    half3 envSpec = DecodeHDR(unity_SpecCube0.SampleLevel(reflect(-V, N), RoughnessToMip(roughness)),
                              unity_SpecCube0_HDR);

    // --- SSS diffuse ---
    half3 sssDiffuse = albedo * sssSkin.rgb;

    half3 color = addLightColor + mainLight + indirectDiffuse + envSpec + sssDiffuse;

    half dofMask = lerp(1, _DOFBlurFlag, _DOFEnable);
    return { half4(color, dofMask), dofMask };
}
```

---

## 19. 对 shading model 的命名建议

如果要给这个 shader 的 shading model 起一个准确名字，可以叫：

> Stylized Character Skin BRDF with Screen-Space SSS, Makeup Layering, GGX Specular, Clustered Additional Lights, and Procedural Sparkle

中文可称：

> 风格化角色皮肤模型：屏幕空间 SSS + 多层妆容合成 + GGX 高光 + 屏幕空间额外光 + 程序化闪点

它不是纯 PBR，但 specular 子模块明显采用了 PBR/GGX；diffuse/skin 部分则更偏角色定制与屏幕空间缓存。

---

## 20. 关键判断依据

1. `1798` 的材质布局中有大量皮肤/妆容/唇部/闪点参数，说明这是角色皮肤专用 shader。
2. 纹理列表包含 `_SSSSkinTexture` 和 `_ScreenShadowTexture`，且二者用 screen UV 采样，说明存在屏幕空间 SSS/阴影系统。
3. IR 中存在 `roughness^2`、`1 / ((NdotH^2(a^2-1)+1)^2)`、`1/pi`、`pow5` 形态，说明 specular 是 GGX + Schlick Fresnel。
4. `_LightIndexMap` rgba 转 index，并访问 additional light arrays，说明使用 light index map 做 per-pixel additional light selection。
5. 大量 `fract`、`floor`、hash-like 常量、cell distance 计算说明存在程序化 sparkle。
6. `SV_TARGET1` 输出和 `SV_TARGET0.a` 相同，且由 `_DOFEnable` / `_DOFBlurFlag` 控制，说明 alpha 是 DOF/post-process mask。

---

## 21. 最终一句话总结

`SkinMakeupNew` 是一个移动端角色皮肤专用 fragment shader：它先用多层妆容贴图构造最终皮肤 albedo，再用 normal/eyelid normal 构造 world normal；光照部分将角色主光、light-index-map 选出的 additional lights、屏幕空间阴影、屏幕空间 SSS、SH/probe 间接光、reflection cubemap 和 GGX/Schlick 高光组合起来，最后额外叠加 eye/lip sparkle 与 morph part 特效，并输出颜色与 DOF mask。
