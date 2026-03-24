#!/usr/bin/env python3
"""Add S02 files to PlayCover.xcodeproj."""

import os
import subprocess
import sys

PBXDIR = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "PlayCover.xcodeproj"))
PBX = os.path.join(PBXDIR, "project.pbxproj")

def run(cmd):
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        print(f"WARN: {cmd} failed: {r.stderr.strip()}")
    return r.stdout.strip()

def gen_id():
    import random
    return ''.join(random.choices('0123456789ABCDEF', k=24))

def main():
    with open(PBX, 'r') as f:
        c = f.read()

    # Verify current state
    result = run(['plutil', '-lint', PBX])
    if 'OK' not in result:
        print(f"ERROR: pbxproj lint failed before changes: {result}")
        sys.exit(1)

    # Files to add:
    # 1. PlayCoverMCP/Session/TouchService.swift -> Session group, both targets
    # 2. PlayCoverMCP/Tools/Session/TouchTools.swift -> Tools/Session group, both targets
    # 3. PlayCoverMCPTests/SessionTouchTests.swift -> PlayCoverMCPTests group, test target only

    files_info = {}

    for name in ["TouchService.swift", "TouchTools.swift", "SessionTouchTests.swift"]:
        if f"/* {name} */" in c:
            print(f"SKIP: {name} already in pbxproj")
            sys.exit(0)

    # Generate IDs
    for name in ["TouchService.swift", "TouchTools.swift", "SessionTouchTests.swift"]:
        files_info[name] = {
            "file_ref_id": gen_id(),
            "build_file_mcp_id": gen_id(),
            "build_file_test_id": gen_id(),
        }

    # === 1. Add PBXBuildFile entries ===
    # Insert after SessionLifecycleTests.swift build file entries
    anchor = "C9B77BE0F966388DE55DF2CC /* SessionLifecycleTests.swift in Sources */ = {isa = PBXBuildFile;"
    idx = c.find(anchor)
    if idx == -1:
        print("ERROR: Could not find SessionLifecycleTests anchor in PBXBuildFile section")
        sys.exit(1)
    end_of_line = c.find('\n', idx)

    insertions = ""
    # TouchService.swift: both MCP and Tests targets
    info = files_info["TouchService.swift"]
    insertions += f"\t\t{info['build_file_mcp_id']} /* TouchService.swift in Sources */ = {{isa = PBXBuildFile; fileRef = {info['file_ref_id']} /* TouchService.swift */; }};\n"
    insertions += f"\t\t{info['build_file_test_id']} /* TouchService.swift in Sources */ = {{isa = PBXBuildFile; fileRef = {info['file_ref_id']} /* TouchService.swift */; }};\n"

    # TouchTools.swift: both MCP and Tests targets
    info = files_info["TouchTools.swift"]
    insertions += f"\t\t{info['build_file_mcp_id']} /* TouchTools.swift in Sources */ = {{isa = PBXBuildFile; fileRef = {info['file_ref_id']} /* TouchTools.swift */; }};\n"
    insertions += f"\t\t{info['build_file_test_id']} /* TouchTools.swift in Sources */ = {{isa = PBXBuildFile; fileRef = {info['file_ref_id']} /* TouchTools.swift */; }};\n"

    # SessionTouchTests.swift: test target only
    info = files_info["SessionTouchTests.swift"]
    insertions += f"\t\t{info['build_file_test_id']} /* SessionTouchTests.swift in Sources */ = {{isa = PBXBuildFile; fileRef = {info['file_ref_id']} /* SessionTouchTests.swift */; }};\n"

    c = c[:end_of_line + 1] + insertions + c[end_of_line + 1:]

    # === 2. Add PBXFileReference entries ===
    # Insert after SessionLifecycleTests.swift file reference
    anchor = "21549A0830B5DFB9F2E1D233 /* SessionLifecycleTests.swift */ = {isa = PBXFileReference;"
    idx = c.find(anchor)
    if idx == -1:
        print("ERROR: Could not find SessionLifecycleTests anchor in PBXFileReference section")
        sys.exit(1)
    end_of_line = c.find('\n', idx)

    insertions = ""
    for name in ["TouchService.swift", "TouchTools.swift", "SessionTouchTests.swift"]:
        info = files_info[name]
        insertions += f"\t\t{info['file_ref_id']} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; name = {name}; path = {name}; sourceTree = \"<group>\"; }};\n"

    c = c[:end_of_line + 1] + insertions + c[end_of_line + 1:]

    # === 3. Add TouchService.swift to Session group ===
    # Session group has SessionService.swift as last entry
    anchor = "A532939C6B04A6BADB1275CC /* SessionService.swift */,"
    idx = c.find(anchor)
    if idx == -1:
        print("ERROR: Could not find SessionService anchor in Session group")
        sys.exit(1)
    end_of_line = c.find('\n', idx)
    info = files_info["TouchService.swift"]
    c = c[:end_of_line + 1] + f"\t\t\t\t{info['file_ref_id']} /* TouchService.swift */,\n" + c[end_of_line + 1:]

    # === 4. Add TouchTools.swift to Tools/Session group ===
    # Tools/Session group has SessionTools.swift
    anchor = "E09AC6EBA62B88DCAE9BC0CB /* SessionTools.swift */,"
    idx = c.find(anchor)
    if idx == -1:
        print("ERROR: Could not find SessionTools anchor in Tools/Session group")
        sys.exit(1)
    end_of_line = c.find('\n', idx)
    info = files_info["TouchTools.swift"]
    c = c[:end_of_line + 1] + f"\t\t\t\t{info['file_ref_id']} /* TouchTools.swift */,\n" + c[end_of_line + 1:]

    # === 5. Add SessionTouchTests.swift to PlayCoverMCPTests group ===
    # After SessionLifecycleTests.swift in group children
    anchor = "21549A0830B5DFB9F2E1D233 /* SessionLifecycleTests.swift */,"
    # This appears in the group section (not build file section)
    # Find it in the group children context (after line ~652)
    search_start = c.find("24B2B5244BD64F859A19F172 /* SessionTests.swift */,")
    if search_start == -1:
        print("ERROR: Could not find SessionTests in PlayCoverMCPTests group")
        sys.exit(1)
    idx = c.find(anchor, search_start)
    if idx == -1:
        print("ERROR: Could not find SessionLifecycleTests in PlayCoverMCPTests group")
        sys.exit(1)
    end_of_line = c.find('\n', idx)
    info = files_info["SessionTouchTests.swift"]
    c = c[:end_of_line + 1] + f"\t\t\t\t{info['file_ref_id']} /* SessionTouchTests.swift */,\n" + c[end_of_line + 1:]

    # === 6. Add to PlayCoverMCP Sources build phase ===
    # After SessionResources.swift in Sources (near line 1226)
    anchor = "2DAF33DFB3A42A90C36E50D6 /* SessionResources.swift in Sources */,"
    idx = c.find(anchor)
    if idx == -1:
        print("ERROR: Could not find SessionResources in PlayCoverMCP Sources")
        sys.exit(1)
    end_of_line = c.find('\n', idx)

    sources_insert = ""
    for name in ["TouchService.swift", "TouchTools.swift"]:
        info = files_info[name]
        sources_insert += f"\t\t\t\t{info['build_file_mcp_id']} /* {name} in Sources */,\n"
    c = c[:end_of_line + 1] + sources_insert + c[end_of_line + 1:]

    # === 7. Add to PlayCoverMCPTests Sources build phase ===
    # After SessionLifecycleTests.swift in Tests Sources (near line 1285)
    anchor = "C9B77BE0F966388DE55DF2CC /* SessionLifecycleTests.swift in Sources */,"
    # Need to find in the test target sources, not the MCP target sources
    # The test target sources section comes after the MCP target sources section
    search_start = c.find("0A8EEBDAD8704A82BD740815 /* Sources */")
    if search_start == -1:
        print("ERROR: Could not find PlayCoverMCPTests Sources build phase")
        sys.exit(1)
    idx = c.find(anchor, search_start)
    if idx == -1:
        print("ERROR: Could not find SessionLifecycleTests in PlayCoverMCPTests Sources")
        sys.exit(1)
    end_of_line = c.find('\n', idx)

    sources_insert = ""
    # Add all source files to test target (service files + test file)
    for name in ["TouchService.swift", "TouchTools.swift"]:
        info = files_info[name]
        sources_insert += f"\t\t\t\t{info['build_file_test_id']} /* {name} in Sources */,\n"
    info = files_info["SessionTouchTests.swift"]
    sources_insert += f"\t\t\t\t{info['build_file_test_id']} /* SessionTouchTests.swift in Sources */,\n"
    c = c[:end_of_line + 1] + sources_insert + c[end_of_line + 1:]

    # Write back
    with open(PBX, 'w') as f:
        f.write(c)

    # Verify
    result = run(['plutil', '-lint', PBX])
    if 'OK' not in result:
        print(f"ERROR: pbxproj lint failed after changes: {result}")
        print("Restoring...")
        run(['git', 'checkout', '--', PBX])
        sys.exit(1)

    print("OK: All S02 files added to pbxproj")

if __name__ == '__main__':
    main()
