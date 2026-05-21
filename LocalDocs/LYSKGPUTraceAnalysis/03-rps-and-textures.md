# 03 — RPS 与纹理索引

> 数据来源：`data/rps_index.json` + `data/textures_index.json`

## 1. 65 个 RPS 全表（按 key 升序）

> 表头：`key | label | vertex_fn / fragment_fn | color# | depth | 出现的 encoder`
>
> `vf=A/B` 中 A 是 vertex_function_key，B 是 fragment_function_key（都是 trace 内部的 MTLFunction 句柄 ID，可以喂给 `shader-of-rps` / `disasm` 拉 IR）。

### 1.1 后处理 / 屏幕空间（440–471 段，主要是「**全屏 quad** + post-effect」）

| key | label | vf=v/f | color# | depth | 出现 encoder |
|---|---|---|---|---|---|
| 440 | Unlit/TAA/TemporalAA | 257/259 | 2 | D32S8 | E4（draw51 — 收尾全屏 quad） |
| 441 | Unlit/TAA/TemporalAA | 265/267 | 1 | Other | **E18 — TAA 主体** |
| 442 | Unlit/FSR_EASU_PS | 263/271 | 1 | Other | **E29 — FSR EASU** |
| 443 | Unlit/FSR_RCAS_PS | 263/273 | 1 | D32S8 | **E30 draw102 — FSR RCAS** |
| 444 | Hidden/InternalClearMetal | 275/277 | 1 | D32S8 | E30 draw103（stencil 初始化） |
| 445 | TextMeshPro/Distance Field | 279/281 | 1 | D32S8 | E30 draw108（文本） |
| 446 | Hidden/Papegame/DepthResolve | 263/291 | 1 | D32S8 | **E6 — DepthResolve** |
| 447 | Unlit/SSAO | 293/295 | 1 | Other | **E7 — SSAO** |
| 448 | Unlit/SSAOBlur | 293/297 | 1 | Other | **E8 — SSAO Blur** |
| 449 | Hidden/Papegame/ScreenSpaceShadowMap | 261/299 | 1 | D32S8 | E9（SSSM compose） |
| 450 | Unlit/Papegame/SpotShadow | 301/303 | 1 | D32S8 | E9 |
| 451 | Papegame/Atmosphere/CustomNewSky | 305/307 | 1 | D32S8 | **E13 — Sky** |
| 452 | Papegame/Effect/EffectFresnel | 309/311 | 1 | D32S8 | E13（特效） |
| 453 | Papegame/Effect/EffectMisregist | 313/315 | 1 | D32S8 | E13（特效×3） |
| 454 | Papegame/Effect/EffectMisregist | 313/315 | 1 | D32S8 | E13 |
| 455 | Papegame/Effect/EffectFresnel | 309/311 | 1 | D32S8 | E13 |
| 456 | Hidden/Papegame/DOFDownSample | 269/317 | 1 | Other | **E14 — DOF down** |
| 457 | Hidden/Papegame/DOFGather | 269/319 | 1 | Other | **E16 — DOF gather** |
| 458 | Papegame/Bloom | 321/323 | 1 | Other | **E19 — Bloom threshold/down 0** |
| 459 | Papegame/Bloom | 321/325 | 1 | Other | **E20–E23 — Bloom down pyramid** |
| 460 | Papegame/Bloom | 269/327 | 1 | Other | **E24–E27 — Bloom up pyramid** |
| 461 | Hidden/Papegame/FinalBlit | 269/329 | 1 | Other | **E28 — Tonemap/FinalBlit** |
| 462 | Hidden/Papegame/ScreenSpaceShadowMap | 261/331 | 1 | Other | **E5 — Coarse SSSM** |
| 463 | Hidden/Papegame/ScreenSpaceShadowMap | 261/333 | 1 | D32S8 | E9 |
| 464 | Hidden/Papegame/SeparableSubsurfaceScatter | 269/335 | 1 | Other | **E11 — SSS H-blur** |
| 465 | Hidden/Papegame/SeparableSubsurfaceScatter | 269/337 | 1 | Other | **E12 — SSS V-blur** |
| 466 | Hidden/EffectCombine2 | 283/285 | 1 | D32S8 | E30 draw121 |
| 467 | UI/Default | 339/341 | 1 | D32S8 | E30 ×16 draws |
| 468 | Unlit/InverseTonemapping | 343/249 | 2 | D32S8 | E4 draw40 |
| 469 | Unlit/InverseTonemapping | 345/347 | 1 | D32S8 | E13 draw66 |
| 470 | Papegame/Effect/EffectVertexDisplacement | 349/351 | 1 | D32S8 | E13 draw75 |
| 471 | Papegame/Effect/EffectDissolve | 353/355 | 1 | D32S8 | E17 |

### 1.2 角色材质 — Z-Prepass / Shadow Caster（472–480，全部 `color#=0, depth=D32F`）

| key | label | vf=v/f |
|---|---|---|
| 472 | Papegame/Cloth/ClothStandard | 359/375 |
| 473 | Papegame/Cloth/ClothStandard | 359/361 |
| 474 | Papegame/Teeth | 251/253 |
| 475 | Papegame/SkinSSS | 251/253 |
| **476** | **Papegame/SkinMakeupNew** | **251/253** |
| 477 | Papegame/Cloth/ClothStandard | 367/369 |
| 478 | Papegame/Cloth/ClothStandard | 359/361 |
| 479 | Papegame/EyeSpec | 287/253 |
| 480 | Papegame/HairScreenDoor | 377/379 |

→ 出现在 **E2（Cascade shadow）+ E3（Local shadow atlas）**。注意 474/475/476 共享 `vf=251/253`，是同一个 depth-only shader 在不同 render-state 下的实例（很可能 alpha-test mask 不同）。

### 1.3 角色材质 — GBuffer 主写入（481–489，全部 `color#=2, depth=D32S8`）

| key | label | vf=v/f |
|---|---|---|
| 481 | Papegame/Cloth/ClothStandard | 363/365 |
| 482 | Papegame/Cloth/ClothStandard | 363/365 |
| 483 | Papegame/Cloth/ClothStandard | 363/365 |
| **484** | **Papegame/SkinMakeupNew** | **289/357** |
| 485 | Papegame/SkinSSS | 289/357 |
| 486 | Papegame/EyeSpec | 289/357 |
| 487 | Papegame/Teeth | 289/357 |
| 488 | Papegame/Cloth/ClothStandard | 371/373 |
| 489 | Papegame/HairScreenDoor | 381/383 |

→ 出现在 **E4 GBuffer pass**。484–487 共享 `vf=289/357`，说明皮肤/眼/牙在 GBuffer 阶段使用**同一个 fragment shader**（差异由 binding 决定）。

### 1.4 角色材质 — Half-res Lighting Branch（490–492，仅皮肤+牙齿）

| key | label | vf=v/f |
|---|---|---|
| 490 | Papegame/Teeth | 385/387 |
| **491** | **Papegame/SkinMakeupNew** | **389/391** |
| 492 | Papegame/SkinSSS | 393/395 |

→ 出现在 **E10 半分辨率 lighting**。

### 1.5 角色材质 — Full-res HDR Compose（493–500）

| key | label | vf=v/f | 备注 |
|---|---|---|---|
| 493 | Papegame/Cloth/ClothStandard | 397/399 | |
| 494 | Papegame/Teeth | 401/403 | |
| 495 | Papegame/EyeSpec | 405/407 | |
| **496** | **Papegame/SkinMakeupNew** | **409/411** | **采样 232 SSS 结果** |
| 497 | Papegame/SkinSSS | 413/415 | 同样采样 232 |
| 498 | Papegame/Cloth/ClothStandard | 417/419 | |
| 499 | Papegame/Cloth/ClothStandard | 417/421 | |
| 500 | Papegame/Cloth/ClothStandard | 417/423 | |

→ 出现在 **E13 全分辨率 HDR compose**。

### 1.6 角色材质 — Refraction / Transparent 收尾（501–504）

| key | label | vf=v/f |
|---|---|---|
| 501 | Papegame/HairScreenDoor | 425/427 |
| 502 | Papegame/EyeCornea | 429/431 |
| 503 | Papegame/Eyelash | 433/435 |
| 504 | Papegame/HairTransparent | 437/439 |

→ 出现在 **E17**，需要读 224 已 DOF 后的场景做 refraction / blend。

### 1.7 唯一的 Compute Pipeline

| key | class | label |
|---|---|---|
| **505** | `AGXG16XFamilyComputePipeline` | **CalcLighting.CSMain** |

→ 出现在 **E1 / E32**（每帧一次）。

---

## 2. 关键 attachment 纹理表

> 数据来源：`data/textures_index.json`（全 247 个资源中筛出有 `renderTarget` usage 的部分）

| ID | 大小 | 格式 | label | 角色 |
|---|---|---|---|---|
| 139 | 1668×2388 | D32S8 | — | swapchain depth/stencil（E30 用） |
| **147** | 1668×2388 | BGRA8Unorm | `CAMetalLayer Display Drawable` | **CB1 swapchain** |
| **160** | 1668×2388 | BGRA8Unorm | `CAMetalLayer Display Drawable` | **CB3 swapchain** |
| 222 | 512×512 | RGBA8Unorm_sRGB | `MainTexRT` | UI / 离屏（具体用途未在主链路出现） |
| **224** | 1167×1671 | RGBA16Float | `TempBuffer 118` | **HDR 场景颜色（主合成输出）** |
| **225** | 3072×1024 | Depth32Float | `DirectionalShadowDepth` | **主光定向阴影 atlas（3 cascade）** |
| **226** | 1024×1024 | Depth32Float | `LocalShadowmapAtlas` | **局部光阴影 atlas** |
| **227** | 1167×1671 | D32S8 | `TempBuffer 119` | **主深度+模板** |
| **228** | 1167×1671 | RGBA8Unorm | `TempBuffer 120` | **GBuffer slot 0** |
| **229** | 1167×1671 | RGBA8Unorm | `TempBuffer 121` | **GBuffer slot 1** |
| 230 | 291×417 | R8Unorm | `TempBuffer 122` | 1/4 area Coarse SSSM（E5） |
| 231 | 583×835 | D32S8 | `TempBuffer 123` | 半分辨率深度+模板（E6 输出） |
| **232** | 583×835 | RG11B10Float | `TempBuffer 124` | **半分辨率皮肤 lighting / SSS in-out** |
| 233 | 583×835 | R32Float | `TempBuffer 125` | DepthResolve 标量深度 |
| 234 | 583×835 | R8Unorm | `TempBuffer 126` | SSAO + SSS-mask 复用 |
| 235 | 583×835 | R8Unorm | `TempBuffer 127` | SSAO 中间 |
| 236 | 583×835 | RGBA8Unorm | `TempBuffer 128` | 半分辨率 ScreenSpaceShadow composite（E9） |
| 237 | 583×835 | RG11B10Float | `TempBuffer 129` | SSS H-blur 中间（E11） |
| 238 | 583×835 | RGBA16Float | `TempBuffer 130` | DOF down（E14） |
| **239** | 1167×1671 | RGBA16Float | `CameraColor2_0` | **TAA history A**（CB1 写、CB3 读） |
| 240 | 111×160 | RGBA16Float | `TempBuffer 131` | Bloom L1 |
| 241 | 55×80 | RGBA16Float | `TempBuffer 132` | Bloom L2 |
| 242 | 27×40 | RGBA16Float | `TempBuffer 133` | Bloom L3 |
| 243 | 13×20 | RGBA16Float | `TempBuffer 134` | Bloom L4（bottom） |
| 244 | 223×320 | RGBA16Float | `TempBuffer 135` | Bloom L0 / 顶部累加（E19 写、E27 写、E28 读） |
| 245 | 1167×1671 | RGBA8Unorm | `TempBuffer 136` | **FinalBlit/Tonemap 输出 → FSR EASU 输入** |
| 246 | 1668×2388 | RGBA8Unorm | `TempBuffer 137` | **FSR EASU 输出 → FSR RCAS 输入** |
| **247** | 1167×1671 | RGBA16Float | `LastFrameTexture0` | **TAA history B**（CB1 读、CB3 写） |

## 3. 纹理 → encoder 写入/读取 矩阵（关键资源）

| 纹理 | 写入它的 encoder | 读取它的 encoder（推断） |
|---|---|---|
| 225 | E2（30 draws） | E9, E10, E13 |
| 226 | E3（10 draws） | E10, E13 |
| 227 | E4 | E6, E9, E10, E13, E17 |
| 228 / 229 | E4 | E5–E10, E13, E17 |
| 230 | E5 | E9 |
| 231 / 233 | E6 | E7, E8, E9, E10 |
| 234 | E8（写）, E10（再写） | E10, E13, E17 |
| 235 | E7 | E8 |
| 236 | E9 | E10, E13 |
| 232 | E10（写）, E12（写回） | E11, E13（RPS 496/497） |
| 237 | E11 | E12 |
| 238 | E14 | E15 (blit), E16 |
| 224 | E13, E16, E17 | E18, E14（read for DOF down） |
| 239 / 247 | E18（CB1 写 239 / CB3 写 247） | E18 next frame（即 CB3 / CB1） |
| 244 | E19, E27 | E28 |
| 245 | E28 | E29 |
| 246 | E29 | E30 |
| 147 / 160 | E30 / E61 | Present |

## 4. 拉 IR 的快速命令（接 `OfflineSourceRecovery/`）

```bash
BRIDGE=$HOME/Codes/PlayCover/.codebuddy/skills/gpu-trace-analysis/scripts/gputrace_replay_bridge
TRACE=$HOME/Library/Containers/com.papegames.lysk/Data/Documents/Captures/capture_20260518_110050.gputrace
OUT=/tmp/lysk-shaders

# 例：拉 SkinMakeupNew 5 个变体的 IR
for K in 476 484 491 496; do
    "$BRIDGE" shader-of-rps "$TRACE" $K --with-ir --output-dir "$OUT/rps_$K"
done

# 例：拉 SeparableSSS 两个 blur 变体
for K in 464 465; do
    "$BRIDGE" shader-of-rps "$TRACE" $K --with-ir --output-dir "$OUT/rps_$K"
done
```

完整复现命令见 `05-reproduction.md`。
