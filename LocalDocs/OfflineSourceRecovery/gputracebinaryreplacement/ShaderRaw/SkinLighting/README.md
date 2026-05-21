# RPS 496 SkinMakeupNew — Lighting / IBL / Environment Inputs

捕获文件：`~/Library/Containers/com.papegames.lysk/Data/Documents/Captures/capture_20260518_110050.gputrace`
绘制：CB1 / E13 / draw_index_global = **69** (call_index 989)
RPS：**496** `Papegame/SkinMakeupNew`，全分辨率主着色 pass，写到 `224 TempBuffer 118 1167×1671 RGBA16F`（HDR 主场景颜色）。

> 同一 frame 还有 RPS 484 (E4 GBuffer)、RPS 491 (E10 half-res SSS pre-blur)、RPS 476 (E2 Z-prepass) 也使用 SkinMakeupNew，但着色逻辑不同。本文件只针对 **RPS 496** —— 即 Unity shader 翻译版 (`ShaderTranslated/SkinMakeupNew.shader`) 实际对应的 pass。

CB1/CB3 是 ping-pong 双缓冲，本文件的所有数值取自 CB1 (draw 69)；CB3 的对偶 draw 是 191，cbuffer 内容差异极小（仅 `_PrevTime/_LastFrameTexture` ping-pong），结论一致。

---

## 1. 总览

恋与深空（LYSK）此帧是**室内/Home 场景**。最重要的数据特征：

> **关于 shader 是否真的用了某个 cbuffer 字段** —— 后文所有"是否被使用"的判断都是直接核对 RPS 496 fragment IR (`library_410.ll`) 里的 GEP 索引得到的，**不是从值是否为 0 倒推**。RPS 496 fragment 对 `AsukaPerShader_PerCamera` 只访问 field idx `{1, 4, 7, 8}`，对应 `_MainLightPosition` / `_GridInfo` / `_DOFEnable` / `_GlobalMipBias`；其它字段（包括 `_MainLightColor`、`_MainLightRealtime`、`hlslcc_mtx4x4_WorldToLight`、`_ScaledScreenParams`、`_AuroraGridInfo`）整段 shader 都不读。RPS 484 GBuffer / RPS 476 Z-prepass 的 fragment 甚至完全不绑定这个 cbuffer。

| 现象 | 实际数值 | 含义 |
|---|---|---|
| `_MainLightColor` | (0, 0, 0, 1.875) | **shader 根本不读这个字段**（IR 中无 GEP idx 2）。它的值 0 不影响渲染，只是引擎层面碰巧没填 |
| `_MainLightRealtime` | 0 | 同上，**shader 不读这个字段**（IR 中无 GEP idx 6）。它在 RPS 496 fragment 里是死参数；可能仅供 CPU 端或其它 shader 变体使用 |
| `_MainLightPosition` | (0.292, 0.274, 0.916, 0) | ⭐ **shader 实际读这个**（idx 1），作为 GGX 主灯方向（w=0 ⇒ 平行光） |
| `unity_SpecCube0` | 1×1 BlackCube (resource 142) | **没有 reflection probe** —— 只用 black cube placeholder |
| `_CubeSHs[0..6]` | 全 0 | cubemap-derived SH 也关闭 |
| `_SHMaps[0..6]` | 见下 | **唯一的环境光来源 = 烘焙的 Pape SH** |
| `_CharMainLightColor` | (2.514, 2.260, 2.430, 3.141) | 角色专属"主灯" 颜色，HDR 强度（接近白偏暖） |
| `_CharLightColor` | (1.100, 0.936, 0.998, 1.100) | 角色专属补光，略偏冷 |
| `_AdditionalLightCount` | (0,0,0,0) | shader 不通过 count 循环 |
| `_LightIndexMap` (Tex 217) | 512×512 ASTC sRGB | **以世界空间 XZ 为 UV 采 4 个 byte 索引到附加光阵列**（这是项目自定义的 cluster lighting 索引图） |
| 30 个附加光中"活跃"项 | **2**（slot 0、slot 1） | 其余 28 个为 sentinel `(0,0,1,0)` |

也就是说 RPS 496 的光照公式实际配置为：

```
finalColor = SSS(tintedAlbedo, _SSSSkinTexture)             // 主漫反射，已含主灯效果（在 E11/E12 SSS 模糊里）
           + charSpecular (CharLight, GGX D*V*F)            // 角色补光镜面
           + sparkle*_CharMainLightColor + mainSpec         // sparkle + 主灯镜面（即使 _MainLightColor=0，_CharMainLightColor 仍乘进来）
           + envSpecular = decodedCube * SH * F0 * _CharShIntensity  // ≈ 0（cube 全黑）
           + Σ additionalLights (从 LightIndexMap 索引出的最多 4 盏)
```

简化结论：**画面里的环境光 ≈ Pape SH 漫反射 + 2 盏附加光的镜面项 + Char 双灯镜面项**。Reflection cube 与 _MainLightColor 都不贡献。

---

## 2. 文件清单

| 文件 | 含义 |
|---|---|
| `README.md` | 本说明 |
| `draw69_raw_dump.json` | bridge 一次性 dump 的全量结构（bindings + 所有 cbuffer reflection-decoded） |
| `cb0_AsukaPerShader_AddLightParams_PerCamera.json` | bridge 解码（注：bridge 把数组截断到 16，参考下面那一份） |
| **`cb0_AddLightParams_full30.json`** | **手工解出的全部 30 个 light entry**（30×7 字段） |
| **`cb0_AddLightParams_active_lights.json`** | **只列出活跃 2 盏的精简版** —— 还原引擎时直接用这份 |
| `cb1_AsukaPerShader_PerCamera.json` | URP/Asuka 的 per-camera：MainLight、Grid 等 |
| `cb2_UnityPerCamera.json` | 标准 Unity per-camera：相机位置/投影/时间 |
| `cb3_UnityPerDraw.json` | 标准 Unity per-draw：模型矩阵、`unity_SpecCube0_HDR` |
| `cb4_Character_Param.json` | **Papegame 角色专属灯光块**（CharMainLight / CharLight / CharShIntensity 等） |
| `cb5_UnityPerMaterial.json` | 完整材质参数（69 个字段，与翻译 shader 字段一一对应） |
| `cb6_PapePerRendererCB.json` | **Pape SH 探针 (`_SHMaps[7]`)**、cubemap SH、植被参数等 |

---

## 3. 七个 Constant Buffer 的详细解读

### CB0 `AsukaPerShader_AddLightParams_PerCamera`（2176 字节）

每帧最多 30 盏附加光，按结构数组（SoA）摆放。本帧实际使用 **2 盏**（其余 28 个 slot 是 sentinel）：

#### Light 0 — Spot Light（暖白）

| 字段 | 值 | 说明 |
|---|---|---|
| `_AdditionalLightPosition[0]` | (2.1467, 2.3071, 1.5163, 1) | 世界坐标位置 (w=1 ⇒ 点/聚光) |
| `_AdditionalLightColor[0]` | (2.043, 1.774, 1.954, 9) | RGB HDR 颜色（暖白），A=9（项目内自定义的灯类型/优先级 tag） |
| `_AdditionalLightSpotAttenuation[0]` | (28.946, **-26.743**, 1, 1) | 标准 URP `(1/(cosI-cosO), -cosO/(cosI-cosO))`；负 y 表示是 **真正的 spot**，不是 point |
| `_AdditionalLightDistanceAttenuation[0]` | (0.05551, -0.00617, 2.7773, 1) | URP 距离衰减 `saturate(d²·x + y) / (d²·z + 1)`，光照半径 ≈ √(1/0.0555) ≈ 4.24m |
| `_AdditionalLightSpotDir[0]` | (1, 0, 0.7983, 0.2818) | 注意这一组数值看起来像是被打包了 (xyz=方向 (1, 0, 0.798)，w=另一参数 0.282)；引擎可能把 `lightSpotDir.xyz` 当方向用，**w 不参与 IR 中的 spot 计算** |
| `_AdditionalLightShadowWeight[0]` | (0, 1.875, 0, 0) | 4 通道 dot 系数，决定从 _ScreenShadowTexture 的哪一通道取阴影。本灯 shadowWeight.g=1.875 → 取屏幕阴影 G 通道 |

#### Light 1 — Point Light（冷白）

| 字段 | 值 | 说明 |
|---|---|---|
| `_AdditionalLightPosition[1]` | (0.722, 1.742, 0.538, 1) | 世界坐标 |
| `_AdditionalLightColor[1]` | (0.692, 0.718, 0.942, 9) | 冷蓝调，强度 < L0 |
| `_AdditionalLightSpotAttenuation[1]` | (0, 1, 1, 1) | x=0 ⇒ 退化为 1（point 光） |
| `_AdditionalLightDistanceAttenuation[1]` | (0.25, -0.02777, 2.7773, 1) | 半径 ≈ 2m（更近距离） |
| `_AdditionalLightSpotDir[1]` | (0.5322, 1, 0, 0) | point 光 SpotDir 一般无意义 |
| `_AdditionalLightShadowWeight[1]` | (0, 1, 0, 0) | 取屏幕阴影 G 通道 |

> shader 中 `if (lightColor.w == -1) { sparkle 分支 }` 不会触发（两盏灯 .w==9）。

`_AdditionalLightCount = (0,0,0,0)` 不是 bug —— 这版 shader 走的是 LightIndexMap 路线：在 fragment shader 中把 worldPos.xz 投影到 `_GridInfo` 定义的 4×4=128–254m 网格（见 cb1 中 `_GridInfo=(-128,-254,256,256)`）采样 `_LightIndexMap`(Tex 217)，每个像素的 RGBA 4 个 byte 直接索引 `_AdditionalLight*[idx]` 数组，索引值 `255` 是 "no more light" 哨兵。

### CB1 `AsukaPerShader_PerCamera`（144 字节）

```jsonc
{
  "hlslcc_mtx4x4_WorldToLight": [[0,1,0,1],[0,1,0,1],[0,1,0,1],[0,1,0,1]],  // shader 不读（IR 无 idx 0）
  "_MainLightPosition":  [0.292204, 0.274464, 0.916126, 0],   // ✓ shader 读（idx 1） — 主灯方向，w=0
  "_MainLightColor":     [0, 0, 0, 1.875],                    // ✗ shader 不读（IR 无 idx 2）；值为 0 不影响最终着色
  "_ScaledScreenParams": [0, 0, 0, 1.875],                    // ✗ shader 不读（IR 无 idx 3）
  "_GridInfo":           [-128, -254, 256, 256],              // ✓ shader 读（idx 4） — LightIndexMap 网格 origin/size
  "_AuroraGridInfo":     [0, 1, 0, 1],                        // ✗ shader 不读（IR 无 idx 5）
  "_MainLightRealtime":  0,                                   // ✗ shader 不读（IR 无 idx 6）；值为 0 不影响渲染
  "_DOFEnable":          1,                                   // ✓ shader 读（idx 7） — 控制 DOF alpha 输出
  "_GlobalMipBias":      -1.51465                             // ✓ shader 读（idx 8） — _MainTex/_NormalTex 的 mip bias
}
```

**关于 `_MainLightColor` 与 `_MainLightRealtime` 的判定**：在我之前的版本里写"主灯关闭"是值层面的描述，并不准确——RPS 496 的 fragment shader 完全没去读这两个字段。也就是说，**就算你把 `_MainLightColor` 填成 (1,1,1)、把 `_MainLightRealtime` 填成 1，RPS 496 输出像素一比特都不会变**。它们只是 `AsukaPerShader_PerCamera` 这个 cbuffer 在所有 shader（含其它非 SkinMakeupNew 材质）共享布局里的预留 slot。

**对引擎集成的关键提示**：shader 实际"主灯颜色"的来源是 cb4 的 **`_CharMainLightColor`** —— 在 RPS 496 fragment IR 里它出现在主灯 GGX 镜面项的乘数位置：`mainSpecColor = NdotL * _CharMainLightColor.rgb * mainSpecScalar`，并且 sparkle 终值也乘了它。`_MainLightPosition`（来自 cb1，shader **真的会读**）提供主灯方向。所以还原时不要试图把 `_MainLightColor` 喂进去 —— 把 `_CharMainLightColor` 直接当作主灯颜色用。

### CB2 `UnityPerCamera`（320 字节）

```jsonc
{
  "_Time":           [0,0,0,0],          // 未启用（home 场景静态？）
  "_SinTime":        [0,0,0,0],
  "_CosTime":        [0,0,0,0],
  "_TimeParameters": [0,0,0,0],
  "unity_DeltaTime": [0,0,0,0],
  "_WorldSpaceCameraPos":         [0, 1.41176, 1.17663],          // ⚠ 实际相机世界坐标
  "_WorldSpaceRelativeCameraPos": [0, 1.41176, 1.17663],          // 与 absolute 相同 → 没有 origin shifting
  "_EyeAdaptionExposure":         0,
  "_EyeAdaptionInverseExposure":  -5.336,
  "_WorldSpaceCameraDir":         [0, -3.7273, 0],                // 看起来是 forward 向量但模长不为 1，是 raw rate
  "_ProjectionParams":            [-1, 0.1, 5000, 0.0002],        // x=-1 ⇒ 当前是上下翻转的渲染目标 (RT)
  "_ScreenParams":                [0, 0, 0.100002, 0],            // ⚠ 此处 .x/.y 为 0，可能不对当前 pass 生效
  "_ZBufferParams":               [0,0,0,0],
  "_PrevCameraPos":               [0,0,0],
  "_ReflectNormalBias":           0,
  "_PrevTime":                    [0,0,0,0],
  "_SRPTime":                     [0,0,0,0],
  "_PaperUnscaledTime":           [0,0,0,0],
  "_FrameCount8":                 0
}
```

> `_ProjectionParams.x = -1` 在 shader 第 756 行参与屏幕 UV 翻转：`screenUV.y = positionNDC.y * _ProjectionParams.x / positionNDC.w`，把 NDC y 反向。还原时这一项必须给 -1，否则 SSS / ScreenShadow 采样会上下翻。

### CB3 `UnityPerDraw`（320 字节，IR 中是 "buf %4 (112) + buf %5 (336)"，reflection 把它们合在一起）

```jsonc
{
  "hlslcc_mtx4x4unity_ObjectToWorld": [
    [0,        -1,        -7.76e-9, 0],
    [0.603044,  0,         0.797708, 0],
    [-0.797708, 7.76e-9,   0.603044, 0],
    [-0.003427, 0.949883, -0.004638, 1]   // 角色根节点世界坐标，y=0.95m（站在地面）
  ],
  "hlslcc_mtx4x4unity_WorldToObject": [...],   // 上式逆矩阵
  "unity_WorldTransformParams":      [0, 0, 0, 1],
  "unity_SpecCube0_HDR":             [1, 1, 0, 0],   // ⚠ Cube HDR 解码参数 (decodeInstructions)
  "hlslcc_mtx4x4unity_MatrixPreviousM":  [[0,0,0,0],...],  // 全 0：第一帧或不开 motion vectors
  "hlslcc_mtx4x4unity_MatrixPreviousMI": [[0,0,0,0],...],
  "unity_MotionVectorsParams":       [0,0,0,0],
  "Pape_SpecCubeArrayMaxMip":        0
}
```

**对反射 cube HDR 解码**：shader 用 `unity_SpecCube0_HDR.x * exp2(.y * log2(decodeArg))` 公式，本帧 HDR=(1,1,0,0) ⇒ `decodeScale = 1*exp2(0) = 1`，等于 **不做 HDR 解码**（线性贴图）。又因为 cube 本身是 1×1 黑（resource 142），`envSpecular = 0`。

### CB4 `Character_Param`（280 字节，IR 给的是 336 但 reflection 只命中前 100 多字节）

**这个块是项目特有的"角色专属灯光系统"**，不是 URP 的标准灯光：

```jsonc
{
  "_CharLightPosition":    [-0.0828, 0.870, -0.485, 1],     // 角色补光位置（w=1 → point/spot 类型）
  "_CharShColor":          [0, 0, 0, 1],                    // 未使用
  "_CharMainLightColor":   [2.5137, 2.2598, 2.4297, 3.141], // ⭐ 实际"主灯"颜色（RGB HDR） + .w=3.14 ≈ π（强度系数？）
  "_CharLightColor":       [1.0996, 0.9355, 0.9976, 1.0996],// ⭐ 实际补光颜色 + .w=1.10
  "_RootMPosition":        [-0.003, 0.950, -0.005],         // 与 ObjectToWorld 第 4 行对应（角色脚下位置）
  "_CharShIntensity":      0.4500,                          // ⭐ Pape SH 的整体倍率（同时也是 envSpecular 的倍率）
  "_CharShadowIntensity":  1.0000,                          // ⭐ 屏幕阴影叠加权重
  "_CharShHeight":         0.8091,                          // 球谐高度修正系数
  "_ClipYValue":           1.9297,                          // 角色裁剪高度
  "_HomeLightingEnable":   0.3926,                          // ⭐ 0..1 Home Lighting 混合权重 (≈ 39%)
  "_EyeAdaptionInverseExposureEnable": 1.9229,
  "_HomeLightingPPVScale":         [0,0,0,0],               // PPV 后期颜色调制 scale，本帧未启用
  "_HomeLightingPPVColor0":        [0,0,0,0],
  "_HomeLightingPPVColor1":        [0,0,0,0],
  "_HomeRimLightingPPVColor":      [0,0,0,0],
  "_POSMEnabled":          0
}
```

> **注意**：Unity 翻译 shader 文件里 `_CharMainLightColor` 没出现在 `Character_Param`，因为 URP 把 `_MainLightColor` 当作内建。但 IR / reflection 显示 RPS 496 实际从这个 cbuffer 读 `_CharMainLightColor`。**还原时要把 cb4.`_CharMainLightColor` 直接绑到 shader 中所有 "_MainLightColor" 引用上，或者建立一个外部 input 替换 URP 默认值**。

### CB5 `UnityPerMaterial`（136 字节，IR 给的是 280；reflection 字段名按 Unity Shader 文件一一对应）

完整 69 个字段保存在 `cb5_UnityPerMaterial.json`。挑出影响 lighting 的关键项：

| 字段 | 值 | 用途 |
|---|---|---|
| `_Color` | (1.072, 1.048, 1.054, 1) | 基础肤色 tint（≈白） |
| `_NonMetalSpecular` | 0.04 | F0 = `specMask * 0.04 * 0.08`，即 base reflectance ≈ 0.0032，典型皮肤 |
| `_FresnelColor` / `_FresnelIntensity` / `_Fresnelpower` | (1,1,1,1) / 1.0 / 5.0 | Fresnel rim |
| `_ShadowIntensity` | 0.5 | 阴影叠加 |
| `_AOIntensity` | 1.0 | AO 强度 |
| `_LerpValue` | 0 | 眼皮/眼球 lerp |
| `_OverlayColor` | (0.95, 0.78, 0.69, 1) | 整体色调叠加 |
| `_SparkleUV`, `_EyeSparkleParams`, `_LipSparkleParams` 等 | 见 json | 闪片参数 |

化妆颜色（`_MakeupColor1..6`）、化妆密度（`_*Density`）等不直接影响光照公式，但影响 albedo（已包含在 `tintedAlbedo` 内）。

### CB6 `PapePerRendererCB`（144 字节）

**这是本帧最重要的环境光数据。**

```jsonc
{
  "_SHMaps": [           // ⭐ ✓ shader 全部 7 行都读（IR field idx 0, i64 0..6）：唯一的环境光来源
    [-0.00560, -0.06079,  0.08685, 0.34326],   // SHMaps[0]：red 通道  (linear part)
    [-0.05029, -0.05643,  0.07611, 0.34424],   // SHMaps[1]：green 通道 (linear part)
    [-0.06165, -0.06586,  0.12390, 0.45264],   // SHMaps[2]：blue 通道  (linear part)
    [-0.00375,  0.00350,  0.01636, 0.03857],   // SHMaps[3]：red   quadratic basis (xy, yz, zz, xz)
    [ 0.00017,  0.00480,  0.01202, 0.01761],   // SHMaps[4]：green quadratic basis
    [-0.00334,  0.00102,  0.00658, 0.00256],   // SHMaps[5]：blue  quadratic basis
    [ 0.05035,  0.05017,  0.06696, 1.00000]    // SHMaps[6]：(x²-y²) basis 系数 RGB + ambient term (.w 在本 shader 没用，固定 1)
  ],
  "_CubeSHs": [ [0,0,0,0] x 7 ],     // ✗ shader 不读（IR 无 field idx 1 GEP）— 死参数
  "_VegColor": [0,0,0,0],            // ✗ shader 不读
  "_VegetationInShadowLighting":      0,   // ✗ shader 不读
  "_VegetationIndirectSpecIntensity": 0,   // ✗ shader 不读
  "_IsNightMode":   0,               // ✗ shader 不读
  "_RampColorID0":  0,               // ✗ shader 不读
  "_RampColorID1":  0,               // ✗ shader 不读
  "_RampColorBlend":0                // ✗ shader 不读
}
```

**关于 `_CubeSHs` 是否被使用**：RPS 496 fragment IR 对 `PapePerRendererCB` 仅有 7 个 GEP（行 387–399），全部走 `i32 0`（即 `_SHMaps` 数组），索引 `i64 0..6`。**`i32 1` (`_CubeSHs`) 一次都没被读**；其它字段（`_VegColor`/`_IsNightMode`/`_RampColor*` 等）也都没被读。所以 `_CubeSHs[7]` 在 SkinMakeupNew 这个 shader 里**就是个占位符**：它保留在 cbuffer 布局里只是为了字节偏移与项目其它共享 `PapePerRendererCB` 的材质（可能是植被、风景）一致。还原引擎时不绑、绑零、随便绑，对 RPS 496 输出一比特都不会变。

也就是说：`_SHMaps` 是这个 pass 里**唯一**的 SH/IBL 数据源，间接环境漫反射完全由它决定。Cubemap (`unity_SpecCube0`) + `_CubeSHs` 这两条本来可以提供 IBL 的路径在这帧都没被启用。
```

**SH 解码（与 shader 第 512 行 `EvaluatePapeSH` 一致）**：

```glsl
half3 EvaluatePapeSH(half3 N) {
    half4 n4 = half4(N.xyz, 1);
    half3 linear_sh = (
        dot(_SHMaps[0], n4),
        dot(_SHMaps[1], n4),
        dot(_SHMaps[2], n4)
    );
    half4 quadBasis = half4(N.y*N.x, N.z*N.y, N.z*N.z, N.x*N.z);
    half3 quad_sh = (
        dot(_SHMaps[3], quadBasis),
        dot(_SHMaps[4], quadBasis),
        dot(_SHMaps[5], quadBasis),
    );
    half nx2_minus_ny2 = N.x*N.x - N.y*N.y;
    return max(linear_sh + quad_sh + _SHMaps[6].rgb * nx2_minus_ny2, 0);
}
```

把 `_SHMaps` 的数值用一个简单的 `N=(0,1,0)`（朝上）代入，得到大致 ambient ≈ (0.343, 0.344, 0.453)，朝上略偏蓝；`N=(0,-1,0)` 朝下大致 (0.005, -0.06, 0.09)（被裁到 0）—— 这些就是这帧"看起来是什么环境光"的最终答案。**还原时把这 7 个 half4 直接喂给 shader 即可，不要试图从 cubemap 推 —— cubemap 是黑的。**

---

## 4. Fragment Stage 纹理绑定 — 16 张

| 槽位 | resource_id | LYSK label | 大小/格式 | 在 shader 中的语义 |
|---|---|---|---|---|
| 0 | 142 | `UnityBlackCube` | 1×1 cubemap | `unity_SpecCube0`（**全黑**：无反射） |
| 1 | 145 | (未命名) | 128×128 RGBA8 | 未在 IR 中查到强语义 — 可能是 CharSh / Ramp 备用纹理 |
| 2 | 222 | `MainTexRT` | 512×512 RGBA8 sRGB | `_MainTex`（基础肤色，已经过 RT 路径） |
| 3 | 197 | `PL_Head_R` | 512×512 (compressed) | `_SpecularTex`（R=roughness, B=specular, A=mask） |
| 4 | 194 | `PL_Head_MU_N` | 512×512 RGBA8 | `_NormalTex`（双层法线，xy + zw） |
| 5 | 195 | `PL_Makeup_Eyebrow_12_D` | 1024×1024 | `_EyebrowTex` |
| 6 | 213 | `PL_Makeup_Eyeshadow_06_01_D` | 512×512 | `_EyeshadowTex` |
| 7 | 214 | `PL_Makeup_Eyeliner_06_D` | 512×512 | `_EyelinerTex` |
| 8 | 217 | `PL_Makeup_Blush_02_D` | 512×512 | `_BlusherTex` |
| 9 | 200 | `PL_Makeup_Lip_02_D` | 512×512 | `_LipTex` |
| 10 | 141 | `UnityBlack` | 4×4 sRGB | `_DecorateTex`（**全黑 = 无装饰**） |
| 11 | 141 | `UnityBlack` | 4×4 sRGB | `_Decorate2Tex`（**全黑 = 无装饰**） |
| 12 | 196 | `PL_Makeup_Head_ID_UNCOMPRESSED` | 1024×1024 RGBA8 | `_MorphPartTex` |
| 13 | 193 | `PL_Makeup_Eyelid_07_D` | 512×512 | `_EyelidTex` |
| 14 | **232** | `TempBuffer 124` | 583×835 RG11B10F | ⭐ `_SSSSkinTexture` —— **这是 E12 写出的、SSS 已经做完水平+垂直模糊的半分辨率皮肤光照**。RPS 496 把它直接 upsample 后乘 `tintedAlbedo` 当作主漫反射 |
| 15 | **236** | `TempBuffer 128` | 583×835 RGBA8 | ⭐ `_ScreenShadowTexture` —— E9 写出的屏幕空间阴影，r 通道作为主灯阴影 atten，g 通道由 shadow weight 加权 |

> 结论：**RPS 496 的"主灯漫反射"实际上是 SSS pass 的输出**，shader 在这里只做镜面、附加光、环境与最终合成。而 SSS pass 的输入光照（即 RPS 491 写的 232 之前版本）已经包含了 _CharMainLightColor、阴影、SH 等贡献 —— 在还原时务必复刻完整 SSS 链路（E10→E11→E12→E13），不要试图把所有光照塞进 RPS 496 单 pass。

### Fragment Stage CBuffer Binding（7 个 buffer）

| buffer slot | resource_id | offset | size | 名称 |
|---|---|---|---|---|
| 0 | 2 | 275072 | 2176 | `AsukaPerShader_AddLightParams_PerCamera` |
| 1 | 2 | 277248 | 144 | `AsukaPerShader_PerCamera` |
| 2 | 2 | 109632 | 320 | `UnityPerCamera` |
| 3 | 2 | 109952 | 320 | `UnityPerDraw`（含 SpecCube0_HDR） |
| 4 | 2 | 111232 | 280 | `Character_Param` |
| 5 | 2 | 110912 | 136 | `UnityPerMaterial` |
| 6 | 103 | 0 | 144 | `PapePerRendererCB`（每个 renderer 一份独立 buffer） |

> resource 2 是一个超大的 shared upload buffer（多个 cbuffer 子区段），resource 103 是 SkinMakeupNew 这个 renderer 私有的小 cbuffer。

---

## 5. 引擎还原 checklist

把这帧的渲染效果在你的引擎里复刻出来，需要按以下顺序提供数据：

1. **Pape SH** —— 7 个 half4 数组照抄 `cb6_PapePerRendererCB.json` 的 `_SHMaps`，用 `EvaluatePapeSH(N)` 公式计算环境漫反射。**这是 lighting 的主要部分**。
2. **Char 双灯** —— 把 cb4 的 `_CharLightPosition / _CharMainLightColor / _CharLightColor / _CharShIntensity / _CharShadowIntensity` 当作 4 个独立 input 喂给 shader。**不要把 _CharMainLightColor 误用作 _MainLightColor**：URP 的 _MainLightColor 在这帧是 0，要从 _CharMainLightColor 取实际值（或在 shader 外加适配层把它绑到 _MainLightColor）。
3. **主灯方向** —— `_MainLightPosition = (0.292, 0.274, 0.916, 0)`（cb1）作为方向向量。
4. **附加光（2 盏）** —— 抄 `cb0_AddLightParams_active_lights.json`，按 LightIndexMap 路径或者直接 hardcode 到 0/1 槽位（其它 28 个置 sentinel）。`_GridInfo=(-128,-254,256,256)` 决定 LightIndexMap UV 投影。
5. **反射 IBL** —— 这帧实质禁用（cubemap 是 1×1 黑、`_CubeSHs` 全 0）。可以用任意默认 black cube 配 `unity_SpecCube0_HDR=(1,1,0,0)` 占位，**不会影响最终颜色**（因为 envSpecular 全黑）。
6. **SSS 上游 pass** —— 必须先在你的引擎里把：
   - `_ScreenShadowTexture`（E9 的输出 = 屏幕阴影 RGBA）
   - `_SSSSkinTexture`（E10→E11→E12 的输出 = 半分辨率皮肤已 SSS 模糊后的 lighting）
   - 准备好；否则 RPS 496 的最终颜色会全错。
7. **材质参数** —— 用 `cb5_UnityPerMaterial.json` 的 69 个字段直接填到 Material 上（变量名一一对应翻译 shader 文件）。
8. **相机** —— `_WorldSpaceCameraPos = (0, 1.412, 1.177)`，`_ProjectionParams = (-1, 0.1, 5000, 0.0002)`，朝向通过 ObjectToWorld 矩阵能反推。**注意 _ProjectionParams.x = -1 是触发 Y 翻转的关键**。
9. **`_GlobalMipBias = -1.515`** —— 用于 _MainTex / _NormalTex 采样时获得更锐的 LOD，引擎里要支持 mip bias 才能完全一致。

---

## 6. 数据来源

```
trace        = ~/Library/Containers/com.papegames.lysk/Data/Documents/Captures/capture_20260518_110050.gputrace
RPS_key      = 496
draw_index   = 69 (CB1/E13/draw_in_encoder=5, call_index=989)
fragment lib = library_410.module.bc (cache_key 61F4807E5636D024_28097, ir_source=sdi_module_bc)
fragment fn  = xlatMtlMain (signature: define <{ <4 x half>, half }> @xlatMtlMain(...))
```

提取命令：

```bash
SKILL=/Users/songdogwang/Codes/PlayCover/.codebuddy/skills/gpu-trace-analysis
TRACE=~/Library/Containers/com.papegames.lysk/Data/Documents/Captures/capture_20260518_110050.gputrace

python3 "$SKILL/scripts/gputrace_replay_wrapper.py" \
    shader-of-drawcall "$TRACE" 69 --stage fragment \
    --with-bindings --with-uniforms \
    --output-dir <out>
```

附加 30-element 解码（绕过 bridge 的 16-element 截断）：见同目录 `cb0_AddLightParams_full30.json` 与生成它的 inline Python 脚本。
