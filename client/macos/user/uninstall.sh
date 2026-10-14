#!/bin/bash
# __BRAND__ · 卸载（菜单栏「卸载__BRAND__…」用管理员密码运行；也可以 sudo 跑这个文件）。
# 停掉并删除系统服务、菜单栏图标、免密规则和 /Library/Application Support/__APP_ID__。
[ "$(id -u)" = 0 ] || { echo "要用管理员权限运行：sudo bash '$0'"; exit 1; }
for l in com.__APP_ID_LC__.vpn com.__APP_ID_LC__.update; do launchctl bootout "system/$l" 2>/dev/null || true; done
for u in $(ps -axo uid= -o comm= | awk '/__APP_ID__$/ {print $1}' | sort -u); do launchctl bootout "gui/$u/com.__APP_ID_LC__.menubar" 2>/dev/null || true; done
pkill -f '/Applications/__BRAND__.app/Contents/MacOS/__APP_ID__' 2>/dev/null || true
rm -f /Library/LaunchDaemons/com.__APP_ID_LC__.vpn.plist /Library/LaunchDaemons/com.__APP_ID_LC__.update.plist \
      /Library/LaunchAgents/com.__APP_ID_LC__.menubar.plist /etc/sudoers.d/__APP_ID_LC__
rm -rf "/Applications/__BRAND__.app" "/Library/Application Support/__APP_ID__"
echo "已卸载"
