"""Shared helpers for server/ and client/ scripts. Stdlib only, Python 3.9+ (macOS's /usr/bin/python3)."""
import json
import os
import re

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def parse_env(path):
    """KEY=VALUE lines; '#' comments; optional surrounding quotes. Values may contain '=' (base64)."""
    out = {}
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            v = v.split(" #", 1)[0].strip()
            if len(v) >= 2 and v[0] == v[-1] and v[0] in "'\"":
                v = v[1:-1]
            out[k.strip()] = v
    return out


def site_dir():
    """$JPX_SITE, else <repo>/site (gitignored: the deployment's own parameters; template in site.example/)."""
    return os.environ.get("JPX_SITE") or os.path.join(REPO, "site")


def site():
    """lib/defaults.env overlaid with site/site.env -- the same order lib/site.sh sources them in."""
    path = os.path.join(site_dir(), "site.env")
    if not os.path.exists(path):
        raise SystemExit(f"没有 {path}：先 cp -R site.example site，再改里面的域名和 IP")
    s = parse_env(os.path.join(REPO, "lib", "defaults.env"))
    s.update(parse_env(path))
    if "SINGBOX_WINDOWS_VERSION" in s and "SINGBOX_VERSION" not in parse_env(path):
        s["SINGBOX_VERSION"] = s["SINGBOX_WINDOWS_VERSION"]          # old name
    s["OWNER_USERS"] = s.get("OWNER_USERS") or s["SHARED_USER"]
    for k in list(s):
        if (k.endswith("_PORT") or k.endswith("_MBPS")) and s[k]:
            s[k] = int(s[k])
    return s


def state_dir():
    return os.path.expanduser(os.environ.get("JPX_STATE") or site()["STATE_DIR"])


def users(secrets):
    """[(name, hy2_password, stls_password)] -- the shared account (SHARED_USER) first, then per-user
    credentials made by users.sh (<NAME>_HY2_PASSWORD / <NAME>_STLS_PASSWORD), in file order."""
    out = [(site()["SHARED_USER"], secrets["HY2_PASSWORD"], secrets["STLS_PASSWORD"])]
    for k in secrets:
        m = re.fullmatch(r"([A-Z][A-Z0-9]{1,15})_HY2_PASSWORD", k)
        if m and m.group(1) != "HY2":
            up = m.group(1)
            if up + "_STLS_PASSWORD" in secrets:
                out.append((up.lower(), secrets[k], secrets[up + "_STLS_PASSWORD"]))
    return out


def strip_comments(o):
    """Drop keys starting with '_' (documentation inside JSON); sing-box rejects unknown fields."""
    if isinstance(o, dict):
        return {k: strip_comments(v) for k, v in o.items() if not k.startswith("_")}
    if isinstance(o, list):
        return [strip_comments(x) for x in o]
    return o


def load_json(path):
    with open(path, encoding="utf-8-sig") as fh:
        return json.load(fh)


def write_private(path, text):
    """Write a file only its owner can read (configs carry passwords)."""
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    tmp = path + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write(text)
    os.replace(tmp, path)
