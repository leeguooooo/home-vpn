#!/bin/bash
# __BRAND__ · 自动更新配置（系统服务 com.__APP_ID_LC__.update：开机和每 6 小时，root 运行；菜单栏也能触发）。
# 从订阅拉 macOS 版 sing-box 配置 → sing-box check 通过 → 和现在的不同才替换 → 正在连接就重启一下。
# 拉不到、校验不过：什么都不动，旧配置照用。账号到期（410）：写 expired，菜单栏会提示。
# --install：安装时调用，失败时打印给人看的原因，退出码非 0。
set -u
D='/Library/Application Support/__APP_ID__'
INSTALL=0; [ "${1:-}" = --install ] && INSTALL=1
log() { echo "$(date '+%F %T') $*" >> "$D/update.log"; }
quit() { log "$2"; [ $INSTALL = 1 ] && [ "$1" != 0 ] && printf '  %s\n' "$2"; exit "$1"; }

SUB=$(cat "$D/sub.txt")
NEW="$D/config.new.json"
code=$(curl -sS -m 60 --retry 2 -A 'home-vpn-mac/1' -o "$NEW" -w '%{http_code}' "$SUB/singbox-macos" 2>/dev/null)
case $code in
  410) date '+%F %T' > "$D/expired"; chmod 644 "$D/expired"; quit 3 '账号已到期：找给你链接的人续期。' ;;
  404) quit 4 '订阅链接已失效（可能换了新链接）：找给你链接的人要新的，用新链接重新安装。' ;;
  200) ;;
  *) quit 2 "连不上订阅服务（$code）。检查一下网络再试。" ;;
esac
rm -f "$D/expired"
chmod 600 "$NEW"
if ! out=$("$D/sing-box" check -c "$NEW" -D "$D" 2>&1); then rm -f "$NEW"; quit 5 "新配置没通过检查，保留旧配置：$out"; fi
# the menu bar app (not root) needs the local control secret; the config itself stays root-only
secret=$(plutil -extract experimental.clash_api.secret raw -o - "$NEW" 2>/dev/null || true)
( umask 022; printf '%s' "$secret" > "$D/clash.secret.tmp" ) && mv -f "$D/clash.secret.tmp" "$D/clash.secret"
date '+%F %T' > "$D/updated"; chmod 644 "$D/updated"
if [ -f "$D/config.json" ] && cmp -s "$NEW" "$D/config.json"; then rm -f "$NEW"; quit 0 '配置没变化'; fi
mv -f "$NEW" "$D/config.json"
if [ $INSTALL = 0 ] && launchctl print system/com.__APP_ID_LC__.vpn 2>/dev/null | grep -q 'state = running'; then
  launchctl kickstart -k system/com.__APP_ID_LC__.vpn
  quit 0 '配置已更新，已重连'
fi
quit 0 '配置已更新'
