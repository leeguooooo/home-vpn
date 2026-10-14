#!/bin/zsh
# 一键部署服务端。可以重复运行，已经是最新的步骤会跳过。
#   macOS：Homebrew 装依赖，开机任务是用户级 LaunchAgent，不需要 sudo
#   Linux（Debian / Ubuntu）：apt 装依赖、sing-box 下到 $STATE/bin，开机任务是 systemd --user 单元；
#                             第一次要 sudo 几次（装包、允许普通用户监听 443、开机不登录也运行）
#
#   server/install.sh                           新机器：装依赖 → 生成密码和证书 → 渲染配置 → 装开机任务 → 启动
#   server/install.sh --migrate-from <旧目录>    从旧的服务端目录迁过来：沿用密码、证书、用户和日志；
#                                               先证明新渲染的配置和正在跑的一模一样才切换，旧东西归档
#   server/install.sh --check                   只渲染 + sing-box check，不动开机任务
#
# 数据（密码、证书、用户、日志、渲染后的配置）在 STATE_DIR（默认 ~/.home-vpn），不在仓库。
# 回退（macOS）：launchd 旧定义备份在 $STATE/launchd-backup/<时间>/，拷回 ~/Library/LaunchAgents 后 bootout + bootstrap。
set -euo pipefail
REPO=${0:A:h:h}; source $REPO/lib/site.sh
MIGRATE=""; CHECK=0
while (( $# )); do
  case $1 in
    --migrate-from) MIGRATE=${2:A}; shift 2 ;;
    --check) CHECK=1; shift ;;
    *) sed -n '2,13p' $0; exit 1 ;;
  esac
done
say() { print -P "%F{cyan}==%f $*"; }

# ---------------------------------------------------------------- 0. dependencies
if [[ $OS == Darwin ]]; then
  command -v brew >/dev/null || { echo "先装 Homebrew：https://brew.sh"; exit 1; }
  pkgs=(sing-box); [[ $UPNP != off ]] && pkgs+=(miniupnpc)
  for f in $pkgs; do
    brew list --formula $f >/dev/null 2>&1 || { say "brew install $f"; brew install -q $f; }
  done
elif [[ $OS == Linux ]]; then
  command -v systemctl >/dev/null || { echo "只支持用 systemd 的 Linux（Debian / Ubuntu 等）"; exit 1; }
  pkgs=(openssl curl python3 iproute2 ca-certificates); [[ $UPNP != off ]] && pkgs+=(miniupnpc)
  missing=(); for p in $pkgs; do dpkg -s $p >/dev/null 2>&1 || missing+=($p); done
  if (( ${#missing} )); then
    command -v apt-get >/dev/null || { echo "缺这些软件，请自己装上：$missing"; exit 1; }
    say "sudo apt-get install $missing"
    sudo apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $missing >/dev/null
  fi
  # sing-box: the pinned release (distribution packages lag behind and differ in config format)
  if [[ $(sing-box version 2>/dev/null | awk 'NR==1 {print $3}') != $SINGBOX_VERSION ]]; then
    case $(uname -m) in x86_64|amd64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;; *) echo "不支持的 CPU：$(uname -m)"; exit 1 ;; esac
    say "下载 sing-box $SINGBOX_VERSION（linux-$arch）→ $STATE/bin"
    mkdir -p $STATE/bin; t=$(mktemp -d)
    curl -fsSL -m 120 https://github.com/SagerNet/sing-box/releases/download/v$SINGBOX_VERSION/sing-box-$SINGBOX_VERSION-linux-$arch.tar.gz \
      | tar -xz -C $t
    install -m 755 $t/sing-box-$SINGBOX_VERSION-linux-$arch/sing-box $STATE/bin/sing-box; rm -rf $t
  fi
else
  echo "server/install.sh 只支持 macOS 和 Linux"; exit 1
fi

# ---------------------------------------------------------------- 1. state (secrets, certificate, users, logs)
mkdir -p $STATE/certs $STATE/logs $STATE/users; chmod 700 $STATE $STATE/users
if [[ -n $MIGRATE && ! -f $STATE/secrets.env ]]; then
  [[ -f $MIGRATE/secrets.env && -f $MIGRATE/certs/server.key ]] || { echo "$MIGRATE 不像旧的服务端目录"; exit 1; }
  say "迁移状态 $MIGRATE → $STATE（沿用密码和证书，现有客户端不用重配）"
  cp -p $MIGRATE/secrets.env $STATE/
  cp -p $MIGRATE/certs/server.crt $MIGRATE/certs/server.key $STATE/certs/
  [[ -f $MIGRATE/users.json ]] && cp -p $MIGRATE/users.json $STATE/
  [[ -d $MIGRATE/users ]] && cp -Rp $MIGRATE/users/. $STATE/users/
  [[ -d $MIGRATE/logs ]] && cp -Rp $MIGRATE/logs/. $STATE/logs/
fi
if [[ ! -f $STATE/secrets.env ]]; then
  say "生成密码（共用账号 $SHARED_USER）"
  ( umask 077
    { echo "# 共用账号 $SHARED_USER（$(date +%F) 生成）"
      echo "HY2_PASSWORD=$(openssl rand -hex 16)"
      echo "STLS_PASSWORD=$(openssl rand -hex 16)"
      echo "SS_PASSWORD=$(openssl rand -base64 16)"; } > $STATE/secrets.env )
fi
if [[ ! -f $STATE/certs/server.key ]]; then
  say "生成自签证书 CN=$SERVER_DOMAIN（客户端锁定指纹，不需要 CA）"
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650 \
    -keyout $STATE/certs/server.key -out $STATE/certs/server.crt \
    -subj "/CN=$SERVER_DOMAIN" -addext "subjectAltName=DNS:$SERVER_DOMAIN" 2>/dev/null
fi
chmod 600 $STATE/secrets.env $STATE/certs/server.key

# ---------------------------------------------------------------- 2. render and validate
V6=$(stable_v6)
[[ -n $V6 ]] || say "⚠️  ${NET_IFACE:-网卡} 上没有稳定的公网 IPv6，HY2-v6 入口先绑 ::1（只有 IPv4 可用）"
tmp=$(mktemp); trap 'rm -f $tmp' EXIT
python3 $REPO/server/render.py --v6 "${V6:-::1}" --out $tmp
sing-box check -c $tmp || { echo "❌ sing-box check 失败"; exit 1; }
if [[ -n $MIGRATE && -f $MIGRATE/config/config.json ]]; then
  say "对比正在运行的配置"
  python3 $REPO/server/render.py --v6 "${V6:-::1}" --compare $MIGRATE/config/config.json --old-base $MIGRATE \
    || { echo "❌ 新渲染的配置和正在运行的不一致（diff 见上），没有切换"; exit 1; }
fi
(( CHECK )) && { say "检查通过（--check：没动开机任务）"; exit 0; }

# ---------------------------------------------------------------- 3. Linux: one-time system settings (sudo)
if [[ $OS == Linux ]]; then
  # Linux only lets root listen below port 1024. Rather than run the node as root, let ordinary users bind from 443 up
  # (macOS allows that by default for wildcard addresses). Ports below 443 (ssh 22, http 80 ...) stay root-only.
  low=$(sysctl -n net.ipv4.ip_unprivileged_port_start 2>/dev/null || echo 1024)
  need=$(( HY2_V4_PORT < STLS_PORT ? HY2_V4_PORT : STLS_PORT ))
  if (( need < low )); then
    say "sudo：允许普通用户监听 $need 以上的端口（net.ipv4.ip_unprivileged_port_start=$need）"
    echo "net.ipv4.ip_unprivileged_port_start=$need" | sudo tee /etc/sysctl.d/60-$SLUG.conf >/dev/null
    sudo sysctl -q -p /etc/sysctl.d/60-$SLUG.conf
  fi
  # user services normally stop at logout and start at login; linger runs them from boot
  if [[ $(loginctl show-user $USER -p Linger --value 2>/dev/null) != yes ]]; then
    say "sudo：开机不用登录也运行（loginctl enable-linger $USER）"
    sudo loginctl enable-linger $USER
    for i in {1..20}; do [[ -S $XDG_RUNTIME_DIR/bus ]] && break; sleep 0.5; done
  fi
fi

# ---------------------------------------------------------------- 4. boot jobs
BK=$STATE/launchd-backup/$(date +%Y%m%d-%H%M%S)
typeset -a OLD_BIN   # ~/bin scripts the old jobs used; archived after a migration
UNITS=$HOME/.config/systemd/user
LA=$HOME/Library/LaunchAgents
JOB_PATH=$STATE/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin

# job <label> <log> <schedule: keepalive | interval:N | daily:HH:MM> <program> [args...]
job_launchd() {
  local label=$1 log=$2 sched=$3; shift 3
  local want=$(mktemp)
  python3 - "$want" "$label" "$log" "$sched" "$STATE" "$@" <<'PY'
import plistlib, sys
out, label, log, sched, state, *prog = sys.argv[1:]
p = {"Label": label, "ProgramArguments": prog, "StandardOutPath": log, "StandardErrorPath": log,
     "EnvironmentVariables": {"JPX_STATE": state, "PATH": "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"}}
if sched == "keepalive":
    p.update(RunAtLoad=True, KeepAlive=True, ThrottleInterval=10)
elif sched.startswith("interval:"):
    p.update(RunAtLoad=True, StartInterval=int(sched.split(":")[1]))
elif sched.startswith("daily:"):
    h, m = sched.split(":")[1:]
    p["StartCalendarInterval"] = {"Hour": int(h), "Minute": int(m)}
plistlib.dump(p, open(out, "wb"))
PY
  local dst=$LA/$label.plist
  if [[ -f $dst ]] && cmp -s $want $dst; then rm -f $want; echo "   $label 已是最新"; return; fi
  if [[ -f $dst ]]; then
    mkdir -p $BK; cp -p $dst $BK/
    local old=$(/usr/bin/plutil -extract ProgramArguments.0 raw $dst 2>/dev/null || true)
    [[ $old == $HOME/bin/* ]] && OLD_BIN+=($old)
    launchctl bootout gui/$(id -u)/$label 2>/dev/null || true
    # bootout returns before the job is gone; bootstrapping too early fails with "5: Input/output error"
    local i; for i in {1..20}; do launchctl print gui/$(id -u)/$label >/dev/null 2>&1 || break; sleep 0.5; done
  fi
  mv -f $want $dst; chmod 644 $dst
  local ok=0; for i in {1..5}; do launchctl bootstrap gui/$(id -u) $dst 2>/dev/null && { ok=1; break; }; sleep 1; done
  (( ok )) || { echo "❌ $label 没装上：launchctl bootstrap gui/$(id -u) $dst"; exit 1; }
  echo "   $label 已安装"
}

# systemd: <label>.service (+ <label>.timer for the scheduled ones); output appended to the log like launchd does
job_systemd() {
  local label=$1 log=$2 sched=$3; shift 3
  local svc=$(mktemp) tmr="" changed=0 q
  q=${(j: :)${(qq)@}}
  {
    print -r -- "[Unit]"
    print -r -- "Description=$label"
    [[ $sched == keepalive ]] && { print -r -- "After=network-online.target"; print -r -- "Wants=network-online.target"; }
    print -r -- ""
    print -r -- "[Service]"
    if [[ $sched == keepalive ]]; then
      print -r -- "Type=simple"; print -r -- "Restart=always"; print -r -- "RestartSec=10"
    else
      print -r -- "Type=oneshot"
    fi
    print -r -- "Environment=JPX_STATE=$STATE"
    print -r -- "Environment=PATH=$JOB_PATH"
    print -r -- "ExecStart=$q"
    print -r -- "StandardOutput=append:$log"
    print -r -- "StandardError=append:$log"
    if [[ $sched == keepalive ]]; then print -r -- ""; print -r -- "[Install]"; print -r -- "WantedBy=default.target"; fi
  } > $svc
  if [[ $sched != keepalive ]]; then
    tmr=$(mktemp)
    {
      print -r -- "[Unit]"; print -r -- "Description=$label (schedule)"; print -r -- ""; print -r -- "[Timer]"
      if [[ $sched == interval:* ]]; then
        print -r -- "OnBootSec=60"; print -r -- "OnUnitActiveSec=${sched#interval:}"
      else
        local hm=${sched#daily:}; print -r -- "OnCalendar=*-*-* ${(l:2::0:)${hm%%:*}}:${(l:2::0:)${hm#*:}}:00"; print -r -- "Persistent=true"
      fi
      print -r -- ""; print -r -- "[Install]"; print -r -- "WantedBy=timers.target"
    } > $tmr
  fi
  mkdir -p $UNITS
  cmp -s $svc $UNITS/$label.service || { mv -f $svc $UNITS/$label.service; changed=1; }
  rm -f $svc
  if [[ -n $tmr ]]; then cmp -s $tmr $UNITS/$label.timer || { mv -f $tmr $UNITS/$label.timer; changed=1; }; rm -f $tmr; fi
  if (( ! changed )) && { [[ -n $tmr ]] && systemctl --user -q is-active $label.timer || systemctl --user -q is-active $label.service; }; then
    echo "   $label 已是最新"; return
  fi
  systemctl --user daemon-reload
  if [[ -n $tmr ]]; then
    systemctl --user enable -q --now $label.timer
    systemctl --user start --no-block $label.service      # first run now, like launchd's RunAtLoad
  else
    systemctl --user enable -q $label.service; systemctl --user restart $label.service
  fi
  echo "   $label 已安装"
}
job() { if [[ $OS == Darwin ]]; then job_launchd "$@"; else job_systemd "$@"; fi; }

say "开机任务"
[[ $OS == Darwin ]] && mkdir -p $LA
chmod +x $REPO/server/*.sh
job $LABEL_MAINT $STATE/logs/maint.log daily:4:0 /bin/zsh $REPO/server/maint.sh
# UPnP port mapping (when on) and the "stable IPv6 changed -> restart" check both live in upnp.sh: install it either way
job $LABEL_UPNP $STATE/logs/upnp.log interval:600 $REPO/server/upnp.sh
if [[ -f ${~DDNS_ENV} ]]; then
  job $LABEL_DDNS $STATE/logs/ddns.log interval:600 $REPO/server/ddns.sh
else
  say "没有 ${DDNS_ENV}：跳过 Cloudflare DDNS（$SERVER_DOMAIN 的 DNS 记录要自己维护）"
fi
[[ -n ${GITHUB_KEYS_USER:-} ]] && job $LABEL_KEYS $STATE/logs/github-keys-sync.log interval:900 $REPO/server/github-keys-sync.sh
job $LABEL_NODE $STATE/logs/launchd.err.log keepalive $REPO/server/run.sh     # last: this one restarts the node

# ---------------------------------------------------------------- 5. verify
sleep 5
pgrep -f "sing-box run -c $STATE/config.json" >/dev/null || { echo "❌ 节点没起来，看 $STATE/logs/launchd.err.log"; exit 1; }
say "节点在运行，监听："
if [[ $OS == Darwin ]]; then
  lsof -nP -a -c sing-box -i 2>/dev/null | awk 'NR>1 && ($8=="UDP" || $10=="(LISTEN)") {print "   " $8 " " $9}' | sort -u
else
  ss -Hlnptu 2>/dev/null | awk '/"sing-box"/ {print "   " toupper($1) " " $5}' | sort -u
fi

# ---------------------------------------------------------------- 6. archive what the migration replaced
if [[ -n $MIGRATE && -d $MIGRATE ]]; then
  ARCH=${MIGRATE}.pre-repo-$(date +%Y%m%d)
  mv $MIGRATE $ARCH
  if (( ${#OLD_BIN} )); then mkdir -p $ARCH/old-bin; for f in ${(u)OLD_BIN}; do [[ -f $f ]] && mv $f $ARCH/old-bin/; done; fi
  say "旧目录已归档到 $ARCH（含旧 ~/bin 脚本；确认一切正常后可以删）"
fi

# subscriptions carry the certificate and the entry points: push them again after every install
if [[ -f $STATE/sub.env ]]; then
  say "订阅"; python3 $REPO/server/sub.py rules && python3 $REPO/server/sub.py publish || echo "⚠️ 订阅推送失败：server/sub.py rules / publish"
fi

say "完成。客户端："
echo "   Mac：     client/macos/install.sh"
echo "   Windows： client/windows/install.sh <ssh 主机>"
echo "   手机：    client/ios/qr.sh；给别人：server/sub.py url <名字>（订阅页，iPhone / Android 一键导入）"
echo "   加人：    server/users.sh add <名字>"
