# 02 — Frame Breakdown（CB1 一帧 30 个 encoder）

> 数据来源：`data/frame.json` + `data/cb1_summary.json` + `data/replay.json`（纹理 label）
>
> 表格列含义：
> - **Calls** — `[first_call_index, last_call_index]`，按 Metal API 调用号
> - **Draws** — encoder 内 draw 次数（不计 dispatch）
> - **RT** — color attachments（`tex_id:format`）+ depth/stencil
> - **RPS** — 该 encoder 内出现过的所有 RPS_key（按 unique 排）
>
> **CB3 镜像**：每个 encoder 在 CB3 中编号 +31（E1↔E32, E30↔E61），结构完全一致。

---

## 阶段 A — Pre-frame & Shadow

### E1 — CalcLighting (compute)

| 字段 | 值 |
|---|---|
| Calls | 117–117 |
| 类型 | compute |
| Draws / Dispatch | 0 / 1（CPS_key=505，label `CalcLighting.CSMain`，class `AGXG16XFamilyComputePipeline`）|
| RT | — |
| RPS | — |

**用途**：计算屏幕 cluster / tile 的 active light 列表，写入一个共享 buffer（具体 dispatch 网格需 R7.5 swizzle 才能拿到）。

**产物去向**：被后续每个读 lighting 的 fragment shader 通过 `setFragmentBuffer:atIndex:` 绑定。E10、E13、E17 中的角色 RPS 全部依赖它。

---

### E2 — Cascade Directional Shadow

| 字段 | 值 |
|---|---|
| Calls | 125–451 |
| 类型 | render |
| Draws | 30 |
| RT | depth=`225 DirectionalShadowDepth 3072×1024 D32F` |
| RPS | 472, 473, 474, 475, 476, 477, 478, 479, 480 |

**用途**：主光定向阴影 atlas — 9 个角色 depth-only RPS（皮肤/牙齿/眼/头发/布料 各一），在三段 viewport 上各画一遍 = 30 draws（**3 cascade × 10 draw**，恰好对应：每个 cascade 9 个 RPS + 1 个材质重复）。

**draw 列表节选（每个 cascade 段）**：

```
ClothStandard ic=15099 → ClothStandard ic=13434 → Teeth ic=8682 →
SkinSSS ic=1698 → SkinMakeupNew ic=27894 → ClothStandard ic=51699 →
ClothStandard ic=10047 → EyeSpec ic=2280 → EyeSpec ic=2280 → HairScreenDoor ic=50835
```

**产物**：`225` — 被 E5（quarter-res penumbra mask）、E9（full PCF 写入 236.R）采样。E10/E13 通过 236 间接获取方向光阴影信息。

---

### E3 — Local Shadow Atlas

| 字段 | 值 |
|---|---|
| Calls | 459–566 |
| 类型 | render |
| Draws | 10 |
| RT | depth=`226 LocalShadowmapAtlas 1024×1024 D32F` |
| RPS | 472, 473, 474, 475, 476, 477, 478, 479, 480 |

**用途**：局部光（spot / point）阴影 atlas — 同 9 个 RPS（多一个 EyeSpec 重复）渲染一次。

**产物**：`226` — 被 E9 中的 `SpotShadow` (RPS 450) 采样，写入 236.G。E10/E13 通过 236 间接获取局部光阴影信息。

---

## 阶段 B — Velocity + Normal Pre-pass（不是 GBuffer！）

### E4 — Velocity + Normal Pre-pass + Z

> ⚠ 注意：此 pass **不是传统 deferred GBuffer**。228/229 不存材质属性；它们是**TAA 用的 motion vector**（228）和 **screen-space octahedral normal + 角色 mask**（229）。完整证据与解码方法见 `06-gbuffer-truth.md`。

| 字段 | 值 |
|---|---|
| Calls | 570–671 |
| 类型 | render |
| Draws | 12 |
| RT | color={`228 RGBA8 (Velocity)`, `229 RGBA8 (Normal+Mask)`} + d/s=`227 D32S8` |
| RPS | 440, 468, 481, 482, 483, 484, 485, 486, 487, 488, 489 |

**用途**：在角色几何上写：
- **228 = packed motion vector**（curr.NDC.xy − prev.NDC.xy）→ 服务于 TAA reprojection；
- **229 = octahedral world-normal + sign(N.z) + A 通道角色前景 mask（0.047）**；
- **227 = 主深度+模板**（同时 Z-write，使后续屏幕空间 pass 能拿到 depth）。

所有 9 个角色 RPS（481–489）的 fragment shader **是同一份 motion+normal pack 模板**（详见 `06-gbuffer-truth.md §4`），**完全不采样任何材质纹理**（488/489 例外，做 alpha-test/stipple discard 才有 sample）。

**draw 列表（按时序）**：

```
draw40 RPS=468 Unlit/InverseTonemapping       ic=792    // 在 history TAA buffer 上做反映射，写 A=0 mask
draw41 RPS=481 Cloth/ClothStandard           ic=10047
draw42 RPS=482 Cloth/ClothStandard           ic=15099
draw43 RPS=483 Cloth/ClothStandard           ic=13434
draw44 RPS=484 SkinMakeupNew                 ic=27894   ← 关键 SkinMakeupNew velocity-prepass 变体
draw45 RPS=485 SkinSSS                       ic=1698
draw46 RPS=486 EyeSpec                       ic=2280
draw47 RPS=486 EyeSpec                       ic=2280
draw48 RPS=487 Teeth                         ic=8682
draw49 RPS=488 Cloth/ClothStandard           ic=51699   // alpha-test 变体
draw50 RPS=489 HairScreenDoor                ic=50835   // stipple alpha 变体
draw51 RPS=440 Unlit/TAA/TemporalAA          ic=null    // 收尾全屏 quad
```

**产物**：
- **228 (motion vector)** — 仅消费方：**E18 TAA (RPS 441)** 内的 `_VelocityTexture`
- **229 (octa-normal + mask)** — **本帧无 fragment 显式 sample**（细节见 `06-gbuffer-truth.md §8.5`）
- **227 (深度+模板)** — 被 E6, E9, E10, E13, E17 大量消费

→ 这一 pass 的产物**不喂给后续 lighting**。后续的 lighting compose（E10 / E13 / E17）**重新光栅化几何**并直接采样原始材质纹理，跑的是 forward 路线。

---

## 阶段 C — Half-res Screen-Space Effects

### E5 — Coarse Screen-Space Shadow Map (1/4 area)

| 字段 | 值 |
|---|---|
| Calls | 674–691 |
| 类型 | render |
| Draws | 1 |
| RT | color=`230 R8 291×417` |
| RPS | 462 (`Hidden/Papegame/ScreenSpaceShadowMap`) |

**用途**：用主光阴影 atlas 225 + 半分辨率深度，在 1/16 像素上预算一份粗 mask。

**产物**：`230` — 之后会在 E9 上采到半分辨率 / 在 E10 read。

---

### E6 — Depth Resolve (Half-res)

| 字段 | 值 |
|---|---|
| Calls | 693–713 |
| 类型 | render |
| Draws | 1 |
| RT | color=`233 R32F 583×835` + d/s=`231 D32S8 583×835` |
| RPS | 446 (`Hidden/Papegame/DepthResolve`) |

**用途**：主深度 227 → 半分辨率 R32F 标量 233 + 半分辨率 D32S8 231。

**产物**：
- `233` — 喂给 SSAO（E7）、SSS 半分辨率分支
- `231` — 半分辨率 lighting（E10）的 depth/stencil 目标

---

### E7 — SSAO

| 字段 | 值 |
|---|---|
| Calls | 715–732 |
| 类型 | render |
| Draws | 1 |
| RT | color=`235 R8 583×835` |
| RPS | 447 (`Unlit/SSAO`) |

**用途**：屏幕空间环境光遮蔽，输入 233（半分辨率深度）。法线可能从 depth 重建或从 229 采样（06 §8.5 扫描未能确认 229 在本帧被显式 sample）。

**产物**：`235` — 喂给 E8 模糊。

---

### E8 — SSAO Blur

| 字段 | 值 |
|---|---|
| Calls | 734–751 |
| 类型 | render |
| Draws | 1 |
| RT | color=`234 R8 583×835` |
| RPS | 448 (`Unlit/SSAOBlur`) |

**用途**：双边模糊 235 → 234。

**产物**：`234` — 喂给 E10 / E13 / E17 的 lighting compose。

---

### E9 — Screen-Space Shadow Composite

| 字段 | 值 |
|---|---|
| Calls | 753–800 |
| 类型 | render |
| Draws | 3 |
| RT | color=`236 RGBA8 583×835` + d/s=`231` |
| RPS | 449 (`Hidden/Papegame/ScreenSpaceShadowMap`), 450 (`Unlit/Papegame/SpotShadow`), 463 (`ScreenSpaceShadowMap`) |

**用途**：把 Cascade 方向光阴影（225 → PCF² → 236.R）、Spot 阴影（226 → Poisson disk → 236.G）、SSAO（234 → 236.A）合成到一张半分辨率 RGBA8 mask（236）。粗阴影 230 在 draw 56 (fallback) 中使用但被 draw 57 完全覆写。

**产物**：`236` — E10 / E13 lighting compose 时采样。

---

### E10 — Half-res Lighting (Skin/Teeth/SSS)

| 字段 | 值 |
|---|---|
| Calls | 803–854 |
| 类型 | render |
| Draws | 3 |
| RT | color={`232 RG11B10F`, `234 R8`} + d/s=`231` |
| RPS | 490 (`Teeth`), 491 (`SkinMakeupNew`), 492 (`SkinSSS`) |

**用途**：在半分辨率上对**仅皮肤+牙齿**做光照计算，写入 lighting buffer 232。同时把 234 的对应通道写为 SSS-mask（用于后面 SeparableSSS 是否启用的早出口）。

**注意**：这个 pass **重新光栅化角色几何**（vertex shader 的 input 是 POSITION0/NORMAL0/TANGENT0/TEXCOORD0..3 — 真实 mesh 数据），fragment shader 直接采样 5 张纹理：
- `_LightIndexMap` (rid 145，**CalcLighting.CSMain 的输出**)
- `_SpecularTex` (PL_Head_R)
- `_NormalTex` (PL_Head_MU_N — 直接读原图，**不通过 229**)
- `_EyelidTex` (PL_Makeup_Eyelid_07_D)
- `_ScreenShadowTexture` (236 — 半分辨率屏幕空间阴影)

→ **这是 forward shading 在 half-res 下的实例化**，不是 deferred lighting。

**产物**：
- `232` — 半分辨率皮肤 lighting，**SSS 输入**（E11/E12）
- `234`（修改） — SSS-mask + 残留 SSAO

> 这个 pass 只跑 3 个 RPS，不包含布料/眼睛/头发；说明 LYSK 把 SSS 限定在「皮肤 + 牙齿」三类材质上，其它材质保留全分辨率直照。

---

## 阶段 D — Separable Subsurface Scattering

### E11 — SSS Horizontal Blur

| 字段 | 值 |
|---|---|
| Calls | 857–874 |
| 类型 | render |
| Draws | 1 |
| RT | color=`237 RG11B10F 583×835` |
| RPS | 464 (`Hidden/Papegame/SeparableSubsurfaceScatter`) |

**用途**：水平方向 separable Gaussian-like SSS。输入 232，输出 237。

---

### E12 — SSS Vertical Blur

| 字段 | 值 |
|---|---|
| Calls | 876–893 |
| 类型 | render |
| Draws | 1 |
| RT | color=`232 RG11B10F`（**写回 232**） |
| RPS | 465 (`Hidden/Papegame/SeparableSubsurfaceScatter`) |

**用途**：垂直方向 SSS，写回 232。**结束后 232 = 已 SSS 滤波的半分辨率皮肤 lighting**。

**产物**：`232` — E13 全分辨率 compose 阶段被 `SkinMakeupNew (496)` / `SkinSSS (497)` 采样（上采样到全分辨率，作为漫反射主体乘以 `tintedAlbedo`）。

---

## 阶段 E — Full-res HDR Compose + Sky + FX

### E13 — 全分辨率主合成

| 字段 | 值 |
|---|---|
| Calls | 896–1180 |
| 类型 | render |
| Draws | **18** |
| RT | color=`224 CameraColor 1167×1671 RGBA16F` + d/s=`227` |
| RPS | 451, 452, 453, 454, 455, 469, 470, 493, 494, 495, 496, 497, 498, 499, 500 |

**用途**：这是这一帧的「主合成」pass。输入是 E10/E12 产的半分辨率 lighting (232) + 屏幕空间阴影 (236) + 材质原始纹理 + cluster lights (145) + 各 cbuffer，输出全分辨率 HDR 场景颜色 224。期间还混入大气、特效粒子、顶点位移特效。

> **注意**：RPS 496 (SkinMakeupNew) 的 fragment texture binding 中**没有** 228/229/225/226 — 皮肤材质通过 236 (ScreenShadow) 间接获取阴影信息，通过重新光栅化几何 + 采样原始 PL_* 贴图获取材质数据（详见 `08-rps496-binding-truth.md`）。其他 RPS（Cloth/Eye/Teeth）的 binding 情况参见各自分析。

**draw 列表（按时序，按用途分组）**：

```
■ Full-res Compose（角色材质上采样到 224）
draw64 RPS=493 Cloth/ClothStandard            ic=15099
draw65 RPS=494 Teeth                          ic=8682
draw66 RPS=469 Unlit/InverseTonemapping       ic=792    // pre-mix 处理
draw67 RPS=495 EyeSpec                        ic=2280
draw68 RPS=495 EyeSpec                        ic=2280
draw69 RPS=496 SkinMakeupNew                  ic=27894  ← 全分辨率皮肤合成（采样 232 SSS 结果）
draw70 RPS=497 SkinSSS                        ic=1698
draw71 RPS=498 Cloth/ClothStandard            ic=13434
draw72 RPS=499 Cloth/ClothStandard            ic=10047
draw73 RPS=500 Cloth/ClothStandard            ic=51699

■ Sky
draw74 RPS=451 Papegame/Atmosphere/CustomNewSky ic=3510

■ Effect / Vertex Displacement
draw75 RPS=470 EffectVertexDisplacement       ic=9600
draw76 RPS=452 EffectFresnel                  ic=6
draw77 RPS=453 EffectMisregist                ic=240
draw78 RPS=453 EffectMisregist                ic=1080
draw79 RPS=453 EffectMisregist                ic=2160
draw80 RPS=454 EffectMisregist                ic=1026
draw81 RPS=455 EffectFresnel                  ic=9600
```

**产物**：`224 CameraColor` — **本帧主输出**，被 E14（DOF）、E16（DOF gather 写回 224）、E17（眼/发/溶解再叠加）、E18（TAA）连续消费。

---

## 阶段 F — Depth of Field

### E14 — DOF Down-sample (Half-res)

| Calls | 1185–1202 | Draws | 1 | RT | `238 RGBA16F 583×835` | RPS | 456 (`Hidden/Papegame/DOFDownSample`) |

**用途**：把 224 下采样到 583×835，按 CoC 分桶。**产物 → E15/E16**。

### E15 — Blit (DOF helper)

| Calls | 1204 | Draws | 0 | 类型 | blit |

**用途**：DOF 中间纹理对齐 / 复用同一资源不同 mip 等的辅助 blit。

### E16 — DOF Gather

| Calls | 1208–1225 | Draws | 1 | RT | `224` (写回 HDR) | RPS | 457 (`Hidden/Papegame/DOFGather`) |

**用途**：从 238 采样、近场/远场聚合，写回 224（in-place DOF）。

---

## 阶段 G — Eyes / Hair / Dissolve 收尾

### E17 — Transparent / Refraction

| Calls | 1228–1315 | Draws | 6 | RT | `224 RGBA16F` + d/s=`227` | RPS | 471, 501, 502, 503, 504 |

**用途**：所有需要读 224（已 DOF 过的 HDR 场景）作为 refraction / blend 源的最后阶段。

```
draw RPS=501 HairScreenDoor              // 头发 stipple alpha
draw RPS=502 EyeCornea                   // 眼角膜（refraction，需要场景颜色）
draw RPS=503 Eyelash                     // 睫毛
draw RPS=504 HairTransparent             // 头发透明叠加
draw RPS=471 EffectDissolve              // 溶解特效
```

**产物**：`224` — 已含全部 opaque + sky + FX + 头发眼睛溶解。

---

## 阶段 H — TAA + Bloom

### E18 — TAA

| Calls | 1318–1335 | Draws | 1 | RT | `239 CameraColor2_0 1167×1671 RGBA16F` | RPS | 441 (`Unlit/TAA/TemporalAA`) |

**用途**：jitter resolve — 输入当前 224 + 上帧 247 LastFrameTexture0 → 输出 239。

> **CB1 写 239、读 247；CB3 写 247、读 239**。这两张图就是双历史 ping-pong 的 buffer。

### E19 — Bloom Threshold + Down (1167×1671 → 223×320)

| Calls | 1337–1354 | Draws | 1 | RT | `244 RGBA16F 223×320` | RPS | 458 (`Papegame/Bloom`) |

### E20–E23 — Bloom Down Pyramid

| Enc | Calls | RT | RPS |
|---|---|---|---|
| E20 | 1356–1372 | `240 RGBA16F 111×160` | 459 |
| E21 | 1374–1390 | `241 RGBA16F 55×80` | 459 |
| E22 | 1392–1408 | `242 RGBA16F 27×40` | 459 |
| E23 | 1410–1426 | `243 RGBA16F 13×20` | 459 |

**用途**：5 级下采样（含 E19 进入级）。RPS 459 是「bloom downsample fragment」。

### E24–E27 — Bloom Up Pyramid

| Enc | Calls | RT | RPS |
|---|---|---|---|
| E24 | 1428–1445 | `242` | 460 |
| E25 | 1447–1464 | `241` | 460 |
| E26 | 1466–1483 | `240` | 460 |
| E27 | 1485–1502 | `244` | 460 |

**用途**：5 级累加上采样。RPS 460 = 「bloom upsample + accumulate fragment」。最终 244 携带最大半径 bloom 贡献。

**Bloom 链总产物**：`244` — 喂给 E28 FinalBlit。

---

## 阶段 I — Tonemap / FSR / UI / Present

### E28 — FinalBlit / Tonemap

| Calls | 1504–1521 | Draws | 1 | RT | `245 RGBA8Unorm 1167×1671` | RPS | 461 (`Hidden/Papegame/FinalBlit`) |

**用途**：把 TAA 输出 239 + Bloom 244 合并 + tonemap → LDR 245。**注意分辨率仍是 1167×1671**（FSR 是后续步骤，这里还在渲染分辨率）。

### E29 — FSR EASU (1.0)

| Calls | 1523–1540 | Draws | 1 | RT | `246 RGBA8Unorm 1668×2388` | RPS | 442 (`Unlit/FSR_EASU_PS`) |

**用途**：边缘自适应缩放 — 把 LDR 245（1167×1671）放大到 246（1668×2388）。

### E30 — RCAS Sharpen + UI Overlay → Present

| Calls | 1542–1663 | Draws | **20** | RT | `147 BGRA8Unorm 1668×2388 swapchain` + d/s=`139 D32S8 1668×2388` | RPS | 443, 444, 445, 466, 467 |

**用途**：把上一步的 246 锐化后写入真正的 swapchain，再叠加全部 UI / 文字 / 特效 combine。

**draw 列表（按时序）**：

```
draw102 RPS=443 Unlit/FSR_RCAS_PS         ic=null    // RCAS 锐化 246 → 147
draw103 RPS=444 Hidden/InternalClearMetal ic=6       // stencil 初始化（UI clipping 用）
draw104 RPS=467 UI/Default                ic=96
draw105 RPS=467 UI/Default                ic=54
draw106 RPS=467 UI/Default                ic=18
draw107 RPS=467 UI/Default                ic=6
draw108 RPS=445 TextMeshPro/Distance Field ic=30     // 文本
draw109..120 RPS=467 UI/Default           ic=18~594  // 12 个 UI 批次
draw121 RPS=466 Hidden/EffectCombine2     ic=600     // 全屏特效叠加（最后一笔）
```

**产物**：`147` swapchain — present。

---

## 阶段 J — CB0 / CB2（cross-frame blit）

| CB | Call | 类型 | 用途（推断） |
|---|---|---|---|
| CB0 | 16 | blit | 上一帧收尾 — 把 history texture / 资源对齐到本帧使用 |
| CB2 | 1722 | blit | frame N 与 frame N+1 之间的同类 blit |

→ 内容上不影响主渲染流；如要确认细节需补 swizzle 拿 `MTLBlitCommandEncoder` 的 source/destination resource ID。

---

## 整帧对账表

| 阶段 | encoder | draws | 产物 | 主要消费方 |
|---|---|---|---|---|
| A. Pre-frame & Shadow | E1–E3 | 0+30+10 | lighting buf (145), 225, 226 | 145→E10/E13/E17；225→E5/E9；226→E9 |
| B. Velocity+Normal Pre-pass | E4 | 12 | 228 (velocity), 229 (octa-normal+mask), 227 (D+S) | E18 (228), E6/E9/E10/E13/E17 (227)；229 本帧无消费 |
| C. Half-res SS Effects | E5–E10 | 1+1+1+1+3+3 = 10 | 230, 231, 233, 234, 235, 236, 232 | E11, E13 |
| D. SSS | E11–E12 | 2 | 232 (滤波后) | E13 (RPS 496/497) |
| E. Full-res Compose | E13 | 18 | **224** | E14, E17, E18 |
| F. DOF | E14–E16 | 2 | 224 (in-place) | E17, E18 |
| G. Transparent/Refraction | E17 | 6 | 224 (in-place) | E18 |
| H. TAA + Bloom | E18–E27 | 10 | 239 (TAA out), 244 (Bloom out) | E28 |
| I. Tonemap/FSR/UI | E28–E30 | 22 | 245 → 246 → 147 (swapchain) | Present |
| **合计** | **30** | **122** | | |
