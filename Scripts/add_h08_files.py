#!/usr/bin/env python3
"""Add H08 (Signing) files to PlayCover.xcodeproj.
Uses safe section-based insertion to avoid corrupting the pbxproj file."""

import os, sys, subprocess, uuid, re

PBX = os.path.join(os.path.dirname(__file__), "..", "PlayCover.xcodeproj", "project.pbxproj")
PBXDIR = os.path.dirname(PBX)

gid = lambda: uuid.uuid4().hex[:24].upper()

def insert_before_section(c, section_end_marker, content):
    idx = c.find(section_end_marker)
    if idx < 0:
        print(f"WARN: Could not find marker: {section_end_marker}")
        return c
    return c[:idx] + content + "\n" + c[idx:]

def find_group_id(c, name):
    """Find the ID of a PBXGroup by its name comment."""
    pattern = f'/* {name} */ = {{\n\t\t\tisa = PBXGroup;'
    idx = c.find(pattern)
    if idx < 0:
        # Try alternate spacing
        pattern = f'/* {name} */'
        for line in c.split('\n'):
            if pattern in line and '=' in line:
                return line.strip().split()[0]
        return None
    # Walk backwards to find the ID
    line_start = c.rfind('\n', 0, idx)
    if line_start < 0:
        return None
    line = c[line_start+1:idx]
    return line.strip().split()[0].rstrip(';')

def find_children_end(c, group_id):
    """Find the end of a group's children array (the ); line)."""
    # Find the group definition
    pattern = f'{group_id} /* '
    idx = c.find(pattern)
    if idx < 0:
        return -1, -1
    # Find "children = (" after this
    children_pattern = 'children = (\n'
    children_idx = c.find(children_pattern, idx)
    if children_idx < 0:
        return -1, -1
    # Find the closing );
    close_idx = c.find(');\n', children_idx)
    if close_idx < 0:
        return -1, -1
    # Find last child entry's newline
    last_child_end = c.rfind('\n', children_idx, close_idx)
    return children_idx, close_idx, last_child_end

def main():
    with open(PBX) as f:
        c = f.read()

    # Files to add
    signing_service = "PlayCoverMCP/HostServices/Signing/SigningService.swift"
    signing_tools = "PlayCoverMCP/Tools/Host/SigningTools.swift"
    signing_tests = "PlayCoverMCPTests/SigningServiceTests.swift"

    mcp_files = [signing_service, signing_tools]
    test_files = [signing_tests]

    # Generate IDs
    file_refs = {}
    build_files = {}
    for p in mcp_files + test_files:
        file_refs[p] = gid()
        build_files[p] = gid()
    signing_grp_id = gid()

    # === 1. PBXBuildFile section ===
    bf = ""
    for p in mcp_files + test_files:
        name = os.path.basename(p)
        bf += f'\t\t{build_files[p]} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {file_refs[p]} /* {name} */; }};\n'
    c = insert_before_section(c, "/* End PBXBuildFile section */", bf)
    print("OK: PBXBuildFile entries added")

    # === 2. PBXFileReference section ===
    fr = ""
    for p in mcp_files:
        name = os.path.basename(p)
        fr += f'\t\t{file_refs[p]} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; name = {name}; path = {name}; sourceTree = "<group>"; }};\n'
    fr += f'\t\t{file_refs[signing_tests]} /* {os.path.basename(signing_tests)} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; name = {os.path.basename(signing_tests)}; path = {os.path.basename(signing_tests)}; sourceTree = "<group>"; }};\n'
    c = insert_before_section(c, "/* End PBXFileReference section */", fr)
    print("OK: PBXFileReference entries added")

    # === 3. PBXGroup section ===
    # 3a. Create Signing group
    signing_grp = (
        f'\t\t{signing_grp_id} /* Signing */ = {{\n'
        f'\t\t\tisa = PBXGroup;\n'
        f'\t\t\tchildren = (\n'
        f'\t\t\t\t{file_refs[signing_service]} /* {os.path.basename(signing_service)} */,\n'
        f'\t\t\t);\n'
        f'\t\t\tpath = Signing;\n'
        f'\t\t\tsourceTree = "<group>";\n'
        f'\t\t}};\n'
    )
    c = insert_before_section(c, "/* End PBXGroup section */", signing_grp)
    print("OK: Signing group created")

    # 3b. Add Signing group to HostServices group
    hostservices_id = find_group_id(c, "HostServices")
    if hostservices_id:
        result = find_children_end(c, hostservices_id)
        if len(result) == 3 and result[0] >= 0:
            _, close_idx, last_child_end = result
            # Insert after the last child line (before the close)
            insertion = f',\n\t\t\t\t{signing_grp_id} /* Signing */'
            c = c[:last_child_end + 1] + insertion + c[last_child_end + 1:]
            print(f"OK: Signing group added to HostServices ({hostservices_id})")
        else:
            print(f"WARN: Could not find children for HostServices ({hostservices_id})")
    else:
        print("WARN: Could not find HostServices group")

    # 3c. Add SigningTools.swift to Host group
    host_id = find_group_id(c, "Host")
    if host_id:
        result = find_children_end(c, host_id)
        if len(result) == 3 and result[0] >= 0:
            _, close_idx, last_child_end = result
            insertion = f',\n\t\t\t\t{file_refs[signing_tools]} /* {os.path.basename(signing_tools)} */'
            c = c[:last_child_end + 1] + insertion + c[last_child_end + 1:]
            print(f"OK: SigningTools.swift added to Host group")
        else:
            print(f"WARN: Could not find children for Host ({host_id})")
    else:
        print("WARN: Could not find Host group")

    # 3d. Add test file to PlayCoverMCPTests group
    tests_id = find_group_id(c, "PlayCoverMCPTests")
    if tests_id:
        result = find_children_end(c, tests_id)
        if len(result) == 3 and result[0] >= 0:
            _, close_idx, last_child_end = result
            insertion = f',\n\t\t\t{file_refs[signing_tests]} /* {os.path.basename(signing_tests)} */'
            c = c[:last_child_end + 1] + insertion + c[last_child_end + 1:]
            print(f"OK: SigningServiceTests.swift added to PlayCoverMCPTests group")
        else:
            print(f"WARN: Could not find children for PlayCoverMCPTests ({tests_id})")
    else:
        print("WARN: Could not find PlayCoverMCPTests group")

    # === 4. PBXSourcesBuildPhase ===
    # Find MCP target Sources phase - look for SettingsTools build file entry
    settings_bf_pattern = 'SettingsTools.swift in Sources */,\n'
    settings_idx = c.find(settings_bf_pattern)
    if settings_idx >= 0:
        end_of_line = settings_idx + len(settings_bf_pattern)
        for mp in mcp_files:
            name = os.path.basename(mp)
            insertion = f'\t\t\t\t{build_files[mp]} /* {name} in Sources */,\n'
            c = c[:end_of_line] + insertion + c[end_of_line:]
            end_of_line += len(insertion)
        print("OK: MCP files added to MCP Sources build phase")
    else:
        print("WARN: Could not find SettingsTools in MCP build phase")

    # Find Test target Sources phase - look for SettingsServiceTests build file entry
    test_bf_pattern = 'SettingsServiceTests.swift in Sources */,\n'
    test_idx = c.find(test_bf_pattern)
    if test_idx >= 0:
        end_of_line = test_idx + len(test_bf_pattern)
        for tp in test_files:
            name = os.path.basename(tp)
            insertion = f'\t\t\t\t{build_files[tp]} /* {name} in Sources */,\n'
            c = c[:end_of_line] + insertion + c[end_of_line:]
            end_of_line += len(insertion)
        print("OK: Test files added to Test Sources build phase")
    else:
        print("WARN: Could not find SettingsServiceTests in Test build phase")

    # === 5. Verify and save ===
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
                       capture_output=True, text=True, cwd=PBXDIR, timeout=30)
    if 'damaged' in r.stderr or 'parse error' in r.stderr.lower():
        print(f"FAIL: {r.stderr.strip()[:500]}")
        sys.exit(1)
    print("OK: xcodebuild -list passed")
    print("Done!")

if __name__ == "__main__":
    main()
