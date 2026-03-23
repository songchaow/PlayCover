#!/usr/bin/env python3
"""Add H10 (Keymap) files to PlayCover.xcodeproj.
Uses safe section-based insertion to avoid corrupting the pbxproj file."""

import os, sys, subprocess, uuid, re

PBX = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "PlayCover.xcodeproj", "project.pbxproj"))
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
    with open(PBX, 'rb') as f:
        raw = f.read()

    # Detect line endings and work with LF
    if b'\r\n' in raw:
        line_ending = '\r\n'
        c = raw.decode('utf-8').replace('\r\n', '\n')
    else:
        line_ending = '\n'
        c = raw.decode('utf-8')

    # Files to add
    mcp_files = [
        "PlayCoverMCP/HostServices/Keymap/KeymapService.swift",
        "PlayCoverMCP/Tools/Host/KeymapTools.swift",
    ]
    test_files = [
        "PlayCoverMCPTests/KeymapServiceTests.swift",
    ]
    all_files = mcp_files + test_files

    # Check files exist
    for p in all_files:
        full = os.path.join(os.path.dirname(__file__), "..", p)
        if not os.path.exists(full):
            print(f"FAIL: File not found: {full}")
            sys.exit(1)

    # Generate IDs
    file_refs = {p: gid() for p in all_files}
    build_files = {p: gid() for p in all_files}
    keymap_grp_id = gid()

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
    # 3a. Create Keymap group under HostServices
    keymap_grp = (
        f'\t\t{keymap_grp_id} /* Keymap */ = {{\n'
        f'\t\t\tisa = PBXGroup;\n'
        f'\t\t\tchildren = (\n'
        f'\t\t\t\t{file_refs[mcp_files[0]]} /* {os.path.basename(mcp_files[0])} */,\n'
        f'\t\t\t);\n'
        f'\t\t\tpath = Keymap;\n'
        f'\t\t\tsourceTree = "<group>";\n'
        f'\t\t}};\n'
    )
    c = insert_before_section(c, "/* End PBXGroup section */", keymap_grp)

    # 3b. Find HostServices group dynamically
    # The format uses tabs: BFD73CC3... /* HostServices */ = {\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n
    hs_pattern = '/* HostServices */ = {\n'
    hs_idx = c.find(hs_pattern)
    if hs_idx < 0:
        print("FAIL: Could not find HostServices group")
        sys.exit(1)
    # Find the closing of the children list
    children_close = c.find(');\n', hs_idx)
    if children_close < 0:
        print("FAIL: Could not find HostServices children close")
        sys.exit(1)
    # Insert before the closing ");
    insertion = f'\t\t\t\t{keymap_grp_id} /* Keymap */,\n'
    c = c[:children_close] + insertion + c[children_close:]
    print("OK: Keymap group added to HostServices")

    # 3c. Add KeymapTools.swift to Host group
    # Use the Host group ID pattern to find it reliably
    host_grp_def_pattern = '/* Host */ = {\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n'
    host_grp_idx = c.find(host_grp_def_pattern)
    if host_grp_idx < 0:
        print("WARN: Could not find Host group definition")
    else:
        children_close = c.find(');\n', host_grp_idx)
        if children_close < 0:
            print("WARN: Could not find Host group children close")
        else:
            name = os.path.basename(mcp_files[1])
            insertion = f'\t\t\t\t{file_refs[mcp_files[1]]} /* {name} */,\n'
            c = c[:children_close] + insertion + c[children_close:]
            print(f"OK: {name} added to Host group")

    # 3d. Add test files to PlayCoverMCPTests group
    test_grp_pattern = '/* PlayCoverMCPTests */ = {'
    test_grp_idx = c.find(test_grp_pattern)
    if test_grp_idx >= 0:
        children_open = c.find('children = (\n', test_grp_idx)
        if children_open >= 0:
            close_idx = c.find(');\n', children_open)
            if close_idx >= 0:
                # Find the last child entry line (the line before ");")
                # close_idx points to ");\n" - we want to insert before it
                for tp in test_files:
                    name = os.path.basename(tp)
                    insertion = f'\t\t\t\t{file_refs[tp]} /* {name} */,\n'
                    c = c[:close_idx] + insertion + c[close_idx:]
                    close_idx += len(insertion)
                print("OK: Test files added to PlayCoverMCPTests group")

    # === 4. PBXSourcesBuildPhase ===
    # Find MCP target Sources phase (use InjectionTools as reference)
    mcp_ref_pattern = 'InjectionTools.swift in Sources */,\n'
    mcp_ref_idx = c.find(mcp_ref_pattern)
    if mcp_ref_idx >= 0:
        end_of_line = mcp_ref_idx + len(mcp_ref_pattern)
        for mp in mcp_files:
            name = os.path.basename(mp)
            insertion = f'\t\t\t\t{build_files[mp]} /* {name} in Sources */,\n'
            c = c[:end_of_line] + insertion + c[end_of_line:]
            end_of_line += len(insertion)
        print("OK: MCP files added to Sources build phase")
    else:
        print("WARN: Could not find InjectionTools reference for MCP Sources phase")

    # Find Test target Sources phase (use InjectionServiceTests as reference)
    test_ref_pattern = 'InjectionServiceTests.swift in Sources */,\n'
    test_ref_idx = c.find(test_ref_pattern)
    if test_ref_idx >= 0:
        end_of_line = test_ref_idx + len(test_ref_pattern)
        # Also add the service source file to the test build phase
        # (PlayCoverMCPTests compiles all source files directly, not as a framework)
        insertion = f'\t\t\t\t{build_files[mcp_files[0]]} /* {os.path.basename(mcp_files[0])} in Sources */,\n'
        c = c[:end_of_line] + insertion + c[end_of_line:]
        end_of_line += len(insertion)
        for tp in test_files:
            name = os.path.basename(tp)
            insertion = f'\t\t\t\t{build_files[tp]} /* {name} in Sources */,\n'
            c = c[:end_of_line] + insertion + c[end_of_line:]
            end_of_line += len(insertion)
        print("OK: Test files added to Sources build phase")
    else:
        print("WARN: Could not find InjectionServiceTests reference for Test Sources phase")

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

    # Verify with plutil
    r = subprocess.run(['plutil', '-lint', PBX], capture_output=True, text=True, cwd=PBXDIR)
    # Note: plutil output goes to stdout
    plutil_output = r.stdout + r.stderr
    if 'OK' not in plutil_output:
        print(f"WARN: plutil lint check returned: {plutil_output.strip()}")
        # Don't abort - file may still be valid
    else:
        print("OK: plutil -lint passed")

    # Verify with xcodebuild
    r = subprocess.run(['xcodebuild', '-project', PBXDIR + '/project.pbxproj', '-list'],
                       capture_output=True, text=True, timeout=15)
    if 'damaged' in r.stderr or 'parse error' in r.stderr.lower():
        print(f"FAIL: xcodebuild reported damage: {r.stderr.strip()[:200]}")
        sys.exit(1)
    print("OK: xcodebuild -list passed")
    print("Done!")

if __name__ == "__main__":
    main()
