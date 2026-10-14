# home-vpn

把你在海外的一台常开电脑（家里的 Mac mini、Linux 小主机，或者一台 VPS）变成私人出口。人在国内时，手机和电脑连过去，网站看到的就是那台机器所在地的 IP，可以正常用 Claude、ChatGPT、Google 和 Netflix。

[English](README.en.md)

```
国内的设备                                    海外那台机器
Mac / Windows / 手机 ──IPv4 :443 (UDP/TCP) ──┐
                    ──IPv6 :8443 (UDP) ──────┼─> sing-box ──> 外网（那台机器的 IP）
                                             ┘
```

| 节点 | 协议 | 用途 |
|---|---|---|
| Home-HY2-v4 / -v6 | Hysteria2（UDP） | 主力。国内实测 25~40 Mbps |
| Home-STLS-v4 / -v6 | Shadowsocks 2022 + ShadowTLS v3（TCP 443） | UDP 被干扰时手动切过去应急，实测只有 0.3~0.4 Mbps |

客户端默认分流：国内网站直连，Claude 只走出口（没有直连兜底），其余走出口。两条 HY2 线路按延迟自动选，ShadowTLS 不进自动组，因为它延迟最低、带宽却几乎没有，按延迟选一定会选中它。为什么这样设计、踩过哪些坑，见 [docs/gotchas.md](docs/gotchas.md)。

## 能做什么

- **服务端一键部署**：macOS（launchd）或 Linux（systemd）。脚本自动生成密码和自签证书（客户端锁定证书指纹），装好开机任务，每天清理日志，并撤销到期的账号。家宽路由器支持 UPnP 的话会自动映射端口，用 Cloudflare 管域名的话可以自动更新 DDNS。
- **Mac 客户端**：一条命令装好，带菜单栏开关。系统睡醒或换网络后会重测节点，设置窗口里能看到每个账号的在线设备和来源 IP。
- **Windows 客户端**：在 Mac 上用一条命令远程装好，带托盘图标和桌面开关。改了配置要立即生效时，会先挂一个 5 分钟后自动回滚的任务，确认出口正确后再撤掉。
- **手机**：用 Shadowrocket 扫码导入。
- **给别人用**：每人一个独立账号，可以设到期日、随时撤销，每人一条订阅链接。iPhone、安卓、电视盒子、Windows、Mac 都能用这条链接一键导入。订阅服务跑在 Cloudflare Worker 上，上面只存密文。
- **回国出口**（可选）：反过来，人在国外时通过国内家里那台电脑用国内 IP。

## 准备

- **服务器**：一台常开的 macOS 或 Linux（Debian / Ubuntu）机器。家宽要么有公网 IPv4（路由器支持 UPnP，或者能手动转发 443 端口），要么有公网 IPv6。VPS 本来就有公网 IP。
- **域名**：要有一个指向服务器的域名，HY2 的证书用这个名字签。家宽 IP 会变的话，配好 DDNS（`server/ddns.sh` 支持 Cloudflare）。
- **客户端**：一台 Mac，用来装自己的客户端，也用来远程装 Windows。手机用 Shadowrocket（需要外区 Apple ID）。
- **ssh**：客户端安装时会 ssh 到服务器去取密码和证书。最省事的办法是在 `site.env` 里填 `GITHUB_KEYS_USER`，服务器会自动同步你登记在 GitHub 上的公钥。

## 1. 服务端

```bash
# macOS 要先装 Homebrew；Linux 要先装 zsh：sudo apt install -y zsh git
git clone https://github.com/leeguooooo/home-vpn ~/home-vpn
cd ~/home-vpn
cp -R site.example site            # 你这套部署的参数，不进 git
$EDITOR site/site.env              # 至少要改 SERVER_DOMAIN、SERVER_V4、SERVER_SSH
server/install.sh                  # 装依赖 → 生成密码和证书 → 渲染配置 → 装开机任务 → 启动
```

- 脚本可以重复运行，已经是最新的步骤会自动跳过。加 `--check` 只渲染和校验配置，不动开机任务。
- **macOS**：开机任务装成用户级 LaunchAgent，全程不需要 sudo。
- **Linux**：开机任务是 systemd `--user` 单元，脚本会执行 `loginctl enable-linger`，这样不登录也能运行。sing-box 按 `SINGBOX_VERSION` 下载到 `~/.home-vpn/bin/`。普通用户默认不能监听 443，所以脚本会用一次 sudo，往 `/etc/sysctl.d/` 写入 `net.ipv4.ip_unprivileged_port_start=443`。
- **端口**：防火墙和路由器要放行 UDP 443、TCP 443，以及 IPv6 的 UDP 8443。
- **数据位置**：密码、证书、用户、日志都在服务器的 `~/.home-vpn/`（由 `STATE_DIR` 决定），不在仓库里。
- **`site/`**：只有你自己的域名和 IP，没有密码。可以单独放进一个私有仓库，克隆到 `~/home-vpn/site`，几台电脑就能共用。

日常管理：

```bash
server/users.sh list                   # 用户和到期日
server/users.sh add xiaowang 30        # 加人（30 天后到期，0 = 永不到期），重启节点后生效
server/users.sh expire xiaowang 90     # 改到期日：天数、2026-12-31 或 never。不用重启
server/users.sh del xiaowang           # 撤销（会重启节点，所有人断开 10~20 秒）
server/audit.py [名字] [--days 7]       # 谁连过、访问了哪些站、被拦了什么
```

## 2. Mac 客户端

```bash
gh ssh-key add ~/.ssh/id_ed25519.pub         # 把公钥登记到 GitHub，服务器 15 分钟内会同步（没填 GITHUB_KEYS_USER 就自己把公钥加进服务器）
cat client/ssh-config.example >> ~/.ssh/config   # 再把里面的主机名改成你的
client/macos/install.sh                      # 第一次运行会要求输入一次电脑密码
```

- 菜单栏会出现一个盾牌图标，带勾表示已连接，带斜杠表示未连接。点开可以连接 / 断开、看出口 IP、切换节点。
- 开机只启动图标，不会自动连 VPN。
- 更新：`git pull && client/macos/install.sh`。配置变了默认在下次连接时生效，加 `--apply` 会立即断开重连。

## 3. Windows 客户端（在 Mac 上远程装）

那台 Windows 要先开启「OpenSSH 服务器」，ssh 用的账号要是管理员，公钥放在 `C:\ProgramData\ssh\administrators_authorized_keys`。

```bash
client/windows/install.sh <ssh 主机> --apply   # 如果有 site/clients/<ssh 主机>.json，会自动套用里面的设置
```

装好后：sing-box 在 `C:\ProgramData\sing-box\`，开机以 SYSTEM 身份自动连接；桌面有「VPN 开关」和「VPN 状态」，右下角托盘有状态图标。

## 4. 手机

```bash
client/ios/qr.sh          # 屏幕上显示两个 HY2 节点的二维码，在 Shadowrocket 左上角扫码导入
```

## 5. 给别人用：订阅链接（可选）

不想给每个人都配 ssh，可以部署订阅服务。每人一条 `https://sub.example.com/s/<令牌>`，App 来取时按 User-Agent 返回对应格式，浏览器打开则是安装页，会自动识别设备。

| 设备 | 用户要装什么 | 怎么导入 |
|---|---|---|
| iPhone / iPad | Shadowrocket | 安装页上「一键导入」 |
| 安卓 | FlClash（订阅服务提供镜像） | 安装页上「一键导入」 |
| 电视 / 盒子 | Clash Meta | 用遥控器输入 8 位电视码地址 |
| Windows / Mac | 本仓库的用户版（`client/*/user/`） | 粘贴一行命令 |

部署步骤：

1. 在 Cloudflare 建一个 KV 和一个 R2 桶，把 `site/wrangler.toml` 填好，然后执行 `npx wrangler deploy -c site/wrangler.toml`。
2. 生成一个管理口令，设为 Worker 的 secret `ADMIN_TOKEN`，同样的值写进服务器 `~/.home-vpn/sub.env` 的 `SUB_ADMIN_TOKEN=`。
3. 把 `site.env` 里的 `SUB_BASE` 设成 Worker 的自定义域名（`workers.dev` 在国内打不开），然后执行 `server/sub.py rules`、`server/sub.py apps`。
4. 给某人发链接：`server/sub.py url <名字>`。

服务器生成配置后，用从令牌派生的密钥加密再推上去，所以 Cloudflare 上只有密文。分流规则和安装包也从这个域名下载，国内不用连 GitHub。用户的 App 和程序每 6 小时自动更新配置；到期或被撤销后，链接就失效了。

**安全**：只有 `OWNER_USERS`（默认就是你自己的共用账号）能经代理访问服务器所在的局域网。其他账号连到局域网、服务器本机或家里公网地址的流量，都会在解析后被拒绝。另外所有人都不能连 25 端口，也不能用 BT。

## 6. 回国出口（可选）

人在国外、又要用国内 IP 时（B 站、网银、国内视频的版权限制），让国内家里一台 Windows 开着，它连上服务器后反向开一条 ssh 通道。用「回国」账号连服务器的流量，就会经这条通道从国内家宽出去。光猫不用改，不需要公网 IP，那台电脑也不用对外开端口。

- 在 `site.env` 里设 `CN_EXIT_USER=cn`（再 `server/users.sh add cn 0`）和 `SERVER_SSH_USER`。在 `site/clients/<那台电脑>.json` 里设 `"cn_exit_listen_port": 18090`。之后执行 `client/windows/install.sh <那台电脑>`，它会把通道和授权一起装好。
- 只走 TCP：服务端会直接拒绝 UDP，App 会马上改用 TCP。网页、视频、银行 App 都能用；少数只走 UDP 的游戏和语音不行。
- Mac 菜单栏「模式」可以切换：选「在国外·回国」时，国内网站走那台电脑，其余直连。

## 仓库结构

```
lib/defaults.env        所有参数的默认值（名字、端口、开关）
site.example/           你自己的 site/ 从这里复制：域名、IP、每台电脑的额外设置、订阅服务配置
server/                 服务端：安装、渲染配置、用户、维护、审计、UPnP、DDNS、公钥同步、订阅推送、回国通道
client/make-config.py   所有客户端共用的配置生成器（节点、分组、分流规则都在这一个文件里）
client/macos/           Mac：安装脚本、菜单栏程序（Swift）、给别人用的用户版
client/windows/         Windows：远程安装、托盘、用户版
client/ios/qr.sh        手机扫码导入
sub/worker.js           订阅服务（Cloudflare Worker）
tests/                  python3 -m unittest discover -s tests（设置 SINGBOX=… 时会对每份生成的配置跑 sing-box check）
```

## 出问题先看这里

| 现象 | 处理 |
|---|---|
| 突然变慢 | 看当前选中的是哪个节点（Mac 看菜单栏，Windows 打开 `http://127.0.0.1:9090/ui`）。被切到 STLS 就换回自动组 |
| 连上了但打不开网页 | Mac 看 `/tmp/home-vpn-client.err`：`no route to host` 说明选错了节点（点菜单栏「立即重测节点」）；timeout 说明线路有问题 |
| Google 打不开、别的都正常 | 客户端 tun 的 `stack` 必须是 `gvisor` |
| 所有设备都连不上 | 先 ssh 到服务器看 `~/.home-vpn/logs/`；macOS 执行 `launchctl list \| grep home-vpn`，Linux 执行 `systemctl --user status io.github.home-vpn.node` |

## 声明

本项目用于你自己和信任的人在自己的机器上搭私人线路。请遵守你所在地和服务器所在地的法律，以及各网站的服务条款。

MIT License
