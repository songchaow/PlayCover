#!/usr/bin/env python3
"""
Decode all texture .bin files from RPS 496 (Draw 69) AvatarResources and export as PNG.

The .bin files were exported by the gputrace replay bridge as raw pixel data (mip 0 only).
- RGBA8Unorm / RGBA8Unorm_sRGB / ASTC textures → all exported as decompressed RGBA8 (4 bytes/pixel)
- RG11B10Float → exported as raw packed 32-bit (11+11+10 unsigned float, 4 bytes/pixel)

Usage:
    python3 decode_textures.py [--output-dir <dir>]
"""
import numpy as np
import struct
import os
import sys
from PIL import Image

BASE = os.path.dirname(os.path.abspath(__file__))
TEX_DIR = os.path.join(BASE, "textures")
DEFAULT_OUTPUT = os.path.join(BASE, "textures_decoded")

# ──────────────────────────────────────────────────────────────────────────────
# Texture metadata from the gputrace resource list
# ──────────────────────────────────────────────────────────────────────────────
TEXTURES = [
    # (filename, rid, width, height, pixel_format, pixel_format_name, description)
    ("MainTexRT_rid222.bin",                    222, 512,  512,  71,  "RGBA8Unorm_sRGB",  "皮肤主贴图 (_MainTex)"),
    ("PL_Head_R_rid197.bin",                    197, 512,  512,  204, "ASTC_8x8_sRGB",    "高光/粗糙度 (_SpecularTex)"),
    ("PL_Head_MU_N_rid194.bin",                 194, 512,  512,  70,  "RGBA8Unorm",       "法线贴图 (_NormalTex)"),
    ("PL_Makeup_Eyebrow_12_D_rid195.bin",       195, 1024, 1024, 186, "ASTC_4x4_sRGB",   "眉毛 (_EyebrowTex)"),
    ("PL_Makeup_Eyeshadow_06_01_D_rid213.bin",  213, 512,  512,  186, "ASTC_4x4_sRGB",   "眼影 (_EyeshadowTex)"),
    ("PL_Makeup_Eyeliner_06_D_rid214.bin",      214, 512,  512,  186, "ASTC_4x4_sRGB",   "眼线 (_EyelinerTex)"),
    ("PL_Makeup_Blush_02_D_rid217.bin",         217, 512,  512,  186, "ASTC_4x4_sRGB",   "腮红 (_BlusherTex)"),
    ("PL_Makeup_Lip_02_D_rid200.bin",           200, 512,  512,  186, "ASTC_4x4_sRGB",   "唇部 (_LipTex)"),
    ("PL_Makeup_Head_ID_UNCOMPRESSED_rid196.bin", 196, 1024, 1024, 70, "RGBA8Unorm",     "面部ID/Morph分区 (_MorphPartTex)"),
    ("PL_Makeup_Eyelid_07_D_rid193.bin",        193, 512,  512,  204, "ASTC_8x8_sRGB",   "眼睑 (_EyelidTex)"),
    # Render targets
    ("LightIndexMap_rid145.bin",                145, 128,  128,  70,  "RGBA8Unorm",       "Cluster lighting索引 (_LightIndexMap)"),
    ("SSSSkinTexture_rid232.bin",               232, 583,  835,  92,  "RG11B10Float",     "SSS vertical-blur (_SSSSkinTexture)"),
    ("ScreenShadowTexture_rid236.bin",          236, 583,  835,  70,  "RGBA8Unorm",       "屏幕空间阴影 (_ScreenShadowTexture)"),
]


def decode_rg11b10_float(packed_u32):
    """
    Decode RG11B10Float packed format to float RGB.
    
    Layout (LSB to MSB in a uint32):
      bits [0:10]   = R (11-bit unsigned float: 5-bit exponent, 6-bit mantissa)
      bits [11:21]  = G (11-bit unsigned float: 5-bit exponent, 6-bit mantissa)
      bits [22:31]  = B (10-bit unsigned float: 5-bit exponent, 5-bit mantissa)
    
    11-bit float: exponent bias = 15, mantissa bits = 6
    10-bit float: exponent bias = 15, mantissa bits = 5
    """
    r_bits = (packed_u32 & 0x7FF).astype(np.uint32)          # bits 0-10
    g_bits = ((packed_u32 >> 11) & 0x7FF).astype(np.uint32)  # bits 11-21
    b_bits = ((packed_u32 >> 22) & 0x3FF).astype(np.uint32)  # bits 22-31

    def decode_11bit(bits):
        """11-bit unsigned float: 5-bit exp (bias 15), 6-bit mantissa."""
        exp = ((bits >> 6) & 0x1F).astype(np.int32)
        man = (bits & 0x3F).astype(np.float64)
        
        result = np.zeros_like(man, dtype=np.float64)
        
        # Normal: (1 + mantissa/64) * 2^(exp-15)
        normal_mask = (exp > 0) & (exp < 31)
        result[normal_mask] = (1.0 + man[normal_mask] / 64.0) * (2.0 ** (exp[normal_mask] - 15))
        
        # Denormal: (mantissa/64) * 2^(1-15) = (mantissa/64) * 2^(-14)
        denorm_mask = exp == 0
        result[denorm_mask] = (man[denorm_mask] / 64.0) * (2.0 ** (-14))
        
        # Inf/NaN (exp=31): treat as max value for display
        inf_mask = exp == 31
        result[inf_mask] = 65504.0  # max representable
        
        return result

    def decode_10bit(bits):
        """10-bit unsigned float: 5-bit exp (bias 15), 5-bit mantissa."""
        exp = ((bits >> 5) & 0x1F).astype(np.int32)
        man = (bits & 0x1F).astype(np.float64)
        
        result = np.zeros_like(man, dtype=np.float64)
        
        # Normal: (1 + mantissa/32) * 2^(exp-15)
        normal_mask = (exp > 0) & (exp < 31)
        result[normal_mask] = (1.0 + man[normal_mask] / 32.0) * (2.0 ** (exp[normal_mask] - 15))
        
        # Denormal
        denorm_mask = exp == 0
        result[denorm_mask] = (man[denorm_mask] / 32.0) * (2.0 ** (-14))
        
        # Inf/NaN
        inf_mask = exp == 31
        result[inf_mask] = 65504.0
        
        return result

    r = decode_11bit(r_bits)
    g = decode_11bit(g_bits)
    b = decode_10bit(b_bits)
    
    return r, g, b


def tonemap_hdr(r, g, b):
    """
    Simple Reinhard tonemap + gamma for HDR data visualization.
    Maps [0, inf) to [0, 1] then applies sRGB gamma.
    """
    # Reinhard tonemap
    r_tm = r / (1.0 + r)
    g_tm = g / (1.0 + g)
    b_tm = b / (1.0 + b)
    
    # sRGB gamma
    def linear_to_srgb(c):
        c = np.clip(c, 0.0, 1.0)
        low = c * 12.92
        high = 1.055 * np.power(c, 1.0 / 2.4) - 0.055
        return np.where(c <= 0.0031308, low, high)
    
    r_out = linear_to_srgb(r_tm)
    g_out = linear_to_srgb(g_tm)
    b_out = linear_to_srgb(b_tm)
    
    return r_out, g_out, b_out


def decode_rgba8(data, width, height, is_srgb=False, is_bgra=True):
    """
    Decode raw RGBA8/BGRA8 data to PIL Image.
    
    The bridge exports textures with standard row order (top-to-bottom).
    For textures read via getBytes (non-compressed), Metal returns BGRA byte order.
    For textures decompressed via render pass (ASTC/compressed), the output is already RGBA.
    If is_bgra=True (default for non-compressed), swap B and R channels.
    If is_srgb=True, the data is already in sRGB space (GPU stores sRGB-encoded values).
    """
    expected_size = width * height * 4
    if len(data) != expected_size:
        raise ValueError(f"Data size {len(data)} != expected {expected_size} for {width}x{height}")
    
    pixels = np.frombuffer(data, dtype=np.uint8).reshape(height, width, 4).copy()
    
    if is_bgra:
        # Bridge exports in BGRA byte order (Metal native format for getBytes)
        # Swap B and R channels: BGRA -> RGBA
        pixels[:, :, 0], pixels[:, :, 2] = pixels[:, :, 2].copy(), pixels[:, :, 0].copy()
    
    # Check if alpha channel is meaningful (has significant variation)
    alpha = pixels[:, :, 3]
    alpha_mean = alpha.mean()
    # If alpha is nearly all-zero or all-opaque, output as RGB only
    # (render targets often store non-transparency data in alpha)
    if alpha_mean < 32 or alpha_mean > 250:
        img = Image.fromarray(pixels[:, :, :3], mode='RGB')
    else:
        img = Image.fromarray(pixels, mode='RGBA')
    return img


def decode_rg11b10_texture(data, width, height):
    """
    Decode RG11B10Float texture to a tonemapped RGB PNG.
    """
    expected_size = width * height * 4
    if len(data) != expected_size:
        raise ValueError(f"Data size {len(data)} != expected {expected_size} for {width}x{height} RG11B10Float")
    
    packed = np.frombuffer(data, dtype=np.uint32).reshape(height, width)
    r, g, b = decode_rg11b10_float(packed.flatten())
    
    # Reshape to image dimensions
    r = r.reshape(height, width)
    g = g.reshape(height, width)
    b = b.reshape(height, width)
    
    # Tonemap for visualization
    r_out, g_out, b_out = tonemap_hdr(r, g, b)
    
    # Convert to uint8
    rgb = np.stack([
        (r_out * 255.0).astype(np.uint8),
        (g_out * 255.0).astype(np.uint8),
        (b_out * 255.0).astype(np.uint8),
    ], axis=-1)
    
    img = Image.fromarray(rgb, mode='RGB')
    return img


def validate_image(img, name):
    """
    Basic validation to detect garbled/corrupted images.
    Checks for:
    - All-zero (completely black)
    - All-same-value (flat)
    - Extreme pixel distribution (likely garbled)
    """
    arr = np.array(img)
    
    issues = []
    
    # Check all-zero
    if arr.max() == 0:
        issues.append("WARNING: image is completely black (all zeros)")
    
    # Check all-same
    if arr.min() == arr.max():
        issues.append(f"WARNING: image is flat (all pixels = {arr.min()})")
    
    # Check for garbled pattern: if the image has very few unique values
    # in a way that suggests byte-swizzle error
    if len(arr.shape) == 3 and arr.shape[2] >= 3:
        # Check if one channel is all zeros while others aren't (might indicate channel swap)
        for ch_idx, ch_name in enumerate(['R', 'G', 'B']):
            ch = arr[:, :, ch_idx]
            if ch.max() == 0 and arr.max() > 0:
                issues.append(f"NOTE: {ch_name} channel is all zeros")
    
    # Check for suspicious row patterns (stride mismatch → diagonal garble)
    if len(arr.shape) == 3:
        # Compare adjacent rows - if they're all identical, might be stride issue
        if arr.shape[0] > 2:
            row_diffs = np.abs(arr[1:].astype(int) - arr[:-1].astype(int)).sum(axis=(1, 2))
            if row_diffs.max() == 0 and arr.max() > 0:
                issues.append("WARNING: all rows are identical (possible stride error)")
    
    return issues


def main():
    output_dir = DEFAULT_OUTPUT
    if "--output-dir" in sys.argv:
        idx = sys.argv.index("--output-dir")
        if idx + 1 < len(sys.argv):
            output_dir = sys.argv[idx + 1]
    
    os.makedirs(output_dir, exist_ok=True)
    
    print(f"Decoding textures from: {TEX_DIR}")
    print(f"Output directory: {output_dir}")
    print(f"Total textures: {len(TEXTURES)}")
    print("=" * 72)
    
    success_count = 0
    error_count = 0
    
    for filename, rid, width, height, pf, pf_name, desc in TEXTURES:
        src_path = os.path.join(TEX_DIR, filename)
        out_name = os.path.splitext(filename)[0] + ".png"
        out_path = os.path.join(output_dir, out_name)
        
        print(f"\n[rid {rid}] {filename}")
        print(f"  Format: {pf_name} ({pf}), Size: {width}x{height}")
        print(f"  Desc: {desc}")
        
        if not os.path.exists(src_path):
            print(f"  ERROR: source file not found!")
            error_count += 1
            continue
        
        try:
            data = open(src_path, 'rb').read()
            file_size = len(data)
            expected_size = width * height * 4
            
            if file_size != expected_size:
                print(f"  ERROR: file size {file_size} != expected {expected_size}")
                error_count += 1
                continue
            
            if pf == 92:  # RG11B10Float
                img = decode_rg11b10_texture(data, width, height)
            else:
                # All others are RGBA8 (bridge decompresses ASTC on export via render pass)
                is_srgb = pf in (71, 186, 204)  # sRGB variants
                # Metal getBytes byte order is determined by pixelFormat name:
                #   - RGBA8Unorm (70), RGBA8Unorm_sRGB (71) -> RGBA order, no swap needed
                #   - BGRA8Unorm (80), BGRA8Unorm_sRGB (81) -> BGRA order, need B<->R swap
                #   - ASTC (render pass decompressed) -> output is RGBA order, no swap needed
                is_bgra = pf in (80, 81)  # Only BGRA8 formats need swap
                img = decode_rgba8(data, width, height, is_srgb=is_srgb, is_bgra=is_bgra)
            
            # Validate
            issues = validate_image(img, filename)
            if issues:
                for issue in issues:
                    print(f"  {issue}")
            
            # Save
            img.save(out_path)
            file_kb = os.path.getsize(out_path) / 1024
            print(f"  ✓ Saved: {out_name} ({file_kb:.1f} KB)")
            success_count += 1
            
        except Exception as e:
            print(f"  ERROR: {e}")
            error_count += 1
    
    print("\n" + "=" * 72)
    print(f"Done! Success: {success_count}, Errors: {error_count}")
    print(f"Output: {output_dir}/")


if __name__ == "__main__":
    main()
