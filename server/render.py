#!/usr/bin/env python3
"""Render the server sing-box config: server/config.tmpl.json + site/ + $JPX_STATE/secrets.env.

  render.py --v6 <stable-ipv6> [--out FILE]                write the config (mode 600)
  render.py --v6 ... --compare OLD.json --old-base DIR     exit 1 if it differs from OLD.json once DIR
                                                           is rewritten to the state dir (migration guard)
"""
import argparse
import difflib
import json
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib"))
import jpx  # noqa: E402


def render(v6, state=None):
    state = state or jpx.state_dir()
    s = jpx.site()
    secrets = jpx.parse_env(os.path.join(state, "secrets.env"))
    people = jpx.users(secrets)
    values = {
        "STATE": state,
        "V6": v6,
        "HY2_USERS": [{"name": n, "password": h} for n, h, _ in people],
        "STLS_USERS": [{"name": n, "password": t} for n, _, t in people],
        "SS_PASSWORD": secrets["SS_PASSWORD"],
        "SITE_RULES": jpx.strip_comments(jpx.load_json(os.path.join(jpx.site_dir(), "server-rules.json"))),
    }
    for k in ("HY2_V4_PORT", "HY2_V6_PORT", "STLS_PORT", "STLS_HANDSHAKE", "SS_METHOD"):
        values[k] = s[k]

    def fill(o):
        if isinstance(o, dict):
            return {k: fill(v) for k, v in o.items()}
        if isinstance(o, list):
            out = []
            for x in o:
                if x == "@SITE_RULES@":
                    out.extend(values["SITE_RULES"])      # spliced in place
                else:
                    out.append(fill(x))
            return out
        if isinstance(o, str) and "@" in o:
            if o.startswith("@") and o.endswith("@") and o.count("@") == 2:
                return values[o[1:-1]]
            for k, v in values.items():
                if isinstance(v, str):
                    o = o.replace("@" + k + "@", v)
            if "@" in o and not o.startswith("mailto"):
                raise SystemExit("unfilled placeholder in template: " + o)
        return o

    cfg = fill(jpx.load_json(os.path.join(jpx.REPO, "server", "config.tmpl.json")))
    extra = []   # after the template's rules: port 25 / BitTorrent stay refused for everyone
    cn = s.get("CN_EXIT_USER", "")
    if cn and cn in [n for n, _, _ in people]:
        # 回国: this account's traffic leaves through the China desktop's reverse ssh tunnel (TCP only)
        cfg["outbounds"].append({"type": "socks", "tag": "cn-exit", "server": "127.0.0.1",
                                 "server_port": s["CN_EXIT_PORT"], "version": "5"})
        extra += [
            {"auth_user": [cn], "network": ["udp"], "action": "reject"},
            {"auth_user": [cn], "outbound": "cn-exit"},
        ]
    # Everyone else stays out of the home network and this server itself: no LAN, no loopback, not the home's own public
    # addresses (they lead back to this server and the router). Written as "the owner's accounts pass, the rest is
    # checked" so connections whose user is unknown (ShadowTLS -> ss-in carries no user) are checked too.
    # Names are resolved first, so "localhost" or a DNS name pointing at 192.168.x.x does not slip through.
    owners = [n for n in s["OWNER_USERS"].split() if n in [p[0] for p in people]]
    extra += [
        {"auth_user": owners, "outbound": "direct"},
        {"action": "resolve"},
        {"ip_is_private": True, "action": "reject"},
        {"ip_cidr": ["0.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16", "::1/128", "fc00::/7", "fe80::/10",
                     s["SERVER_V4"] + "/32", v6 + "/128"], "action": "reject"},
        {"domain_suffix": ["localhost", "local", "lan", "home.arpa"], "action": "reject"},
    ]
    cfg["route"]["rules"] += extra
    return cfg


def canonical(o):
    return json.dumps(o, sort_keys=True, indent=1, ensure_ascii=False).splitlines()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--v6", required=True)
    ap.add_argument("--out")
    ap.add_argument("--compare")
    ap.add_argument("--old-base")
    a = ap.parse_args()
    cfg = render(a.v6)
    if a.compare:
        old = open(a.compare).read()
        if a.old_base:
            old = old.replace(a.old_base.rstrip("/"), jpx.state_dir())
        # the old layout kept logs and certs under the old base; after the rewrite both point into state
        diff = list(difflib.unified_diff(canonical(json.loads(old)), canonical(cfg), "running", "rendered", lineterm=""))
        if diff:
            red = [l if "password" not in l else l.split(":")[0] + ": <redacted>" for l in diff]
            print("\n".join(red))
            sys.exit(1)
        print("rendered config is identical to the running one")
        return
    text = json.dumps(cfg, ensure_ascii=False, indent=2) + "\n"
    if a.out:
        jpx.write_private(a.out, text)
    else:
        sys.stdout.write(text)


if __name__ == "__main__":
    main()
