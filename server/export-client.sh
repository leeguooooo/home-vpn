#!/bin/zsh
# 输出某个用户的客户端参数（JSON，含密码和证书）。客户端安装脚本通过 ssh 调它，结果不落盘到 git。
#   export-client.sh [name]     默认共用账号（site.env 的 SHARED_USER）
set -euo pipefail
REPO=${0:A:h:h}; source $REPO/lib/site.sh
exec python3 - "${1:-$SHARED_USER}" <<PY
import hashlib, json, os, ssl, sys
sys.path.insert(0, "$REPO/lib")
import jpx
name = sys.argv[1]
st = jpx.state_dir()
secrets = jpx.parse_env(os.path.join(st, "secrets.env"))
people = {n: (h, t) for n, h, t in jpx.users(secrets)}
if name not in people:
    sys.exit("no such user: " + name)
pem = open(os.path.join(st, "certs", "server.crt")).read().strip()
der = ssl.PEM_cert_to_DER_cert(pem)
fp = hashlib.sha256(der).hexdigest().upper()
s = jpx.site()
json.dump({
    "user": name,
    "hy2_password": people[name][0],
    "stls_password": people[name][1],
    "ss_password": secrets["SS_PASSWORD"],
    "cert_pem": pem,
    "cert_sha256": ":".join(fp[i:i + 2] for i in range(0, len(fp), 2)),
    "server_domain": s["SERVER_DOMAIN"],
    "server_v4": s["SERVER_V4"],
    "server_v4_host": s.get("SERVER_V4_HOST") or s["SERVER_V4"],
    "hy2_v4_port": s["HY2_V4_PORT"],
    "hy2_v6_port": s["HY2_V6_PORT"],
    "stls_port": s["STLS_PORT"],
    "stls_handshake": s["STLS_HANDSHAKE"],
    "ss_method": s["SS_METHOD"],
}, sys.stdout, ensure_ascii=False)
PY
