#!/usr/bin/env python3
"""Add S00 (Session Bridge) files to PlayCover.xcodeproj.
Uses safe section-based insertion to avoid corrupting the pbxproj file."""

import os, sys, subprocess, uuid

PBX = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "PlayCover.xcodeproj", "project.pbxproj"))
PBXDIR = os.path.dirname(PBX)
REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))

gid = lambda: uuid.uuid4().hex[:24].upper()

def insert_before_section(c, section_end_marker, content):
    """Insert content before a section end marker."""
    idx = c.find(section_end_marker)
    if idx < 0:
        print(f"WARN: Could not find marker: {section_end_marker}")
        return c
    return c[:idx] + content + "\n" + c[idx:]

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
        "PlayCoverMCP/Session/BridgeProtocol.swift",
        "PlayCoverMCP/Session/SessionInfo.swift",
        "PlayCoverMCP/Session/SessionRegistry.swift",
        "PlayCoverMCP/Session/BridgeClient.swift",
        "PlayCoverMCP/Session/RegistrationListener.swift",
    ]
    test_files = [
        "PlayCoverMCPTests/SessionTests.swift",
    ]
    all_files = mcp_files + test_files

    # Check files exist
    for p in all_files:
        full = os.path.join(REPO, p)
        if not os.path.exists(full):
            print(f"FAIL: File not found: {full}")
            sys.exit(1)

    # Generate IDs
    file_refs = {p: gid() for p in all_files}
    build_files = {p: gid() for p in all_files}
    session_grp_id = gid()

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
    # 3a. Create Session group under PlayCoverMCP
    session_grp = (
        f'\t\t{session_grp_id} /* Session */ = {{\n'
        f'\t\t\tisa = PBXGroup;\n'
        f'\t\t\tchildren = (\n'
    )
    for mp in mcp_files:
        name = os.path.basename(mp)
        session_grp += f'\t\t\t\t{file_refs[mp]} /* {name} */,\n'
    session_grp += (
        f'\t\t\t);\n'
        f'\t\t\tpath = Session;\n'
        f'\t\t\tsourceTree = "<group>";\n'
        f'\t\t}};\n'
    )
    c = insert_before_section(c, "/* End PBXGroup section */", session_grp)
    print("OK: Session group created")

    # 3b. Find PlayCoverMCP main group and add Session group to it
    mcp_grp_pattern = '/* PlayCoverMCP */ = {\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n'
    mcp_grp_idx = c.find(mcp_grp_pattern)
    if mcp_grp_idx >= 0:
        children_close = c.find(');\n', mcp_grp_idx)
        if children_close >= 0:
            insertion = f'\t\t\t\t{session_grp_id} /* Session */,\n'
            c = c[:children_close] + insertion + c[children_close:]
            print("OK: Session group added to PlayCoverMCP")
    else:
        print("WARN: Could not find PlayCoverMCP group")

    # 3c. Add test files to PlayCoverMCPTests group
    test_grp_pattern = '/* PlayCoverMCPTests */ = {'
    test_grp_idx = c.find(test_grp_pattern)
    if test_grp_idx >= 0:
        children_open = c.find('children = (\n', test_grp_idx)
        if children_open >= 0:
            close_idx = c.find(');\n', children_open)
            if close_idx >= 0:
                for tp in test_files:
                    name = os.path.basename(tp)
                    insertion = f'\t\t\t\t{file_refs[tp]} /* {name} */,\n'
                    c = c[:close_idx] + insertion + c[close_idx:]
                    close_idx += len(insertion)
                print("OK: Test files added to PlayCoverMCPTests group")
    else:
        print("WARN: Could not find PlayCoverMCPTests group")

    # === 4. PBXSourcesBuildPhase ===
    # Add source files to PlayCoverMCP target Sources phase
    # Find a reference file that's in the MCP target's Sources (use KeymapService as anchor)
    mcp_ref_pattern = 'KeymapService.swift in Sources */,\n'
    mcp_ref_idx = c.find(mcp_ref_pattern)
    if mcp_ref_idx >= 0:
        end_of_line = mcp_ref_idx + len(mcp_ref_pattern)
        for mp in mcp_files:
            name = os.path.basename(mp)
            insertion = f'\t\t\t\t{build_files[mp]} /* {name} in Sources */,\n'
            c = c[:end_of_line] + insertion + c[end_of_line:]
            end_of_line += len(insertion)
        print("OK: MCP source files added to PlayCoverMCP Sources build phase")
    else:
        print("WARN: Could not find KeymapService reference for MCP Sources phase")

    # Add source + test files to PlayCoverMCPTests target Sources phase
    # (Tests compile source files directly)
    test_ref_pattern = 'KeymapServiceTests.swift in Sources */,\n'
    test_ref_idx = c.find(test_ref_pattern)
    if test_ref_idx >= 0:
        end_of_line = test_ref_idx + len(test_ref_pattern)
        # Add all MCP source files to test target
        for mp in mcp_files:
            name = os.path.basename(mp)
            insertion = f'\t\t\t\t{build_files[mp]} /* {name} in Sources */,\n'
            c = c[:end_of_line] + insertion + c[end_of_line:]
            end_of_line += len(insertion)
        # Add test files
        for tp in test_files:
            name = os.path.basename(tp)
            insertion = f'\t\t\t\t{build_files[tp]} /* {name} in Sources */,\n'
            c = c[:end_of_line] + insertion + c[end_of_line:]
            end_of_line += len(insertion)
        print("OK: All files added to PlayCoverMCPTests Sources build phase")
    else:
        print("WARN: Could not find KeymapServiceTests reference for Test Sources phase")

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
    plutil_output = r.stdout + r.stderr
    if 'OK' not in plutil_output:
        print(f"WARN: plutil lint check returned: {plutil_output.strip()}")
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
