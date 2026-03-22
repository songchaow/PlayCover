#!/usr/bin/env python3
"""
Script to add PlayCoverMCP and PlayCoverMCPTests targets to PlayCover.xcodeproj.

This adds:
- PlayCoverMCP: macOS command-line tool target
- PlayCoverMCPTests: unit test bundle target (depends on PlayCoverMCP)
- PlayCoverMCP.xcscheme: shared scheme for building & testing
- Directory groups: PlayCoverMCP/, PlayCoverMCP/HostServices/, PlayCoverMCP/Session/

Usage:
    python3 Scripts/add_mcp_targets.py
"""

import re
import uuid
import os

PBXPROJ_PATH = os.path.join(os.path.dirname(__file__), "..", "PlayCover.xcodeproj", "project.pbxproj")
SCHEME_PATH = os.path.join(os.path.dirname(__file__), "..", "PlayCover.xcodeproj", "xcshareddata", "xcschemes", "PlayCoverMCP.xcscheme")


def generate_id():
    """Generate a deterministic 24-char hex ID using UUID4."""
    return uuid.uuid4().hex[:24].upper()


def main():
    # Generate all needed IDs
    ids = {}

    # PlayCoverMCP target
    ids['mcp_target'] = generate_id()
    ids['mcp_product'] = generate_id()
    ids['mcp_sources'] = generate_id()
    ids['mcp_frameworks'] = generate_id()
    ids['mcp_resources'] = generate_id()
    ids['mcp_config_list'] = generate_id()
    ids['mcp_release'] = generate_id()
    ids['mcp_nightly'] = generate_id()

    # PlayCoverMCPTests target
    ids['test_target'] = generate_id()
    ids['test_product'] = generate_id()
    ids['test_sources'] = generate_id()
    ids['test_frameworks'] = generate_id()
    ids['test_resources'] = generate_id()
    ids['test_config_list'] = generate_id()
    ids['test_release'] = generate_id()
    ids['test_nightly'] = generate_id()
    ids['test_dependency'] = generate_id()
    ids['test_proxy'] = generate_id()

    # File references
    ids['main_swift_ref'] = generate_id()
    ids['main_swift_build'] = generate_id()
    ids['mcp_info_ref'] = generate_id()
    ids['test_swift_ref'] = generate_id()
    ids['test_swift_build'] = generate_id()
    ids['test_info_ref'] = generate_id()

    # Groups
    ids['mcp_group'] = generate_id()
    ids['hostservices_group'] = generate_id()
    ids['session_group'] = generate_id()
    ids['tests_group'] = generate_id()

    print("Generated IDs:")
    for k, v in ids.items():
        print(f"  {k}: {v}")

    with open(PBXPROJ_PATH, 'r') as f:
        content = f.read()

    # ============================================================
    # 1. PBXBuildFile section
    # ============================================================
    build_files = f"""\t\t{ids['main_swift_build']} /* main.swift in Sources */ = {{isa = PBXBuildFile; fileRef = {ids['main_swift_ref']} /* main.swift */; }};
\t\t{ids['test_swift_build']} /* PlayCoverMCPTests.swift in Sources */ = {{isa = PBXBuildFile; fileRef = {ids['test_swift_ref']} /* PlayCoverMCPTests.swift */; }};"""
    content = content.replace(
        "/* End PBXBuildFile section */",
        build_files + "\n/* End PBXBuildFile section */"
    )

    # ============================================================
    # 2. PBXContainerItemProxy section
    # ============================================================
    container_proxy = f"""\t\t{ids['test_proxy']} /* PBXContainerItemProxy */ = {{
\t\t\tisa = PBXContainerItemProxy;
\t\t\tcontainerPortal = 8783CFEF26B8C52D00171041 /* Project object */;
\t\t\tproxyType = 1;
\t\t\tremoteGlobalIDString = {ids['mcp_target']};
\t\t\tremoteInfo = PlayCoverMCP;
\t\t}};"""
    content = content.replace(
        "/* End PBXBuildFile section */",
        "/* End PBXBuildFile section */\n\n/* Begin PBXContainerItemProxy section */\n" +
        container_proxy + "\n/* End PBXContainerItemProxy section */"
    )

    # ============================================================
    # 3. PBXFileReference section
    # ============================================================
    file_refs = f"""\t\t{ids['main_swift_ref']} /* main.swift */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = main.swift; sourceTree = "<group>"; }};
\t\t{ids['mcp_info_ref']} /* Info.plist */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>"; }};
\t\t{ids['test_swift_ref']} /* PlayCoverMCPTests.swift */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = PlayCoverMCPTests.swift; sourceTree = "<group>"; }};
\t\t{ids['test_info_ref']} /* Info.plist */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>"; }};
\t\t{ids['mcp_product']} /* PlayCoverMCP */ = {{isa = PBXFileReference; explicitFileType = "compiled.mach-o.executable"; includeInIndex = 0; path = PlayCoverMCP; sourceTree = BUILT_PRODUCTS_DIR; }};
\t\t{ids['test_product']} /* PlayCoverMCPTests.xctest */ = {{isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = PlayCoverMCPTests.xctest; sourceTree = BUILT_PRODUCTS_DIR; }};"""
    content = content.replace(
        "/* End PBXFileReference section */",
        file_refs + "\n/* End PBXFileReference section */"
    )

    # ============================================================
    # 4. PBXFrameworksBuildPhase section
    # ============================================================
    frameworks = f"""\t\t{ids['mcp_frameworks']} /* Frameworks */ = {{
\t\t\tisa = PBXFrameworksBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
\t\t{ids['test_frameworks']} /* Frameworks */ = {{
\t\t\tisa = PBXFrameworksBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};"""
    content = content.replace(
        "/* End PBXFrameworksBuildPhase section */",
        frameworks + "\n/* End PBXFrameworksBuildPhase section */"
    )

    # ============================================================
    # 5. PBXGroup section - Add new groups
    # ============================================================
    groups = f"""\t\t{ids['hostservices_group']} /* HostServices */ = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t);
\t\t\tpath = HostServices;
\t\t\tsourceTree = "<group>";
\t\t}};
\t\t{ids['session_group']} /* Session */ = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t);
\t\t\tpath = Session;
\t\t\tsourceTree = "<group>";
\t\t}};
\t\t{ids['mcp_group']} /* PlayCoverMCP */ = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\t{ids['hostservices_group']} /* HostServices */,
\t\t\t\t{ids['session_group']} /* Session */,
\t\t\t\t{ids['main_swift_ref']} /* main.swift */,
\t\t\t\t{ids['mcp_info_ref']} /* Info.plist */,
\t\t\t);
\t\t\tpath = PlayCoverMCP;
\t\t\tsourceTree = "<group>";
\t\t}};
\t\t{ids['tests_group']} /* PlayCoverMCPTests */ = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\t{ids['test_swift_ref']} /* PlayCoverMCPTests.swift */,
\t\t\t\t{ids['test_info_ref']} /* Info.plist */,
\t\t\t);
\t\t\tpath = PlayCoverMCPTests;
\t\t\tsourceTree = "<group>";
\t\t}};"""
    content = content.replace(
        "/* End PBXGroup section */",
        groups + "\n/* End PBXGroup section */"
    )

    # ============================================================
    # 5b. Update main group to include PlayCoverMCP and PlayCoverMCPTests
    # ============================================================
    main_group_pattern = r'(8783CFEE26B8C52D00171041 = \{[^}]*children = \(\s*.*?)(8783CFF926B8C52D00171041 /\* PlayCover \*/)'
    content = re.sub(
        main_group_pattern,
        lambda m: m.group(1) + f"\n\t\t\t\t{ids['mcp_group']} /* PlayCoverMCP */,\n\t\t\t\t{ids['tests_group']} /* PlayCoverMCPTests */,\n\t\t\t\t" + m.group(2),
        content,
        flags=re.DOTALL
    )

    # ============================================================
    # 5c. Update Products group
    # ============================================================
    products_pattern = r'(8783CFF826B8C52D00171041 /\* Products \*/ = \{[^}]*children = \(\s*.*?)(8783CFF726B8C52D00171041 /\* PlayCover\.app \*/)'
    content = re.sub(
        products_pattern,
        lambda m: m.group(1) + f"\n\t\t\t\t{ids['mcp_product']} /* PlayCoverMCP */,\n\t\t\t\t{ids['test_product']} /* PlayCoverMCPTests.xctest */,\n\t\t\t\t" + m.group(2),
        content,
        flags=re.DOTALL
    )

    # ============================================================
    # 6. PBXNativeTarget section
    # ============================================================
    targets = f"""\t\t{ids['mcp_target']} /* PlayCoverMCP */ = {{
\t\t\tisa = PBXNativeTarget;
\t\t\tbuildConfigurationList = {ids['mcp_config_list']} /* Build configuration list for PBXNativeTarget "PlayCoverMCP" */;
\t\t\tbuildPhases = (
\t\t\t\t{ids['mcp_sources']} /* Sources */,
\t\t\t\t{ids['mcp_frameworks']} /* Frameworks */,
\t\t\t\t{ids['mcp_resources']} /* Resources */,
\t\t\t);
\t\t\tbuildRules = (
\t\t\t);
\t\t\tdependencies = (
\t\t\t);
\t\t\tname = PlayCoverMCP;
\t\t\tproductName = PlayCoverMCP;
\t\t\tproductReference = {ids['mcp_product']} /* PlayCoverMCP */;
\t\t\tproductType = "com.apple.product-type.tool";
\t\t}};
\t\t{ids['test_target']} /* PlayCoverMCPTests */ = {{
\t\t\tisa = PBXNativeTarget;
\t\t\tbuildConfigurationList = {ids['test_config_list']} /* Build configuration list for PBXNativeTarget "PlayCoverMCPTests" */;
\t\t\tbuildPhases = (
\t\t\t\t{ids['test_sources']} /* Sources */,
\t\t\t\t{ids['test_frameworks']} /* Frameworks */,
\t\t\t\t{ids['test_resources']} /* Resources */,
\t\t\t);
\t\t\tbuildRules = (
\t\t\t);
\t\t\tdependencies = (
\t\t\t\t{ids['test_dependency']} /* PBXTargetDependency */,
\t\t\t);
\t\t\tname = PlayCoverMCPTests;
\t\t\tproductName = PlayCoverMCPTests;
\t\t\tproductReference = {ids['test_product']} /* PlayCoverMCPTests.xctest */;
\t\t\tproductType = "com.apple.product-type.bundle.unit-test";
\t\t}};"""
    content = content.replace(
        "/* End PBXNativeTarget section */",
        targets + "\n/* End PBXNativeTarget section */"
    )

    # ============================================================
    # 7. PBXProject section - update targets list and attributes
    # ============================================================
    # Add targets
    targets_list_pattern = r'(targets = \(\s*8783CFF626B8C52D00171041 /\* PlayCover \*/,)'
    content = re.sub(
        targets_list_pattern,
        lambda m: m.group(1) + f"\n\t\t\t\t{ids['mcp_target']} /* PlayCoverMCP */,\n\t\t\t\t{ids['test_target']} /* PlayCoverMCPTests */,",
        content
    )

    # Add TargetAttributes
    attrs_pattern = r'(TargetAttributes = \{\s*8783CFF626B8C52D00171041 = \{[^}]*\};)'
    attrs = f"""{attrs_pattern.group(1) if False else ''}
\t\t\t\t\t{ids['mcp_target']} = {{
\t\t\t\t\t\tCreatedOnToolsVersion = 15.0;
\t\t\t\t\t}};
\t\t\t\t\t{ids['test_target']} = {{
\t\t\t\t\t\tCreatedOnToolsVersion = 15.0;
\t\t\t\t\t\tTestTargetID = {ids['mcp_target']};
\t\t\t\t\t}};"""

    # Simpler approach: find the TargetAttributes block and insert after PlayCover entry
    content = re.sub(
        r'(TargetAttributes = \{[^}]*8783CFF626B8C52D00171041 = \{[^}]*\};)',
        lambda m: m.group(1) + f"""
\t\t\t\t\t{ids['mcp_target']} = {{
\t\t\t\t\t\tCreatedOnToolsVersion = 15.0;
\t\t\t\t\t}};
\t\t\t\t\t{ids['test_target']} = {{
\t\t\t\t\t\tCreatedOnToolsVersion = 15.0;
\t\t\t\t\t\tTestTargetID = {ids['mcp_target']};
\t\t\t\t\t}};""",
        content
    )

    # ============================================================
    # 8. PBXResourcesBuildPhase section
    # ============================================================
    resources = f"""\t\t{ids['mcp_resources']} /* Resources */ = {{
\t\t\tisa = PBXResourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
\t\t{ids['test_resources']} /* Resources */ = {{
\t\t\tisa = PBXResourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};"""
    content = content.replace(
        "/* End PBXResourcesBuildPhase section */",
        resources + "\n/* End PBXResourcesBuildPhase section */"
    )

    # ============================================================
    # 9. PBXSourcesBuildPhase section
    # ============================================================
    sources = f"""\t\t{ids['mcp_sources']} /* Sources */ = {{
\t\t\tisa = PBXSourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t\t{ids['main_swift_build']} /* main.swift in Sources */,
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
\t\t{ids['test_sources']} /* Sources */ = {{
\t\t\tisa = PBXSourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t\t{ids['test_swift_build']} /* PlayCoverMCPTests.swift in Sources */,
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};"""
    content = content.replace(
        "/* End PBXSourcesBuildPhase section */",
        sources + "\n/* End PBXSourcesBuildPhase section */"
    )

    # ============================================================
    # 10. PBXTargetDependency section
    # ============================================================
    target_dep = f"""\t\t{ids['test_dependency']} /* PBXTargetDependency */ = {{
\t\t\tisa = PBXTargetDependency;
\t\t\ttarget = {ids['mcp_target']} /* PlayCoverMCP */;
\t\t\ttargetProxy = {ids['test_proxy']} /* PBXContainerItemProxy */;
\t\t}};"""
    content = content.replace(
        "/* End PBXResourcesBuildPhase section */",
        "/* End PBXResourcesBuildPhase section */\n\n/* Begin PBXTargetDependency section */\n" +
        target_dep + "\n/* End PBXTargetDependency section */"
    )

    # ============================================================
    # 11. XCBuildConfiguration section
    # ============================================================
    mcp_configs = f"""\t\t{ids['mcp_release']} /* Release */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
\t\t\t\tARCHS = arm64;
\t\t\t\tCODE_SIGN_STYLE = Automatic;
\t\t\t\tCOMBINE_HIDPI_IMAGES = YES;
\t\t\t\tCURRENT_PROJECT_VERSION = 1;
\t\t\t\tDEAD_CODE_STRIPPING = YES;
\t\t\t\tDEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";
\t\t\t\tENABLE_HARDENED_RUNTIME = YES;
\t\t\t\tEXCLUDED_ARCHS = x86_64;
\t\t\t\tEXECUTABLE_PREFIX = "";
\t\t\t\tMACOSX_DEPLOYMENT_TARGET = 12.0;
\t\t\t\tMARKETING_VERSION = 1.0.0;
\t\t\t\tONLY_ACTIVE_ARCH = NO;
\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = io.playcover.PlayCover.MCP;
\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";
\t\t\t\tSWIFT_VERSION = 5.0;
\t\t\t}};
\t\t\tname = Release;
\t\t}};
\t\t{ids['mcp_nightly']} /* Nightly */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
\t\t\t\tARCHS = arm64;
\t\t\t\tCODE_SIGN_STYLE = Automatic;
\t\t\t\tCOMBINE_HIDPI_IMAGES = YES;
\t\t\t\tCURRENT_PROJECT_VERSION = 1;
\t\t\t\tDEAD_CODE_STRIPPING = YES;
\t\t\t\tDEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";
\t\t\t\tENABLE_HARDENED_RUNTIME = YES;
\t\t\t\tEXCLUDED_ARCHS = x86_64;
\t\t\t\tEXECUTABLE_PREFIX = "";
\t\t\t\tMACOSX_DEPLOYMENT_TARGET = 12.0;
\t\t\t\tMARKETING_VERSION = 1.0.0;
\t\t\t\tONLY_ACTIVE_ARCH = NO;
\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = io.playcover.PlayCover.MCP;
\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";
\t\t\t\tSWIFT_VERSION = 5.0;
\t\t\t}};
\t\t\tname = Nightly;
\t\t}};
\t\t{ids['test_release']} /* Release */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
\t\t\t\tARCHS = arm64;
\t\t\t\tBUNDLE_LOADER = "$(TEST_HOST)";
\t\t\t\tCODE_SIGN_STYLE = Automatic;
\t\t\t\tCOMBINE_HIDPI_IMAGES = YES;
\t\t\t\tCURRENT_PROJECT_VERSION = 1;
\t\t\t\tDEAD_CODE_STRIPPING = YES;
\t\t\t\tDEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";
\t\t\t\tEXCLUDED_ARCHS = x86_64;
\t\t\t\tMACOSX_DEPLOYMENT_TARGET = 12.0;
\t\t\t\tMARKETING_VERSION = 1.0.0;
\t\t\t\tONLY_ACTIVE_ARCH = NO;
\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = io.playcover.PlayCover.MCPTests;
\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";
\t\t\t\tSWIFT_VERSION = 5.0;
\t\t\t\tTEST_HOST = "$(BUILT_PRODUCTS_DIR)/PlayCoverMCP";
\t\t\t}};
\t\t\tname = Release;
\t\t}};
\t\t{ids['test_nightly']} /* Nightly */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
\t\t\t\tARCHS = arm64;
\t\t\t\tBUNDLE_LOADER = "$(TEST_HOST)";
\t\t\t\tCODE_SIGN_STYLE = Automatic;
\t\t\t\tCOMBINE_HIDPI_IMAGES = YES;
\t\t\t\tCURRENT_PROJECT_VERSION = 1;
\t\t\t\tDEAD_CODE_STRIPPING = YES;
\t\t\t\tDEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";
\t\t\t\tEXCLUDED_ARCHS = x86_64;
\t\t\t\tMACOSX_DEPLOYMENT_TARGET = 12.0;
\t\t\t\tMARKETING_VERSION = 1.0.0;
\t\t\t\tONLY_ACTIVE_ARCH = NO;
\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = io.playcover.PlayCover.MCPTests;
\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";
\t\t\t\tSWIFT_VERSION = 5.0;
\t\t\t\tTEST_HOST = "$(BUILT_PRODUCTS_DIR)/PlayCoverMCP";
\t\t\t}};
\t\t\tname = Nightly;
\t\t}};"""
    content = content.replace(
        "/* End XCBuildConfiguration section */",
        mcp_configs + "\n/* End XCBuildConfiguration section */"
    )

    # ============================================================
    # 12. XCConfigurationList section
    # ============================================================
    config_lists = f"""\t\t{ids['mcp_config_list']} /* Build configuration list for PBXNativeTarget "PlayCoverMCP" */ = {{
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = (
\t\t\t\t{ids['mcp_release']} /* Release */,
\t\t\t\t{ids['mcp_nightly']} /* Nightly */,
\t\t\t);
\t\t\tdefaultConfigurationIsVisible = 0;
\t\t\tdefaultConfigurationName = Release;
\t\t}};
\t\t{ids['test_config_list']} /* Build configuration list for PBXNativeTarget "PlayCoverMCPTests" */ = {{
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = (
\t\t\t\t{ids['test_release']} /* Release */,
\t\t\t\t{ids['test_nightly']} /* Nightly */,
\t\t\t);
\t\t\tdefaultConfigurationIsVisible = 0;
\t\t\tdefaultConfigurationName = Release;
\t\t}};"""
    content = content.replace(
        "/* End XCConfigurationList section */",
        config_lists + "\n/* End XCConfigurationList section */"
    )

    with open(PBXPROJ_PATH, 'w') as f:
        f.write(content)

    print(f"\nSuccessfully updated {PBXPROJ_PATH}")

    # ============================================================
    # 13. Create PlayCoverMCP.xcscheme
    # ============================================================
    os.makedirs(os.path.dirname(SCHEME_PATH), exist_ok=True)
    scheme_content = f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "1410"
   version = "1.3">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{ids['mcp_target']}"
               BuildableName = "PlayCoverMCP"
               BlueprintName = "PlayCoverMCP"
               ReferencedContainer = "container:PlayCover.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
         <TestableReference
            skipped = "NO">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{ids['test_target']}"
               BuildableName = "PlayCoverMCPTests.xctest"
               BlueprintName = "PlayCoverMCPTests"
               ReferencedContainer = "container:PlayCover.xcodeproj">
            </BuildableReference>
         </TestableReference>
      </Testables>
   </TestAction>
   <LaunchAction
      buildConfiguration = "Release"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{ids['mcp_target']}"
            BuildableName = "PlayCoverMCP"
            BlueprintName = "PlayCoverMCP"
            ReferencedContainer = "container:PlayCover.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Release"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      debugDocumentVersioning = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{ids['mcp_target']}"
            BuildableName = "PlayCoverMCP"
            BlueprintName = "PlayCoverMCP"
            ReferencedContainer = "container:PlayCover.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction
      buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>"""
    with open(SCHEME_PATH, 'w') as f:
        f.write(scheme_content)

    print(f"Created {SCHEME_PATH}")
    print("\nDone! PlayCoverMCP and PlayCoverMCPTests targets have been added.")
    print(f"\nGenerated IDs saved for reference: {ids}")


if __name__ == "__main__":
    main()
