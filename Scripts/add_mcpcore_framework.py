#!/usr/bin/env python3
"""Add PlayCoverMCPCore framework target to PlayCover.xcodeproj.
Step-by-step with xcodebuild build verification at the end."""

import os, sys, subprocess, uuid

PBX = os.path.join(os.path.dirname(__file__), "..", "PlayCover.xcodeproj", "project.pbxproj")
PBXDIR = os.path.dirname(PBX)
PO = "8783CFEF26B8C52D00171041"
MCP_TGT = "935F3C0F7A044595BF595D4E"
MCP_FW = "1264A262BDD141FB873E242A"
TST_TGT = "C3598980EF9342ABA562BD5E"
TST_FW = "3BB65D7B5C3E48A0BB046CD8"
MCP_GRP = "1BC53A43D5794DA3AE83DC73"
PROD_GRP = "8783CFF826B8C52D00171041"
TST_REL = "C5F24B52E47C4C638BD4156C"
TST_NGT = "13792A782FB747A1ADD8E81B"
TST_DEP = "03B84BE5122A47A5A2B7CE62"
TST_PROXY = "6C00AF96D6104C1FB53EFD41"

gid = lambda: uuid.uuid4().hex[:24].upper()

def verify_list(content, step_name):
    """Verify with xcodebuild -list."""
    with open(PBX, 'w') as f:
        f.write(content)
    r = subprocess.run(['xcodebuild', '-project', os.path.join(PBXDIR, 'PlayCover.xcodeproj'), '-list'],
                       capture_output=True, text=True, cwd=PBXDIR, timeout=15)
    if 'damaged' in r.stderr or 'parse error' in r.stderr.lower():
        print(f"  FAIL [{step_name}]: {r.stderr.strip()[:120]}")
        return False
    print(f"  OK   [{step_name}]")
    return True

def check_braces(content):
    depth = 0
    for i, ch in enumerate(content):
        if ch == '{': depth += 1
        elif ch == '}': depth -= 1
        if depth < 0:
            return False, i
    return depth == 0, depth

def main():
    with open(PBX) as f:
        c = f.read()

    # Generate IDs
    ct = gid(); cp = gid(); cs = gid(); cf = gid(); cr = gid()
    cl = gid(); c_rel = gid(); c_ngt = gid()
    fr = [gid() for _ in range(5)]
    fb = [gid() for _ in range(5)]
    pg = gid(); tg = gid(); rg = gid(); sg = gid()
    md = gid(); mp = gid(); td = gid(); tp = gid()
    m2b = gid(); t2b = gid()

    files = [
        ("Protocol/MCPTypes.swift", "MCPTypes.swift"),
        ("Transport/StdioTransport.swift", "StdioTransport.swift"),
        ("Registry/ToolRegistry.swift", "ToolRegistry.swift"),
        ("Registry/ResourceRegistry.swift", "ResourceRegistry.swift"),
        ("Server/MCPServer.swift", "MCPServer.swift"),
    ]

    # Apply all modifications
    # 1. PBXBuildFile
    bf = "\n".join(
        f"\t\t{fb[i]} /* {n} in Sources */ = {{isa = PBXBuildFile; fileRef = {fr[i]} /* {n} */; }};"
        for i, (_, n) in enumerate(files)
    )
    bf += f"\n\t\t{m2b} /* PlayCoverMCPCore in Frameworks */ = {{isa = PBXBuildFile; fileRef = {cp} /* PlayCoverMCPCore.framework */; }};"
    bf += f"\n\t\t{t2b} /* PlayCoverMCPCore in Frameworks */ = {{isa = PBXBuildFile; fileRef = {cp} /* PlayCoverMCPCore.framework */; }};"
    c = c.replace("/* End PBXBuildFile section */", bf + "\n/* End PBXBuildFile section */")

    # 2. PBXContainerItemProxy
    ci = (
        f"\t\t{mp} /* PBXContainerItemProxy */ = {{\n"
        f"\t\t\tisa = PBXContainerItemProxy;\n"
        f"\t\t\tcontainerPortal = {PO} /* Project object */;\n"
        f"\t\t\tproxyType = 1;\n"
        f"\t\t\tremoteGlobalIDString = {ct};\n"
        f"\t\t\tremoteInfo = PlayCoverMCPCore;\n"
        f"\t\t}};\n"
        f"\t\t{tp} /* PBXContainerItemProxy */ = {{\n"
        f"\t\t\tisa = PBXContainerItemProxy;\n"
        f"\t\t\tcontainerPortal = {PO} /* Project object */;\n"
        f"\t\t\tproxyType = 1;\n"
        f"\t\t\tremoteGlobalIDString = {ct};\n"
        f"\t\t\tremoteInfo = PlayCoverMCPCore;\n"
        f"\t\t}};"
    )
    c = c.replace("/* End PBXContainerItemProxy section */", ci + "\n/* End PBXContainerItemProxy section */")

    # 3. PBXFileReference
    frs = "\n".join(
        f"\t\t{fr[i]} /* {n} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; name = {n}; path = {p}; sourceTree = \"<group>\"; }};"
        for i, (p, n) in enumerate(files)
    )
    frs += f"\n\t\t{cp} /* PlayCoverMCPCore.framework */ = {{isa = PBXFileReference; explicitFileType = wrapper.framework; includeInIndex = 0; path = PlayCoverMCPCore.framework; sourceTree = BUILT_PRODUCTS_DIR; }};"
    c = c.replace("/* End PBXFileReference section */", frs + "\n/* End PBXFileReference section */")

    # 4. PBXFrameworksBuildPhase
    c = c.replace(
        "/* End PBXFrameworksBuildPhase section */",
        f"\t\t{cf} /* Frameworks */ = {{\n\t\t\tisa = PBXFrameworksBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};\n/* End PBXFrameworksBuildPhase section */"
    )

    # 5. PBXResourcesBuildPhase
    c = c.replace(
        "/* End PBXResourcesBuildPhase section */",
        f"\t\t{cr} /* Resources */ = {{\n\t\t\tisa = PBXResourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};\n/* End PBXResourcesBuildPhase section */"
    )

    # 6. PBXSourcesBuildPhase
    srcs = ",\n".join(f"\t\t\t\t{fb[i]} /* {files[i][1]} in Sources */" for i in range(5))
    c = c.replace(
        "/* End PBXSourcesBuildPhase section */",
        f"\t\t{cs} /* Sources */ = {{\n\t\t\tisa = PBXSourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n{srcs},\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};\n/* End PBXSourcesBuildPhase section */"
    )

    # 7. PBXTargetDependency
    deps = (
        f"\t\t{md} /* PBXTargetDependency */ = {{\n"
        f"\t\t\tisa = PBXTargetDependency;\n"
        f"\t\t\ttarget = {ct} /* PlayCoverMCPCore */;\n"
        f"\t\t\ttargetProxy = {mp} /* PBXContainerItemProxy */;\n"
        f"\t\t}};\n"
        f"\t\t{td} /* PBXTargetDependency */ = {{\n"
        f"\t\t\tisa = PBXTargetDependency;\n"
        f"\t\t\ttarget = {ct} /* PlayCoverMCPCore */;\n"
        f"\t\t\ttargetProxy = {tp} /* PBXContainerItemProxy */;\n"
        f"\t\t}};"
    )
    c = c.replace("/* End PBXTargetDependency section */", deps + "\n/* End PBXTargetDependency section */")

    # 8. PBXGroup entries
    gs = (
        f"\t\t{pg} /* Protocol */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n\t\t\t\t{fr[0]} /* MCPTypes.swift */,\n\t\t\t);\n\t\t\tpath = Protocol;\n\t\t\tsourceTree = \"<group>\";\n\t\t}};\n"
        f"\t\t{tg} /* Transport */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n\t\t\t\t{fr[1]} /* StdioTransport.swift */,\n\t\t\t);\n\t\t\tpath = Transport;\n\t\t\tsourceTree = \"<group>\";\n\t\t}};\n"
        f"\t\t{rg} /* Registry */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n\t\t\t\t{fr[2]} /* ToolRegistry.swift */,\n\t\t\t\t{fr[3]} /* ResourceRegistry.swift */,\n\t\t\t);\n\t\t\tpath = Registry;\n\t\t\tsourceTree = \"<group>\";\n\t\t}};\n"
        f"\t\t{sg} /* Server */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n\t\t\t\t{fr[4]} /* MCPServer.swift */,\n\t\t\t);\n\t\t\tpath = Server;\n\t\t\tsourceTree = \"<group>\";\n\t\t}};"
    )
    c = c.replace("/* End PBXGroup section */", gs + "\n/* End PBXGroup section */")

    # 9. Update PlayCoverMCP group children
    old = (
        "\t\t\t\t6D5A783BCD8844EF91870961 /* HostServices */,\n"
        "\t\t\t\tE72C14DFDBA1436DB1BCDFCB /* Session */,\n"
        "\t\t\t\tA5D9C44AF910418082DE86B6 /* main.swift */,\n"
        "\t\t\t\t7ECF709C0250403AB44D2771 /* Info.plist */,"
    )
    new = (
        "\t\t\t\t6D5A783BCD8844EF91870961 /* HostServices */,\n"
        "\t\t\t\tE72C14DFDBA1436DB1BCDFCB /* Session */,\n"
        f"\t\t\t\t{pg} /* Protocol */,\n"
        f"\t\t\t\t{tg} /* Transport */,\n"
        f"\t\t\t\t{rg} /* Registry */,\n"
        f"\t\t\t\t{sg} /* Server */,\n"
        "\t\t\t\tA5D9C44AF910418082DE86B6 /* main.swift */,\n"
        "\t\t\t\t7ECF709C0250403AB44D2771 /* Info.plist */,"
    )
    c = c.replace(old, new)

    # 10. Products group
    c = c.replace(
        "\t\t\t\t8783CFF726B8C52D00171041 /* PlayCover.app */,\n\t\t\t);",
        f"\t\t\t\t{cp} /* PlayCoverMCPCore.framework */,\n\t\t\t\t8783CFF726B8C52D00171041 /* PlayCover.app */,\n\t\t\t);"
    )

    # 11. PBXNativeTarget
    c = c.replace(
        "/* End PBXNativeTarget section */",
        f"""\t\t{ct} /* PlayCoverMCPCore */ = {{
\t\t\tisa = PBXNativeTarget;
\t\t\tbuildConfigurationList = {cl} /* Build configuration list for PBXNativeTarget "PlayCoverMCPCore" */;
\t\t\tbuildPhases = (
\t\t\t\t{cs} /* Sources */,
\t\t\t\t{cf} /* Frameworks */,
\t\t\t\t{cr} /* Resources */,
\t\t\t);
\t\t\tbuildRules = (
\t\t\t);
\t\t\tdependencies = (
\t\t\t);
\t\t\tname = PlayCoverMCPCore;
\t\t\tproductName = PlayCoverMCPCore;
\t\t\tproductReference = {cp} /* PlayCoverMCPCore.framework */;
\t\t\tproductType = "com.apple.product-type.framework";
\t\t}};
/* End PBXNativeTarget section */"""
    )

    # 12. Add dep to PlayCoverMCP target
    c = c.replace(
        f"\t\t\tdependencies = (\n\t\t\t);\n\t\t\tname = PlayCoverMCP",
        f"\t\t\tdependencies = (\n\t\t\t\t{md} /* PBXTargetDependency */,\n\t\t\t);\n\t\t\tname = PlayCoverMCP"
    )

    # 13. Add dep to PlayCoverMCPTests target
    c = c.replace(
        f"\t\t\t\t{TST_DEP} /* PBXTargetDependency */,\n\t\t\t);\n\t\t\tname = PlayCoverMCPTests",
        f"\t\t\t\t{TST_DEP} /* PBXTargetDependency */,\n\t\t\t\t{td} /* PBXTargetDependency */,\n\t\t\t);\n\t\t\tname = PlayCoverMCPTests"
    )

    # 14. Add framework link to PlayCoverMCP
    c = c.replace(
        f"\t\t{MCP_FW} /* Frameworks */ = {{\n\t\t\tisa = PBXFrameworksBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n\t\t\t);",
        f"\t\t{MCP_FW} /* Frameworks */ = {{\n\t\t\tisa = PBXFrameworksBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n\t\t\t\t{m2b} /* PlayCoverMCPCore in Frameworks */,\n\t\t\t);"
    )

    # 15. Add framework link to PlayCoverMCPTests
    c = c.replace(
        f"\t\t{TST_FW} /* Frameworks */ = {{\n\t\t\tisa = PBXFrameworksBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n\t\t\t);",
        f"\t\t{TST_FW} /* Frameworks */ = {{\n\t\t\tisa = PBXFrameworksBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n\t\t\t\t{t2b} /* PlayCoverMCPCore in Frameworks */,\n\t\t\t);"
    )

    # 16. XCBuildConfiguration
    fws = (
        "\t\t\t\tARCHS = arm64;\n"
        "\t\t\t\tCODE_SIGN_STYLE = Automatic;\n"
        "\t\t\t\tCOMBINE_HIDPI_IMAGES = YES;\n"
        "\t\t\t\tCURRENT_PROJECT_VERSION = 1;\n"
        "\t\t\t\tDEFINES_MODULE = YES;\n"
        "\t\t\t\tDYLIB_COMPATIBILITY_VERSION = 1;\n"
        "\t\t\t\tDYLIB_CURRENT_VERSION = 1;\n"
        "\t\t\t\tDYLIB_INSTALL_NAME_BASE = @rpath;\n"
        "\t\t\t\tENABLE_HARDENED_RUNTIME = YES;\n"
        "\t\t\t\tEXCLUDED_ARCHS = x86_64;\n"
        "\t\t\t\tGENERATE_INFOPLIST_FILE = YES;\n"
        "\t\t\t\tINSTALL_PATH = \"$(LOCAL_LIBRARY_DIR)/Frameworks\";\n"
        "\t\t\t\tLD_RUNPATH_SEARCH_PATHS = \"$(inherited) @executable_path/../Frameworks @loader_path/Frameworks\";\n"
        "\t\t\t\tMACOSX_DEPLOYMENT_TARGET = 12.0;\n"
        "\t\t\t\tMARKETING_VERSION = 1.0.0;\n"
        "\t\t\t\tONLY_ACTIVE_ARCH = NO;\n"
        "\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = io.playcover.PlayCover.MCPCore;\n"
        "\t\t\t\tPRODUCT_NAME = \"$(TARGET_NAME)\";\n"
        "\t\t\t\tSKIP_INSTALL = YES;\n"
        "\t\t\t\tSWIFT_VERSION = 5.0;\n"
        "\t\t\t\tTARGETED_DEVICE_FAMILY = \"1,2\";\n"
    )
    cfgs = (
        f"\t\t{c_rel} /* Release */ = {{\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {{\n{fws}\t\t\t}};\n\t\t\tname = Release;\n\t\t}};\n"
        f"\t\t{c_ngt} /* Nightly */ = {{\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {{\n{fws}\t\t\t}};\n\t\t\tname = Nightly;\n\t\t}};"
    )
    c = c.replace("/* End XCBuildConfiguration section */", cfgs + "\n/* End XCBuildConfiguration section */")

    # 17. Test LD_RUNPATH
    lr = '\t\t\t\tLD_RUNPATH_SEARCH_PATHS = "$(inherited) @executable_path/Frameworks @loader_path/Frameworks";\n'
    c = c.replace(f"{TST_REL} /* Release */ = {{\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {{\n\t\t\t\tARCHS = arm64;\n",
                    f"{TST_REL} /* Release */ = {{\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {{\n\t\t\t\tARCHS = arm64;\n{lr}")
    c = c.replace(f"{TST_NGT} /* Nightly */ = {{\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {{\n\t\t\t\tARCHS = arm64;\n",
                    f"{TST_NGT} /* Nightly */ = {{\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {{\n\t\t\t\tARCHS = arm64;\n{lr}")

    # 18. XCConfigurationList
    c = c.replace(
        "/* End XCConfigurationList section */",
        f"""\t\t{cl} /* Build configuration list for PBXNativeTarget "PlayCoverMCPCore" */ = {{
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = (
\t\t\t\t{c_rel} /* Release */,
\t\t\t\t{c_ngt} /* Nightly */,
\t\t\t);
\t\t\tdefaultConfigurationIsVisible = 0;
\t\t\tdefaultConfigurationName = Release;
\t\t}};
/* End XCConfigurationList section */"""
    )

    # 19. Add target to project targets list
    c = c.replace(
        f"\t\t\t\t{MCP_TGT} /* PlayCoverMCP */,\n\t\t\t\t{TST_TGT} /* PlayCoverMCPTests */,",
        f"\t\t\t\t{MCP_TGT} /* PlayCoverMCP */,\n\t\t\t\t{ct} /* PlayCoverMCPCore */,\n\t\t\t\t{TST_TGT} /* PlayCoverMCPTests */,"
    )

    # 20. TargetAttributes
    c = c.replace(
        f"\t\t\t\t{TST_TGT} = {{\n\t\t\t\t\tCreatedOnToolsVersion = 15.0;\n\t\t\t\t\tTestTargetID = {MCP_TGT};\n\t\t\t\t}};",
        f"\t\t\t\t{ct} = {{\n\t\t\t\t\tCreatedOnToolsVersion = 15.0;\n\t\t\t\t}};\n\t\t\t\t{TST_TGT} = {{\n\t\t\t\t\tCreatedOnToolsVersion = 15.0;\n\t\t\t\t\tTestTargetID = {MCP_TGT};\n\t\t\t\t}};"
    )

    # Check braces
    ok, depth = check_braces(c)
    if not ok:
        print(f"FAIL: brace balance issue (depth={depth})")
        sys.exit(1)
    print("OK: brace balance")

    # Save and verify
    with open(PBX, 'w') as f:
        f.write(c)

    r = subprocess.run(['xcodebuild', '-project', 'PlayCover.xcodeproj', '-list'],
                       capture_output=True, text=True, cwd=PBXDIR, timeout=15)
    if 'damaged' in r.stderr or 'parse error' in r.stderr.lower():
        print(f"FAIL: xcodebuild -list: {r.stderr.strip()[:200]}")
        sys.exit(1)
    print("OK: xcodebuild -list")
    print(f"Framework target ID: {ct}")
    print(f"Targets listed:")
    for line in r.stdout.split('\n'):
        if 'PlayCoverMCP' in line or 'PlayCover' in line:
            print(f"  {line.strip()}")


if __name__ == "__main__":
    main()
