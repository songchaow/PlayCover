#!/usr/bin/env python3
"""Add Cleanup files to Xcode project using line-based insertion."""

import uuid

PBXPROJ = "PlayCover.xcodeproj/project.pbxproj"

with open(PBXPROJ, "rb") as f:
    raw = f.read()

eol = b"\r\n" if raw.count(b"\r\n") > raw.count(b"\n") else b"\n"
lines = raw.decode("utf-8").split(eol.decode())

def gen_id():
    return uuid.uuid4().hex[:24].upper()

T = "\t"

# Generate unique IDs
CLEANUP_GROUP = gen_id()
CS_REF = gen_id()
CS_BUILD = gen_id()
CT_REF = gen_id()
CT_BUILD = gen_id()
CST_REF = gen_id()
CST_BUILD = gen_id()

# Find existing IDs to anchor after
launch_tools_build_id = None
launch_tests_build_id = None

for line in lines:
    if "LaunchTools.swift in Sources" in line:
        launch_tools_build_id = line.split("/*")[0].strip()
    if "LaunchServiceTests.swift in Sources" in line:
        launch_tests_build_id = line.split("/*")[0].strip()

print(f"Launch tools build ID: {launch_tools_build_id}")
print(f"Launch tests build ID: {launch_tests_build_id}")

insertions = {}

for i, line in enumerate(lines):
    # 1. PBXBuildFile: before End PBXBuildFile section
    if "/* End PBXBuildFile section */" in line and 1 not in insertions:
        insertions[1] = (i, [
            f'{T}{T}{CS_BUILD} /* CleanupService.swift in Sources */ = {{isa = PBXBuildFile; fileRef = {CS_REF} /* CleanupService.swift */; }};',
            f'{T}{T}{CT_BUILD} /* CleanupTools.swift in Sources */ = {{isa = PBXBuildFile; fileRef = {CT_REF} /* CleanupTools.swift */; }};',
            f'{T}{T}{CST_BUILD} /* CleanupServiceTests.swift in Sources */ = {{isa = PBXBuildFile; fileRef = {CST_REF} /* CleanupServiceTests.swift */; }};',
        ])

    # 2. PBXFileReference: before End PBXFileReference section
    if "/* End PBXFileReference section */" in line and 2 not in insertions:
        insertions[2] = (i, [
            f'{T}{T}{CS_REF} /* CleanupService.swift */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; name = CleanupService.swift; path = CleanupService.swift; sourceTree = "<group>"; }};',
            f'{T}{T}{CT_REF} /* CleanupTools.swift */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; name = CleanupTools.swift; path = CleanupTools.swift; sourceTree = "<group>"; }};',
            f'{T}{T}{CST_REF} /* CleanupServiceTests.swift */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; name = CleanupServiceTests.swift; path = CleanupServiceTests.swift; sourceTree = "<group>"; }};',
        ])

    # 3. Cleanup group child in HostServices: after Launch child
    if "Launch */," in line and 3 not in insertions:
        context = "\n".join(lines[max(0, i - 10): i + 1])
        if "HostServices" in context:
            insertions[3] = (i + 1, [
                f"{T}{T}{T}{CLEANUP_GROUP} /* Cleanup */,",
            ])

    # 4. CleanupTools child in Host group (Tools/Host)
    if "LaunchTools.swift */," in line and 4 not in insertions:
        context = "\n".join(lines[max(0, i - 10): i + 1])
        if "path = Host" in context:
            insertions[4] = (i + 1, [
                f"{T}{T}{T}{CT_REF} /* CleanupTools.swift */,",
            ])

    # 5. CleanupServiceTests child in PlayCoverMCPTests group
    if "LaunchServiceTests.swift */," in line and 5 not in insertions:
        context = "\n".join(lines[max(0, i - 20): i + 1])
        if "PlayCoverMCPTests" in context:
            insertions[5] = (i + 1, [
                f"{T}{T}{T}{CST_REF} /* CleanupServiceTests.swift */,",
            ])

    # 6. Group definitions: before End PBXGroup section
    if "/* End PBXGroup section */" in line and 6 not in insertions:
        insertions[6] = (i, [
            f"{T}{CLEANUP_GROUP} /* Cleanup */ = {{",
            f"{T}{T}isa = PBXGroup;",
            f"{T}{T}children = (",
            f"{T}{T}{T}{CS_REF} /* CleanupService.swift */,",
            f"{T}{T});",
            f"{T}{T}path = Cleanup;",
            f"{T}{T}sourceTree = \"<group>\";",
            f"{T}}};",
        ])

    # 7. PlayCoverMCP Sources build phase: after LaunchTools build entry
    if launch_tools_build_id and f"{launch_tools_build_id} /* LaunchTools.swift in Sources */," in line and 7 not in insertions:
        insertions[7] = (i + 1, [
            f"{T}{T}{T}{CS_BUILD} /* CleanupService.swift in Sources */,",
            f"{T}{T}{T}{CT_BUILD} /* CleanupTools.swift in Sources */,",
        ])

    # 8. PlayCoverMCPTests Sources build phase: after LaunchServiceTests build entry
    if launch_tests_build_id and f"{launch_tests_build_id} /* LaunchServiceTests.swift in Sources */," in line and 8 not in insertions:
        insertions[8] = (i + 1, [
            f"{T}{T}{T}{CST_BUILD} /* CleanupServiceTests.swift in Sources */,",
        ])

print(f"Found {len(insertions)} insertion points:")
for key in sorted(insertions.keys()):
    idx, new_lines = insertions[key]
    anchor = lines[idx][:80].strip() if idx < len(lines) else "???"
    print(f"  #{key}: line {idx} -> insert {len(new_lines)} lines (before: {anchor})")

# Process from bottom to top
sorted_insertions = sorted(insertions.items(), key=lambda x: x[1][0], reverse=True)
for key, (idx, new_lines) in sorted_insertions:
    lines[idx:idx] = new_lines

result = eol.decode().join(lines)
with open(PBXPROJ, "w") as f:
    f.write(result)

print(f"\nDone. {len(insertions)} insertion points processed.")
