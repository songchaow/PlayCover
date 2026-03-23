#!/usr/bin/env python3
"""Add Launch files to Xcode project using line-based insertion."""

import uuid

PBXPROJ = "PlayCover.xcodeproj/project.pbxproj"

with open(PBXPROJ, "rb") as f:
    raw = f.read()

eol = b"\r\n" if raw.count(b"\r\n") > raw.count(b"\n") else b"\n"
lines = raw.decode("utf-8").split(eol.decode())


def gen_id():
    return uuid.uuid4().hex[:24].upper()


LAUNCH_GROUP = gen_id()
HOST_GROUP = gen_id()
LS_REF = gen_id()
LS_BUILD = gen_id()
LT_REF = gen_id()
LT_BUILD = gen_id()
LTST_REF = gen_id()
LTST_BUILD = gen_id()

T = "\t"

# Build list of (insert_before_line_index, lines_to_insert)
insertions = {}

# Pre-compute context strings for matching
full_text = "\n".join(lines)

# Find line indices for all anchors
for i, line in enumerate(lines):
    # 1. PBXBuildFile: before "/* End PBXBuildFile section */"
    if "/* End PBXBuildFile section */" in line and 1 not in insertions:
        insertions[1] = (i, [
            f"{T}{T}{LS_BUILD} /* LaunchService.swift in Sources */ = {{isa = PBXBuildFile; fileRef = {LS_REF} /* LaunchService.swift */; }};",
            f"{T}{T}{LT_BUILD} /* LaunchTools.swift in Sources */ = {{isa = PBXBuildFile; fileRef = {LT_REF} /* LaunchTools.swift */; }};",
            f"{T}{T}{LTST_BUILD} /* LaunchServiceTests.swift in Sources */ = {{isa = PBXBuildFile; fileRef = {LTST_REF} /* LaunchServiceTests.swift */; }};",
        ])

    # 2. PBXFileReference: before "/* End PBXFileReference section */"
    if "/* End PBXFileReference section */" in line and 2 not in insertions:
        insertions[2] = (i, [
            f"{T}{T}{LS_REF} /* LaunchService.swift */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; name = LaunchService.swift; path = LaunchService.swift; sourceTree = \"<group>\"; }};",
            f"{T}{T}{LT_REF} /* LaunchTools.swift */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; name = LaunchTools.swift; path = LaunchTools.swift; sourceTree = \"<group>\"; }};",
            f"{T}{T}{LTST_REF} /* LaunchServiceTests.swift */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; name = LaunchServiceTests.swift; path = LaunchServiceTests.swift; sourceTree = \"<group>\"; }};",
        ])

    # 3. Launch group child in HostServices: before Install child
    if "CEAB2BDBA75A41CD893BC233 /* Install */," in line and 3 not in insertions:
        insertions[3] = (i, [
            f"{T}{T}{T}{LAUNCH_GROUP} /* Launch */,",
        ])

    # 4. Host group child in Tools: before AppTools child
    # Look for AppTools.swift child that is inside the Tools group
    if "9582C48DB29E44938338E6C4 /* AppTools.swift */," in line and 4 not in insertions:
        # Verify it's inside Tools group by checking surrounding context
        context = "\n".join(lines[max(0, i-20):i])
        if "3AD721A147D7400EAD4E2FA2 /* Tools */" in context or "path = Tools" in context:
            insertions[4] = (i, [
                f"{T}{T}{T}{HOST_GROUP} /* Host */,",
            ])

    # 5. LaunchServiceTests child in PlayCoverMCPTests group
    if "562CF7645F174B1A9498A196 /* InstallerServiceTests.swift */," in line and 5 not in insertions:
        context = "\n".join(lines[max(0, i-20):i])
        if "PlayCoverMCPTests" in context or "655C253FCA19492C8624612B" in context:
            insertions[5] = (i + 1, [
                f"{T}{T}{T}{LTST_REF} /* LaunchServiceTests.swift */,",
            ])

    # 6. Group definitions: before "/* End PBXGroup section */"
    if "/* End PBXGroup section */" in line and 6 not in insertions:
        insertions[6] = (i, [
            f"{T}{LAUNCH_GROUP} /* Launch */ = {{",
            f"{T}{T}isa = PBXGroup;",
            f"{T}{T}children = (",
            f"{T}{T}{T}{LS_REF} /* LaunchService.swift */,",
            f"{T}{T});",
            f"{T}{T}path = Launch;",
            f"{T}{T}sourceTree = \"<group>\";",
            f"{T}}};",
            f"{T}{HOST_GROUP} /* Host */ = {{",
            f"{T}{T}isa = PBXGroup;",
            f"{T}{T}children = (",
            f"{T}{T}{T}{LT_REF} /* LaunchTools.swift */,",
            f"{T}{T});",
            f"{T}{T}path = Host;",
            f"{T}{T}sourceTree = \"<group>\";",
            f"{T}}};",
        ])

    # 7. PlayCoverMCP Sources build phase: after Shell.swift build entry
    if "B8B544F872A140AA94CACDEA /* Shell.swift in Sources */," in line and 7 not in insertions:
        insertions[7] = (i + 1, [
            f"{T}{T}{T}{LS_BUILD} /* LaunchService.swift in Sources */,",
            f"{T}{T}{T}{LT_BUILD} /* LaunchTools.swift in Sources */,",
        ])

    # 8. PlayCoverMCPTests Sources build phase: after InstallerServiceTests build entry
    if "D718C5A51078417FBD18C953 /* InstallerServiceTests.swift in Sources */," in line and 8 not in insertions:
        insertions[8] = (i + 1, [
            f"{T}{T}{T}{LTST_BUILD} /* LaunchServiceTests.swift in Sources */,",
        ])

print(f"Found {len(insertions)} insertion points:")
for key in sorted(insertions.keys()):
    idx, new_lines = insertions[key]
    anchor = lines[idx][:60].strip() if idx < len(lines) else "???"
    print(f"  #{key}: line {idx} -> insert {len(new_lines)} lines (before: {anchor})")

# Process insertions from bottom to top to preserve line indices
sorted_insertions = sorted(insertions.items(), key=lambda x: x[1][0], reverse=True)

for key, (idx, new_lines) in sorted_insertions:
    lines[idx:idx] = new_lines

result = eol.decode().join(lines)
with open(PBXPROJ, "w") as f:
    f.write(result)

print(f"\nDone. {len(insertions)} insertion points processed.")
