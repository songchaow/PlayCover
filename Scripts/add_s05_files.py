#!/usr/bin/env python3
"""Add S05 (Session Reliability) files to PlayCover.xcodeproj.
Files:
  - PlayCoverMCP/Session/SessionHealthMonitor.swift  → MCP target + Test target Sources
  - PlayCoverMCPTests/SessionReliabilityTests.swift  → Test target Sources only

Uses safe section-based insertion following lessons from 08-经验教训与常见陷阱.md."""

import os, sys, subprocess, uuid

PBX = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "PlayCover.xcodeproj", "project.pbxproj"))

gid = lambda: uuid.uuid4().hex[:24].upper()


def insert_before_section(c, section_end_marker, content):
    """Insert content before a section end marker."""
    idx = c.find(section_end_marker)
    if idx < 0:
        print(f"FAIL: Could not find marker: {section_end_marker}")
        sys.exit(1)
    return c[:idx] + content + "\n" + c[idx:]


def main():
    # Pre-check: plutil lint
    r = subprocess.run(['plutil', '-lint', PBX], capture_output=True, text=True)
    if 'OK' not in (r.stdout + r.stderr):
        print(f"FAIL: pbxproj is already broken: {(r.stdout + r.stderr).strip()}")
        sys.exit(1)
    print("OK: pbxproj pre-check passed")

    # Check new files exist on disk
    base = os.path.join(os.path.dirname(__file__), "..")
    for rel in ["PlayCoverMCP/Session/SessionHealthMonitor.swift",
                "PlayCoverMCPTests/SessionReliabilityTests.swift"]:
        full = os.path.join(base, rel)
        if not os.path.exists(full):
            print(f"FAIL: File not found: {full}")
            sys.exit(1)
    print("OK: All source files exist")

    with open(PBX, 'rb') as f:
        raw = f.read()
    if b'\r\n' in raw:
        c = raw.decode('utf-8').replace('\r\n', '\n')
    else:
        c = raw.decode('utf-8')

    # Check files not already in pbxproj
    if 'SessionHealthMonitor.swift' in c:
        print("SKIP: SessionHealthMonitor.swift already in pbxproj")
        return
    if 'SessionReliabilityTests.swift' in c:
        print("SKIP: SessionReliabilityTests.swift already in pbxproj")
        return

    # Generate unique IDs
    # SessionHealthMonitor.swift needs:
    #   - 1 PBXFileReference
    #   - 2 PBXBuildFile (MCP target + Test target)
    # SessionReliabilityTests.swift needs:
    #   - 1 PBXFileReference
    #   - 1 PBXBuildFile (Test target only)
    monitor_fileref = gid()
    monitor_bf_mcp = gid()    # PBXBuildFile for MCP target
    monitor_bf_test = gid()   # PBXBuildFile for Test target

    reltest_fileref = gid()
    reltest_bf_test = gid()   # PBXBuildFile for Test target only

    print(f"  monitor_fileref = {monitor_fileref}")
    print(f"  monitor_bf_mcp  = {monitor_bf_mcp}")
    print(f"  monitor_bf_test = {monitor_bf_test}")
    print(f"  reltest_fileref = {reltest_fileref}")
    print(f"  reltest_bf_test = {reltest_bf_test}")

    # === 1. PBXBuildFile section ===
    bf_entries = (
        f'\t\t{monitor_bf_mcp} /* SessionHealthMonitor.swift in Sources */ = {{isa = PBXBuildFile; fileRef = {monitor_fileref} /* SessionHealthMonitor.swift */; }};\n'
        f'\t\t{monitor_bf_test} /* SessionHealthMonitor.swift in Sources */ = {{isa = PBXBuildFile; fileRef = {monitor_fileref} /* SessionHealthMonitor.swift */; }};\n'
        f'\t\t{reltest_bf_test} /* SessionReliabilityTests.swift in Sources */ = {{isa = PBXBuildFile; fileRef = {reltest_fileref} /* SessionReliabilityTests.swift */; }};\n'
    )
    c = insert_before_section(c, "/* End PBXBuildFile section */", bf_entries)
    print("OK: PBXBuildFile entries added")

    # === 2. PBXFileReference section ===
    fr_entries = (
        f'\t\t{monitor_fileref} /* SessionHealthMonitor.swift */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; name = SessionHealthMonitor.swift; path = SessionHealthMonitor.swift; sourceTree = "<group>"; }};\n'
        f'\t\t{reltest_fileref} /* SessionReliabilityTests.swift */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; name = SessionReliabilityTests.swift; path = SessionReliabilityTests.swift; sourceTree = "<group>"; }};\n'
    )
    c = insert_before_section(c, "/* End PBXFileReference section */", fr_entries)
    print("OK: PBXFileReference entries added")

    # === 3. PBXGroup: Add SessionHealthMonitor.swift to Session group (PlayCoverMCP/Session) ===
    # Find the Session group that has path = Session under PlayCoverMCP (contains BridgeProtocol.swift)
    session_grp_pattern = '44E69163029B448383ACDC34 /* Session */ = {'
    session_grp_idx = c.find(session_grp_pattern)
    if session_grp_idx < 0:
        # Dynamic fallback: find Session group containing BridgeProtocol.swift
        alt_pattern = 'BridgeProtocol.swift'
        bp_idx = c.find(alt_pattern, c.find('/* Begin PBXGroup section */'))
        if bp_idx < 0:
            print("FAIL: Cannot find Session group for PlayCoverMCP")
            sys.exit(1)
        # Walk backwards to find group open
        grp_open = c.rfind('/* Session */ = {', 0, bp_idx)
        if grp_open < 0:
            print("FAIL: Cannot find Session group header")
            sys.exit(1)
        session_grp_idx = grp_open
    # Find children close ");\n" for this group
    children_close = c.find(');\n', session_grp_idx)
    if children_close < 0:
        print("FAIL: Cannot find Session group children close")
        sys.exit(1)
    insertion = f'\t\t\t\t{monitor_fileref} /* SessionHealthMonitor.swift */,\n'
    c = c[:children_close] + insertion + c[children_close:]
    print("OK: SessionHealthMonitor.swift added to Session group")

    # === 4. PBXGroup: Add SessionReliabilityTests.swift to PlayCoverMCPTests group ===
    test_grp_pattern = '655C253FCA19492C8624612B /* PlayCoverMCPTests */ = {'
    test_grp_idx = c.find(test_grp_pattern)
    if test_grp_idx < 0:
        # Dynamic fallback
        test_grp_idx = c.find('/* PlayCoverMCPTests */ = {\n\t\t\tisa = PBXGroup;')
        if test_grp_idx < 0:
            print("FAIL: Cannot find PlayCoverMCPTests group")
            sys.exit(1)
    children_close = c.find(');\n', test_grp_idx)
    if children_close < 0:
        print("FAIL: Cannot find PlayCoverMCPTests group children close")
        sys.exit(1)
    insertion = f'\t\t\t\t{reltest_fileref} /* SessionReliabilityTests.swift */,\n'
    c = c[:children_close] + insertion + c[children_close:]
    print("OK: SessionReliabilityTests.swift added to PlayCoverMCPTests group")

    # === 5. PBXSourcesBuildPhase: MCP target ===
    # Find MCP target Sources phase. Use InputTools.swift as anchor (last entry before close)
    mcp_src_anchor = 'InputTools.swift in Sources */,\n'
    # There may be multiple matches; the MCP target's Sources phase is the first one
    # that also contains KeymapTools.swift
    # Strategy: find "KeymapTools.swift in Sources" and use its line-end as insertion point
    keymap_anchor = 'E46D6DBE0FDE41C4AB2A4F68 /* KeymapTools.swift in Sources */,\n'
    keymap_idx = c.find(keymap_anchor)
    if keymap_idx < 0:
        # Dynamic fallback
        keymap_idx = c.find('KeymapTools.swift in Sources */,\n')
        if keymap_idx < 0:
            print("FAIL: Cannot find KeymapTools.swift in MCP Sources phase")
            sys.exit(1)
    end_of_line = keymap_idx + len(c[keymap_idx:c.index('\n', keymap_idx)]) + 1
    insertion = f'\t\t\t\t{monitor_bf_mcp} /* SessionHealthMonitor.swift in Sources */,\n'
    c = c[:end_of_line] + insertion + c[end_of_line:]
    print("OK: SessionHealthMonitor.swift added to MCP Sources build phase")

    # === 6. PBXSourcesBuildPhase: Test target ===
    # Find the Test target Sources phase. Use SessionInputTests as anchor (near end)
    # After our previous insertion, find the SECOND occurrence of "SessionInputTests.swift in Sources"
    # or better, find InjectionToolsAndResourcesTests as it's the last entry
    test_anchor = 'InjectionToolsAndResourcesTests.swift in Sources */,\n'
    test_anchor_idx = c.find(test_anchor)
    if test_anchor_idx < 0:
        print("FAIL: Cannot find InjectionToolsAndResourcesTests.swift in Test Sources phase")
        sys.exit(1)
    end_of_line = test_anchor_idx + len(c[test_anchor_idx:c.index('\n', test_anchor_idx)]) + 1
    # Add both: SessionHealthMonitor.swift + SessionReliabilityTests.swift
    insertion = (
        f'\t\t\t\t{monitor_bf_test} /* SessionHealthMonitor.swift in Sources */,\n'
        f'\t\t\t\t{reltest_bf_test} /* SessionReliabilityTests.swift in Sources */,\n'
    )
    c = c[:end_of_line] + insertion + c[end_of_line:]
    print("OK: SessionHealthMonitor + SessionReliabilityTests added to Test Sources build phase")

    # === 7. Brace balance check ===
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
    print("OK: brace balance check passed")

    # === 8. Write ===
    with open(PBX, 'w') as f:
        f.write(c)
    print("OK: pbxproj written")

    # === 9. plutil lint ===
    r = subprocess.run(['plutil', '-lint', PBX], capture_output=True, text=True)
    plutil_output = r.stdout + r.stderr
    if 'OK' not in plutil_output:
        print(f"WARN: plutil lint returned: {plutil_output.strip()}")
        print("WARNING: pbxproj may be damaged. Check with `git diff` before proceeding.")
    else:
        print("OK: plutil -lint passed")

    print("\nDone! Files added to project:")
    print("  - SessionHealthMonitor.swift   → Session group + MCP target + Test target")
    print("  - SessionReliabilityTests.swift → PlayCoverMCPTests group + Test target")


if __name__ == "__main__":
    main()
