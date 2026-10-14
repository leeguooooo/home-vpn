#!/bin/zsh
# 每天 04:00（开机任务 $LABEL_MAINT）：
#   1) 出前一天审计报告 → logs/reports/<日期>.txt（留 90 天）
#   2) 日志归档：sing-box.log → logs/archive/sing-box-<昨天>.log.gz，原文件清空（sing-box 追加写，不用重启）
#   3) 删 30 天前的归档；可用空间 < 5GB 时从最老的删
#   4) 订阅服务上的国内分流规则和 App 安装包更新一次（server/sub.py rules / apps）
#   5) 撤销 users.json 里到期的用户，然后重启节点（04:00 断 10~20 秒）
# 手动：maint.sh      只看会撤销谁：maint.sh --dry-run
set -euo pipefail
REPO=${0:A:h:h}; source $REPO/lib/site.sh
LOG=$STATE/logs/sing-box.log; ARC=$STATE/logs/archive; mkdir -p $ARC $STATE/logs/reports
DRY=${1:-}
if [[ -z $DRY && -s $LOG ]]; then
  { echo "# $(yesterday %F) 审计报告"; python3 $REPO/server/audit.py; echo; echo "## 被拦截"; python3 $REPO/server/audit.py --blocked; } > $STATE/logs/reports/$(yesterday %Y%m%d).txt 2>&1 || true
  D=$(yesterday %Y%m%d); F=$ARC/sing-box-$D.log
  [[ -e $F.gz ]] && F=$ARC/sing-box-$D-$(date +%H%M%S).log
  cp $LOG $F && : > $LOG && gzip -f $F
fi
if [[ -z $DRY ]]; then
  find $ARC -name 'sing-box-*.log.gz' -mtime +30 -delete
  for f in $(ls -1tr $ARC/sing-box-*.log.gz 2>/dev/null); do
    (( $(df -k $HOME | awk 'NR==2{print $4}') > 5*1024*1024 )) && break
    echo "磁盘不足，删 $f"; rm -f $f
  done
  find $STATE/logs/reports -name '*.txt' -mtime +90 -delete 2>/dev/null || true
  [[ -f $STATE/sub.env ]] && { python3 $REPO/server/sub.py rules >/dev/null || echo "$(date '+%F %T') ⚠️ 订阅规则没推上去"; }
  [[ -f $STATE/sub.env ]] && { python3 $REPO/server/sub.py apps | grep -v "已是" || true; }
fi
EXPIRED=$(python3 - "$STATE/users.json" <<'PY'
import datetime, json, os, sys
p = sys.argv[1]
if os.path.exists(p):
    t = datetime.date.today().isoformat()
    print(" ".join(n for n, v in json.load(open(p)).items() if v.get("expires") and v["expires"] < t))
PY
)
[[ -z $EXPIRED ]] && { echo "$(date '+%F %T') 无到期用户"; exit 0; }
echo "$(date '+%F %T') 到期：$EXPIRED"; [[ -n $DRY ]] && exit 0
for n in ${=EXPIRED}; do $REPO/server/users.sh del $n --no-restart; done
svc_restart $LABEL_NODE
