#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
macho_info.py —— 静态分析 dylib / Mach-O

    python macho_info.py xxx.dylib          # 概览
    python macho_info.py xxx.dylib -s       # 只看字符串
    python macho_info.py xxx.dylib -y       # 只看符号
    python macho_info.py xxx.dylib -k 点击   # 按关键字过滤
"""

import os
import struct
import sys

MH_MAGIC_64 = 0xFEEDFACF
FAT_MAGIC = 0xCAFEBABE
FAT_MAGIC_64 = 0xCAFEBABF

LC_SEGMENT_64 = 0x19
LC_SYMTAB = 0x2
LC_LOAD_DYLIB = 0x0C
LC_LOAD_WEAK_DYLIB = 0x80000018
LC_REEXPORT_DYLIB = 0x8000001F
LC_ID_DYLIB = 0x0D
LC_LOAD_DYLINKER = 0xE
LC_UUID = 0x1B
LC_BUILD_VERSION = 0x32
LC_VERSION_MIN_IPHONEOS = 0x25
LC_RPATH = 0x8000001C
LC_CODE_SIGNATURE = 0x1D

CPU = {0x0100000C: "arm64", 0x01000007: "x86_64", 0x0000000C: "arm", 0x00000007: "i386"}


def cstr(buf, off, limit=400):
    end = buf.find(b"\x00", off, off + limit)
    if end < 0:
        end = off + limit
    return buf[off:end].decode("utf-8", "replace")


def parse_slice(buf, base, label, verbose):
    out = {"label": label, "dylibs": [], "sections": [], "symtab": None,
           "platform": "", "rpaths": [], "id": ""}

    ncmds, sizeofcmds = struct.unpack_from("<II", buf, base + 16)
    off = base + 32
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", buf, off)
        if cmdsize < 8:
            break

        if cmd in (LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB, LC_ID_DYLIB):
            noff = struct.unpack_from("<I", buf, off + 8)[0]
            name = cstr(buf, off + noff, cmdsize)
            if cmd == LC_ID_DYLIB:
                out["id"] = name
            else:
                out["dylibs"].append(name)

        elif cmd == LC_RPATH:
            noff = struct.unpack_from("<I", buf, off + 8)[0]
            out["rpaths"].append(cstr(buf, off + noff, cmdsize))

        elif cmd == LC_SEGMENT_64:
            segname = buf[off + 8:off + 24].rstrip(b"\x00").decode("ascii", "replace")
            nsects = struct.unpack_from("<I", buf, off + 64)[0]
            s = off + 72
            for _ in range(nsects):
                sect = buf[s:s + 16].rstrip(b"\x00").decode("ascii", "replace")
                seg2 = buf[s + 16:s + 32].rstrip(b"\x00").decode("ascii", "replace")
                addr, size = struct.unpack_from("<QQ", buf, s + 32)
                soff = struct.unpack_from("<I", buf, s + 48)[0]
                out["sections"].append((seg2, sect, soff, size))
                s += 80

        elif cmd == LC_SYMTAB:
            symoff, nsyms, stroff, strsize = struct.unpack_from("<IIII", buf, off + 8)
            out["symtab"] = (symoff, nsyms, stroff, strsize)

        elif cmd == LC_BUILD_VERSION:
            platform, minos, sdk = struct.unpack_from("<III", buf, off + 8)
            out["platform"] = "platform=%d minos=0x%x sdk=0x%x" % (platform, minos, sdk)

        elif cmd == LC_VERSION_MIN_IPHONEOS:
            v, sdk = struct.unpack_from("<II", buf, off + 8)
            out["platform"] = "iphoneos min=0x%x sdk=0x%x" % (v, sdk)

        off += cmdsize
    return out


def collect_strings(buf, info, minlen=4):
    res = []
    for seg, sect, soff, size in info["sections"]:
        if sect not in ("__cstring", "__objc_methname", "__objc_classname",
                        "__objc_methtype", "__ustring"):
            continue
        if soff == 0 or size == 0 or soff >= len(buf):
            continue
        chunk = buf[soff:soff + size]
        cur = []
        for b in chunk:
            if 32 <= b < 127:
                cur.append(chr(b))
            else:
                if len(cur) >= minlen:
                    res.append((sect, "".join(cur)))
                cur = []
        if len(cur) >= minlen:
            res.append((sect, "".join(cur)))
    return res


def collect_symbols(buf, info):
    if not info["symtab"]:
        return []
    symoff, nsyms, stroff, strsize = info["symtab"]
    out = []
    for i in range(nsyms):
        p = symoff + i * 16
        if p + 16 > len(buf):
            break
        n_strx, n_type, n_sect, n_desc, n_value = struct.unpack_from("<IBBHQ", buf, p)
        if n_strx == 0 or stroff + n_strx >= len(buf):
            continue
        name = cstr(buf, stroff + n_strx)
        if name:
            out.append((name, n_type & 0x0E, n_sect, n_value))
    return out


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    path = sys.argv[1]
    only_str = "-s" in sys.argv
    only_sym = "-y" in sys.argv
    kw = None
    if "-k" in sys.argv:
        kw = sys.argv[sys.argv.index("-k") + 1]

    buf = open(path, "rb").read()
    print("=" * 70)
    print("%s  (%.1f KB)" % (os.path.basename(path), len(buf) / 1024.0))

    slices = []
    magic_be = struct.unpack_from(">I", buf, 0)[0]
    if magic_be in (FAT_MAGIC, FAT_MAGIC_64):
        nfat = struct.unpack_from(">I", buf, 4)[0]
        print("fat, %d slices" % nfat)
        off = 8
        step = 20 if magic_be == FAT_MAGIC else 32
        for _ in range(nfat):
            cputype, csub, offset, size = struct.unpack_from(">iiII", buf, off)
            slices.append((offset, size, CPU.get(cputype, hex(cputype))))
            off += step
    else:
        slices.append((0, len(buf), "?"))

    infos = []
    for offset, size, label in slices:
        if offset + 4 > len(buf):
            continue
        m = struct.unpack_from("<I", buf, offset)[0]
        if m != MH_MAGIC_64:
            print("  slice %s: 不是 64 位 Mach-O" % label)
            continue
        cputype, csub, ftype = struct.unpack_from("<iiI", buf, offset + 4)
        label = CPU.get(cputype, hex(cputype))
        info = parse_slice(buf, offset, label, True)
        infos.append((offset, info))
        print("\n[slice %s]  filetype=%d  %s" % (label, ftype, info["platform"]))
        if info["id"]:
            print("  install_name: %s" % info["id"])
        print("  依赖:")
        if not info["dylibs"]:
            print("    (无)")
        for d in info["dylibs"]:
            mark = ""
            if "substrate" in d.lower() or "ellekit" in d.lower() or "tweak" in d.lower():
                mark = "   <-- hook 框架"
            print("    %s%s" % (d, mark))
        if info["rpaths"]:
            print("  rpaths: %s" % ", ".join(info["rpaths"]))

    if not only_str and not only_sym:
        for offset, info in infos:
            syms = collect_symbols(buf, info)
            print("\n  符号: %d 个 (导出)" % len(syms))
            for name, t, sect, val in syms[:40]:
                if t == 0x0E:
                    print("    + %s" % name)
            if len(syms) > 40:
                print("    ... 共 %d 个" % len(syms))

    if only_sym:
        for offset, info in infos:
            print("\n--- 符号 ---")
            for name, t, sect, val in collect_symbols(buf, info):
                if kw and kw not in name:
                    continue
                print(name)

    if only_str or kw:
        print("\n--- 字符串 ---")
        seen = set()
        for offset, info in infos:
            for sect, s in collect_strings(buf, info):
                if kw and kw not in s:
                    continue
                if s in seen:
                    continue
                seen.add(s)
                print(s)
        print("(共 %d 条)" % len(seen))

    return 0


if __name__ == "__main__":
    sys.exit(main())
