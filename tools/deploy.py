#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
deploy.py —— 把新编好的 dylib 推到手机沙盒（自更新）

    # 上传本地 dylib 并验证
    python tools/deploy.py 10.4.37.156 dist/RemoteDebug.dylib

    # 只看当前 stage 状态
    python tools/deploy.py 10.4.37.156 --status

    # 从 GitHub 拉最新 artifact 再上传
    python tools/deploy.py 10.4.37.156 --fetch <TOKEN> [RUN_ID]

说明：
    bundle 目录不可写（权限拒绝），所以不能原地替换 dylib。
    这里是把新 dylib 存到沙盒 Documents/RemoteDebug/stage/，
    由 dylib 自己决定要不要加载它。
"""

import json
import os
import sys
import tempfile
import urllib.request
import zipfile

OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))

GH_REPO = "lachek-bit/rd-dylib"
GH_PROXY = "http://127.0.0.1:7897"      # 需要时用，见坑 9
GH_TOKEN = None


def http(method, url, body=None, timeout=60):
    r = urllib.request.Request(url, data=body, method=method)
    with OPENER.open(r, timeout=timeout) as resp:
        return resp.status, resp.read()


def api(ip, path, timeout=30):
    st, raw = http("GET", "http://%s:8899%s" % (ip, path), timeout=timeout)
    try:
        return json.loads(raw.decode("utf-8"))
    except Exception:
        return {"ok": False, "error": raw[:200].decode("utf-8", "replace")}


def show(obj):
    print(json.dumps(obj, ensure_ascii=False, indent=1))


# --------------------------------------------------------------------------
# GitHub 拉包
# --------------------------------------------------------------------------

def gh_get(url, token):
    req = urllib.request.Request(url)
    req.add_header("Authorization", "Bearer %s" % token)
    req.add_header("Accept", "application/vnd.github+json")
    import ssl
    handler = urllib.request.ProxyHandler({"http": GH_PROXY, "https": GH_PROXY})
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    op = urllib.request.build_opener(handler,
                                     urllib.request.HTTPSHandler(context=ctx))
    with op.open(req, timeout=120) as r:
        return r.read()


def fetch_artifact(token, run_id=None):
    base = "https://api.github.com/repos/%s/actions" % GH_REPO
    if run_id is None:
        d = json.loads(gh_get(base + "/runs?per_page=1", token).decode())
        run_id = d["workflow_runs"][0]["id"]
        print("[*] 最新 run: %s (%s / %s)" % (
            run_id, d["workflow_runs"][0]["status"],
            d["workflow_runs"][0]["conclusion"]))

    d = json.loads(gh_get("%s/runs/%s/artifacts" % (base, run_id), token).decode())
    arts = d.get("artifacts") or []
    if not arts:
        raise SystemExit("[x] 这个 run 没有 artifact")
    aid = arts[0]["id"]
    print("[*] artifact: %s (%d 字节)" % (arts[0]["name"], arts[0]["size_in_bytes"]))

    blob = gh_get("%s/artifacts/%s/zip" % (base, aid), token)
    tmp = tempfile.mkdtemp()
    zp = os.path.join(tmp, "a.zip")
    open(zp, "wb").write(blob)
    with zipfile.ZipFile(zp) as z:
        for n in z.namelist():
            if n.endswith(".dylib"):
                out = os.path.join(tmp, "RemoteDebug.dylib")
                with z.open(n) as s, open(out, "wb") as f:
                    f.write(s.read())
                return out
    raise SystemExit("[x] zip 里没找到 dylib")


# --------------------------------------------------------------------------
# 主流程
# --------------------------------------------------------------------------

def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 1

    ip = sys.argv[1]
    args = sys.argv[2:]

    if not args or args[0] in ("-h", "--help"):
        print(__doc__)
        return 0

    if args[0] == "--status":
        show(api(ip, "/api/deploy/status"))
        return 0

    if args[0] == "--fetch":
        if len(args) < 2:
            print("[x] --fetch 后面要跟 token")
            return 1
        token = args[1]
        run_id = args[2] if len(args) > 2 else None
        path = fetch_artifact(token, run_id)
        print("[*] 已下载 ->", path, os.path.getsize(path), "字节")
    else:
        path = args[0]

    if not os.path.exists(path):
        print("[x] 找不到文件:", path)
        return 1

    data = open(path, "rb").read()
    print("[*] 上传 %d 字节 ..." % len(data))

    try:
        st, raw = http("POST", "http://%s:8899/api/deploy" % ip, data, timeout=120)
    except Exception as e:
        print("[x] 上传失败:", e)
        return 2
    print("[*] http", st)
    show(json.loads(raw.decode("utf-8")))

    print("\n[*] 验证 dlopen ...")
    r = api(ip, "/api/tool?name=deploy.test", timeout=60)
    show(r)

    res = r.get("result") or {}
    if res.get("ok"):
        print("\n[✓] 沙盒 dylib 能加载 —— 自更新可行")
        print("    下一步需要改造：同名 ObjC 类冲突 + 启动优先加载")
    else:
        print("\n[!] dlopen 不可用：", res.get("error"))
        print("    只能退回「自动打包 IPA + TrollStore 安装」")
    return 0


if __name__ == "__main__":
    sys.exit(main())
