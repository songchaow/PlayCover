# 04 — Skin / SSS Pipeline 在帧内的精确定位

> 这份文档是这次帧分析最直接对接 `LocalDocs/OfflineSourceRecovery/` 现有调试工作的部分。
> 你之前抓的 `Papegame_SkinMakeupNew_*_lib*.ll` / `SeparableSubsurfaceScatter_fragment.ll` / `library_ptr_map.json` 在本帧里的位置全部在这里给定。

## 1. SkinMakeupNew 的 5 个变体在哪里

LYSK 把同一种「皮肤+底妆」材质按渲染阶段拆成了 5 个 RPS。一帧内全部出现：

| RPS | label | vf=v/f | encoder | RT | 含义 |
|---|---|---|---|---|---|
| **476** | Papegame/SkinMakeupNew | **251/253** | E2（cascade shadow ×3）+ E3（local shadow atlas） | depth=`225` / `226` D32F | **Z-Prepass / Shadow Caster** — 仅写 depth、做 alpha-test mask |
| **484** | Papegame/SkinMakeupNew | **289/357** | E4（velocity+normal pre-pass） | color={`228`, `229`} RGBA8 + d/s=`227` D32S8 | **Velocity + Normal pre-pass**（**不是 GBuffer**） — 写 motion vector 到 228、octa-normal+角色 mask 到 229、深度模板到 227。**不写材质属性、不被 lighting pass 读取**（详见 `06-gbuffer-truth.md`）|
| **491** | Papegame/SkinMakeupNew | **389/391** | E10（half-res lighting） | color={`232` RG11B10F, `234` R8} + d/s=`231` D32S8 | **半分辨率皮肤光照** — 输出皮肤 lighting 到 232（喂给 SSS）+ 写 SSS-mask 到 234 |
| **496** | Papegame/SkinMakeupNew | **409/411** | E13（full-res HDR compose） | color=`224` RGBA16F + d/s=`227` D32S8 | **全分辨率合成** — 采样 232（已 SSS 滤波）+ GBuffer + 阴影 → HDR 颜色 |
| ⚠ — | — | — | — | — | **第 5 个变体（refraction/transparent 阶段）在本 trace 中没出现**（皮肤本身不需要 refraction，眼睛/头发才有 — 见 RPS 502/503/504） |

> 与 `extract_shader_raw.py` 抓出来的文件名对应：
> - `Papegame_SkinMakeupNew_ZPrepass_RPS476_fragment_lib252.ll` ⇄ RPS **476**（fragment_function_key 253，library_key 252）
> - `Papegame_SkinMakeupNew_SubsurfacePass_RPS484_fragment_lib356.ll` ⇄ RPS **484**（fragment_function_key 357，library_key 356）
> - `Papegame_SkinMakeupNew_fragment_lib0x7b12cd440.ll` / `Papegame_SkinMakeupNew_fragment_lib0x7b12cd4c0.ll` ⇄ 应当对应 RPS **491**（half-res）和 RPS **496**（full-res compose）；可用 `data/rps_index.json` 中的 `fragment_library_key` 与 `library_ptr_map.json` 中的指针映射核对。

## 2. SSS 的两个 blur 变体在哪里

| RPS | label | vf=v/f | encoder | RT | 输入 → 输出 |
|---|---|---|---|---|---|
| **464** | Hidden/Papegame/SeparableSubsurfaceScatter | **269/335** | E11 | color=`237` RG11B10F 583×835 | 232 → 237（**水平方向**） |
| **465** | Hidden/Papegame/SeparableSubsurfaceScatter | **269/337** | E12 | color=`232` RG11B10F 583×835 | 237 → 232（**垂直方向，写回原 buffer**） |

→ `SeparableSubsurfaceScatter_fragment.ll` 对应 fragment_function_key 335 或 337（看你抓的是哪个变体）。两份 IR 应只有 **kernel 方向 / sample tap 偏移**的差异。

## 3. 完整数据流（皮肤侧）

```
                  ┌──────────────────────────────────────┐
                  │ E2/E3  Shadow Caster (RPS 476)       │
                  │   写 225 (cascade) + 226 (local)     │
                  └──────────────┬───────────────────────┘
                                 │
                                 ▼
       ┌──────────────────────────────────────────────────┐
       │ E4  GBuffer (RPS 484, vf=289/357)                │
       │   写 228 baseColor / 229 normal / 227 D+S        │
       └──────────────┬───────────────────────────────────┘
                      │
                      ▼
       ┌──────────────────────────────────────────────────┐
       │ E5–E9  Half-res prep                             │
       │   230 (Coarse SSSM)                              │
       │   233/231 (Half-res depth)                       │
       │   235→234 (SSAO + Blur)                          │
       │   236 (SSSM compose)                             │
       └──────────────┬───────────────────────────────────┘
                      │
                      ▼
       ┌──────────────────────────────────────────────────┐
       │ E10  Half-res Lighting (RPS 491, vf=389/391)     │
       │   读 228/229 GBuffer + 234 SSAO + 236 Shadow     │
       │      + 225 cascade shadow + lighting buffer      │
       │      + cluster lights (E1 compute output)        │
       │   写 232 (RG11B10F, 皮肤光照)                     │
       │   写 234 (R8, SSS-mask 通道)                      │
       └──────────────┬───────────────────────────────────┘
                      │
                      ▼
       ┌──────────────────────────────────────────────────┐
       │ E11  SSS H-Blur (RPS 464, vf=269/335)            │
       │   读 232 + 234 (mask 控制是否做)                  │
       │   写 237                                          │
       └──────────────┬───────────────────────────────────┘
                      │
                      ▼
       ┌──────────────────────────────────────────────────┐
       │ E12  SSS V-Blur (RPS 465, vf=269/337)            │
       │   读 237 + 234                                    │
       │   写 232 (in-place — 现在 232 = SSS 后皮肤光照)   │
       └──────────────┬───────────────────────────────────┘
                      │
                      ▼
       ┌──────────────────────────────────────────────────┐
       │ E13  Full-res Compose (RPS 496, vf=409/411)      │
       │   draw69 ic=27894（与 E2/E4/E10 同一份索引！）    │
       │   读 232 (SSS lighting) — 上采样到 1167×1671      │
       │   读 228/229 (GBuffer) — 重新解 normal/baseColor  │
       │   读 225 (cascade shadow) + 226 (local shadow)   │
       │   读 234 (SSAO + SSS-mask)                        │
       │   写 224 (HDR 场景颜色)                            │
       └──────────────────────────────────────────────────┘
```

## 4. SkinMakeupNew 的 ic（index count）追踪

同一组皮肤几何在帧中以**完全相同的 ic=27894**出现 5 次（E2 ×3 cascade + E3 ×1 local + E4 + E10 + E13），证明：

- 每帧角色皮肤被画 **6 次几何**（3 cascade + 1 local + 1 GBuffer + 1 half-res lighting + 1 full-res compose）。
  → cascade 那 3 次共享 RPS 476 即 fragment 253，可能是同一 viewport 渲染 3 cascade 段也可能是 3 个独立 draw（draw 列表显示是 3 段独立 draw，每段 RPS 476 + 27894 ic）。
- **几何根本没有 culling 上的差异**（ic 完全相等）— 也就是说没有针对 cascade 的 frustum 裁剪粒度。
- 半分辨率分支（RPS 491，E10）也对**全部 27894 三角形**算 lighting；这是 LYSK 选择「半分辨率覆盖率优先」而非「半分辨率只画 SSS-mask 区域」的工程决定。

`data/frame.json` 中的 draw_to_rps_map 可直接验证：

```bash
# 找出所有 ic=27894 的 draw
jq '.command_buffers[1].encoders[].draws[]? | select(.index_count==27894) | {idx:.draw_index_global, encoder:.draw_in_encoder, rps:.rps_key, label:.rps_label}' \
   data/frame.json
```

应输出：

| draw | encoder | RPS | label |
|---|---|---|---|
| 4 | E2 | 476 | SkinMakeupNew (cascade 0) |
| 14 | E2 | 476 | SkinMakeupNew (cascade 1) |
| 24 | E2 | 476 | SkinMakeupNew (cascade 2) |
| 34 | E3 | 476 | SkinMakeupNew (local) |
| 44 | E4 | 484 | SkinMakeupNew (GBuffer) |
| 47 (实际 idx 不同) | E10 | 491 | SkinMakeupNew (half-res) |
| 69 | E13 | 496 | SkinMakeupNew (full-res) |

## 5. 调试切入点建议

如果要排查皮肤渲染问题，按从根因到表现的顺序定位：

1. **形态错** → 看 RPS **484**（GBuffer），导出 228/229 检查 normal/baseColor 是否正常。
   ```bash
   "$BRIDGE" replay "$TRACE" --export 228 /tmp/gbuf0.bin
   "$BRIDGE" replay "$TRACE" --export 229 /tmp/gbuf1.bin
   ```
2. **光照黑/亮异常** → 看 RPS **491**（半分辨率 lighting），导出 232 检查（导出前需关闭 SSS pass 的写回）。
   ```bash
   "$BRIDGE" shader-of-drawcall "$TRACE" <draw_index_of_491> --with-ir --with-uniforms
   ```
3. **皮肤过红/过白/过糊** → 看 RPS **464/465**（SSS blur），尤其 sigma / kernel 偏移 cbuffer。
4. **最终颜色错** → 看 RPS **496**（full-res compose），它读 232+GBuffer 的混合系数最容易出问题。

每一项都可以通过 `shader-of-drawcall --with-bindings --with-uniforms` 一行命令拿到完整 binding 表 + cbuffer 字段。

## 6. 与 `OfflineSourceRecovery/` 已有产物的对账

| OfflineSourceRecovery 文件 | 在本帧中的精确身份 |
|---|---|
| `gputracebinaryreplacement/ShaderRaw/Papegame_SkinMakeupNew_ZPrepass_RPS476_fragment_lib252.ll` | RPS **476**, fragment_function_key=**253**, fragment_library_key=**252**, encoder **E2/E3**（shadow caster） |
| `gputracebinaryreplacement/ShaderRaw/Papegame_SkinMakeupNew_SubsurfacePass_RPS476_fragment_lib252.ll` | ⚠ 文件名误导 — 实际 RPS 476 不是 subsurface pass 而是 Z-prepass。Subsurface pass 是 RPS **484**。建议重命名 |
| `gputracebinaryreplacement/ShaderRaw/Papegame_SkinMakeupNew_SubsurfacePass_RPS484_fragment_lib356.ll` | RPS **484**, fragment_function_key=**357**, fragment_library_key=**356**, encoder **E4**（GBuffer，**真正的「subsurface pass」**） |
| `gputracebinaryreplacement/ShaderRaw/Papegame_SkinMakeupNew_fragment_lib0x7b12cd440.ll` | 通过 `library_ptr_map.json` 查 0x7b12cd440 → library_key → 比对 RPS 491 (vf=389/391) 或 496 (vf=409/411)（用 `data/rps_index.json` 反查 fragment_library_key 即可定案） |
| `gputracebinaryreplacement/ShaderRaw/Papegame_SkinMakeupNew_fragment_lib0x7b12cd4c0.ll` | 同上 |
| `gputracebinaryreplacement/ShaderRaw/SeparableSubsurfaceScatter_fragment.ll` / `SkinMakeupNew_fragment_lib0x7b12cd4c0.ll` | 对应 RPS **464**（vf=269/335）或 **465**（vf=269/337）；用 fragment_library_key 反查可定案 |

→ 建议下次拉文件时直接用 `--output-dir` 命名规范带上 `RPS<key>_vf<v>_<f>_lib<lib>` 三段，避免文件名歧义。

## 7. 一行命令拉所有皮肤变体的 IR + binding + uniform

```bash
BRIDGE=$HOME/Codes/PlayCover/.codebuddy/skills/gpu-trace-analysis/scripts/gputrace_replay_bridge
WRAPPER=$HOME/Codes/PlayCover/.codebuddy/skills/gpu-trace-analysis/scripts/gputrace_replay_wrapper.py
TRACE=$HOME/Library/Containers/com.papegames.lysk/Data/Documents/Captures/capture_20260518_110050.gputrace
OUT=/tmp/lysk-skin-all
mkdir -p "$OUT"

# 5 个 RPS（含 SSS H/V）
for K in 476 484 491 496 464 465; do
    "$BRIDGE" shader-of-rps "$TRACE" $K --with-ir --output-dir "$OUT/rps_$K"
done

# 也可以按 draw 拉（需要先用 frame.json 找 SkinMakeupNew 的 draw_index_global）
SKIN_DRAWS=$(jq -r '.draw_to_rps_map[] | select(.rps_key==496) | .draw_index_global' \
             "$HOME/Codes/PlayCover/LocalDocs/LYSKGPUTraceAnalysis/data/frame.json")
for D in $SKIN_DRAWS; do
    python3 "$WRAPPER" shader-of-drawcall "$TRACE" $D \
        --stage fragment --with-ir --with-uniforms \
        --output-dir "$OUT/draw_$D"
done
```
