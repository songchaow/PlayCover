#!/usr/bin/env python3
"""Add S04 (Input) files to PlayCover.xcodeproj.
Uses safe section-based insertion to avoid corrupting the pbxproj file.

Files to add:
  PlayCoverMCP target:
    - PlayCoverMCP/Session/InputService.swift  (into Session group under PlayCoverMCP)
    - PlayCoverMCP/Tools/Session/InputTools.swift (into Session group under Tools)
  PlayCoverMCPTests target:
    - PlayCoverMCPTests/SessionInputTests.swift
  
  Both InputService.swift and InputTools.swift also need build entries in PlayCoverMCPTests 
  Sources build phase (tests compile sources directly)."""

import os, sys, subprocess, uuid

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

def main():
    # Verify files exist first
    files_to_check = [
        "PlayCoverMCP/Session/InputService.swift",
        "PlayCoverMCP/Tools/Session/InputTools.swift",
        "PlayCoverMCPTests/SessionInputTests.swift",
    ]
    root = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
    for f in files_to_check:
        full = os.path.join(root, f)
        if not os.path.exists(full):
            print(f"FAIL: File not found: {full}")
            sys.exit(1)
    print("OK: All source files exist")

    # Pre-check plutil
    r = subprocess.run(['plutil', '-lint', PBX], capture_output=True, text=True)
    if 'OK' not in (r.stdout + r.stderr):
        print(f"FAIL: pbxproj already invalid before changes: {(r.stdout + r.stderr).strip()}")
        sys.exit(1)
    print("OK: pbxproj valid before changes")

    with open(PBX, 'r') as f:
        c = f.read()

    # Check if already added
    if 'InputService.swift' in c:
        print("SKIP: InputService.swift already in pbxproj")
        sys.exit(0)

    # --- Generate unique IDs ---
    # File references (one per physical file)
    fr_input_service = gid()
    fr_input_tools = gid()
    fr_session_input_tests = gid()

    # Build file entries (one per file per target)
    # PlayCoverMCP target
    bf_input_service_mcp = gid()
    bf_input_tools_mcp = gid()
    # PlayCoverMCPTests target (needs service, tools, and test file)
    bf_input_service_test = gid()
    bf_input_tools_test = gid()
    bf_session_input_tests = gid()

    # === 1. PBXBuildFile section ===
    bf_entries = (
        f'\t\t{bf_input_service_mcp} /* InputService.swift in Sources */ = {{isa = PBXBuildFile; fileRef = {fr_input_service} /* InputService.swift */; }};\n'
        f'\t\t{bf_input_tools_mcp} /* InputTools.swift in Sources */ = {{isa = PBXBuildFile; fileRef = {fr_input_tools} /* InputTools.swift */; }};\n'
        f'\t\t{bf_input_service_test} /* InputService.swift in Sources */ = {{isa = PBXBuildFile; fileRef = {fr_input_service} /* InputService.swift */; }};\n'
        f'\t\t{bf_input_tools_test} /* InputTools.swift in Sources */ = {{isa = PBXBuildFile; fileRef = {fr_input_tools} /* InputTools.swift */; }};\n'
        f'\t\t{bf_session_input_tests} /* SessionInputTests.swift in Sources */ = {{isa = PBXBuildFile; fileRef = {fr_session_input_tests} /* SessionInputTests.swift */; }};\n'
    )
    c = insert_before_section(c, "/* End PBXBuildFile section */", bf_entries)
    print("OK: PBXBuildFile entries added")

    # === 2. PBXFileReference section ===
    fr_entries = (
        f'\t\t{fr_input_service} /* InputService.swift */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; name = InputService.swift; path = InputService.swift; sourceTree = "<group>"; }};\n'
        f'\t\t{fr_input_tools} /* InputTools.swift */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; name = InputTools.swift; path = InputTools.swift; sourceTree = "<group>"; }};\n'
        f'\t\t{fr_session_input_tests} /* SessionInputTests.swift */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; name = SessionInputTests.swift; path = SessionInputTests.swift; sourceTree = "<group>"; }};\n'
    )
    c = insert_before_section(c, "/* End PBXFileReference section */", fr_entries)
    print("OK: PBXFileReference entries added")

    # === 3. PBXGroup section ===
    # 3a. Add InputService.swift to Session group under PlayCoverMCP (the one with BridgeProtocol.swift)
    # Find: /* Session */ = { ... children = ( ... BridgeProtocol.swift ...
    session_service_pattern = '/* Session */ = {\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n'
    # There are multiple Session groups; find the one containing BridgeProtocol.swift
    search_from = 0
    found_session_service = False
    while True:
        idx = c.find(session_service_pattern, search_from)
        if idx < 0:
            break
        # Check if this group contains BridgeProtocol
        close = c.find(');\n', idx)
        if close >= 0 and 'BridgeProtocol.swift' in c[idx:close]:
            # This is the Session group under PlayCoverMCP (services)
            insertion = f'\t\t\t\t{fr_input_service} /* InputService.swift */,\n'
            c = c[:close] + insertion + c[close:]
            found_session_service = True
            print("OK: InputService.swift added to PlayCoverMCP/Session group")
            break
        search_from = idx + len(session_service_pattern)
    if not found_session_service:
        print("WARN: Could not find PlayCoverMCP Session (services) group")

    # 3b. Add InputTools.swift to Session group under Tools (the one with SessionTools.swift, TouchTools.swift)
    search_from = 0
    found_session_tools = False
    while True:
        idx = c.find(session_service_pattern, search_from)
        if idx < 0:
            break
        close = c.find(');\n', idx)
        if close >= 0 and 'TouchTools.swift' in c[idx:close]:
            # This is the Session group under Tools
            insertion = f'\t\t\t\t{fr_input_tools} /* InputTools.swift */,\n'
            c = c[:close] + insertion + c[close:]
            found_session_tools = True
            print("OK: InputTools.swift added to Tools/Session group")
            break
        search_from = idx + len(session_service_pattern)
    if not found_session_tools:
        print("WARN: Could not find Tools/Session group")

    # 3c. Add SessionInputTests.swift to PlayCoverMCPTests group
    test_grp_pattern = '/* PlayCoverMCPTests */ = {'
    test_grp_idx = c.find(test_grp_pattern)
    if test_grp_idx >= 0:
        children_open = c.find('children = (\n', test_grp_idx)
        if children_open >= 0:
            close_idx = c.find(');\n', children_open)
            if close_idx >= 0:
                insertion = f'\t\t\t\t{fr_session_input_tests} /* SessionInputTests.swift */,\n'
                c = c[:close_idx] + insertion + c[close_idx:]
                print("OK: SessionInputTests.swift added to PlayCoverMCPTests group")
    else:
        print("WARN: Could not find PlayCoverMCPTests group")

    # === 4. PBXSourcesBuildPhase ===
    # 4a. Add to PlayCoverMCP target Sources phase
    # Use TouchTools.swift as anchor (it's in the MCP target Sources)
    mcp_anchor = 'TouchTools.swift in Sources */,\n'
    mcp_anchor_idx = c.find(mcp_anchor)
    if mcp_anchor_idx >= 0:
        end_of_line = mcp_anchor_idx + len(mcp_anchor)
        insertion = (
            f'\t\t\t\t{bf_input_service_mcp} /* InputService.swift in Sources */,\n'
            f'\t\t\t\t{bf_input_tools_mcp} /* InputTools.swift in Sources */,\n'
        )
        c = c[:end_of_line] + insertion + c[end_of_line:]
        print("OK: MCP target Sources build phase updated")
    else:
        print("WARN: Could not find TouchTools anchor for MCP Sources phase")

    # 4b. Add to PlayCoverMCPTests target Sources phase
    # Use SessionTouchTests.swift as anchor (it's in the test target Sources)
    test_anchor = 'SessionTouchTests.swift in Sources */,\n'
    test_anchor_idx = c.find(test_anchor)
    if test_anchor_idx >= 0:
        end_of_line = test_anchor_idx + len(test_anchor)
        insertion = (
            f'\t\t\t\t{bf_input_service_test} /* InputService.swift in Sources */,\n'
            f'\t\t\t\t{bf_input_tools_test} /* InputTools.swift in Sources */,\n'
            f'\t\t\t\t{bf_session_input_tests} /* SessionInputTests.swift in Sources */,\n'
        )
        c = c[:end_of_line] + insertion + c[end_of_line:]
        print("OK: Test target Sources build phase updated")
    else:
        print("WARN: Could not find SessionTouchTests anchor for Test Sources phase")

    # === 5. Verify brace balance and save ===
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
    r = subprocess.run(['plutil', '-lint', PBX], capture_output=True, text=True)
    plutil_output = r.stdout + r.stderr
    if 'OK' not in plutil_output:
        print(f"WARN: plutil lint check returned: {plutil_output.strip()}")
    else:
        print("OK: plutil -lint passed")

    print("Done!")

if __name__ == "__main__":
    main()
