#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
selftest.py —— RemoteDebug 全接口自检

    python tools/selftest.py 10.4.37.156

只做只读 / 无害操作，不会改 app 状态（不点击、不装 hook、不改 UI）。
"""

import json
import sys
import time
import urllib.request

IP = sys.argv[1] if len(sys.argv) > 1 else "10.4.37.156"
BASE = "http://%s:8899" % IP

# 局域网直连，绕开所有代理
OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))

results = []


def call(path, method="GET", body=None, timeout=10):
    url = BASE + path
    data = body.encode("utf-8") if body is not None else None
    r = urllib.request.Request(url, data=data, method=method)
    t0 = time.time()
    try:
        with OPENER.open(r, timeout=timeout) as resp:
            raw = resp.read()
            return resp.status, raw, (time.time() - t0) * 1000, None
    except Exception as e:
        return 0, b"", (time.time() - t0) * 1000, "%s: %s" % (type(e).__name__, e)


def jload(raw):
    try:
        return json.loads(raw.decode("utf-8"))
    except Exception:
        return None


def check(name, path, method="GET", body=None, timeout=10):
    st, raw, ms, err = call(path, method, body, timeout)
    ok = False
    note = ""

    if err:
        note = err
    elif st != 200:
        note = "HTTP %d" % st
    else:
        j = jload(raw)
        if j is None:
            # 非 JSON（文本 / 图片）也算成功，说明一下类型
            if raw[:2] == b"\xff\xd8":
                ok = True
                note = "JPEG %d KB" % (len(raw) // 1024)
            else:
                ok = True
                note = "%d 字节文本" % len(raw)
        else:
            if j.get("ok") is False:
                note = "ok=false: %s" % str(j.get("error"))[:80]
            else:
                ok = True
                r = j.get("result")
                if isinstance(r, dict):
                    note = "keys=%s" % ",".join(list(r.keys())[:4])
                elif isinstance(r, list):
                    note = "%d 项" % len(r)
                elif isinstance(r, str):
                    note = r[:50].replace("\n", " ")
                elif r is not None:
                    note = str(r)[:50]
                else:
                    note = "ok"

    results.append((name, ok, ms, note))
    return ok, raw


def main():
    print("=" * 78)
    print("RemoteDebug 自检  ->  %s" % IP)
    print("=" * 78)

    # ---------- 基础 ----------
    ok, raw = check("ping", "/api/ping", timeout=5)
    if not ok:
        print("\n[!] 设备连不上，后续跳过。%s" % results[-1][3])
        return report()

    check("info", "/api/info")
    check("logs", "/api/logs?since=0")
    check("tools 列表", "/api/tools")
    check("hooks 列表", "/api/hooks")

    # ---------- UI ----------
    check("ui 层级", "/api/ui", timeout=15)
    check("ui 控制器栈", "/api/ui?vc=1")
    ok, raw = check("截图", "/api/screenshot.jpg?q=0.6", timeout=20)

    # ---------- 工具 ----------
    for tool in ["ui.tree", "ui.dump", "ui.vc", "screen.size", "pasteboard.get"]:
        check("工具 " + tool, "/api/tool?name=" + tool, timeout=15)

    # ---------- JS ----------
    check("eval 基础", "/api/eval", "POST", "'hello'")
    check("eval 调 block", "/api/eval", "POST", "_rd.version")
    check("eval NSInvocation",
          "/api/eval", "POST",
          "var u=_rd.call('NSUserDefaults','standardUserDefaults',[]);"
          "_rd.inst(u,'boolForKey:',['premium'])")
    check("eval 枚举 defaults 键",
          "/api/eval", "POST",
          "var u=_rd.call('NSUserDefaults','standardUserDefaults',[]);"
          "var d=_rd.inst(u,'dictionaryRepresentation',[]);"
          "Object.keys(d).length")

    # ---------- 反射（曾经崩过的地方） ----------
    check("classes Grow", "/api/classes?q=Grow", timeout=20)
    check("classes 空查询", "/api/classes", timeout=20)
    check("methods", "/api/methods?cls=Grow.GrowUser")
    check("props", "/api/props?cls=Grow.GrowUser&all=1")
    check("ivars", "/api/ivars?cls=Grow.GrowUser")
    check("find UILabel", "/api/find?cls=UILabel&limit=5")

    # ---------- 文件 ----------
    check("fs 根目录", "/api/fs?path=/")
    check("fs 沙盒",
          "/api/fs?path=/var/mobile/Library/RemoteDebug")
    check("读 crash.log",
          "/api/file?path=/var/mobile/Library/RemoteDebug/com.floatingislandapps.grow/crash.log",
          timeout=15)
    check("读 last.log",
          "/api/file?path=/var/mobile/Library/RemoteDebug/com.floatingislandapps.grow/last.log",
          timeout=15)

    # ---------- defaults ----------
    check("defaults 标准域", "/api/defaults", timeout=15)

    # ---------- 自定义工具 ----------
    defn = json.dumps({
        "name": "selftest.echo",
        "title": "自检",
        "group": "测试",
        "params": [{"name": "v", "type": "string", "required": False}],
        "code": "return 'echo:' + (args.v || 'none');"
    })
    ok, _ = check("tooldef 注册", "/api/tooldef", "POST", defn)
    if ok:
        check("tooldef 调用", "/api/tool?name=selftest.echo&v=abc")
        check("tooldef 删除", "/api/toolrm?name=selftest.echo")

    return report()


def report():
    print("\n%-26s %-6s %8s  %s" % ("项目", "结果", "耗时", "备注"))
    print("-" * 78)
    bad = 0
    for name, ok, ms, note in results:
        if not ok:
            bad += 1
        print("%-26s %-6s %7.0fms  %s" % (name, "OK" if ok else "FAIL", ms, note))
    print("-" * 78)
    print("共 %d 项，失败 %d 项" % (len(results), bad))
    return 0 if bad == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
