#!/bin/zsh
# 每 15 分钟（开机任务 $LABEL_KEYS）：让 ~/.ssh/authorized_keys 里的一个受管区块等于 github.com/<user>.keys。
# 新电脑 `gh ssh-key add` 之后 15 分钟内就能 ssh 进来（客户端安装脚本靠这个拉配置）；
# GitHub 上删掉的钥匙下一轮也会从这里消失。区块外的行永远不动。
set -u
REPO=${0:A:h:h}; source $REPO/lib/site.sh
U=${GITHUB_KEYS_USER:?}
AK=$HOME/.ssh/authorized_keys
BEGIN="# BEGIN github:$U (managed by github-keys-sync, edits inside are overwritten)"
END="# END github:$U"
LOG() { echo "$(date '+%F %T') $*"; }

keys=$(curl -fsS -m 20 "https://github.com/$U.keys") || { LOG "fetch failed, unchanged"; exit 0; }
keys=$(print -r -- "$keys" | grep -E '^(ssh-(ed25519|rsa)|ecdsa-sha2-nistp[0-9]+|sk-(ssh-ed25519|ecdsa-sha2-nistp256)@openssh\.com) [A-Za-z0-9+/=]+$')
[[ -z "$keys" ]] && { LOG "no valid keys returned, unchanged"; exit 0; }

mkdir -p ~/.ssh; chmod 700 ~/.ssh; touch $AK
[[ -f $AK.bak-before-github-sync ]] || cp $AK $AK.bak-before-github-sync
block=$(print -r -- "$BEGIN"; print -r -- "$keys" | sed "s/\$/ github:$U/"; print -r -- "$END")
outside=$(awk -v b="$BEGIN" -v e="$END" '$0==b{skip=1; next} $0==e{skip=0; next} !skip' $AK)
new=$( { [[ -n "$outside" ]] && print -r -- "$outside"; print -r -- "$block"; } )
if [[ "$new" != "$(cat $AK)" ]]; then
  print -r -- "$new" > $AK.tmp && chmod 600 $AK.tmp && mv $AK.tmp $AK
  LOG "updated: $(print -r -- "$keys" | wc -l | tr -d ' ') GitHub key(s) in managed block"
fi
