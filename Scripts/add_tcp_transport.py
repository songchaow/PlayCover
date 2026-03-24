#!/usr/bin/env python3
"""
Add TCPTransport.swift and TCPTransportTests.swift to the Xcode project.
Uses precise line content matching with verification.
"""

import sys
import os

PBXPROJ = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                        '..', 'PlayCover.xcodeproj', 'project.pbxproj')
PBXPROJ = os.path.normpath(PBXPROJ)

# New UUIDs (24 hex chars)
TCP_FILEREF_ID      = 'B3F7A1C2D4E5F60100AABB01'
TCP_BUILD_GUI_ID    = 'B3F7A1C2D4E5F60200AABB02'
TCP_BUILD_MCP_ID    = 'B3F7A1C2D4E5F60300AABB03'
TCP_BUILD_TEST_ID   = 'B3F7A1C2D4E5F60400AABB04'
TCPTEST_FILEREF_ID  = 'B3F7A1C2D4E5F60500AABB05'
TCPTEST_BUILD_ID    = 'B3F7A1C2D4E5F60600AABB06'

# Anchor IDs for matching
STDIO_FILEREF_ID    = 'A369BC937EC744178C1B211D'


def insert_after(lines, anchor_text, new_lines_to_insert, label):
    """Insert new_lines after the first line containing anchor_text. Returns modified lines."""
    for i, line in enumerate(lines):
        if anchor_text in line:
            print(f"  [{label}] Found anchor at line {i+1}: {line.rstrip()[:80]}")
            return lines[:i+1] + new_lines_to_insert + lines[i+1:]
    print(f"  ERROR: [{label}] Anchor not found: {anchor_text}")
    sys.exit(1)


def main():
    with open(PBXPROJ, 'r') as f:
        content = f.read()

    if 'TCPTransport.swift' in content:
        print("TCPTransport.swift already exists in pbxproj, skipping.")
        return 0

    lines = content.split('\n')
    # Keep newlines for proper writing
    lines = [l + '\n' for l in lines]
    # Last line might have extra newline
    if lines and lines[-1].endswith('\n\n'):
        lines[-1] = lines[-1][:-1]

    print("Step 1: Adding PBXBuildFile entries...")
    # Insert after the 5C596A7CF8C345919790DF67 line (StdioTransport test build file)
    build_file_entries = [
        f'\t\t{TCP_BUILD_GUI_ID} /* TCPTransport.swift in Sources */ = {{isa = PBXBuildFile; fileRef = {TCP_FILEREF_ID} /* TCPTransport.swift */; }};\n',
        f'\t\t{TCP_BUILD_MCP_ID} /* TCPTransport.swift in Sources */ = {{isa = PBXBuildFile; fileRef = {TCP_FILEREF_ID} /* TCPTransport.swift */; }};\n',
        f'\t\t{TCP_BUILD_TEST_ID} /* TCPTransport.swift in Sources */ = {{isa = PBXBuildFile; fileRef = {TCP_FILEREF_ID} /* TCPTransport.swift */; }};\n',
        f'\t\t{TCPTEST_BUILD_ID} /* TCPTransportTests.swift in Sources */ = {{isa = PBXBuildFile; fileRef = {TCPTEST_FILEREF_ID} /* TCPTransportTests.swift */; }};\n',
    ]
    lines = insert_after(lines, '5C596A7CF8C345919790DF67', build_file_entries, 'PBXBuildFile')

    print("Step 2: Adding PBXFileReference entries...")
    # Insert after StdioTransport.swift PBXFileReference
    file_ref_entries = [
        f'\t\t{TCP_FILEREF_ID} /* TCPTransport.swift */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; name = TCPTransport.swift; path = TCPTransport.swift; sourceTree = "<group>"; }};\n',
        f'\t\t{TCPTEST_FILEREF_ID} /* TCPTransportTests.swift */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = TCPTransportTests.swift; sourceTree = "<group>"; }};\n',
    ]
    # Find the PBXFileReference line for StdioTransport (not the build file or group reference)
    found = False
    for i, line in enumerate(lines):
        if STDIO_FILEREF_ID in line and 'PBXFileReference' in line:
            print(f"  [PBXFileReference] Found anchor at line {i+1}")
            lines = lines[:i+1] + file_ref_entries + lines[i+1:]
            found = True
            break
    if not found:
        print("  ERROR: PBXFileReference anchor not found")
        sys.exit(1)

    print("Step 3: Adding to Transport group children...")
    # Find StdioTransport in Transport group's children list
    # It's the line with STDIO_FILEREF_ID that is NOT in PBXBuildFile or PBXFileReference section
    # and does NOT contain "in Sources"
    found = False
    for i, line in enumerate(lines):
        if (STDIO_FILEREF_ID in line
            and 'StdioTransport.swift' in line
            and 'PBXFileReference' not in line
            and 'PBXBuildFile' not in line
            and 'in Sources' not in line):
            print(f"  [Transport Group] Found anchor at line {i+1}: {line.rstrip()[:80]}")
            insert = [f'\t\t\t\t{TCP_FILEREF_ID} /* TCPTransport.swift */,\n']
            lines = lines[:i+1] + insert + lines[i+1:]
            found = True
            break
    if not found:
        print("  ERROR: Transport group children anchor not found")
        sys.exit(1)

    print("Step 4: Adding to PlayCoverMCPTests group children...")
    # Find SessionReliabilityTests.swift in group children (not in Sources)
    found = False
    for i, line in enumerate(lines):
        if ('2542BBA788BC4BCFB2924607' in line
            and 'SessionReliabilityTests.swift' in line
            and 'in Sources' not in line):
            print(f"  [Tests Group] Found anchor at line {i+1}")
            insert = [f'\t\t\t\t{TCPTEST_FILEREF_ID} /* TCPTransportTests.swift */,\n']
            lines = lines[:i+1] + insert + lines[i+1:]
            found = True
            break
    if not found:
        print("  ERROR: Tests group children anchor not found")
        sys.exit(1)

    print("Step 5: Adding to PlayCover Sources build phase...")
    lines = insert_after(lines, '7ACFBF9F816249E5A9FDA859',
                         [f'\t\t\t\t{TCP_BUILD_GUI_ID} /* TCPTransport.swift in Sources */,\n'],
                         'PlayCover Sources')

    print("Step 6: Adding to PlayCoverMCP Sources build phase...")
    lines = insert_after(lines, '63E7EEA005D24C6090BDAD61',
                         [f'\t\t\t\t{TCP_BUILD_MCP_ID} /* TCPTransport.swift in Sources */,\n'],
                         'PlayCoverMCP Sources')

    print("Step 7: Adding to PlayCoverMCPTests Sources build phase...")
    lines = insert_after(lines, '95D4FBFC13B04BD3B5A42C0F',
                         [f'\t\t\t\t{TCP_BUILD_TEST_ID} /* TCPTransport.swift in Sources */,\n',
                          f'\t\t\t\t{TCPTEST_BUILD_ID} /* TCPTransportTests.swift in Sources */,\n'],
                         'PlayCoverMCPTests Sources')

    print("Writing modified pbxproj...")
    with open(PBXPROJ, 'w') as f:
        f.writelines(lines)

    print("Done! Now run: plutil -lint PlayCover.xcodeproj/project.pbxproj")
    return 0


if __name__ == '__main__':
    sys.exit(main())
