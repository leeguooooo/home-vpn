#!/bin/bash
# __BRAND__ · Mac 安装（给用户自己装的版本）。订阅页上「复制安装命令」得到的就是：
#   curl -fsSL <订阅链接>/mac | bash
# 订阅服务（sub/worker.js）下发时填好占位符：这个人的订阅链接、sing-box 版本、本目录另两个脚本，
# 以及站点参数 BRAND、APP_ID（及其小写）、EXIT_NAME、EXIT_COUNTRY、SERVER_V4（见 lib/defaults.env）。
# 重复运行 = 修复 / 升级。
#
# 装好之后：
#   /Library/Application Support/__APP_ID__/   sing-box、config.json（有密码：只有 root 可读）、自动更新和卸载脚本
#   系统服务 com.__APP_ID_LC__.vpn               root 跑 sing-box（虚拟网卡）；开机自动连接；异常退出自动拉起，手动断开就保持断开
#   系统服务 com.__APP_ID_LC__.update            每 6 小时和开机时拉订阅，校验通过才替换配置
#   /Applications/__BRAND__.app             菜单栏图标，登录时自动打开；连接 / 断开不要密码（/etc/sudoers.d/__APP_ID_LC__ 只放开这两条）
# 和管理员自己那套（client/macos/install.sh：~/<CLIENT_NAME>、<CLIENT_LABEL>）互不相干。
main() {
set -euo pipefail
SUB='__SUB_URL__'
BASE=$(printf '%s' "$SUB" | sed -E 's#^(https://[^/]+).*#\1#')
VER='__SINGBOX_VERSION__'
D='/Library/Application Support/__APP_ID__'
fail() { printf '\n  \033[31m安装没有完成：%s\033[0m\n  把这个窗口截图发给给你链接的人。\n\n' "$1"; exit 1; }
step() { printf '  · %s\n' "$1"; }

printf '\n  \033[36m正在安装「__BRAND__」，大约需要一分钟……\033[0m\n\n'
case $(uname -m) in arm64) A=arm64 ;; x86_64) A=amd64 ;; *) fail "不认识这台 Mac 的处理器（$(uname -m)）" ;; esac
[ "$(sw_vers -productVersion | cut -d. -f1)" -ge 13 ] || fail "需要 macOS 13 或更新的系统"

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
step '下载程序（约 40 MB）'
curl -fsSL --retry 2 -o "$T/sb.tar.gz" "$BASE/dl/sing-box-darwin-$A.tar.gz" || fail '下载失败，检查一下网络再运行一次'
curl -fsSL --retry 2 -o "$T/app.zip" "$BASE/dl/__APP_ID_LC__-mac.zip" || fail '下载失败，检查一下网络再运行一次'
tar -xzf "$T/sb.tar.gz" -C "$T"
SBBIN=$(find "$T" -name sing-box -type f -perm -u+x | head -1)
[ -n "$SBBIN" ] || fail '下载的文件不完整，再运行一次'
/usr/bin/ditto -x -k "$T/app.zip" "$T/app"
[ -d "$T/app/__BRAND__.app" ] || fail '下载的文件不完整，再运行一次'
cat > "$T/update.sh" <<'HOMEVPN_END_OF_UPDATE_SH'
__UPDATE_SH__
HOMEVPN_END_OF_UPDATE_SH
cat > "$T/uninstall.sh" <<'HOMEVPN_END_OF_UNINSTALL_SH'
__UNINSTALL_SH__
HOMEVPN_END_OF_UNINSTALL_SH

printf '\n  接下来要输入这台 Mac 的\033[1m开机密码\033[0m（输入时屏幕上不显示，是正常的），输完按回车。\n'
printf '  （要是弹出指纹框，按一下指纹也行。）\n\n'
# authenticate on its own first: a cancelled Touch ID prompt or a typo gets another try instead of ending the install
ok=0
for try in 1 2 3; do
  if sudo -v -p '  密码：' < /dev/tty; then ok=1; break; fi
  [ $try -lt 3 ] && printf '\n  \033[33m没通过，再输一次开机密码。\033[0m\n\n'
done
[ $ok = 1 ] || fail '开机密码没通过（输了 3 次）。确认一下密码，再运行一次安装命令'
sudo /bin/bash -s -- "$SUB" "$T" "$SBBIN" "$(id -un)" "$(id -u)" <<'ROOT' || fail '系统设置那一步没成功'
set -euo pipefail
SUB=$1; T=$2; SBBIN=$3; U=$4; UID_=$5
D='/Library/Application Support/__APP_ID__'
step() { printf '  · %s\n' "$1"; }
step '安装系统组件'
mkdir -p "$D"; chown root:wheel "$D"; chmod 755 "$D"
install -m 755 -o root -g wheel "$SBBIN" "$D/sing-box"
install -m 755 -o root -g wheel "$T/update.sh" "$D/update.sh"
install -m 755 -o root -g wheel "$T/uninstall.sh" "$D/uninstall.sh"
( umask 077; printf '%s' "$SUB" > "$D/sub.txt" ); chown root:wheel "$D/sub.txt"
printf '%s' "$SUB" > "$D/help.txt"; chmod 644 "$D/help.txt"      # the menu's「使用说明」opens it
step '获取你的配置'
"$D/update.sh" --install || exit 1

step '设置开机自动连接'
# plists written as XML directly: a fresh Mac has no python3 (the stub pops up a "install developer tools" dialog)
x() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g'; }
args() { for a in "$@"; do printf '<string>%s</string>' "$(x "$a")"; done; }
plist() {   # plist <file> <label> <inner xml>
  printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict><key>Label</key><string>%s</string>%s</dict></plist>\n' "$2" "$3" > "$1"
  chown root:wheel "$1"; chmod 644 "$1"; plutil -lint "$1" >/dev/null
}
plist /Library/LaunchDaemons/com.__APP_ID_LC__.vpn.plist com.__APP_ID_LC__.vpn \
  "<key>ProgramArguments</key><array>$(args "$D/sing-box" run -c "$D/config.json" -D "$D")</array><key>RunAtLoad</key><true/><key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict><key>ThrottleInterval</key><integer>10</integer><key>StandardErrorPath</key><string>$(x "$D/sing-box.log")</string>"
plist /Library/LaunchDaemons/com.__APP_ID_LC__.update.plist com.__APP_ID_LC__.update \
  "<key>ProgramArguments</key><array>$(args "$D/update.sh")</array><key>RunAtLoad</key><true/><key>StartInterval</key><integer>21600</integer><key>StandardErrorPath</key><string>$(x "$D/update.err")</string>"
plist /Library/LaunchAgents/com.__APP_ID_LC__.menubar.plist com.__APP_ID_LC__.menubar \
  "<key>ProgramArguments</key><array>$(args "/Applications/__BRAND__.app/Contents/MacOS/__APP_ID__")</array><key>RunAtLoad</key><true/><key>LimitLoadToSessionType</key><string>Aqua</string><key>ProcessType</key><string>Interactive</string>"
# every user on this Mac may connect / disconnect / update without a password; nothing else
tmp=$(mktemp)
cat > "$tmp" <<EOF
# __BRAND__：菜单栏图标只能启动 / 停止这个 VPN 服务、触发一次配置更新。别的一概不放开。
ALL ALL=(root) NOPASSWD: /bin/launchctl kickstart system/com.__APP_ID_LC__.vpn, /bin/launchctl kill SIGTERM system/com.__APP_ID_LC__.vpn, /bin/launchctl kickstart system/com.__APP_ID_LC__.update
EOF
visudo -cf "$tmp" >/dev/null && install -m 0440 -o root -g wheel "$tmp" /etc/sudoers.d/__APP_ID_LC__
rm -f "$tmp"

step '安装菜单栏图标'
launchctl bootout "gui/$UID_/com.__APP_ID_LC__.menubar" 2>/dev/null || true
rm -rf "/Applications/__BRAND__.app"
/usr/bin/ditto "$T/app/__BRAND__.app" "/Applications/__BRAND__.app"
chown -R root:wheel "/Applications/__BRAND__.app"

step '连接'
for l in com.__APP_ID_LC__.vpn com.__APP_ID_LC__.update; do
  launchctl bootout "system/$l" 2>/dev/null || true
  for i in 1 2 3 4 5 6 7 8 9 10; do launchctl print "system/$l" >/dev/null 2>&1 || break; sleep 0.5; done
  launchctl bootstrap system "/Library/LaunchDaemons/$l.plist"
done
for i in 1 2 3 4 5; do launchctl bootstrap "gui/$UID_" /Library/LaunchAgents/com.__APP_ID_LC__.menubar.plist 2>/dev/null && break; sleep 1; done
ROOT

ok=0
for i in $(seq 1 30); do
  sleep 2
  # exit country when the site set one (a home IPv4 can change under DDNS), else the server's IPv4
  if [ -n '__EXIT_COUNTRY__' ]; then got=$(curl -s -m 5 https://ipinfo.io/country 2>/dev/null); want='__EXIT_COUNTRY__'
  else got=$(curl -s -m 5 https://ipinfo.io/ip 2>/dev/null); want='__SERVER_V4__'; fi
  if [ "$got" = "$want" ]; then ok=1; break; fi
done
echo
if [ $ok = 1 ]; then
  printf '  \033[32m装好了，已经连上（__EXIT_NAME__）。\033[0m\n'
else
  printf '  \033[33m装好了，但还没确认连上。稍等半分钟，看屏幕右上角的盾牌图标。\033[0m\n'
fi
printf '  以后点屏幕右上角的盾牌图标：带勾 = 已连接，带斜杠 = 未连接；点它就能连接 / 断开。开机会自动连上。\n'
printf '  这个终端窗口可以关掉了。\n\n'
}
main "$@"
