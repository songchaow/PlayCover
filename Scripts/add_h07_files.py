#!/usr/bin/env python3
"""Add H07 (Settings) files to PlayCover.xcodeproj.
Uses safe section-based insertion to avoid corrupting the pbxproj file."""

import os, sys, subprocess, uuid, re

PBX = os.path.join(os.path.dirname(__file__), "..", "PlayCover.xcodeproj", "project.pbxproj")
PBXDIR = os.path.dirname(PBX)

gid = lambda: uuid.uuid4().hex[:24].upper()

def insert_before_section(c, section_end_marker, content):
    """Insert content before a section end marker."""
    idx = c.find(section_end_marker)
    if idx < 0:
        print(f"WARN: Could not find marker: {section_end_marker}")
        return c
    return c[:idx] + content + "\n" + c[idx:]

def insert_after_line(c, pattern, content):
    """Insert content after the first line matching pattern."""
    idx = c.find(pattern)
    if idx < 0:
        print(f"WARN: Could not find pattern: {pattern}")
        return c
    end_of_line = c.index('\n', idx)
    return c[:end_of_line + 1] + content + c[end_of_line + 1:]

def main():
    with open(PBX) as f:
        c = f.read()

    # Files to add
    mcp_files = [
        "PlayCoverMCP/HostServices/Settings/SettingsService.swift",
        "PlayCoverMCP/Tools/Host/SettingsTools.swift",
        "PlayCoverMCP/Resources/SettingsResources.swift",
    ]
    test_files = [
        "PlayCoverMCPTests/SettingsServiceTests.swift",
        "PlayCoverMCPTests/SettingsToolsAndResourcesTests.swift",
    ]
    all_files = mcp_files + test_files

    # Generate IDs
    file_refs = {p: gid() for p in all_files}
    build_files = {p: gid() for p in all_files}
    settings_grp_id = gid()

    # === 1. PBXBuildFile section ===
    bf = ""
    for p in all_files:
        name = os.path.basename(p)
        bf += f'\t\t{build_files[p]} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {file_refs[p]} /* {name} */; }};\n'
    c = insert_before_section(c, "/* End PBXBuildFile section */", bf)
    print("OK: PBXBuildFile entries added")

    # === 2. PBXFileReference section ===
    fr = ""
    for p in all_files:
        name = os.path.basename(p)
        fr += f'\t\t{file_refs[p]} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; name = {name}; path = {name}; sourceTree = "<group>"; }};\n'
    c = insert_before_section(c, "/* End PBXFileReference section */", fr)
    print("OK: PBXFileReference entries added")

    # === 3. PBXGroup section ===
    # 3a. Create Settings group under HostServices
    settings_grp = (
        f'\t\t{settings_grp_id} /* Settings */ = {{\n'
        f'\t\t\tisa = PBXGroup;\n'
        f'\t\t\tchildren = (\n'
        f'\t\t\t\t{file_refs[mcp_files[0]]} /* {os.path.basename(mcp_files[0])} */,\n'
        f'\t\t\t);\n'
        f'\t\t\tpath = Settings;\n'
        f'\t\t\tsourceTree = "<group>";\n'
        f'\t\t}};\n'
    )
    c = insert_before_section(c, "/* End PBXGroup section */", settings_grp)

    # 3b. Add Settings group to HostServices group children
    hostservices_id = "6D5A783BCD8844EF91870961"
    # Find the HostServices group and add Settings to its children
    pattern = f'\t\t\t{hostservices_id} /* HostServices */ = {{\n\t\t\tchildren = (\n'
    c = insert_after_line(c, pattern, f'\t\t\t\t{settings_grp_id} /* Settings */,\n')
    print("OK: Settings group added to HostServices")

    # 3c. Add SettingsTools.swift to Host group
    tools_host_pattern = 'path = Host;\n\t\t\tsourceTree = "<group>";\n\t\t};'
    # Find the last child line before the Host group close
    # Look for LaunchTools in Host group
    lt_pattern = 'LaunchTools.swift in Sources'
    lt_idx = c.find(lt_pattern)
    if lt_idx < 0:
        print("WARN: Could not find LaunchTools")
    # Find the Host group - search backwards from LaunchTools for "path = Host"
    host_path_idx = c.rfind('path = Host;', 0, lt_idx)
    if host_path_idx >= 0:
        # Find the children array opening before this
        children_open = c.rfind('children = (\n', 0, host_path_idx)
        if children_open >= 0:
            # Find the closing ); after children_open
            close_idx = c.find(');\n', children_open)
            if close_idx >= 0:
                # Get the last child entry
                last_child_end = c.rfind('\n', children_open, close_idx)
                if last_child_end >= 0:
                    insertion = f',\n\t\t\t\t{file_refs[mcp_files[1]]} /* {os.path.basename(mcp_files[1])} */'
                    c = c[:last_child_end + 1] + insertion + c[last_child_end + 1:]
                    print(f"OK: {os.path.basename(mcp_files[1])} added to Host group")

    # 3d. Add SettingsResources.swift to Resources group
    res_path_idx = c.find('path = Resources;\n\t\t\tsourceTree = "<group>";')
    if res_path_idx >= 0:
        children_open = c.rfind('children = (\n', 0, res_path_idx)
        if children_open >= 0:
            close_idx = c.find(');\n', children_open)
            if close_idx >= 0:
                last_child_end = c.rfind('\n', children_open, close_idx)
                if last_child_end >= 0:
                    name = os.path.basename(mcp_files[2])
                    insertion = f',\n\t\t\t\t{file_refs[mcp_files[2]]} /* {name} */'
                    c = c[:last_child_end + 1] + insertion + c[last_child_end + 1:]
                    print(f"OK: {name} added to Resources group")

    # 3e. Add test files to PlayCoverMCPTests group
    test_grp_pattern = '/* PlayCoverMCPTests */ = {'
    test_grp_idx = c.find(test_grp_pattern)
    if test_grp_idx >= 0:
        children_open = c.find('children = (\n', test_grp_idx)
        if children_open >= 0:
            close_idx = c.find(');\n', children_open)
            if close_idx >= 0:
                last_child_end = c.rfind('\n', children_open, close_idx)
                if last_child_end >= 0:
                    for tp in test_files:
                        name = os.path.basename(tp)
                        insertion = f',\n\t\t\t{file_refs[tp]} /* {name} */'
                        c = c[:last_child_end + 1] + insertion + c[last_child_end + 1:]
                        last_child_end += len(insertion)
                    print("OK: Test files added to PlayCoverMCPTests group")

    # === 4. PBXSourcesBuildPhase ===
    # Find MCP target Sources phase (contains CleanupTools)
    cleanup_bf_pattern = 'CleanupTools.swift in Sources */,\n'
    cleanup_idx = c.find(cleanup_bf_pattern)
    if cleanup_idx >= 0:
        end_of_line = cleanup_idx + len(cleanup_bf_pattern)
        for mp in mcp_files:
            name = os.path.basename(mp)
            insertion = f'\t\t\t\t{build_files[mp]} /* {name} in Sources */,\n'
            c = c[:end_of_line] + insertion + c[end_of_line:]
            end_of_line += len(insertion)
        print("OK: MCP files added to Sources build phase")

    # Find Test target Sources phase (contains CleanupServiceTests)
    test_bf_pattern = 'CleanupServiceTests.swift in Sources */,\n'
    test_idx = c.find(test_bf_pattern)
    if test_idx >= 0:
        end_of_line = test_idx + len(test_bf_pattern)
        for tp in test_files:
            name = os.path.basename(tp)
            insertion = f'\t\t\t\t{build_files[tp]} /* {name} in Sources */,\n'
            c = c[:end_of_line] + insertion + c[end_of_line:]
            end_of_line += len(insertion)
        print("OK: Test files added to Sources build phase")

    # === 5. Verify and save ===
    # Check brace balance
    depth = 0
    for i, ch in enumerate(c):
        if ch == '{': depth += 1
        elif ch == '}': depth -= 1
        if depth < 0:
            print(f"FAIL: unbalanced brace at position {i}")
            sys.exit(1)
    if depth != 0:
        print(f"FAIL: brace depth = {depth}")
        sys.exit(1)
    print("OK: brace balance")

    with open(PBX, 'w') as f:
        f.write(c)

    # Verify with xcodebuild
    r = subprocess.run(['xcodebuild', '-project', 'PlayCover.xcodeproj', '-list'],
                       capture_output=True, text=True, cwd=PBXDIR, timeout=15)
    if 'damaged' in r.stderr or 'parse error' in r.stderr.lower():
        print(f"FAIL: {r.stderr.strip()[:200]}")
        sys.exit(1)
    print("OK: xcodebuild -list passed")
    print("Done!")

if __name__ == "__main__":
    main()
