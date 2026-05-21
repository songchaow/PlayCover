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
    error: Optional[str] = None
    hint: Optional[str] = None
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
            error=data.get("error"),
            hint=data.get("hint"),
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
    except (FileNotFoundError, ValueError) as e:
        print(json.dumps({"error": True, "message": str(e)}, indent=indent), file=sys.stderr)
        sys.exit(2)
    except TimeoutError as e:
        print(json.dumps({"error": True, "message": str(e)}, indent=indent), file=sys.stderr)
        sys.exit(124)


if __name__ == "__main__":
    _cli_main()
