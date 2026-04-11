#!/usr/bin/env python3
from __future__ import annotations

import re
import sys
import uuid
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
SOURCE_FILE = REPO_ROOT / "Carthage/Checkouts/PlayTools/PlayTools/IRToMSLConverter.swift"
PBXPROJ_FILE = REPO_ROOT / "Carthage/Checkouts/PlayTools/PlayTools.xcodeproj/project.pbxproj"

SEGMENTS = {
    "IRToMSLConverter+AirBuiltins.swift": (269, 1382),
    "IRToMSLConverter+Metadata.swift": (1383, 2201),
    "IRToMSLConverter+IRParsing.swift": (2298, 3793),
    "IRToMSLConverter+BodyTranslation.swift": (3795, 5047),
    "IRToMSLConverter+InstructionTranslation.swift": (5048, 7679),
    "IRToMSLConverter+CodeGeneration.swift": (7681, 8515),
}

EXPECTED_MARKERS = {
    44: "struct IRToMSLConverter {",
    269: "    // MARK: - Air Builtin Mapping (E-004e3)",
    1383: "    // MARK: - IR Metadata Types",
    2203: "    // MARK: - Public API",
    2298: "    // MARK: - IR Parsing",
    3795: "    // MARK: - IR Body Parser (E-004e4a)",
    5048: "    // MARK: - Instruction Translators",
    6807: "    // MARK: - IR Parsing Helpers (E-004e4a)",
    7681: "    /// 生成完整的 MSL 源码",
    8516: "}",
}

PLAYTOOLS_GROUP_LINE = '\t\t\t\tA1F9B30C2F5A000500000001 /* IRToMSLConverter.swift */,\n'
SOURCES_LINE = '\t\t\t\tA1F9B30B2F5A000500000001 /* IRToMSLConverter.swift in Sources */,\n'


def fail(message: str) -> None:
    print(f"FAIL: {message}", file=sys.stderr)
    sys.exit(1)


def gid() -> str:
    return uuid.uuid4().hex.upper()[:24]


def normalize_access(text: str) -> str:
    text = re.sub(r'^(\s*)private static func\b', r'\1static func', text, flags=re.MULTILINE)
    text = re.sub(r'^(\s*)private static let\b', r'\1static let', text, flags=re.MULTILINE)
    text = re.sub(r'^(\s*)private (struct|class|enum|func)\b', r'\1\2', text, flags=re.MULTILINE)
    return text


def insert_before_marker(content: str, marker: str, addition: str) -> str:
    idx = content.find(marker)
    if idx == -1:
        fail(f"未找到插入标记: {marker}")
    return content[:idx] + addition + content[idx:]


def main() -> None:
    if not SOURCE_FILE.exists():
        fail(f"未找到源文件: {SOURCE_FILE}")
    if not PBXPROJ_FILE.exists():
        fail(f"未找到工程文件: {PBXPROJ_FILE}")

    raw_lines = SOURCE_FILE.read_text(encoding="utf-8").splitlines()
    if len(raw_lines) < 8516:
        fail(f"源文件行数过短，期望至少 8516，实际 {len(raw_lines)}")

    for line_no, expected in EXPECTED_MARKERS.items():
        actual = raw_lines[line_no - 1]
        if actual != expected:
            fail(f"第 {line_no} 行锚点不匹配。\n期望: {expected}\n实际: {actual}")

    def segment(start: int, end: int) -> str:
        return "\n".join(raw_lines[start - 1:end])

    base_lines = raw_lines[:268] + raw_lines[2201:2297] + [raw_lines[8515]]
    base_text = "\n".join(base_lines) + "\n"
    SOURCE_FILE.write_text(base_text, encoding="utf-8")
    print(f"OK: 重写主文件 {SOURCE_FILE.name}")

    output_dir = SOURCE_FILE.parent
    for filename, (start, end) in SEGMENTS.items():
        body = normalize_access(segment(start, end)).rstrip() + "\n"
        content = f"import Foundation\n\nextension IRToMSLConverter {{\n{body}}}\n"
        (output_dir / filename).write_text(content, encoding="utf-8")
        print(f"OK: 写入拆分文件 {filename} ({start}-{end})")

    pbx_content = PBXPROJ_FILE.read_text(encoding="utf-8")
    existing_names = [name for name in SEGMENTS if name in pbx_content]
    if existing_names:
        fail(f"pbxproj 中已存在待添加文件，请先手动检查: {', '.join(existing_names)}")

    file_refs = {name: gid() for name in SEGMENTS}
    build_refs = {name: gid() for name in SEGMENTS}

    build_entries = "".join(
        f"\t\t{build_refs[name]} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {file_refs[name]} /* {name} */; }};\n"
        for name in SEGMENTS
    )
    pbx_content = insert_before_marker(pbx_content, "/* End PBXBuildFile section */", build_entries)

    file_entries = "".join(
        f"\t\t{file_refs[name]} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {name}; sourceTree = \"<group>\"; }};\n"
        for name in SEGMENTS
    )
    pbx_content = insert_before_marker(pbx_content, "/* End PBXFileReference section */", file_entries)

    playtools_group_addition = "".join(
        f"\t\t\t\t{file_refs[name]} /* {name} */,\n"
        for name in SEGMENTS
    )
    if PLAYTOOLS_GROUP_LINE not in pbx_content:
        fail("未找到 PlayTools group 中的 IRToMSLConverter.swift 行")
    pbx_content = pbx_content.replace(PLAYTOOLS_GROUP_LINE, PLAYTOOLS_GROUP_LINE + playtools_group_addition, 1)

    sources_addition = "".join(
        f"\t\t\t\t{build_refs[name]} /* {name} in Sources */,\n"
        for name in SEGMENTS
    )
    if SOURCES_LINE not in pbx_content:
        fail("未找到 Sources build phase 中的 IRToMSLConverter.swift 行")
    pbx_content = pbx_content.replace(SOURCES_LINE, SOURCES_LINE + sources_addition, 1)

    PBXPROJ_FILE.write_text(pbx_content, encoding="utf-8")
    print("OK: 更新 PlayTools.xcodeproj/project.pbxproj")

    print("DONE: IRToMSLConverter 已完成纯拆分式重构")


if __name__ == "__main__":
    main()
