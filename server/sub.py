#!/usr/bin/env python3
"""订阅链接：每个用户一个带私密令牌的链接，手机 / 电脑的客户端从它拉配置，服务器这边一改就自动同步。

  server/sub.py url <name>        打印这个人的订阅页链接（没有令牌就新建，并推送）
  server/sub.py reset <name>      换新令牌（旧链接立刻失效）并推送
  server/sub.py publish [name…]   重新生成并推送（默认所有有令牌的人）；证书、线路、到期日变了都要跑一次
  server/sub.py drop <name>       从订阅服务删掉并作废令牌（users.sh del 会调）
  server/sub.py list              谁有订阅
  server/sub.py upload <名字> <文件> <版本>   上传别处编好的安装包（Mac 用户版：client/macos/build-user-app.sh 会调）
  server/sub.py apps              把 App 安装包（安卓 FlClash、电视 Clash Meta）的新版本从 GitHub 取来推到订阅服务（maint.sh 每天跑）
  server/sub.py rules             把国内分流规则（geosite-cn / geoip-cn）从 GitHub 取来推到订阅服务（maint.sh 每天跑）

订阅服务是 Cloudflare Worker（仓库 sub/，地址 site.env 的 SUB_BASE）。这里生成配置、用令牌派生的密钥加密后
PUT 上去：Cloudflare 上只有密文，按 sha256(令牌) 存；没有链接里的令牌谁也解不开，Worker 只在有人拿令牌来取时解密。
令牌在 secrets.env（<NAME>_SUB_TOKEN），推送用的管理口令在 $JPX_STATE/sub.env（SUB_ADMIN_TOKEN）。
每人还有一个 8 位的电视码（<NAME>_TV_CODE）：电视上用遥控器输入 <SUB_BASE>/t/<电视码>，内容和订阅一样，另存一份密文。
"""
import base64
import datetime
import hashlib
import hmac
import importlib.util
import json
import os
import re
import secrets as rnd
import subprocess
import sys
import time
import urllib.parse as up
import urllib.request

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib"))
import jpx  # noqa: E402

STATE = jpx.state_dir()
SECRETS = os.path.join(STATE, "secrets.env")


def make_config():
    spec = importlib.util.spec_from_file_location("make_config", os.path.join(jpx.REPO, "client", "make-config.py"))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


# ---------------------------------------------------------------- crypto (mirrored in sub/worker.js)
def keys(token):
    # "jp-exit-sub" (and "jp-exit clash api:" below) are the project's old name, kept as protocol constants: changing
    # them changes every key / id, and every subscription link already handed out stops working.
    """HKDF-SHA256(token) -> 32-byte AES key + 32-byte HMAC key; id = sha256 of the token, used as the storage key."""
    prk = hmac.new(b"jp-exit-sub", token.encode(), hashlib.sha256).digest()
    okm, t = b"", b""
    for i in (1, 2):
        t = hmac.new(prk, t + b"v1 enc+mac" + bytes([i]), hashlib.sha256).digest()
        okm += t
    return okm[:32], okm[32:], hashlib.sha256(b"jp-exit-sub:id:" + token.encode()).hexdigest()


def seal(token, data):
    """iv | AES-256-CBC(data) | HMAC-SHA256(iv | ct), base64. openssl does the AES (stdlib Python has none)."""
    ek, mk, _ = keys(token)
    iv = rnd.token_bytes(16)
    ct = subprocess.run(["openssl", "enc", "-aes-256-cbc", "-K", ek.hex(), "-iv", iv.hex()],
                        input=data, capture_output=True, check=True).stdout
    return base64.b64encode(iv + ct + hmac.new(mk, iv + ct, hashlib.sha256).digest()).decode()


def unseal(token, blob):
    ek, mk, _ = keys(token)
    raw = base64.b64decode(blob)
    iv, ct, tag = raw[:16], raw[16:-32], raw[-32:]
    if not hmac.compare_digest(tag, hmac.new(mk, iv + ct, hashlib.sha256).digest()):
        raise ValueError("bad tag")
    return subprocess.run(["openssl", "enc", "-d", "-aes-256-cbc", "-K", ek.hex(), "-iv", iv.hex()],
                          input=ct, capture_output=True, check=True).stdout


# ---------------------------------------------------------------- tokens in secrets.env
TV_ALPHABET = "23456789abcdefghjkmnpqrstuvwxyz"   # no 0/1/i/l/o: typed with a TV remote, read off a phone


def token_key(name, kind="SUB_TOKEN"):
    return f"{name.upper()}_{kind}"


def get_token(name, kind="SUB_TOKEN"):
    return jpx.parse_env(SECRETS).get(token_key(name, kind))


def new_tokens(name):
    set_token(name, base64.urlsafe_b64encode(rnd.token_bytes(24)).decode().rstrip("="))
    set_token(name, "".join(rnd.choice(TV_ALPHABET) for _ in range(8)), "TV_CODE")


def set_token(name, value, kind="SUB_TOKEN"):
    """Replace or append <NAME>_SUB_TOKEN / _TV_CODE (None removes it); the rest of the file stays byte-for-byte."""
    k = token_key(name, kind)
    with open(SECRETS) as fh:
        lines = [ln for ln in fh.read().splitlines(keepends=True) if not ln.startswith(k + "=")]
    if value:
        if lines and not lines[-1].endswith("\n"):
            lines[-1] += "\n"
        lines.append(f"{k}={value}\n")
    jpx.write_private(SECRETS, "".join(lines))


# ---------------------------------------------------------------- content
def export(name):
    out = subprocess.run([os.path.join(jpx.REPO, "server", "export-client.sh"), name],
                         capture_output=True, text=True, check=True).stdout
    return json.loads(out)


def shadowrocket(ex):
    """Shadowrocket subscription: base64 of one URI per line (the two HY2 nodes, cert pinned)."""
    prefix = jpx.site()["NODE_PREFIX"]
    sni = ex["server_domain"]
    q = up.urlencode({"sni": sni, "peer": sni, "insecure": "0", "pinSHA256": ex["cert_sha256"], "alpn": "h3"})
    lines = []
    for fam, host, port in (("v4", ex.get("server_v4_host") or ex["server_v4"], ex["hy2_v4_port"]),
                            ("v6", ex["server_domain"], ex["hy2_v6_port"])):
        lines.append(f"hysteria2://{up.quote(ex['hy2_password'], safe='')}@{host}:{port}/?{q}#{up.quote(prefix + '-HY2-' + fam)}")
    return base64.b64encode("\n".join(lines).encode()).decode()


def files_for(name):
    ex = export(name)
    meta = jpx.load_json(os.path.join(STATE, "users.json")).get(name, {}) if os.path.exists(os.path.join(STATE, "users.json")) else {}
    mc = make_config()
    s = jpx.site()
    app = s["APP_ID"]
    dump = lambda o: json.dumps(o, ensure_ascii=False, indent=2)
    # a stable local-API secret per account: a random one would make every publish look like a new config,
    # and each user's computer would drop its connection for a reconnect it does not need
    secret = hashlib.sha256(("jp-exit clash api:" + ex["hy2_password"]).encode()).hexdigest()[:24]
    return {
        # brand ... node_prefix: the names the Worker fills into the install page and the user-edition scripts
        "meta": json.dumps({"name": name, "expires": meta.get("expires"), "shared": name == s["SHARED_USER"], "tv": get_token(name, "TV_CODE"),
                            "brand": s["BRAND"], "app_id": app, "exit_name": s["EXIT_NAME"],
                            "exit_country": s.get("EXIT_COUNTRY", ""), "node_prefix": s["NODE_PREFIX"], "server_v4": s["SERVER_V4"],
                            "updated": datetime.datetime.now().astimezone().isoformat(timespec="seconds")}, ensure_ascii=False),
        "shadowrocket": shadowrocket(ex),
        # defaults=False: site/clients/_default.json is for the owner's own machines (their LAN), not other people's
        "singbox": dump(mc.build(ex, "mobile", rule_sets="remote", defaults=False)),
        "singbox-macos": dump(mc.build(ex, "macos", rule_sets="remote", data_dir=f"/Library/Application Support/{app}", defaults=False, clash_secret=secret)),
        "singbox-windows": dump(mc.build(ex, "windows", rule_sets="remote", data_dir=f"C:/ProgramData/{app}", defaults=False, clash_secret=secret)),
        # the Clash profile pulls its nodes from <record>/clash-proxies: filled in per record by publish()
        "clash": lambda base: ("# " + s["BRAND"] + "（" + name + "）。由服务器生成，节点每 6 小时自动更新；别手改。\n"
                               + mc.to_yaml(mc.build_clash(ex, provider_url=base + "/clash-proxies")) + "\n"),
        "clash-proxies": mc.to_yaml(mc.clash_nodes(ex)) + "\n",
    }


# ---------------------------------------------------------------- worker API
def admin():
    s = jpx.site()
    env = jpx.parse_env(os.path.join(STATE, "sub.env"))
    return s["SUB_BASE"].rstrip("/"), env["SUB_ADMIN_TOKEN"]


def call(method, path, body=None):
    base, tok = admin()
    req = urllib.request.Request(base + path, method=method, data=None if body is None else json.dumps(body).encode(),
                                 headers={"Authorization": "Bearer " + tok, "Content-Type": "application/json",
                                          "User-Agent": "home-vpn-sub/1"})
    with urllib.request.urlopen(req, timeout=20) as r:
        return r.read().decode()


def publish(name):
    """The same files twice: sealed under the link token and under the TV code (each only opens with its own)."""
    tok = get_token(name)
    if not tok:
        return False
    files = files_for(name)
    sub = jpx.site()["SUB_BASE"].rstrip("/")
    for kind, t in (("s", tok), ("t", get_token(name, "TV_CODE"))):
        if t:
            base = f"{sub}/{kind}/{t}"
            body = {k: seal(t, (v(base) if callable(v) else v).encode()) for k, v in files.items()}
            call("PUT", "/admin/u/" + keys(t)[2], {"files": body})
    return True


def unpublish(name):
    for kind in ("SUB_TOKEN", "TV_CODE"):
        t = get_token(name, kind)
        if t:
            call("DELETE", "/admin/u/" + keys(t)[2])
            set_token(name, None, kind)


def push_rules():
    """Mirror the CN rule sets (sing-box .srs, mihomo .mrs): subscription clients download them from the Worker,
    which is reachable before the tunnel is up."""
    mc = make_config()
    base, tok = admin()
    for t in ("geosite-cn", "geoip-cn"):
        for fname, src in ((f"{t}.srs", mc.RULE_URL.format(repo="sing-" + t.split("-")[0], tag=t)),
                           (f"{t}.mrs", mc.MRS_URL.format(kind=t.split("-")[0]))):
            push_rule(base, tok, fname, src)


def push_rule(base, tok, fname, src):
    with urllib.request.urlopen(src, timeout=60) as r:
        data = r.read()
    if len(data) < 1000:
        raise SystemExit(f"{fname}: 下载到的文件太小（{len(data)} 字节），不推")
    req = lambda: urllib.request.Request(f"{base}/admin/r/{fname}", method="PUT", data=data,
                                         headers={"Authorization": "Bearer " + tok, "User-Agent": "home-vpn-sub/1"})
    retry(lambda: urllib.request.urlopen(req(), timeout=60).close())
    print(f"✅ {fname} {len(data)} 字节")


def retry(fn, tries=3):
    for i in range(tries):
        try:
            return fn()
        except Exception:
            if i == tries - 1:
                raise
            time.sleep(5 * (i + 1))


# (R2 name, GitHub repo, asset name pattern): phones are arm64 nowadays; TVs often run a 32-bit system,
# and the armeabi-v7a build installs on both 32- and 64-bit ARM TVs
# sing-box for the Windows client is pinned (site.env SINGBOX_VERSION): the configs we generate follow its format.
APPS = [("flclash-android.apk", "chen08209/FlClash", r"FlClash-[\d.]+-android-arm64-v8a\.apk", None),
        ("clashmeta-tv.apk", "MetaCubeX/ClashMetaForAndroid", r"cmfa-[\d.]+-meta-armeabi-v7a-release\.apk", None),
        # a few newer boxes run a 64-bit-only system: the page offers this one when the first will not install
        ("clashmeta-tv-arm64.apk", "MetaCubeX/ClashMetaForAndroid", r"cmfa-[\d.]+-meta-arm64-v8a-release\.apk", None),
        ("sing-box-windows-amd64.zip", "SagerNet/sing-box", r"sing-box-[\d.]+-windows-amd64\.zip", "SINGBOX_VERSION"),
        ("sing-box-darwin-arm64.tar.gz", "SagerNet/sing-box", r"sing-box-[\d.]+-darwin-arm64\.tar\.gz", "SINGBOX_VERSION"),
        ("sing-box-darwin-amd64.tar.gz", "SagerNet/sing-box", r"sing-box-[\d.]+-darwin-amd64\.tar\.gz", "SINGBOX_VERSION")]


def push_apps():
    """New app releases from GitHub -> R2 (only when the version changed). The server is outside China: GitHub is fast from there."""
    base, tok = admin()
    have = json.loads(call("GET", "/admin/dl"))
    for name, repo, pat, pin in APPS:
        which = f"tags/v{jpx.site()[pin]}" if pin else "latest"
        rel = json.load(urllib.request.urlopen(urllib.request.Request(
            f"https://api.github.com/repos/{repo}/releases/{which}", headers={"User-Agent": "home-vpn-sub/1"}), timeout=30))
        asset = next((a for a in rel["assets"] if re.fullmatch(pat, a["name"])), None)
        if not asset:
            print(f"⚠️ {repo} {rel['tag_name']} 里没有匹配 {pat} 的安装包，跳过")
            continue
        if have.get(name, {}).get("version") == rel["tag_name"]:
            print(f"   {name} 已是 {rel['tag_name']}")
            continue
        with urllib.request.urlopen(asset["browser_download_url"], timeout=300) as r:
            data = r.read()
        if len(data) != asset["size"]:
            raise SystemExit(f"{asset['name']}: 下载不完整（{len(data)}/{asset['size']}）")
        req = lambda: urllib.request.Request(f"{base}/admin/dl/{name}", method="PUT", data=data,
                                             headers={"Authorization": "Bearer " + tok, "User-Agent": "home-vpn-sub/1",
                                                      "x-version": rel["tag_name"],
                                                      "Content-Type": "application/octet-stream"})
        retry(lambda: urllib.request.urlopen(req(), timeout=300).close())
        print(f"✅ {name} ← {asset['name']}（{len(data) // 1_000_000} MB）")


def page_url(name):
    return f"{jpx.site()['SUB_BASE'].rstrip('/')}/s/{get_token(name)}"


def people():
    return [n for n, _, _ in jpx.users(jpx.parse_env(SECRETS))]


def main():
    a = sys.argv[1:]
    cmd, rest = (a[0], a[1:]) if a else ("list", [])
    if cmd in ("url", "reset", "drop") and (len(rest) != 1 or rest[0] not in people()):
        sys.exit(f"用法：sub.py {cmd} <name>；现有用户：{' '.join(people())}")
    if cmd == "url":
        n = rest[0]
        if not get_token(n):
            new_tokens(n)
            publish(n)
        elif not get_token(n, "TV_CODE"):   # made before TV codes existed
            set_token(n, "".join(rnd.choice(TV_ALPHABET) for _ in range(8)), "TV_CODE")
            publish(n)
        print(page_url(n))
    elif cmd == "reset":   # new link AND new TV code; the old ones stop working at once
        n = rest[0]
        had = get_token(n)
        if had:
            unpublish(n)
        new_tokens(n)
        publish(n)
        print(page_url(n))
    elif cmd == "drop":
        n = rest[0]
        had = get_token(n)
        unpublish(n)
        print(f"✅ {n} 的订阅已删除" if had else f"{n} 没有订阅")
    elif cmd == "apps":
        push_apps()
    elif cmd == "upload":   # a file built elsewhere (the Mac user app): upload <name> <file> <version>
        if len(rest) != 3:
            sys.exit("用法：sub.py upload <名字> <文件> <版本>")
        base, tok = admin()
        data = open(rest[1], "rb").read()
        req = lambda: urllib.request.Request(f"{base}/admin/dl/{rest[0]}", method="PUT", data=data,
                                             headers={"Authorization": "Bearer " + tok, "User-Agent": "home-vpn-sub/1",
                                                      "x-version": rest[2], "Content-Type": "application/octet-stream"})
        retry(lambda: urllib.request.urlopen(req(), timeout=300).close())
        print(f"✅ {rest[0]} {rest[2]}（{len(data) // 1000} KB）")
    elif cmd == "publish":
        names = rest or [n for n in people() if get_token(n)]
        for n in names:
            print(("✅ 已推送 " if publish(n) else "跳过（没有订阅）") + n)
    elif cmd == "rules":
        push_rules()
    elif cmd == "list":
        for n in people():
            print(f"{n:<16} {'有订阅' if get_token(n) else '-'}")
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
