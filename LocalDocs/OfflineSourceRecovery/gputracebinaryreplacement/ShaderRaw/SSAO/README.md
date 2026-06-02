# SSAO & SSAOBlur — IR 与逆向指引

> **trace**: `capture_20260518_110050.gputrace`
> **拉取时间**: 2026-06-02
> **帧内位置**: E7 (SSAO) → E8 (SSAOBlur)，属于阶段 C "Half-res Screen-Space Effects"

---

## 文件清单

| 文件 | RPS | Stage | Lib/Fn Key | 行数 | 说明 |
|---|---|---|---|---|---|
| `rps447_SSAO_fragment_lib294.ll` | 447 | fragment | lib=294, fn=295 | 524 | **SSAO 主体**（深度重建法线 + 半球采样遮蔽计算） |
| `rps448_SSAOBlur_fragment_lib296.ll` | 448 | fragment | lib=296, fn=297 | 136 | **SSAOBlur**（十字形 9-tap 双边模糊） |
| `rps447_448_shared_vertex_lib292.ll` | 447/448 | vertex | lib=292, fn=293 | 78 | 共享全屏 quad vertex shader |

---

## 管线上下文

```
E6 DepthResolve (227 D32S8 → 233 R32F 583×835)
    │
    ▼
E7 SSAO (RPS 447)
    输入: _QuarterLinearDepthTexture = rid 233 (583×835 R32F，半分辨率线性深度)
    输出: rid 235 (583×835 R8Unorm，raw AO)
    │
    ▼
E8 SSAOBlur (RPS 448)
    输入: _HalfAOAndDepthTexture = rid 235 (E7 输出)
    输出: rid 234 (583×835 R8Unorm，blurred AO)
    │
    ▼
E9 ScreenSpaceShadow Composite → 236.A 通道 (SSAO 被合成进这里)
    │
    ▼
E10/E13/E17 各 lighting pass 通过 _ScreenShadowTexture.a 消费
```

---

## RPS 447 — SSAO 主体

### 输入

| 类型 | Slot | `air.arg_name` | 说明 |
|---|---|---|---|
| buffer (144B) | 0 | `cb_SSAO` | 全部参数，结构见下 |
| sampler | 0 | `sampler_QuarterLinearDepthTexture` | |
| texture2d\<float\> | 0 | `_QuarterLinearDepthTexture` | rid 233，半分辨率线性深度 |
| float4 | — | `mtl_FragCoord` (SV_Position) | |
| float2 | — | `TEXCOORD0` | 全屏 quad UV |

### `cb_SSAO` 结构体（144 字节）

```
offset  type      name                             用途
0       float4×4  hlslcc_mtx4x4_SSAO_ViewMatrix    view 矩阵（用于把重建的 view-space 位置旋转到统一坐标系）
64      float4    _UVToView                        UV → view-space 的投影参数 (xy=scale, zw=offset)
80      float4    _SSAO_ResolutionParams           分辨率相关（texel size 等）
96      float4    _ReconstructNormal_UVOffset      法线重建用的 UV 偏移
112     float4    _ReconstructNormal_GatherOffset   法线重建用的 gather 偏移
128     half4     _SSAO_SampleParams               采样半径/步长参数
136     half4     _SSAO_IntensityParams            AO 强度/对比度/衰减
```

### 算法概述（待逆向确认）

从 IR 结构可以推断：

1. **法线重建**（不依赖 229）：使用 `air.gather_texture_2d` 采样深度纹理的 2×2 邻域，通过深度差的 cross product 重建 screen-space 法线。IR 中有两次 `gather`（取 4 个 depth）+ `fabs` 比较 + 选择最小深度差方向 = **典型的"选最小深度差的十字重建法线"**。
2. **view-space 位置重建**：`screenUV * _UVToView.xy + _UVToView.zw` × `linearDepth` → view-space position。
3. **半球采样**：IR 约 470 行，含大量 `fma` + `sample_texture_2d` 循环展开 → 多次采样深度、与当前点的 view-space 位差做 dot → 计算遮蔽因子。
4. **输出**: 单通道 R8（`SV_TARGET0` 的 `.r`），值域 [0,1]，0=完全遮蔽，1=无遮蔽。

**关键确认**：SSAO 只读深度纹理 `_QuarterLinearDepthTexture`（rid 233），**不读法线贴图 229、不读任何光照信息**。纯几何计算。

---

## RPS 448 — SSAOBlur

### 输入

| 类型 | Slot | `air.arg_name` | 说明 |
|---|---|---|---|
| buffer (48B) | 0 | `cb_SSAOBlur` | 模糊参数，结构见下 |
| sampler | 0 | `sampler_HalfAOAndDepthTexture` | |
| texture2d\<half\> | 0 | `_HalfAOAndDepthTexture` | rid 235 = E7 SSAO 输出 |
| float2 | — | `TEXCOORD0` | 全屏 quad UV |

### `cb_SSAOBlur` 结构体（48 字节）

```
offset  type    name                用途
0       float2  _SSAO_PixelOffset   像素级偏移量（texel size）
16      float4  _SSAO_SampleParams  采样参数（与 SSAO 共享一部分）
32      float   _SSAO_Sharpness     边缘保持锐度（双边滤波权重衰减因子）
```

### 算法概述

从 136 行 IR 可完整读出：

1. **9-tap 十字形采样**：以当前像素为中心，沿 `_SSAO_PixelOffset` 方向取 ±1.5 texel 处的 4 个对角样本 + ±1.5 texel 的 4 个正交样本 + 中心 1 个。
2. **加权平均**：
   - 对角 4 tap 权重 = `0x3FC47AE1` = 0.1592... ≈ 0.16（四个共 0.636）
   - 正交 4 tap 权重 = `0x3FB47AE1` = 0.0796... ≈ 0.08（四个共 0.318）
   - 中心 tap 权重 = `0xH291F` ≈ 0.0445（half）
   - 总和 ≈ 1.0（0.636 + 0.318 + 0.044 ≈ 0.998）
3. **无深度感知的简单模糊**：从 IR 看，本帧的 SSAOBlur **没有显式的深度比较/边缘停止逻辑**（`_SSAO_Sharpness` 字段存在于 cbuffer 但 IR 中未 GEP 读取）。这是一个**纯 box-like 加权平均**，不是经典的 bilateral blur。可能是 mobile 优化版本。
4. **输出**: 单通道 R8（`SV_TARGET0` 的 `.r`），写入 rid 234。

---

## 逆向优先级建议

| 优先级 | 任务 | 难度 | 预期工时 |
|---|---|---|---|
| 🟢 低 | SSAOBlur (RPS 448) — 136 行，逻辑完全透明 | 极简单 | 10 分钟 |
| 🟡 中 | SSAO (RPS 447) — 524 行，核心是法线重建 + 半球采样循环 | 中等 | 1–2 小时 |

### 逆向 RPS 447 的建议切入点

1. **先搞清法线重建**（IR 行 10–60）：两次 `gather` + `fabs` 比较 → 重建的 view-space 法线。
2. **再搞 view-space 位置重建**（IR 行 32–52）：`_UVToView` + depth → 3D position。
3. **最后是采样循环**（IR 行 60–470）：展开的 N-tap 遮蔽计算。看是 HBAO / GTAO / Alchemy AO / 自定义。
4. **Cbuffer dump**：如需实测参数值，运行：
   ```bash
   python3 "$WRAPPER" dump-uniforms "$TRACE" <E7的draw_index> 0 --stage fragment --with-hex
   ```
   E7 只有 1 个 draw（draw_index_global = 54，通过 `jq '.command_buffers[1].encoders[6].draws[0].draw_index_global' data/frame.json` 确认）。

---

## 与管线其他文档的关系

- **产物去向**: E8 输出 rid 234 → E9 (RPS 449/463) 合成到 `_ScreenShadowTexture` 236 的 `.a` 通道 → E10/E13/E17 消费。
- **在 RPS 496 (SkinMakeupNew) 中的消费方式**: `charSpecular * screenShadow.a`（只衰减角色补光镜面高光）。详见 `07-skin-forward-lighting.md` §5。
- **SSAO 不读 229 (normal buffer)**: 通过 gather depth + cross-difference 自行重建法线。这解释了 `06-gbuffer-truth.md` §8.5 中"229 本帧无 fragment 显式 sample"的发现。
