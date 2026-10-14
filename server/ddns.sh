#!/bin/zsh
# 每 10 分钟（开机任务 $LABEL_DDNS）：把 $SERVER_DOMAIN 的 AAAA 记录更新成本机稳定 IPv6（Cloudflare API）。
# 令牌在 $DDNS_ENV（不在仓库）：CF_API_TOKEN CF_ZONE_ID CF_RECORD_ID CF_RECORD_NAME CF_INTERFACE
# 可选：CF_RECORD_ID4 CF_RECORD_NAME4 —— 同时维护一条 A 记录（公网 IPv4 取路由器 UPnP 报的外网地址）
set -euo pipefail
REPO=${0:A:h:h}; source $REPO/lib/site.sh
ENV_FILE=${~DDNS_ENV}
[[ -f "$ENV_FILE" ]] || { echo "missing $ENV_FILE"; exit 1; }
source "$ENV_FILE"
: "${CF_API_TOKEN:?}" "${CF_ZONE_ID:?}" "${CF_RECORD_ID:?}" "${CF_RECORD_NAME:?}" "${CF_INTERFACE:=$NET_IFACE}"

NET_IFACE=$CF_INTERFACE
ip6=$(stable_v6); [[ -n "$ip6" ]] || ip6=$(any_v6)
[[ -n "$ip6" ]] || { echo "no global IPv6 on $CF_INTERFACE"; exit 1; }

payload=$(printf '{"type":"AAAA","name":"%s","content":"%s","ttl":1,"proxied":false}' "$CF_RECORD_NAME" "$ip6")
resp=$(curl -fsS -X PUT -H "Authorization: Bearer $CF_API_TOKEN" -H 'Content-Type: application/json' \
  "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records/$CF_RECORD_ID" --data "$payload")
echo "$resp" | grep -q '"success":true' || { echo "$resp"; exit 1; }
echo "$(date '+%F %T') $CF_RECORD_NAME -> $ip6"

# optional IPv4 A record (CF_RECORD_ID4 / CF_RECORD_NAME4): the router's external address, read over UPnP
if [[ -n ${CF_RECORD_ID4:-} && -n ${CF_RECORD_NAME4:-} ]]; then
  ip4=$(upnpc -s 2>/dev/null | awk -F' = ' '/ExternalIPAddress/ {print $2; exit}')
  [[ $ip4 =~ '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' ]] || ip4=$(curl -4 -fsS -m 10 https://api.ipify.org || true)
  if [[ -n $ip4 ]]; then
    payload4=$(printf '{"type":"A","name":"%s","content":"%s","ttl":60,"proxied":false}' "$CF_RECORD_NAME4" "$ip4")
    resp4=$(curl -fsS -X PUT -H "Authorization: Bearer $CF_API_TOKEN" -H 'Content-Type: application/json' \
      "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records/$CF_RECORD_ID4" --data "$payload4")
    echo "$resp4" | grep -q '"success":true' && echo "$(date '+%F %T') $CF_RECORD_NAME4 -> $ip4" || { echo "$resp4"; exit 1; }
  else
    echo "$(date '+%F %T') no external IPv4 (UPnP and api.ipify.org both failed), A record unchanged"
  fi
fi
