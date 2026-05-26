# R11: Skill 防呆与鲁棒性加固

**执行时间**: 2026-05-26 19:49
**状态**: ✅ 全部完成

## 背景

R10（ASTC 修复）暴露了 skill 在"非常规纹理格式"场景下的脆弱性。当前 skill 核心功能齐备，但在边缘场景和 agent 使用体验上存在防呆缺陷。R11 聚焦于四个子任务来解决这些问题。

## 完成的子任务

### R11.1: `--export` 导出后自动验证

**改动文件**: `gputrace_replay_bridge.m`（export 成功后新增验证逻辑）

**实现方式**:
- 导出成功后，重新打开文件并采样前 64KB
- 检测全零、文件大小一致性、非零字节百分比
- 输出结构化 `export_verification` JSON 对象:
  ```json
  {
    "file_size": 16777216,
    "expected_bytes": 16777216,
    "size_match": true,
    "all_zero": false,
    "sample_non_zero_bytes": 52802,
    "sample_size": 65536,
    "non_zero_pct": 80.57,
    "warnings": []
  }
  ```
- 自动生成 warnings（全零、大小不匹配、<1% 非零）

### R11.2: `--export` 输出 `.meta.json`

**改动文件**: `gputrace_replay_bridge.m`

**实现方式**:
- 导出成功后，自动在 `<export_path>.meta.json` 写入元信息
- 包含 width、height、bytes_per_pixel、bytes_per_row、original/output pixel format、was_decompressed、channel_order 等
- JSON 输出中报告 `export_meta_path` 让调用方知道文件位置

**示例 .meta.json**:
```json
{
  "export_id": 151,
  "export_bytes": 16777216,
  "resource_type": "texture",
  "width": 2048,
  "height": 2048,
  "original_pixel_format": 208,
  "original_pixel_format_name": "ASTC_6x6_LDR",
  "output_pixel_format": 70,
  "output_pixel_format_name": "RGBA8Unorm",
  "bytes_per_pixel": 4,
  "bytes_per_row": 8192,
  "was_decompressed": true,
  "original_block_size": "6x6",
  "channel_order": "RGBA"
}
```

### R11.3: `--list-resources` 压缩格式标记

**改动文件**: `gputrace_replay_bridge.m`, `gputrace_replay_wrapper.py`

**实现方式**:
- 新增 `compressed_block_size()` 辅助函数，返回压缩格式的块大小字符串
- 增强 `pixel_format_name()` 覆盖 ASTC/BC/ETC/PVRTC 格式
- 在资源枚举 JSON 中为纹理添加 `"compressed": true/false` 和 `"block_size": "4x4"` 字段
- Python wrapper `Resource` dataclass 同步添加 `compressed` 和 `block_size` 字段

**验证结果**: LYSK trace 247 资源中检测出 57 个压缩纹理，格式名正确（如 `ASTC_6x6_LDR`）

### R11.4: SKILL.md 补充压缩纹理导出注意事项

**改动文件**: `SKILL.md`, `cli-reference.md`

**实现方式**:
- Known Blind Spots 新增 "Compressed Texture Export (R10/R11)" 子节
- Pattern 5 更新，加入压缩纹理检测和 meta.json 使用指导
- cli-reference.md replay 章节新增 R11 export 输出字段文档
- Skill description 扩展，覆盖纹理导出/压缩格式/数据验证场景

## 测试结果

- **编译**: ✅ 无新错误（仅预期的 performSelector warnings）
- **离线测试**: ✅ help 子命令、dataclass 导入正常
- **Live trace 回归**: ✅ **148/148** 全通过
- **R11 功能验证**:
  - R11.3: 57 个压缩纹理正确标记，格式名正确
  - R11.1: export_verification 正确输出（size_match=true, all_zero=false, 80.57% non-zero）
  - R11.2: .meta.json 正确生成（2048x2048 ASTC_6x6_LDR → RGBA8Unorm, was_decompressed=true）

## 改动文件清单

| 文件 | 改动类型 |
|------|---------|
| `.codebuddy/skills/gpu-trace-analysis/scripts/gputrace_replay_bridge.m` | 新增：compressed_block_size()、增强 pixel_format_name()、导出后自动验证 + .meta.json 写入、资源枚举 compressed/block_size |
| `.codebuddy/skills/gpu-trace-analysis/scripts/gputrace_replay_wrapper.py` | 新增：Resource.compressed/block_size、ReplayResult.export_verification/export_meta_path |
| `.codebuddy/skills/gpu-trace-analysis/SKILL.md` | 更新：Known Blind Spots + Pattern 5 + description |
| `.codebuddy/skills/gpu-trace-analysis/references/cli-reference.md` | 更新：replay 章节新增 R11 export 输出字段文档 |
| `LocalDocs/GPUTraceReplayAutomation/README.md` | 更新：R11 标记为 DONE、完成度更新、下一步更新 |
