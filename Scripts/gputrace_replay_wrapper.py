#!/usr/bin/env python3
"""
gputrace_replay_wrapper.py — Python CLI wrapper for gputrace_replay_bridge

R6.2b: 结构化 Python 接口，封装 ObjC bridge 的 5 子命令。
面向自动化流水线，提供参数校验、JSON 解析、错误处理。

用法（作为模块）：
    from gputrace_replay_wrapper import ReplayBridge
    bridge = ReplayBridge()
    result = bridge.replay("/path/to/trace.gputrace", list_resources=True)
    print(result.resource_count)

用法（CLI）：
    python3 gputrace_replay_wrapper.py replay /path/to/trace.gputrace --list-resources
    python3 gputrace_replay_wrapper.py pipeline /path/to/trace.gputrace ./output
    python3 gputrace_replay_wrapper.py shader /path/to/trace.gputrace 248 lib.metallib --verify
    python3 gputrace_replay_wrapper.py config /path/to/trace.gputrace disableOptimizeRestores=0
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Optional


# ---------------------------------------------------------------------------
# R8.1: AIR Metadata Parser — parse LLVM IR (.ll) for buffer/texture arg info
# ---------------------------------------------------------------------------

import re
from functools import lru_cache

# Regex patterns for AIR metadata nodes in .ll files
# Example: !19 = !{i32 0, !"air.buffer", !"air.buffer_size", i32 2176, !"air.location_index", i32 0, i32 1, !"air.read", !"air.struct_type_info", !20, !"air.arg_type_size", i32 336, !"air.arg_type_align_size", i32 8, !"air.arg_type_name", !"UnityPerMaterial_Type", !"air.arg_name", !"UnityPerMaterial"}
_RE_AIR_BUFFER = re.compile(
    r'!\d+\s*=\s*!\{i32\s+\d+,\s*!"air\.buffer"'
    r'.*?"air\.location_index",\s*i32\s+(\d+)'  # group 1: location_index
    r'.*?"air\.arg_type_size",\s*i32\s+(\d+)'   # group 2: arg_type_size
    r'.*?"air\.arg_type_name",\s*!"([^"]*)"'     # group 3: arg_type_name
    r'.*?"air\.arg_name",\s*!"([^"]*)"'          # group 4: arg_name
)

# For textures (no arg_type_size):
# !45 = !{i32 19, !"air.texture", !"air.location_index", i32 1, ... !"air.arg_type_name", !"texture2d<half, sample>", !"air.arg_name", !"_LightIndexMap"}
_RE_AIR_TEXTURE = re.compile(
    r'!\d+\s*=\s*!\{i32\s+\d+,\s*!"air\.texture"'
    r'.*?"air\.location_index",\s*i32\s+(\d+)'  # group 1: location_index
    r'.*?"air\.arg_type_name",\s*!"([^"]*)"'     # group 2: arg_type_name
    r'.*?"air\.arg_name",\s*!"([^"]*)"'          # group 3: arg_name
)

# For samplers:
_RE_AIR_SAMPLER = re.compile(
    r'!\d+\s*=\s*!\{i32\s+\d+,\s*!"air\.sampler"'
    r'.*?"air\.location_index",\s*i32\s+(\d+)'  # group 1: location_index
    r'.*?"air\.arg_type_name",\s*!"([^"]*)"'     # group 2: arg_type_name
    r'.*?"air\.arg_name",\s*!"([^"]*)"'          # group 3: arg_name
)


@dataclass
class AIRBufferArg:
    """Parsed AIR buffer argument metadata."""
    location_index: int
    arg_name: str
    arg_type_name: str
    arg_type_size: int


@dataclass
class AIRTextureArg:
    """Parsed AIR texture argument metadata."""
    location_index: int
    arg_name: str
    arg_type_name: str


@dataclass
class AIRSamplerArg:
    """Parsed AIR sampler argument metadata."""
    location_index: int
    arg_name: str
    arg_type_name: str


@dataclass
class AIRMetadata:
    """Parsed AIR metadata for one shader stage (vertex or fragment)."""
    buffers: dict[int, AIRBufferArg] = field(default_factory=dict)   # location_index → AIRBufferArg
    textures: dict[int, AIRTextureArg] = field(default_factory=dict)  # location_index → AIRTextureArg
    samplers: dict[int, AIRSamplerArg] = field(default_factory=dict)  # location_index → AIRSamplerArg


def parse_air_metadata(ll_path: str | Path) -> AIRMetadata:
    """Parse AIR metadata (buffer/texture/sampler args) from an LLVM IR .ll file.

    Returns an AIRMetadata dataclass with location_index-keyed dicts for each
    resource type.  Gracefully returns empty metadata on IO errors or parse failures.
    """
    result = AIRMetadata()
    try:
        text = Path(ll_path).read_text(errors="replace")
    except (OSError, IOError):
        return result

    for m in _RE_AIR_BUFFER.finditer(text):
        loc_idx = int(m.group(1))
        result.buffers[loc_idx] = AIRBufferArg(
            location_index=loc_idx,
            arg_name=m.group(4),
            arg_type_name=m.group(3),
            arg_type_size=int(m.group(2)),
        )

    for m in _RE_AIR_TEXTURE.finditer(text):
        loc_idx = int(m.group(1))
        result.textures[loc_idx] = AIRTextureArg(
            location_index=loc_idx,
            arg_name=m.group(3),
            arg_type_name=m.group(2),
        )

    for m in _RE_AIR_SAMPLER.finditer(text):
        loc_idx = int(m.group(1))
        result.samplers[loc_idx] = AIRSamplerArg(
            location_index=loc_idx,
            arg_name=m.group(3),
            arg_type_name=m.group(2),
        )

    return result


def compute_size_check(
    bound_buffer_length: Optional[int],
    bound_offset: Optional[int],
    ir_arg_size: Optional[int],
) -> Optional[str]:
    """Compute size_check value per R8.1 spec.

    Returns: 'ok', 'under', 'over', 'cross_section_unknown', or None if inputs insufficient.
    """
    if bound_buffer_length is None or bound_offset is None or ir_arg_size is None:
        return None
    if ir_arg_size <= 0:
        return None
    available = bound_buffer_length - bound_offset
    if available < 0:
        return "under"
    if available < ir_arg_size:
        return "under"
    if available > 4 * ir_arg_size:
        return "over"
    return "ok"


def _is_denormal(v: float) -> bool:
    """Check if a float is denormal (subnormal)."""
    import struct
    try:
        # Use half precision threshold for half values and single for float
        # A float32 is denormal if 0 < |v| < 2^-126 ≈ 1.175e-38
        # A float16 is denormal if 0 < |v| < 2^-14 ≈ 6.1e-5
        # Use the more sensitive half threshold since most values in these
        # shaders are half precision
        return v != 0.0 and abs(v) < 6.1e-5
    except (TypeError, ValueError):
        return False


def compute_value_health_summary(decoded: Any) -> Optional[dict[str, Any]]:
    """R8.2: Scan decoded uniform tree for NaN/inf/denormal values.

    Args:
        decoded: The decoded dict from dump-uniforms output.
                 Shape: {field_name: {offset, data_type, value}} where value
                 can be a scalar, list, or nested dict.

    Returns:
        Health summary dict or None if decoded is empty/None:
        {
            "nan_count": int,
            "inf_count": int,
            "denormal_count": int,
            "fields_with_nan": [str],
            "fields_with_inf": [str],
            "fields_with_denormal": [str]
        }
    """
    if not decoded or not isinstance(decoded, dict):
        return None

    nan_count = 0
    inf_count = 0
    denormal_count = 0
    fields_with_nan: list[str] = []
    fields_with_inf: list[str] = []
    fields_with_denormal: list[str] = []

    def _scan_value(val: Any, field_name: str) -> None:
        nonlocal nan_count, inf_count, denormal_count

        if isinstance(val, str):
            if val == "NaN":
                nan_count += 1
                if field_name not in fields_with_nan:
                    fields_with_nan.append(field_name)
            elif val in ("inf", "-inf", "Infinity", "-Infinity"):
                inf_count += 1
                if field_name not in fields_with_inf:
                    fields_with_inf.append(field_name)
        elif isinstance(val, float):
            import math
            if math.isnan(val):
                nan_count += 1
                if field_name not in fields_with_nan:
                    fields_with_nan.append(field_name)
            elif math.isinf(val):
                inf_count += 1
                if field_name not in fields_with_inf:
                    fields_with_inf.append(field_name)
            elif _is_denormal(val):
                denormal_count += 1
                if field_name not in fields_with_denormal:
                    fields_with_denormal.append(field_name)
        elif isinstance(val, list):
            for item in val:
                _scan_value(item, field_name)

    for field_name, field_data in decoded.items():
        if isinstance(field_data, dict):
            value = field_data.get("value")
            if value is not None:
                _scan_value(value, field_name)
        else:
            _scan_value(field_data, field_name)

    return {
        "nan_count": nan_count,
        "inf_count": inf_count,
        "denormal_count": denormal_count,
        "fields_with_nan": fields_with_nan,
        "fields_with_inf": fields_with_inf,
        "fields_with_denormal": fields_with_denormal,
    }


# ---------------------------------------------------------------------------
# Exit Code Mapping (mirrors bridge EXIT_* constants)
# ---------------------------------------------------------------------------

EXIT_CODE_MAP = {
    0: "OK",
    1: "USAGE_ERROR",
    2: "BAD_INPUT",
    3: "NO_METAL_DEVICE",
    4: "DLOPEN_FAIL",
    5: "SYMBOL_RESOLVE_FAIL",
    6: "APR_FAIL",
    7: "DATASOURCE_FAIL",
    8: "OBJECTMAP_FAIL",
    9: "CONTROLLER_FAIL",
    10: "REPLAY_FAIL",
    11: "SUBCMD_FAIL",
    12: "PLAYTO_OOR",
}


# ---------------------------------------------------------------------------
# Result Dataclasses
# ---------------------------------------------------------------------------

@dataclass
class BridgeError(Exception):
    """Bridge 执行失败时的错误信息"""
    exit_code: int
    exit_name: str
    stderr: str
    command: str
    args: list[str]

    def __str__(self) -> str:
        return f"BridgeError({self.exit_name}, rc={self.exit_code}): {self.stderr.strip()}"


@dataclass
class HelpResult:
    """help 子命令结果"""
    tool: str
    version: str
    commands: list[dict[str, str]]
    raw: dict[str, Any]


@dataclass
class Resource:
    """单个 GPU 资源"""
    id: int
    type: str  # "texture", "buffer", "other"
    # Texture fields
    width: Optional[int] = None
    height: Optional[int] = None
    depth: Optional[int] = None
    pixel_format: Optional[int] = None
    pixel_format_name: Optional[str] = None
    texture_type: Optional[str] = None
    mipmap_level_count: Optional[int] = None
    # Buffer fields
    length: Optional[int] = None
    # Common
    label: Optional[str] = None
    class_name: Optional[str] = None


@dataclass
class ReplayResult:
    """replay 子命令结果"""
    trace_path: str
    device: str
    replay_rc: int
    success: bool
    elapsed_ms: float
    resource_count: int
    playto_index: Optional[int] = None
    resources: list[Resource] = field(default_factory=list)
    export_id: Optional[int] = None
    export_path: Optional[str] = None
    export_bytes: Optional[int] = None
    export_error: Optional[str] = None
    raw: dict[str, Any] = field(default_factory=dict)


@dataclass
class Library:
    """单个 Metal library"""
    key: int
    class_name: str
    function_count: int
    functions: list[str] = field(default_factory=list)
    install_name: Optional[str] = None
    label: Optional[str] = None
    metallib_size: Optional[int] = None
    metallib_magic: Optional[str] = None
    metallib_file: Optional[str] = None
    bitcode_size: Optional[int] = None
    bitcode_magic: Optional[str] = None
    bitcode_file: Optional[str] = None


@dataclass
class ColorAttachment:
    """R7.2: 单个 color attachment 摘要"""
    index: int
    format: str
    pixel_format: int
    write_mask: str
    blending_enabled: bool


@dataclass
class PipelineState:
    """Pipeline state — R7.2: render PSO 现在带 RPS↔shader 关联字段"""
    key: int
    class_name: str
    label: Optional[str] = None
    # R7.2 — RPS↔shader correlation (only present on render_pipeline_states
    # whose descriptor was captured by the bridge swizzle).
    vertex_function_key: Optional[int] = None
    fragment_function_key: Optional[int] = None
    vertex_library_key: Optional[int] = None
    fragment_library_key: Optional[int] = None
    vertex_function_name: Optional[str] = None
    fragment_function_name: Optional[str] = None
    color_attachment_count: Optional[int] = None
    color_attachments: list[ColorAttachment] = field(default_factory=list)
    depth_format: Optional[str] = None
    stencil_format: Optional[str] = None
    raster_sample_count: Optional[int] = None


@dataclass
class Function:
    """Metal function"""
    key: int
    class_name: str
    name: Optional[str] = None
    function_type: Optional[int] = None
    function_type_str: Optional[str] = None


@dataclass
class PipelineResult:
    """pipeline 子命令结果"""
    trace_path: str
    device: str
    output_dir: str
    libraries: list[Library] = field(default_factory=list)
    render_pipeline_states: list[PipelineState] = field(default_factory=list)
    compute_pipeline_states: list[PipelineState] = field(default_factory=list)
    functions: list[Function] = field(default_factory=list)
    libraries_count: int = 0
    metallibs_exported: int = 0
    bitcodes_exported: int = 0
    render_pipeline_states_count: int = 0
    compute_pipeline_states_count: int = 0
    functions_count: int = 0
    # R7.2 — swizzle correlation health
    rps_correlated_count: int = 0
    rps_captured_count: int = 0
    raw: dict[str, Any] = field(default_factory=dict)


@dataclass
class ShaderOfRpsResult:
    """R7.4: shader-of-rps 子命令结果 — RPS 反查 shader"""
    trace_path: str
    rps_key: int
    stage: str
    output_dir: str
    rps_label: Optional[str] = None
    function_key: Optional[int] = None
    function_name: Optional[str] = None
    library_key: Optional[int] = None
    library_metallib_path: Optional[str] = None
    library_metallib_size: Optional[int] = None
    library_air_path: Optional[str] = None
    library_air_size: Optional[int] = None
    cache_key_metallib: Optional[str] = None
    ir_ll_path: Optional[str] = None
    ir_ll_size: Optional[int] = None
    ir_dis_path: Optional[str] = None
    ir_error: Optional[str] = None
    ir_hint: Optional[str] = None
    # R7.7 — IR source provenance + SDI fallback metadata.
    # ir_source: "bitcodeData" (R7.4 legacy AIR path) or "sdi_module_bc"
    # (R7.7 PlayCover ShaderDebugInfo fallback). Absent when no IR was emitted.
    ir_source: Optional[str] = None
    sdi_module_bc_path: Optional[str] = None       # local copy in output_dir
    sdi_module_bc_size: Optional[int] = None
    sdi_bundle_id: Optional[str] = None            # which app the SDI came from
    sdi_module_hash: Optional[str] = None          # sha256(bitcode) folder name
    sdi_source_path: Optional[str] = None          # original SDI path on disk
    error: Optional[str] = None
    hint: Optional[str] = None
    raw: dict[str, Any] = field(default_factory=dict)


@dataclass
class DisasmResult:
    """
    R7.7: ``disasm`` 子命令结果 — 直接 library_key (默认) 或 RPS_key 反汇编。

    library 路径下输出 ``library_metallib_*`` + ``cache_key_metallib`` +
    ``library_air_*`` 或 ``sdi_module_bc_*`` + ``ir_ll_*``，与 ``shader-of-rps``
    共享 R7.7 IR-emission helper (``ir_source`` 区分 bitcodeData / sdi_module_bc)。

    rps 路径下行为等价于 ``shader-of-rps``（bridge 内部直接转发），
    JSON ``command`` 字段为 ``shader-of-rps``；wrapper 把 ``key_type`` 标记为
    ``rps`` 以便区分。
    """
    trace_path: str
    key: int
    key_type: str  # "library" | "rps"
    output_dir: str
    # library 路径独有（rps 路径下从嵌入的 shader_of_rps 读）
    library_key: Optional[int] = None
    library_metallib_path: Optional[str] = None
    library_metallib_size: Optional[int] = None
    cache_key_metallib: Optional[str] = None
    library_air_path: Optional[str] = None
    library_air_size: Optional[int] = None
    # R7.7 SDI fallback fields
    ir_source: Optional[str] = None
    sdi_module_bc_path: Optional[str] = None
    sdi_module_bc_size: Optional[int] = None
    sdi_bundle_id: Optional[str] = None
    sdi_module_hash: Optional[str] = None
    sdi_source_path: Optional[str] = None
    ir_ll_path: Optional[str] = None
    ir_ll_size: Optional[int] = None
    ir_dis_path: Optional[str] = None
    ir_error: Optional[str] = None
    ir_hint: Optional[str] = None
    # rps 路径的嵌入结果（key_type=="rps" 时为 ShaderOfRpsResult）
    shader_of_rps: Optional["ShaderOfRpsResult"] = None
    error: Optional[str] = None
    hint: Optional[str] = None
    warning: Optional[str] = None
    raw: dict[str, Any] = field(default_factory=dict)


@dataclass
class ShaderResult:
    """shader 子命令结果"""
    trace_path: str
    library_key: int
    replacement_done: bool
    original: dict[str, Any] = field(default_factory=dict)
    replacement: dict[str, Any] = field(default_factory=dict)
    verify: Optional[dict[str, Any]] = None
    raw: dict[str, Any] = field(default_factory=dict)


@dataclass
class ConfigResult:
    """config 子命令结果"""
    trace_path: str
    config: dict[str, bool] = field(default_factory=dict)
    play_all_rc: int = 0
    success: bool = False
    elapsed_ms: float = 0.0
    resource_count: int = 0
    raw: dict[str, Any] = field(default_factory=dict)


# ---------------------------------------------------------------------------
# R7.3 — frame-list dataclasses
# ---------------------------------------------------------------------------

@dataclass
class FrameAttachment:
    """R7.3: encoder.color_attachments[i] / depth_attachment / stencil_attachment"""
    texture_id: int
    pixel_format: int
    format: str
    index: Optional[int] = None  # only set on color attachments


# R7.6-A — per-draw binding dataclasses
@dataclass
class FrameBufferBinding:
    """R7.6-A: 单个 vertex/fragment buffer 槽位绑定。

    资源型（普通 ``setVertexBuffer:offset:atIndex:``）填 ``resource_id`` + ``offset``;
    inline 型（``setVertexBytes:length:atIndex:``）填 ``inline_bytes_size``，
    ``resource_id`` 与 ``offset`` 为 None。
    """
    index: int
    resource_id: Optional[int] = None
    offset: Optional[int] = None
    inline_bytes_size: Optional[int] = None


@dataclass
class FrameTextureBinding:
    """R7.6-A: 单个 vertex/fragment texture 槽位绑定。"""
    index: int
    resource_id: int


@dataclass
class FrameSamplerBinding:
    """R7.6-A: 单个 vertex/fragment sampler 槽位绑定。

    sampler 不存在 trace 内部 resource_id（不在 ``objectMap.resources`` 里），
    只输出原始指针字符串供诊断身份匹配使用。
    """
    index: int
    sampler_ptr: str


@dataclass
class FrameStageBindings:
    """R7.6-A: 单个 stage（vertex / fragment）的绑定快照。

    所有列表都是稀疏的 — 仅含被 set* 调用过且非 nil 的槽位。
    """
    buffers: list[FrameBufferBinding] = field(default_factory=list)
    textures: list[FrameTextureBinding] = field(default_factory=list)
    samplers: list[FrameSamplerBinding] = field(default_factory=list)


@dataclass
class FrameDrawBindings:
    """R7.6-A: 一次 draw 的全部 vertex + fragment 绑定。"""
    vertex: FrameStageBindings = field(default_factory=FrameStageBindings)
    fragment: FrameStageBindings = field(default_factory=FrameStageBindings)


@dataclass
class FrameDraw:
    """R7.3: 单个 draw call 记录"""
    draw_index_global: int
    draw_in_encoder: int
    call_index: int
    primitive_type: int
    primitive_type_name: str
    vertex_count: int
    instance_count: int
    indexed: bool
    index_count: Optional[int] = None
    rps_key: Optional[int] = None
    rps_label: Optional[str] = None
    fragment_function_key: Optional[int] = None
    # R7.6-E: function names resolved from pipeline RPS correlation.
    # Populated by find_draws() after joining frame-list × pipeline.
    vertex_function_name: Optional[str] = None
    fragment_function_name: Optional[str] = None
    bindings: Optional[FrameDrawBindings] = None  # R7.6-A; None when --no-bindings


@dataclass
class FrameEncoder:
    """R7.3: 单个 encoder（render / compute / blit）"""
    index: int
    type: str  # 'render' / 'compute' / 'blit'
    label: Optional[str] = None
    first_call_index: int = 0
    last_call_index: int = 0
    draw_count: int = 0
    color_attachment_count: Optional[int] = None
    color_attachments: list[FrameAttachment] = field(default_factory=list)
    depth_attachment: Optional[FrameAttachment] = None
    stencil_attachment: Optional[FrameAttachment] = None
    compute_dispatch_count: Optional[int] = None
    draws: list[FrameDraw] = field(default_factory=list)


@dataclass
class FrameCommandBuffer:
    """R7.3: 单个 command buffer + 其 encoder 列表"""
    index: int
    label: Optional[str] = None
    encoder_count: int = 0
    gpu_start_ms: Optional[float] = None
    gpu_end_ms: Optional[float] = None
    gpu_duration_ms: Optional[float] = None
    encoders: list[FrameEncoder] = field(default_factory=list)


@dataclass
class FrameDrawToRps:
    """R7.3: 扁平化 draw→RPS 映射条目"""
    draw_index_global: int
    encoder_index: int
    draw_in_encoder: int
    call_index: int
    rps_key: Optional[int] = None


@dataclass
class FrameListResult:
    """R7.3: frame-list 子命令结果"""
    trace_path: str
    device: str
    replay_rc: int
    success: bool
    elapsed_ms: float
    total_call_count: int
    with_draws: bool
    with_timing: bool
    with_bindings: bool  # R7.6-A
    command_buffer_count: int
    encoder_count: int
    draw_count: int
    rps_correlated_count: int
    command_buffers: list[FrameCommandBuffer] = field(default_factory=list)
    draw_to_rps_map: list[FrameDrawToRps] = field(default_factory=list)
    raw: dict[str, Any] = field(default_factory=dict)


# ---------------------------------------------------------------------------
# R7.6 子项 E — find-draws (label / shader-name → draw 反查)
# ---------------------------------------------------------------------------

@dataclass
class FindDrawsHit:
    """R7.6-E: 单条 find-draws 命中记录"""
    draw_index: int
    encoder_index: int
    draw_in_encoder: int
    call_index: int
    rps_key: Optional[int] = None
    rps_label: Optional[str] = None
    vertex_function_name: Optional[str] = None
    fragment_function_name: Optional[str] = None


@dataclass
class FindDrawsResult:
    """R7.6-E: find-draws 子命令结果"""
    trace_path: str
    hits: list[FindDrawsHit] = field(default_factory=list)
    hit_count: int = 0
    draw_count: int = 0
    filter_by_label: Optional[str] = None
    filter_by_shader_name: Optional[str] = None
    filter_by_rps_key: Optional[int] = None
    limit: Optional[int] = None
    truncated: bool = False
    # 当 --show-first 联动 shader-of-drawcall 时嵌入完整结果
    show_first_result: Optional["ShaderOfDrawcallResult"] = None
    raw: dict[str, Any] = field(default_factory=dict)


# ---------------------------------------------------------------------------
# R8.1 — draw-info (per-draw merged binding view with IR metadata)
# ---------------------------------------------------------------------------

@dataclass
class DrawInfoResult:
    """R8.1: ``draw-info`` 子命令结果 — 单 draw 的扁平 merged binding view。

    将 frame-list bindings + pipeline RPS 关联 + AIR metadata 自动 join，
    输出 agent 友好的单 draw 视图。每个 buffer/texture 绑定自动带上
    ``ir_arg_name`` / ``ir_arg_type_name`` / ``ir_arg_size`` / ``size_check``。
    """
    trace_path: str
    draw_index: int
    encoder_index: Optional[int] = None
    draw_in_encoder: Optional[int] = None
    call_index: Optional[int] = None
    rps_key: Optional[int] = None
    rps_label: Optional[str] = None
    # Merged bindings with IR metadata injected
    vertex_bindings: Optional[dict[str, Any]] = None
    fragment_bindings: Optional[dict[str, Any]] = None
    # Metadata join health
    metadata_join_ok: bool = False
    metadata_join_failed_count: int = 0
    metadata_join_error: Optional[str] = None
    # Optional uniforms (when with_uniforms=True)
    uniforms: Optional[list["DumpUniformsResult"]] = None
    error: Optional[str] = None
    hint: Optional[str] = None
    raw: dict[str, Any] = field(default_factory=dict)


# ---------------------------------------------------------------------------
# R7.6 子项 C — shader-of-drawcall 薄封装
# ---------------------------------------------------------------------------

@dataclass
class DrawIndexOutOfRange(Exception):
    """R7.6-C: draw_index 超出 frame-list 输出的 draw_to_rps_map 长度"""
    draw_index: int
    draw_count: int
    trace_path: str

    def __str__(self) -> str:
        return (
            f"draw_index_out_of_range: requested draw_index={self.draw_index}, "
            f"trace has draw_count={self.draw_count} ({self.trace_path})"
        )


@dataclass
class ShaderOfDrawcallResult:
    """
    R7.6-C/D: ``shader-of-drawcall`` 结果。

    包装 ``(frame-list draw 元信息, shader-of-rps 反查结果)``，让用户
    一次拿到 "draw N → shader IR" 链路的全部上下文，无需自己拼两次调用。

    R7.6-D 升级为"三件套真合一"：``with_bindings`` 时附 ``bindings`` 字段
    (复用 ``frame_list`` 同一次调用的输出)；``with_uniforms`` 时对该 draw 的
    ``bindings.{stage}.buffers[]`` 中每个 slot 调一次 ``dump-uniforms``，
    组装到 ``uniforms`` 列表。Per-slot 软错误（``reflection_not_captured`` /
    ``binding_not_a_buffer`` / ``offset_out_of_range`` 等）落到该 slot 的
    ``DumpUniformsResult.error`` 字段，不阻塞整体。
    """
    trace_path: str
    draw_index: int
    stage: str
    output_dir: str
    # frame-list 上下文（来自 draw_to_rps_map[draw_index]）
    encoder_index: Optional[int] = None
    draw_in_encoder: Optional[int] = None
    call_index: Optional[int] = None
    rps_key: Optional[int] = None
    rps_label: Optional[str] = None
    # shader-of-rps 透传（嵌入完整结果以便上层消费 .ir_ll_path 等字段）
    shader: Optional[ShaderOfRpsResult] = None
    # R7.6-D — bindings (该 draw 的 vertex/fragment binding 快照；
    # 仅当 with_bindings=True 时填，从同一次 frame_list 复用)
    bindings: Optional[FrameDrawBindings] = None
    # R7.6-D — uniforms (对 bindings.{stage}.buffers[] 每个 slot 跑一次
    # dump-uniforms 的结果列表；仅当 with_uniforms=True 时填。即使 per-slot
    # 失败也会留一项，错误透传到 DumpUniformsResult.error)
    uniforms: Optional[list["DumpUniformsResult"]] = None
    # 链路上的错误（仅在 wrapper 自身产生，例如 rps_key 为 null 而非 OOR 时）
    error: Optional[str] = None
    hint: Optional[str] = None
    raw: dict[str, Any] = field(default_factory=dict)


# ---------------------------------------------------------------------------
# R7.6 子项 B — dump-uniforms (cbuffer 字节按反射树解码)
# ---------------------------------------------------------------------------


@dataclass
class DumpUniformsResult:
    """
    R7.6-B: ``dump-uniforms`` 子命令结果 — 把指定 (RPS, stage, bind_slot) 处
    的 buffer 字节按 ``MTLRenderPipelineReflection`` 的 ``MTLStructType`` 树
    解码成 JSON。

    - ``layout`` 始终输出（来自反射），即使没传 ``buffer_key``；让用户先看到
      shader 期望的 cbuffer 字段名 / 偏移 / 类型。
    - 传 ``buffer_key + offset`` 时，``decoded`` 输出实际数值。``buffer_key``
      通常来自 R7.6-A 的 ``frame-list --with-bindings`` 输出。
    - 反射不可用时返回 ``error="reflection_not_captured"``；可用 ``with_hex=True``
      退化为 hex dump。

    Wrapper 同时支持 ``draw`` 模式（见 :meth:`ReplayBridge.dump_uniforms`）：
    传 ``draw_index`` 时 wrapper 内部先跑 ``frame-list --with-bindings``，
    自动解析出 ``rps_key`` / ``buffer_key`` / ``offset`` 再调 bridge。
    """
    trace_path: str
    rps_key: int
    stage: str
    bind_slot: int
    output_dir: str
    rps_label: Optional[str] = None
    binding_name: Optional[str] = None
    buffer_data_size: Optional[int] = None  # 反射给出的 struct/leaf 总长度
    buffer_data_type: Optional[str] = None  # "struct" / "float4" / ...
    layout: Optional[dict[str, Any]] = None  # MTLStructType 反射树（始终在）
    layout_source: Optional[str] = None      # "metallib_reflection" / "none"
    layout_warning: Optional[str] = None
    # 字节级解码（仅当 buffer_key 传入时存在）
    buffer_key: Optional[int] = None
    buffer_offset: Optional[int] = None
    buffer_length: Optional[int] = None
    buffer_label: Optional[str] = None
    decoded: Optional[Any] = None            # 解码后的字段树（与 layout 同形）
    decoded_ok: Optional[bool] = None
    decoded_bytes: Optional[int] = None
    decoded_skip_reason: Optional[str] = None
    # hex 调试
    hex: Optional[str] = None
    hex_bytes_emitted: Optional[int] = None
    # frame-list 转发上下文（仅在 wrapper 内通过 draw_index 入口时填）
    draw_index: Optional[int] = None
    encoder_index: Optional[int] = None
    draw_in_encoder: Optional[int] = None
    call_index: Optional[int] = None
    # 错误模型
    error: Optional[str] = None
    hint: Optional[str] = None
    rps_captured_count: Optional[int] = None
    binding_type: Optional[int] = None
    # 原 JSON 留作 round-trip
    raw: dict[str, Any] = field(default_factory=dict)


# ---------------------------------------------------------------------------
# Bridge Class
# ---------------------------------------------------------------------------

class ReplayBridge:
    """
    Python wrapper for gputrace_replay_bridge ObjC binary.

    自动定位 bridge binary（同目录下或 PATH 中），
    提供类型安全的调用接口和结构化返回值。
    """

    def __init__(self, bridge_path: Optional[str | Path] = None):
        """
        初始化 bridge wrapper。

        Args:
            bridge_path: bridge binary 路径。如果为 None，自动搜索。
        """
        self._air_metadata_cache: dict[int, AIRMetadata] = {}  # R8.1
        if bridge_path:
            self._binary = Path(bridge_path)
        else:
            self._binary = self._find_bridge()

        if not self._binary.exists():
            raise FileNotFoundError(f"Bridge binary not found: {self._binary}")
        if not os.access(self._binary, os.X_OK):
            raise PermissionError(f"Bridge binary not executable: {self._binary}")

    def _find_bridge(self) -> Path:
        """自动定位 bridge binary"""
        # 1. 同目录
        here = Path(__file__).parent
        candidate = here / "gputrace_replay_bridge"
        if candidate.exists():
            return candidate

        # 2. PATH 搜索
        import shutil
        found = shutil.which("gputrace_replay_bridge")
        if found:
            return Path(found)

        # 3. 默认路径
        return candidate

    def _run(self, args: list[str], timeout: float = 300.0) -> tuple[dict[str, Any], str]:
        """
        执行 bridge 命令并返回解析后的 JSON + stderr。

        Args:
            args: 命令参数列表（不含 binary 路径）
            timeout: 超时秒数（默认 5 分钟）

        Returns:
            (parsed_json_dict, stderr_str)

        Raises:
            BridgeError: bridge 返回非 0 退出码时
            json.JSONDecodeError: stdout 不是有效 JSON
            subprocess.TimeoutExpired: 超时
        """
        cmd = [str(self._binary)] + args
        try:
            proc = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=timeout,
            )
        except subprocess.TimeoutExpired as e:
            raise TimeoutError(
                f"Bridge timed out after {timeout}s: {' '.join(cmd)}"
            ) from e

        if proc.returncode != 0:
            # Exit codes 11 (SUBCMD_FAIL) and 12 (PLAYTO_OOR) are graceful
            # structured failures: the bridge still produced a JSON payload on
            # stdout describing the error. Don't lose that payload by raising —
            # callers can inspect `error`/`hint` fields on the parsed JSON and
            # branch on the exit code via .raw if needed.
            if proc.returncode in (11, 12) and proc.stdout.strip():
                try:
                    return json.loads(proc.stdout.strip()), proc.stderr
                except json.JSONDecodeError:
                    pass
            raise BridgeError(
                exit_code=proc.returncode,
                exit_name=EXIT_CODE_MAP.get(proc.returncode, f"UNKNOWN_{proc.returncode}"),
                stderr=proc.stderr,
                command=args[0] if args else "",
                args=args[1:],
            )

        # 解析 JSON（bridge 每行一个 JSON 对象）
        stdout = proc.stdout.strip()
        if not stdout:
            return {}, proc.stderr

        data = json.loads(stdout)
        return data, proc.stderr

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

    def help(self) -> HelpResult:
        """获取 bridge 帮助信息"""
        data, _ = self._run(["help"])
        return HelpResult(
            tool=data.get("tool", ""),
            version=data.get("version", ""),
            commands=data.get("commands", []),
            raw=data,
        )

    def replay(
        self,
        trace_path: str | Path,
        *,
        playto: Optional[int] = None,
        list_resources: bool = False,
        export_id: Optional[int] = None,
        export_path: Optional[str | Path] = None,
        timeout: float = 300.0,
    ) -> ReplayResult:
        """
        执行 headless replay。

        Args:
            trace_path: .gputrace bundle 路径
            playto: 定向 replay 到指定 call index（None=playAll）
            list_resources: 是否枚举 replay 后的资源
            export_id: 要导出的资源 ID
            export_path: 导出文件路径
            timeout: 超时秒数

        Returns:
            ReplayResult 结构体
        """
        trace_path = self._validate_trace(trace_path)
        args = ["replay", str(trace_path)]

        if playto is not None:
            args += ["--playto", str(playto)]
        if list_resources:
            args.append("--list-resources")
        if export_id is not None and export_path is not None:
            args += ["--export", str(export_id), str(export_path)]

        data, _ = self._run(args, timeout=timeout)

        # Parse resources
        resources = []
        for r in data.get("resources", []):
            resources.append(Resource(
                id=r["id"],
                type=r.get("type", "other"),
                width=r.get("width"),
                height=r.get("height"),
                depth=r.get("depth"),
                pixel_format=r.get("pixelFormat"),
                pixel_format_name=r.get("pixelFormatName"),
                texture_type=r.get("textureType"),
                mipmap_level_count=r.get("mipmapLevelCount"),
                length=r.get("length"),
                label=r.get("label"),
                class_name=r.get("class"),
            ))

        return ReplayResult(
            trace_path=data.get("trace_path", str(trace_path)),
            device=data.get("device", ""),
            replay_rc=data.get("replay_rc", -1),
            success=data.get("success", False),
            elapsed_ms=data.get("elapsed_ms", 0.0),
            resource_count=data.get("resource_count", 0),
            playto_index=data.get("playto_index"),
            resources=resources,
            export_id=data.get("export_id"),
            export_path=data.get("export_path"),
            export_bytes=data.get("export_bytes"),
            export_error=data.get("export_error"),
            raw=data,
        )

    def pipeline(
        self,
        trace_path: str | Path,
        output_dir: Optional[str | Path] = None,
        *,
        timeout: float = 300.0,
    ) -> PipelineResult:
        """
        枚举 libraries + pipeline states，导出 metallib/AIR。

        Args:
            trace_path: .gputrace bundle 路径
            output_dir: 导出目录（None=当前目录）
            timeout: 超时秒数

        Returns:
            PipelineResult 结构体
        """
        trace_path = self._validate_trace(trace_path)
        args = ["pipeline", str(trace_path)]
        if output_dir:
            args.append(str(output_dir))

        data, _ = self._run(args, timeout=timeout)

        # Parse libraries
        libraries = []
        for lib in data.get("libraries", []):
            libraries.append(Library(
                key=lib["key"],
                class_name=lib.get("class", ""),
                function_count=lib.get("function_count", 0),
                functions=lib.get("functions", []),
                install_name=lib.get("installName"),
                label=lib.get("label"),
                metallib_size=lib.get("metallib_size"),
                metallib_magic=lib.get("metallib_magic"),
                metallib_file=lib.get("metallib_file"),
                bitcode_size=lib.get("bitcode_size"),
                bitcode_magic=lib.get("bitcode_magic"),
                bitcode_file=lib.get("bitcode_file"),
            ))

        # Parse pipeline states. Render pipelines now carry R7.2 correlation
        # fields when the bridge swizzle captured the descriptor.
        def _parse_render_ps(ps: dict[str, Any]) -> PipelineState:
            cas = [
                ColorAttachment(
                    index=ca["index"],
                    format=ca.get("format", ""),
                    pixel_format=ca.get("pixelFormat", 0),
                    write_mask=ca.get("writeMask", ""),
                    blending_enabled=ca.get("blendingEnabled", False),
                )
                for ca in ps.get("color_attachments", [])
            ]
            return PipelineState(
                key=ps["key"],
                class_name=ps.get("class", ""),
                label=ps.get("label"),
                vertex_function_key=ps.get("vertex_function_key"),
                fragment_function_key=ps.get("fragment_function_key"),
                vertex_library_key=ps.get("vertex_library_key"),
                fragment_library_key=ps.get("fragment_library_key"),
                vertex_function_name=ps.get("vertex_function_name"),
                fragment_function_name=ps.get("fragment_function_name"),
                color_attachment_count=ps.get("color_attachment_count"),
                color_attachments=cas,
                depth_format=ps.get("depth_format"),
                stencil_format=ps.get("stencil_format"),
                raster_sample_count=ps.get("raster_sample_count"),
            )

        render_ps = [_parse_render_ps(ps) for ps in data.get("render_pipeline_states", [])]
        compute_ps = [
            PipelineState(key=ps["key"], class_name=ps.get("class", ""), label=ps.get("label"))
            for ps in data.get("compute_pipeline_states", [])
        ]

        # Parse functions
        functions = [
            Function(
                key=f["key"],
                class_name=f.get("class", ""),
                name=f.get("name"),
                function_type=f.get("functionType"),
                function_type_str=f.get("functionTypeStr"),
            )
            for f in data.get("functions", [])
        ]

        return PipelineResult(
            trace_path=data.get("trace_path", str(trace_path)),
            device=data.get("device", ""),
            output_dir=data.get("output_dir", str(output_dir or ".")),
            libraries=libraries,
            render_pipeline_states=render_ps,
            compute_pipeline_states=compute_ps,
            functions=functions,
            libraries_count=data.get("libraries_count", 0),
            metallibs_exported=data.get("metallibs_exported", 0),
            bitcodes_exported=data.get("bitcodes_exported", 0),
            render_pipeline_states_count=data.get("render_pipeline_states_count", 0),
            compute_pipeline_states_count=data.get("compute_pipeline_states_count", 0),
            functions_count=data.get("functions_count", 0),
            rps_correlated_count=data.get("rps_correlated_count", 0),
            rps_captured_count=data.get("rps_captured_count", 0),
            raw=data,
        )

    def shader(
        self,
        trace_path: str | Path,
        lib_key: int,
        metallib_path: Optional[str | Path] = None,
        *,
        source_path: Optional[str | Path] = None,
        verify: bool = False,
        timeout: float = 300.0,
    ) -> ShaderResult:
        """
        热替换 library。

        Args:
            trace_path: .gputrace bundle 路径
            lib_key: library key（偶数）
            metallib_path: metallib binary 文件路径
            source_path: MSL source 文件路径（与 metallib_path 二选一）
            verify: 替换后是否 rewind+playAll 验证
            timeout: 超时秒数

        Returns:
            ShaderResult 结构体
        """
        trace_path = self._validate_trace(trace_path)

        if not metallib_path and not source_path:
            raise ValueError("Must provide either metallib_path or source_path")

        args = ["shader", str(trace_path), str(lib_key)]

        if source_path:
            source_p = Path(source_path)
            if not source_p.exists():
                raise FileNotFoundError(f"Source file not found: {source_p}")
            args += ["--source", str(source_p)]
        elif metallib_path:
            metallib_p = Path(metallib_path)
            if not metallib_p.exists():
                raise FileNotFoundError(f"Metallib file not found: {metallib_p}")
            args.append(str(metallib_p))

        if verify:
            args.append("--verify")

        data, _ = self._run(args, timeout=timeout)

        return ShaderResult(
            trace_path=data.get("trace_path", str(trace_path)),
            library_key=data.get("library_key", lib_key),
            replacement_done=data.get("replacement_done", False),
            original=data.get("original", {}),
            replacement=data.get("replacement", {}),
            verify=data.get("verify"),
            raw=data,
        )

    def shader_of_rps(
        self,
        trace_path: str | Path,
        rps_key: int,
        *,
        stage: str = "fragment",
        with_ir: bool = False,
        output_dir: Optional[str | Path] = None,
        timeout: float = 300.0,
    ) -> ShaderOfRpsResult:
        """
        R7.4: 通过 RPS_key 反查 fragment/vertex shader, 可选生成 LLVM IR (.ll)。

        Args:
            trace_path: .gputrace bundle 路径
            rps_key: render pipeline state key (来自 pipeline 子命令)
            stage: 'fragment' (默认) 或 'vertex'
            with_ir: True 时调用 llvm-dis 产出 .ll IR 文件
            output_dir: 导出目录 (None=系统临时目录)
            timeout: 超时秒数

        Returns:
            ShaderOfRpsResult — 失败时 .error 字段填充人类可读原因
        """
        if stage not in ("fragment", "vertex"):
            raise ValueError(f"stage must be 'fragment' or 'vertex', got {stage!r}")
        trace_path = self._validate_trace(trace_path)

        args = ["shader-of-rps", str(trace_path), str(rps_key), "--stage", stage]
        if with_ir:
            args.append("--with-ir")
        if output_dir:
            args += ["--output-dir", str(output_dir)]

        data, _ = self._run(args, timeout=timeout)

        return ShaderOfRpsResult(
            trace_path=data.get("trace_path", str(trace_path)),
            rps_key=data.get("rps_key", rps_key),
            stage=data.get("stage", stage),
            output_dir=data.get("output_dir", str(output_dir or "")),
            rps_label=data.get("rps_label"),
            function_key=data.get("function_key"),
            function_name=data.get("function_name"),
            library_key=data.get("library_key"),
            library_metallib_path=data.get("library_metallib_path"),
            library_metallib_size=data.get("library_metallib_size"),
            library_air_path=data.get("library_air_path"),
            library_air_size=data.get("library_air_size"),
            cache_key_metallib=data.get("cache_key_metallib"),
            ir_ll_path=data.get("ir_ll_path"),
            ir_ll_size=data.get("ir_ll_size"),
            ir_dis_path=data.get("ir_dis_path"),
            ir_error=data.get("ir_error"),
            ir_hint=data.get("ir_hint"),
            # R7.7
            ir_source=data.get("ir_source"),
            sdi_module_bc_path=data.get("sdi_module_bc_path"),
            sdi_module_bc_size=data.get("sdi_module_bc_size"),
            sdi_bundle_id=data.get("sdi_bundle_id"),
            sdi_module_hash=data.get("sdi_module_hash"),
            sdi_source_path=data.get("sdi_source_path"),
            error=data.get("error"),
            hint=data.get("hint"),
            raw=data,
        )

    def disasm(
        self,
        trace_path: str | Path,
        key: int,
        *,
        key_type: str = "library",
        stage: str = "fragment",
        with_ir: bool = False,
        output_dir: Optional[str | Path] = None,
        timeout: float = 300.0,
    ) -> DisasmResult:
        """
        R7.7: 直接 ``library_key`` (默认) 或 ``rps_key`` 反汇编。

        - ``key_type="library"``: 直接拿 ``MTLLibrary`` 的 metallib + cacheKey，
          再走 R7.7 IR-emission helper（``bitcodeData`` 优先 → SDI module.bc fallback）。
          适合在 ``pipeline`` 输出后直接对某个 library 反编译，免去先找 RPS。
        - ``key_type="rps"``: bridge 内部转发到 ``shader-of-rps``，行为等价；
          wrapper 把结果包装到 ``DisasmResult.shader_of_rps`` 内嵌字段。

        Args:
            trace_path: .gputrace bundle 路径
            key: library_key (默认) 或 rps_key
            key_type: 'library' (默认) 或 'rps'
            stage: 仅 key_type='rps' 有效；'fragment' (默认) 或 'vertex'
            with_ir: True 时调用 llvm-dis 产出 .ll IR 文件
            output_dir: 导出目录 (None=系统临时目录)
            timeout: 超时秒数

        Returns:
            DisasmResult — 软错误（如 library_not_found）通过 .error 字段暴露
        """
        if key_type not in ("library", "rps"):
            raise ValueError(f"key_type must be 'library' or 'rps', got {key_type!r}")
        if stage not in ("fragment", "vertex"):
            raise ValueError(f"stage must be 'fragment' or 'vertex', got {stage!r}")
        trace_path = self._validate_trace(trace_path)

        args = ["disasm", str(trace_path), str(key), "--key-type", key_type]
        if key_type == "rps":
            args += ["--stage", stage]
        if with_ir:
            args.append("--with-ir")
        if output_dir:
            args += ["--output-dir", str(output_dir)]

        data, _ = self._run(args, timeout=timeout)

        # rps 路径下 bridge 输出 "command":"shader-of-rps"，字段格式与
        # ShaderOfRpsResult 完全一致。我们包一层 DisasmResult 让上层调用方
        # 不必区分两种 schema。
        if key_type == "rps":
            sor = ShaderOfRpsResult(
                trace_path=data.get("trace_path", str(trace_path)),
                rps_key=data.get("rps_key", key),
                stage=data.get("stage", stage),
                output_dir=data.get("output_dir", str(output_dir or "")),
                rps_label=data.get("rps_label"),
                function_key=data.get("function_key"),
                function_name=data.get("function_name"),
                library_key=data.get("library_key"),
                library_metallib_path=data.get("library_metallib_path"),
                library_metallib_size=data.get("library_metallib_size"),
                library_air_path=data.get("library_air_path"),
                library_air_size=data.get("library_air_size"),
                cache_key_metallib=data.get("cache_key_metallib"),
                ir_ll_path=data.get("ir_ll_path"),
                ir_ll_size=data.get("ir_ll_size"),
                ir_dis_path=data.get("ir_dis_path"),
                ir_error=data.get("ir_error"),
                ir_hint=data.get("ir_hint"),
                ir_source=data.get("ir_source"),
                sdi_module_bc_path=data.get("sdi_module_bc_path"),
                sdi_module_bc_size=data.get("sdi_module_bc_size"),
                sdi_bundle_id=data.get("sdi_bundle_id"),
                sdi_module_hash=data.get("sdi_module_hash"),
                sdi_source_path=data.get("sdi_source_path"),
                error=data.get("error"),
                hint=data.get("hint"),
                raw=data,
            )
            return DisasmResult(
                trace_path=data.get("trace_path", str(trace_path)),
                key=key,
                key_type="rps",
                output_dir=data.get("output_dir", str(output_dir or "")),
                # rps 路径下顶层产物镜像到 DisasmResult 同名字段，方便消费
                library_key=data.get("library_key"),
                library_metallib_path=data.get("library_metallib_path"),
                library_metallib_size=data.get("library_metallib_size"),
                cache_key_metallib=data.get("cache_key_metallib"),
                library_air_path=data.get("library_air_path"),
                library_air_size=data.get("library_air_size"),
                ir_source=data.get("ir_source"),
                sdi_module_bc_path=data.get("sdi_module_bc_path"),
                sdi_module_bc_size=data.get("sdi_module_bc_size"),
                sdi_bundle_id=data.get("sdi_bundle_id"),
                sdi_module_hash=data.get("sdi_module_hash"),
                sdi_source_path=data.get("sdi_source_path"),
                ir_ll_path=data.get("ir_ll_path"),
                ir_ll_size=data.get("ir_ll_size"),
                ir_dis_path=data.get("ir_dis_path"),
                ir_error=data.get("ir_error"),
                ir_hint=data.get("ir_hint"),
                shader_of_rps=sor,
                error=data.get("error"),
                hint=data.get("hint"),
                raw=data,
            )

        # library 路径
        return DisasmResult(
            trace_path=data.get("trace_path", str(trace_path)),
            key=key,
            key_type="library",
            output_dir=data.get("output_dir", str(output_dir or "")),
            library_key=data.get("library_key", key),
            library_metallib_path=data.get("library_metallib_path"),
            library_metallib_size=data.get("library_metallib_size"),
            cache_key_metallib=data.get("cache_key_metallib"),
            library_air_path=data.get("library_air_path"),
            library_air_size=data.get("library_air_size"),
            ir_source=data.get("ir_source"),
            sdi_module_bc_path=data.get("sdi_module_bc_path"),
            sdi_module_bc_size=data.get("sdi_module_bc_size"),
            sdi_bundle_id=data.get("sdi_bundle_id"),
            sdi_module_hash=data.get("sdi_module_hash"),
            sdi_source_path=data.get("sdi_source_path"),
            ir_ll_path=data.get("ir_ll_path"),
            ir_ll_size=data.get("ir_ll_size"),
            ir_dis_path=data.get("ir_dis_path"),
            ir_error=data.get("ir_error"),
            ir_hint=data.get("ir_hint"),
            error=data.get("error"),
            hint=data.get("hint"),
            warning=data.get("warning"),
            raw=data,
        )

    def config(
        self,
        trace_path: str | Path,
        *,
        disable_optimize_restores: Optional[bool] = None,
        force_load_unused_resources: Optional[bool] = None,
        enable_validation: Optional[bool] = None,
        timeout: float = 300.0,
    ) -> ConfigResult:
        """
        配置控制 replay。

        Args:
            trace_path: .gputrace bundle 路径
            disable_optimize_restores: True=跳过 optimizeRestores（默认）
            force_load_unused_resources: True=加载未使用资源（默认）
            enable_validation: True=启用 Metal validation
            timeout: 超时秒数

        Returns:
            ConfigResult 结构体
        """
        trace_path = self._validate_trace(trace_path)
        args = ["config", str(trace_path)]

        if disable_optimize_restores is not None:
            args.append(f"disableOptimizeRestores={'1' if disable_optimize_restores else '0'}")
        if force_load_unused_resources is not None:
            args.append(f"forceLoadUnusedResources={'1' if force_load_unused_resources else '0'}")
        if enable_validation is not None:
            args.append(f"enableValidation={'1' if enable_validation else '0'}")

        data, _ = self._run(args, timeout=timeout)

        return ConfigResult(
            trace_path=data.get("trace_path", str(trace_path)),
            config=data.get("config", {}),
            play_all_rc=data.get("playAll_rc", -1),
            success=data.get("success", False),
            elapsed_ms=data.get("elapsed_ms", 0.0),
            resource_count=data.get("resource_count", 0),
            raw=data,
        )

    def frame_list(
        self,
        trace_path: str | Path,
        *,
        with_draws: bool = True,
        with_timing: bool = False,
        with_bindings: bool = True,
        timeout: float = 300.0,
    ) -> FrameListResult:
        """
        R7.3: 枚举 trace 内 command buffer / encoder / draw 时间序列，
        并产出 ``draw_to_rps_map`` 用于直接喂给 ``shader_of_rps`` 拿 IR。

        Args:
            trace_path: .gputrace bundle 路径
            with_draws: 是否输出 draws 数组与扁平化 draw_to_rps_map（默认 True）
            with_timing: 是否输出 per-cb GPU 时间（默认 False；许多 replay
                内部 cb 不 commit，timing 字段可能为 null）
            with_bindings: R7.6-A — 是否每 draw 输出 vertex/fragment buffer/
                texture/sampler 绑定快照（默认 True）。设 False 时 bridge 端
                跳过 binding swizzle 累积，输出体积约 -75%
            timeout: 超时秒数

        Returns:
            FrameListResult — 包含 command_buffers 树 + 可选 draw_to_rps_map
        """
        trace_path = self._validate_trace(trace_path)
        args = ["frame-list", str(trace_path)]
        # `--with-draws` is the default in the bridge; we only need to pass
        # `--no-draws` when the caller opted out, otherwise `--with-timing`.
        if not with_draws:
            args.append("--no-draws")
        if with_timing:
            args.append("--with-timing")
        if not with_bindings:
            args.append("--no-bindings")

        data, _ = self._run(args, timeout=timeout)

        # ------- nested encoders/draws/attachments -------
        def _parse_attachment(att: dict[str, Any], idx: Optional[int] = None) -> FrameAttachment:
            return FrameAttachment(
                texture_id=att.get("texture_id", 0),
                pixel_format=att.get("pixelFormat", 0),
                format=att.get("format", ""),
                index=idx,
            )

        def _parse_buffer_binding(b: dict[str, Any]) -> FrameBufferBinding:
            # inline-bytes form lacks resource_id/offset; resource form lacks inline_bytes_size
            return FrameBufferBinding(
                index=b.get("index", 0),
                resource_id=b.get("resource_id"),
                offset=b.get("offset"),
                inline_bytes_size=b.get("inline_bytes_size"),
            )

        def _parse_stage_bindings(sb: dict[str, Any]) -> FrameStageBindings:
            return FrameStageBindings(
                buffers=[_parse_buffer_binding(b) for b in sb.get("buffers", [])],
                textures=[
                    FrameTextureBinding(index=t.get("index", 0), resource_id=t.get("resource_id", 0))
                    for t in sb.get("textures", [])
                ],
                samplers=[
                    FrameSamplerBinding(index=s.get("index", 0), sampler_ptr=s.get("sampler_ptr", ""))
                    for s in sb.get("samplers", [])
                ],
            )

        def _parse_draw(d: dict[str, Any]) -> FrameDraw:
            bd = d.get("bindings")
            bindings = None
            if isinstance(bd, dict):
                bindings = FrameDrawBindings(
                    vertex=_parse_stage_bindings(bd.get("vertex", {})),
                    fragment=_parse_stage_bindings(bd.get("fragment", {})),
                )
            return FrameDraw(
                draw_index_global=d.get("draw_index_global", 0),
                draw_in_encoder=d.get("draw_in_encoder", 0),
                call_index=d.get("call_index", 0),
                primitive_type=d.get("primitive_type", 0),
                primitive_type_name=d.get("primitive_type_name", ""),
                vertex_count=d.get("vertex_count", 0),
                instance_count=d.get("instance_count", 0),
                indexed=d.get("indexed", False),
                index_count=d.get("index_count"),
                rps_key=d.get("rps_key"),
                rps_label=d.get("rps_label"),
                fragment_function_key=d.get("fragment_function_key"),
                bindings=bindings,
            )

        def _parse_encoder(e: dict[str, Any]) -> FrameEncoder:
            color_atts = [
                _parse_attachment(a, a.get("index"))
                for a in e.get("color_attachments", [])
            ]
            depth = e.get("depth_attachment")
            stencil = e.get("stencil_attachment")
            return FrameEncoder(
                index=e["index"],
                type=e.get("type", "other"),
                label=e.get("label"),
                first_call_index=e.get("first_call_index", 0),
                last_call_index=e.get("last_call_index", 0),
                draw_count=e.get("draw_count", 0),
                color_attachment_count=e.get("color_attachment_count"),
                color_attachments=color_atts,
                depth_attachment=_parse_attachment(depth) if depth else None,
                stencil_attachment=_parse_attachment(stencil) if stencil else None,
                compute_dispatch_count=e.get("compute_dispatch_count"),
                draws=[_parse_draw(d) for d in e.get("draws", [])],
            )

        cbs = []
        for cb in data.get("command_buffers", []):
            cbs.append(FrameCommandBuffer(
                index=cb["index"],
                label=cb.get("label"),
                encoder_count=cb.get("encoder_count", 0),
                gpu_start_ms=cb.get("gpu_start_ms"),
                gpu_end_ms=cb.get("gpu_end_ms"),
                gpu_duration_ms=cb.get("gpu_duration_ms"),
                encoders=[_parse_encoder(e) for e in cb.get("encoders", [])],
            ))

        d2r = [
            FrameDrawToRps(
                draw_index_global=r.get("draw_index_global", 0),
                encoder_index=r.get("encoder_index", 0),
                draw_in_encoder=r.get("draw_in_encoder", 0),
                call_index=r.get("call_index", 0),
                rps_key=r.get("rps_key"),
            )
            for r in data.get("draw_to_rps_map", [])
        ]

        return FrameListResult(
            trace_path=data.get("trace_path", str(trace_path)),
            device=data.get("device", ""),
            replay_rc=data.get("replay_rc", -1),
            success=data.get("success", False),
            elapsed_ms=data.get("elapsed_ms", 0.0),
            total_call_count=data.get("total_call_count", 0),
            with_draws=data.get("with_draws", with_draws),
            with_timing=data.get("with_timing", with_timing),
            with_bindings=data.get("with_bindings", with_bindings),
            command_buffer_count=data.get("command_buffer_count", 0),
            encoder_count=data.get("encoder_count", 0),
            draw_count=data.get("draw_count", 0),
            rps_correlated_count=data.get("rps_correlated_count", 0),
            command_buffers=cbs,
            draw_to_rps_map=d2r,
            raw=data,
        )

    def shader_of_drawcall(
        self,
        trace_path: str | Path,
        draw_index: int,
        *,
        stage: str = "fragment",
        with_ir: bool = False,
        with_bindings: bool = False,
        with_uniforms: bool = False,
        output_dir: Optional[str | Path] = None,
        timeout: float = 300.0,
    ) -> ShaderOfDrawcallResult:
        """
        R7.6-C/D: ``draw_index`` → shader (metallib / AIR / 可选 LLVM IR
        + bindings + uniforms 三件套) 一行调用。

        薄封装：内部串联 ``frame_list(...)`` 拿 ``draw_to_rps_map[draw_index]``
        + 该 draw 的 vertex/fragment binding 快照，再调 ``shader_of_rps(...)``
        透传 stage / with_ir / output_dir。R7.6-D 进一步联动 ``dump-uniforms``
        把所有 buffer slot 的字节按反射解码，让"知 draw_index"这一用户心智
        入口与 GUI 选 draw 时默认看到的一屏完整上下文（IR + bindings +
        uniforms）对齐。

        Args:
            trace_path: .gputrace bundle 路径
            draw_index: ``draw_to_rps_map`` 中的 ``draw_index_global``
            stage: 'fragment' (默认) 或 'vertex'
            with_ir: True 时调用 llvm-dis 产出 .ll IR 文件
            with_bindings: R7.6-D — True 时附该 draw 的 vertex/fragment
                binding 快照到 ``ShaderOfDrawcallResult.bindings``。复用
                同一次 frame_list 调用的 bindings 字段，无额外子进程开销。
                ``with_uniforms`` 隐含此项。
            with_uniforms: R7.6-D — True 时对 ``bindings.{stage}.buffers[]``
                中每个 slot 调一次 bridge ``dump-uniforms``，结果按 slot 顺序
                写入 ``ShaderOfDrawcallResult.uniforms``。Per-slot 软错误
                (``reflection_not_captured`` / ``binding_not_a_buffer`` /
                ``offset_out_of_range`` 等) 落到该 slot 的 ``error`` 字段，
                不阻塞整体。隐含 ``with_bindings``。
            output_dir: shader-of-rps 输出目录
            timeout: 每个底层子命令的超时秒数

        Returns:
            ShaderOfDrawcallResult — 包含 frame-list 元信息 + shader-of-rps
            嵌入 + 可选 bindings + 可选 uniforms 列表

        Raises:
            DrawIndexOutOfRange: 当 ``draw_index`` 超出 trace 实际 draw 数量
                （含 ``draw_count == 0`` 的 compute-only trace）
            ValueError: stage 非法
            BridgeError: 任一底层子命令以非 11/12 退出码失败
        """
        if stage not in ("fragment", "vertex"):
            raise ValueError(f"stage must be 'fragment' or 'vertex', got {stage!r}")
        if draw_index < 0:
            raise ValueError(f"draw_index must be >= 0, got {draw_index}")

        # with_uniforms 隐含 with_bindings — 后者承载前者所需的 (slot, buffer_key, offset)
        if with_uniforms:
            with_bindings = True

        trace_path = self._validate_trace(trace_path)

        # 1. frame-list 拿 draw→RPS 映射 + 可选 bindings。R7.6-D 收尾：
        #    当 with_bindings=True 时复用同一次调用即可拿到 bindings，
        #    避免 R7.6-C 旧实现那种"明明 frame-list 已含 bindings 字段
        #    却只取了 draw_to_rps_map"的浪费。
        fl = self.frame_list(
            trace_path,
            with_draws=True,
            with_timing=False,
            with_bindings=with_bindings,
            timeout=timeout,
        )

        # 2. 边界检查：包括 compute-only trace (draw_count==0) 与超出范围
        if draw_index >= fl.draw_count or draw_index >= len(fl.draw_to_rps_map):
            raise DrawIndexOutOfRange(
                draw_index=draw_index,
                draw_count=fl.draw_count,
                trace_path=str(trace_path),
            )

        entry = fl.draw_to_rps_map[draw_index]

        # frame-list 已经把 (draw_index, encoder_index, draw_in_encoder, call_index, rps_key) 串好。
        # 进一步从 command_buffers 树里拿 rps_label 与（可选）bindings 作为人类可读上下文。
        rps_label: Optional[str] = None
        draw_bindings: Optional[FrameDrawBindings] = None
        for cb in fl.command_buffers:
            for enc in cb.encoders:
                if enc.index != entry.encoder_index:
                    continue
                for d in enc.draws:
                    if d.draw_index_global == entry.draw_index_global:
                        rps_label = d.rps_label
                        draw_bindings = d.bindings
                        break
                if rps_label is not None or draw_bindings is not None:
                    break
            if rps_label is not None or draw_bindings is not None:
                break

        result = ShaderOfDrawcallResult(
            trace_path=str(trace_path),
            draw_index=draw_index,
            stage=stage,
            output_dir=str(output_dir or ""),
            encoder_index=entry.encoder_index,
            draw_in_encoder=entry.draw_in_encoder,
            call_index=entry.call_index,
            rps_key=entry.rps_key,
            rps_label=rps_label,
            bindings=draw_bindings if with_bindings else None,
        )

        # 3. rps_key 缺失（swizzle gap，不是 OOR）— 透传为软错误，不抛异常
        if entry.rps_key is None:
            result.error = "draw_has_no_rps_key"
            result.hint = (
                "frame-list 在该 draw 上未捕获 RPS pointer; 通常是 swizzle 安装失败"
                "或 trace 走了非公开 API 路径。检查 frame-list 输出 rps_correlated_count 与 stderr。"
            )
            return result

        # 4. shader-of-rps 透传
        sor = self.shader_of_rps(
            trace_path,
            entry.rps_key,
            stage=stage,
            with_ir=with_ir,
            output_dir=output_dir,
            timeout=timeout,
        )
        result.shader = sor
        # 把 shader-of-rps 的结构化错误也提到顶层，方便 CLI exit-code 判断
        if sor.error:
            result.error = sor.error
            result.hint = sor.hint

        # 5. R7.6-D — uniforms 列表：对该 draw 的指定 stage buffers 每 slot
        #    调一次 bridge dump-uniforms。复用上面已解析好的 (rps_key,
        #    buffer_key, offset)，避免内部再跑一次 frame-list。Per-slot
        #    软错误（反射缺失 / 非 buffer / OOR 等）通过 BridgeError 软处理 —
        #    bridge 在 exit 11 时仍输出 JSON，_run() 会把 payload 还原为 data。
        uniforms_list: Optional[list[DumpUniformsResult]] = None
        if with_uniforms and draw_bindings is not None:
            uniforms_list = []
            stage_b = draw_bindings.fragment if stage == "fragment" else draw_bindings.vertex
            for buf in stage_b.buffers:
                # inline-bytes 形式 (setVertexBytes:length:atIndex:) 没有 resource_id —
                # bridge 反射可能仍能给 layout，但没字节可解。遵循 R7.6-D 设计：
                # 调用并把软错误透传 (binding_not_a_buffer / no_buffer_resource_id 等)。
                buffer_key = buf.resource_id
                offset = buf.offset
                try:
                    du = self._dump_uniforms_for_resolved(
                        trace_path=trace_path,
                        rps_key=entry.rps_key,
                        bind_slot=buf.index,
                        stage=stage,
                        buffer_key=buffer_key,
                        offset=offset,
                        draw_index=draw_index,
                        encoder_index=entry.encoder_index,
                        draw_in_encoder=entry.draw_in_encoder,
                        call_index=entry.call_index,
                        output_dir=output_dir,
                        timeout=timeout,
                    )
                except BridgeError as e:
                    # 极少见 — exit 非 11/12 的硬故障。落一个伪结果让上层观察。
                    du = DumpUniformsResult(
                        trace_path=str(trace_path),
                        rps_key=entry.rps_key or -1,
                        stage=stage,
                        bind_slot=buf.index,
                        output_dir=str(output_dir or ""),
                        draw_index=draw_index,
                        encoder_index=entry.encoder_index,
                        draw_in_encoder=entry.draw_in_encoder,
                        call_index=entry.call_index,
                        error=f"bridge_error_exit_{e.exit_code}",
                        hint=e.stderr.strip()[:512] if e.stderr else None,
                    )
                uniforms_list.append(du)
            result.uniforms = uniforms_list

        # raw 留作 round-trip：包含三条命令的原始 JSON（uniforms 仅含 raw 字段，体积可控）
        result.raw = {
            "frame_list_meta": {
                "draw_index_global": entry.draw_index_global,
                "encoder_index": entry.encoder_index,
                "draw_in_encoder": entry.draw_in_encoder,
                "call_index": entry.call_index,
                "rps_key": entry.rps_key,
                "rps_label": rps_label,
                "draw_count": fl.draw_count,
                "rps_correlated_count": fl.rps_correlated_count,
            },
            "shader_of_rps": sor.raw,
        }
        if with_bindings and draw_bindings is not None:
            # 仅落 vertex/fragment 计数，不复制整个 bindings 对象 — wrapper 调用方
            # 用 result.bindings (dataclass) 拿结构化数据。
            result.raw["bindings_summary"] = {
                "vertex": {
                    "buffers": len(draw_bindings.vertex.buffers),
                    "textures": len(draw_bindings.vertex.textures),
                    "samplers": len(draw_bindings.vertex.samplers),
                },
                "fragment": {
                    "buffers": len(draw_bindings.fragment.buffers),
                    "textures": len(draw_bindings.fragment.textures),
                    "samplers": len(draw_bindings.fragment.samplers),
                },
            }
        if uniforms_list is not None:
            result.raw["uniforms"] = [u.raw for u in uniforms_list]
            # R8.2: aggregate value_health_summary across all decoded slots
            agg_nan = 0
            agg_inf = 0
            agg_denormal = 0
            agg_nan_fields: list[str] = []
            agg_inf_fields: list[str] = []
            agg_denormal_fields: list[str] = []
            for u in uniforms_list:
                if u.decoded:
                    vhs = compute_value_health_summary(u.decoded)
                    if vhs:
                        agg_nan += vhs["nan_count"]
                        agg_inf += vhs["inf_count"]
                        agg_denormal += vhs["denormal_count"]
                        prefix = u.binding_name or f"slot_{u.bind_slot}"
                        agg_nan_fields.extend(f"{prefix}.{f}" for f in vhs["fields_with_nan"])
                        agg_inf_fields.extend(f"{prefix}.{f}" for f in vhs["fields_with_inf"])
                        agg_denormal_fields.extend(f"{prefix}.{f}" for f in vhs["fields_with_denormal"])
            if agg_nan + agg_inf + agg_denormal > 0:
                result.raw["value_health_summary"] = {
                    "nan_count": agg_nan,
                    "inf_count": agg_inf,
                    "denormal_count": agg_denormal,
                    "fields_with_nan": agg_nan_fields,
                    "fields_with_inf": agg_inf_fields,
                    "fields_with_denormal": agg_denormal_fields,
                }
        return result

    # --- internal helper ---------------------------------------------------

    def _dump_uniforms_for_resolved(
        self,
        *,
        trace_path: Path,
        rps_key: int,
        bind_slot: int,
        stage: str,
        buffer_key: Optional[int],
        offset: Optional[int],
        draw_index: Optional[int],
        encoder_index: Optional[int],
        draw_in_encoder: Optional[int],
        call_index: Optional[int],
        output_dir: Optional[str | Path],
        timeout: float,
    ) -> DumpUniformsResult:
        """
        R7.6-D 内部 helper：在调用方已经解析出 (rps_key, buffer_key, offset)
        的前提下直接调 bridge ``dump-uniforms`` (target=rps_key)，跳过
        :meth:`dump_uniforms` 本身在 ``target_kind="draw"`` 路径下会重新
        跑一次 ``frame-list`` 的开销。

        与 :meth:`dump_uniforms` 的 ``target_kind="rps"`` 路径行为等价，
        但额外附加 wrapper 已知的 ``draw_index`` / ``encoder_index`` 等
        上下文字段到结果，方便消费方 round-trip。
        """
        args = [
            "dump-uniforms",
            str(trace_path),
            str(rps_key),
            str(bind_slot),
            "--stage", stage,
        ]
        if buffer_key is not None and buffer_key > 0:
            args += ["--buffer-key", str(buffer_key)]
            if offset is not None:
                args += ["--offset", str(offset)]
        if output_dir:
            args += ["--output-dir", str(output_dir)]

        data, _ = self._run(args, timeout=timeout)

        return DumpUniformsResult(
            trace_path=data.get("trace_path", str(trace_path)),
            rps_key=data.get("rps_key", rps_key),
            stage=data.get("stage", stage),
            bind_slot=data.get("bind_slot", bind_slot),
            output_dir=data.get("output_dir", str(output_dir or "")),
            rps_label=data.get("rps_label"),
            binding_name=data.get("binding_name"),
            buffer_data_size=data.get("buffer_data_size"),
            buffer_data_type=data.get("buffer_data_type"),
            layout=data.get("layout"),
            layout_source=data.get("layout_source"),
            layout_warning=data.get("layout_warning"),
            buffer_key=data.get("buffer_key"),
            buffer_offset=data.get("buffer_offset"),
            buffer_length=data.get("buffer_length"),
            buffer_label=data.get("buffer_label"),
            decoded=data.get("decoded"),
            decoded_ok=data.get("decoded_ok"),
            decoded_bytes=data.get("decoded_bytes"),
            decoded_skip_reason=data.get("decoded_skip_reason"),
            hex=data.get("hex"),
            hex_bytes_emitted=data.get("hex_bytes_emitted"),
            draw_index=draw_index,
            encoder_index=encoder_index,
            draw_in_encoder=draw_in_encoder,
            call_index=call_index,
            error=data.get("error"),
            hint=data.get("hint"),
            rps_captured_count=data.get("rps_captured_count"),
            binding_type=data.get("binding_type"),
            raw=data,
        )

    def dump_uniforms(
        self,
        trace_path: str | Path,
        target: int,
        bind_slot: int,
        *,
        target_kind: str = "draw",
        stage: str = "fragment",
        buffer_key: Optional[int] = None,
        offset: Optional[int] = None,
        with_hex: bool = False,
        max_hex_bytes: int = 256,
        output_dir: Optional[str | Path] = None,
        timeout: float = 300.0,
    ) -> DumpUniformsResult:
        """
        R7.6-B: 把指定 (RPS / draw + stage + bind_slot) 处的 buffer 字节按
        ``MTLRenderPipelineReflection`` 解码成 JSON。

        - ``target_kind="draw"`` (默认)：``target`` = ``draw_index``。
          wrapper 内部串联 ``frame_list(--with-bindings)`` 拿
          ``draw_to_rps_map[draw_index]`` + 该 draw 的 buffer 绑定，自动算出
          ``rps_key``、``buffer_key``、``offset``，再调 bridge ``dump-uniforms``。
          这是绝大多数 "看 draw N 时 cbuffer 实际值" 用例的入口。
        - ``target_kind="rps"``：``target`` = ``rps_key``。直接调 bridge。
          需要显式传 ``buffer_key`` / ``offset`` 才能解出字节；不传则只输出
          反射 layout。

        Args:
            trace_path: .gputrace bundle 路径
            target: ``draw_index`` (默认) 或 ``rps_key``
            bind_slot: 反射里 binding 的 ``index`` 字段（NOT 数组下标）
            target_kind: 'draw' (默认) 或 'rps'
            stage: 'fragment' (默认) 或 'vertex'
            buffer_key: 显式 buffer key（仅 ``target_kind=rps`` 时有用，
                draw 模式下从 frame-list 自动解析）
            offset: 显式 offset（同上）
            with_hex: True 时附带 hex dump（裁到 ``max_hex_bytes``）
            max_hex_bytes: hex dump 截断阈值（默认 256）
            output_dir: bridge 临时输出目录
            timeout: 每个底层子命令的超时秒数

        Returns:
            DumpUniformsResult — ``layout`` 始终非空（除非反射缺失），
            ``decoded`` 仅当字节实际可用时非空

        Raises:
            DrawIndexOutOfRange: draw 模式下 draw_index 超出 trace 范围
            ValueError: stage / target_kind / bind_slot 非法
            BridgeError: bridge 以非 11/12 退出码失败
        """
        if stage not in ("fragment", "vertex"):
            raise ValueError(f"stage must be 'fragment' or 'vertex', got {stage!r}")
        if target_kind not in ("draw", "rps"):
            raise ValueError(f"target_kind must be 'draw' or 'rps', got {target_kind!r}")
        if bind_slot < 0:
            raise ValueError(f"bind_slot must be >= 0, got {bind_slot}")
        if target < 0:
            raise ValueError(f"target must be >= 0, got {target}")

        trace_path = self._validate_trace(trace_path)

        # Resolve (rps_key, buffer_key, offset) in draw mode by running frame-list.
        draw_index_for_result: Optional[int] = None
        encoder_index_for_result: Optional[int] = None
        draw_in_encoder_for_result: Optional[int] = None
        call_index_for_result: Optional[int] = None

        if target_kind == "draw":
            fl = self.frame_list(
                trace_path,
                with_draws=True,
                with_bindings=True,
                with_timing=False,
                timeout=timeout,
            )
            if target >= fl.draw_count or target >= len(fl.draw_to_rps_map):
                raise DrawIndexOutOfRange(
                    draw_index=target,
                    draw_count=fl.draw_count,
                    trace_path=str(trace_path),
                )
            entry = fl.draw_to_rps_map[target]
            draw_index_for_result = target
            encoder_index_for_result = entry.encoder_index
            draw_in_encoder_for_result = entry.draw_in_encoder
            call_index_for_result = entry.call_index
            rps_key_resolved = entry.rps_key
            if rps_key_resolved is None:
                # 软错误：透传到结果，不抛
                return DumpUniformsResult(
                    trace_path=str(trace_path),
                    rps_key=-1,
                    stage=stage,
                    bind_slot=bind_slot,
                    output_dir=str(output_dir or ""),
                    draw_index=target,
                    encoder_index=encoder_index_for_result,
                    draw_in_encoder=draw_in_encoder_for_result,
                    call_index=call_index_for_result,
                    error="draw_has_no_rps_key",
                    hint=(
                        "frame-list did not capture a RPS pointer for this draw. "
                        "Inspect 'frame-list rps_correlated_count' and stderr."
                    ),
                )
            # 找到对应 draw 中 (stage, bind_slot) 的 buffer binding
            resolved_buf_key: Optional[int] = None
            resolved_offset: Optional[int] = None
            for cb in fl.command_buffers:
                for enc in cb.encoders:
                    if enc.index != entry.encoder_index:
                        continue
                    for d in enc.draws:
                        if d.draw_index_global != entry.draw_index_global:
                            continue
                        if d.bindings is None:
                            break
                        stage_b = d.bindings.fragment if stage == "fragment" else d.bindings.vertex
                        if stage_b is None:
                            break
                        for b in stage_b.buffers:
                            if b.index == bind_slot:
                                resolved_buf_key = b.resource_id
                                resolved_offset = b.offset
                                break
                        break
                    break
            # 用户显式传入 buffer_key/offset 优先级最高（罕见 override）
            if buffer_key is None:
                buffer_key = resolved_buf_key
            if offset is None:
                offset = resolved_offset
            target_for_bridge = rps_key_resolved
        else:
            # rps mode
            target_for_bridge = target

        # Build bridge args
        args = [
            "dump-uniforms",
            str(trace_path),
            str(target_for_bridge),
            str(bind_slot),
            "--stage", stage,
        ]
        if buffer_key is not None and buffer_key > 0:
            args += ["--buffer-key", str(buffer_key)]
            if offset is not None:
                args += ["--offset", str(offset)]
        if with_hex:
            args.append("--with-hex")
            args += ["--max-hex-bytes", str(max_hex_bytes)]
        if output_dir:
            args += ["--output-dir", str(output_dir)]

        data, _ = self._run(args, timeout=timeout)

        result = DumpUniformsResult(
            trace_path=data.get("trace_path", str(trace_path)),
            rps_key=data.get("rps_key", target_for_bridge),
            stage=data.get("stage", stage),
            bind_slot=data.get("bind_slot", bind_slot),
            output_dir=data.get("output_dir", str(output_dir or "")),
            rps_label=data.get("rps_label"),
            binding_name=data.get("binding_name"),
            buffer_data_size=data.get("buffer_data_size"),
            buffer_data_type=data.get("buffer_data_type"),
            layout=data.get("layout"),
            layout_source=data.get("layout_source"),
            layout_warning=data.get("layout_warning"),
            buffer_key=data.get("buffer_key"),
            buffer_offset=data.get("buffer_offset"),
            buffer_length=data.get("buffer_length"),
            buffer_label=data.get("buffer_label"),
            decoded=data.get("decoded"),
            decoded_ok=data.get("decoded_ok"),
            decoded_bytes=data.get("decoded_bytes"),
            decoded_skip_reason=data.get("decoded_skip_reason"),
            hex=data.get("hex"),
            hex_bytes_emitted=data.get("hex_bytes_emitted"),
            draw_index=draw_index_for_result,
            encoder_index=encoder_index_for_result,
            draw_in_encoder=draw_in_encoder_for_result,
            call_index=call_index_for_result,
            error=data.get("error"),
            hint=data.get("hint"),
            rps_captured_count=data.get("rps_captured_count"),
            binding_type=data.get("binding_type"),
            raw=data,
        )
        return result

    # ------------------------------------------------------------------
    # R7.6-E — find-draws (label / shader-name → draw 反查)
    # ------------------------------------------------------------------

    def find_draws(
        self,
        trace_path: str | Path,
        *,
        by_label: Optional[str] = None,
        by_shader_name: Optional[str] = None,
        by_rps_key: Optional[int] = None,
        limit: int = 50,
        show_first: bool = False,
        show_first_stage: str = "fragment",
        show_first_with_ir: bool = False,
        show_first_with_uniforms: bool = False,
        output_dir: Optional[str | Path] = None,
        timeout: float = 300.0,
    ) -> FindDrawsResult:
        """
        R7.6-E: 按 RPS label / shader function name / rps_key 反查 draw 列表。

        消除"用户在 Xcode GUI 看到 shader 名但 CLI 要 draw_index"的入口阻抗。
        Bridge 零变更：内部串联 ``frame-list`` + ``pipeline``，在 wrapper 做
        内存 join 与过滤。

        Args:
            trace_path: .gputrace bundle 路径
            by_label: 按 RPS label 模糊匹配（大小写不敏感子串）
            by_shader_name: 按 vertex/fragment function name 模糊匹配
                （大小写不敏感子串）
            by_rps_key: 按 RPS key 精确匹配
            limit: 最大返回命中数（默认 50）
            show_first: True 时自动对第一条命中跑
                ``shader-of-drawcall --with-ir --with-uniforms``
            show_first_stage: ``show_first`` 联动时的 stage（默认 fragment）
            show_first_with_ir: ``show_first`` 联动时是否产出 IR
            show_first_with_uniforms: ``show_first`` 联动时是否产出 uniforms
            output_dir: ``show_first`` 联动时传给 shader-of-drawcall
            timeout: 每个底层子命令的超时秒数

        Returns:
            FindDrawsResult — 含命中列表 + 可选 show_first_result

        Raises:
            ValueError: 三个过滤条件都为 None 时
        """
        if by_label is None and by_shader_name is None and by_rps_key is None:
            raise ValueError(
                "At least one filter must be specified: "
                "--by-label, --by-shader-name, or --by-rps-key"
            )

        trace_path = self._validate_trace(trace_path)

        # 1. frame-list 拿 draw→rps 映射（不含 bindings 以减少输出体积）
        fl = self.frame_list(
            trace_path,
            with_draws=True,
            with_timing=False,
            with_bindings=False,
            timeout=timeout,
        )

        # 2. 如果需要 --by-shader-name，调 pipeline 拿 rps_key → function_name 映射
        rps_fn_map: dict[int, tuple[Optional[str], Optional[str]]] = {}
        if by_shader_name is not None:
            pl = self.pipeline(trace_path, timeout=timeout)
            for rps in pl.render_pipeline_states:
                rps_fn_map[rps.key] = (rps.vertex_function_name, rps.fragment_function_name)

        # 3. 收集所有 draw 并做过滤
        hits: list[FindDrawsHit] = []
        label_lower = by_label.lower() if by_label else None
        name_lower = by_shader_name.lower() if by_shader_name else None

        for cb in fl.command_buffers:
            for enc in cb.encoders:
                for d in enc.draws:
                    # 获取该 draw 的 function names（如果已查）
                    vfn: Optional[str] = None
                    ffn: Optional[str] = None
                    if d.rps_key is not None and d.rps_key in rps_fn_map:
                        vfn, ffn = rps_fn_map[d.rps_key]

                    # 过滤逻辑（所有提供的过滤条件做 AND）
                    match = True

                    if by_rps_key is not None:
                        if d.rps_key != by_rps_key:
                            match = False

                    if match and label_lower is not None:
                        dl = (d.rps_label or "").lower()
                        if label_lower not in dl:
                            match = False

                    if match and name_lower is not None:
                        vn = (vfn or "").lower()
                        fn = (ffn or "").lower()
                        if name_lower not in vn and name_lower not in fn:
                            match = False

                    if match:
                        hits.append(FindDrawsHit(
                            draw_index=d.draw_index_global,
                            encoder_index=enc.index,
                            draw_in_encoder=d.draw_in_encoder,
                            call_index=d.call_index,
                            rps_key=d.rps_key,
                            rps_label=d.rps_label,
                            vertex_function_name=vfn,
                            fragment_function_name=ffn,
                        ))

        truncated = len(hits) > limit
        hits_limited = hits[:limit]

        result = FindDrawsResult(
            trace_path=str(trace_path),
            hits=hits_limited,
            hit_count=len(hits),
            draw_count=fl.draw_count,
            filter_by_label=by_label,
            filter_by_shader_name=by_shader_name,
            filter_by_rps_key=by_rps_key,
            limit=limit,
            truncated=truncated,
        )

        # 4. --show-first 联动
        if show_first and hits_limited:
            first = hits_limited[0]
            sod = self.shader_of_drawcall(
                trace_path,
                first.draw_index,
                stage=show_first_stage,
                with_ir=show_first_with_ir,
                with_bindings=True,
                with_uniforms=show_first_with_uniforms,
                output_dir=output_dir,
                timeout=timeout,
            )
            result.show_first_result = sod

        # raw JSON
        result.raw = {
            "command": "find-draws",
            "trace_path": str(trace_path),
            "filter": {
                "by_label": by_label,
                "by_shader_name": by_shader_name,
                "by_rps_key": by_rps_key,
            },
            "hit_count": len(hits),
            "draw_count": fl.draw_count,
            "limit": limit,
            "truncated": truncated,
            "hits": [
                {
                    "draw_index": h.draw_index,
                    "encoder_index": h.encoder_index,
                    "draw_in_encoder": h.draw_in_encoder,
                    "call_index": h.call_index,
                    "rps_key": h.rps_key,
                    "rps_label": h.rps_label,
                    "vertex_function_name": h.vertex_function_name,
                    "fragment_function_name": h.fragment_function_name,
                }
                for h in hits_limited
            ],
        }
        return result

    # ------------------------------------------------------------------
    # R8.1 — draw-info (per-draw merged binding view with IR metadata)
    # ------------------------------------------------------------------

    def draw_info(
        self,
        trace_path: str | Path,
        draw_index: int,
        *,
        with_uniforms: bool = False,
        output_dir: Optional[str | Path] = None,
        timeout: float = 300.0,
    ) -> DrawInfoResult:
        """
        R8.1: Per-draw merged binding view — 单 draw 的扁平视图，binding 表自动
        注入 ``ir_arg_name`` / ``ir_arg_type_name`` / ``ir_arg_size`` / ``size_check``。

        内部链路：
        1. ``frame-list --with-bindings`` → 目标 draw 的 bindings + rps_key
        2. ``pipeline`` → rps_key 的 vertex/fragment library_key
        3. ``disasm --with-ir`` → library 的 .ll IR 文件
        4. ``parse_air_metadata(.ll)`` → slot → arg_name/type_name/size 映射
        5. 注入到 bindings 各 slot → 输出扁平 JSON

        Args:
            trace_path: .gputrace bundle 路径
            draw_index: ``draw_to_rps_map`` 中的 ``draw_index_global``
            with_uniforms: True 时附带 per-slot uniform decode
            output_dir: IR 输出目录
            timeout: 超时秒数

        Returns:
            DrawInfoResult — 含 vertex_bindings + fragment_bindings (已注入 IR metadata)
        """
        if draw_index < 0:
            raise ValueError(f"draw_index must be >= 0, got {draw_index}")
        trace_path = self._validate_trace(trace_path)

        out_dir = str(output_dir) if output_dir else None

        # 1. frame-list 拿 bindings + rps_key
        fl = self.frame_list(
            trace_path,
            with_draws=True,
            with_bindings=True,
            with_timing=False,
            timeout=timeout,
        )

        if draw_index >= fl.draw_count or draw_index >= len(fl.draw_to_rps_map):
            raise DrawIndexOutOfRange(
                draw_index=draw_index,
                draw_count=fl.draw_count,
                trace_path=str(trace_path),
            )

        entry = fl.draw_to_rps_map[draw_index]

        # 找到 draw 的 bindings 和 rps_label
        rps_label: Optional[str] = None
        draw_bindings: Optional[FrameDrawBindings] = None
        for cb in fl.command_buffers:
            for enc in cb.encoders:
                if enc.index != entry.encoder_index:
                    continue
                for d in enc.draws:
                    if d.draw_index_global == entry.draw_index_global:
                        rps_label = d.rps_label
                        draw_bindings = d.bindings
                        break
                break
            if draw_bindings is not None:
                break

        result = DrawInfoResult(
            trace_path=str(trace_path),
            draw_index=draw_index,
            encoder_index=entry.encoder_index,
            draw_in_encoder=entry.draw_in_encoder,
            call_index=entry.call_index,
            rps_key=entry.rps_key,
            rps_label=rps_label,
        )

        if entry.rps_key is None:
            result.error = "draw_has_no_rps_key"
            result.hint = "frame-list did not capture a RPS pointer for this draw."
            return result

        if draw_bindings is None:
            result.error = "bindings_not_captured"
            result.hint = "frame-list did not capture bindings for this draw."
            return result

        # 2. pipeline 拿 rps_key → library_key 映射
        pl = self.pipeline(trace_path, output_dir=out_dir, timeout=timeout)

        # 找到目标 RPS 的 vertex/fragment library key
        vertex_lib_key: Optional[int] = None
        fragment_lib_key: Optional[int] = None
        for rps in pl.render_pipeline_states:
            if rps.key == entry.rps_key:
                vertex_lib_key = rps.vertex_library_key
                fragment_lib_key = rps.fragment_library_key
                break

        # 3. 获取 vertex/fragment AIR metadata
        v_meta = self._get_air_metadata_for_library(
            trace_path, vertex_lib_key, output_dir=out_dir, timeout=timeout
        ) if vertex_lib_key is not None else AIRMetadata()

        f_meta = self._get_air_metadata_for_library(
            trace_path, fragment_lib_key, output_dir=out_dir, timeout=timeout
        ) if fragment_lib_key is not None else AIRMetadata()

        # 4. 获取 resource 信息（buffer labels + lengths）用于 size_check
        resource_info = self._build_resource_info(fl)

        # 5. 注入 metadata 到 bindings
        v_bindings_enriched, v_failed = self._enrich_stage_bindings(
            draw_bindings.vertex, v_meta, resource_info
        )
        f_bindings_enriched, f_failed = self._enrich_stage_bindings(
            draw_bindings.fragment, f_meta, resource_info
        )

        result.vertex_bindings = v_bindings_enriched
        result.fragment_bindings = f_bindings_enriched
        result.metadata_join_failed_count = v_failed + f_failed
        result.metadata_join_ok = (v_failed + f_failed) == 0

        if v_failed + f_failed > 0:
            result.metadata_join_error = (
                f"{v_failed + f_failed} bindings could not be matched to IR metadata "
                f"(vertex: {v_failed}, fragment: {f_failed})"
            )

        # 6. 可选 uniforms
        uniforms_list: Optional[list[DumpUniformsResult]] = None
        if with_uniforms:
            uniforms_list = []
            for buf in draw_bindings.fragment.buffers:
                try:
                    du = self._dump_uniforms_for_resolved(
                        trace_path=trace_path,
                        rps_key=entry.rps_key,
                        bind_slot=buf.index,
                        stage="fragment",
                        buffer_key=buf.resource_id,
                        offset=buf.offset,
                        draw_index=draw_index,
                        encoder_index=entry.encoder_index,
                        draw_in_encoder=entry.draw_in_encoder,
                        call_index=entry.call_index,
                        output_dir=output_dir,
                        timeout=timeout,
                    )
                except BridgeError as e:
                    du = DumpUniformsResult(
                        trace_path=str(trace_path),
                        rps_key=entry.rps_key or -1,
                        stage="fragment",
                        bind_slot=buf.index,
                        output_dir=str(output_dir or ""),
                        draw_index=draw_index,
                        encoder_index=entry.encoder_index,
                        draw_in_encoder=entry.draw_in_encoder,
                        call_index=entry.call_index,
                        error=f"bridge_error_exit_{e.exit_code}",
                        hint=e.stderr.strip()[:512] if e.stderr else None,
                    )
                uniforms_list.append(du)
            result.uniforms = uniforms_list

        # raw JSON
        result.raw = {
            "command": "draw-info",
            "trace_path": str(trace_path),
            "draw_index": draw_index,
            "encoder_index": entry.encoder_index,
            "draw_in_encoder": entry.draw_in_encoder,
            "call_index": entry.call_index,
            "rps_key": entry.rps_key,
            "rps_label": rps_label,
            "vertex_bindings": v_bindings_enriched,
            "fragment_bindings": f_bindings_enriched,
            "metadata_join_ok": result.metadata_join_ok,
            "metadata_join_failed_count": result.metadata_join_failed_count,
        }
        if result.metadata_join_error:
            result.raw["metadata_join_error"] = result.metadata_join_error
        if uniforms_list is not None:
            result.raw["with_uniforms"] = True
            result.raw["uniforms"] = [u.raw for u in uniforms_list]
            # R8.2: aggregate value_health_summary across all decoded slots
            agg_nan = 0
            agg_inf = 0
            agg_denormal = 0
            agg_nan_fields: list[str] = []
            agg_inf_fields: list[str] = []
            agg_denormal_fields: list[str] = []
            for u in uniforms_list:
                if u.decoded:
                    vhs = compute_value_health_summary(u.decoded)
                    if vhs:
                        agg_nan += vhs["nan_count"]
                        agg_inf += vhs["inf_count"]
                        agg_denormal += vhs["denormal_count"]
                        prefix = u.binding_name or f"slot_{u.bind_slot}"
                        agg_nan_fields.extend(f"{prefix}.{f}" for f in vhs["fields_with_nan"])
                        agg_inf_fields.extend(f"{prefix}.{f}" for f in vhs["fields_with_inf"])
                        agg_denormal_fields.extend(f"{prefix}.{f}" for f in vhs["fields_with_denormal"])
            if agg_nan + agg_inf + agg_denormal > 0:
                result.raw["value_health_summary"] = {
                    "nan_count": agg_nan,
                    "inf_count": agg_inf,
                    "denormal_count": agg_denormal,
                    "fields_with_nan": agg_nan_fields,
                    "fields_with_inf": agg_inf_fields,
                    "fields_with_denormal": agg_denormal_fields,
                }
        if result.error:
            result.raw["error"] = result.error
            result.raw["hint"] = result.hint
        return result

    # ------------------------------------------------------------------
    # R8.1 — Internal helpers for metadata enrichment
    # ------------------------------------------------------------------

    def _get_air_metadata_for_library(
        self,
        trace_path: Path,
        library_key: int,
        *,
        output_dir: Optional[str] = None,
        timeout: float = 300.0,
    ) -> AIRMetadata:
        """Get AIR metadata for a library (with caching).

        Calls ``disasm --with-ir`` to produce the .ll file, then parses it.
        """
        if library_key in self._air_metadata_cache:
            return self._air_metadata_cache[library_key]

        try:
            dr = self.disasm(
                trace_path,
                library_key,
                key_type="library",
                with_ir=True,
                output_dir=output_dir,
                timeout=timeout,
            )
            if dr.ir_ll_path:
                meta = parse_air_metadata(dr.ir_ll_path)
            else:
                meta = AIRMetadata()
        except (BridgeError, Exception):
            meta = AIRMetadata()

        self._air_metadata_cache[library_key] = meta
        return meta

    def _build_resource_info(self, fl: FrameListResult) -> dict[int, dict[str, Any]]:
        """Build resource_id → {label, length} from replay result (frame-list raw).

        frame-list raw JSON may contain a 'resources' section from the bridge
        if --list-resources was used, but typically we don't have it. Instead
        we'll gather what we can from the bindings themselves (buffer_length etc.
        are available in dump-uniforms, not in frame-list). For now we return
        an empty dict — size_check will use the binding-level info when available
        from pipeline/replay calls. The actual buffer_length per resource is
        only fully resolved when combined with dump-uniforms (R7.6-B) or a
        dedicated replay --list-resources call.

        For R8.1 MVP, size_check uses buffer info from dump-uniforms output
        (buffer_length field). The draw-info path adds size_check to the
        enriched binding dict when ir_arg_size is known and buffer_length is
        available from the replay resource list or subsequent dump-uniforms.
        """
        # Placeholder — fill from replay resource list in future enhancement
        return {}

    def _enrich_stage_bindings(
        self,
        stage_bindings: FrameStageBindings,
        metadata: AIRMetadata,
        resource_info: dict[int, dict[str, Any]],
    ) -> tuple[dict[str, Any], int]:
        """Enrich a stage's bindings with AIR metadata.

        Returns (enriched_dict, failed_count) where enriched_dict follows the
        R8.1 target schema and failed_count is the number of bindings that
        couldn't be matched to IR metadata.
        """
        failed = 0

        enriched_buffers = []
        for buf in stage_bindings.buffers:
            entry: dict[str, Any] = {
                "index": buf.index,
            }
            if buf.resource_id is not None:
                entry["resource_id"] = buf.resource_id
            if buf.offset is not None:
                entry["offset"] = buf.offset
            if buf.inline_bytes_size is not None:
                entry["inline_bytes_size"] = buf.inline_bytes_size

            # Inject resource info (label, length) if available
            if buf.resource_id is not None and buf.resource_id in resource_info:
                ri = resource_info[buf.resource_id]
                if "label" in ri:
                    entry["buffer_label"] = ri["label"]
                if "length" in ri:
                    entry["buffer_length"] = ri["length"]

            # Inject IR metadata
            air_buf = metadata.buffers.get(buf.index)
            if air_buf is not None:
                entry["ir_arg_name"] = air_buf.arg_name
                entry["ir_arg_type_name"] = air_buf.arg_type_name
                entry["ir_arg_size"] = air_buf.arg_type_size
                # size_check (requires buffer_length from resource_info)
                buf_len = entry.get("buffer_length")
                if buf_len is not None:
                    sc = compute_size_check(buf_len, buf.offset, air_buf.arg_type_size)
                    if sc:
                        entry["size_check"] = sc
            else:
                failed += 1

            enriched_buffers.append(entry)

        enriched_textures = []
        for tex in stage_bindings.textures:
            entry = {
                "index": tex.index,
                "resource_id": tex.resource_id,
            }
            # Inject resource info
            if tex.resource_id in resource_info:
                ri = resource_info[tex.resource_id]
                if "label" in ri:
                    entry["texture_label"] = ri["label"]

            # Inject IR metadata
            air_tex = metadata.textures.get(tex.index)
            if air_tex is not None:
                entry["ir_arg_name"] = air_tex.arg_name
                entry["ir_arg_type_name"] = air_tex.arg_type_name
            else:
                failed += 1

            enriched_textures.append(entry)

        enriched_samplers = []
        for smp in stage_bindings.samplers:
            entry = {
                "index": smp.index,
                "sampler_ptr": smp.sampler_ptr,
            }
            air_smp = metadata.samplers.get(smp.index)
            if air_smp is not None:
                entry["ir_arg_name"] = air_smp.arg_name
                entry["ir_arg_type_name"] = air_smp.arg_type_name

            enriched_samplers.append(entry)

        return {
            "buffers": enriched_buffers,
            "textures": enriched_textures,
            "samplers": enriched_samplers,
        }, failed

    # ------------------------------------------------------------------
    # Validation Helpers
    # ------------------------------------------------------------------

    @staticmethod
    def _validate_trace(trace_path: str | Path) -> Path:
        """验证 .gputrace 路径存在且为目录"""
        p = Path(trace_path)
        if not p.exists():
            raise FileNotFoundError(f".gputrace not found: {p}")
        if not p.is_dir():
            raise ValueError(f".gputrace must be a directory bundle: {p}")
        if not p.suffix == ".gputrace":
            raise ValueError(f"Path does not end with .gputrace: {p}")
        return p


# ---------------------------------------------------------------------------
# CLI Entry Point
# ---------------------------------------------------------------------------

def _cli_main():
    """命令行入口"""
    # Common parent parser for shared options
    parent = argparse.ArgumentParser(add_help=False)
    parent.add_argument("--bridge", help="Path to bridge binary", default=None)
    parent.add_argument("--timeout", type=float, default=300.0, help="Timeout in seconds")
    parent.add_argument("--pretty", "-p", action="store_true", help="Pretty-print JSON output")

    parser = argparse.ArgumentParser(
        prog="gputrace_replay_wrapper",
        description="Python CLI wrapper for gputrace_replay_bridge",
        parents=[parent],
    )

    subparsers = parser.add_subparsers(dest="command")

    # help
    subparsers.add_parser("help", parents=[parent], help="Show bridge help")

    # replay
    p_replay = subparsers.add_parser("replay", parents=[parent], help="Headless replay")
    p_replay.add_argument("trace", help="Path to .gputrace bundle")
    p_replay.add_argument("--playto", type=int, default=None, help="Play to call index")
    p_replay.add_argument("--list-resources", action="store_true", help="List resources")
    p_replay.add_argument("--export", nargs=2, metavar=("ID", "PATH"), help="Export resource")

    # pipeline
    p_pipeline = subparsers.add_parser("pipeline", parents=[parent], help="Library enumeration + export")
    p_pipeline.add_argument("trace", help="Path to .gputrace bundle")
    p_pipeline.add_argument("output_dir", nargs="?", default=None, help="Output directory")

    # shader
    p_shader = subparsers.add_parser("shader", parents=[parent], help="Shader hot-replace")
    p_shader.add_argument("trace", help="Path to .gputrace bundle")
    p_shader.add_argument("lib_key", type=int, help="Library key")
    p_shader.add_argument("metallib", nargs="?", default=None, help="Metallib file path")
    p_shader.add_argument("--source", default=None, help="MSL source file path")
    p_shader.add_argument("--verify", action="store_true", help="Verify after replace")

    # shader-of-rps (R7.4)
    p_sor = subparsers.add_parser("shader-of-rps", parents=[parent],
                                   help="Reverse-lookup shader by RPS key (optionally produce LLVM IR)")
    p_sor.add_argument("trace", help="Path to .gputrace bundle")
    p_sor.add_argument("rps_key", type=int, help="Render pipeline state key (from `pipeline` output)")
    p_sor.add_argument("--stage", choices=["fragment", "vertex"], default="fragment",
                       help="Which stage to look up (default: fragment)")
    p_sor.add_argument("--with-ir", action="store_true",
                       help="Run llvm-dis on the AIR bitcode and emit a .ll file")
    p_sor.add_argument("--output-dir", default=None,
                       help="Output directory (default: system tmp)")

    # frame-list (R7.3 + R7.6-A)
    p_fl = subparsers.add_parser("frame-list", parents=[parent],
                                  help="Enumerate cb/encoder/draw timeline + draw_to_rps_map (R7.3) + per-draw bindings (R7.6-A)")
    p_fl.add_argument("trace", help="Path to .gputrace bundle")
    p_fl.add_argument("--no-draws", action="store_true",
                      help="Suppress per-draw records and draw_to_rps_map")
    p_fl.add_argument("--with-timing", action="store_true",
                      help="Include per-cb GPU start/end/duration (often null for replay-internal CBs)")
    p_fl.add_argument("--no-bindings", action="store_true",
                      help="R7.6-A: suppress per-draw vertex/fragment binding tables (default ON; output ~75%% smaller without)")

    # shader-of-drawcall (R7.6 子项 C/D — 薄封装 + 三件套合一)
    p_sod = subparsers.add_parser(
        "shader-of-drawcall", parents=[parent],
        help=("Reverse-lookup shader by draw_index (frame-list → shader-of-rps thin wrapper, R7.6-C); "
              "with --with-bindings / --with-uniforms for full draw-context (IR + bindings + uniforms, R7.6-D)"),
    )
    p_sod.add_argument("trace", help="Path to .gputrace bundle")
    p_sod.add_argument("draw_index", type=int,
                       help="Global draw index from frame-list draw_to_rps_map[]")
    p_sod.add_argument("--stage", choices=["fragment", "vertex"], default="fragment",
                       help="Which stage to look up (default: fragment)")
    p_sod.add_argument("--with-ir", action="store_true",
                       help="Run llvm-dis on the AIR bitcode and emit a .ll file")
    p_sod.add_argument("--with-bindings", action="store_true",
                       help="R7.6-D: attach this draw's vertex/fragment binding snapshot "
                            "(reuses the same frame-list call, no extra cost). Implied by --with-uniforms.")
    p_sod.add_argument("--with-uniforms", action="store_true",
                       help="R7.6-D: for each buffer slot of <stage>, run dump-uniforms and "
                            "decode the bytes via captured reflection. Implies --with-bindings.")
    p_sod.add_argument("--output-dir", default=None,
                       help="Output directory passed through to shader-of-rps (default: system tmp)")

    # disasm (R7.7)
    p_disasm = subparsers.add_parser(
        "disasm", parents=[parent],
        help="Direct library_key (default) or rps_key disassembly + SDI module.bc fallback (R7.7)",
    )
    p_disasm.add_argument("trace", help="Path to .gputrace bundle")
    p_disasm.add_argument("key", type=int,
                          help="library_key (default) or rps_key (with --key-type rps)")
    p_disasm.add_argument("--key-type", choices=["library", "rps"], default="library",
                          help="Interpret <key> as library_key (default) or rps_key")
    p_disasm.add_argument("--stage", choices=["fragment", "vertex"], default="fragment",
                          help="Only used when --key-type=rps (default: fragment)")
    p_disasm.add_argument("--with-ir", action="store_true",
                          help="Run llvm-dis and emit a .ll file (uses bitcodeData first, "
                               "falls back to PlayCover SDI module.bc — raises hit-rate ~3%% → ~100%% on LYSK)")
    p_disasm.add_argument("--output-dir", default=None,
                          help="Output directory (default: system tmp)")

    # dump-uniforms (R7.6-B)
    p_du = subparsers.add_parser(
        "dump-uniforms", parents=[parent],
        help="Decode a buffer binding's bytes via captured MTLRenderPipelineReflection (R7.6-B)",
    )
    p_du.add_argument("trace", help="Path to .gputrace bundle")
    p_du.add_argument("target", type=int,
                      help="draw_index (default --target-kind draw) or rps_key (--target-kind rps)")
    p_du.add_argument("bind_slot", type=int,
                      help="MTLBinding.index of the buffer binding to decode")
    p_du.add_argument("--target-kind", choices=["draw", "rps"], default="draw",
                      help="Interpret <target> as draw_index (default) or rps_key")
    p_du.add_argument("--stage", choices=["fragment", "vertex"], default="fragment",
                      help="Pipeline stage (default: fragment)")
    p_du.add_argument("--buffer-key", type=int, default=None,
                      help="Override the resolved buffer key (only meaningful in --target-kind=rps; "
                           "in draw mode it's auto-resolved from frame-list bindings)")
    p_du.add_argument("--offset", type=int, default=None,
                      help="Override the buffer offset (see --buffer-key)")
    p_du.add_argument("--with-hex", action="store_true",
                      help="Also emit a hex dump of the buffer bytes")
    p_du.add_argument("--max-hex-bytes", type=int, default=256,
                      help="Truncate hex dump at this many bytes (default: 256)")
    p_du.add_argument("--output-dir", default=None,
                      help="Output directory (default: system tmp)")
    p_du.add_argument("--by-name", default=None,
                      help="R8.3: Query by IR arg_name instead of bind_slot. "
                           "Resolves the bind_slot from pipeline + AIR metadata. "
                           "When set, the positional 'bind_slot' is ignored (use 0 as placeholder).")
    p_du.add_argument("--field", default=None,
                      help="R8.3: When used with --by-name, filter decoded output to a single field "
                           "(case-insensitive substring match on field name)")

    # find-draws (R7.6-E — label / shader-name → draw 反查)
    p_fd = subparsers.add_parser(
        "find-draws", parents=[parent],
        help="Find draws by RPS label / shader function name / RPS key (R7.6-E). "
             "Eliminates the GUI↔CLI entry impedance.",
    )
    p_fd.add_argument("trace", help="Path to .gputrace bundle")
    p_fd.add_argument("--by-label", default=None,
                      help="Filter by RPS label substring (case-insensitive)")
    p_fd.add_argument("--by-shader-name", default=None,
                      help="Filter by vertex/fragment function name substring (case-insensitive)")
    p_fd.add_argument("--by-rps-key", type=int, default=None,
                      help="Filter by exact RPS key")
    p_fd.add_argument("--limit", type=int, default=50,
                      help="Max number of hits to return (default: 50)")
    p_fd.add_argument("--show-first", action="store_true",
                      help="Automatically run shader-of-drawcall on the first hit "
                           "(with --with-ir and --with-uniforms via passthrough flags)")
    p_fd.add_argument("--stage", choices=["fragment", "vertex"], default="fragment",
                      help="Stage for --show-first联动 (default: fragment)")
    p_fd.add_argument("--with-ir", action="store_true",
                      help="Pass --with-ir to shader-of-drawcall when --show-first is used")
    p_fd.add_argument("--with-uniforms", action="store_true",
                      help="Pass --with-uniforms to shader-of-drawcall when --show-first is used")
    p_fd.add_argument("--output-dir", default=None,
                      help="Output directory for --show-first (default: system tmp)")

    # draw-info (R8.1 — per-draw merged binding view with IR metadata)
    p_di = subparsers.add_parser(
        "draw-info", parents=[parent],
        help="Per-draw merged binding view with IR arg_name/type/size auto-injected (R8.1). "
             "Flat single-draw JSON — eliminates multi-source join errors.",
    )
    p_di.add_argument("trace", help="Path to .gputrace bundle")
    p_di.add_argument("draw_index", type=int,
                      help="Global draw index from frame-list draw_to_rps_map[]")
    p_di.add_argument("--with-uniforms", action="store_true",
                      help="Also decode buffer bytes via reflection (per fragment buffer slot)")
    p_di.add_argument("--output-dir", default=None,
                      help="Output directory for IR files (default: system tmp)")

    # config
    p_config = subparsers.add_parser("config", parents=[parent], help="Configuration control")
    p_config.add_argument("trace", help="Path to .gputrace bundle")
    p_config.add_argument("options", nargs="*", help="key=value pairs")

    args = parser.parse_args()

    if not args.command:
        parser.print_help()
        sys.exit(1)

    try:
        bridge = ReplayBridge(bridge_path=args.bridge)
    except (FileNotFoundError, PermissionError) as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)

    indent = 2 if args.pretty else None

    try:
        if args.command == "help":
            result = bridge.help()
            print(json.dumps(result.raw, indent=indent))

        elif args.command == "replay":
            export_id = int(args.export[0]) if args.export else None
            export_path = args.export[1] if args.export else None
            result = bridge.replay(
                args.trace,
                playto=args.playto,
                list_resources=args.list_resources,
                export_id=export_id,
                export_path=export_path,
                timeout=args.timeout,
            )
            print(json.dumps(result.raw, indent=indent))

        elif args.command == "pipeline":
            result = bridge.pipeline(args.trace, args.output_dir, timeout=args.timeout)
            print(json.dumps(result.raw, indent=indent))

        elif args.command == "shader":
            result = bridge.shader(
                args.trace,
                args.lib_key,
                metallib_path=args.metallib,
                source_path=args.source,
                verify=args.verify,
                timeout=args.timeout,
            )
            print(json.dumps(result.raw, indent=indent))

        elif args.command == "shader-of-rps":
            result = bridge.shader_of_rps(
                args.trace,
                args.rps_key,
                stage=args.stage,
                with_ir=args.with_ir,
                output_dir=args.output_dir,
                timeout=args.timeout,
            )
            print(json.dumps(result.raw, indent=indent))
            # Surface the bridge's structured error (e.g. rps_not_found) via
            # exit code so shell pipelines can detect it without parsing JSON.
            if result.error:
                sys.exit(11)

        elif args.command == "frame-list":
            result = bridge.frame_list(
                args.trace,
                with_draws=not args.no_draws,
                with_timing=args.with_timing,
                with_bindings=not args.no_bindings,
                timeout=args.timeout,
            )
            print(json.dumps(result.raw, indent=indent))

        elif args.command == "shader-of-drawcall":
            result = bridge.shader_of_drawcall(
                args.trace,
                args.draw_index,
                stage=args.stage,
                with_ir=args.with_ir,
                with_bindings=args.with_bindings,
                with_uniforms=args.with_uniforms,
                output_dir=args.output_dir,
                timeout=args.timeout,
            )
            # 输出 schema：顶层 frame-list 元信息 + 嵌入 shader-of-rps 完整 raw
            # R7.6-D: 当 with_bindings / with_uniforms 时附 bindings / uniforms 字段
            payload: dict[str, Any] = {
                "command": "shader-of-drawcall",
                "trace_path": result.trace_path,
                "draw_index": result.draw_index,
                "stage": result.stage,
                "output_dir": result.output_dir,
                "encoder_index": result.encoder_index,
                "draw_in_encoder": result.draw_in_encoder,
                "call_index": result.call_index,
                "rps_key": result.rps_key,
                "rps_label": result.rps_label,
                "shader_of_rps": result.shader.raw if result.shader else None,
            }
            # R7.6-D — bindings: 直接落 raw 中保存的 bindings_summary 与原始字典
            #         (用 result.raw 中已有的 bindings_summary 给一个简洁视图；
            #         完整结构通过 frame-list 子命令获取)
            if result.bindings is not None:
                payload["with_bindings"] = True
                # 把 frame-list 同来源的 bindings dict 重新塞回 (保证字节级 round-trip)
                # 这里直接构造 dict，因为 dataclass→dict 不复杂。
                def _bg(sb: FrameStageBindings) -> dict[str, Any]:
                    return {
                        "buffers": [
                            {k: v for k, v in {
                                "index": b.index,
                                "resource_id": b.resource_id,
                                "offset": b.offset,
                                "inline_bytes_size": b.inline_bytes_size,
                            }.items() if v is not None}
                            for b in sb.buffers
                        ],
                        "textures": [
                            {"index": t.index, "resource_id": t.resource_id}
                            for t in sb.textures
                        ],
                        "samplers": [
                            {"index": s.index, "sampler_ptr": s.sampler_ptr}
                            for s in sb.samplers
                        ],
                    }
                payload["bindings"] = {
                    "vertex": _bg(result.bindings.vertex),
                    "fragment": _bg(result.bindings.fragment),
                }
            else:
                payload["with_bindings"] = False
            if result.uniforms is not None:
                payload["with_uniforms"] = True
                payload["uniforms"] = [u.raw for u in result.uniforms]
                # 同时给一个简洁汇总，让消费方一眼看到 per-slot 健康度
                payload["uniforms_summary"] = {
                    "slot_count": len(result.uniforms),
                    "slot_ok": sum(1 for u in result.uniforms if u.error is None),
                    "slot_failed": sum(1 for u in result.uniforms if u.error is not None),
                    "errors": [
                        {"bind_slot": u.bind_slot, "error": u.error}
                        for u in result.uniforms if u.error is not None
                    ],
                }
                # R8.2: aggregate value_health_summary across all decoded slots
                agg_nan = 0
                agg_inf = 0
                agg_denormal = 0
                agg_nan_fields: list[str] = []
                agg_inf_fields: list[str] = []
                agg_denormal_fields: list[str] = []
                for u in result.uniforms:
                    if u.decoded:
                        vhs = compute_value_health_summary(u.decoded)
                        if vhs:
                            agg_nan += vhs["nan_count"]
                            agg_inf += vhs["inf_count"]
                            agg_denormal += vhs["denormal_count"]
                            prefix = u.binding_name or f"slot_{u.bind_slot}"
                            agg_nan_fields.extend(f"{prefix}.{f}" for f in vhs["fields_with_nan"])
                            agg_inf_fields.extend(f"{prefix}.{f}" for f in vhs["fields_with_inf"])
                            agg_denormal_fields.extend(f"{prefix}.{f}" for f in vhs["fields_with_denormal"])
                if agg_nan + agg_inf + agg_denormal > 0:
                    payload["value_health_summary"] = {
                        "nan_count": agg_nan,
                        "inf_count": agg_inf,
                        "denormal_count": agg_denormal,
                        "fields_with_nan": agg_nan_fields,
                        "fields_with_inf": agg_inf_fields,
                        "fields_with_denormal": agg_denormal_fields,
                    }
            else:
                payload["with_uniforms"] = False
            if result.error:
                payload["error"] = result.error
                payload["hint"] = result.hint
            print(json.dumps(payload, indent=indent))
            # 与 shader-of-rps 同款 — 把链路上的结构化失败映射成 exit 11，让 shell 流水线
            # 不必解析 JSON 也能感知。OOR 单独走 except 分支映射到 exit 12。
            if result.error:
                sys.exit(11)

        elif args.command == "disasm":
            disasm_result = bridge.disasm(
                args.trace,
                args.key,
                key_type=args.key_type,
                stage=args.stage,
                with_ir=args.with_ir,
                output_dir=args.output_dir,
                timeout=args.timeout,
            )
            print(json.dumps(disasm_result.raw, indent=indent))
            # 与 shader-of-rps 同款：library_not_found 等结构化错误映射 exit 11
            if disasm_result.error:
                sys.exit(11)

        elif args.command == "dump-uniforms":
            # R8.3: --by-name mode — resolve bind_slot from IR arg_name
            if args.by_name is not None:
                # Need to resolve arg_name → bind_slot via pipeline + disasm + AIR metadata
                trace_path_resolved = ReplayBridge._validate_trace(args.trace)
                # Step 1: determine rps_key (from draw or directly)
                if args.target_kind == "draw":
                    fl = bridge.frame_list(
                        trace_path_resolved,
                        with_draws=True,
                        with_bindings=True,
                        with_timing=False,
                        timeout=args.timeout,
                    )
                    if args.target >= fl.draw_count:
                        raise DrawIndexOutOfRange(
                            draw_index=args.target,
                            draw_count=fl.draw_count,
                            trace_path=str(trace_path_resolved),
                        )
                    entry = fl.draw_to_rps_map[args.target]
                    rps_key_resolved = entry.rps_key
                else:
                    rps_key_resolved = args.target

                if rps_key_resolved is None:
                    print(json.dumps({
                        "error": "draw_has_no_rps_key",
                        "hint": "Cannot resolve --by-name without a valid RPS key",
                    }, indent=indent))
                    sys.exit(11)

                # Step 2: find library_key for the stage
                pl = bridge.pipeline(trace_path_resolved, timeout=args.timeout)
                lib_key: Optional[int] = None
                for rps in pl.render_pipeline_states:
                    if rps.key == rps_key_resolved:
                        lib_key = rps.fragment_library_key if args.stage == "fragment" else rps.vertex_library_key
                        break

                if lib_key is None:
                    print(json.dumps({
                        "error": "library_key_not_found",
                        "hint": f"Could not find {args.stage} library for RPS {rps_key_resolved}",
                    }, indent=indent))
                    sys.exit(11)

                # Step 3: parse AIR metadata to find bind_slot by name
                meta = bridge._get_air_metadata_for_library(
                    trace_path_resolved, lib_key,
                    output_dir=args.output_dir, timeout=args.timeout,
                )
                name_lower = args.by_name.lower()
                matched_slot: Optional[int] = None
                for loc_idx, buf_arg in meta.buffers.items():
                    if buf_arg.arg_name.lower() == name_lower:
                        matched_slot = loc_idx
                        break
                if matched_slot is None:
                    # Try substring match
                    for loc_idx, buf_arg in meta.buffers.items():
                        if name_lower in buf_arg.arg_name.lower():
                            matched_slot = loc_idx
                            break
                if matched_slot is None:
                    print(json.dumps({
                        "error": "binding_name_not_found",
                        "by_name": args.by_name,
                        "stage": args.stage,
                        "available_names": [b.arg_name for b in meta.buffers.values()],
                        "hint": "No buffer binding matches the given --by-name. Check available names above.",
                    }, indent=indent))
                    sys.exit(11)

                # Step 4: run dump-uniforms with the resolved bind_slot
                du_result = bridge.dump_uniforms(
                    args.trace,
                    args.target,
                    matched_slot,
                    target_kind=args.target_kind,
                    stage=args.stage,
                    buffer_key=args.buffer_key,
                    offset=args.offset,
                    with_hex=args.with_hex,
                    max_hex_bytes=args.max_hex_bytes,
                    output_dir=args.output_dir,
                    timeout=args.timeout,
                )
            else:
                du_result = bridge.dump_uniforms(
                    args.trace,
                    args.target,
                    args.bind_slot,
                    target_kind=args.target_kind,
                    stage=args.stage,
                    buffer_key=args.buffer_key,
                    offset=args.offset,
                    with_hex=args.with_hex,
                    max_hex_bytes=args.max_hex_bytes,
                    output_dir=args.output_dir,
                    timeout=args.timeout,
                )
            # 把 wrapper 自身合成的 frame-list 上下文也带进 raw（如 draw_index/encoder_index）
            payload = dict(du_result.raw)
            if du_result.draw_index is not None:
                payload.setdefault("draw_index", du_result.draw_index)
                payload.setdefault("encoder_index", du_result.encoder_index)
                payload.setdefault("draw_in_encoder", du_result.draw_in_encoder)
                payload.setdefault("call_index", du_result.call_index)
            # R8.2: value_health_summary
            if du_result.decoded:
                vhs = compute_value_health_summary(du_result.decoded)
                if vhs:
                    payload["value_health_summary"] = vhs
            # R8.3: --field filter — strip decoded down to matching field(s)
            if args.field and du_result.decoded and isinstance(du_result.decoded, dict):
                field_lower = args.field.lower()
                filtered = {
                    k: v for k, v in du_result.decoded.items()
                    if field_lower in k.lower()
                }
                payload["decoded"] = filtered
                payload["field_filter"] = args.field
                payload["field_match_count"] = len(filtered)
            print(json.dumps(payload, indent=indent))
            if du_result.error:
                sys.exit(11)

        elif args.command == "find-draws":
            fd_result = bridge.find_draws(
                args.trace,
                by_label=args.by_label,
                by_shader_name=args.by_shader_name,
                by_rps_key=args.by_rps_key,
                limit=args.limit,
                show_first=args.show_first,
                show_first_stage=args.stage,
                show_first_with_ir=args.with_ir,
                show_first_with_uniforms=args.with_uniforms,
                output_dir=args.output_dir,
                timeout=args.timeout,
            )
            payload = dict(fd_result.raw)
            if fd_result.show_first_result is not None:
                sod = fd_result.show_first_result
                payload["show_first"] = {
                    "draw_index": sod.draw_index,
                    "stage": sod.stage,
                    "rps_key": sod.rps_key,
                    "rps_label": sod.rps_label,
                    "shader_of_rps": sod.shader.raw if sod.shader else None,
                    "error": sod.error,
                    "hint": sod.hint,
                }
            print(json.dumps(payload, indent=indent))

        elif args.command == "draw-info":
            di_result = bridge.draw_info(
                args.trace,
                args.draw_index,
                with_uniforms=args.with_uniforms,
                output_dir=args.output_dir,
                timeout=args.timeout,
            )
            print(json.dumps(di_result.raw, indent=indent))
            if di_result.error:
                sys.exit(11)

        elif args.command == "config":
            # Parse key=value pairs into kwargs
            kwargs: dict[str, Any] = {}
            for opt in (args.options or []):
                if "=" not in opt:
                    continue
                k, v = opt.split("=", 1)
                if k == "disableOptimizeRestores":
                    kwargs["disable_optimize_restores"] = v == "1"
                elif k == "forceLoadUnusedResources":
                    kwargs["force_load_unused_resources"] = v == "1"
                elif k == "enableValidation":
                    kwargs["enable_validation"] = v == "1"
            result = bridge.config(args.trace, timeout=args.timeout, **kwargs)
            print(json.dumps(result.raw, indent=indent))

    except BridgeError as e:
        print(json.dumps({
            "error": True,
            "exit_code": e.exit_code,
            "exit_name": e.exit_name,
            "stderr": e.stderr.strip(),
            "command": e.command,
        }, indent=indent), file=sys.stderr)
        sys.exit(e.exit_code)
    except DrawIndexOutOfRange as e:
        # R7.6-C: 与 bridge 的 PLAYTO_OOR (exit 12) 同语义 — "用户给了一个超出范围的索引"。
        # 复用 exit 12，但 error 字符串区分为 draw_index_out_of_range，方便 shell 解析。
        print(json.dumps({
            "error": "draw_index_out_of_range",
            "draw_index": e.draw_index,
            "draw_count": e.draw_count,
            "trace_path": e.trace_path,
            "hint": (
                "frame-list reports draw_count=0 for compute-only traces; "
                "shader-of-drawcall is only meaningful when the trace has render draws."
            ) if e.draw_count == 0 else
                f"valid draw_index range is [0, {e.draw_count - 1}].",
        }, indent=indent))
        sys.exit(12)
    except (FileNotFoundError, ValueError) as e:
        print(json.dumps({"error": True, "message": str(e)}, indent=indent), file=sys.stderr)
        sys.exit(2)
    except TimeoutError as e:
        print(json.dumps({"error": True, "message": str(e)}, indent=indent), file=sys.stderr)
        sys.exit(124)


if __name__ == "__main__":
    _cli_main()
