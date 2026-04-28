#!/usr/bin/env python3
"""Check NGR ASLR slide in LLDB."""
import lldb

def __lldb_init_module(debugger, internal_dict):
    target = debugger.GetSelectedTarget()
    if not target or not target.IsValid():
        print("[check-slide] No valid target")
        return
    print(f"[check-slide] Target: {target}")
    print(f"[check-slide] Modules count: {target.GetNumModules()}")
    for i in range(target.GetNumModules()):
        mod = target.GetModuleAtIndex(i)
        filespec = mod.GetFileSpec()
        print(f"  [{i}] {filespec.GetFilename()} @ {mod.GetUUIDString()}")
        if filespec.GetFilename() == "NGR":
            text = mod.FindSection("__TEXT")
            if text and text.IsValid():
                slid = text.GetLoadAddress(target)
                print(f"      __TEXT load address: 0x{slid:x}")
                print(f"      slide: 0x{slid - 0x100000000:x}")
