# 踩过的坑

按「现象 → 原因 → 做法」记。改代码前先看一遍，很多「看起来更合理」的改法这里已经证明不行。

## 铁律

- **回国期间本机流量永远不能以中国 IP 出去**（账号会被封）。不切手机热点直连、不随手停客户端 sing-box；停的那几秒 TUN 不在，就是直连。客户端安装脚本默认不重启正在跑的 VPN，`--apply` 才会。
- **重启服务端不会露 IP**：客户端 TUN 一直在，服务端断的 10~20 秒只是连不上。但会连带断掉你正经它 ssh 的会话，等一下自己恢复。
- 服务器和客户端可能不在一个时区（比如服务器在东京、笔记本设的上海时间），对日志时先换算。

## 服务端

- **绑定具体地址时 443 报 permission denied**：macOS 普通用户只能在「所有地址」上监听 <1024 端口。HY2-v6 要绑具体地址，所以用 8443。
- **HY2 在 IPv6 上不通、TCP 却通**：监听 `::` 时 UDP 回包可能从临时 IPv6 发出，客户端丢弃。`run.sh` 启动时填入稳定（非 temporary）地址；`upnp.sh` 发现稳定地址变了就重启节点。
- **从某台机器测 HY2-v6 失败**：那台走 Cloudflare WARP，IPv6 路径 MTU 1280，QUIC 握手包过不去。换网络测，不是服务端问题。
- **IPv4 入口晚高峰可能被限速到 0**（2026-09-21），同时 v6 正常；也有反过来的时候。所以客户端两条 HY2 都要有，由自动组挑。
- **Brutal 只在下行一定有用，上行要按网络实测**：客户端 `down_mbps` 让服务端往你这发时不因丢包降速（2026-09-18 单连接 5~18 → 55~89 Mbps；2026-09-29 家里宽带 v4 下载 60 → 82）。`up_mbps` 是你往服务器发的速度，声明高了会猛丢包、低了会被压住：2026-09-29 国内家里宽带（中国移动）往东京上传，不设 28~105 波动，Brutal 40 → ~30，60 → 37~45（最稳），80 → 忽好忽坏。所以站点默认不设上行（笔记本会换网络，普通拥塞控制自己适应），固定在家的台式机在 `site/clients/<机器>.json` 用 `hy2_up_mbps` 钉 60。测法：临时起一个不接管系统的 sing-box（mixed 入站 + 出站 `bind_interface: en0` 直连服务器），换不同 `up_mbps` 交替上传 `speed.cloudflare.com/__up`，多轮取中位数。
- **国内家里宽带的 IPv6 往境外上传可能被卡在约 5 Mbps**（2026-09-29，中国移动，不管设不设 Brutal 都是 4.9~5.0），下载正常（~80）。自动组选到 v6 时上传就只有 5 Mbps。
- **macOS 替换开机任务时 bootstrap 报 `5: Input/output error`**：`launchctl bootout` 返回时任务还没走完，紧跟着 bootstrap 就失败，节点会停在没加载的状态。安装脚本先轮询 `launchctl print` 直到任务消失，bootstrap 再重试几次。
- **日志里大量 `shadowtls … hmac mismatch`**：公网扫描器探测 443，ShadowTLS 把它们转给 apple.com，正常。
- **解析 secrets.env 不能用 `cut -d= -f2`**：SS2022 密码是 base64，带 `=`，会被截断。按第一个 `=` 切（`lib/jpx.py`）。
- **Hysteria2 不开 salamander 混淆**：Surge 5.10 不支持，当时为了兼容没开；现在客户端都能配，但开了要所有设备重发配置。

## 客户端（sing-box）

- **TUN 必须 `"stack": "gvisor"`**：`system` 栈下 `hijack-dns` 接管不了 macOS 的解析，系统仍用国内 DNS，Google 被投毒、TLS 被 RST。
- **隧道内 DNS 用 `8.8.8.8`，别用 `1.1.1.1`**（国内连不上 Cloudflare DoH，拖 20 秒）。`8.8.8.8` 是 IP，别再给它配 `domain_resolver`，否则自指超时，流量掉回直连。
- **SS2022 over ShadowTLS 的 UDP 报 `invalid argument`**：shadowsocks 出站加 `"udp_over_tcp": {"enabled": true, "version": 2}`。
- **规则集要是本地文件**：启动时在线下载规则集，第一个节点不通就会卡 15 秒后退出。安装脚本让服务器代下，客户端启动不联网。
- **STLS 不能放进自动组**：国内 STLS 只有 0.3~0.4 Mbps，但延迟最低（约 270ms，HY2 约 280ms），按延迟挑会选中它。2026-09-28 另一个会话为修「没有 IPv6」把 v6 节点全删，只剩 STLS，速度掉到 0.7 Mbps。
- **自动组 v4 在前**：一个都没测过或都失败时 urltest 用第一个；v4 有没有 IPv6 都能用。
- **睡醒 / 换网络后卡在坏节点**（2026-09-28 夜里断了一晚）：热点（有 IPv6）上选了 v6 → 睡眠 → 醒来在没有 IPv6 的网络 → 一直用 v6，笔记本日志 8603 次 `no route to host`，一次都没试 v4。sing-box urltest 只按间隔测、空闲会暂停，不会因唤醒或网络变化重测。Mac 菜单栏图标监听唤醒和网络变化，调 clash API `GET /group/<自动组>/delay` 强制重测。
- **排查「上不了网」先看报错类型**：`no route to host` = 本机没这类地址（选错了节点）；timeout = 包发出去没回应（线路或封锁）。再对服务端日志的连接数。
- **`cache_file` 会记住 selector 的选择**，优先于配置里的 default。改了分组结构后用 clash API 显式切一次。
- **Mac 上验证免密 sudo 别用 `sudo -n -l <命令>`**：有 `(ALL) ALL` 时它对任何命令都说允许（不管要不要密码）。要实际执行：服务在跑时 `sudo -n launchctl kickstart system/…`（不带 `-k` 是空操作）。

## Windows

- **PowerShell 5.1 读没有 BOM 的 UTF-8 文件会按 GBK 解释**：中文乱码，连文件名都建错（建快捷方式报 "pathname must end with .lnk"）。仓库里的 `.ps1` 都带 BOM；`.vbs` 要纯 ASCII、不带 BOM（wscript 不认）。
- **通过 ssh 跑 PowerShell 别内联复杂命令**：引号和中文会被拆坏。写成文件传过去再 `-File`。
- **文件从一个账号的家目录移到公共目录会带着原来的权限**：别的账号双击就一闪而过。放好后 `icacls <文件> /reset` 继承目录权限。
- **ssh 账号和日常账号可能不是同一个**：比如 ssh 登录用 A 账号，桌面和浏览器在 B 账号。桌面图标、托盘要装给日常账号（profile 的 `desktop_user`）；在 ssh 账号下测一切正常说明不了什么。
- **桌面可能被 OneDrive 接管**：真实路径看该用户注册表 `User Shell Folders\Desktop`。
- **这台的 UAC 是「管理员提权不提示」**（`ConsentPromptBehaviorAdmin=0`）：带管理员标记的快捷方式直接执行，不弹确认框。
- **控制台窗口一闪而过时什么都看不到**：开关和状态改成 MessageBox 弹窗，快捷方式带 `-WindowStyle Hidden`，每次运行写 `C:\ProgramData\sing-box-tools\vpn-switch.log`（有记录 = 脚本跑了，没记录 = 快捷方式或权限没让它跑起来）。
- **PowerShell 函数参数不能叫 `$args`**（自动变量，会被当成数组）。
- **Defender 会把某些 `-EncodedCommand` 里用 `UdpClient` 的脚本当恶意（Commando.A!ml）拦掉**。别用编码命令发 UDP。
- **某个网站一直「加载中」**：先用全新配置的 Chrome（或无痕窗口）试。2026-09-23 chatgpt.com 卡住是 Chrome 里的 Smartproxy 代理扩展抢了代理——扩展代理优先于系统，整机已走 TUN，不需要它。

## 回国出口（ssh 反向通道）

- **authorized_keys 里不能写 `permitopen="none"`**：那是 sshd_config 的写法；写在钥匙选项里 sshd 会判整行无效、直接拒绝这把钥匙（Permission denied，看不出原因）。用 `permitopen="127.0.0.1:9"`（没人监听）等于禁止正向转发。逐项加选项二分定位的。
- **Windows 上以 SYSTEM 运行的 ssh 拒绝用「别人可读」的私钥**：ssh-keygen 会给创建它的账号单独加一条 ACE，`icacls /grant:r` 不会去掉它；对 SYSTEM 来说那个账号就是「别人」→ `UNPROTECTED PRIVATE KEY FILE`。只留 SYSTEM 和 Administrators（安装脚本已处理）。
- **PowerShell 5.1 丢掉空的原生参数**：`ssh-keygen -N ""` 要用 `Start-Process -ArgumentList` 的整串写法。
- **sshd 默认不检测对端掉线**：通道断了以后旧会话还占着 18090，新连接绑不上端口。强制命令检查占用者是不是本次连接（沿父进程往上查三层，中间可能隔着 shell），不是就杀掉并退出，让台式机重连。
- **分组切换会断反向通道**：Home / Claude 设了 `interrupt_exist_connections`，台式机上任何切分组（包括别的自动切换脚本）都会断掉走 Home 的 ssh 通道，约 45 秒内自己重连。
- **验证回国出口**：用国内网站（myip.ipip.net、B 站 zone 接口），别用 ipinfo.io 这类境外站——经国内出口访问境外站本来就会被墙。从境外那边测（在服务器上起一个回国账号的客户端），在国内测会混进国内到服务器那段 UDP 握手的丢包。curl 要看状态码，别只看正文（跳转时正文是空的）。

## 手机（Shadowrocket）

- **连通性测试默认用 TCP，对 HY2 会显示超时**，不代表不通。判断标准是能不能打开网页。
- **只有 IPv4 的网络要有 Home-HY2-v4**：早期手机只配了 IPv6 节点，纯 IPv4 网络上一个能用的都没有。
- Surge 没有 Pro 就没有「出站模式」，只能直连；所以用 Shadowrocket。
