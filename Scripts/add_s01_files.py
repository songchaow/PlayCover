#!/usr/bin/env python3
"""Add S01 files to PlayCover.xcodeproj."""

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

    # Check files don't already exist
    for name in ["SessionService.swift", "SessionTools.swift", "SessionResources.swift", "SessionLifecycleTests.swift"]:
        if f"/* {name} */" in c:
            print(f"SKIP: {name} already in pbxproj")
            # Reset file to avoid partial state
            continue

    # Files to add
    files = [
        ("PlayCoverMCP/Session/SessionService.swift", "Session"),
        ("PlayCoverMCP/Tools/Session/SessionTools.swift", "Tools/Session (new group)"),
        ("PlayCoverMCP/Resources/Session/SessionResources.swift", "Resources/Session (new group)"),
        ("PlayCoverMCPTests/SessionLifecycleTests.swift", "PlayCoverMCPTests root group"),
    ]

    entries = {}
    for filepath, location in files:
        name = os.path.basename(filepath)
        file_ref_id = gen_id()
        build_file_mcp_id = gen_id()
        build_file_test_id = gen_id()
        entries[name] = {
            "filepath": filepath,
            "name": name,
            "file_ref_id": file_ref_id,
            "build_file_mcp_id": build_file_mcp_id,
            "build_file_test_id": build_file_test_id,
            "location": location,
        }

    # === 1. Add PBXBuildFile entries ===
    # Find the last PBXBuildFile entry (near SessionTests line 161)
    # Insert after the last SessionTests.swift in Sources (line ~161)
    anchor = "87BEE38E84974F38B193EC3D /* SessionTests.swift in Sources */"
    idx = c.find(anchor)
    if idx == -1:
        print("ERROR: Could not find SessionTests anchor in PBXBuildFile section")
        sys.exit(1)

    # Find end of this line
    end_of_line = c.find('\n', idx)
    
    insertions = ""
    for name, info in entries.items():
        # PlayCoverMCP Sources build file
        insertions += f"\t\t{info['build_file_mcp_id']} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {info['file_ref_id']} /* {name} */; }};\n"
        # PlayCoverMCPTests Sources build file
        insertions += f"\t\t{info['build_file_test_id']} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {info['file_ref_id']} /* {name} */; }};\n"

    c = c[:end_of_line + 1] + insertions + c[end_of_line + 1:]

    # === 2. Add PBXFileReference entries ===
    # Find the last PBXFileReference (near SessionTests line 340)
    anchor = "24B2B5244BD64F859A19F172 /* SessionTests.swift */"
    idx = c.find(anchor)
    if idx == -1:
        print("ERROR: Could not find SessionTests anchor in PBXFileReference section")
        sys.exit(1)
    end_of_line = c.find('\n', idx)
    
    insertions = ""
    for name, info in entries.items():
        insertions += f"\t\t{info['file_ref_id']} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; name = {name}; path = {name}; sourceTree = \"<group>\"; }};\n"

    c = c[:end_of_line + 1] + insertions + c[end_of_line + 1:]

    # === 3. Add to Session group ===
    # Session group children (line ~812-816), add SessionService.swift
    anchor = "E9C8C42E2F5F4F0098953ED2 /* RegistrationListener.swift */,"
    idx = c.find(anchor)
    if idx == -1:
        print("ERROR: Could not find RegistrationListener anchor in Session group")
        sys.exit(1)
    end_of_line = c.find('\n', idx)
    info = entries["SessionService.swift"]
    name_str = info['name']
    c = c[:end_of_line + 1] + f"\t\t\t\t{info['file_ref_id']} /* {name_str} */,\n" + c[end_of_line + 1:]

    # === 4. Create Tools/Session group and add to Tools group ===
    # Tools group (line ~719-728)
    # Find "3AD721A147D7400EAD4E2FA2 /* Tools */"
    session_tools_group_id = gen_id()
    tools_info = entries["SessionTools.swift"]
    
    # Create the Session subgroup before the Tools group
    session_group_block = f"\t\t{session_tools_group_id} /* Session */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n\t\t\t\t{tools_info['file_ref_id']} /* {tools_info['name']} */,\n\t\t\t);\n\t\t\tpath = Session;\n\t\t\tsourceTree = \"<group>\";\n\t\t}};\n"
    
    # Insert before the Tools group definition
    anchor = "\t\t3AD721A147D7400EAD4E2FA2 /* Tools */ = {"
    idx = c.find(anchor)
    if idx == -1:
        print("ERROR: Could not find Tools group")
        sys.exit(1)
    c = c[:idx] + session_group_block + c[idx:]

    # Add Session subgroup to Tools group children
    anchor = "\t\t\t\t19B42407C52741048C0D0A94 /* InstallerTools.swift */,"
    idx = c.find(anchor)
    if idx == -1:
        print("ERROR: Could not find InstallerTools anchor in Tools group")
        sys.exit(1)
    end_of_line = c.find('\n', idx)
    c = c[:end_of_line + 1] + f"\t\t\t\t{session_tools_group_id} /* Session */,\n" + c[end_of_line + 1:]

    # === 5. Create Resources/Session group and add to Resources group ===
    session_resources_group_id = gen_id()
    resources_info = entries["SessionResources.swift"]
    
    session_resources_group_block = f"\t\t{session_resources_group_id} /* Session */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n\t\t\t\t{resources_info['file_ref_id']} /* {resources_info['name']} */,\n\t\t\t);\n\t\t\tpath = Session;\n\t\t\tsourceTree = \"<group>\";\n\t\t}};\n"
    
    # Insert before the Resources group
    anchor = "\t\t40738BD4E1A9446E8BB6B77A /* Resources */ = {"
    idx = c.find(anchor)
    if idx == -1:
        print("ERROR: Could not find Resources group")
        sys.exit(1)
    c = c[:idx] + session_resources_group_block + c[idx:]

    # Add Session subgroup to Resources group children
    anchor = "\t\t\t\tA1B2C3D4E5F60006AAAABBBB /* SettingsResources.swift */,"
    idx = c.find(anchor)
    if idx == -1:
        print("ERROR: Could not find SettingsResources anchor in Resources group")
        sys.exit(1)
    end_of_line = c.find('\n', idx)
    c = c[:end_of_line + 1] + f"\t\t\t\t{session_resources_group_id} /* Session */,\n" + c[end_of_line + 1:]

    # === 6. Add SessionLifecycleTests.swift to PlayCoverMCPTests group ===
    # Find the PlayCoverMCPTests group
    test_info = entries["SessionLifecycleTests.swift"]
    # Look for "24B2B5244BD64F859A19F172 /* SessionTests.swift */," in the children
    anchor = "\t\t\t\t24B2B5244BD64F859A19F172 /* SessionTests.swift */,"
    idx = c.find(anchor)
    if idx == -1:
        print("ERROR: Could not find SessionTests in PlayCoverMCPTests group")
        sys.exit(1)
    end_of_line = c.find('\n', idx)
    c = c[:end_of_line + 1] + f"\t\t\t\t{test_info['file_ref_id']} /* {test_info['name']} */,\n" + c[end_of_line + 1:]

    # === 7. Add to PlayCoverMCP Sources build phase ===
    # Find the last Session file in PlayCoverMCP Sources (line ~1192)
    anchor = "AB50E2E1A20C462897A04A29 /* RegistrationListener.swift in Sources */,"
    idx = c.find(anchor)
    if idx == -1:
        print("ERROR: Could not find RegistrationListener in PlayCoverMCP Sources")
        sys.exit(1)
    end_of_line = c.find('\n', idx)
    
    sources_insert = ""
    for name, info in entries.items():
        sources_insert += f"\t\t\t\t{info['build_file_mcp_id']} /* {name} in Sources */,\n"
    c = c[:end_of_line + 1] + sources_insert + c[end_of_line + 1:]

    # === 8. Add to PlayCoverMCPTests Sources build phase ===
    # Find SessionTests in PlayCoverMCPTests Sources (line ~1247)
    anchor = "87BEE38E84974F38B193EC3D /* SessionTests.swift in Sources */,"
    idx = c.find(anchor)
    if idx == -1:
        print("ERROR: Could not find SessionTests in PlayCoverMCPTests Sources")
        sys.exit(1)
    end_of_line = c.find('\n', idx)
    
    sources_insert = ""
    for name, info in entries.items():
        sources_insert += f"\t\t\t\t{info['build_file_test_id']} /* {name} in Sources */,\n"
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

    print("OK: All S01 files added to pbxproj")

if __name__ == '__main__':
    main()
