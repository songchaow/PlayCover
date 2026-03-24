#!/usr/bin/env python3
"""
G02: 将 MCP 源文件添加到 PlayCover.app target 的 Sources build phase。

策略：
- 使用基于行的解析
- 在 PBXSourcesBuildPhase section 中找到对应 build phase
- 提取所有 BuildFile ID
- 排除 main.swift 和 StdioTransport.swift
- 创建新 PBXBuildFile 条目添加到 GUI target
"""

import os
import re
import subprocess
import sys
import uuid

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.dirname(SCRIPT_DIR)
PBX = os.path.join(PROJECT_ROOT, "PlayCover.xcodeproj", "project.pbxproj")

# 需要排除的文件（不添加到 GUI target）
EXCLUDE_FILES = {"main.swift", "StdioTransport.swift"}

# PlayCover.app target 的 Sources build phase ID
GUI_SOURCES_PHASE_ID = "8783CFF326B8C52D00171041"

# PlayCoverMCP target 的 Sources build phase ID
MCP_SOURCES_PHASE_ID = "1846259310234BF491844A47"


def generate_id():
    """生成 24 字符的 Xcode 风格 ID"""
    return uuid.uuid4().hex[:24].upper()


def lint():
    """验证 pbxproj 格式"""
    result = subprocess.run(["plutil", "-lint", PBX], capture_output=True, text=True)
    ok = "OK" in result.stdout
    if not ok:
        print(f"  plutil -lint FAILED: {result.stdout.strip()} {result.stderr.strip()}")
    else:
        print(f"  plutil -lint: OK")
    return ok


def read_pbxproj():
    with open(PBX, "r", encoding="utf-8") as f:
        return f.readlines()


def write_pbxproj(lines):
    with open(PBX, "w", encoding="utf-8") as f:
        f.writelines(lines)


def backup_pbxproj():
    """创建备份"""
    backup_path = PBX + ".bak_g02"
    with open(PBX, "r", encoding="utf-8") as f:
        content = f.read()
    with open(backup_path, "w", encoding="utf-8") as f:
        f.write(content)
    print(f"  备份已保存到: {backup_path}")
    return backup_path


def restore_pbxproj(backup_path):
    """从备份恢复"""
    with open(backup_path, "r", encoding="utf-8") as f:
        content = f.read()
    with open(PBX, "w", encoding="utf-8") as f:
        f.write(content)
    print(f"  已从备份恢复: {backup_path}")


def find_sources_build_phase(lines, phase_id):
    """在 PBXSourcesBuildPhase section 中找到指定 phase 的 files 列表。
    关键：只在 PBXSourcesBuildPhase section 中查找，避免匹配 PBXNativeTarget section 中的引用。
    返回 [(build_file_id, comment_filename)] 和 files 列表的起止行号 (start_line, end_line)
    """
    in_section = False
    in_phase = False
    in_files = False
    results = []
    files_start = None
    files_end = None

    for i, line in enumerate(lines):
        stripped = line.strip()

        # 检测进入 PBXSourcesBuildPhase section
        if "/* Begin PBXSourcesBuildPhase section */" in stripped:
            in_section = True
            continue

        # 检测离开 PBXSourcesBuildPhase section
        if "/* End PBXSourcesBuildPhase section */" in stripped:
            in_section = False
            break

        if not in_section:
            continue

        # 在 section 中，查找目标 phase
        if phase_id in stripped and "/* Sources */" in stripped:
            in_phase = True
            continue

        if in_phase:
            if "files = (" in stripped:
                in_files = True
                files_start = i + 1  # files 条目从下一行开始
                continue

            if in_files:
                if stripped == ");" or stripped == ");":
                    files_end = i  # 这行是 );
                    in_files = False
                    in_phase = False
                    break

                # 解析条目
                m = re.match(r'\s*([A-Fa-f0-9]{20,})\s*/\*\s*(.*?)\s+in\s+Sources\s*\*/', stripped)
                if m:
                    bf_id = m.group(1)
                    filename = m.group(2)
                    results.append((bf_id, filename))

    return results, files_start, files_end


def find_build_file_fileref(lines, build_file_id):
    """从 PBXBuildFile section 中找到 BuildFile 对应的 FileReference ID"""
    for line in lines:
        stripped = line.strip()
        if stripped.startswith(build_file_id) and "PBXBuildFile" in line and "fileRef" in line:
            m = re.search(r'fileRef\s*=\s*([A-Fa-f0-9]{20,})', line)
            if m:
                return m.group(1)
    return None


def main():
    print("=" * 60)
    print("G02: 将 MCP 源文件添加到 PlayCover.app GUI target")
    print("=" * 60)

    # Step 0: 初始验证
    print("\n[Step 0] 初始 plutil 验证...")
    if not lint():
        print("ERROR: pbxproj 初始状态就有问题，终止")
        sys.exit(1)

    # Step 1: 备份
    print("\n[Step 1] 备份 pbxproj...")
    backup_path = backup_pbxproj()

    lines = read_pbxproj()

    # Step 2: 提取 MCP build files
    print("\n[Step 2] 提取 PlayCoverMCP Sources build phase 文件列表...")
    mcp_files, _, _ = find_sources_build_phase(lines, MCP_SOURCES_PHASE_ID)
    print(f"  找到 {len(mcp_files)} 个文件")
    for bf_id, name in mcp_files:
        print(f"    {name} (BuildFile={bf_id})")

    if len(mcp_files) == 0:
        print("ERROR: 未找到任何文件，请检查 MCP_SOURCES_PHASE_ID")
        sys.exit(1)

    # Step 3: 提取 GUI 已有的 FileRef 集合
    print("\n[Step 3] 提取 GUI target 已有文件...")
    gui_files, gui_files_start, gui_files_end = find_sources_build_phase(lines, GUI_SOURCES_PHASE_ID)
    print(f"  GUI Sources build phase 有 {len(gui_files)} 个文件")
    print(f"  files 列表行号范围: {gui_files_start} - {gui_files_end}")

    gui_filerefs = set()
    for bf_id, _ in gui_files:
        ref = find_build_file_fileref(lines, bf_id)
        if ref:
            gui_filerefs.add(ref)

    # Step 4: 确定哪些文件需要添加
    print("\n[Step 4] 确定需要添加的文件...")
    files_to_add = []  # [(filename, fileref_id)]

    for bf_id, filename in mcp_files:
        if filename in EXCLUDE_FILES:
            print(f"  排除: {filename}")
            continue

        fileref_id = find_build_file_fileref(lines, bf_id)
        if fileref_id is None:
            print(f"  WARNING: 无法找到 {filename} (BuildFile={bf_id}) 的 FileRef，跳过")
            continue

        if fileref_id in gui_filerefs:
            print(f"  已存在: {filename} (FileRef={fileref_id})")
            continue

        files_to_add.append((filename, fileref_id))
        print(f"  待添加: {filename} (FileRef={fileref_id})")

    if not files_to_add:
        print("\n所有文件已在 GUI target 中，无需操作")
        return

    print(f"\n  共需添加 {len(files_to_add)} 个文件")

    # Step 5: 生成新的 PBXBuildFile 条目
    print("\n[Step 5] 生成新的 PBXBuildFile 条目...")
    new_entries = []  # [(new_build_file_id, filename, fileref_id)]

    for filename, fileref_id in files_to_add:
        new_id = generate_id()
        new_entries.append((new_id, filename, fileref_id))
        print(f"  {filename}: NewBuildFile={new_id}, FileRef={fileref_id}")

    # Step 6: 修改 pbxproj
    print("\n[Step 6] 修改 pbxproj...")

    # 6a: 找到 "/* End PBXBuildFile section */" 所在行
    end_bf_line_idx = None
    for i, line in enumerate(lines):
        if "/* End PBXBuildFile section */" in line:
            end_bf_line_idx = i
            break

    if end_bf_line_idx is None:
        print("ERROR: 找不到 PBXBuildFile section 结束标记")
        restore_pbxproj(backup_path)
        sys.exit(1)

    # 在 End PBXBuildFile section 之前插入新 BuildFile 条目
    new_bf_lines = []
    for new_id, filename, fileref_id in new_entries:
        new_bf_lines.append(
            f"\t\t{new_id} /* {filename} in Sources */ = {{isa = PBXBuildFile; fileRef = {fileref_id} /* {filename} */; }};\n"
        )

    for j, new_line in enumerate(new_bf_lines):
        lines.insert(end_bf_line_idx + j, new_line)

    # 需要更新 gui_files_end 的行号（因为前面插入了行）
    offset = len(new_bf_lines)
    gui_files_end_adjusted = gui_files_end + offset

    # 6b: 在 GUI Sources build phase 的 files 列表 ); 之前插入新条目
    new_src_lines = []
    for new_id, filename, _ in new_entries:
        new_src_lines.append(f"\t\t\t\t{new_id} /* {filename} in Sources */,\n")

    for j, new_line in enumerate(new_src_lines):
        lines.insert(gui_files_end_adjusted + j, new_line)

    # Step 7: 写入并验证
    print("\n[Step 7] 写入并验证...")
    write_pbxproj(lines)

    if not lint():
        print("ERROR: 修改后 plutil 验证失败！恢复备份...")
        restore_pbxproj(backup_path)
        if lint():
            print("  恢复成功")
        else:
            print("  恢复后仍然失败，严重错误！")
        sys.exit(1)

    # Step 8: 验证结果
    print("\n[Step 8] 验证修改结果...")
    verify_lines = read_pbxproj()
    gui_files_after, _, _ = find_sources_build_phase(verify_lines, GUI_SOURCES_PHASE_ID)
    print(f"  GUI Sources build phase 现在有 {len(gui_files_after)} 个文件 (之前 {len(gui_files)})")

    mcp_files_after, _, _ = find_sources_build_phase(verify_lines, MCP_SOURCES_PHASE_ID)
    print(f"  MCP Sources build phase 仍有 {len(mcp_files_after)} 个文件 (未变)")

    print("\n" + "=" * 60)
    print(f"成功！已将 {len(files_to_add)} 个 MCP 源文件添加到 PlayCover.app target")
    print("=" * 60)
    print("\n下一步验证：")
    print("  1. git diff --stat PlayCover.xcodeproj/project.pbxproj")
    print("  2. xcodebuild -project PlayCover.xcodeproj -scheme PlayCover -configuration Release build 2>&1 | tail -10")
    print("  3. xcodebuild -project PlayCover.xcodeproj -scheme PlayCoverMCP -configuration Release build 2>&1 | tail -10")


if __name__ == "__main__":
    main()
