# 读站点参数 + 跨平台小工具。server/ 和 client/ 下的 zsh 脚本第一行就 source 它：
#   REPO=${0:A:h:h}; source $REPO/lib/site.sh
# 顺序：lib/defaults.env → $JPX_SITE/site.env（默认 $REPO/site）。Python 那边是 lib/jpx.py 的 site()，规则一样。
JPX_SITE=${JPX_SITE:-$REPO/site}
[[ -f $JPX_SITE/site.env ]] || { print -u2 "没有 $JPX_SITE/site.env：先 cp -R $REPO/site.example $REPO/site，再改里面的域名和 IP"; exit 1; }
source $REPO/lib/defaults.env
source $JPX_SITE/site.env
: ${SINGBOX_VERSION:=${SINGBOX_WINDOWS_VERSION:-}}        # old name
[[ -n $OWNER_USERS ]] || OWNER_USERS=$SHARED_USER
STATE=${JPX_STATE:-${~STATE_DIR}}; export JPX_STATE=$STATE
OS=$(uname)
export PATH=$STATE/bin:$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH   # plain `ssh host cmd` shells lack Homebrew
[[ $OS == Linux ]] && export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}   # systemctl --user over ssh

# 默认路由所在的网卡（NET_IFACE 没写时）
default_iface() {
  if [[ $OS == Darwin ]]; then route -n get default 2>/dev/null | awk '/interface:/ {print $2; exit}'
  else ip -4 route show default 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "dev") {print $(i + 1); exit}}'; fi
}
[[ -n $NET_IFACE ]] || NET_IFACE=$(default_iface)

# 稳定的公网 IPv6（不是 temporary / deprecated，不是 ULA / link-local）。没有就输出空。
# UDP 监听在 :: 上会从临时地址回包，Hysteria2 客户端会丢这些包，所以 HY2-v6 绑这个具体地址。
stable_v6() {
  if [[ $OS == Darwin ]]; then
    ifconfig $NET_IFACE 2>/dev/null | awk '$1=="inet6" && $2 !~ /^(fe80|fd|fc)/ && $0 !~ /temporary|deprecated/ {print $2; exit}'
  else
    ip -6 -o addr show dev $NET_IFACE scope global -temporary -deprecated 2>/dev/null \
      | awk '{split($4, a, "/"); if (a[1] !~ /^(fd|fc)/) {print a[1]; exit}}'
  fi
}
# 任何公网 IPv6（DDNS 在没有稳定地址时退而求其次）
any_v6() {
  if [[ $OS == Darwin ]]; then ifconfig $NET_IFACE 2>/dev/null | awk '$1=="inet6" && $2 !~ /^(fe80|fd|fc)/ {print $2; exit}'
  else ip -6 -o addr show dev $NET_IFACE scope global 2>/dev/null | awk '{split($4, a, "/"); if (a[1] !~ /^(fd|fc)/) {print a[1]; exit}}'; fi
}
lan_ip() {
  if [[ $OS == Darwin ]]; then ipconfig getifaddr $NET_IFACE
  else ip -4 -o addr show dev $NET_IFACE scope global 2>/dev/null | awk '{split($4, a, "/"); print a[1]; exit}'; fi
}
# 重启 / 查看开机任务（launchd 标签或 systemd --user 单元名）
svc_restart() {
  if [[ $OS == Darwin ]]; then launchctl kickstart -k gui/$(id -u)/$1
  else systemctl --user restart $1.service; fi
}
svc_restart_hint() {
  if [[ $OS == Darwin ]]; then print -r -- "launchctl kickstart -k gui/\$(id -u)/$1"
  else print -r -- "systemctl --user restart $1"; fi
}
# 昨天的日期（strftime 格式）
yesterday() { if [[ $OS == Darwin ]]; then date -v-1d +$1; else date -d yesterday +$1; fi; }
# 今天 + N 天
days_from_now() { if [[ $OS == Darwin ]]; then date -v+$1d +%F; else date -d "+$1 days" +%F; fi; }
# 就地改文件（BSD 和 GNU sed 的 -i 写法不同）
sed_i() { if [[ $OS == Darwin ]]; then sed -i '' "$@"; else sed -i "$@"; fi; }
# 谁在监听某个 TCP 端口（pid）
tcp_listener() {
  if command -v lsof >/dev/null; then lsof -nP -t -iTCP:$1 -sTCP:LISTEN 2>/dev/null | head -1
  else ss -Htlnp "sport = :$1" 2>/dev/null | grep -o 'pid=[0-9]*' | head -1 | cut -d= -f2; fi
}
