#!/usr/bin/env python3
"""Add H04 files (Shell.swift, InstallerService.swift, InstallerTools.swift, InstallerServiceTests.swift)
to PlayCoverMCP and PlayCoverMCPTests targets in PlayCover.xcodeproj."""

import os, sys, subprocess, uuid

PBX = os.path.join(os.path.dirname(__file__), "..", "PlayCover.xcodeproj", "project.pbxproj")
PBXDIR = os.path.dirname(PBX)

gid = lambda: uuid.uuid4().hex[:24].upper()

def main():
    with open(PBX) as f:
        c = f.read()

    # New files to add
    new_files = [
        ("PlayCoverMCP/HostServices/Shell.swift", "Shell.swift", "MCP_SOURCES"),
        ("PlayCoverMCP/HostServices/Install/InstallerService.swift", "InstallerService.swift", "MCP_SOURCES"),
        ("PlayCoverMCP/Tools/InstallerTools.swift", "InstallerTools.swift", "MCP_SOURCES"),
        ("PlayCoverMCPTests/InstallerServiceTests.swift", "InstallerServiceTests.swift", "TEST_SOURCES"),
    ]

    # Generate IDs
    file_refs = {}
    build_files = {}
    for path, name, target in new_files:
        file_refs[name] = gid()
        build_files[name] = gid()

    # PlayCoverMCP Sources build phase ID
    MCP_SOURCES = "1846259310234BF491844A47"
    # PlayCoverMCPTests Sources build phase ID
    TEST_SOURCES = "0A8EEBDAD8704A82BD740815"

    # HostServices group - find existing or create
    HOST_SERVICES_GRP = "6D5A783BCD8844EF91870961"

    # 1. PBXBuildFile entries
    bf_additions = ""
    for path, name, target in new_files:
        bf_additions += f'\t\t{build_files[name]} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {file_refs[name]} /* {name} */; }};\n'
    c = c.replace("/* End PBXBuildFile section */", bf_additions + "/* End PBXBuildFile section */")

    # 2. PBXFileReference entries
    fr_additions = ""
    for path, name, target in new_files:
        fr_additions += f'\t\t{file_refs[name]} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; name = {name}; path = {path}; sourceTree = "<group>"; }};\n'
    c = c.replace("/* End PBXFileReference section */", fr_additions + "/* End PBXFileReference section */")

    # 3. Add Install subdirectory group under HostServices
    install_grp_id = gid()
    install_grp = (
        f'\t\t{install_grp_id} /* Install */ = {{\n'
        f'\t\t\tisa = PBXGroup;\n'
        f'\t\t\tchildren = (\n'
        f'\t\t\t\t{file_refs["InstallerService.swift"]} /* InstallerService.swift */,\n'
        f'\t\t\t);\n'
        f'\t\t\tpath = Install;\n'
        f'\t\t\tsourceTree = "<group>";\n'
        f'\t\t}};\n'
    )
    c = c.replace("/* End PBXGroup section */", install_grp + "/* End PBXGroup section */")

    # 4. Add Shell.swift to HostServices group and Install group
    # Add Shell.swift file ref to HostServices group
    hs_children_pattern = f'\t\t\t{HOST_SERVICES_GRP} /* HostServices */ = {{\n\t\t\t\tisa = PBXGroup;\n\t\t\t\tchildren = (\n'
    hs_new_children = (
        f'\t\t\t{HOST_SERVICES_GRP} /* HostServices */ = {{\n'
        f'\t\t\t\tisa = PBXGroup;\n'
        f'\t\t\t\tchildren = (\n'
        f'\t\t\t\t\t{install_grp_id} /* Install */,\n'
        f'\t\t\t\t\t{file_refs["Shell.swift"]} /* Shell.swift */,\n'
    )
    c = c.replace(hs_children_pattern, hs_new_children)

    # 5. Add InstallerTools.swift to Tools group - find the Tools group
    # Need to find the Tools group in PlayCoverMCP group and add the file
    # Look for the pattern where Tools group children are listed
    tools_pattern_candidates = [
        'children = (\n\t\t\t\t\tE63DA694C7ED40BCB6E350BE /* AppTools.swift */,\n',
        'children = (\n\t\t\t\t\t99C5D776BEFF46FAAF37124A /* AppResources.swift */,\n',
    ]
    for pat in tools_pattern_candidates:
        if pat in c:
            # This is likely in the Tools group
            # Find the enclosing group to check if it's the Tools group
            idx = c.index(pat)
            # Look backwards for "Tools"
            preceding = c[max(0, idx-500):idx]
            if 'Tools */' in preceding:
                c = c.replace(
                    pat,
                    pat.rstrip() + f'\n\t\t\t\t\t{build_files["InstallerTools.swift"]} /* InstallerTools.swift */,\n'
                    if "InstallerTools" not in c.split(pat)[1][:200]
                    else pat
                )
                break

    # Actually, let me find the Tools group more reliably
    # Search for the Tools group definition
    import re
    tools_group_match = re.search(r'(/\* Tools \*/ = \{\s*isa = PBXGroup;\s*children = \(\s*)(.*?)(\s*\);)',
                                  c, re.DOTALL)
    if tools_group_match:
        prefix = tools_group_match.group(1)
        children = tools_group_match.group(2)
        suffix = tools_group_match.group(3)
        if "InstallerTools" not in children:
            new_children = children.rstrip() + f'\n\t\t\t\t\t{file_refs["InstallerTools.swift"]} /* InstallerTools.swift */,'
            c = c.replace(tools_group_match.group(0), prefix + new_children + suffix)

    # 6. Add sources to build phases
    # Add to PlayCoverMCP Sources
    mcp_src_end = f'\t\t{MCP_SOURCES} /* Sources */ = {{'
    # Find the closing of MCP sources files list
    mcp_files_end = '\t\t);'
    # Insert before the closing );
    for path, name, target in new_files:
        if target == "MCP_SOURCES":
            # Find the last file in MCP sources and add after it
            insert_point = f'\t\t\t\t99C5D776BEFF46FAAF37124A /* AppResources.swift in Sources */,\n'
            replacement = insert_point + f'\t\t\t\t{build_files[name]} /* {name} in Sources */,\n'
            if replacement not in c:
                c = c.replace(insert_point, replacement, 1)

    # Add to PlayCoverMCPTests Sources
    for path, name, target in new_files:
        if target == "TEST_SOURCES":
            insert_point = f'\t\t\t\t47A8288D276C4E65A6736A7C /* AppToolsAndResourcesTests.swift in Sources */,\n'
            replacement = insert_point + f'\t\t\t\t{build_files[name]} /* {name} in Sources */,\n'
            if replacement not in c:
                c = c.replace(insert_point, replacement, 1)

    # Check brace balance
    depth = 0
    for ch in c:
        if ch == '{': depth += 1
        elif ch == '}': depth -= 1
        if depth < 0:
            print("FAIL: brace balance issue")
            sys.exit(1)
    if depth != 0:
        print(f"FAIL: brace balance issue (depth={depth})")
        sys.exit(1)
    print("OK: brace balance")

    # Save
    with open(PBX, 'w') as f:
        f.write(c)

    # Verify
    r = subprocess.run(['xcodebuild', '-project', os.path.join(PBXDIR, 'PlayCover.xcodeproj'), '-list'],
                       capture_output=True, text=True, cwd=PBXDIR, timeout=15)
    if 'damaged' in r.stderr or 'parse error' in r.stderr.lower():
        print(f"FAIL: xcodebuild -list: {r.stderr.strip()[:200]}")
        sys.exit(1)
    print("OK: xcodebuild -list")
    print(f"Added files:")
    for path, name, target in new_files:
        print(f"  {name} -> {target}")

if __name__ == "__main__":
    main()
