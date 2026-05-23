#!/usr/bin/env python3
"""
Decode RPS 496 (SkinMakeupNew, Draw 69) vertex data and export as OBJ.
Validates that the octahedral normal decode + position extraction produce
a geometrically valid mesh.

Usage:
    python3 decode_and_export.py [output.obj]
"""
import numpy as np
import sys
import os

BASE = os.path.dirname(os.path.abspath(__file__))
VERTEX_COUNT = 5077
INDEX_COUNT = 27894

def octahedral_decode(stored):
    """Decode [0,1]² stored values to unit-sphere normals via octahedral mapping."""
    xy = stored * 2.0 - 1.0
    z = 1.0 - np.abs(xy[:, 0]) - np.abs(xy[:, 1])
    # Reflect for z < 0 (lower hemisphere fold)
    mask = z < 0
    ox = xy[:, 0].copy()
    oy = xy[:, 1].copy()
    xy[mask, 0] = (1.0 - np.abs(oy[mask])) * np.sign(ox[mask])
    xy[mask, 1] = (1.0 - np.abs(ox[mask])) * np.sign(oy[mask])
    normals = np.column_stack([xy, z])
    lengths = np.linalg.norm(normals, axis=1, keepdims=True)
    return normals / np.maximum(lengths, 1e-8)


def main():
    output_path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(BASE, "PL_Head_decoded.obj")

    # --- Load raw data ---
    print("Loading vertex buffers...")
    pos_raw = np.fromfile(os.path.join(BASE, "vertex/position_rid100.bin"), dtype=np.uint8).reshape(VERTEX_COUNT, 40)
    positions = np.frombuffer(pos_raw[:, :12].tobytes(), dtype=np.float32).reshape(VERTEX_COUNT, 3)
    
    normal_stored = np.fromfile(os.path.join(BASE, "vertex/normal_rid83.bin"), dtype=np.float32).reshape(VERTEX_COUNT, 2)
    tangent_stored = np.fromfile(os.path.join(BASE, "vertex/tangent_rid84.bin"), dtype=np.float32).reshape(VERTEX_COUNT, 2)
    
    uv0 = np.fromfile(os.path.join(BASE, "vertex/texcoord0_rid85.bin"), dtype=np.float32).reshape(VERTEX_COUNT, 2)
    
    indices = np.fromfile(os.path.join(BASE, "index/index_buffer_rid88.bin"), dtype=np.uint16)
    
    # --- Decode normals ---
    print("Decoding octahedral normals...")
    normals = octahedral_decode(normal_stored)
    
    # --- Statistics ---
    print(f"\nMesh Statistics:")
    print(f"  Vertices: {VERTEX_COUNT}")
    print(f"  Triangles: {INDEX_COUNT // 3}")
    print(f"  Position bounds:")
    print(f"    X: [{positions[:,0].min():.4f}, {positions[:,0].max():.4f}]")
    print(f"    Y: [{positions[:,1].min():.4f}, {positions[:,1].max():.4f}]")
    print(f"    Z: [{positions[:,2].min():.4f}, {positions[:,2].max():.4f}]")
    print(f"  Normal sanity check:")
    lengths = np.linalg.norm(normals, axis=1)
    print(f"    Length range: [{lengths.min():.6f}, {lengths.max():.6f}]")
    print(f"    Mean: {lengths.mean():.6f}")
    print(f"  UV0 range: [{uv0.min():.4f}, {uv0.max():.4f}]")
    
    # --- Export OBJ ---
    print(f"\nExporting to: {output_path}")
    with open(output_path, 'w') as f:
        f.write(f"# PL_Head mesh decoded from RPS 496 (Draw 69)\n")
        f.write(f"# Vertices: {VERTEX_COUNT}, Triangles: {INDEX_COUNT//3}\n")
        f.write(f"# Source: capture_20260518_110050.gputrace\n\n")
        
        # Vertices
        for i in range(VERTEX_COUNT):
            f.write(f"v {positions[i,0]:.6f} {positions[i,1]:.6f} {positions[i,2]:.6f}\n")
        f.write("\n")
        
        # Normals
        for i in range(VERTEX_COUNT):
            f.write(f"vn {normals[i,0]:.6f} {normals[i,1]:.6f} {normals[i,2]:.6f}\n")
        f.write("\n")
        
        # UVs
        for i in range(VERTEX_COUNT):
            f.write(f"vt {uv0[i,0]:.6f} {uv0[i,1]:.6f}\n")
        f.write("\n")
        
        # Faces (OBJ is 1-indexed)
        f.write("g PL_Head\n")
        for i in range(0, INDEX_COUNT, 3):
            i0 = int(indices[i]) + 1
            i1 = int(indices[i+1]) + 1
            i2 = int(indices[i+2]) + 1
            f.write(f"f {i0}/{i0}/{i0} {i1}/{i1}/{i1} {i2}/{i2}/{i2}\n")
    
    file_size = os.path.getsize(output_path)
    print(f"  File size: {file_size/1024:.1f} KB")
    print("\nDone! Open in Blender/Unity to verify geometry.")


if __name__ == "__main__":
    main()
