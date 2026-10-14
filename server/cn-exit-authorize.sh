#!/bin/zsh
# 给国内台式机的回国反向通道授权（client/windows/install.sh 会自动调它）：
#   cn-exit-authorize.sh "ssh-ed25519 AAAA…"
# 在 ~/.ssh/authorized_keys 里写一条受限钥匙（GitHub 同步区块之外，同步不会动它）：
#   只能在本机 127.0.0.1:$CN_EXIT_PORT 开反向转发；正向转发只准连 127.0.0.1:9（没人监听，等于禁止）；没有终端；
#   注意 authorized_keys 里不能写 permitopen="none"（那是 sshd_config 的写法），sshd 会判整行无效、直接拒绝这把钥匙。
#   登录后只能跑 server/cn-exit-session.sh（清掉占着端口的旧通道，然后保持会话）。
# 重复运行会替换旧的那条（按行尾标记 $SLUG-cn-tunnel）。
set -euo pipefail
REPO=${0:A:h:h}; source $REPO/lib/site.sh
key=${1:?用法: cn-exit-authorize.sh "ssh-ed25519 AAAA…"}
read -r kt kb _rest <<< "$key"
[[ $kt == ssh-ed25519 && $kb =~ '^[A-Za-z0-9+/]+=*$' ]] || { echo "不是 ed25519 公钥"; exit 1; }
AK=$HOME/.ssh/authorized_keys; TAG=$SLUG-cn-tunnel
line="restrict,port-forwarding,permitlisten=\"127.0.0.1:$CN_EXIT_PORT\",permitopen=\"127.0.0.1:9\",command=\"$REPO/server/cn-exit-session.sh\" $kt $kb $TAG"
touch $AK; chmod 600 $AK
[[ -f $AK.bak-before-cn-exit ]] || cp -p $AK $AK.bak-before-cn-exit
python3 - "$AK" "$TAG" "$line" <<'PY'
import sys
path, tag, line = sys.argv[1:]
lines = [l for l in open(path).read().splitlines() if not l.endswith(" " + tag)]
# keep it outside (before) the GitHub-managed block
i = next((n for n, l in enumerate(lines) if l.startswith("# BEGIN github:")), len(lines))
lines.insert(i, line)
open(path + ".tmp", "w").write("\n".join(lines) + "\n")
PY
chmod 600 $AK.tmp && mv $AK.tmp $AK
echo "✅ 已授权（127.0.0.1:$CN_EXIT_PORT 反向转发，标记 $TAG）"
