#!/usr/bin/env python3
"""
set_shader_replacement_mode.py — 切换单个 App Settings plist 中的 shader replacement / extraction 开关。

示例：
    python3 Scripts/set_shader_replacement_mode.py \
        --bundle-id com.miHoYo.Yuanshen \
        --mode off

    python3 Scripts/set_shader_replacement_mode.py \
        --bundle-id com.miHoYo.Yuanshen \
        --mode on \
        --print-path

    python3 Scripts/set_shader_replacement_mode.py \
        --bundle-id com.papegames.lysk \
        --mode extraction \
        --print-path
"""

from __future__ import annotations

import argparse
import plistlib
import sys
from pathlib import Path


DEFAULT_CONTAINER = Path.home() / "Library/Containers/io.playcover.PlayCover"
REPLACEMENT_KEY = "shaderSourceReplacementEnabled"
EXTRACTION_KEY = "shaderDebugInfoExtractionEnabled"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Toggle shader source replacement / debug info extraction for one PlayCover app settings plist"
    )
    parser.add_argument("--bundle-id", required=True, help="target app bundle identifier")
    parser.add_argument(
        "--mode",
        required=True,
        choices=("on", "off", "extraction"),
        help="desired mode: 'on' enables full replacement, 'extraction' enables lightweight extraction only, 'off' disables both",
    )
    parser.add_argument(
        "--container",
        default=str(DEFAULT_CONTAINER),
        help="PlayCover container root (default: ~/Library/Containers/io.playcover.PlayCover)",
    )
    parser.add_argument(
        "--print-path",
        action="store_true",
        help="print the resolved plist path after updating",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    container = Path(args.container).expanduser().resolve()
    settings_path = container / "App Settings" / f"{args.bundle_id}.plist"
    if not settings_path.is_file():
        raise SystemExit(f"settings plist not found: {settings_path}")

    with settings_path.open("rb") as handle:
        payload = plistlib.load(handle)

    if not isinstance(payload, dict):
        raise SystemExit(f"unexpected plist root type at {settings_path}")

    prev_replacement = payload.get(REPLACEMENT_KEY)
    prev_extraction = payload.get(EXTRACTION_KEY)

    if args.mode == "on":
        payload[REPLACEMENT_KEY] = True
        payload[EXTRACTION_KEY] = True
    elif args.mode == "extraction":
        payload[REPLACEMENT_KEY] = False
        payload[EXTRACTION_KEY] = True
    else:  # off
        payload[REPLACEMENT_KEY] = False
        payload[EXTRACTION_KEY] = False

    with settings_path.open("wb") as handle:
        plistlib.dump(payload, handle, sort_keys=False)

    print(
        f"{args.bundle_id}: {REPLACEMENT_KEY} {prev_replacement!r} -> {payload[REPLACEMENT_KEY]!r}, "
        f"{EXTRACTION_KEY} {prev_extraction!r} -> {payload[EXTRACTION_KEY]!r}",
        file=sys.stdout,
    )
    if args.print_path:
        print(settings_path, file=sys.stdout)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
