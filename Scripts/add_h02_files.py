#!/usr/bin/env python3
"""Add H02 files (Task, Logging, Error) to PlayCover.xcodeproj."""

import os, sys, subprocess, uuid

PBX = os.path.join(os.path.dirname(__file__), "..", "PlayCover.xcodeproj", "project.pbxproj")
PBXDIR = os.path.dirname(PBX)

MCP_SRC_PHASE = "1846259310234BF491844A47"  # PlayCoverMCP Sources
TST_SRC_PHASE = "0A8EEBDAD8704A82BD740815"  # PlayCoverMCPTests Sources
MCP_GRP = "1BC53A43D5794DA3AE83DC73"          # PlayCoverMCP group
TST_GRP = "655C253FCA19492C8624612B"          # PlayCoverMCPTests group

gid = lambda: uuid.uuid4().hex[:24].upper()

# New source files: (relative_path, filename, group_uuid_for_dir)
# We'll create new directories: PlayCoverMCP/Tasks/, PlayCoverMCP/Logging/, PlayCoverMCP/Common/
# New source files
src_files = [
    ("PlayCoverMCP/Tasks/TaskManager.swift", "TaskManager.swift", "Tasks"),
    ("PlayCoverMCP/Logging/MCPLogger.swift", "MCPLogger.swift", "Logging"),
    ("PlayCoverMCP/Common/MCPErrorExtensions.swift", "MCPErrorExtensions.swift", "Common"),
]

# New test files
test_files = [
    ("PlayCoverMCPTests/TaskManagerTests.swift", "TaskManagerTests.swift"),
    ("PlayCoverMCPTests/MCPLoggerTests.swift", "MCPLoggerTests.swift"),
    ("PlayCoverMCPTests/MCPErrorExtensionsTests.swift", "MCPErrorExtensionsTests.swift"),
]

def main():
    with open(PBX) as f:
        c = f.read()

    # Generate UUIDs
    # Source: fileRef + buildFile for MCP target + buildFile for Test target
    src_refs = [gid() for _ in src_files]
    src_bf_mcp = [gid() for _ in src_files]
    src_bf_tst = [gid() for _ in src_files]

    # Test: fileRef + buildFile
    tst_refs = [gid() for _ in test_files]
    tst_bf = [gid() for _ in test_files]

    # Group UUIDs for new directories
    tasks_grp = gid()
    logging_grp = gid()
    common_grp = gid()

    # 1. PBXBuildFile section — add all build file entries
    bf_entries = []
    for i, (_, name, _) in enumerate(src_files):
        bf_entries.append(f"\t\t{src_bf_mcp[i]} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {src_refs[i]} /* {name} */; }};")
        bf_entries.append(f"\t\t{src_bf_tst[i]} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {src_refs[i]} /* {name} */; }};")
    for i, (_, name) in enumerate(test_files):
        bf_entries.append(f"\t\t{tst_bf[i]} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {tst_refs[i]} /* {name} */; }};")
    
    bf_block = "\n".join(bf_entries)
    c = c.replace("/* End PBXBuildFile section */", bf_block + "\n/* End PBXBuildFile section */")

    # 2. PBXFileReference section
    fr_entries = []
    for i, (path, name, _) in enumerate(src_files):
        # path is relative to group, name is the filename
        dir_name = os.path.dirname(path)
        fr_entries.append(f"\t\t{src_refs[i]} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; name = {name}; path = {name}; sourceTree = \"<group>\"; }};")
    for i, (_, name) in enumerate(test_files):
        fr_entries.append(f"\t\t{tst_refs[i]} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {name}; sourceTree = \"<group>\"; }};")
    
    fr_block = "\n".join(fr_entries)
    c = c.replace("/* End PBXFileReference section */", fr_block + "\n/* End PBXFileReference section */")

    # 3. Add new directory groups before End PBXGroup
    group_entries = [
        f"\t\t{tasks_grp} /* Tasks */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n\t\t\t\t{src_refs[0]} /* TaskManager.swift */,\n\t\t\t);\n\t\t\tpath = Tasks;\n\t\t\tsourceTree = \"<group>\";\n\t\t}};",
        f"\t\t{logging_grp} /* Logging */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n\t\t\t\t{src_refs[1]} /* MCPLogger.swift */,\n\t\t\t);\n\t\t\tpath = Logging;\n\t\t\tsourceTree = \"<group>\";\n\t\t}};",
        f"\t\t{common_grp} /* Common */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n\t\t\t\t{src_refs[2]} /* MCPErrorExtensions.swift */,\n\t\t\t);\n\t\t\tpath = Common;\n\t\t\tsourceTree = \"<group>\";\n\t\t}};",
    ]
    grp_block = "\n".join(group_entries)
    c = c.replace("/* End PBXGroup section */", grp_block + "\n/* End PBXGroup section */")

    # 4. Add new groups to PlayCoverMCP group children
    old_children = (
        "\t\t\t\t6D5A783BCD8844EF91870961 /* HostServices */,\n"
        "\t\t\t\tE72C14DFDBA1436DB1BCDFCB /* Session */,\n"
        "\t\t\t\tB2DF4C9855164E3FB4E71130 /* Protocol */,\n"
        "\t\t\t\t3874B7FA90B5433F896B4A15 /* Transport */,\n"
        "\t\t\t\t808D969E625048FA8CF52E42 /* Registry */,\n"
        "\t\t\t\tCAB6818880264CE18D074061 /* Server */,\n"
        "\t\t\t\tA5D9C44AF910418082DE86B6 /* main.swift */,\n"
    )
    new_children = (
        "\t\t\t\t6D5A783BCD8844EF91870961 /* HostServices */,\n"
        "\t\t\t\tE72C14DFDBA1436DB1BCDFCB /* Session */,\n"
        "\t\t\t\tB2DF4C9855164E3FB4E71130 /* Protocol */,\n"
        "\t\t\t\t3874B7FA90B5433F896B4A15 /* Transport */,\n"
        "\t\t\t\t808D969E625048FA8CF52E42 /* Registry */,\n"
        "\t\t\t\tCAB6818880264CE18D074061 /* Server */,\n"
        f"\t\t\t\t{tasks_grp} /* Tasks */,\n"
        f"\t\t\t\t{logging_grp} /* Logging */,\n"
        f"\t\t\t\t{common_grp} /* Common */,\n"
        "\t\t\t\tA5D9C44AF910418082DE86B6 /* main.swift */,\n"
    )
    c = c.replace(old_children, new_children)

    # 5. Add test files to PlayCoverMCPTests group
    old_tst_children = (
        "\t\t\t\t3FEDED914AC74CBE8DB5241C /* MCPSmokeTests.swift */,\n"
        "\t\t\t\t7ABE004742B3446A8C66A3A1 /* Info.plist */,"
    )
    new_tst_children = (
        "\t\t\t\t3FEDED914AC74CBE8DB5241C /* MCPSmokeTests.swift */,\n"
        f"\t\t\t\t{tst_refs[0]} /* TaskManagerTests.swift */,\n"
        f"\t\t\t\t{tst_refs[1]} /* MCPLoggerTests.swift */,\n"
        f"\t\t\t\t{tst_refs[2]} /* MCPErrorExtensionsTests.swift */,\n"
        "\t\t\t\t7ABE004742B3446A8C66A3A1 /* Info.plist */,"
    )
    c = c.replace(old_tst_children, new_tst_children)

    # 6. Add source files to PlayCoverMCP Sources build phase
    old_mcp_src = (
        "\t\t\t\tF9C5147CC3B0413EB2E0F011 /* MCPServer.swift in Sources */,\n"
        "\t\t\t);\n"
        "\t\t\trunOnlyForDeploymentPostprocessing = 0;\n"
        "\t\t};\n"
        "/* End PBXSourcesBuildPhase section */"
    )
    new_mcp_src = (
        "\t\t\t\tF9C5147CC3B0413EB2E0F011 /* MCPServer.swift in Sources */,\n"
        f"\t\t\t\t{src_bf_mcp[0]} /* TaskManager.swift in Sources */,\n"
        f"\t\t\t\t{src_bf_mcp[1]} /* MCPLogger.swift in Sources */,\n"
        f"\t\t\t\t{src_bf_mcp[2]} /* MCPErrorExtensions.swift in Sources */,\n"
        "\t\t\t);\n"
        "\t\t\trunOnlyForDeploymentPostprocessing = 0;\n"
        "\t\t};\n"
        "/* End PBXSourcesBuildPhase section */"
    )
    c = c.replace(old_mcp_src, new_mcp_src)

    # 7. Add files to PlayCoverMCPTests Sources build phase
    old_tst_src = (
        "\t\t\t\tA10E57289D0C4907BF8E3870 /* MCPSmokeTests.swift in Sources */,\n"
        "\t\t\t);\n"
        "\t\t\trunOnlyForDeploymentPostprocessing = 0;\n"
        "\t\t};\n"
        "/* End PBXSourcesBuildPhase section */"
    )
    new_tst_src = (
        "\t\t\t\tA10E57289D0C4907BF8E3870 /* MCPSmokeTests.swift in Sources */,\n"
        f"\t\t\t\t{src_bf_tst[0]} /* TaskManager.swift in Sources */,\n"
        f"\t\t\t\t{src_bf_tst[1]} /* MCPLogger.swift in Sources */,\n"
        f"\t\t\t\t{src_bf_tst[2]} /* MCPErrorExtensions.swift in Sources */,\n"
        f"\t\t\t\t{tst_bf[0]} /* TaskManagerTests.swift in Sources */,\n"
        f"\t\t\t\t{tst_bf[1]} /* MCPLoggerTests.swift in Sources */,\n"
        f"\t\t\t\t{tst_bf[2]} /* MCPErrorExtensionsTests.swift in Sources */,\n"
        "\t\t\t);\n"
        "\t\t\trunOnlyForDeploymentPostprocessing = 0;\n"
        "\t\t};\n"
        "/* End PBXSourcesBuildPhase section */"
    )
    c = c.replace(old_tst_src, new_tst_src)

    # Check braces
    depth = 0
    for ch in c:
        if ch == '{': depth += 1
        elif ch == '}': depth -= 1
    if depth != 0:
        print(f"FAIL: brace balance issue (depth={depth})")
        sys.exit(1)
    print("OK: brace balance")

    with open(PBX, 'w') as f:
        f.write(c)

    r = subprocess.run(['xcodebuild', '-project', os.path.join(PBXDIR, 'PlayCover.xcodeproj'), '-list'],
                       capture_output=True, text=True, cwd=PBXDIR, timeout=15)
    if 'damaged' in r.stderr or 'parse error' in r.stderr.lower():
        print(f"FAIL: xcodebuild -list: {r.stderr.strip()[:200]}")
        sys.exit(1)
    print("OK: xcodebuild -list")
    
    print(f"Tasks group ID: {tasks_grp}")
    print(f"Logging group ID: {logging_grp}")
    print(f"Common group ID: {common_grp}")

if __name__ == "__main__":
    main()
