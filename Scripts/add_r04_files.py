#!/usr/bin/env python3
"""
add_r04_files.py — Add R04 CaptureService/CaptureTools/CaptureToolsTests to pbxproj

Adds:
  1. CaptureService.swift      → PlayCover + PlayCoverMCP + PlayCoverMCPTests sources
  2. CaptureTools.swift         → PlayCover + PlayCoverMCP + PlayCoverMCPTests sources
  3. CaptureToolsTests.swift    → PlayCoverMCPTests sources only

Files are also added to the appropriate PBXGroup children.
"""

import os, sys, subprocess, uuid

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(SCRIPT_DIR, ".."))
PBX = os.path.join(REPO_ROOT, "PlayCover.xcodeproj", "project.pbxproj")


def gen_id():
    """Generate a 24-char uppercase hex ID like Xcode uses."""
    return uuid.uuid4().hex[:24].upper()


def lint(path):
    r = subprocess.run(["plutil", "-lint", path], capture_output=True, text=True)
    return r.returncode == 0, r.stdout + r.stderr


def main():
    # 1. Pre-check
    ok, out = lint(PBX)
    if not ok:
        print(f"ABORT: pbxproj already broken:\n{out}")
        sys.exit(1)
    print("✅ Pre-lint OK")

    with open(PBX, "r") as f:
        c = f.read()

    # ---- Generate unique IDs ----
    # CaptureService.swift
    cs_fileref = gen_id()
    cs_build_host = gen_id()     # PlayCover Host Sources
    cs_build_mcp = gen_id()      # PlayCoverMCP Sources
    cs_build_tests = gen_id()    # PlayCoverMCPTests Sources

    # CaptureTools.swift
    ct_fileref = gen_id()
    ct_build_host = gen_id()     # PlayCover Host Sources
    ct_build_mcp = gen_id()      # PlayCoverMCP Sources
    ct_build_tests = gen_id()    # PlayCoverMCPTests Sources

    # CaptureToolsTests.swift
    ctt_fileref = gen_id()
    ctt_build_tests = gen_id()   # PlayCoverMCPTests Sources only

    # ---- 2. Add PBXBuildFile entries (before "End PBXBuildFile section") ----
    build_file_marker = "/* End PBXBuildFile section */"
    build_entries = (
        f"\t\t{cs_build_host} /* CaptureService.swift in Sources */ = {{isa = PBXBuildFile; fileRef = {cs_fileref} /* CaptureService.swift */; }};\n"
        f"\t\t{cs_build_mcp} /* CaptureService.swift in Sources */ = {{isa = PBXBuildFile; fileRef = {cs_fileref} /* CaptureService.swift */; }};\n"
        f"\t\t{cs_build_tests} /* CaptureService.swift in Sources */ = {{isa = PBXBuildFile; fileRef = {cs_fileref} /* CaptureService.swift */; }};\n"
        f"\t\t{ct_build_host} /* CaptureTools.swift in Sources */ = {{isa = PBXBuildFile; fileRef = {ct_fileref} /* CaptureTools.swift */; }};\n"
        f"\t\t{ct_build_mcp} /* CaptureTools.swift in Sources */ = {{isa = PBXBuildFile; fileRef = {ct_fileref} /* CaptureTools.swift */; }};\n"
        f"\t\t{ct_build_tests} /* CaptureTools.swift in Sources */ = {{isa = PBXBuildFile; fileRef = {ct_fileref} /* CaptureTools.swift */; }};\n"
        f"\t\t{ctt_build_tests} /* CaptureToolsTests.swift in Sources */ = {{isa = PBXBuildFile; fileRef = {ctt_fileref} /* CaptureToolsTests.swift */; }};\n"
    )
    idx = c.find(build_file_marker)
    if idx == -1:
        print("ABORT: Cannot find PBXBuildFile end marker")
        sys.exit(1)
    c = c[:idx] + build_entries + c[idx:]
    print("✅ PBXBuildFile entries added")

    # ---- 3. Add PBXFileReference entries (before "End PBXFileReference section") ----
    fileref_marker = "/* End PBXFileReference section */"
    fileref_entries = (
        f'\t\t{cs_fileref} /* CaptureService.swift */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; name = CaptureService.swift; path = CaptureService.swift; sourceTree = "<group>"; }};\n'
        f'\t\t{ct_fileref} /* CaptureTools.swift */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; name = CaptureTools.swift; path = CaptureTools.swift; sourceTree = "<group>"; }};\n'
        f'\t\t{ctt_fileref} /* CaptureToolsTests.swift */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; name = CaptureToolsTests.swift; path = CaptureToolsTests.swift; sourceTree = "<group>"; }};\n'
    )
    idx = c.find(fileref_marker)
    if idx == -1:
        print("ABORT: Cannot find PBXFileReference end marker")
        sys.exit(1)
    c = c[:idx] + fileref_entries + c[idx:]
    print("✅ PBXFileReference entries added")

    # ---- 4. Add to PBXGroup children ----

    # 4a. CaptureService.swift → MCP Session group (contains InputService.swift with unique fileRef)
    session_service_marker = "BBA93F1020F7431D90F7FE32 /* InputService.swift */,"
    idx = c.find(session_service_marker)
    if idx == -1:
        print("ABORT: Cannot find InputService.swift in Session group")
        sys.exit(1)
    end_of_line = c.find("\n", idx) + 1
    insert = f"\t\t\t\t{cs_fileref} /* CaptureService.swift */,\n"
    c = c[:end_of_line] + insert + c[end_of_line:]
    print("✅ CaptureService.swift added to Session group (MCP)")

    # 4b. CaptureTools.swift → Session tools group (contains InputTools.swift with unique fileRef)
    session_tools_marker = "B275B27D2B5F4E6BBDFD054E /* InputTools.swift */,"
    idx = c.find(session_tools_marker)
    if idx == -1:
        print("ABORT: Cannot find InputTools.swift in Session tools group")
        sys.exit(1)
    end_of_line = c.find("\n", idx) + 1
    insert = f"\t\t\t\t{ct_fileref} /* CaptureTools.swift */,\n"
    c = c[:end_of_line] + insert + c[end_of_line:]
    print("✅ CaptureTools.swift added to Session tools group")

    # 4c. CaptureToolsTests.swift → PlayCoverMCPTests group (contains SessionInputTests.swift with unique fileRef)
    tests_marker = "362AE3D78BF14F4BA17D491F /* SessionInputTests.swift */,"
    idx = c.find(tests_marker)
    if idx == -1:
        print("ABORT: Cannot find SessionInputTests.swift in tests group")
        sys.exit(1)
    end_of_line = c.find("\n", idx) + 1
    insert = f"\t\t\t\t{ctt_fileref} /* CaptureToolsTests.swift */,\n"
    c = c[:end_of_line] + insert + c[end_of_line:]
    print("✅ CaptureToolsTests.swift added to tests group")

    # ---- 5. Add to PBXSourcesBuildPhase ----
    # Each phase has UNIQUE build file IDs. We use unique markers to find each phase.

    # 5a. PlayCover Host Sources build phase
    #     Unique marker: 8E2D679461824632B004385A /* InputTools.swift in Sources */
    host_marker = "8E2D679461824632B004385A /* InputTools.swift in Sources */,"
    idx = c.find(host_marker)
    if idx == -1:
        print("ABORT: Cannot find InputTools.swift in PlayCover Host Sources build phase")
        sys.exit(1)
    end_of_line = c.find("\n", idx) + 1
    insert = (
        f"\t\t\t\t{cs_build_host} /* CaptureService.swift in Sources */,\n"
        f"\t\t\t\t{ct_build_host} /* CaptureTools.swift in Sources */,\n"
    )
    c = c[:end_of_line] + insert + c[end_of_line:]
    print("✅ CaptureService + CaptureTools added to PlayCover Host Sources")

    # 5b. PlayCoverMCP Sources build phase
    #     Unique marker: 821DCE0775B2404D922B2F5A /* InputTools.swift in Sources */
    mcp_marker = "821DCE0775B2404D922B2F5A /* InputTools.swift in Sources */,"
    idx = c.find(mcp_marker)
    if idx == -1:
        print("ABORT: Cannot find InputTools.swift in PlayCoverMCP Sources build phase")
        sys.exit(1)
    end_of_line = c.find("\n", idx) + 1
    insert = (
        f"\t\t\t\t{cs_build_mcp} /* CaptureService.swift in Sources */,\n"
        f"\t\t\t\t{ct_build_mcp} /* CaptureTools.swift in Sources */,\n"
    )
    c = c[:end_of_line] + insert + c[end_of_line:]
    print("✅ CaptureService + CaptureTools added to PlayCoverMCP Sources")

    # 5c. PlayCoverMCPTests Sources build phase
    #     Unique marker: CEBB186D7B144E77B41EC640 /* SessionInputTests.swift in Sources */
    tests_sources_marker = "CEBB186D7B144E77B41EC640 /* SessionInputTests.swift in Sources */,"
    idx = c.find(tests_sources_marker)
    if idx == -1:
        print("ABORT: Cannot find SessionInputTests.swift in PlayCoverMCPTests Sources build phase")
        sys.exit(1)
    end_of_line = c.find("\n", idx) + 1
    insert = (
        f"\t\t\t\t{cs_build_tests} /* CaptureService.swift in Sources */,\n"
        f"\t\t\t\t{ct_build_tests} /* CaptureTools.swift in Sources */,\n"
        f"\t\t\t\t{ctt_build_tests} /* CaptureToolsTests.swift in Sources */,\n"
    )
    c = c[:end_of_line] + insert + c[end_of_line:]
    print("✅ Capture files added to PlayCoverMCPTests Sources")

    # ---- 6. Write and verify ----
    with open(PBX, "w") as f:
        f.write(c)

    ok, out = lint(PBX)
    if not ok:
        print(f"❌ Post-lint FAILED:\n{out}")
        print("WARNING: pbxproj may be broken. Use 'git checkout -- PlayCover.xcodeproj/project.pbxproj' to restore.")
        sys.exit(1)

    print("✅ Post-lint OK — all entries added successfully!")


if __name__ == "__main__":
    main()
