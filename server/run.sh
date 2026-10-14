#!/bin/zsh
# 节点入口（开机任务 $LABEL_NODE）：找稳定 IPv6 → 渲染配置 → exec sing-box。
# 稳定 = 不是 temporary/deprecated：UDP 监听在 :: 上会从临时地址回包，Hysteria2 客户端会丢这些包。
set -euo pipefail
REPO=${0:A:h:h}; source $REPO/lib/site.sh
V6=$(stable_v6)
mkdir -p $STATE/logs
python3 $REPO/server/render.py --v6 "${V6:-::1}" --out $STATE/config.json
exec sing-box run -c $STATE/config.json
