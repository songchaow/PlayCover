#!/usr/bin/env python3
"""Add MCP source files to both PlayCoverMCP and PlayCoverMCPTests targets.
Source files are compiled into both targets (simple approach, no framework needed)."""

import os, sys, subprocess, uuid

PBX = os.path.join(os.path.dirname(__file__), "..", "PlayCover.xcodeproj", "project.pbxproj")

# Known IDs
MCP_SRC_PHASE = "1846259310234BF491844A47"
MCP_GRP = "1BC53A43D5794DA3AE83DC73"
TST_SRC_PHASE = "0A8EEBDAD8704A82BD740815"

gid = lambda: uuid.uuid4().hex[:24].upper()

def main():
    with open(PBX) as f:
        c = f.read()

    fr = [gid() for _ in range(5)]
    fb_mcp = [gid() for _ in range(5)]   # build files for MCP target
    fb_tst = [gid() for _ in range(5)]   # build files for test target
    pg = gid(); tg = gid(); rg = gid(); sg = gid()

    files = [
        ("MCPTypes.swift", "MCPTypes.swift"),
        ("StdioTransport.swift", "StdioTransport.swift"),
        ("ToolRegistry.swift", "ToolRegistry.swift"),
        ("ResourceRegistry.swift", "ResourceRegistry.swift"),
        ("MCPServer.swift", "MCPServer.swift"),
    ]

    tfr = [gid() for _ in range(4)]
    tfb = [gid() for _ in range(4)]

    test_files = [
        ("MCPProtocolTests.swift", "MCPProtocolTests.swift"),
        ("MCPServerTests.swift", "MCPServerTests.swift"),
        ("MCPRegistryTests.swift", "MCPRegistryTests.swift"),
        ("MCPSmokeTests.swift", "MCPSmokeTests.swift"),
    ]

    # 1. PBXBuildFile: source files in MCP target + test target, test files in test target
    bf = "\n".join(
        f"\t\t{fb_mcp[i]} /* {n} in Sources */ = {{isa = PBXBuildFile; fileRef = {fr[i]} /* {n} */; }};"
        for i, (_, n) in enumerate(files)
    )
    bf += "\n".join(
        f"\t\t{fb_tst[i]} /* {n} in Sources */ = {{isa = PBXBuildFile; fileRef = {fr[i]} /* {n} */; }};"
        for i, (_, n) in enumerate(files)
    )
    bf += "\n".join(
        f"\t\t{tfb[i]} /* {n} in Sources */ = {{isa = PBXBuildFile; fileRef = {tfr[i]} /* {n} */; }};"
        for i, (_, n) in enumerate(test_files)
    )
    c = c.replace("/* End PBXBuildFile section */", bf + "\n/* End PBXBuildFile section */")

    # 2. PBXFileReference
    src_fr = "\n".join(
        f"\t\t{fr[i]} /* {n} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; name = {n}; path = {n}; sourceTree = \"<group>\"; }};"
        for i, (_, n) in enumerate(files)
    )
    test_fr = "\n".join(
        f"\t\t{tfr[i]} /* {n} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {n}; sourceTree = \"<group>\"; }};"
        for i, (_, n) in enumerate(test_files)
    )
    c = c.replace("/* End PBXFileReference section */", src_fr + "\n" + test_fr + "\n/* End PBXFileReference section */")

    # 3. PBXGroup sub-groups
    gs = (
        f"\t\t{pg} /* Protocol */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n\t\t\t\t{fr[0]} /* MCPTypes.swift */,\n\t\t\t);\n\t\t\tpath = Protocol;\n\t\t\tsourceTree = \"<group>\";\n\t\t}};\n"
        f"\t\t{tg} /* Transport */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n\t\t\t\t{fr[1]} /* StdioTransport.swift */,\n\t\t\t);\n\t\t\tpath = Transport;\n\t\t\tsourceTree = \"<group>\";\n\t\t}};\n"
        f"\t\t{rg} /* Registry */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n\t\t\t\t{fr[2]} /* ToolRegistry.swift */,\n\t\t\t\t{fr[3]} /* ResourceRegistry.swift */,\n\t\t\t);\n\t\t\tpath = Registry;\n\t\t\tsourceTree = \"<group>\";\n\t\t}};\n"
        f"\t\t{sg} /* Server */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n\t\t\t\t{fr[4]} /* MCPServer.swift */,\n\t\t\t);\n\t\t\tpath = Server;\n\t\t\tsourceTree = \"<group>\";\n\t\t}};"
    )
    c = c.replace("/* End PBXGroup section */", gs + "\n/* End PBXGroup section */")

    # 4. Update PlayCoverMCP group
    old_grp = (
        "\t\t\t\t6D5A783BCD8844EF91870961 /* HostServices */,\n"
        "\t\t\t\tE72C14DFDBA1436DB1BCDFCB /* Session */,\n"
        "\t\t\t\tA5D9C44AF910418082DE86B6 /* main.swift */,\n"
        "\t\t\t\t7ECF709C0250403AB44D2771 /* Info.plist */,"
    )
    new_grp = (
        "\t\t\t\t6D5A783BCD8844EF91870961 /* HostServices */,\n"
        "\t\t\t\tE72C14DFDBA1436DB1BCDFCB /* Session */,\n"
        f"\t\t\t\t{pg} /* Protocol */,\n"
        f"\t\t\t\t{tg} /* Transport */,\n"
        f"\t\t\t\t{rg} /* Registry */,\n"
        f"\t\t\t\t{sg} /* Server */,\n"
        "\t\t\t\tA5D9C44AF910418082DE86B6 /* main.swift */,\n"
        "\t\t\t\t7ECF709C0250403AB44D2771 /* Info.plist */,"
    )
    c = c.replace(old_grp, new_grp)

    # 5. Update PlayCoverMCPTests group
    old_test_grp = (
        "\t\t\t\t1FDA695ADCBB4DD192ABF5DE /* PlayCoverMCPTests.swift */,\n"
        "\t\t\t\t7ABE004742B3446A8C66A3A1 /* Info.plist */,"
    )
    new_test_grp = (
        "\t\t\t\t1FDA695ADCBB4DD192ABF5DE /* PlayCoverMCPTests.swift */,\n"
        f"\t\t\t\t{tfr[0]} /* MCPProtocolTests.swift */,\n"
        f"\t\t\t\t{tfr[1]} /* MCPServerTests.swift */,\n"
        f"\t\t\t\t{tfr[2]} /* MCPRegistryTests.swift */,\n"
        f"\t\t\t\t{tfr[3]} /* MCPSmokeTests.swift */,\n"
        "\t\t\t\t7ABE004742B3446A8C66A3A1 /* Info.plist */,"
    )
    c = c.replace(old_test_grp, new_test_grp)

    # 6. Add source files to PlayCoverMCP Sources build phase
    src_entries = ",\n".join(f"\t\t\t\t{fb_mcp[i]} /* {files[i][1]} in Sources */" for i in range(5))
    c = c.replace(
        f"\t\t{MCP_SRC_PHASE} /* Sources */ = {{\n\t\t\tisa = PBXSourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n\t\t\t\tF8498CF92E3B416D9577B817 /* main.swift in Sources */,\n\t\t\t);",
        f"\t\t{MCP_SRC_PHASE} /* Sources */ = {{\n\t\t\tisa = PBXSourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n\t\t\t\tF8498CF92E3B416D9577B817 /* main.swift in Sources */,\n{src_entries},\n\t\t\t);"
    )

    # 7. Add source files + test files to PlayCoverMCPTests Sources build phase
    test_src_entries = ",\n".join(f"\t\t\t\t{fb_tst[i]} /* {files[i][1]} in Sources */" for i in range(5))
    test_entries = ",\n".join(f"\t\t\t\t{tfb[i]} /* {test_files[i][1]} in Sources */" for i in range(4))
    c = c.replace(
        f"\t\t{TST_SRC_PHASE} /* Sources */ = {{\n\t\t\tisa = PBXSourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n\t\t\t\tB73085F57C194B8FBE136049 /* PlayCoverMCPTests.swift in Sources */,\n\t\t\t);",
        f"\t\t{TST_SRC_PHASE} /* Sources */ = {{\n\t\t\tisa = PBXSourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n\t\t\t\tB73085F57C194B8FBE136049 /* PlayCoverMCPTests.swift in Sources */,\n{test_src_entries},\n{test_entries},\n\t\t\t);"
    )

    with open(PBX, 'w') as f:
        f.write(c)

    print("Done! Added:")
    print(f"  {len(files)} source files to PlayCoverMCP target")
    print(f"  {len(files)} source files (with -w) to PlayCoverMCPTests target")
    print(f"  {len(test_files)} test files to PlayCoverMCPTests target")

if __name__ == "__main__":
    main()
