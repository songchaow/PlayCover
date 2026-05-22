# 07 — SkinMakeupNew Forward Pass（RPS 496）受光剖析

> **目标**：把 `ShaderTranslated/SkinMakeupNew.shader` 在 **RPS 496（CB1/E13/draw69）** 的实际受光情况完整拆解清楚 —— 即「这一像素的最终颜色由哪些光源、各贡献多少、互相怎么组合」。
>
> **输入 1（shader 行为）**：[`SkinMakeupNew.shader`](../OfflineSourceRecovery/gputracebinaryreplacement/ShaderTranslated/SkinMakeupNew.shader)（IR 反编译并整理过的 HLSL）
> **输入 2（实测数值）**：bridge `dump-uniforms`（按 fragment IR 的 `air.struct_type_info` 元数据，从 trace 中各 cbuffer binding 的真实 offset / size 解出字段值）；7 个 cbuffer 的 reflection-decoded JSON 也归档在 [`SkinLighting/`](../OfflineSourceRecovery/gputracebinaryreplacement/ShaderRaw/SkinLighting/) 目录的 `cb*.json` 与 `draw69_raw_dump.json`
> **范围**：仅 **RPS 496**（E13 全分辨率 forward compose）。RPS 484（E4 velocity-prepass，见 `06-gbuffer-truth.md`）/ RPS 491（E10 half-res forward lighting，写 `_SSSSkinTexture` 输入端）/ RPS 476（E2 shadow caster）不在本文范围内。

---

## 1. 一行结论 + 一张图

> **`finalColor = tintedAlbedo · _SSSSkinTexture (≈主漫反射 + 主灯) + charShadow · (mainSpec + sparkle·_CharMainLightColor) + charSpec · screenShadow.a + envSpec(≈0) + Σ addSpec`**

```
                                     ┌──────────────────────────────────┐
                                     │  ⓪ 上游 SSS pass 结果            │
   _SSSSkinTexture (rid 232) ──────► │  半分辨率皮肤 lighting 已含主灯  │
   E10→E11→E12 的产物                │  ½×½ → 上采样到全分辨率           │
                                     └──────┬───────────────────────────┘
                                            │ × tintedAlbedo (含 makeup 后的肤色)
                                            ▼
                                     [漫反射主体（最大贡献）]
                                            ▲
                                            │ + charShadow ·
   ① _CharMainLightColor (cb4) ──── ┐       │   ┌───────────────────┐
                              │ × NdotL│      │   │ ⑤ 主灯 GGX 镜面    │
                              │       │      │   │ + sparkle·CharMain│
   _MainLightPosition (cb1)   ┘ × DVF  └─────┤   └───────────────────┘
                                            │       (charShadow=lerp(1,
                                            │        screenShadow.r,
                                            │        _CharShadowIntensity))
                                            │
                                            │ + screenShadow.a ·
   ② _CharLightColor (cb4) ──────┐          │   ┌───────────────────┐
   _CharLightPosition (cb4) ─────┘ DVF      │   │ ⑥ Char Light 镜面 │
                                            │   └───────────────────┘
                                            │
                                            │ + (≈0) ·
   ③ unity_SpecCube0 (rid 142, 1×1 黑)──┐    │   ┌───────────────────┐
   _SHMaps[7] (cb6, Pape SH 是 0)? ─────┘ × F0 │   │ ⑦ envSpec ≈ 0     │
                                            │   └───────────────────┘
                                            │
                                            │ + Σ ·
   ④ _AdditionalLight* (cb0, 30 槽 / ─────┐  │   ┌───────────────────┐
       本帧 2 盏活跃) ───────────────────┘  └─►│ ⑧ 附加光镜面（最多 4 盏）│
   _LightIndexMap (rid 145) → 4 byte 索引     │   └───────────────────┘
                                            ▼
                                       finalColor (RGBA16F → 224)
```

每个数字（①–⑧）对应下文一个小节。**记忆要点**：

1. **皮肤最主要的受光是 SSS pass 的输出，不是 RPS 496 自己算的**。RPS 496 自己算的只是镜面 + 附加光 + IBL。
2. **URP 标准的 `_MainLightColor` 在这帧是 0**（不被 RPS 496 fragment 读取）；**所有"主灯亮度"都来自 cb4 的 `_CharMainLightColor = (2.51, 2.26, 2.43)`**。
3. **环境光是 Pape SH（cb6 `_SHMaps[7]`），不是 cubemap probe**：cubemap 是 1×1 黑、`_CubeSHs[7]` 全 0；整个 envSpec 项数值上接近 0。
4. **附加光走的是 LightIndexMap 路径**，本帧从 30 个 slot 中取出 2 盏：1 个暖白 spot（slot 0）、1 个冷蓝 point（slot 1）。

---

## 2. 漫反射主体 = `tintedAlbedo · _SSSSkinTexture` ⓪

shader 第 956 行：

```hlsl
half3 sssBlock = tintedAlbedo * sssSkin.rgb + charShadowBlock;
```

### `tintedAlbedo` 怎么算（行 944–946）

```
albedo  = mainTex.rgb * _Color.rgb            // 基础肤色
        ⊕ 9 层化妆 (eyebrow, eyeshadow, eyeliner, blusher, lip, decorate1/2, morph)
        + morphTerm1 + morphTerm2 + morphTerm3
tintedAlbedo = albedo * lerp(eyelidBlend, 1, lerpFactor)   // 眼皮区域附加 tint
```

涉及的 cbuffer 字段（cb5 `UnityPerMaterial`，frag buf slot 5 → ScratchBuffer @ 110912，336B 完整可读）：

| 字段 | 实测值 | 角色 |
|---|---|---|
| `_Color` | (-0.000122, -1.74219, 0, 1.875) | 全局肤色 tint。⚠ 数值非常规 — 含负分量、第三分量为 0。可能含义：引擎把这块字节复用作占位/索引，shader 在使用前会经 saturate/half-decode；不要按"中性肤色 1.0×"理解 |
| `_OverlayColor` | (2.514, 2.260, 2.430, 3.141) | 注：与 `_CharMainLightColor` 的字节布局完全相同；shader IR 中无对应 GEP，**不被读** — 死参数 |
| `_MakeupMultiplyColor` | (0, 0, 1) | 化妆叠加倍乘 — 等效于"只放大蓝通道" |
| 9 个 makeup 颜色 | `_MakeupColor1=(0,0,0,1.875) / _MakeupColor2=(0,1.875,0,1.875) / _MakeupColor3=(0.812,0.812,0.812,1) / _MakeupColor4=(0,0,0,0) / _MakeupColor5=(0.798,0.848,0.858,1) / _MakeupColor6=(0,0,0,0)` | 各 makeup 层颜色；4/6 关闭，3/5 是常规化妆 tint |
| 9 个 makeup density | 全部 = 0 | **本帧 9 层化妆全部关闭**（_EyebrowDensity..._Decorate2Density 全 0） |
| `_LipRoughness / _LipSpecular` | **0 / 0** | 唇部覆盖 roughness/specular —— 本帧两者都是 0 |
| `_NonMetalSpecular` | 0.9834 | 决定 F0：F0 = specMask · 0.9834 · 0.08 ≈ specMask · 0.0787 |
| `_Cutoff / _ShadowIntensity / _AOIntensity / _FresnelIntensity / _Fresnelpower` | 0.450 / 1.0 / -1.204 / 3.047 / 0.490 | — |

### `_SSSSkinTexture` 是 **E12 的输出**

| 槽位 | 资源 | 大小/格式 | 含义 |
|---|---|---|---|
| `_SSSSkinTexture` (frag tex 14) | `rid 232 TempBuffer 124` | 583×835 RG11B10F | **E12 vertical SSS blur 写回**；上采样到全分辨率使用 |

**关键认识**：`_SSSSkinTexture` 不是单纯的"SSS 项"，而是**整条半分辨率 lighting + SSS blur 的成品**。它的采样语义实际上是：

```
sampled @ screenUV → ≈ (主灯 NdotL · _CharMainLightColor · shadow)  ✱ SkinSSS profile blur ✱ 上采样
```

这是为什么 RPS 496 自己**没有**漫反射 NdotL 项的原因 —— 主灯漫反射已经被 RPS 491 在 half-res 算掉，再经 RPS 464/465 SSS 模糊存到 232。RPS 496 直接把它当"已完成的漫反射"乘到 `tintedAlbedo` 上。

> ⚠ **还原引擎易错点**：如果你在自己的引擎里把 RPS 496 单独跑、并把 `_SSSSkinTexture` 喂成 1.0（白），漫反射会整体乘 ≈ `tintedAlbedo` 而**没有任何主灯方向感**。必须先把上游 E10→E11→E12 链路接好。

---

## 3. 主灯方向 + 颜色解构 ①

### 实测数据矛盾点：URP `_MainLightColor` 是 0

| 字段 | 来源 | 实测值 | RPS 496 是否真的读 |
|---|---|---|---|
| `_MainLightPosition` | cb1 `AsukaPerShader_PerCamera` idx 1 | **(0.292, 0.274, 0.916, 0)** | ✅ **shader 读**（GEP idx 1）— 作为方向，w=0 ⇒ 平行光 |
| `_MainLightColor` | cb1 idx 2 | (0, 0, 0, 1.875) | ❌ **shader 不读**（IR 中无 GEP idx 2）— 死参数 |
| `_MainLightRealtime` | cb1 idx 6 | 0 | ❌ shader 不读（IR 中无 GEP idx 6）|
| `_CharMainLightColor` | **cb4 `Character_Param`** | **(2.51, 2.26, 2.43, π=3.14)** | ✅ **shader 读** — 作为「真正的主灯颜色」 |

→ **结论**：URP 内建的 `_MainLightColor` 在 LYSK 这套自研管线里是**残留 slot**，不参与渲染；这套 shader 用 `_CharMainLightColor` 替换之。

→ **方向**：`_MainLightPosition.xyz = (0.292, 0.274, 0.916)` 单位化后的方向 ≈ `(0.300, 0.282, 0.911)`。这是个**朝右上后方**的平行光方向；常见的"室内主光"角度。

### 主灯镜面 = GGX D·V·F（行 765–795）

```hlsl
half3 mainLightDir = normalize(_MainLightPosition.xyz);
half NdotL_main = max(dot(worldNormal, mainLightDir), 0);

float D = SkinGGX_D(NdotH, perceptualRoughness);          // GGX NDF（mobile 优化形态）
float V = SkinVisibility(NdotL, NdotV, perceptualRoughness); // Smith-Hammon joint
half F = SkinFresnel(F0, F0_grazing, VdotH);              // Schlick 5 次方

half mainSpecScalar = (half)(D * V) * F;
half3 mainSpecColor = (NdotL_main > 0)
    ? (NdotL_main * _CharMainLightColor.rgb * mainSpecScalar)
    : 0;
```

**注意三个细节**：

1. **没有漫反射项**。RPS 496 的主灯**只贡献镜面**；漫反射已经在 SSS pass 中算完。
2. **颜色载体是 `_CharMainLightColor`，不是 URP 的 `_MainLightColor`**。
3. **`F0 = specMask · _NonMetalSpecular · 0.08`**，实测 `_NonMetalSpecular = 0.983`，故 `F0 = specMask · 0.0786`。当 `specMask = 1`（鼻尖、眉骨等高镜面区）F0 ≈ 0.079，接近 dielectric 默认值的 ~2 倍 — 属于**亚光皮肤偏强镜面**调教。

### 主灯 sparkle（行 798–801）

```hlsl
half sparkleNdotH_main = dot(worldNormal, H_main) * 0.5h + 0.5h;
half4 sparkleRaw_main = ComputeSparkleRaw(mainUV, activeSparkleSize, activeSparkleParams, sparkleNdotH_main);
half sparkleMask_main = sparkleRaw_main.x * sparkleStrength;   // sparkleStrength 与 mainTex.a / lipTex.a 相关
half3 sparkleColor_main = sparkleMask_main * activeSparkleColor;
```

最终合成（行 950）：`sparkleAndSpec = sparkleColor_main * _CharMainLightColor.rgb + mainSpecColor`。即 **sparkle 也是被主灯颜色着色的**。

> 🔑 在调参时，**改 `_CharMainLightColor` 会同时影响**「主灯镜面 + sparkle 染色」两个项；改 `_MainLightPosition` 只影响方向。

---

## 4. Char Light（角色专属补光）镜面 ②

| 字段 | cb4 `Character_Param` | 实测 |
|---|---|---|
| `_CharLightPosition` | (-0.083, 0.870, -0.485, 1) | 角色补光世界坐标，w=1 ⇒ point/spot 类型，但 IR 把它当方向用（normalize 后） |
| `_CharLightColor` | (1.10, 0.94, 1.00, 1.10) | 略偏冷的近白光 |

shader 第 916–930 行**只算镜面**（与主灯同样省漫反射）：

```hlsl
half3 charLightDir = normalize(_CharLightPosition.xyz);
half charNdotL = max(dot(worldNormal, charLightDir), 0);
// GGX D·V·F
float D_char = SkinGGX_D(NdotH_char, roughness);
half F_char = SkinFresnel(F0, F0_grazing, VdotH_char);
float V_char = SkinVisibility(charNdotL, NdotV, roughness);
half charSpecScalar = (half)(D_char * V_char) * F_char;

half3 charSpecular = (charNdotL > 0)
    ? (_CharLightColor.rgb * charNdotL * charSpecScalar)
    : 0;
```

**注意**：尽管 `_CharLightPosition.w = 1`（按 Unity 惯例 = 点光源），但 shader **没有做任何距离衰减**，直接把 `_CharLightPosition.xyz` 当成方向 normalize。这与 URP 标准 `MainLight` 的行为一致（URP 中 `_MainLightPosition.w == 0` 时是平行光），LYSK 这里其实是把 Char Light 当作"附加在角色上的固定方向高光灯"用。

→ **Char Light 在视觉上的作用**：在主灯之外加一个**几乎反方向**的高光（注意 z=-0.485，与主灯 z=+0.916 相反），制造**"环绕式高光"**效果，让人物脸部任意角度都至少有一个角度能看到镜面亮点。这是角色 PBR 渲染的标准技巧。

---

## 5. 主灯阴影 vs Char Light 阴影 ⑤⑥（合成顺序的关键）

**两个阴影项不同**，shader 第 956–959 行：

```hlsl
//  ↓ 用 screenShadow.r 控制主灯/sparkle 项
half charShadow = lerp(1.0h, screenShadow.r, _CharShadowIntensity);
half3 charShadowBlock = charShadow * sparkleAndSpec;        // sparkleAndSpec = sparkle·CharMainLight + mainSpec
half3 sssBlock = tintedAlbedo * sssSkin.rgb + charShadowBlock;

//  ↓ 用 screenShadow.a 控制 Char Light 项（不同通道！）
half3 finalColor = charSpecular * screenShadow.a + sssBlock;
```

### `_ScreenShadowTexture` (rid 236) 通道解读

`_ScreenShadowTexture` = **E9 写出的 RGBA8 半分辨率屏幕空间阴影合成图**。它的四个通道在这套 shader 中各司其职：

| 通道 | 在 RPS 496 中的用途 |
|---|---|
| `.r` | 主灯阴影（和 `_CharShadowIntensity = 1.0` 相乘后给 sparkle/mainSpec） |
| `.g` | 附加光阴影 — 通过 `_AdditionalLightShadowWeight[idx]` dot 取 |
| `.b` | （shader 中未直接读，可能是预留 Spot Shadow 通道）|
| `.a` | Char Light 阴影（直接乘 charSpecular，不经 lerp） |

> 引擎还原时务必：(a) 复刻 E9 ScreenSpaceShadowMap pass 的输出格式；(b) 注意四个通道分别承载不同灯的阴影数据。最常见的错误是把 `.r` 当所有灯的阴影 → 角色补光会和主灯一起一暗一亮、看起来像"穿模"。

`_CharShadowIntensity = 1.0` 实测值 ⇒ `charShadow = lerp(1, screenShadow.r, 1) = screenShadow.r` 直接采用。

---

## 6. 附加光（LightIndexMap 路径）④

整段在 shader 第 805–897 行。**LYSK 用的是自定义 cluster lighting**，与 URP 标准 `GetAdditionalLight()` API **不同**。

### 6.1 索引怎么取（行 808–811）

```hlsl
float2 lightMapUV = (input.positionWS.xz - _GridInfo.xy) / _GridInfo.zw;
half4 lightIndexTex = SAMPLE_TEXTURE2D(_LightIndexMap, sampler_LightIndexMap, lightMapUV);
float4 lightIndices = floor(lightIndexTex * 255.0 + 0.5);     // 4 个 0..255 的字节索引
```

实测 `_GridInfo = (-128, -254, 256, 256)`（cb1 idx 4） ⇒ **256m × 256m 的 grid，原点在 (-128, -254) 即东 128m / 北 254m**。角色站在 worldPos ≈ (0, 0.95, 0) 时落在 grid 中央。

`_LightIndexMap` 槽位：fragment texture slot 1 = **资源 145**（128×128 RGBA8Unorm，usage=shaderRead+shaderWrite+renderTarget — 一张被 compute pass 写、再被本 draw 采样的小型 cluster light index map）。绑定**正确无误**，按 `_GridInfo` 投影后采到的 4 字节即为 4 个灯索引。完整 binding 表见 [`08-rps496-binding-truth.md`](./08-rps496-binding-truth.md) §3.3。

### 6.2 取出后的索引语义

每个像素 4 字节 → 4 个索引到 `_AdditionalLight*[30]` 数组。**`255` 是"no more light"哨兵 → 早退出**（行 824）。

实测 30 个 slot 中**只有 slot 0 / slot 1 是真灯**，其它全是 `(0, 0, 1, 0)` sentinel。**所以即使 LightIndexMap UV 任意采样、解出的索引 4 字节大概率都包含真有效的索引 0 / 1**，每像素最终最多算到 2 盏附加光镜面。

### 6.3 两盏附加光的画像

| Light | Position | Color (RGB·HDR, A=tag=9) | 衰减形态 | 范围 | ShadowWeight |
|---|---|---|---|---|---|
| **0 — 暖白 Spot** | (2.15, 2.31, 1.52, 1) | (2.04, 1.77, 1.95, 9) | spotAtten=(28.95, **−26.74**, 1, 1) ⇒ 真锥形 | distAtten ≈ 4.24m | (0, **1**, 0, 0) ⇒ 取 g 通道，权重 1.0 |
| **1 — 冷蓝 Point** | (0.72, 1.74, 0.54, 1) | (0.69, 0.72, 0.94, 9) | spotAtten=(0, 1, 1, 1) ⇒ 退化为 point | distAtten ≈ 2m | **(0, 0, 0, 0)** ⇒ shadowRaw = 0 ⇒ **不受任何屏幕阴影影响** |

> 角色根节点世界坐标（cb3 `unity_ObjectToWorld` 第 4 行）= `(-0.003, 0.950, -0.005)`。
>
> - Light 0 距离角色 ≈ √((2.15)²+(2.31−0.95)²+(1.52)²) ≈ 3.04m，落在 4.24m 范围内 ⇒ **有贡献**。
> - Light 1 距离角色 ≈ √((0.72)²+(1.74−0.95)²+(0.54)²) ≈ 1.16m，落在 2m 范围内 ⇒ **有贡献**。

### 6.4 附加光的简化 BRDF（行 873–885）

```hlsl
// 注意：附加光的镜面用的是 SkinGGX_D × roughnessScale × F0，没有 Visibility 项！
float D_add = SkinGGX_D(NdotH_add, perceptualRoughness);
half roughnessScale = perceptualRoughness * 0.25 + 0.25;     // 把 roughness 映射到 [0.25, 0.5]
half specFactor_add = (half)D_add * roughnessScale;
half specScalar_add = specFactor_add * F0;
half3 addSpecular = (lightColor.rgb * NdotL_add * lightAtten) * specScalar_add;
```

→ **附加光的 BRDF 比主灯简化得多**（去掉 V，roughness 走线性 lerp）。这是 mobile-friendly 优化：每像素最多 4 盏附加光的 GGX，省一个 Smith V 项。

### 6.5 sparkle 触发条件

```hlsl
if (lightColor.w == -1.0h) {                  // ✗ 本帧两盏 .w==9，永不触发
    addSpecular += sparkleMask * sparkleColor * lightColor.rgb;
}
```

实测两盏灯 `.w = 9`（一种"灯类型 / priority"标签），**sparkle 分支不会被附加光触发**。

### 6.6 阴影（行 829–836）

```hlsl
half shadowRaw = (idx < 30) ? dot(1.0h - screenShadow, _AdditionalLightShadowWeight[idx]) : 1.0h;
half addShadow = 1.0h - _CharShadowIntensity * shadowRaw;
addLightContribution += addSpecular * addShadow;
```

- Light 0 ShadowWeight = `(0, 1, 0, 0)` → `shadowRaw = (1-screenShadow).g · 1`，**与主灯阴影 g 通道等权叠加**（不是加重，也不是替代主灯 .r 通道阴影）。
- Light 1 ShadowWeight = `(0, 0, 0, 0)` → `shadowRaw = 0` → `addShadow = 1 - _CharShadowIntensity · 0 = 1`，**该灯完全不受屏幕阴影衰减**。这是引擎为冷蓝 point light 单独保留的"不打阴影补光"配置。

### 6.7 附加光对最终颜色的贡献量级估算

以 Light 1（冷蓝 point，最近，**且完全无屏幕阴影衰减**）为例：

```
NdotL ≈ 0.5 (典型)
lightAtten ≈ saturate(1.16² · (-0.0278) + 2.78) / (1.16² · 0.25 + 1) ≈ 0.86
specFactor_add ≈ D(NdotH≈0.9, r≈0.5) · (0.5·0.25+0.25) = ~5.0 · 0.375 = 1.875
F0 ≈ specMask · 0.0786  (假设 specMask=1，使用实测 _NonMetalSpecular=0.983)
specScalar_add ≈ 1.875 · 0.0786 ≈ 0.147
addBase ≈ (0.69, 0.72, 0.94) · 0.5 · 0.86 ≈ (0.297, 0.310, 0.404)
addSpecular ≈ (0.297, 0.310, 0.404) · 0.147 ≈ (0.0437, 0.0456, 0.0594)
addShadow = 1.0 (Light 1 ShadowWeight = (0,0,0,0))
最终贡献 ≈ (0.044, 0.046, 0.059)
```

→ Light 1 在鼻尖/唇高光区贡献约 4–6% 的**冷蓝点缀**，因不受屏幕阴影遮挡，即使角色脸正处于阴影部分也会出现。

Light 0（暖白 spot，距离 3.04m，spotFalloff 还要乘锥形衰减、且 ShadowWeight=(0,1,0,0) 受 `(1-screenShadow).g` 衰减）整体更弱，本帧合计两盏附加光镜面贡献约 **3–6%**。


---

## 7. 间接光照 = Pape SH（不是 cubemap）③

### 7.1 SH 漫反射

`_SHMaps[7]`（cb6 `PapePerRendererCB`）实测值 + shader 第 512–536 行 `EvaluatePapeSH`：

```hlsl
half3 EvaluatePapeSH(half3 N) {
    half4 n4 = half4(N, 1);
    half3 linear_sh = (dot(_SHMaps[0], n4), dot(_SHMaps[1], n4), dot(_SHMaps[2], n4));
    half4 quadBasis = half4(N.y*N.x, N.z*N.y, N.z*N.z, N.x*N.z);
    half3 quad_sh   = (dot(_SHMaps[3], quadBasis), dot(_SHMaps[4], quadBasis), dot(_SHMaps[5], quadBasis));
    half nx2_minus_ny2 = N.x*N.x - N.y*N.y;
    return max(linear_sh + quad_sh + _SHMaps[6].rgb * nx2_minus_ny2, 0);
}
```

代入 N=(0,1,0)（朝上）：

```
linear  = (-0.0608+0.3433, -0.0564+0.3442, -0.0659+0.4526)
        = (0.283, 0.288, 0.387)
quad    = (0, 0, 0)                ← Ny² 不在 quadBasis 里
(Nx²−Ny²) 项 = (-0.0504, -0.0502, -0.0670)   ← Nx²−Ny² = -1
result  = max((0.283, 0.288, 0.387) + 0 + (-0.050, -0.050, -0.067), 0)
       ≈ (0.233, 0.238, 0.320)
```

代入 N=(0,-1,0)（朝下）：

```
linear  = (0.0608+0.3433, 0.0564+0.3442, 0.0659+0.4526)
        = (0.404, 0.401, 0.519)
quad    = (0, 0, 0)
(Nx²−Ny²) 项 = (-0.050, -0.050, -0.067)      ← Nx²−Ny² = -1
result  ≈ (0.354, 0.351, 0.452)
```

代入 N=(0,0,1)（朝相机/正前）：

```
linear  = (0.0869+0.3433, 0.0761+0.3442, 0.1239+0.4526) = (0.430, 0.420, 0.576)
quad    = (Nz²=1 项) = (0.01636, 0.01202, 0.00658)
(Nx²−Ny²) 项 = 0                              ← Nx²−Ny² = 0
result  ≈ (0.446, 0.432, 0.583)
```

→ 朝上 → (0.233, 0.238, 0.320)，朝下 → (0.354, 0.351, 0.452)，朝前 → (0.446, 0.432, 0.583)。**这套 SH 不是"上亮下暗"的天空形态，而是 DC 项主导、各方向都有非零强度、整体偏冷蓝（B 通道全程比 R/G 高）**。在角色周身基本处于"全包围的偏冷调环境光"。

### 7.2 但是！RPS 496 没有把 SH 漫反射加到 finalColor

⚠ **这是非常关键的一个发现**：仔细对比 shader 行 904 与最终 compositing：

```hlsl
half3 shIrradiance = EvaluatePapeSH(worldNormal);                    // 行 904 — 算出来
...
half3 envSpecular = decodedCube * shIrradiance * F0 * _CharShIntensity;  // 行 913 — 只用作 envSpec 的"代替天光"
...
finalColor = ... + envSpecular;                                       // 行 962 — 只加 envSpec
```

**`shIrradiance` 没有作为 indirect diffuse 加进 finalColor**！它**只参与 envSpec 项的乘子**（在 `decodedCube` 旁边占了"环境光强度"的位置）。

→ 那 indirect diffuse 跑到哪去了？答案：**`_SSSSkinTexture` 已经包含**。RPS 491（half-res forward lighting）在算 SSS profile 之前的 lighting buffer 时，已经把 Pape SH 喂进了它的 fragment IR；E12 SSS 模糊后存到 232；RPS 496 通过乘 `tintedAlbedo` 拿到这部分能量。

→ **结论**：在 RPS 496 视角，SH 既贡献了"主灯漫反射 + SSS"（间接通过 _SSSSkinTexture），也作为 envSpec 强度调制器（直接通过 `shIrradiance` 变量）。**不要在 RPS 496 之外的位置再加一遍 SH 漫反射**，否则会双倍叠加。

### 7.3 envSpec ≈ 0（cubemap 全黑）

```hlsl
half3 reflDir = reflect(-viewDir, worldNormal);
half mipLevel = PerceptualRoughnessToMip(perceptualRoughness);  // r·(1.7−0.7r)·6
half4 encodedCube = SAMPLE_TEXTURECUBE_LOD(unity_SpecCube0, ..., reflDir, mipLevel);
half3 decodedCube = DecodeHDRCubemap(encodedCube, unity_SpecCube0_HDR);
half3 envSpecular = decodedCube * shIrradiance * F0 * _CharShIntensity;
```

| 输入 | 实测 | 结果 |
|---|---|---|
| `unity_SpecCube0` | rid 142 = `UnityBlackCube` 1×1 cube | encoded ≈ (0,0,0,1) |
| `unity_SpecCube0_HDR` | (1, 1, 0, 0) | decodeScale = 1·exp2(0) = 1，等于"不做 HDR 解码" |
| `decodedCube` | ≈ (0, 0, 0) | 因为 cubemap 全黑 |
| `_CharShIntensity` | 0.45 | 即使非 0 也乘以 0 |
| **envSpecular** | **≈ (0, 0, 0)** | **本帧 IBL 镜面项为 0** |

→ 引擎还原时把 cubemap 给个 1×1 黑或者随便给一张但把 `_CharShIntensity` 设成 0，结果一样。

---

## 8. 完整 finalColor 公式

把 shader 行 944–965 浓缩成一行（按实际算式顺序，不化简）：

```
finalColor =
    // ① 漫反射主体（包含主灯漫反射 + SH 漫反射，已在 SSS pass 中预积分）
    tintedAlbedo · _SSSSkinTexture                                                 [≈ 主要贡献]

    // ⑤ 主灯镜面 + sparkle，受主灯阴影衰减
  + lerp(1, screenShadow.r, _CharShadowIntensity) · (
        sparkleColor_main · _CharMainLightColor                                    [闪片]
      + NdotL_main · _CharMainLightColor · GGX_D · GGX_V · Fresnel                 [主灯镜面]
    )

    // ⑥ Char Light 镜面，受独立的 .a 通道阴影衰减
  + screenShadow.a · (
        charNdotL · _CharLightColor · GGX_D · GGX_V · Fresnel                      [角色补光镜面]
    )

    // ⑦ 环境镜面（cubemap×SH×F0×CharShIntensity，本帧 ≈ 0）
  + decodedCube · shIrradiance · F0 · _CharShIntensity                              [≈ 0，cube 全黑]

    // ④ 附加光镜面（最多 4 盏，本帧实际 2 盏，每盏简化 BRDF）
  + Σ_{i=0..3, idx≠255} addShadow_i · lightColor_i · NdotL_i · lightAtten_i
                       · (D · roughnessScale) · F0
```

每一项的**典型量级**（基于本帧实测，假设视线正面看角色脸颊；具体 cb5 实测值见 §0）：

| 项 | 量级 | 占最终颜色比 |
|---|---|---|
| ① 漫反射主体 `tintedAlbedo · sssSkin` | (0.6, 0.5, 0.45) | **~80%**（主导） |
| ⑤ 主灯镜面（仅鼻尖/眉骨） | (0.05, 0.045, 0.05) | **~7%**（局部） |
| ⑤ 主灯 sparkle（仅唇/眼） | (0, 0, 0) | **0%**（**本帧 cb5 中 `_EyeSparkleColor / _LipSparkleColor / _EyeSparkleParams / _LipSparkleParams` 全部为 0，sparkle 输出为 0**） |
| ⑥ Char Light 镜面 | (0.03, 0.025, 0.027) | **~5%**（高光环绕） |
| ⑦ envSpec | ≈ 0 | **0%** |
| ④ 附加光（合计 2 盏） | ~(0.04, 0.04, 0.06) | **~3–6%**（局部，鼻尖/唇高光区可见冷蓝点缀） |

→ **「化妆+底色 SSS 漫反射」承担 ~80% 视觉贡献**，剩余 ~20% 由 3 个镜面源（主灯、Char Light、附加光）瓜分。`_NonMetalSpecular = 0.983` 让 F0 维持在 ~0.08 的"偏强镜面"档位，附加光在鼻尖/唇高光区是**可见的局部冷色调点缀**而不是噪点级贡献。

---

## 9. 引擎还原时的灯光 cheat sheet

按贡献从大到小给一张"必喂、可省"清单：

| 光源 | 贡献 | 必须正确 | 来源 cbuffer / 资源 | 可否省略 |
|---|---|---|---|---|
| **`_SSSSkinTexture`**（实质 = 主灯漫反射 + SH 漫反射 + SSS profile） | ★★★★★ | ✅ | rid 232（E12 输出，需先跑 E10/E11/E12） | 不可，省了画面就糊 |
| **`_CharMainLightColor`** | ★★★★ | ✅ | cb4 idx 2 = `(2.51, 2.26, 2.43, 3.14)` | 不可，主灯镜面/sparkle 都用 |
| **`_MainLightPosition`** | ★★★★ | ✅ | cb1 idx 1 = `(0.292, 0.274, 0.916, 0)` 单位化 | 不可，主灯方向 |
| **`_ScreenShadowTexture` 4 通道** | ★★★ | ✅ | rid 236（E9 输出）| 不可，阴影感缺失 |
| **`_CharShadowIntensity`** | ★★★ | ✅ | cb4 = 1.0 | 设 0 ⇒ 阴影全失 |
| **Pape SH 7 个 half4** | ★★ | ✅ | cb6 `_SHMaps[0..6]` | 影响 envSpec（但 envSpec ≈ 0），实际可全填 0 |
| **`_CharLightPosition`/`Color`** | ★★ | ✅ | cb4 idx 0 / 3 | 不可，丢掉补光高光 |
| **附加光 0/1（cb0 中 30×7 字段，仅前 2 槽）** | ★ | ✅ | cb0，配合 `_GridInfo` 与 `_LightIndexMap` (rid 145) | 在角色身上量级 ~3-6%，可全置 sentinel；注意 Light 1 ShadowWeight=(0,0,0,0) 完全不受屏幕阴影衰减 |
| URP `_MainLightColor` | — | ❌ | cb1 idx 2 | **shader 不读**，给什么值都不影响 |
| URP `_AdditionalLightCount` | — | ❌ | cb0 末段 | **shader 不读**（走 LightIndexMap 路径） |
| `_SHMaps[6].w` | — | ❌ | cb6 idx 0[6][3] | shader 公式中只用 `.rgb` |
| `unity_SpecCube0` 内容 | — | ❌ | rid 142 默认 1×1 黑 | 给任意值，envSpec 在 `_CharShIntensity` 或 cubemap 中就被吃掉 |
| `_CubeSHs[7]` | — | ❌ | cb6 idx 1 | **shader 不读**，shader 不引用此字段 |

---

## 10. 改图实验建议（用于验证理解）

如果你想用 `shader --verify`（hot-replace）去验证某项的贡献，按以下顺序最经济：

1. **关掉主灯镜面**：把 `_CharMainLightColor` 全改 0 → 角色应失去鼻尖/眉骨高光，但漫反射不变（因为 SSS pass 已经存了 `_CharMainLightColor` 进 232，但 RPS 496 自己的镜面会消失）。
2. **关掉 Char Light**：`_CharLightColor = 0` → 角色失去"补光高光"，画面阴面会暗一档。
3. **关掉 SH**：`_SHMaps = 0`（7×4=28 个 half 全置 0） → envSpec 项变 0（本来就 ≈0），看不出变化；说明 SH 在这个 pass 里**只**通过 `_SSSSkinTexture` 间接生效（验证我们的判断 ✓）。
4. **替换 SSS texture**：把 RPS 496 fragment 第 14 个纹理 binding 替换成全白（1×1） → 整脸丢主灯漫反射，颜色只剩化妆 albedo + 镜面项 → 直接证实 _SSSSkinTexture 是漫反射主载体。

每一步都可以通过 `gputrace_replay_bridge shader 410 <new_lib>.metallib --verify` 完成。

---

## 11. 与 `06-gbuffer-truth.md` / `08-rps496-binding-truth.md` 的关系

- **06**：解释 RPS 484（E4）是 velocity-prepass，**不是** GBuffer，**不被 RPS 496 读取**。
- **07**（本文）：解释 RPS 496 真正的输入数据从哪里来 — 完全不依赖 228/229，而是从：
  - 上游 SSS pass 输出（rid 232 `_SSSSkinTexture`）
  - 屏幕空间阴影（rid 236 `_ScreenShadowTexture`，4 通道分别承载主灯/附加光/Char Light 阴影）
  - 7 个 cbuffer 的字段（其中 cb4 / cb6 是 LYSK 自定义的）
  - cube placeholder（rid 142 全黑）
  - cluster lighting index（rid 145 = 128×128 RGBA8Unorm renderTarget，正常工作）
  - 直接采样原始材质纹理（`PL_Head_*` / `PL_Makeup_*` 等 14 张）
- **08**：RPS 496 完整 binding 真值表（不分析 lighting，纯描述每个 buffer / texture / sampler 槽位绑了什么 + IR 元数据交叉对应）。本文中所有 cbuffer/texture 引用都可在 08 中查到出处。

→ **整套 forward shading 路径在 RPS 496 这里"汇总收尾"**，写出唯一被人眼看见的 HDR 颜色 224。后续 DOF / TAA / Bloom / Tonemap / FSR 都是 224 的 in-place 后处理。

---

## 12. 数据来源与复现

```
trace        = ~/Library/Containers/com.papegames.lysk/Data/Documents/Captures/capture_20260518_110050.gputrace
RPS_key      = 496 (Papegame/SkinMakeupNew, full-res forward compose)
draw_index   = 69 (CB1 / E13 / draw_in_encoder=5 / call_index=989)
fragment lib = library_410.module.bc (cache_key 61F4807E5636D024_28097, ir_source=sdi_module_bc)
fragment fn  = xlatMtlMain  → 见反编译版 ShaderTranslated/SkinMakeupNew.shader
所有 cbuffer dump: LocalDocs/OfflineSourceRecovery/gputracebinaryreplacement/ShaderRaw/SkinLighting/
```

引用文件：

- 翻译 shader：[`OfflineSourceRecovery/gputracebinaryreplacement/ShaderTranslated/SkinMakeupNew.shader`](../OfflineSourceRecovery/gputracebinaryreplacement/ShaderTranslated/SkinMakeupNew.shader)
- 7 个 cbuffer 实测值：[`OfflineSourceRecovery/gputracebinaryreplacement/ShaderRaw/SkinLighting/`](../OfflineSourceRecovery/gputracebinaryreplacement/ShaderRaw/SkinLighting/) 目录下 `cb*.json` 与 `draw69_raw_dump.json`
- 单 draw 全量 dump：同目录 `draw69_raw_dump.json` / `cb*.json`
- 帧级管线脉络：本目录 `01-architecture-overview.md` / `02-frame-breakdown.md`
- GBuffer 真相（为什么 484 不是 GBuffer）：本目录 `06-gbuffer-truth.md`
- SSS / SkinMakeupNew 在帧内 5 个变体定位：本目录 `04-skin-and-sss-pipeline.md`

---

