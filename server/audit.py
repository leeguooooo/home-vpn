#!/usr/bin/env python3
"""代理审计查询（读 $JPX_STATE/logs 下的 sing-box debug 日志 + 归档）。

  server/audit.py                         今天所有用户概况（连接数、来源 IP、常去域名、被拦截次数）
  server/audit.py <name>                  某人今天的逐条记录
  server/audit.py <name> --days 7         最近 7 天
  server/audit.py <name> --grep openai    只看域名/地址含关键字的
  server/audit.py --blocked [--days 30]   所有被拦截的连接（25 端口 / BT）
  server/audit.py --date 20260919         指定某一天（归档按天存）
  server/audit.py --json [--hours 24]     每个用户的客户端概况（JSON，给 Mac 菜单栏的设置面板用）：
                                          在线来源、各来源 IP 的连接数和最后活动时间、归属地、常去域名
"""
import argparse, collections, datetime, glob, gzip, ipaddress, json, os, re, sys, urllib.request

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib"))
import jpx  # noqa: E402

SHARED = jpx.site()["SHARED_USER"]

BASE = os.path.join(jpx.state_dir(), "logs")
ap = argparse.ArgumentParser(add_help=False)
ap.add_argument("user", nargs="?")
ap.add_argument("--days", type=int, default=1)
ap.add_argument("--date")
ap.add_argument("--grep")
ap.add_argument("--blocked", action="store_true")
ap.add_argument("--json", action="store_true")
ap.add_argument("--hours", type=int)
ap.add_argument("-h", "--help", action="store_true")
a = ap.parse_args()
if a.help: print(__doc__); sys.exit()
if a.hours: a.days = a.hours // 24 + 2   # archives are cut at 04:00, so reach one file further and filter by time

def files():
    today = datetime.date.today()
    if a.date:
        days = [a.date]
    else:
        days = [(today - datetime.timedelta(d)).strftime("%Y%m%d") for d in range(a.days)]
    out = []
    for d in sorted(days):
        out += sorted(glob.glob(f"{BASE}/archive/sing-box-{d}*.log.gz"))
    # 当前文件里是"上次归档之后"的内容，查今天或多天时都要带上
    if not a.date or a.date == today.strftime("%Y%m%d"):
        out.append(f"{BASE}/sing-box.log")
    return out

def lines():
    for f in files():
        op = gzip.open if f.endswith(".gz") else open
        with op(f, "rt", errors="replace") as fh:
            yield from fh

RX = {
    "from": re.compile(r"\[(\d+) [^\]]*\] inbound/(\w+)\[[^:]+: inbound (?:packet )?connection from (\S+)"),
    "user": re.compile(r"^\S+ (\S+ \S+) .*?\[(\d+) [^\]]*\] inbound/[^:]+: \[([^\]]+)\] inbound (?:packet )?connection to (\S+)"),
    "dom":  re.compile(r"\[(\d+) [^\]]*\] router: sniffed protocol: (\w+)(?:, domain: (\S+))?"),
    "rej":  re.compile(r"\[(\d+) [^\]]*\] router: match\[\d+\] (.+?) => reject"),
}
src, conns = {}, {}   # id -> 来源 ; id -> dict
KEEP = ("connection from", "connection to", "sniffed protocol", "=> reject")
for ln in lines():
    if not any(k in ln for k in KEEP): continue
    if (m := RX["from"].search(ln)):
        ip, port = m[3].rsplit(":", 1)
        src[m[1]] = (ip.strip("[]"), port if m[2] == "hysteria2" else "tcp"); continue
    if (m := RX["user"].search(ln)):
        conns[m[2]] = {"t": m[1], "u": m[3], "dst": m[4], "src": src.get(m[2], ("?",))[0], "sess": src.pop(m[2], ("?", "?"))[1], "dom": None, "rej": None}; continue
    if (m := RX["dom"].search(ln)) and m[1] in conns:
        conns[m[1]]["dom"] = m[3] or conns[m[1]]["dom"]; continue
    if (m := RX["rej"].search(ln)) and m[1] in conns:
        conns[m[1]]["rej"] = m[2]

def where(ips):
    """归属地（ip-api.com，查过的缓存在 $JPX_STATE/geo-cache.json；查不到就空着）"""
    path = os.path.join(os.path.dirname(BASE), "geo-cache.json")
    try: cache = json.load(open(path))
    except Exception: cache = {}
    todo = [i for i in ips if i not in cache and ipaddress.ip_address(i).is_global][:100]
    if todo:
        try:
            req = urllib.request.Request("http://ip-api.com/batch?fields=query,status,country,regionName,city,isp&lang=zh-CN",
                                         data=json.dumps(todo).encode(), headers={"Content-Type": "application/json"})
            for r in json.load(urllib.request.urlopen(req, timeout=4)):
                if r.get("status") == "success":
                    cache[r["query"]] = " ".join(x for x in (r["country"], r["regionName"], r["city"], r["isp"]) if x)
            json.dump(cache, open(path, "w"), ensure_ascii=False)
        except Exception:
            pass
    return {i: cache.get(i, "" if ipaddress.ip_address(i).is_global else "局域网") for i in ips}

PROBES = {"www.gstatic.com", "cp.cloudflare.com", "connectivitycheck.gstatic.com"}

def summary(rows):
    """per user: sources (IPv6 grouped by /64, since phones rotate addresses inside it), online = active in the last 10 min"""
    def net(ip):
        try:
            x = ipaddress.ip_address(ip)
        except ValueError:
            return ip
        return str(ipaddress.ip_network(f"{ip}/64", strict=False)) if x.version == 6 else ip
    meta = {}
    try: meta = json.load(open(os.path.join(os.path.dirname(BASE), "users.json")))
    except Exception: pass
    try:   # who has a subscription link (server/sub.py); only the fact, never the token
        subs = {l.split("_SUB_TOKEN=")[0].lower() for l in open(os.path.join(os.path.dirname(BASE), "secrets.env")) if "_SUB_TOKEN=" in l}
    except Exception:
        subs = set()
    by = collections.defaultdict(list)
    for c in rows: by[c["u"]].append(c)
    geo = where(sorted({c["src"] for c in rows if c["src"] != "?"}))
    users = []
    for u in sorted(set(by) | set(meta) | {SHARED}):
        cs = by.get(u, [])
        srcs = collections.defaultdict(list)
        for c in cs: srcs[net(c["src"])].append(c)
        sources = []
        for n, xs in srcs.items():
            last = max(x["t"] for x in xs)
            ips = collections.Counter(x["src"] for x in xs)
            sources.append({"net": n, "ip": ips.most_common(1)[0][0], "where": geo.get(ips.most_common(1)[0][0], ""),
                            # one HY2 client keeps one QUIC connection (one source port); TCP counts as one
                            # latency probes (clients test every node every few minutes) are not use
                            "devices": len({x["sess"] for x in xs if age(x["t"]) <= 600 and host(x) not in PROBES}),
                            "conns": len(xs), "first": min(x["t"] for x in xs), "last": last, "idle": int(age(last))})
        sources.sort(key=lambda s: s["idle"])
        doms = collections.Counter(host(c) for c in cs)
        m = meta.get(u, {})
        users.append({"name": u, "created": m.get("created"), "expires": m.get("expires"), "shared": u == SHARED, "sub": u in subs,
                      "conns": len(cs), "blocked": sum(1 for c in cs if c["rej"]),
                      "online": sum(s["devices"] for s in sources),
                      "last": max((c["t"] for c in cs), default=None),
                      "sources": sources, "top": doms.most_common(8)})
    return {"generated": now.strftime("%Y-%m-%d %H:%M:%S"), "hours": a.hours or a.days * 24, "users": users}

rows = list(conns.values())
now = datetime.datetime.now()   # log times are this Mac's local time
age = lambda t: (now - datetime.datetime.strptime(t, "%Y-%m-%d %H:%M:%S")).total_seconds()
if a.hours: rows = [c for c in rows if age(c["t"]) <= a.hours * 3600]
host = lambda c: c["dom"] or c["dst"].rsplit(":", 1)[0].strip("[]")
if a.grep: rows = [c for c in rows if a.grep.lower() in (host(c) + c["dst"]).lower()]

if a.json:
    print(json.dumps(summary(rows), ensure_ascii=False)); sys.exit()

if a.blocked:
    for c in rows:
        if c["rej"]: print(c["t"], c["u"], c["src"], c["dst"], "拦截:", c["rej"])
    sys.exit()

if a.user:
    rows = [c for c in rows if c["u"] == a.user]
    for c in rows:
        print(c["t"], f'{c["src"]:<16}', host(c), "" if c["dom"] is None else f'({c["dst"]})', "  ⛔ 拦截" if c["rej"] else "")
    print(f"-- {a.user}: {len(rows)} 条")
    sys.exit()

by = collections.defaultdict(list)
for c in rows: by[c["u"]].append(c)
if not by: print("没有记录"); sys.exit()
for u, cs in sorted(by.items()):
    doms = collections.Counter(host(c) for c in cs)
    srcs = collections.Counter(c["src"] for c in cs)
    rej = sum(1 for c in cs if c["rej"])
    print(f"== {u}: {len(cs)} 次连接，拦截 {rej} 次")
    print("   来源 IP：", "，".join(f"{s}×{n}" for s, n in srcs.most_common(5)))
    print("   常去：", "，".join(f"{d}×{n}" for d, n in doms.most_common(15)))
