#!/usr/bin/env python3
"""Build a sing-box TUN client config from server/export-client.sh output (JSON on stdin).

  make-config.py --platform macos|windows|mobile [--profile site/clients/<name>.json] [--remote-rules]
                 [--data-dir DIR] [--keep-secret-from OLD.json] [--out FILE]

One place defines the client policy for every computer:
  - nodes: Home-HY2-v6 / Home-HY2-v4 (UDP, fast) and Home-STLS-v6 / -v4 (TCP ShadowTLS, ~0.4 Mbps, emergency only)
  - "⚡ 自动(HY2)" urltest over the two HY2 nodes only, v4 first. STLS stays out: it has the LOWEST latency but
    almost no bandwidth, so a latency test would pick it. v4 first: when nothing has been tested yet (or both fail)
    urltest uses the first member, and v4 works on networks with and without IPv6.
  - "🏠 Home" / "🤖 Claude" selectors default to the auto group; the single nodes stay selectable by hand.
  - Claude domains only via the exit (no direct fallback); CN sites/IPs direct; everything else via the exit.
Per-computer differences (extra rules, MTU, upload rate, auto_members) come from --profile.
"""
import argparse
import json
import os
import secrets as rnd
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib"))
import jpx  # noqa: E402

AUTO, HOME, CLAUDE = "⚡ 自动(HY2)", "🏠 Home", "🤖 Claude"
CN_AUTO, CN_SITES = "🇨🇳 回国", "🇨🇳 国内"
CLAUDE_DOMAINS = ["anthropic.com", "claude.ai", "claude.com", "claudeusercontent.com", "clau.de"]
NETFLIX = ["netflix.com", "netflix.net", "nflxext.com", "nflximg.com", "nflximg.net", "nflxso.net", "nflxvideo.net"]
PLATFORM = {
    "macos": {"mtu": 1500, "data_dir": None, "log": None},          # data_dir: ~/<CLIENT_NAME>/data (site.env)
    "windows": {"mtu": 9000, "data_dir": "C:/ProgramData/sing-box", "log": "C:/ProgramData/sing-box/sing-box.log"},
    # the sing-box apps (Android SFA / iOS SFI) through a subscription: they own logging, the dashboard and the data dir
    "mobile": {"mtu": 9000, "data_dir": None, "log": None},
}
RULE_URL = "https://raw.githubusercontent.com/SagerNet/{repo}/rule-set/{tag}.srs"   # upstream; server/sub.py mirrors it


def merged_profile(profile, defaults=True):
    """site/clients/_default.json + the machine's profile: lists concatenate (default first), other keys: machine wins.
    defaults=False for other people's devices (subscriptions): _default.json holds the owner's own machines' rules."""
    path = os.path.join(jpx.site_dir(), "clients", "_default.json")
    if not defaults:
        return jpx.strip_comments(profile or {})
    base = jpx.strip_comments(jpx.load_json(path)) if os.path.exists(path) else {}
    out = dict(base)
    for k, v in jpx.strip_comments(profile or {}).items():
        out[k] = base.get(k, []) + v if isinstance(v, list) and isinstance(base.get(k), list) else v
    return out


# user editions (installed from a subscription) get their own TUN addresses and API port: they never clash with the
# owner's client on the same machine, and the owner can test a user install without stopping their own VPN
USER_EDITION = {"tun": ["172.18.0.1/30", "fdfe:dcba:9875::1/126"], "api": "127.0.0.1:19090"}


def build(ex, platform, profile=None, data_dir=None, clash_secret=None, cn_ex=None, rule_sets="local", defaults=True):
    """cn_ex: export of the 回国 account. When given, the config gets a mode switch: "🇨🇳 国内" (CN sites + their DNS)
    is direct at home in China, or goes through the China desktop ("🇨🇳 回国") when abroad; "🏠 Home" can be
    set to direct abroad. Two selectors, no restart; the menu bar app switches them together.
    rule_sets="remote": the CN rule sets are downloaded (through the exit) and kept in the cache file instead of being
    local files: for subscription clients, which only get this one JSON."""
    profile = merged_profile(profile, defaults)
    site = jpx.site()
    plat = PLATFORM[platform]
    if platform == "macos" and not (data_dir or plat["data_dir"]):
        data_dir = f"~/{site['CLIENT_NAME']}/data"
    data_dir = (data_dir or plat["data_dir"] or "").rstrip("/")
    if platform == "macos":
        data_dir = os.path.expanduser(data_dir)
    # up 0 = no Brutal on upload (BBR adapts to whatever network a laptop is on); a fixed machine can pin a
    # measured rate in its profile. down stays Brutal: it is what keeps downloads fast when the path loses packets.
    up = profile.get("hy2_up_mbps", site["HY2_UP_MBPS"])
    down = profile.get("hy2_down_mbps", site["HY2_DOWN_MBPS"])
    hy2_tls = {"enabled": True, "server_name": ex["server_domain"], "alpn": ["h3"],
               "certificate": ex["cert_pem"].strip().split("\n")}
    stls_tls = {"enabled": True, "server_name": ex["stls_handshake"], "utls": {"enabled": True, "fingerprint": "chrome"}}

    def hy2(tag, server, port, password=None):
        o = {"type": "hysteria2", "tag": tag, "server": server, "server_port": port, "password": password or ex["hy2_password"]}
        if up:
            o["up_mbps"] = up
        o["down_mbps"] = down
        o["tls"] = hy2_tls
        return o

    def stls(fam, server):
        return [
            {"type": "shadowtls", "tag": "stls-" + fam, "server": server, "server_port": ex["stls_port"],
             "version": 3, "password": ex["stls_password"], "tls": stls_tls},
            {"type": "shadowsocks", "tag": "Home-STLS-" + fam, "method": ex["ss_method"], "password": ex["ss_password"],
             "detour": "stls-" + fam, "udp_over_tcp": {"enabled": True, "version": 2}},
        ]

    v4 = ex.get("server_v4_host") or ex["server_v4"]      # a name that follows the home IPv4 (DDNS), else the IP
    manual = ["Home-HY2-v6", "Home-HY2-v4", "Home-STLS-v6", "Home-STLS-v4"]
    outbounds = [
        hy2("Home-HY2-v6", ex["server_domain"], ex["hy2_v6_port"]),
        hy2("Home-HY2-v4", v4, ex["hy2_v4_port"]),
        *stls("v4", v4),
        *stls("v6", ex["server_domain"]),
        {"type": "urltest", "tag": AUTO, "outbounds": profile.get("auto_members", ["Home-HY2-v4", "Home-HY2-v6"]),
         "url": "https://www.gstatic.com/generate_204", "interval": "1m", "tolerance": 100,
         "idle_timeout": "30m", "interrupt_exist_connections": True},
        {"type": "selector", "tag": HOME, "outbounds": [AUTO] + manual, "default": AUTO, "interrupt_exist_connections": True},
        {"type": "selector", "tag": CLAUDE, "outbounds": [AUTO] + manual, "default": AUTO, "interrupt_exist_connections": True},
        {"type": "direct", "tag": "direct"},
    ]
    cn_target = "direct"
    if cn_ex:
        cn_nodes = ["回国-HY2-v4", "回国-HY2-v6"]
        outbounds[-1:-1] = [
            hy2("回国-HY2-v4", v4, ex["hy2_v4_port"], cn_ex["hy2_password"]),
            hy2("回国-HY2-v6", ex["server_domain"], ex["hy2_v6_port"], cn_ex["hy2_password"]),
            {"type": "urltest", "tag": CN_AUTO, "outbounds": cn_nodes, "url": "https://www.baidu.com/favicon.ico",
             "interval": "1m", "tolerance": 100, "idle_timeout": "30m", "interrupt_exist_connections": True},
            {"type": "selector", "tag": CN_SITES, "outbounds": ["direct", CN_AUTO], "default": "direct",
             "interrupt_exist_connections": True},
        ]
        next(o for o in outbounds if o["tag"] == HOME)["outbounds"].append("direct")   # abroad: non-CN traffic direct
        cn_target = CN_SITES
    rules = [
        {"action": "sniff"},
        {"protocol": "dns", "action": "hijack-dns"},
        *profile.get("rules_before_private", []),
        {"ip_is_private": True, "outbound": "direct"},
        *profile.get("rules_after_private", []),
        {"domain_suffix": CLAUDE_DOMAINS, "outbound": CLAUDE},
        {"domain_suffix": NETFLIX, "outbound": HOME},
        {"rule_set": ["geosite-cn", "geoip-cn"], "outbound": cn_target},
    ]
    inbounds = [{"type": "tun", "tag": "tun-in",
                 "address": USER_EDITION["tun"] if not defaults else ["172.19.0.1/30", "fdfe:dcba:9876::1/126"],
                 "auto_route": True, "strict_route": True, "stack": "gvisor",
                 "mtu": profile.get("tun_mtu", plat["mtu"])}]
    if profile.get("cn_exit_listen_port"):
        # this machine IS the 回国 exit: a loopback-only SOCKS entry that the ssh reverse tunnel exposes on the
        # server; whatever comes in here leaves directly with this home line's China IP
        inbounds.append({"type": "socks", "tag": "cn-exit-in", "listen": "127.0.0.1",
                         "listen_port": profile["cn_exit_listen_port"]})
        rules.insert(0, {"inbound": ["cn-exit-in"], "outbound": "direct"})
    dns_servers = [{"type": "udp", "tag": "local", "server": "223.5.5.5"},
                   {"type": "https", "tag": "remote", "server": "8.8.8.8", "detour": HOME}]
    cn_dns = "local"
    if cn_ex:
        # CN names are resolved from wherever CN traffic leaves (China DNS answers depend on where you ask from)
        dns_servers.append({"type": "https", "tag": "cn", "server": "223.5.5.5", "detour": CN_SITES})
        cn_dns = "cn"
    log = {"level": "warn", "timestamp": True}
    if platform == "windows":
        log["output"] = f"{data_dir}/sing-box.log"
    elif plat["log"]:
        log["output"] = plat["log"]
    experimental = {"cache_file": {"enabled": True, "store_rdrc": False}}
    if platform != "mobile":
        experimental["clash_api"] = {"external_controller": USER_EDITION["api"] if not defaults else "127.0.0.1:9090",
                                     "secret": clash_secret or rnd.token_hex(12), "default_mode": "rule"}
        if defaults:   # the owner's machines keep the web dashboard; user editions have their own menu / tray
            experimental["clash_api"].update({"external_ui": "ui", "external_ui_download_detour": HOME,
                "external_ui_download_url": "https://github.com/Zephyruso/zashboard/releases/latest/download/dist.zip"})
    if platform == "macos" and rule_sets == "remote":
        experimental["cache_file"]["path"] = f"{data_dir}/cache.db"
    return {
        "log": log,
        "dns": {
            "servers": dns_servers,
            "rules": [{"rule_set": "geosite-cn", "server": cn_dns}, {"domain_suffix": [".cn"], "server": cn_dns}],
            "final": "remote",
            "strategy": "prefer_ipv6",
        },
        "inbounds": inbounds,
        "outbounds": outbounds,
        "route": {
            "rules": rules,
            "rule_set": [{"type": "local", "tag": t, "format": "binary", "path": f"{data_dir}/{t}.srs"}
                         if rule_sets == "local" else
                         # from the subscription service, directly: it must work before the tunnel does (sing-box
                         # refuses to start when a remote rule set cannot be fetched and none is cached yet).
                         # download_detour, not 1.14's http_client: the phone apps may still ship an older core
                         # that rejects unknown fields; 1.14 only warns (removal is planned for 1.16).
                         {"type": "remote", "tag": t, "format": "binary", "update_interval": "7d", "download_detour": "direct",
                          "url": f"{site['SUB_BASE'].rstrip('/')}/rules/{t}.srs" if site.get("SUB_BASE")
                          else RULE_URL.format(repo="sing-" + t.split("-")[0], tag=t)}
                         for t in ("geosite-cn", "geoip-cn")],
            "final": HOME,
            "auto_detect_interface": True,
            "default_domain_resolver": {"server": "local"},
        },
        "experimental": experimental,
    }


# ---------------------------------------------------------------- Clash / mihomo (TV, Android, Clash Mi, Clash Verge)
PRIVATE_V4 = ["10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16", "172.16.0.0/12", "192.168.0.0/16"]
PRIVATE_V6 = ["::1/128", "fc00::/7", "fe80::/10"]
MRS_URL = "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/{kind}/cn.mrs"   # upstream; server/sub.py mirrors it
PICK, AUTO_C = "🚀 节点选择", "⚡ 自动"     # the provider is named after site.env BRAND


def clash_nodes(ex):
    """Just the nodes, for the proxy-provider URL."""
    return {"proxies": build_clash(ex)["proxies"]}


def build_clash(ex, provider_url=None):
    """mihomo config for the Clash-family apps (the same policy as build(): HY2 url-test first, ShadowTLS only by hand,
    Claude never direct, CN sites direct). Cert pinned with `fingerprint` (SHA-256 of the whole certificate).
    provider_url: the nodes come from that URL (a proxy-provider refreshed every 6 h) instead of being written in.
    Clash Meta on a TV leaves profile auto-update off by default; with a provider the nodes (certificate, addresses,
    passwords) still follow the server."""
    site = jpx.site()
    sub = site.get("SUB_BASE", "").rstrip("/")
    pre, provider = site["NODE_PREFIX"], site["BRAND"]
    v4 = ex.get("server_v4_host") or ex["server_v4"]

    def hy2(name, server, port):
        return {"name": name, "type": "hysteria2", "server": server, "port": port, "password": ex["hy2_password"],
                "sni": ex["server_domain"], "fingerprint": ex["cert_sha256"], "alpn": ["h3"],
                "down": f"{site['HY2_DOWN_MBPS']} Mbps"}

    def stls(name, server):
        return {"name": name, "type": "ss", "server": server, "port": ex["stls_port"], "cipher": ex["ss_method"],
                "password": ex["ss_password"], "udp-over-tcp": True, "udp-over-tcp-version": 2, "plugin": "shadow-tls",
                "client-fingerprint": "chrome",
                "plugin-opts": {"host": ex["stls_handshake"], "password": ex["stls_password"], "version": 3}}

    hy = [f"{pre}-HY2-v4", f"{pre}-HY2-v6"]
    proxies = [hy2(hy[0], v4, ex["hy2_v4_port"]), hy2(hy[1], ex["server_domain"], ex["hy2_v6_port"]),
               stls(f"{pre}-慢速备用-v4", v4), stls(f"{pre}-慢速备用-v6", ex["server_domain"])]
    rule_src = lambda kind: f"{sub}/rules/{kind}-cn.mrs" if sub else MRS_URL.format(kind=kind)
    rules = [f"DOMAIN-SUFFIX,{d},{PICK}" for d in CLAUDE_DOMAINS + NETFLIX]
    rules += [f"IP-CIDR,{c},DIRECT,no-resolve" for c in PRIVATE_V4] + [f"IP-CIDR6,{c},DIRECT,no-resolve" for c in PRIVATE_V6]
    rules += ["RULE-SET,cn-site,DIRECT", "RULE-SET,cn-ip,DIRECT", f"MATCH,{PICK}"]
    if provider_url:
        groups = [
            {"name": PICK, "type": "select", "proxies": [AUTO_C], "use": [provider]},
            {"name": AUTO_C, "type": "url-test", "use": [provider], "filter": "HY2",
             "url": "https://www.gstatic.com/generate_204", "interval": 300, "tolerance": 100},
        ]
        nodes = {"proxy-providers": {provider: {
            "type": "http", "url": provider_url, "path": f"./proxies/{pre.lower()}.yaml", "interval": 21600, "proxy": "DIRECT",
            "health-check": {"enable": True, "url": "https://www.gstatic.com/generate_204", "interval": 600}}}}
    else:
        groups = [
            {"name": PICK, "type": "select", "proxies": [AUTO_C] + [p["name"] for p in proxies]},
            {"name": AUTO_C, "type": "url-test", "proxies": hy, "url": "https://www.gstatic.com/generate_204",
             "interval": 300, "tolerance": 100},
        ]
        nodes = {"proxies": proxies}
    return {
        "mixed-port": 7890, "allow-lan": False, "mode": "rule", "log-level": "warning", "ipv6": True,
        "unified-delay": True, "tcp-concurrent": True, "profile": {"store-selected": True},
        "dns": {"enable": True, "ipv6": True, "enhanced-mode": "fake-ip", "fake-ip-range": "198.18.0.1/16",
                "fake-ip-filter": ["+.lan", "+.local", "+.msftconnecttest.com", "+.msftncsi.com"],
                "default-nameserver": ["223.5.5.5", "119.29.29.29"],
                "nameserver": ["https://223.5.5.5/dns-query", "https://doh.pub/dns-query"],
                "proxy-server-nameserver": ["https://223.5.5.5/dns-query", "https://doh.pub/dns-query"]},
        **nodes,
        "proxy-groups": groups,
        # fetched DIRECT from the subscription service: must work before any node does
        "rule-providers": {
            "cn-site": {"type": "http", "behavior": "domain", "format": "mrs", "url": rule_src("geosite"),
                        "path": "./rules/geosite-cn.mrs", "interval": 86400, "proxy": "DIRECT"},
            "cn-ip": {"type": "http", "behavior": "ipcidr", "format": "mrs", "url": rule_src("geoip"),
                      "path": "./rules/geoip-cn.mrs", "interval": 86400, "proxy": "DIRECT"},
        },
        "rules": rules,
    }


def to_yaml(o, indent=0):
    """Block YAML for plain dicts / lists / scalars; strings as JSON double-quoted scalars (valid YAML, safe to quote)."""
    pad = "  " * indent
    scalar = lambda v: json.dumps(v, ensure_ascii=False) if isinstance(v, (str, bool)) or v is None else str(v)
    out = []
    if isinstance(o, dict):
        for k, v in o.items():
            key = json.dumps(k, ensure_ascii=False) if not str(k).replace("-", "").isalnum() else k
            if isinstance(v, (dict, list)) and v:
                out.append(f"{pad}{key}:")
                out.append(to_yaml(v, indent + 1))
            else:
                out.append(f"{pad}{key}: {scalar(v) if not isinstance(v, (dict, list)) else ('{}' if isinstance(v, dict) else '[]')}")
    else:
        for v in o:
            if isinstance(v, dict):
                inner = to_yaml(v, indent + 1).split("\n")
                out.append(f"{pad}- {inner[0].lstrip()}")
                out.extend(inner[1:])
            elif isinstance(v, list):
                out.append(f"{pad}- {json.dumps(v, ensure_ascii=False)}")
            else:
                out.append(f"{pad}- {scalar(v)}")
    return "\n".join(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--platform", choices=sorted(PLATFORM), required=True)
    ap.add_argument("--profile")
    ap.add_argument("--data-dir")
    ap.add_argument("--keep-secret-from")
    ap.add_argument("--out")
    ap.add_argument("--remote-rules", action="store_true", help="download the CN rule sets instead of local .srs files")
    ap.add_argument("--cn-export", help="export-client.sh output of the 回国 account (adds the in-China / abroad mode switch)")
    a = ap.parse_args()
    cn_ex = jpx.load_json(a.cn_export) if a.cn_export else None
    ex = json.load(sys.stdin)
    profile = jpx.load_json(a.profile) if a.profile else None
    secret = None
    if a.keep_secret_from and os.path.exists(a.keep_secret_from):
        try:
            secret = jpx.load_json(a.keep_secret_from)["experimental"]["clash_api"]["secret"]
        except (KeyError, ValueError):
            secret = None
    text = json.dumps(build(ex, a.platform, profile, a.data_dir, secret, cn_ex, "remote" if a.remote_rules else "local"), ensure_ascii=False, indent=2) + "\n"
    if a.out:
        jpx.write_private(a.out, text)
    else:
        sys.stdout.write(text)


if __name__ == "__main__":
    main()
