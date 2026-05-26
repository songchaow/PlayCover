# 20260526 - ASTC 压缩纹理导出修复

> **任务来源**: 用户发现 `PL_Makeup_Lip_02_D_rid200.png` 导出结果呈现横条/竖条纹理，完全不是唇部图案  
> **Trace**: `capture_20260518_110050.gputrace`  
> **涉及文件**: `AvatarResources/decode_textures.py`, bridge `.m` 源码  
> **完成时间**: 2026-05-26

---

## 1. 任务背景

上一个 commit (`3232cc5`) 完成了 AvatarResources 目录下 13 张纹理 `.bin` 文件到 PNG 的解码脚本。用户在验证时发现唇部纹理 (`PL_Makeup_Lip_02_D_rid200.png`) 导出结果完全错误——图像呈现横条/竖条纹理而非唇部图案，与 Xcode GPU Debugger 中预览的正确唇部贴图完全不一致。

## 2. 问题调查过程

### 2.1 初步分析

对比导出的 PNG 与 Xcode 预览：
- **导出结果**: 横条/竖条纹理，数据明显错乱
- **Xcode 预览**: 正确的唇部形状（肤色区域 + 黑色背景 + 半透明渐变）

### 2.2 根因定位

通过 hex dump 分析 `.bin` 文件数据发现：

```
00000000: fcfd ffff ffff ffff 0000 0000 0000 0000
```

关键发现：
- `0xFCFD` 开头是 **ASTC void-extent block** 的标志
- 文件大小 1,048,576 = 512×512×4，表面上与 RGBA8 预期一致
- 但只有前 128 行有实际内容（128 block rows × 2048 bytes = 262,144 bytes 是 ASTC 4x4 的实际数据量）

**结论**: Bridge 的 `--export` 命令对 ASTC 纹理调用 `getBytes:bytesPerRow:fromRegion:mipmapLevel:` 时，Metal 返回的是**原始 ASTC 压缩块数据**，而不是解压后的 RGBA8 像素。

### 2.3 问题范围

所有 ASTC 格式的纹理都受影响：
- `PL_Makeup_Lip_02_D_rid200.bin` (ASTC_4x4_sRGB, pixelFormat 186)
- `PL_Head_R_rid197.bin` (ASTC_8x8_sRGB, pixelFormat 204)  
- `PL_Makeup_Eyebrow_12_D_rid195.bin` (ASTC_4x4_sRGB)
- `PL_Makeup_Eyeshadow_06_01_D_rid213.bin` (ASTC_4x4_sRGB)
- `PL_Makeup_Eyeliner_06_D_rid214.bin` (ASTC_4x4_sRGB)
- `PL_Makeup_Blush_02_D_rid217.bin` (ASTC_4x4_sRGB)
- `PL_Makeup_Eyelid_07_D_rid193.bin` (ASTC_8x8_sRGB)

## 3. 修复方案

### 3.1 Bridge 修改 (`gputrace_replay_bridge.m`)

#### 新增辅助函数

```objc
static BOOL is_compressed_format(MTLPixelFormat fmt) {
    if (fmt >= 186 && fmt <= 200) return YES;  // ASTC sRGB
    if (fmt >= 204 && fmt <= 218) return YES;  // ASTC LDR
    if (fmt >= 222 && fmt <= 236) return YES;  // ASTC HDR
    if (fmt >= 160 && fmt <= 167) return YES;  // PVRTC
    if (fmt >= 170 && fmt <= 183) return YES;  // ETC2/EAC
    if (fmt >= 130 && fmt <= 159) return YES;  // BC1-BC7
    return NO;
}

static MTLPixelFormat uncompressed_equivalent(MTLPixelFormat fmt) {
    if (fmt >= 186 && fmt <= 200) return MTLPixelFormatRGBA8Unorm_sRGB;
    if (fmt >= 204 && fmt <= 218) return MTLPixelFormatRGBA8Unorm;
    if (fmt >= 222 && fmt <= 236) return MTLPixelFormatRGBA16Float;
    return MTLPixelFormatRGBA8Unorm;
}
```

#### 导出逻辑修改

对压缩格式纹理，使用 **render pass + fullscreen triangle shader** 替代直接 `getBytes`：

1. 创建 RGBA8 destination texture (storageMode = shared)
2. 编译内联 Metal shader（fullscreen triangle + nearest sampler）
3. 创建 render pipeline state
4. 通过 render pass 将 ASTC 纹理采样写入 destination
5. 从 destination texture `getBytes` 导出

**关键**: Metal 的 blit `copyFromTexture:toTexture:` 不支持跨格式组转换（ASTC→RGBA8），只会做逐字节拷贝。必须通过 shader 采样来完成真正的解压。

### 3.2 decode_textures.py 修改

Bridge 通过 render pass 解压 ASTC 纹理后，输出的像素字节序为 **RGBA**（shader 写入的标准顺序），而非 Metal `getBytes` 的 BGRA native 字节序。因此 `decode_rgba8` 函数需要区分两种路径：

```python
def decode_rgba8(data, width, height, is_srgb=False, is_bgra=True):
    """
    For textures read via getBytes (non-compressed): Metal returns BGRA -> need swap
    For textures decompressed via render pass (ASTC): output is already RGBA -> no swap
    """
    # ...
    if is_bgra:
        pixels[:, :, 0], pixels[:, :, 2] = pixels[:, :, 2].copy(), pixels[:, :, 0].copy()
```

调用时根据 pixelFormat 判断：
```python
is_compressed = pf in (186, 204)  # ASTC formats
img = decode_rgba8(data, width, height, is_srgb=is_srgb, is_bgra=not is_compressed)
```

## 4. 发现的 Skill 不足

### 4.1 Bridge 不支持压缩纹理导出

原始 bridge 的 `bytes_per_pixel_for_format` 函数对 ASTC 格式（186, 204 等）走 `default: return 4` 分支，然后用 `getBytes` 读取。Metal 对 ASTC 纹理返回原始压缩块而非解压数据，bridge 完全没有处理这种情况。

### 4.2 Blit copy 不等于格式转换

第一次修复尝试使用 `MTLBlitCommandEncoder.copyFromTexture:toTexture:` 从 ASTC source 拷贝到 RGBA8 destination，但 blit copy 对不同格式组的纹理只做逐字节拷贝，不会执行解压。这导致 destination 中仍然是 ASTC 压缩数据。

### 4.3 README 中的描述有误

README 中声称 "bridge 在导出时已将 ASTC 压缩数据解压为 RGBA8"，但实际并非如此。bridge 只是分配了 `width*height*4` 大小的 buffer 然后 `getBytes`，Metal 填入的是原始 ASTC 块。

## 5. 经验教训

1. **Metal `getBytes` 对压缩纹理返回原始块数据**：不会自动解压。这是 Metal API 的设计行为，需要通过 GPU 操作（render pass 或 compute shader）来实现解压。

2. **Blit copy 不跨格式组转换**：`copyFromTexture:toTexture:` 在 source 和 destination pixelFormat 不属于同一 texture view compatible group 时，只做逐字节拷贝。ASTC 和 RGBA8 不在同一组内。

3. **Render pass shader 输出为 RGBA 字节序**：与 `getBytes` 的 BGRA native 字节序不同。decode 脚本需要区分这两种路径来决定是否做 B↔R swap。

4. **ASTC pixelFormat 枚举值需查 Metal headers**：
   - ASTC_4x4_sRGB = 186, ASTC_8x8_sRGB = 194（不是 204）
   - ASTC_4x4_LDR = 204, ASTC_8x8_LDR = 212
   - ASTC sRGB 范围: 186-200, LDR: 204-218, HDR: 222-236

5. **验证导出数据时应检查数据模式**：如果前几个字节呈现重复的 16-byte 模式（ASTC block size），说明数据是原始压缩块而非解压后的像素。

## 6. 可复用脚本

本次执行涉及两个可复用脚本：

### 6.1 `gputrace_replay_bridge` (Objective-C CLI)

**位置**: `.codebuddy/skills/gpu-trace-analysis/scripts/gputrace_replay_bridge.m`

用途：从 `.gputrace` 文件中 replay Metal 命令流并导出纹理资源。本次新增的 ASTC 解压能力使其成为通用的纹理导出工具，支持：
- 非压缩格式（RGBA8, RG11B10Float 等）：直接 `getBytes` 导出
- ASTC/BC/ETC 压缩格式：通过 render pass shader 解压后导出为 RGBA8

编译方式：
```bash
cd .codebuddy/skills/gpu-trace-analysis/scripts
clang -fobjc-arc -framework Metal -framework Foundation -framework CoreGraphics -framework IOKit \
  -o gputrace_replay_bridge gputrace_replay_bridge.m
```

使用示例：
```bash
./gputrace_replay_bridge replay /path/to/capture.gputrace --export <resource_id> /path/to/output.bin
./gputrace_replay_bridge replay /path/to/capture.gputrace --list-resources
```

### 6.2 `decode_textures.py` (Python)

**位置**: `LocalDocs/LYSKGPUTraceAnalysis/AvatarResources/decode_textures.py`

用途：将 bridge 导出的 `.bin` 原始像素数据批量转换为 PNG 图片。支持的像素格式：
- RGBA8Unorm / RGBA8Unorm_sRGB（从 `getBytes` 导出，BGRA 字节序 → 需 B↔R swap）
- ASTC_4x4_sRGB / ASTC_8x8_sRGB（从 render pass 导出，已经是 RGBA 字节序 → 无需 swap）
- RG11B10Float（手动解包为 HDR 再 tone-map）

关键设计：通过 `is_bgra` 参数区分两种字节序路径：
```python
is_compressed = pf in (186, 187, 188, ..., 218)  # ASTC formats
img = decode_rgba8(data, width, height, is_srgb=is_srgb, is_bgra=not is_compressed)
```

使用示例：
```bash
cd LocalDocs/LYSKGPUTraceAnalysis/AvatarResources
python3 decode_textures.py [--output-dir <dir>]
```

## 8. 修改文件列表

| 文件 | 修改类型 | 说明 |
|------|----------|------|
| `.codebuddy/skills/gpu-trace-analysis/scripts/gputrace_replay_bridge.m` | 修改 | 添加 `is_compressed_format`, `uncompressed_equivalent`; 导出逻辑加入 render pass 解压路径 |
| `LocalDocs/LYSKGPUTraceAnalysis/AvatarResources/decode_textures.py` | 修改 | `decode_rgba8` 添加 `is_bgra` 参数; 主循环根据 pixelFormat 判断是否需要 B↔R swap |
| `LocalDocs/LYSKGPUTraceAnalysis/AvatarResources/textures/*.bin` | 重新导出 | 所有 ASTC 纹理通过修复后的 bridge 重新导出 |
| `LocalDocs/LYSKGPUTraceAnalysis/AvatarResources/textures_decoded/*.png` | 重新生成 | 所有 PNG 通过修复后的脚本重新生成 |

## 9. 验证结果

修复后的 `PL_Makeup_Lip_02_D_rid200.png` 正确显示唇部形状，与 Xcode GPU Debugger 预览一致。所有 13 张纹理成功解码（0 errors）。
