#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
ipa_tool.py —— IPA 就地编辑工具（Windows / macOS / Linux，纯 Python）

配合 RemoteDebug 用：运行时用 hook 快速验证，验证完把改动落到 IPA 里。

子命令：
    info                      Info.plist 摘要 + 可执行文件信息
    list [前缀]               列出包内文件
    get <路径> -o <文件>      导出包内文件
    plist-get <key>           读 Info.plist 的某项
    plist-set <key> <value>   改 Info.plist（类型自动推断）
    replace <路径> <文件>     用本地文件替换包内文件
    hexpatch <路径> <旧hex> <新hex> [--all]
                              在包内文件里做字节替换
    rm <路径>                 删除包内文件
    inject <dylib>            注入 dylib（转调 inject_ipa.py）

示例：
    python ipa_tool.py app.ipa info
    python ipa_tool.py app.ipa plist-set CFBundleDisplayName 我的App -o app2.ipa
    python ipa_tool.py app.ipa hexpatch Payload/App.app/App 00000014 00000015 --all
"""

import argparse
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import zipfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import inject_ipa as inj  # noqa: E402


def fail(msg):
    print("[x] %s" % msg)
    sys.exit(2)


def unpack(ipa, tmp):
    with zipfile.ZipFile(ipa, "r") as z:
        z.extractall(tmp)
    app = inj.find_app_bundle(tmp)
    if not app:
        fail("IPA 里找不到 .app")
    return app


def parse_value(s):
    low = s.lower()
    if low in ("true", "yes"):
        return True
    if low in ("false", "no"):
        return False
    try:
        return int(s)
    except ValueError:
        pass
    try:
        return float(s)
    except ValueError:
        pass
    return s


def load_plist(path):
    with open(path, "rb") as f:
        return plistlib.load(f)


def save_plist(path, data):
    fmt = plistlib.FMT_BINARY
    head = open(path, "rb").read(8)
    if head.startswith(b"<?xml"):
        fmt = plistlib.FMT_XML
    with open(path, "wb") as f:
        plistlib.dump(data, f, fmt=fmt)


def cmd_info(args):
    with tempfile.TemporaryDirectory() as tmp:
        app = unpack(args.ipa, tmp)
        pl = load_plist(os.path.join(app, "Info.plist"))
        exe_name = pl.get("CFBundleExecutable", "?")
        exe = os.path.join(app, exe_name)

        print("app        : %s" % os.path.basename(app))
        for k in ("CFBundleIdentifier", "CFBundleDisplayName", "CFBundleName",
                  "CFBundleShortVersionString", "CFBundleVersion",
                  "MinimumOSVersion", "CFBundleExecutable"):
            print("%-11s: %s" % (k.replace("CFBundle", ""), pl.get(k, "-")))

        if pl.get("UIFileSharingEnabled"):
            print("提示       : 开了 UIFileSharingEnabled，可以直接往 Documents 里塞文件")

        extra = [k for k in pl.keys() if k.lower().startswith("url") or "scheme" in k.lower()]
        if extra:
            print("URL 相关   : %s" % ", ".join(extra))

        if os.path.exists(exe):
            data = open(exe, "rb").read(0x4000)
            try:
                info = inj.scan_load_commands(data, 0)
                print("load cmd   : 结束于 0x%X，首个 section 0x%X，padding %d 字节"
                      % (info["lc_end_rel"], info["first_data_rel"],
                         info["first_data_rel"] - info["lc_end_rel"]))
                linked = [d for d in info["dylibs"] if "/System/" not in d
                          and "@rpath" not in d and "/usr/lib/" not in d]
                if linked:
                    print("已注入     :")
                    for d in linked:
                        print("             %s" % d)
            except inj.InjectError as e:
                print("load cmd   : 解析失败 %s" % e)
        else:
            print("可执行文件 : 缺失 %s" % exe_name)


def cmd_list(args):
    with tempfile.TemporaryDirectory() as tmp:
        app = unpack(args.ipa, tmp)
        base = tmp
        prefix = args.prefix or ""
        entries = []
        for dirpath, _dirs, files in os.walk(base):
            for f in files:
                full = os.path.join(dirpath, f)
                arc = os.path.relpath(full, base).replace("\\", "/")
                if arc.startswith(prefix):
                    entries.append((arc, os.path.getsize(full)))
        entries.sort()
        for arc, size in entries:
            print("%10d  %s" % (size, arc))
        print("--- %d 个文件" % len(entries))


def cmd_get(args):
    with tempfile.TemporaryDirectory() as tmp:
        app = unpack(args.ipa, tmp)
        src = os.path.join(tmp, args.path)
        if not os.path.exists(src):
            fail("包内没有 %s" % args.path)
        out = args.output or os.path.basename(args.path)
        shutil.copy2(src, out)
        print("[✓] 已导出 %s (%d 字节)" % (out, os.path.getsize(out)))


def cmd_plist_get(args):
    with tempfile.TemporaryDirectory() as tmp:
        app = unpack(args.ipa, tmp)
        pl = load_plist(os.path.join(app, "Info.plist"))
        cur = pl
        for part in args.key.split("."):
            if isinstance(cur, dict) and part in cur:
                cur = cur[part]
            elif isinstance(cur, list):
                try:
                    cur = cur[int(part)]
                except (ValueError, IndexError):
                    fail("路径不存在: %s" % args.key)
            else:
                fail("路径不存在: %s" % args.key)
        print(repr(cur))


def cmd_plist_set(args):
    out = args.output or (os.path.splitext(args.ipa)[0] + "-edited.ipa")
    with tempfile.TemporaryDirectory() as tmp:
        app = unpack(args.ipa, tmp)
        ppath = os.path.join(app, "Info.plist")
        pl = load_plist(ppath)

        keys = args.key.split(".")
        cur = pl
        for k in keys[:-1]:
            if not isinstance(cur.get(k), dict):
                cur[k] = {}
            cur = cur[k]
        old = cur.get(keys[-1], "<不存在>")
        cur[keys[-1]] = parse_value(args.value)
        save_plist(ppath, pl)

        # 删旧签名，避免重签冲突
        for junk in ("_CodeSignature", "SC_Info"):
            p = os.path.join(app, junk)
            if os.path.isdir(p):
                shutil.rmtree(p, ignore_errors=True)

        inj.repack_ipa(args.ipa, tmp, out)
        print("[✓] %s: %r -> %r" % (args.key, old, cur[keys[-1]]))
        print("    输出 %s" % out)
        print("    用 TrollStore 安装（会重签）")


def cmd_replace(args):
    if not os.path.exists(args.file):
        fail("本地文件不存在: %s" % args.file)
    out = args.output or (os.path.splitext(args.ipa)[0] + "-edited.ipa")
    with tempfile.TemporaryDirectory() as tmp:
        app = unpack(args.ipa, tmp)
        dst = os.path.join(tmp, args.path)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copy2(args.file, dst)
        for junk in ("_CodeSignature", "SC_Info"):
            p = os.path.join(app, junk)
            if os.path.isdir(p):
                shutil.rmtree(p, ignore_errors=True)
        inj.repack_ipa(args.ipa, tmp, out)
        print("[✓] 已替换 %s" % args.path)
        print("    输出 %s" % out)


def cmd_hexpatch(args):
    try:
        old = bytes.fromhex(args.old.replace(" ", ""))
        new = bytes.fromhex(args.new.replace(" ", ""))
    except ValueError as e:
        fail("hex 解析失败: %s" % e)
    if len(old) != len(new):
        fail("新旧长度必须一致（就地替换，不移动数据）")
    if not old:
        fail("旧 pattern 不能为空")

    out = args.output or (os.path.splitext(args.ipa)[0] + "-patched.ipa")
    with tempfile.TemporaryDirectory() as tmp:
        app = unpack(args.ipa, tmp)
        target = os.path.join(tmp, args.path)
        if not os.path.exists(target):
            fail("包内没有 %s" % args.path)

        data = open(target, "rb").read()
        count = data.count(old)
        if count == 0:
            fail("没找到这个字节序列")

        if args.all:
            data = data.replace(old, new)
            done = count
        else:
            idx = data.find(old)
            data = data[:idx] + new + data[idx + len(old):]
            done = 1

        open(target, "wb").write(data)
        for junk in ("_CodeSignature", "SC_Info"):
            p = os.path.join(app, junk)
            if os.path.isdir(p):
                shutil.rmtree(p, ignore_errors=True)
        inj.repack_ipa(args.ipa, tmp, out)
        print("[✓] 命中 %d 处，替换 %d 处" % (count, done))
        print("    输出 %s" % out)
        if count > done:
            print("    还剩 %d 处未替换，需要的话加 --all" % (count - done))


def cmd_rm(args):
    out = args.output or (os.path.splitext(args.ipa)[0] + "-edited.ipa")
    with tempfile.TemporaryDirectory() as tmp:
        app = unpack(args.ipa, tmp)
        target = os.path.join(tmp, args.path)
        if not os.path.exists(target):
            fail("包内没有 %s" % args.path)
        if os.path.isdir(target):
            shutil.rmtree(target)
        else:
            os.remove(target)
        for junk in ("_CodeSignature", "SC_Info"):
            p = os.path.join(app, junk)
            if os.path.isdir(p):
                shutil.rmtree(p, ignore_errors=True)
        inj.repack_ipa(args.ipa, tmp, out)
        print("[✓] 已删除 %s" % args.path)
        print("    输出 %s" % out)


def cmd_inject(args):
    script = os.path.join(os.path.dirname(os.path.abspath(__file__)), "inject_ipa.py")
    cmd = [sys.executable, script, args.ipa, "-d", args.dylib]
    if args.output:
        cmd += ["-o", args.output]
    sys.exit(subprocess.call(cmd))


class _Args(object):
    pass


def opt(rest, flag, takes_value=True):
    if flag in rest:
        i = rest.index(flag)
        if takes_value:
            if i + 1 >= len(rest):
                fail("%s 后面缺值" % flag)
            v = rest[i + 1]
            del rest[i:i + 2]
            return v
        del rest[i]
        return True
    return None


def main():
    argv = sys.argv[1:]
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__)
        return 0

    ipa = argv[0]
    if not os.path.exists(ipa):
        fail("找不到文件: %s" % ipa)
    if len(argv) < 2:
        print(__doc__)
        return 1

    cmd = argv[1]
    rest = argv[2:]

    a = _Args()
    a.ipa = ipa
    a.output = opt(rest, "-o") or opt(rest, "--output")
    a.all = bool(opt(rest, "--all", takes_value=False))

    try:
        if cmd == "info":
            return cmd_info(a)
        if cmd == "list":
            a.prefix = rest[0] if rest else ""
            return cmd_list(a)
        if cmd == "get":
            a.path = rest[0]
            return cmd_get(a)
        if cmd == "plist-get":
            a.key = rest[0]
            return cmd_plist_get(a)
        if cmd == "plist-set":
            a.key, a.value = rest[0], rest[1]
            return cmd_plist_set(a)
        if cmd == "replace":
            a.path, a.file = rest[0], rest[1]
            return cmd_replace(a)
        if cmd == "hexpatch":
            a.path, a.old, a.new = rest[0], rest[1], rest[2]
            return cmd_hexpatch(a)
        if cmd == "rm":
            a.path = rest[0]
            return cmd_rm(a)
        if cmd == "inject":
            a.dylib = rest[0]
            return cmd_inject(a)
    except IndexError:
        fail("参数不足\n\n" + __doc__)

    print(__doc__)
    return 1


if __name__ == "__main__":
    sys.exit(main())
