#!/bin/zsh
# 用户管理。共用账号（site.env 的 SHARED_USER）不能增删；其他人各有独立的 HY2 / ShadowTLS 密码，可单独撤销。
#
#   users.sh list                       列出用户和到期日
#   users.sh add <name> [天数]           新增（默认 30 天，0 = 永不到期）；不重启，攒几个再重启
#   users.sh del <name> [--no-restart]  撤销（默认重启节点，所有人断 10~20 秒）
#   users.sh expire <name> <天数|YYYY-MM-DD|never>
#                                       改到期日（天数从今天算；到期日当天还能用，第二天 04:00 撤销）；不用重启
#   users.sh bundle <name> [macos|windows]
#                                       给没有 ssh 权限的人打包客户端配置到 $JPX_STATE/users/<name>/
#
# 密码在 $JPX_STATE/secrets.env（<NAME>_HY2_PASSWORD / <NAME>_STLS_PASSWORD），到期日在 users.json。
# 每天 04:00 的 maint.sh 会撤销到期用户。
set -euo pipefail
REPO=${0:A:h:h}; source $REPO/lib/site.sh
SECRETS=$STATE/secrets.env; USERS=$STATE/users.json

check_config() {   # render with a dummy v6 and let sing-box validate it
  local t; t=$(mktemp); python3 $REPO/server/render.py --v6 ::1 --out $t && sing-box check -c $t; local rc=$?; rm -f $t; return $rc
}
restart_node() { svc_restart $LABEL_NODE; }
# subscription (server/sub.py): best effort, the account change itself already happened
sub() { [[ -f $STATE/sub.env ]] || return 0; python3 $REPO/server/sub.py "$@" || echo "⚠️ 订阅没同步上（server/sub.py $*），稍后手动重跑"; }

cmd=${1:-list}; name=${2:-}
case $cmd in
  list)
    python3 - "$SECRETS" "$USERS" "$REPO/lib" "$SHARED_USER" <<'PY'
import json, os, sys
sys.path.insert(0, sys.argv[3])
import jpx
s = jpx.parse_env(sys.argv[1]); u = json.load(open(sys.argv[2])) if os.path.exists(sys.argv[2]) else {}
for n, _, _ in jpx.users(s):
    meta = u.get(n, {})
    print(f"{n:<16} 创建 {meta.get('created', '-'):<10}  到期 {meta.get('expires') or ('共用账号' if n == sys.argv[4] else '永不')}")
PY
    ;;
  add)
    [[ $name =~ ^[a-z][a-z0-9]{1,15}$ ]] || { echo "名字只能是小写字母开头的字母数字（2-16 位）"; exit 1; }
    [[ $name != $SHARED_USER ]] || { echo "$SHARED_USER 是共用账号"; exit 1; }
    days=${3:-30}; [[ $days =~ ^[0-9]+$ ]] || { echo "天数要是数字"; exit 1; }
    UP=${(U)name}
    grep -q "^${UP}_HY2_PASSWORD=" $SECRETS && { echo "$name 已存在"; exit 1; }
    cp -p $SECRETS $SECRETS.bak-add-$name
    [[ -z $(tail -c1 $SECRETS) ]] || echo >> $SECRETS          # end on a newline, so del restores the file exactly
    printf '# %s（%s 加）\n%s_HY2_PASSWORD=%s\n%s_STLS_PASSWORD=%s\n' "$name" "$(date +%F)" "$UP" "$(openssl rand -hex 16)" "$UP" "$(openssl rand -hex 16)" >> $SECRETS
    if ! check_config; then mv -f $SECRETS.bak-add-$name $SECRETS; echo "❌ 配置校验失败，已回滚"; exit 1; fi
    rm -f $SECRETS.bak-add-$name
    python3 - "$USERS" "$name" "$days" <<'PY'
import datetime, json, os, sys
p, n, d = sys.argv[1], sys.argv[2], int(sys.argv[3])
u = json.load(open(p)) if os.path.exists(p) else {}
t = datetime.date.today()
u[n] = {"created": t.isoformat(), "expires": (t + datetime.timedelta(days=d)).isoformat() if d else None}
json.dump(u, open(p, "w"), ensure_ascii=False, indent=2)
PY
    echo "✅ $name 已加入（还没生效），到期：$([[ $days == 0 ]] && echo 永不 || days_from_now $days)"
    echo "   生效要重启节点（所有人断 10~20 秒）：$(svc_restart_hint $LABEL_NODE)"
    echo "   给他的客户端配置：$0 bundle $name [macos|windows]"
    ;;
  del)
    [[ -n $name && $name != $SHARED_USER ]] || { echo "用法：users.sh del <name>（不能删共用账号 $SHARED_USER）"; exit 1; }
    UP=${(U)name}
    grep -q "^${UP}_HY2_PASSWORD=" $SECRETS || { echo "没有 $name"; exit 1; }
    sub drop $name
    cp -p $SECRETS $SECRETS.bak-del-$name
    sed_i "/^${UP}_[A-Z0-9]*_PASSWORD=/d; /^${UP}_SUB_TOKEN=/d; /^${UP}_TV_CODE=/d; /^# ${name}（/d" $SECRETS
    if ! check_config; then mv -f $SECRETS.bak-del-$name $SECRETS; echo "❌ 配置校验失败，已回滚"; exit 1; fi
    rm -f $SECRETS.bak-del-$name
    python3 -c 'import json,os,sys; p,n=sys.argv[1:]; u=json.load(open(p)) if os.path.exists(p) else {}; u.pop(n,None); json.dump(u,open(p,"w"),ensure_ascii=False,indent=2)' $USERS $name
    [[ -d $STATE/users/$name ]] && { mkdir -p $STATE/users/.revoked; mv $STATE/users/$name $STATE/users/.revoked/$name-$(date +%Y%m%d-%H%M%S); }
    echo "✅ 已撤销 $name"
    [[ ${3:-} == --no-restart ]] || restart_node
    ;;
  expire)
    [[ -n $name && $name != $SHARED_USER ]] || { echo "用法：users.sh expire <name> <天数|YYYY-MM-DD|never>（$SHARED_USER 是共用账号，不会到期）"; exit 1; }
    grep -q "^${(U)name}_HY2_PASSWORD=" $SECRETS || { echo "没有 $name"; exit 1; }
    python3 - "$USERS" "$name" "${3:-}" <<'PY'
import datetime, json, os, sys
p, n, v = sys.argv[1:]
t = datetime.date.today()
if v in ("never", "0"):
    e = None
elif v.isdigit():
    e = (t + datetime.timedelta(days=int(v))).isoformat()
else:
    try:
        d = datetime.date.fromisoformat(v)
    except ValueError:
        sys.exit("到期要写天数、YYYY-MM-DD 或 never")
    if d < t: sys.exit("到期日不能早于今天（要马上停用就用 del）")
    e = d.isoformat()
u = json.load(open(p)) if os.path.exists(p) else {}
u.setdefault(n, {"created": None})["expires"] = e
tmp = p + ".tmp"
json.dump(u, open(tmp, "w"), ensure_ascii=False, indent=2)
os.replace(tmp, p)
print(f"✅ {n} 到期：{e or '永不'}" + (f"（{e} 当天还能用，第二天 04:00 撤销）" if e else ""))
PY
    [[ -n $(python3 $REPO/server/sub.py list | awk -v n=$name '$1==n && $2=="有订阅"') ]] && sub publish $name >/dev/null
    ;;
  bundle)
    [[ -n $name ]] || { echo "用法：users.sh bundle <name> [macos|windows]"; exit 1; }
    plat=${3:-macos}; out=$STATE/users/$name; mkdir -p $out; chmod 700 $STATE/users $out
    # rule sets travel with the bundle; the config points at them relative to sing-box's -D directory
    for r in sing-geosite/rule-set/geosite-cn sing-geoip/rule-set/geoip-cn; do
      curl -fsSL -m 60 -o $out/${r:t}.srs https://raw.githubusercontent.com/SagerNet/$r.srs
    done
    dd=.; [[ $plat == windows ]] && dd=C:/ProgramData/sing-box
    $REPO/server/export-client.sh $name | python3 $REPO/client/make-config.py --platform $plat --data-dir $dd --out $out/config-$plat.json
    sing-box check -c $out/config-$plat.json -D $out >/dev/null 2>&1 || [[ $plat == windows ]] || { echo "❌ 打包的配置没通过 sing-box check"; exit 1; }
    echo "✅ $out/（config-$plat.json + 两个规则文件；含密码，只发给本人）"
    echo "   macOS：brew install sing-box；把整个文件夹拷过去，在里面 sudo sing-box run -c config-macos.json -D ."
    echo "   Windows：文件放进 C:\\ProgramData\\sing-box\\，管理员 PowerShell 里 sing-box.exe run -c config.json -D C:\\ProgramData\\sing-box"
    ;;
  *) sed -n '2,14p' $0; exit 1 ;;
esac
