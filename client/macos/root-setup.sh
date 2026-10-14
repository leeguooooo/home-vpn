#!/bin/bash
# client/macos/install.sh 需要 root 的那一次性部分（它会用 sudo 调这个脚本，你只输一次密码）：
#   1. 系统服务 LaunchDaemon：root 跑 sing-box（TUN 需要 root）。开机加载但不运行（RunAtLoad false），
#      停了也不自动拉起（KeepAlive false）——开机默认不连，由菜单栏图标开关。
#   2. sudoers：安装它的那个用户只能免密执行两条命令——启动和停止这个服务。别的一概不放开。
# 可重复运行；已经是目标状态就什么都不改。
#   sudo client/macos/root-setup.sh --dir /Users/<you>/<CLIENT_NAME> --label <CLIENT_LABEL> --name <CLIENT_NAME> [--sing-box <路径>]
# （install.sh 会把站点参数里的 CLIENT_LABEL / CLIENT_NAME 传进来；这个脚本自己不读站点参数）
set -euo pipefail
LABEL=""; NAME=""; DIR=""; SB=/opt/homebrew/bin/sing-box
while (( $# )); do
  case $1 in
    --dir) DIR=$2; shift 2 ;;
    --label) LABEL=$2; shift 2 ;;
    --name) NAME=$2; shift 2 ;;
    --sing-box) SB=$2; shift 2 ;;
    *) echo "unknown $1"; exit 1 ;;
  esac
done
[[ $LABEL =~ ^[A-Za-z0-9.-]+$ && $NAME =~ ^[A-Za-z0-9_-]+$ ]] || { echo "要 --label 和 --name（字母数字）"; exit 1; }
PLIST=/Library/LaunchDaemons/$LABEL.plist
SUDOERS=/etc/sudoers.d/$NAME
[ "$(id -u)" = 0 ] || { echo "要用 sudo 运行"; exit 1; }
U=${SUDO_USER:?run via sudo from your own account}
[ -n "$DIR" ] || DIR=$(eval echo "~$U")/$NAME
[ -x $SB ] || { echo "没有 $SB（先 brew install sing-box）"; exit 1; }

# 1. LaunchDaemon
want=$(mktemp)
/usr/bin/python3 - "$want" "$LABEL" "$SB" "$DIR" "$NAME" <<'PY'
import plistlib, sys
out, label, sb, d, name = sys.argv[1:]
plistlib.dump({"Label": label, "ProgramArguments": [sb, "run", "-c", f"{d}/config.json", "-D", f"{d}/data"],
               "RunAtLoad": False, "KeepAlive": False, "ProcessType": "Background",
               "StandardOutPath": f"/tmp/{name}.log", "StandardErrorPath": f"/tmp/{name}.err"},
              open(out, "wb"))
PY
if [ -f $PLIST ] && [ "$(plutil -convert json -o - $PLIST | python3 -c 'import json,sys;print(sorted(json.load(sys.stdin).items()))')" = "$(plutil -convert json -o - $want | python3 -c 'import json,sys;print(sorted(json.load(sys.stdin).items()))')" ]; then
  echo "LaunchDaemon 已是目标状态"
else
  [ -f $PLIST ] && cp -p $PLIST $PLIST.bak-$(date +%Y%m%d-%H%M%S)
  running=0; pgrep -qf "sing-box run -c $DIR/config.json" && running=1
  install -m 644 -o root -g wheel $want $PLIST
  launchctl bootout system/$LABEL 2>/dev/null || true
  launchctl bootstrap system $PLIST
  [ $running = 1 ] && launchctl kickstart system/$LABEL   # it was connected: keep it connected
  echo "LaunchDaemon 已安装：$PLIST（开机不自动连）"
fi
rm -f $want

# 2. sudoers — exactly two commands, validated before it is kept
tmp=$(mktemp)
cat > $tmp <<EOF
# 菜单栏图标（~/Applications/VPN.app）：只允许启动 / 停止这个 VPN 服务。
$U ALL=(root) NOPASSWD: /bin/launchctl kickstart system/$LABEL, /bin/launchctl kill SIGTERM system/$LABEL
EOF
if [ -f $SUDOERS ] && cmp -s $tmp $SUDOERS; then
  echo "sudoers 规则已是目标状态"
elif visudo -cf $tmp >/dev/null; then
  install -m 0440 -o root -g wheel $tmp $SUDOERS; echo "sudoers 规则已安装：$SUDOERS"
else
  echo "❌ sudoers 规则没通过 visudo 校验，没改"; rm -f $tmp; exit 1
fi
rm -f $tmp
