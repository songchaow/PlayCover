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

唇部会覆盖/调制。这里要特别注意：**粗糙度/specular 覆盖使用的是 `LipTex.a`，不是已经乘过 `_LipDensity` 的唇色混合 mask**。IR 对应 `%99 = LipTex.a`，然后直接用它对 `_LipRoughness` / `_LipSpecular` 做插值。

\[
roughnessRaw = SpecularTex.r \cdot lerp(1, \_LipRoughness, LipTex.a)
\]

\[
specMask = SpecularTex.b \cdot lerp(1, \_LipSpecular, LipTex.a)
\]

随后用于 cubemap LOD 的 perceptual roughness 是：

\[
perceptualRoughness = \max(roughnessRaw, 0.010002136)
\]

对应 IR：

```llvm
%46  = SpecularTex.rb
%99  = LipTex.a
%107 = half2(_LipRoughness, _LipSpecular)
%108 = %107 - 1
%110 = fma(%99.xx, %108, 1)          ; lerp(1, lip override, LipTex.a)
%111 = %46 * %110                   ; (roughnessRaw, specMask)
%447.x = max(%111.x, 0xH211F)        ; perceptualRoughness, 0xH211F=0.010002136
```

也就是说它不是从 `NdotL`、`NdotV` 或 Fresnel 算出来的，而是直接来自 **材质 specular 贴图的 r 通道 + 唇部 roughness 覆盖**。

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

### 10.3 GGX NDF：IR 级实现

这里不要只写“GGX”，因为 IR 里的写法不是教科书公式直写，而是一个为移动端重排过的 reciprocal 形式。

相关 IR 变量关系：

```c
// %463：前面算出的 perceptual roughness / roughness-like 值
half r = roughness;

// %464, %467, %469
half r2 = max(r * r, 0.010002136h);   // 0xH211F

// %470, %471, %472, %473
float invR2 = 1.0 / r2;
float r2f = (float)r2;
float ggxA = r2f - invR2;
```

对每个 specular evaluation，IR 会对 `NdotH` 做如下计算：

```c
float ndh = saturate(dot(N, H));
ndh = min(ndh, 0.99902344f);          // IR 中常见 0x3FEFF7CEE...，约等于 0.999
float ndh2 = ndh * ndh;

float denom = mad(ndh2, ggxA, invR2);
float invDenom = 1.0 / denom;
invDenom = min(invDenom, 10.0);

float D = invDenom * invDenom * 0.3173828125f; // 约 1/pi
```

把它展开：

\[
\begin{aligned}
r_2 &= \max(r^2, 0.010002136) \\
inv &= \frac{1}{r_2} \\
denom &= (N\cdot H)^2\cdot(r_2-inv)+inv \\
D &= \min\left(\frac{1}{denom},10\right)^2\cdot0.3173828125
\end{aligned}
\]

这个 `denom` 和标准 GGX NDF 是等价重排：

\[
denominator
= \frac{(N\cdot H)^2(r_2^2-1)+1}{r_2}
\]

所以：

\[
\left(\frac{1}{denom}\right)^2
= \frac{r_2^2}{((N\cdot H)^2(r_2^2-1)+1)^2}
\]

再乘 `1/pi` 就是：

\[
D_{GGX}
=
\frac{r_2^2}{\pi\left((N\cdot H)^2(r_2^2-1)+1\right)^2}
\]

关键细节：

- `r2` 最小值不是 0，而是 `0.010002136`。
- reciprocal 会 clamp 到 `10.0`，所以 `D` 最大约为 `10^2 * 0.3173828125 = 31.73828125`。
- `NdotH` 也会被限制在略小于 1 的值，避免极端 grazing/镜面尖峰导致数值爆炸。

### 10.4 Fresnel：不是只写 Schlick，要看 IR 里的混合形式

IR 中确实出现 Schlick pow5 模式，但它不是单纯：

```c
F = F0 + (1 - F0) * pow5(1 - VdotH);
```

更接近下面这种“两个端点之间按 pow5 插值”的形式：

```c
float vdoth = saturate(dot(V, H));
float x = 1.0 - vdoth;
float x2 = x * x;
float x4 = x2 * x2;
float x5 = x4 * x;

// IR 中常见：
// oneMinusX5 = mad(-x4, x, 1.0)
float oneMinusX5 = 1.0 - x5;

// specBase 通常来自 specMask、_NonMetalSpecular、AO/全局缩放等。
// grazingTerm / edgeTerm 在不同路径里由角色光、sparkle 或其它局部项提供。
float F = specBase * oneMinusX5 + grazingTerm * x5;
```

也就是：

\[
F = specBase\cdot(1-(1-V\cdot H)^5)+grazingTerm\cdot(1-V\cdot H)^5
\]

等价于：

\[
F = lerp(specBase, grazingTerm, (1-V\cdot H)^5)
\]

所以当前 shader 的 Fresnel 不是完全固定的 dielectric Fresnel，而是一个角色定制的 Schlick-style 端点插值。

### 10.5 Direct specular lobe 的组合形式

综合上面，单盏灯的 specular lobe 可以写成：

```c
float3 H = normalize(L + V);
float ndl = max(dot(N, L), 0.0);
float ndh = saturate(dot(N, H));
float vdh = saturate(dot(V, H));

float D = Skin_GGX_D(roughness, ndh);
float F = Skin_Fresnel(specBase, grazingTerm, vdh);

// IR 里没有看到完整教科书 Smith G 的直写，更多是移动端合并项。
// attenuation 包含：距离、spot、screen shadow、light index 权重等。
float3 spec = lightColor.rgb * ndl * attenuation * D * F * extraSpecScale;
```

其中 `extraSpecScale` 在不同路径里会包含：

- `_NonMetalSpecular`
- `_AOIntensity` 或类似全局调制
- `_LipSpecular`
- `_LipRoughness`
- sparkle mask
- additional light shadow/spot/distance attenuation

所以准确说：**BRDF 的核心 NDF/Fresnel 是 GGX + Schlick-style，但最终 specular 是角色 shader 合并过的经验模型，不是完整未改造的 Cook-Torrance。**

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

## 15. 间接光与环境反射：cubemap IBL 的具体实现

这一段之前写得太概括。根据 IR，`unity_SpecCube0` 的 cubemap IBL 可以比较明确地还原为下面几个函数。

### 15.1 Reflection vector

IR 先取已经归一化的视线方向和 world normal：

```c
// %387：由 TEXCOORD3.w / TEXCOORD4.w / TEXCOORD5.w 组成并 normalize 后的方向，按使用方式可视为 V。
// %401：TBN 变换后的 world normal N。
half3 V = normalize(half3(TEXCOORD3.w, TEXCOORD4.w, TEXCOORD5.w));
half3 N = normalize(worldNormal);
```

反射方向不是调用高级函数，而是直接展开：

```c
half3 I = -V;
half d = dot(I, N);
half3 R_half = mad(N, half3(-2.0h * d), I); // I - 2*N*dot(I,N)
float3 R = float3(R_half);
```

对应：

\[
R = reflect(-V, N) = -V - 2N\cdot dot(-V,N)
\]

对应 IR：

- `%520 = -%387`
- `%521 = dot(%520, %401)`
- `%522 = %521 + %521`
- `%525 = -%522`
- `%526 = fma(%401, %525, %520)`

### 15.2 Roughness 到 cubemap mip：这里不是模糊的 `f(roughness)`

IR 中的 LOD 公式非常明确：

```llvm
%527 = -roughness
%528 = fma(%527, 0xH399A, 0xH3ECD)
%529 = roughness * %528
%530 = %529 * 0xH4600
```

把 half 常量解出来：

- `0xH399A = 0.7001953125`
- `0xH3ECD = 1.7001953125`
- `0xH4600 = 6.0`

所以：

```c
half PerceptualRoughnessToSpecCubeMip(half roughness) {
    // 注意：这里使用的是前面已经处理过的 roughness-like 值 %463。
    // 它至少经过 specTex/lip 调制，并被下游路径 clamp。
    return roughness * (1.7001953125h - 0.7001953125h * roughness) * 6.0h;
}
```

数学形式：

\[
mip = r\cdot(1.7001953125 - 0.7001953125r)\cdot6
\]

也就是：

\[
mip = 10.201171875r - 4.201171875r^2
\]

几个采样点：

| `r` | `mip` |
|---:|---:|
| 0.0 | 0.0 |
| 0.25 | 2.2873535 |
| 0.5 | 4.0502930 |
| 0.75 | 5.2873535 |
| 1.0 | 6.0 |

这就是 Unity 常见的 `perceptualRoughnessToMipmapLevel` 形态：

```c
mip = perceptualRoughness * (1.7 - 0.7 * perceptualRoughness) * UNITY_SPECCUBE_LOD_STEPS;
```

但在当前 IR 里 `UNITY_SPECCUBE_LOD_STEPS` 已经常量折叠成 `6.0`，没有读取 `Pape_SpecCubeArrayMaxMip`。

### 15.3 Cubemap sample

采样调用对应：

```c
half4 encoded = unity_SpecCube0.sample(samplerunity_SpecCube0, R, level(mip));
```

IR 形式：

```llvm
%533 = air.sample_texture_cube(..., %R, i1 true, float %mip, float 0.0, i32 0)
```

这里可以理解为显式 LOD/level 采样：

- 坐标：`R`
- LOD：上面的 `mip`
- 额外 bias：`0`

### 15.4 Unity HDR cubemap decode：具体公式

采样结果记为：

```c
half4 encoded = sampleCube(...);
float4 hdr = unity_SpecCube0_HDR;
```

IR 对 RGB 的 decode 是：

```c
float decodeArg = hdr.w * ((float)encoded.a - 1.0) + 1.0;
decodeArg = max((half)decodeArg, 0.0h); // IR 里转 half 后 fmax 0

float decodeScale = hdr.x * exp2(hdr.y * log2(decodeArg));
half3 decodedCube = encoded.rgb * (half)decodeScale;
```

等价数学式：

\[
decodeArg = \max(1 + hdr_w(encoded_a - 1), 0)
\]

\[
decodeScale = hdr_x\cdot decodeArg^{hdr_y}
\]

\[
C_{cube} = encoded_{rgb}\cdot decodeScale
\]

对应 IR：

- `%1224 = encoded.a - 1`
- `%1226 = hdr.w * %1224 + 1`
- `%1228 = max(%1226, 0)`
- `%1229 = log2(%1228)`
- `%1231 = hdr.y * log2(...)`
- `%1233 = exp2(...)`
- `%1235 = hdr.x * exp2(...)`
- `%1239 = encoded.rgb * %1235`

注意：当前路径只使用了 `unity_SpecCube0_HDR.x`、`.y`、`.w`，没有看到 `.z` 参与 decode。

### 15.5 Pape SH / probe 项：具体 basis

`PapePerRendererCB` 中的 `_SHMaps[7]` 被加载为 7 个 `half4`：

```c
half4 sh0 = _SHMaps[0];
half4 sh1 = _SHMaps[1];
half4 sh2 = _SHMaps[2];
half4 sh3 = _SHMaps[3];
half4 sh4 = _SHMaps[4];
half4 sh5 = _SHMaps[5];
half4 sh6 = _SHMaps[6];
```

IR 里的 SH-like evaluate 可以写成：

```c
half3 EvaluatePapeSH(half3 N) {
    half4 n4 = half4(N.x, N.y, N.z, 1.0h);

    half3 linear;
    linear.r = dot(sh0, n4);
    linear.g = dot(sh1, n4);
    linear.b = dot(sh2, n4);

    half4 quadBasis = half4(
        N.y * N.x,
        N.z * N.y,
        N.z * N.z,
        N.x * N.z
    );

    half3 quad;
    quad.r = dot(sh3, quadBasis);
    quad.g = dot(sh4, quadBasis);
    quad.b = dot(sh5, quadBasis);

    half nx2MinusNy2 = N.x * N.x - N.y * N.y;

    return max(linear + quad + sh6.rgb * nx2MinusNy2, 0.0h);
}
```

这不是泛泛地说“SH”，而是当前 IR 实际使用的 basis：

\[
[ N_x, N_y, N_z, 1 ]
\]

\[
[ N_yN_x, N_zN_y, N_zN_z, N_xN_z ]
\]

\[
N_x^2 - N_y^2
\]

最后 clamp 到非负。

### 15.6 Cubemap IBL 最终进入颜色前的组合

IR 中 cubemap decode 后并不是直接 `envSpec = decodedCube`。它又乘了上面的 SH/probe 项和一个 spec scale：

```c
half3 decodedCube = DecodeUnitySpecCube(encoded, unity_SpecCube0_HDR);
half3 shProbe = EvaluatePapeSH(N);

// %433 是前面算出的 spec/ao 缩放：大致来自 SpecularTex 调制结果、_AOIntensity、0.08 等。
float specScale = previousSpecScale;

half3 envSpecPre = decodedCube * shProbe;
half3 envSpec = half3(float3(envSpecPre) * specScale);
```

后面在主光/角色光组合处又乘了 `_CharShIntensity`：

```c
half3 indirectSpec = envSpec * _CharShIntensity;
```

因此当前 shader 的 cubemap IBL 路径更准确地写成：

```c
half3 Skin_CubemapIBL(half3 N, half3 V, half roughness, float4 unity_SpecCube0_HDR) {
    half3 I = -V;
    half3 R = mad(N, half3(-2.0h * dot(I, N)), I);

    half mip = roughness * (1.7001953125h - 0.7001953125h * roughness) * 6.0h;
    half4 encoded = unity_SpecCube0.sample(samplerunity_SpecCube0, float3(R), level((float)mip));

    float decodeArg = unity_SpecCube0_HDR.w * ((float)encoded.a - 1.0) + 1.0;
    decodeArg = max(decodeArg, 0.0);
    float decodeScale = unity_SpecCube0_HDR.x * exp2(unity_SpecCube0_HDR.y * log2(decodeArg));

    half3 decodedCube = encoded.rgb * (half)decodeScale;
    half3 shProbe = EvaluatePapeSH(N);

    return decodedCube * shProbe * (half)specScale * _CharShIntensity;
}
```

这里唯一还不能从这一个小段独立命名的变量是 `specScale`，但它不是未知函数：它在 IR 前面已经算好并以 `%433` 形式参与 IBL。其来源链路大致是：

```c
specScale = adjustedSpecularMask * _AOIntensity * 0.08;
```

其中 `adjustedSpecularMask` 来自 `_SpecularTex` 通道并经过唇部 `_LipSpecular` 等参数调制。

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

    // --- indirect / cubemap IBL ---
    half3 shProbe = EvaluatePapeSH(N); // 具体 basis 见第 15.5 节
    half3 indirectDiffuse = albedo * shProbe;

    half3 I = -V;
    half3 R = mad(N, half3(-2.0h * dot(I, N)), I);
    half mip = roughness * (1.7001953125h - 0.7001953125h * roughness) * 6.0h;
    half4 encodedCube = unity_SpecCube0.sample(samplerunity_SpecCube0, float3(R), level((float)mip));

    float decodeArg = unity_SpecCube0_HDR.w * ((float)encodedCube.a - 1.0) + 1.0;
    decodeArg = max(decodeArg, 0.0);
    float decodeScale = unity_SpecCube0_HDR.x * exp2(unity_SpecCube0_HDR.y * log2(decodeArg));
    half3 decodedCube = encodedCube.rgb * (half)decodeScale;

    half3 envSpec = decodedCube * shProbe * (half)specScale * _CharShIntensity;

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
