#!/bin/zsh
# 台式机回国通道那把受限钥匙的强制命令（由 cn-exit-authorize.sh 写进 authorized_keys）。
# 台式机的 ssh 先申请 -R 127.0.0.1:$CN_EXIT_PORT，再开会话跑这个脚本：
#   - 端口由本次连接的 sshd（本脚本的父进程）占着 → 一直挂着，保持通道
#   - 被别的进程占着（上次掉线没清掉的旧通道；sshd 默认不检测对端掉线）→ 杀掉它，退出，台式机 10 秒后重连
#   - 没人占 → 本次转发没绑上，退出重来
REPO=${0:A:h:h}; source $REPO/lib/site.sh
LOG=$STATE/logs/cn-exit.log
log() { echo "$(date '+%F %T') $*" >> $LOG; }
sleep 2
holder=$(tcp_listener $CN_EXIT_PORT)
# our own connection's sshd may be the parent or sit one or two levels up (a shell can be in between)
mine=(); p=$$
for i in 1 2 3; do p=$(ps -o ppid= -p $p 2>/dev/null | tr -d ' '); [[ -n $p && $p != 1 ]] && mine+=($p); done
if [[ -n $holder && ${mine[(Ie)$holder]} -gt 0 ]]; then
  log "tunnel up (sshd $holder, from ${SSH_CLIENT%% *})"
  exec sleep 2147483647
elif [[ -n $holder ]]; then
  log "stale tunnel held by $holder, killing; client will reconnect"
  kill $holder 2>/dev/null
  exit 1
else
  log "forward not bound in this session, client will reconnect"
  exit 1
fi
