#!/bin/zsh
# 每 10 分钟（开机任务 $LABEL_UPNP）：
#   1) UPNP 不是 off 时：重新声明路由器上的 IPv4 端口映射（路由器重启或服务器局域网 IP 变了会丢）
#   2) 稳定 IPv6 变了就重启节点（HY2-v6 绑的是具体地址）
REPO=${0:A:h:h}; source $REPO/lib/site.sh
if [[ $UPNP != off ]] && command -v upnpc >/dev/null; then
  LAN_IP=$(lan_ip)
  # the description stays the same across runs, so the router updates its mappings instead of adding more
  upnpc -e $UPNP_DESC -a "$LAN_IP" $STLS_PORT $STLS_PORT TCP 0 >/dev/null 2>&1
  upnpc -e $UPNP_DESC -a "$LAN_IP" $HY2_V4_PORT $HY2_V4_PORT UDP 0 >/dev/null 2>&1
  echo "$(date '+%F %T') $LAN_IP"
fi

CUR=$(stable_v6)
if [[ -n "$CUR" && -f $STATE/config.json ]] && ! grep -q "\"$CUR\"" $STATE/config.json; then
  echo "$(date '+%F %T') IPv6 changed -> $CUR, restarting node"
  svc_restart $LABEL_NODE
fi
