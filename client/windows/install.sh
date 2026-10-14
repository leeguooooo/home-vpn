#!/bin/zsh
# 在 Mac 上跑：通过 ssh 给一台 Windows 电脑装 / 更新 VPN（那台要开 OpenSSH 服务器，ssh 账号是管理员）。
#
#   client/windows/install.sh <ssh 主机> [--profile <名字>] [--user <账号>] [--desktop-user <账号>] [--apply]
#
#   --profile       site/clients/<名字>.json：这台电脑的额外规则、MTU、日常账号；默认用和 ssh 主机同名的文件
#   --desktop-user  平时坐在电脑前的账号（桌面图标、开机托盘装给他）；默认取 profile 的 desktop_user
#   --apply         配置有变化时立即重启 VPN（带 5 分钟自动回滚）；不加则下次开机或点「VPN 开关」时生效
#
# 装的东西：C:\ProgramData\sing-box（sing-box.exe、config.json、规则文件，只有管理员可读）、开机计划任务 sing-box、
# 桌面「VPN 开关」「VPN 状态」、右下角托盘图标。密码来自服务器，只在传输时的临时目录里出现，装完就删。
#   --user          用哪个账号的密码（默认共用账号 SHARED_USER）
set -euo pipefail
REPO=${0:A:h:h:h}; source $REPO/lib/site.sh
HOST=${1:-}; [[ -n $HOST && $HOST != -* ]] || { sed -n '2,13p' $0; exit 1; }; shift
PROFILE=""; USER_NAME=$SHARED_USER; DESK=""; APPLY=()
while (( $# )); do
  case $1 in
    --profile) PROFILE=$2; shift 2 ;;
    --user) USER_NAME=$2; shift 2 ;;
    --desktop-user) DESK=$2; shift 2 ;;
    --apply) APPLY=(-Apply); shift ;;
    *) sed -n '2,13p' $0; exit 1 ;;
  esac
done
[[ -z $PROFILE && -f $JPX_SITE/clients/$HOST.json ]] && PROFILE=$HOST
PROFILE_FILE=${PROFILE:+$JPX_SITE/clients/$PROFILE.json}
[[ -z $DESK && -n $PROFILE_FILE ]] && DESK=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("desktop_user",""))' $PROFILE_FILE)
say() { print -P "%F{cyan}==%f $*"; }
W=(ssh -o BatchMode=yes -o ConnectTimeout=15 $HOST)
TMPD=$(mktemp -d); chmod 700 $TMPD; trap 'rm -rf $TMPD' EXIT
STAGE=$TMPD/stage; mkdir -p $STAGE
CACHE=$HOME/.cache/$SLUG; mkdir -p $CACHE

say "检查 $HOST"
REMOTE_HOME=$($W 'Write-Output $env:USERPROFILE' 2>/dev/null | tr -d '\r' | tail -1)
[[ $REMOTE_HOME == [A-Z]:\\* ]] || { echo "❌ ssh $HOST 不通，或默认 shell 不是 PowerShell"; exit 1; }

say "从 $SERVER_SSH 取 $USER_NAME 的节点参数"
ssh -o BatchMode=yes -o ConnectTimeout=15 $SERVER_SSH "$SERVER_REPO/server/export-client.sh $USER_NAME" > $TMPD/export.json

# keep the dashboard secret the machine already has
scp -q "$HOST:C:/ProgramData/sing-box/config.json" $TMPD/old.json 2>/dev/null || true
PROF_ARGS=(); [[ -n $PROFILE_FILE ]] && PROF_ARGS=(--profile $PROFILE_FILE)   # zsh does not word-split ${x:+a b}
python3 $REPO/client/make-config.py --platform windows $PROF_ARGS \
  --keep-secret-from $TMPD/old.json --out $STAGE/config.json < $TMPD/export.json
say "配置已生成（profile：${PROFILE:-无}）"

# rule sets: reuse this Mac's copy when fresh, else have the server fetch them
for t in geosite-cn geoip-cn; do
  src=$HOME/$CLIENT_NAME/data/$t.srs
  if [[ -s $src && -z $(find $src -mtime +30 2>/dev/null) ]]; then cp $src $STAGE/
  else
    repo=${t/geosite-cn/sing-geosite}; repo=${repo/geoip-cn/sing-geoip}
    ssh -o BatchMode=yes $SERVER_SSH "curl -fsSL -m 60 https://raw.githubusercontent.com/SagerNet/$repo/rule-set/$t.srs" > $STAGE/$t.srs
  fi
done

# scripts: fill in the server IP and names; .ps1 keep their UTF-8 BOM (PowerShell 5.1 reads BOM-less files as GBK)
for f in vpn-toggle.ps1 vpn-status.ps1 vpn-tray.ps1 vpn-tray.vbs install.ps1 cn-exit-tunnel.ps1; do
  sed -e "s/__SERVER_V4__/$SERVER_V4/g" -e "s/__SLUG__/$SLUG/g" -e "s/__EXIT_NAME__/$EXIT_NAME/g" $REPO/client/windows/$f > $STAGE/$f
done

# sing-box.exe only when the machine has a different version
V=$SINGBOX_VERSION
have=$($W "& 'C:\\ProgramData\\sing-box\\sing-box.exe' version" 2>/dev/null | tr -d '\r' | head -1 || true)
if [[ $have != *" $V"* ]]; then
  zip=$CACHE/sing-box-$V-windows-amd64.zip
  [[ -s $zip ]] || { say "下载 sing-box $V（Windows）"; curl -fsSL -o $zip.tmp "https://github.com/SagerNet/sing-box/releases/download/v$V/sing-box-$V-windows-amd64.zip" && mv $zip.tmp $zip; }
  unzip -o -q -j $zip '*/sing-box.exe' -d $STAGE
  say "sing-box.exe 会更新：${have:-未安装} → $V"
fi

say "上传到 $HOST 并安装"
STG=$SLUG-stage
$W "Remove-Item -Recurse -Force $STG -ErrorAction SilentlyContinue; New-Item -ItemType Directory $STG | Out-Null" >/dev/null
scp -q $STAGE/* "$HOST:$STG/"
# 回国 exit: the profile says this machine exposes a loopback SOCKS entry for the server
CN_PORT=""; [[ -n $PROFILE_FILE ]] && CN_PORT=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("cn_exit_listen_port",""))' $PROFILE_FILE)
CN_ARGS=""; [[ -n $CN_PORT && -n ${CN_EXIT_USER:-} ]] && CN_ARGS="-CnExit -CnServer $SERVER_DOMAIN -CnUser $SERVER_SSH_USER -CnPort $CN_PORT"
set +e
$W "powershell -NoProfile -ExecutionPolicy Bypass -File \"$REMOTE_HOME\\$STG\\install.ps1\" -Stage \"$REMOTE_HOME\\$STG\" -ServerV4 $SERVER_V4 ${DESK:+-DesktopUser $DESK} ${APPLY[@]} $CN_ARGS" 2>&1 \
  | grep -v -iE 'post-quantum|store now|openssh.com/pq' | tee $TMPD/install.out | grep -v '^CN_EXIT_PUBKEY:'
rc=${pipestatus[1]}
set -e
$W "Remove-Item -Recurse -Force $STG" >/dev/null 2>&1 || true      # the staged config holds passwords
(( rc == 0 )) || { echo "❌ 安装脚本返回 $rc"; exit $rc; }
pub=$(grep '^CN_EXIT_PUBKEY: ' $TMPD/install.out | head -1 | sed 's/^CN_EXIT_PUBKEY: //' | tr -d '\r')
if [[ -n $pub ]]; then
  # listening on the server? lsof on macOS, ss on Linux
  tunnel_up() { ssh -o BatchMode=yes $SERVER_SSH "lsof -nP -iTCP:$CN_EXIT_PORT -sTCP:LISTEN 2>/dev/null || ss -Htln 'sport = :$CN_EXIT_PORT' 2>/dev/null | grep -q ." >/dev/null 2>&1; }
  say "在 $SERVER_SSH 上授权回国通道钥匙"
  ssh -o BatchMode=yes $SERVER_SSH "$SERVER_REPO/server/cn-exit-authorize.sh '$pub'"
  say "等回国通道连上服务器的 127.0.0.1:$CN_EXIT_PORT（最多 90 秒）"
  for i in {1..18}; do
    tunnel_up && { say "回国通道已连上 ✓"; break; }
    sleep 5
  done
  tunnel_up || print -r -- "⚠️ 回国通道 90 秒内没连上：看台式机 C:\\ProgramData\\$SLUG-cn\\tunnel.log 和服务器 $STATE_DIR/logs/cn-exit.log"
fi
