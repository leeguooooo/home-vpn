#!/bin/zsh
# 一键装 / 更新 Mac 客户端。可以重复运行，已经是最新的步骤会跳过。
#
#   client/macos/install.sh [--user <账号>] [--dir ~/<CLIENT_NAME>] [--apply] [--no-menubar]
#   （默认账号 SHARED_USER，默认目录 ~/$CLIENT_NAME，见 lib/defaults.env）
#
#   1. brew 装 sing-box（和 qrencode，给 client/ios/qr.sh 用）
#   2. ssh 到服务器（site.env 的 SERVER_SSH）现取密码和证书——所以这台电脑的公钥要先登记到 GitHub
#      （gh ssh-key add），服务器 15 分钟内同步；仓库和这台电脑上都不存密码的来源
#   3. 规则文件（geosite-cn / geoip-cn）由服务器代下，国内不用连 GitHub
#   4. 生成 $DIR/config.json（client/make-config.py），sing-box check；没变化就不动
#   5. 第一次装时 sudo 一次（root-setup.sh）：系统服务 + 两条免密 launchctl
#   6. 菜单栏图标 ~/Applications/VPN.app + 登录时启动（只启动图标，不连 VPN）
#
# 不会自己重启正在跑的 VPN（断开的那几秒是中国 IP 直连）：新配置下次连接时生效；--apply 立即断开重连。
set -euo pipefail
REPO=${0:A:h:h:h}; source $REPO/lib/site.sh
USER_NAME=$SHARED_USER; DIR=$HOME/$CLIENT_NAME; APPLY=0; MENUBAR=1
while (( $# )); do
  case $1 in
    --user) USER_NAME=$2; shift 2 ;;
    --dir) DIR=${2:A}; shift 2 ;;
    --apply) APPLY=1; shift ;;
    --no-menubar) MENUBAR=0; shift ;;
    *) sed -n '2,18p' $0; exit 1 ;;
  esac
done
LABEL=$CLIENT_LABEL
SB=$(command -v sing-box || echo /opt/homebrew/bin/sing-box)
APP=$HOME/Applications/VPN.app
say() { print -P "%F{cyan}==%f $*"; }
vpn_running() { pgrep -qf "sing-box run -c $DIR/config.json"; }
TMPD=$(mktemp -d); trap 'rm -rf $TMPD' EXIT; chmod 700 $TMPD

# ---------------------------------------------------------------- 1. dependencies
command -v brew >/dev/null || { echo "先装 Homebrew：https://brew.sh"; exit 1; }
for f in sing-box qrencode; do brew list --formula $f >/dev/null 2>&1 || { say "brew install $f"; brew install -q $f; }; done

# ---------------------------------------------------------------- 2. credentials from the server
say "从 $SERVER_SSH 取 $USER_NAME 的节点参数"
ssh -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new $SERVER_SSH \
    "$SERVER_REPO/server/export-client.sh $USER_NAME" > $TMPD/export.json \
  || { echo "❌ ssh $SERVER_SSH 失败：这台电脑的公钥登记到 GitHub 了吗（gh ssh-key add ~/.ssh/id_ed25519.pub）？登记后等 15 分钟。"
       echo "   国内没有 IPv6 的网络连不到 $SERVER_DOMAIN，先用手机热点或别的已通的设备"; exit 1; }

# 回国 account (server-side CN_EXIT_USER): when it exists, the config gets the in-China / abroad mode switch
CN_ARGS=()
if [[ -n ${CN_EXIT_USER:-} ]] && ssh -o BatchMode=yes $SERVER_SSH "$SERVER_REPO/server/export-client.sh $CN_EXIT_USER" > $TMPD/export-cn.json 2>/dev/null; then
  CN_ARGS=(--cn-export $TMPD/export-cn.json); say "有回国账号 $CN_EXIT_USER：配置带「在国内 / 在国外」模式（菜单栏切换）"
fi

# ---------------------------------------------------------------- 3. rule sets (fetched by the server)
mkdir -p $DIR/data; chmod 700 $DIR
for r in sing-geosite/rule-set/geosite-cn sing-geoip/rule-set/geoip-cn; do
  f=$DIR/data/${r:t}.srs
  if [[ ! -s $f || -n $(find $f -mtime +30 2>/dev/null) ]]; then
    say "规则文件 ${r:t}（经服务器下载）"
    if ssh -o BatchMode=yes $SERVER_SSH "curl -fsSL -m 60 https://raw.githubusercontent.com/SagerNet/$r.srs" > $f.tmp && [[ -s $f.tmp ]]; then
      mv -f $f.tmp $f
    else
      rm -f $f.tmp; [[ -s $f ]] || { echo "❌ 下不到 ${r:t}.srs"; exit 1; }
    fi
  fi
done

# ---------------------------------------------------------------- 4. config
python3 $REPO/client/make-config.py --platform macos --data-dir $DIR/data $CN_ARGS \
  --keep-secret-from $DIR/config.json --out $TMPD/config.json < $TMPD/export.json
$SB check -c $TMPD/config.json || { echo "❌ 生成的配置没通过 sing-box check"; exit 1; }
CHANGED=0
mkdir -p $DIR/backups; chmod 700 $DIR/backups
if [[ -f $DIR/config.json ]] && cmp -s $TMPD/config.json $DIR/config.json; then
  say "配置没有变化"
else
  [[ -f $DIR/config.json ]] && cp -p $DIR/config.json $DIR/backups/config-$(date +%Y%m%d-%H%M%S).json
  install -m 600 $TMPD/config.json $DIR/config.json; CHANGED=1
  say "配置已更新：$DIR/config.json（旧的在 backups/）"
fi
# tidy what older setups left behind (kept, not deleted)
legacy=( $DIR/config.json.bak-*(N) $DIR/start.sh(N) $DIR/start.sh.bak-*(N) $DIR/install-service.sh(N) $DIR/menubar(N) $DIR/dashboard-secret.txt(N) )
if (( ${#legacy} )); then
  L=$DIR/backups/legacy-$(date +%Y%m%d); mkdir -p $L; mv $legacy $L/; say "旧文件收进 ${L/#$HOME/~}（${#legacy} 个）"
fi

# ---------------------------------------------------------------- 5. system service + passwordless start/stop (sudo once)
need_root=0
[[ -f /Library/LaunchDaemons/$LABEL.plist && -f /etc/sudoers.d/$CLIENT_NAME ]] || need_root=1
if (( ! need_root )); then
  [[ $(/usr/bin/plutil -extract ProgramArguments.3 raw /Library/LaunchDaemons/$LABEL.plist 2>/dev/null) == $DIR/config.json &&
     $(/usr/bin/plutil -extract RunAtLoad raw /Library/LaunchDaemons/$LABEL.plist 2>/dev/null) == false &&
     $(/usr/bin/plutil -extract KeepAlive raw /Library/LaunchDaemons/$LABEL.plist 2>/dev/null) == false ]] || need_root=1
fi
if (( need_root )); then
  say "第一次装：需要输一次电脑密码（装系统服务和两条免密开关命令）"
  sudo $REPO/client/macos/root-setup.sh --dir $DIR --label $LABEL --name $CLIENT_NAME --sing-box $SB
else
  say "系统服务和免密开关已就绪"
fi

# ---------------------------------------------------------------- 6. menu bar app
if (( MENUBAR )); then
  say "菜单栏图标"
  cat > $TMPD/Site.swift <<EOF
import Foundation
let label = "$LABEL"
let configPath = "$DIR/config.json"
let serverIP = "$SERVER_V4"
let serverSSH = "$SERVER_SSH"
let serverRepo = "$SERVER_REPO"
let userEdition = false
let secretPath = ""
let helpPath = ""
let uninstallPath = ""
let expiredPath = ""
let clashAddr = "127.0.0.1:9090"
let brand = "$BRAND"
let exitName = "$EXIT_NAME"
let errLogPath = "/tmp/$CLIENT_NAME.err"
let menubarLabel = "$MENUBAR_LABEL"
EOF
  mkdir -p $APP/Contents/MacOS
  /usr/bin/python3 - $APP/Contents/Info.plist $MENUBAR_LABEL <<'PY'
import plistlib, sys
plistlib.dump({"CFBundleIdentifier": sys.argv[2], "CFBundleName": "VPN", "CFBundleExecutable": "VPNMenu",
               "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "1.0", "LSUIElement": True,
               "LSMinimumSystemVersion": "13.0"}, open(sys.argv[1], "wb"))
PY
  swiftc -O -o $TMPD/VPNMenu $REPO/client/macos/menubar/*.swift $TMPD/Site.swift -framework AppKit -framework Network -framework SwiftUI
  # sign with the Developer ID from the login keychain (hardened runtime + Apple timestamp), else ad-hoc.
  # Not notarized: the app is built on this Mac and never quarantined, so Gatekeeper does not look at it.
  # Override with JPX_SIGN_IDENTITY="Developer ID Application: …" (or "-" for ad-hoc).
  SIGN_ID=${JPX_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"')}
  if ! cmp -s $TMPD/VPNMenu $APP/Contents/MacOS/VPNMenu || ! codesign --verify --strict $APP >/dev/null 2>&1; then
    install -m 755 $TMPD/VPNMenu $APP/Contents/MacOS/VPNMenu
    if [[ -n $SIGN_ID && $SIGN_ID != - ]] && codesign --force --options runtime --timestamp -s "$SIGN_ID" $APP >/dev/null 2>&1; then
      say "已签名：$SIGN_ID"
    else
      codesign --force -s - $APP >/dev/null 2>&1
      say "临时签名（钥匙串里没有 Developer ID Application 证书，或签名失败）"
    fi
  fi
  AGENT=$HOME/Library/LaunchAgents/$MENUBAR_LABEL.plist
  /usr/bin/python3 - $TMPD/agent.plist "$APP/Contents/MacOS/VPNMenu" $MENUBAR_LABEL <<'PY'
import plistlib, sys
plistlib.dump({"Label": sys.argv[3], "ProgramArguments": [sys.argv[2]], "RunAtLoad": True,
               "LimitLoadToSessionType": "Aqua", "ProcessType": "Interactive"}, open(sys.argv[1], "wb"))
PY
  MB=gui/$(id -u)/$MENUBAR_LABEL
  if ! cmp -s $TMPD/agent.plist $AGENT 2>/dev/null; then
    install -m 644 $TMPD/agent.plist $AGENT
    launchctl bootout $MB 2>/dev/null || true
    # bootout returns before the job is gone; bootstrapping too early fails with "5: Input/output error"
    for i in {1..10}; do launchctl print $MB >/dev/null 2>&1 || break; sleep 0.5; done
    for i in {1..5}; do launchctl bootstrap gui/$(id -u) $AGENT 2>/dev/null && break; sleep 1; done
  else
    launchctl kickstart -k $MB 2>/dev/null || launchctl bootstrap gui/$(id -u) $AGENT
  fi
  sleep 2; pgrep -qf "$APP/Contents/MacOS/VPNMenu" && say "菜单栏图标在运行" || { echo "❌ 菜单栏图标没起来：launchctl print $MB"; exit 1; }
fi

# ---------------------------------------------------------------- 7. apply / status
# the running sing-box read its config at start: anything written after that is still pending
PENDING=0
if vpn_running; then
  pid=$(pgrep -f "sing-box run -c $DIR/config.json" | head -1)
  started=$(date -j -f '%a %b %d %T %Y' "$(ps -o lstart= -p $pid | sed 's/  */ /g; s/^ //; s/ $//')" +%s 2>/dev/null || echo 0)
  (( $(stat -f %m $DIR/config.json) > started )) && PENDING=1
fi
if (( PENDING )); then
  if (( APPLY )); then
    say "--apply：断开再连接（2~3 秒直连）"
    sudo -n /bin/launchctl kill SIGTERM system/$LABEL
    for i in {1..20}; do vpn_running || break; sleep 0.5; done
    sudo -n /bin/launchctl kickstart system/$LABEL
    for i in {1..20}; do vpn_running && break; sleep 0.5; done
    sleep 3; (( MENUBAR )) && $APP/Contents/MacOS/VPNMenu --retest-once || true
  else
    say "VPN 正在用旧配置运行：新配置下次连接时生效（菜单栏「断开」再「连接」，或重跑加 --apply）"
  fi
fi
if vpn_running; then
  say "VPN 已连接，出口：$(curl -s --max-time 8 https://ipinfo.io/ip || echo 查不到)"
else
  say "VPN 未连接：点菜单栏的盾牌图标 →「连接 VPN」"
fi
