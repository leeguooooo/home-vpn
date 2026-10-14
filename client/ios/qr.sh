#!/bin/zsh
# 手机（Shadowrocket，iPhone / iPad）导入节点：在这台 Mac 屏幕上显示二维码，手机扫码。
#
#   client/ios/qr.sh [v4|v6|both] [--user <账号>] [--seconds N]     （默认账号 SHARED_USER）
#
#   v4：Home-HY2-v4（只有 IPv4 的网络靠它）  v6：Home-HY2-v6   both（默认）：两个都显示
#   --user cn：回国节点（回国-HY2-v4 / -v6），在国外时用：流量从国内家里的台式机出去，只走 TCP
#   图片里有节点密码：只在本机打开，按回车（或 --seconds 到时）就删掉。
# 导入后在 Shadowrocket 节点详情里确认：「允许不安全」关，「SHA256 / 证书指纹」= 下面打印的指纹。
# 建议在「代理分组」里建一个 url-test 组，只放这两个 HY2 节点（STLS 别放：延迟最低但几乎不走流量）。
set -euo pipefail
REPO=${0:A:h:h:h}; source $REPO/lib/site.sh
WHICH=both; USER_NAME=$SHARED_USER; SECS=0
while (( $# )); do
  case $1 in
    v4|v6|both) WHICH=$1; shift ;;
    --user) USER_NAME=$2; shift 2 ;;
    --seconds) SECS=$2; shift 2 ;;
    *) sed -n '2,11p' $0; exit 1 ;;
  esac
done
command -v qrencode >/dev/null || brew install -q qrencode
TMPD=$(mktemp -d); chmod 700 $TMPD
cleanup() {
  # Preview opens the images one after another: close a few times so a late window is caught too
  for i in 1 2 3; do osascript -e "tell application \"Preview\" to close (every window whose name contains \"$SLUG-\")" >/dev/null 2>&1 || true; sleep 0.5; done
  rm -P -f $TMPD/*(N); rm -rf $TMPD
}
trap cleanup EXIT INT TERM
ssh -o BatchMode=yes -o ConnectTimeout=15 $SERVER_SSH "$SERVER_REPO/server/export-client.sh $USER_NAME" > $TMPD/export.json
python3 - $TMPD $WHICH "${CN_EXIT_USER:-}" "$SLUG" <<'PY'
import json, subprocess, sys, urllib.parse as u
d, which, cn_user, slug = sys.argv[1:]
ex = json.load(open(f"{d}/export.json"))
nodes = {"v4": (ex.get("server_v4_host") or ex["server_v4"], ex["hy2_v4_port"]), "v6": (ex["server_domain"], ex["hy2_v6_port"])}
for fam in (["v4", "v6"] if which == "both" else [which]):
    host, port = nodes[fam]
    sni = ex["server_domain"]
    q = u.urlencode({"sni": sni, "peer": sni, "insecure": "0", "pinSHA256": ex["cert_sha256"], "alpn": "h3"})
    name = ("回国" if ex["user"] == cn_user else "Home") + f"-HY2-{fam}"   # the 回国 account exits in China
    uri = f"hysteria2://{u.quote(ex['hy2_password'], safe='')}@{host}:{port}/?{q}#{u.quote(name)}"
    subprocess.run(["qrencode", "-s", "10", "-m", "3", "-o", f"{d}/{slug}-{name}.png"], input=uri.encode(), check=True)
    print(f"{name}: {host}:{port}  SNI {sni}")
print("证书指纹（SHA256）:", ex["cert_sha256"])
PY
open -a Preview $TMPD/$SLUG-*.png
if (( SECS > 0 )); then sleep $SECS; else read -r "?扫完按回车（二维码会被删掉）"; fi
