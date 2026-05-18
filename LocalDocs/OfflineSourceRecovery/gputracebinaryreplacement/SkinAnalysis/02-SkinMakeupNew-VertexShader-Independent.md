## Papegame/SkinMakeupNew Vertex Shader — Metal IR 实现分析（独立复核）

### 分析对象

| 属性 | 值 |
|------|------|
| **Shader 名称** | `Papegame/SkinMakeupNew` |
| **着色器类型** | Vertex shader |
| **入口函数** | `@xlatMtlMain` |
| **Target** | `air64_v24-apple-ios15.0.0` |
| **AIR 版本** | `2.4.0` |
| **Metal 语言版本** | `Metal 2.3.0` |
| **编译器** | `Apple metal version 32023.830 (metalfe-32023.830.2)` |
| **IR 文件** | `LocalDocs/OfflineSourceRecovery/gputracebinaryreplacement/ShaderRaw/SkinMakeupNew_vertex_lib0x7b12cf580.ll` |
| **源 bitcode** | `ShaderDebugInfo/com.papegames.lysk/C2F2D89403D39FBF_7593/modules/0aae7e0986955774b1126afa4878163b49fe0e39c7b8e3b212e08aa9613b4477/module.bc` |

### 总体结论

这个 vertex shader 是一个**几何与 varyings 准备阶段**，不直接参与皮肤 PBR、SSS、化妆、闪片或附加光照计算。它的核心职责是：

- **位置变换**：把 object space 顶点位置变换到 absolute world space，同时用 camera-relative 坐标进入 `ViewProjMatrix` 得到裁剪空间位置。
- **深度微偏移**：对真正写入 `mtl_Position` 的 clip-space `z` 添加 `abs(w) * 0.0008` 的偏移，用于稳定层级或避免深度冲突。
- **屏幕空间坐标保真**：额外输出一份**未加深度偏移**的 raw clip position 到 `TEXCOORD6`，供 fragment shader 重建 screen UV。
- **UV 打包**：把 4 组 `float2` UV 压缩为 2 个 `half4` varying，交给 fragment 阶段采样主贴图、法线、眉毛、眼影、眼线、腮红、口红、装饰等贴图。
- **TBN 构建**：把 object-space normal / tangent 变换到 world space，构造 world-space normal、tangent、bitangent 三向量。
- **视线向量打包**：计算 `cameraPos - worldPos`，并把三个分量分别塞进 `TEXCOORD3.w`、`TEXCOORD4.w`、`TEXCOORD5.w`，减少单独 varying 的开销。

重要的是：该 vertex shader **没有蒙皮、没有 blendshape、没有顶点动画、没有材质参数访问、没有纹理采样、没有分支循环**。如果该角色面部确实有表情/捏脸/变形，这些变形并不在这个 vertex shader 中完成，应该已经在更早阶段、CPU 侧、mesh 数据侧，或另一个 pass/compute 流程中完成。

---

## 入口函数与接口

### 函数签名复原

IR 入口返回一个 aggregate：

```llvm
define <{ <4 x float>, <4 x half>, <4 x half>, <3 x float>, <4 x half>, <4 x half>, <4 x half>, <4 x float> }> @xlatMtlMain(...)
```

对应 Metal/Unity 语义可以复原为：

| 返回序号 | Metal 语义 | 类型 | 复原含义 |
|----------|------------|------|----------|
| `0` | `air.position` | `float4` | `mtl_Position`，带深度偏移的 clip position |
| `1` | `user(TEXCOORD0)` | `half4` | `half4(input.TEXCOORD0.xy, input.TEXCOORD1.xy)` |
| `2` | `user(TEXCOORD1)` | `half4` | `half4(input.TEXCOORD2.xy, input.TEXCOORD3.xy)` |
| `3` | `user(TEXCOORD2)` | `float3` | absolute world position |
| `4` | `user(TEXCOORD3)` | `half4` | `half4(normalWS.xyz, viewVecWS.x)` |
| `5` | `user(TEXCOORD4)` | `half4` | `half4(tangentWS.xyz, viewVecWS.y)` |
| `6` | `user(TEXCOORD5)` | `half4` | `half4(bitangentWS.xyz, viewVecWS.z)` |
| `7` | `user(TEXCOORD6)` | `float4` | raw clip position，未应用 `z += abs(w) * 0.0008` |

### 输入 constant buffers

该 vertex shader 只绑定 3 个 constant buffer：

| Buffer Index | 类型名 | 参数名 | 大小 | 本 shader 实际使用字段 |
|--------------|--------|--------|------|------------------------|
| `0` | `UnityPerCamera_Type` | `UnityPerCamera` | `320B` | `_WorldSpaceRelativeCameraPos`、`_WorldSpaceCameraPos` |
| `1` | `UnityPerDraw_Type` | `UnityPerDraw` | `320B` | `unity_ObjectToWorld`、`unity_WorldToObject`、`unity_WorldTransformParams.w` |
| `2` | `UnityPerPass_Type` | `UnityPerPass` | `592B` | `hlslcc_mtx4x4_ViewProjMatrix` |

没有使用 `UnityPerMaterial`、`Character_Param`、`PapePerRendererCB` 或任何纹理/采样器。这进一步说明：**材质与光照完全在 fragment shader 中完成，vertex shader 只提供坐标基底和必要 varyings**。

### 输入 vertex attributes

| Location | 语义 | 类型 | 用途 |
|----------|------|------|------|
| `0` | `POSITION0` | `float4` | object-space 顶点位置；IR 实际只使用 `.xyz`，隐含 `.w = 1` |
| `1` | `NORMAL0` | `half3` | object-space normal |
| `2` | `TANGENT0` | `half4` | object-space tangent；`.w` 是 tangent handedness |
| `3` | `TEXCOORD0` | `float2` | 第一组 UV，通常为主 UV |
| `4` | `TEXCOORD1` | `float2` | 第二组 UV |
| `5` | `TEXCOORD2` | `float2` | 第三组 UV |
| `6` | `TEXCOORD3` | `float2` | 第四组 UV |

---

## 阶段 1：Object Space → Absolute World Space

### IR 行为

IR 先加载 `UnityPerDraw.hlslcc_mtx4x4unity_ObjectToWorld` 的前 4 个 `float4` 槽位，然后执行：

```hlsl
float3 p = POSITION0.xyz;
float3 worldPos =
    unity_ObjectToWorld[0].xyz * p.x +
    unity_ObjectToWorld[1].xyz * p.y +
    unity_ObjectToWorld[2].xyz * p.z +
    unity_ObjectToWorld[3].xyz;
```

对应 IR 证据：

| IR 区间 | 含义 |
|---------|------|
| `12–16` | 取 `POSITION0.y`，乘 `unity_ObjectToWorld[1].xyz` |
| `17–21` | FMA 加上 `POSITION0.x * unity_ObjectToWorld[0].xyz` |
| `22–26` | FMA 加上 `POSITION0.z * unity_ObjectToWorld[2].xyz` |
| `27–30` | 加上 `unity_ObjectToWorld[3].xyz` 作为平移 |

### 关键结论

- **`POSITION0.w` 未参与计算**：IR 没有读取 `%3.w`，而是直接加上矩阵第 4 槽的 `.xyz`。这等价于假设输入位置是 `float4(positionOS, 1)`。
- **无顶点变形**：没有读取 bone matrices、blendshape、morph 参数、时间参数或材质参数。此 pass 对顶点几何是“刚性 object-to-world”变换。
- **输出 absolute world position**：后面直接把 `worldPos` 作为 `TEXCOORD2` 输出给 fragment shader，用于光照距离、视线方向、附加光等计算。

---

## 阶段 2：Camera-relative ViewProj 变换

### 计算过程

变换到裁剪空间之前，shader 先从 `worldPos` 减去 `_WorldSpaceRelativeCameraPos`：

```hlsl
float3 relativeWorldPos = worldPos - _WorldSpaceRelativeCameraPos;
```

随后使用 `UnityPerPass.hlslcc_mtx4x4_ViewProjMatrix` 做 affine 形式的矩阵乘法：

```hlsl
float4 clipRaw =
    ViewProjMatrix[0] * relativeWorldPos.x +
    ViewProjMatrix[1] * relativeWorldPos.y +
    ViewProjMatrix[2] * relativeWorldPos.z +
    ViewProjMatrix[3];
```

对应 IR 证据：

| IR 区间 | 含义 |
|---------|------|
| `31–33` | 加载 `_WorldSpaceRelativeCameraPos` 并计算 `worldPos - relativeCameraPos` |
| `34–48` | 使用 `hlslcc_mtx4x4_ViewProjMatrix` 计算 `clipRaw` |

### 为什么使用 `_WorldSpaceRelativeCameraPos`

这个 shader 同时使用了两个相机位置字段：

| 字段 | 用途 |
|------|------|
| `_WorldSpaceRelativeCameraPos` | 只用于进入 `ViewProjMatrix` 前的 camera-relative 坐标 |
| `_WorldSpaceCameraPos` | 用于计算传给 fragment 的 view vector |

这说明渲染管线采用了**相机相对渲染**：矩阵投影路径使用 `worldPos - relativeCameraPos`，从而减少大世界坐标下的浮点精度损失；但 fragment 仍需要 absolute `worldPos` 和 absolute camera position 之间的向量，因此另算 `cameraPos - worldPos`。

---

## 阶段 3：Clip-space 深度偏移

### 精确公式

得到 `clipRaw` 后，shader 没有直接作为 `mtl_Position` 输出，而是只修改 `z`：

```hlsl
float4 clipBiased = clipRaw;
clipBiased.z = clipRaw.z + abs(clipRaw.w) * 0.00079999998;
```

常量来自 IR 中的 double literal：

```llvm
0x3F4A36E2E0000000 ≈ 0.00079999998
```

对应 IR 证据：

| IR 行 | 含义 |
|-------|------|
| `49` | 取 `clipRaw.w` |
| `50` | `abs(clipRaw.w)` |
| `51–52` | `clipRaw.z + abs(clipRaw.w) * 0.0008` |
| `53–56` | 组装 `float4(clipRaw.x, clipRaw.y, biasedZ, clipRaw.w)` |

### 语义判断

这个偏移是**按 clip-space w 缩放的深度偏移**。因为 NDC 深度大致来自 `z / w`，所以：

```hlsl
biasedZ / w = clipRaw.z / w + abs(w) / w * 0.0008
```

在常规正 `w` 投影下，近似等于给 NDC depth 增加一个常量 `0.0008`。其常见用途包括：

- 避免同一脸部/皮肤层与其他贴面、妆容层、深度预写层发生 z-fighting。
- 在不移动 world position 的情况下，只影响深度测试/光栅化位置。
- 保持 fragment 中基于 `worldPos` 的光照不被偏移污染。

### 特别重要：`TEXCOORD6` 输出的是未偏移 clipRaw

虽然 `mtl_Position` 使用 `clipBiased`，但 `TEXCOORD6` 输出的是原始 `%47`，即 `clipRaw`。

这意味着 fragment shader 重建 screen UV 时使用的是**未加深度偏移的投影坐标**。这对 `_SSSSkinTexture`、`_ScreenShadowTexture`、`_LightIndexMap` 等屏幕空间资源很重要：屏幕采样不会因为 depth bias 而产生额外漂移。

---

## 阶段 4：UV 打包与精度策略

### 精确映射

IR 把 4 个输入 `float2` 合并成 2 个 `half4`：

```hlsl
OUT.TEXCOORD0 = half4(IN.TEXCOORD0.xy, IN.TEXCOORD1.xy);
OUT.TEXCOORD1 = half4(IN.TEXCOORD2.xy, IN.TEXCOORD3.xy);
```

对应 IR：

| IR 行 | 含义 |
|-------|------|
| `57–58` | 拼接 `%6` 和 `%7`，转换为 `half4`，输出 `TEXCOORD0` |
| `59–60` | 拼接 `%8` 和 `%9`，转换为 `half4`，输出 `TEXCOORD1` |

### 与 fragment shader 的关系

fragment shader 中的多层化妆采样依赖这些 UV：

| Vertex 输出 | Fragment 可用通道 | 典型用途 |
|-------------|-------------------|----------|
| `TEXCOORD0.xy` | 输入 UV0 | 主贴图、法线、高光、眉毛、口红等主 UV |
| `TEXCOORD0.zw` | 输入 UV1 | 辅助妆容 UV |
| `TEXCOORD1.xy` | 输入 UV2 | 眼影/眼线/腮红等区域 UV，具体由 fragment 解释 |
| `TEXCOORD1.zw` | 输入 UV3 | 额外装饰或辅助区域 UV |

这个 vertex shader **不做任何 UV ST 变换**，比如 `_DecorateUV.xyzw` 或 `_Decorate2UV.xyzw` 这样的缩放偏移都应在 fragment shader 中执行。

### 精度判断

输入 UV 是 `float2`，输出降为 `half4`。对面部贴图 UV 来说，FP16 通常足够；这可以降低 varying 带宽。由于 fragment shader 的纹理采样数量很多，这种带宽优化是合理的移动端策略。

---

## 阶段 5：View Vector 计算与打包

### 精确公式

shader 加载 `_WorldSpaceCameraPos`，计算：

```hlsl
float3 viewVecWS = _WorldSpaceCameraPos - worldPos;
```

然后把三个分量截断为 half，分别放入 TBN 三个输出的 `.w`：

```hlsl
OUT.TEXCOORD3.w = half(viewVecWS.x);
OUT.TEXCOORD4.w = half(viewVecWS.y);
OUT.TEXCOORD5.w = half(viewVecWS.z);
```

对应 IR：

| IR 区间 | 含义 |
|---------|------|
| `61–63` | 加载 `_WorldSpaceCameraPos`，计算 `cameraPos - worldPos` |
| `64–65` | `viewVecWS.x` 转 half，等待写入 `TEXCOORD3.w` |
| `92–95` | `viewVecWS.y/z` 转 half，等待写入 `TEXCOORD4.w`、`TEXCOORD5.w` |

### 设计目的

这种布局把 view vector 的 3 个分量“藏”在 TBN 的 `.w` 通道中，避免额外输出一个 `half3` 或 `float3` varying。fragment 阶段可以这样还原：

```hlsl
half3 viewVecWS = half3(IN.TEXCOORD3.w, IN.TEXCOORD4.w, IN.TEXCOORD5.w);
half3 viewDirWS = normalize(viewVecWS);
```

### 潜在精度代价

view vector 被降到 `half` 后插值。对角色面部近距离渲染通常足够，但在极大世界坐标或极远相机距离下可能出现量化误差。该 shader 同时输出 `float3 worldPos`，fragment 理论上也可以重新用 `cameraPos - worldPos` 计算更高精度 view vector；但既然 vertex 已传 half view vector，说明作者更重视 varying 带宽和 fragment ALU 成本。

---

## 阶段 6：Normal 变换

### 精确公式

object-space normal 输入为 `half3 NORMAL0`，先转成 `float3`：

```hlsl
float3 normalOS = float3(IN.NORMAL0);
```

然后使用 `unity_WorldToObject` 的前三个向量做 dot：

```hlsl
half3 normalWSPre = half3(
    dot(normalOS, unity_WorldToObject[0].xyz),
    dot(normalOS, unity_WorldToObject[1].xyz),
    dot(normalOS, unity_WorldToObject[2].xyz)
);

half3 normalWS = normalize(normalWSPre);
```

对应 IR：

| IR 区间 | 含义 |
|---------|------|
| `66` | `NORMAL0 half3` 转 `float3` |
| `67–84` | 对 `unity_WorldToObject[0..2].xyz` 分别 dot，得到 `normalWSPre` |
| `85–89` | `dot(normalWSPre, normalWSPre)` + `rsqrt` + 归一化 |
| `90–91` | 组装 `half4(normalWS, viewVecWS.x)` |

### 为什么 normal 使用 `WorldToObject`

这是 Unity/HLSL 中典型的 normal transform 写法：normal 需要乘 object-to-world 的 inverse transpose。在 HLSLcc 展开后，经常表现为对 `unity_WorldToObject` 的行/槽做 dot。

这能正确处理 non-uniform scale 下的法线方向。最后 normalize 是必需的，因为逆转置变换后长度通常不再为 1。

### 精度策略

这里的 dot 是 FP32，随后截断成 half，再用 half 做 `dot + rsqrt + multiply` 归一化。也就是说：

- **矩阵读取与 dot 累加**：使用 `float`。
- **归一化与输出**：使用 `half`。

这是一种典型移动端折中：方向质量足够，同时降低后续 varying 和 fragment TBN 的带宽。

---

## 阶段 7：Tangent 变换

### 精确公式

输入 tangent 为 `half4 TANGENT0`。shader 只把 `.xyz` 用于方向变换，`.w` 留到 bitangent 阶段处理 handedness。

IR 对 `ObjectToWorld` 的访问方式不是直接取 `unity_ObjectToWorld[0].xyz`、`[1].xyz`、`[2].xyz` 来 dot，而是重新组装矩阵的三个行向量：

```hlsl
float3 row0 = float3(unity_ObjectToWorld[0].x, unity_ObjectToWorld[1].x, unity_ObjectToWorld[2].x);
float3 row1 = float3(unity_ObjectToWorld[0].y, unity_ObjectToWorld[1].y, unity_ObjectToWorld[2].y);
float3 row2 = float3(unity_ObjectToWorld[0].z, unity_ObjectToWorld[1].z, unity_ObjectToWorld[2].z);

float3 tangentOS = float3(IN.TANGENT0.xyz);

half3 tangentWSPre = half3(
    dot(row0, tangentOS),
    dot(row1, tangentOS),
    dot(row2, tangentOS)
);

half3 tangentWS = normalize(tangentWSPre);
```

对应 IR：

| IR 区间 | 含义 |
|---------|------|
| `96–103` | 组装第一行并把 `TANGENT0.xyz` 转 float |
| `104–123` | 依次计算 tangent world 的 x/y/z |
| `124–129` | half 精度归一化 |
| `130–131` | 组装 `half4(tangentWS, viewVecWS.y)` |

### 与 normal 的差异

| 向量 | 使用矩阵 | 原因 |
|------|----------|------|
| normal | `WorldToObject` | normal 要用 inverse transpose |
| tangent | `ObjectToWorld` | tangent 是切平面方向向量，用普通方向变换 |

shader 没有对 tangent 做 Gram-Schmidt 正交化，也没有重新投影到 normal 的切平面上。它假设 mesh tangent 与 normal 数据本身是合理的，矩阵变换后独立 normalize 即可。

---

## 阶段 8：Bitangent 构造与 handedness

### 精确公式

bitangent 没有从 vertex attribute 读取，而是由 normal 和 tangent 叉乘得到：

```hlsl
half3 bitangentWS = cross(normalWS, tangentWS) * (IN.TANGENT0.w * unity_WorldTransformParams.w);
```

对应 IR 还原：

```hlsl
half3 crossNT = normalWS.yzx * tangentWS.zxy - tangentWS.yzx * normalWS.zxy;
half sign = IN.TANGENT0.w * unity_WorldTransformParams.w;
half3 bitangentWS = crossNT * sign;
```

对应 IR：

| IR 区间 | 含义 |
|---------|------|
| `132–138` | 用 swizzle + FMA 计算 `cross(normalWS, tangentWS)` |
| `139–145` | 读取 `TANGENT0.w` 与 `unity_WorldTransformParams.w`，相乘得到 handedness sign |
| `146–150` | `crossNT * sign`，并组装 `half4(bitangentWS, viewVecWS.z)` |

### handedness 的意义

`TANGENT0.w` 通常表示 UV tangent space 的左右手性。`unity_WorldTransformParams.w` 通常用于处理 object transform 中的负缩放/镜像。二者相乘可以保持 bitangent 与法线贴图 tangent space 的一致性。

这是 Unity 标准写法的变体：

```hlsl
bitangentWS = cross(normalWS, tangentWS) * tangentSign;
```

其中：

```hlsl
tangentSign = tangentOS.w * unity_WorldTransformParams.w;
```

---

## 输出布局的 fragment contract

这个 vertex shader 与 fragment shader 之间的契约非常明确：

```text
TEXCOORD0.xy = UV0
TEXCOORD0.zw = UV1
TEXCOORD1.xy = UV2
TEXCOORD1.zw = UV3
TEXCOORD2.xyz = worldPosWS
TEXCOORD3.xyz = normalWS
TEXCOORD3.w   = viewVecWS.x
TEXCOORD4.xyz = tangentWS
TEXCOORD4.w   = viewVecWS.y
TEXCOORD5.xyz = bitangentWS
TEXCOORD5.w   = viewVecWS.z
TEXCOORD6.xyzw = clipRaw
mtl_Position.xyzw = clipRaw with biased z
```

因此 fragment shader 中若要把 tangent-space normal map 转到 world space，应按如下矩阵使用：

```hlsl
half3 normalWS   = IN.TEXCOORD3.xyz;
half3 tangentWS  = IN.TEXCOORD4.xyz;
half3 bitangentWS = IN.TEXCOORD5.xyz;

half3 worldNormalFromMap = normalize(
    tangentNormal.x * tangentWS +
    tangentNormal.y * bitangentWS +
    tangentNormal.z * normalWS
);
```

而 view direction 可以从 `.w` 通道拼回：

```hlsl
half3 viewVecWS = half3(IN.TEXCOORD3.w, IN.TEXCOORD4.w, IN.TEXCOORD5.w);
half3 viewDirWS = normalize(viewVecWS);
```

这也解释了 fragment shader 为什么能同时进行：

- normal map / eyelid normal 混合后的 tangent-to-world 变换。
- 基于 `worldPos` 的光源方向与距离计算。
- 基于 `clipRaw` 的 screen-space shadow、SSS LUT、light index map 采样。
- 基于多 UV 的妆容贴图层叠。

---

## HLSL 风格伪代码复原

下面是根据 IR 独立复原出的高层伪代码：

```hlsl
struct VSInput
{
    float4 positionOS : POSITION0;
    half3 normalOS : NORMAL0;
    half4 tangentOS : TANGENT0;
    float2 uv0 : TEXCOORD0;
    float2 uv1 : TEXCOORD1;
    float2 uv2 : TEXCOORD2;
    float2 uv3 : TEXCOORD3;
};

struct VSOutput
{
    float4 positionCS : SV_Position;
    half4 texcoord0 : TEXCOORD0;
    half4 texcoord1 : TEXCOORD1;
    float3 worldPos : TEXCOORD2;
    half4 normalAndViewX : TEXCOORD3;
    half4 tangentAndViewY : TEXCOORD4;
    half4 bitangentAndViewZ : TEXCOORD5;
    float4 rawClipPos : TEXCOORD6;
};

VSOutput Main(VSInput input)
{
    VSOutput output;

    float3 positionOS = input.positionOS.xyz;

    float3 worldPos =
        unity_ObjectToWorld[0].xyz * positionOS.x +
        unity_ObjectToWorld[1].xyz * positionOS.y +
        unity_ObjectToWorld[2].xyz * positionOS.z +
        unity_ObjectToWorld[3].xyz;

    float3 relativeWorldPos = worldPos - _WorldSpaceRelativeCameraPos;

    float4 rawClipPos =
        hlslcc_mtx4x4_ViewProjMatrix[0] * relativeWorldPos.x +
        hlslcc_mtx4x4_ViewProjMatrix[1] * relativeWorldPos.y +
        hlslcc_mtx4x4_ViewProjMatrix[2] * relativeWorldPos.z +
        hlslcc_mtx4x4_ViewProjMatrix[3];

    float4 biasedClipPos = rawClipPos;
    biasedClipPos.z = rawClipPos.z + abs(rawClipPos.w) * 0.00079999998;

    output.positionCS = biasedClipPos;
    output.rawClipPos = rawClipPos;
    output.worldPos = worldPos;

    output.texcoord0 = half4(input.uv0, input.uv1);
    output.texcoord1 = half4(input.uv2, input.uv3);

    float3 viewVecWSFloat = _WorldSpaceCameraPos - worldPos;

    float3 normalOS = float3(input.normalOS);
    half3 normalWS = normalize(half3(
        dot(normalOS, unity_WorldToObject[0].xyz),
        dot(normalOS, unity_WorldToObject[1].xyz),
        dot(normalOS, unity_WorldToObject[2].xyz)
    ));

    float3 tangentOS = float3(input.tangentOS.xyz);
    float3 objectToWorldRow0 = float3(unity_ObjectToWorld[0].x, unity_ObjectToWorld[1].x, unity_ObjectToWorld[2].x);
    float3 objectToWorldRow1 = float3(unity_ObjectToWorld[0].y, unity_ObjectToWorld[1].y, unity_ObjectToWorld[2].y);
    float3 objectToWorldRow2 = float3(unity_ObjectToWorld[0].z, unity_ObjectToWorld[1].z, unity_ObjectToWorld[2].z);

    half3 tangentWS = normalize(half3(
        dot(objectToWorldRow0, tangentOS),
        dot(objectToWorldRow1, tangentOS),
        dot(objectToWorldRow2, tangentOS)
    ));

    half tangentSign = half(float(input.tangentOS.w) * unity_WorldTransformParams.w);
    half3 bitangentWS = cross(normalWS, tangentWS) * tangentSign;

    output.normalAndViewX = half4(normalWS, half(viewVecWSFloat.x));
    output.tangentAndViewY = half4(tangentWS, half(viewVecWSFloat.y));
    output.bitangentAndViewZ = half4(bitangentWS, half(viewVecWSFloat.z));

    return output;
}
```

---

## 与 fragment shader 的分工关系

结合 `SkinMakeupNew` fragment shader 的着色模型，可以看出此 vertex shader 是为一个复杂 fragment pass 提供最小但足够的几何输入：

| Fragment 功能 | Vertex 提供的数据 |
|---------------|------------------|
| 主贴图、眉毛、眼影、眼线、腮红、口红、装饰贴纸采样 | `TEXCOORD0`、`TEXCOORD1` 中打包的 4 组 UV |
| 法线贴图、眼睑法线、secondary normal 混合 | `TEXCOORD3/4/5.xyz` 的 TBN |
| 主光、附加光、角色光方向与距离 | `TEXCOORD2` 的 absolute world position |
| Fresnel、N·V、half vector | `.w` 通道打包的 `viewVecWS` |
| SSS LUT、屏幕空间阴影、LightIndexMap | `TEXCOORD6` 的 raw clip position |
| 深度层级稳定 | `mtl_Position.z` 的 `abs(w) * 0.0008` 偏移 |

尤其值得注意的是：fragment 使用的 screen UV 应来自 `TEXCOORD6`，而不是 `SV_Position`。这使得 screen-space sampling 与逻辑投影位置一致，而 raster depth 又可以单独被轻微偏移。

---

## 性能与带宽特征

### ALU 成本

该 vertex shader 的 ALU 成本中等偏低，主要来自：

- object-to-world position：约 3 次 vector FMA + 1 次 add。
- view-projection：约 3 次 `float4` FMA + 1 次 add。
- normal transform：3 次 `dot(float3)` + 1 次 half normalize。
- tangent transform：3 次 `dot(float3)` + 1 次 half normalize。
- bitangent：1 次 cross + sign multiply。
- depth bias：1 次 `abs` + 1 次 FMA。

没有循环、分支、纹理采样，也没有复杂 transcendental 函数。

### Varying 带宽

输出 varyings 较多：

| Varying | 类型 | 说明 |
|---------|------|------|
| `TEXCOORD0` | `half4` | 2 组 UV |
| `TEXCOORD1` | `half4` | 2 组 UV |
| `TEXCOORD2` | `float3` | world position |
| `TEXCOORD3` | `half4` | normal + view x |
| `TEXCOORD4` | `half4` | tangent + view y |
| `TEXCOORD5` | `half4` | bitangent + view z |
| `TEXCOORD6` | `float4` | raw clip position |

为了控制带宽，shader 做了几个明显优化：

- UV 从 `float2 * 4` 压成 `half4 * 2`。
- TBN 使用 `half3` 输出。
- view vector 分量复用 TBN 的 `.w`，避免额外 varying。
- 只有 `worldPos` 和 `rawClipPos` 保持 `float`，因为它们关系到光照位置和屏幕空间投影。

### 为什么 still 输出较多数据

`SkinMakeupNew` fragment shader 非常重：包含多层化妆、normal map 混合、SSS、屏幕空间阴影、light index map、附加光和 IBL。为了避免 fragment 内重复计算或缺少空间基底，vertex 必须提供完整 TBN、world position、raw clip position 和多组 UV。这是用 varying 带宽换 fragment 逻辑清晰与稳定性的设计。

---

## 潜在实现限制与边界条件

### `POSITION0.w` 被忽略

IR 中没有使用 `POSITION0.w`。如果输入 mesh 使用非 1 的 position w，该 shader 不会正确处理。实际 Unity mesh 顶点一般可视为 `w = 1`，所以这不是问题。

### 无 GPU 蒙皮或 blendshape

该 vertex shader 没有任何骨骼矩阵、权重、索引或 blendshape delta 输入。如果这是角色面部 shader，说明：

- mesh 可能已经是 CPU/其他管线变形后的结果；或
- 这个 pass 用于不需要蒙皮的局部 mesh；或
- 蒙皮发生在另一个 shader variant/pass 中。

### TBN 没有重正交化

normal 与 tangent 分别变换并 normalize，然后用 cross 构造 bitangent。没有执行：

```hlsl
tangentWS = normalize(tangentWS - normalWS * dot(normalWS, tangentWS));
```

因此在极端 non-uniform scale 或输入 tangent 质量较差时，TBN 可能不是严格正交。但对标准 Unity 导入 mesh 来说通常可接受。

### View vector 使用 half 插值

`viewVecWS` 被拆到三个 half `.w` 通道中。近距离面部渲染通常没有问题；但如果角色距离相机非常远，或者世界坐标尺度非常大，half view vector 可能损失方向精度。

### Depth bias 与深度测试有关

`mtl_Position.z` 被推移，但 `worldPos`、`rawClipPos`、screen UV 都不变。因此：

- 光照和屏幕采样仍基于原始几何位置。
- 深度测试/深度写入基于 biased clip position。
- 如果有依赖 scene depth 的后处理，可能观察到该 pass 的深度与其 screen UV/world position 存在一个极小偏差。

---

## IR 证据索引

| IR 行号 | 关键内容 |
|---------|----------|
| `10–11` | `@xlatMtlMain` 主函数签名与返回 aggregate |
| `12–30` | object-space position 到 absolute world position |
| `31–48` | camera-relative world position 到 raw clip position |
| `49–56` | `z += abs(w) * 0.0008` 深度偏移并组装 `mtl_Position` |
| `57–60` | 4 组 UV 打包成 2 个 `half4` |
| `61–65` | `cameraPos - worldPos` 的 x 分量写入路径 |
| `66–91` | normal transform、normalize、输出 `TEXCOORD3.xyz/w` |
| `92–95` | view vector 的 y/z 分量截断为 half |
| `96–130` | tangent transform 与 normalize |
| `132–150` | bitangent = `cross(normal, tangent) * tangent.w * unity_WorldTransformParams.w` |
| `151–159` | aggregate 输出组装顺序 |
| `217–225` | vertex outputs metadata |
| `227–239` | buffers 与 vertex inputs metadata |

---

## 最终判断

这个 vertex shader 可以概括为：

```text
SkinMakeupNew Vertex = object/world/clip transform + depth bias + UV packing + world-space TBN + packed view vector
```

它的设计目标不是做美术效果本身，而是**为 fragment shader 的复杂皮肤/化妆/SSS/PBR 着色准备所有必要的空间信息**。最有特征的实现点有两个：

- **raw clip 与 biased clip 双轨输出**：`mtl_Position` 用 depth-biased clip，`TEXCOORD6` 用 raw clip，兼顾深度稳定与屏幕空间采样准确性。
- **TBN `.w` 复用 view vector**：`TEXCOORD3/4/5.xyz` 存 TBN，`.w` 存 view vector 三分量，在不增加额外 varying 的情况下支持 fragment 里的 Fresnel、N·V、GGX half-vector 等视角相关计算。

因此，这个 vertex shader 与 fragment shader 是典型的“轻 vertex / 重 fragment”分工：vertex 只做一次性空间变换与数据打包，fragment 承担所有皮肤材质、妆容、光照和后效相关计算。
