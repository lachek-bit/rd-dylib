#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
inject_ipa.py —— 给 IPA / .app 注入 dylib

纯 Python 实现，无需 insert_dylib / macOS 环境，Windows 可直接跑。
原理：在 Mach-O 的 load command 区里新增一条 LC_LOAD_DYLIB，
      只填充 header 与首个 section 之间的 padding，不移动任何数据。

用法：
    # 看一眼这个 IPA 里已经链接了哪些 dylib
    python inject_ipa.py app.ipa --check

    # 注入并输出新 IPA
    python inject_ipa.py app.ipa -d RemoteDebug.dylib -o app-debug.ipa

    # 只处理已解包的 .app 目录
    python inject_ipa.py Payload/App.app -d RemoteDebug.dylib
"""

import argparse
import os
import plistlib
import shutil
import struct
import sys
import tempfile
import zipfile

MH_MAGIC_64 = 0xFEEDFACF
MH_CIGAM_64 = 0xCFFAEDFE
FAT_MAGIC = 0xCAFEBABE
FAT_MAGIC_64 = 0xCAFEBABF

LC_SEGMENT_64 = 0x19
LC_LOAD_DYLIB = 0x0C
LC_LOAD_WEAK_DYLIB = 0x80000018
LC_REEXPORT_DYLIB = 0x8000001F
LC_CODE_SIGNATURE = 0x1D

CPU_ARM64 = 0x0100000C
CPU_ARM64E = 0x0100000C  # cpusubtype 区分，cputype 相同

DYLIB_CMD_HDR = 24  # dylib_command 固定部分


class InjectError(Exception):
    pass


# --------------------------------------------------------------------------
# Mach-O 解析
# --------------------------------------------------------------------------

def parse_macho_header(buf, base):
    """返回 (ncmds, sizeofcmds, is64)"""
    magic_le = struct.unpack_from('<I', buf, base)[0]
    if magic_le == MH_MAGIC_64:
        ncmds, sizeofcmds = struct.unpack_from('<II', buf, base + 16)
        return ncmds, sizeofcmds, True
    raise InjectError('不支持的 Mach-O 类型 (magic=0x%08X)，只处理 64 位 arm64' % magic_le)


def scan_load_commands(buf, base):
    ncmds, sizeofcmds, _ = parse_macho_header(buf, base)
    lc_start = base + 32
    lc_end_rel = 32 + sizeofcmds
    lc_end = base + lc_end_rel

    if lc_end > len(buf):
        raise InjectError('load command 区域越界，文件可能损坏')

    first_data = None
    dylibs = []
    has_codesig = False
    off = lc_start

    for _ in range(ncmds):
        if off + 8 > lc_end:
            raise InjectError('load command 遍历越界')
        cmd, cmdsize = struct.unpack_from('<II', buf, off)
        if cmdsize < 8:
            raise InjectError('load command 大小异常 (%d)' % cmdsize)

        if cmd == LC_SEGMENT_64:
            nsects = struct.unpack_from('<I', buf, off + 64)[0]
            s = off + 72
            for _ in range(nsects):
                sect_size = struct.unpack_from('<Q', buf, s + 40)[0]
                sect_off = struct.unpack_from('<I', buf, s + 48)[0]
                if sect_off > 0 and sect_size > 0:
                    if first_data is None or sect_off < first_data:
                        first_data = sect_off
                s += 80
        elif cmd in (LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB):
            name_off = struct.unpack_from('<I', buf, off + 8)[0]
            try:
                end = buf.index(b'\x00', off + name_off, off + cmdsize)
                dylibs.append(buf[off + name_off:end].decode('utf-8', 'replace'))
            except ValueError:
                dylibs.append('<parse-error>')
        elif cmd == LC_CODE_SIGNATURE:
            has_codesig = True

        off += cmdsize

    return {
        'ncmds': ncmds,
        'sizeofcmds': sizeofcmds,
        'lc_end_rel': lc_end_rel,
        'first_data_rel': first_data or 0x4000,
        'dylibs': dylibs,
        'has_codesig': has_codesig,
    }


def detect_fat(buf):
    """返回 [(cputype, cpusubtype, offset, size)] 或 None（thin）"""
    if len(buf) < 8:
        raise InjectError('文件太小')
    magic_be = struct.unpack_from('>I', buf, 0)[0]
    if magic_be not in (FAT_MAGIC, FAT_MAGIC_64):
        return None

    nfat = struct.unpack_from('>I', buf, 4)[0]
    if nfat == 0 or nfat > 16:
        raise InjectError('fat header 异常')

    archs = []
    if magic_be == FAT_MAGIC:
        off = 8
        for _ in range(nfat):
            cputype, cpusubtype, offset, size, align = struct.unpack_from('>iiIII', buf, off)
            archs.append((cputype, cpusubtype, offset, size))
            off += 20
    else:
        off = 8
        for _ in range(nfat):
            cputype, cpusubtype, offset, size, align, _r = struct.unpack_from('>iiIIII', buf, off)
            archs.append((cputype, cpusubtype, offset, size))
            off += 32
    return archs


def build_dylib_cmd(install_name):
    name = install_name.encode('utf-8') + b'\x00'
    cmdsize = DYLIB_CMD_HDR + len(name)
    cmdsize = (cmdsize + 7) & ~7
    payload = struct.pack('<IIIIII', LC_LOAD_DYLIB, cmdsize,
                          DYLIB_CMD_HDR, 2, 0x10000, 0x10000) + name
    return payload.ljust(cmdsize, b'\x00'), cmdsize


def inject_slice(buf, base, install_name):
    """在指定 slice 内注入一条 LC_LOAD_DYLIB，就地修改 buf"""
    info = scan_load_commands(buf, base)

    if install_name in info['dylibs']:
        return False, '已存在 %s，跳过' % install_name

    payload, cmdsize = build_dylib_cmd(install_name)

    need = info['lc_end_rel'] + cmdsize
    avail = info['first_data_rel']
    if need > avail:
        raise InjectError(
            'load command 空间不足：需要 %d 字节，首个 section 在 %d，'
            '只剩 %d 字节 padding。请改用 TrollFools 在设备上注入。'
            % (need, avail, avail - info['lc_end_rel']))

    buf[base + info['lc_end_rel']: base + need] = payload
    struct.pack_into('<II', buf, base + 16,
                     info['ncmds'] + 1,
                     info['sizeofcmds'] + cmdsize)
    return True, '注入完成（新增 %d 字节 load command，padding 剩余 %d）' % (
        cmdsize, avail - need)


def patch_macho(path, install_name, dry_run=False):
    with open(path, 'rb') as f:
        buf = bytearray(f.read())

    archs = detect_fat(buf)
    if archs is None:
        changed, msg = inject_slice(buf, 0, install_name)
        print('  [thin] %s' % msg)
    else:
        changed = False
        for cputype, cpusubtype, offset, size in archs:
            label = 'arm64e' if cputype == CPU_ARM64E and (cpusubtype & 0xFFFFFF) == 2 else \
                    'arm64' if cputype == CPU_ARM64 else 'cpu 0x%X' % cputype
            if cputype != CPU_ARM64:
                print('  [fat] 跳过 %s' % label)
                continue
            try:
                ch, msg = inject_slice(buf, offset, install_name)
                print('  [fat/%s] %s' % (label, msg))
                changed = changed or ch
            except InjectError as e:
                print('  [fat/%s] 失败: %s' % (label, e))

    if changed and not dry_run:
        with open(path, 'wb') as f:
            f.write(buf)
    return changed


# --------------------------------------------------------------------------
# IPA 打包处理
# --------------------------------------------------------------------------

def find_app_bundle(root):
    for dirpath, dirnames, _files in os.walk(root):
        for d in list(dirnames):
            if d.endswith('.app'):
                return os.path.join(dirpath, d)
    return None


def read_executable_name(app_dir):
    plist_path = os.path.join(app_dir, 'Info.plist')
    if not os.path.exists(plist_path):
        raise InjectError('找不到 Info.plist: %s' % plist_path)
    with open(plist_path, 'rb') as f:
        pl = plistlib.load(f)
    exe = pl.get('CFBundleExecutable')
    if not exe:
        raise InjectError('Info.plist 里没有 CFBundleExecutable')
    return exe


def repack_ipa(src_ipa, work_dir, out_ipa):
    """把 work_dir 内容按原 zip 条目顺序重打包"""
    old = zipfile.ZipFile(src_ipa, 'r')
    old_names = old.namelist()
    old_infos = {i.filename: i for i in old.infolist()}

    tmp_out = out_ipa + '.tmp'
    with zipfile.ZipFile(tmp_out, 'w', zipfile.ZIP_DEFLATED, compresslevel=6) as z:
        written = set()

        for name in old_names:
            disk = os.path.join(work_dir, name)
            if os.path.isdir(disk) or not os.path.exists(disk):
                continue
            info = old_infos.get(name)
            zi = zipfile.ZipInfo(name, date_time=info.date_time if info else (2020, 1, 1, 0, 0, 0))
            zi.compress_type = zipfile.ZIP_DEFLATED
            zi.external_attr = info.external_attr if info else 0o644 << 16
            with open(disk, 'rb') as f:
                z.writestr(zi, f.read())
            written.add(name)

        # 新增的文件（注入的 dylib 等）
        for dirpath, _dirnames, filenames in os.walk(work_dir):
            for fn in filenames:
                disk = os.path.join(dirpath, fn)
                arc = os.path.relpath(disk, work_dir).replace('\\', '/')
                if arc in written:
                    continue
                zi = zipfile.ZipInfo(arc, date_time=(2020, 1, 1, 0, 0, 0))
                zi.compress_type = zipfile.ZIP_DEFLATED
                zi.external_attr = 0o755 << 16
                with open(disk, 'rb') as f:
                    z.writestr(zi, f.read())
                written.add(arc)

    old.close()
    if os.path.exists(out_ipa):
        os.remove(out_ipa)
    os.replace(tmp_out, out_ipa)


def sign_if_possible(path):
    ldid = shutil.which('ldid')
    if not ldid:
        return '未找到 ldid，跳过签名（TrollStore 安装时会重签，一般无碍）'
    rc = os.system('"%s" -S "%s"' % (ldid, path))
    return '已用 ldid 做 ad-hoc 签名' if rc == 0 else 'ldid 签名失败（rc=%d）' % rc


def main():
    ap = argparse.ArgumentParser(description='给 IPA / .app 注入 dylib')
    ap.add_argument('target', help='输入 .ipa 或 .app 路径')
    ap.add_argument('-d', '--dylib', help='要注入的 dylib 文件')
    ap.add_argument('-o', '--output', help='输出 ipa 路径（默认 <输入名>-debug.ipa）')
    ap.add_argument('-n', '--name', help='dylib 在 app 内的相对路径'
                                          '（默认 @executable_path/<dylib 文件名>）')
    ap.add_argument('--check', action='store_true', help='只打印信息，不做修改')
    args = ap.parse_args()

    target = os.path.abspath(args.target)
    if not os.path.exists(target):
        print('找不到文件: %s' % target)
        return 1

    is_ipa = target.lower().endswith('.ipa')
    is_app = target.lower().endswith('.app')

    if not is_ipa and not is_app:
        print('目标必须是 .ipa 或 .app')
        return 1

    if not args.check and not args.dylib:
        print('需要 -d 指定 dylib 文件')
        return 1

    dylib_path = os.path.abspath(args.dylib) if args.dylib else None
    if dylib_path and not os.path.exists(dylib_path):
        print('找不到 dylib: %s' % dylib_path)
        return 1

    work_root = None
    try:
        if is_ipa:
            work_root = tempfile.mkdtemp(prefix='ipa_inject_')
            print('[*] 解压 IPA ...')
            with zipfile.ZipFile(target, 'r') as z:
                z.extractall(work_root)
            app_dir = find_app_bundle(work_root)
            if not app_dir:
                raise InjectError('IPA 里找不到 .app')
        else:
            app_dir = target

        exe_name = read_executable_name(app_dir)
        exe_path = os.path.join(app_dir, exe_name)
        if not os.path.exists(exe_path):
            raise InjectError('找不到可执行文件: %s' % exe_path)

        print('[*] app        : %s' % app_dir)
        print('[*] executable : %s' % exe_name)

        with open(exe_path, 'rb') as f:
            head = f.read(0x4000)
        info = scan_load_commands(head, 0)
        print('[*] 已链接 dylib:')
        for d in info['dylibs']:
            print('      %s' % d)
        if not info['dylibs']:
            print('      (无)')
        print('[*] load command 结束于 0x%X，首个 section 偏移 0x%X，可用 padding %d 字节'
              % (info['lc_end_rel'], info['first_data_rel'],
                 info['first_data_rel'] - info['lc_end_rel']))

        if args.check:
            print('[=] --check 模式，未做任何修改')
            return 0

        install_name = args.name or ('@executable_path/' + os.path.basename(dylib_path))

        # 1. 放入 dylib
        dst_dylib = os.path.join(app_dir, install_name.replace('@executable_path/', ''))
        os.makedirs(os.path.dirname(dst_dylib), exist_ok=True)
        shutil.copy2(dylib_path, dst_dylib)
        print('[+] dylib 已放入 %s' % os.path.relpath(dst_dylib, app_dir))

        # 2. 注入 load command
        print('[*] 注入 LC_LOAD_DYLIB: %s' % install_name)
        changed = patch_macho(exe_path, install_name)
        if not changed:
            print('[!] 没有发生修改')

        # 3. 删除旧签名，避免 TrollStore/ldid 重签时冲突
        for junk in ('_CodeSignature', 'SC_Info'):
            p = os.path.join(app_dir, junk)
            if os.path.isdir(p):
                shutil.rmtree(p, ignore_errors=True)
                print('[+] 已删除 %s' % junk)

        # 4. 顺手签一下 dylib
        print('[+] %s' % sign_if_possible(dst_dylib))

        # 5. 重新打包
        if is_ipa:
            out = args.output or (os.path.splitext(target)[0] + '-debug.ipa')
            print('[*] 重新打包 -> %s' % out)
            repack_ipa(target, work_root, out)
            size = os.path.getsize(out) / 1024 / 1024
            print('[✓] 完成，%.1f MB' % size)
            print('    用 TrollStore 安装这个 IPA 即可（会二次签名）')
        else:
            print('[✓] 完成，%s 已就地修改' % app_dir)

        return 0
    except InjectError as e:
        print('[x] 失败: %s' % e)
        return 2
    finally:
        if work_root and os.path.isdir(work_root):
            shutil.rmtree(work_root, ignore_errors=True)


if __name__ == '__main__':
    sys.exit(main())
