# home-vpn

Turn an always-on machine abroad — a Mac mini at home, a Linux box, or a VPS — into your own private exit. When you're in mainland China, your phone and computers connect to it and the internet sees that machine's IP, so Claude, ChatGPT, Google and Netflix keep working.

[中文](README.md)

```
devices in China                                 the machine abroad
Mac / Windows / phone ──IPv4 :443 (UDP/TCP) ──┐
                      ──IPv6 :8443 (UDP) ─────┼─> sing-box ──> internet (its IP)
                                              ┘
```

| Node | Protocol | Role |
|---|---|---|
| Home-HY2-v4 / -v6 | Hysteria2 (UDP) | Main. 25–40 Mbps measured from China |
| Home-STLS-v4 / -v6 | Shadowsocks 2022 + ShadowTLS v3 (TCP 443) | Manual fallback when UDP is disrupted; only 0.3–0.4 Mbps |

Client routing: Chinese sites go direct, Claude only ever goes through the exit, everything else goes through the exit. The two HY2 nodes are picked by latency. ShadowTLS stays out of the auto group: it has the lowest latency and almost no bandwidth, so a latency test would always choose it. Design decisions and pitfalls: [docs/gotchas.md](docs/gotchas.md) (Chinese).

## Features

- **One-command server**: macOS (launchd) or Linux (systemd). It generates passwords and a self-signed certificate (clients pin its fingerprint), installs boot jobs, rotates logs daily, revokes expired accounts, maps ports over UPnP on home routers, and can keep a Cloudflare DDNS record current.
- **Mac client**: one command, with a menu bar switch. It re-tests nodes after sleep or a network change, and its settings window shows each account's online devices and source IPs.
- **Windows client**: installed remotely from your Mac, with a tray icon and desktop shortcuts. When a config change is applied right away, a 5-minute auto-rollback task is armed first and removed once the exit is verified.
- **Phones**: scan a QR code in Shadowrocket.
- **Sharing**: give each person their own account with an expiry date, and revoke it any time. Each person gets one subscription link that works on iPhone, Android, TV boxes, Windows and Mac. The subscription service runs on a Cloudflare Worker that only stores ciphertext.
- **Reverse exit** (optional): when you're abroad, use your home connection in China through a computer left on there.

## Requirements

- **Server**: an always-on macOS or Linux (Debian/Ubuntu) machine with a public IPv4 or a public IPv6. For IPv4 on home broadband, the router needs UPnP or a manual port forward for 443.
- **Domain**: a domain pointing at the server; the HY2 certificate is issued for it. If your home IP changes, `server/ddns.sh` can update a Cloudflare record.
- **Clients**: a Mac for your own client and for installing Windows remotely. Shadowrocket on iPhone needs a non-China Apple ID.
- **ssh**: client installers ssh to the server to fetch passwords and the certificate. The easy way is to set `GITHUB_KEYS_USER` in `site.env`, and the server will sync your GitHub public keys.

## 1. Server

```bash
# macOS: install Homebrew first. Linux: sudo apt install -y zsh git
git clone https://github.com/leeguooooo/home-vpn ~/home-vpn
cd ~/home-vpn
cp -R site.example site            # your deployment's parameters, not tracked by git
$EDITOR site/site.env              # at least SERVER_DOMAIN, SERVER_V4, SERVER_SSH
server/install.sh                  # dependencies → secrets and certificate → config → boot jobs → start
```

- Re-running is safe. `--check` only renders and validates the config.
- **macOS**: user LaunchAgents, no sudo.
- **Linux**: systemd `--user` units, plus `loginctl enable-linger` so the node runs without a login session. sing-box (`SINGBOX_VERSION`) is downloaded to `~/.home-vpn/bin/`. Unprivileged users can't listen on 443 by default, so the installer uses sudo once to write `net.ipv4.ip_unprivileged_port_start=443` to `/etc/sysctl.d/`.
- **Ports**: open UDP 443, TCP 443, and UDP 8443 on IPv6.
- **Where data lives**: secrets, certificates, users and logs are in `~/.home-vpn/` on the server (`STATE_DIR`), never in the repo.
- **`site/`**: holds only your domain and IP, no secrets. You can keep it in a private repo of its own, cloned into `~/home-vpn/site`.

```bash
server/users.sh add alice 30       # new account, expires in 30 days (0 = never); restart the node to apply
server/users.sh expire alice 90    # days, 2026-12-31 or never; no restart
server/users.sh del alice          # revoke (restarts the node: everyone drops for 10–20 s)
server/audit.py [name] [--days 7]  # who connected, where they went, what was blocked
```

## 2. Clients

```bash
client/macos/install.sh                        # Mac (asks for your password once)
client/windows/install.sh <ssh host> --apply   # Windows, over ssh from the Mac (needs OpenSSH Server, admin account)
client/ios/qr.sh                               # QR codes for Shadowrocket
```

## 3. Subscription links (optional)

Deploy `sub/` as a Cloudflare Worker:

1. Fill in `site/wrangler.toml` (KV namespace, R2 bucket, custom domain; `workers.dev` is blocked in China), then run `npx wrangler deploy -c site/wrangler.toml`.
2. Set the Worker secret `ADMIN_TOKEN`, and put the same value in `~/.home-vpn/sub.env` as `SUB_ADMIN_TOKEN=` on the server.
3. Set `SUB_BASE` in `site.env`.

Then `server/sub.py url <name>` prints a link. Opened in a browser, the link shows an install page; fetched by an app, it returns the matching format (Shadowrocket, Clash/mihomo or sing-box). The server encrypts each person's config with a key derived from their token before uploading, so Cloudflare only holds ciphertext.

## 4. Reverse exit (optional)

Set `CN_EXIT_USER` and `SERVER_SSH_USER` in `site.env`, and `cn_exit_listen_port` in the profile of a Windows machine at home in China, then run `client/windows/install.sh` on that machine. It opens a restricted reverse ssh tunnel to the server. Traffic from the `CN_EXIT_USER` account leaves through it with that home connection's IP. The tunnel is TCP only.

## Security

Only `OWNER_USERS` (your shared account by default) can reach the server's LAN through the proxy. For every other account, connections to private addresses, the server itself and its public addresses are refused after DNS resolution. SMTP port 25 and BitTorrent are refused for everyone.

## Disclaimer

For running a private line for yourself and people you trust, on machines you own. Follow the laws where you are and where the server is, and the terms of the services you use.

MIT License
