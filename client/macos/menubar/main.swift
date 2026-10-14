// VPN 菜单栏图标：看状态、连接 / 断开、切节点；「设置…」打开 panel.swift 的设置窗口。开机只启动图标，不自动连接。
// label / configPath / serverIP / serverSSH / serverRepo / brand / exitName 等在构建时由 client/macos/install.sh
// （用户版：build-user-app.sh）从站点参数生成到 Site.swift。
// 连接 = sudo -n launchctl kickstart system/<label>；断开 = sudo -n launchctl kill SIGTERM system/<label>
// （这两条在 /etc/sudoers.d/<CLIENT_NAME> 里免密，其它命令不放开）。
import AppKit
import Network

let autoGroup = "⚡ 自动(HY2)"
let testURL = "https://www.gstatic.com/generate_204"
let logPath = NSString(string: "~/Library/Logs/vpn-menubar.log").expandingTildeInPath

func log(_ line: String) {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let s = "\(f.string(from: Date())) \(line)\n"
    if let h = FileHandle(forWritingAtPath: logPath) {
        h.seekToEndOfFile(); h.write(s.data(using: .utf8)!); h.closeFile()
    } else {
        FileManager.default.createFile(atPath: logPath, contents: s.data(using: .utf8))
    }
}
let groups = ["🏠 Home", "🤖 Claude"]
// 回国 mode (only when the config has these groups): 🇨🇳 国内 = where CN sites go; 🏠 Home = where the rest goes.
// 🤖 Claude has no direct option, so Claude never leaves with a China IP whatever the mode.
let cnSites = "🇨🇳 国内", cnAuto = "🇨🇳 回国", homeGroup = "🏠 Home"
func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)! }

func sh(_ path: String, _ args: [String]) -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = out
    do { try p.run() } catch { return (-1, "\(error)") }
    p.waitUntilExit()
    let s = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return (p.terminationStatus, s.trimmingCharacters(in: .whitespacesAndNewlines))
}

func vpnRunning() -> Bool {
    sh("/usr/bin/pgrep", ["-f", "sing-box run -c \(configPath)"]).0 == 0
}

// user edition (installed from a subscription page): the config is root-only, so the updater copies the API secret
// into a file the user can read; the owner's edition reads it from its own config
func clashSecret() -> String? {
    if !secretPath.isEmpty {
        return (try? String(contentsOfFile: secretPath, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard let d = FileManager.default.contents(atPath: configPath),
          let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
          let e = j["experimental"] as? [String: Any],
          let c = e["clash_api"] as? [String: Any] else { return nil }
    return c["secret"] as? String
}

func clash(_ method: String, _ path: String, body: [String: Any]? = nil, wait: Double = 3) -> [String: Any]? {
    guard let url = URL(string: "http://\(clashAddr)" + path) else { return nil }
    var req = URLRequest(url: url, timeoutInterval: wait)
    req.httpMethod = method
    if let s = clashSecret() { req.setValue("Bearer \(s)", forHTTPHeaderField: "Authorization") }
    if let body = body {
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    let sem = DispatchSemaphore(value: 0)
    var result: [String: Any]?
    URLSession.shared.dataTask(with: req) { data, resp, _ in
        if let data = data, !data.isEmpty {
            result = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        } else if let h = resp as? HTTPURLResponse, h.statusCode == 204 {
            result = [:]
        }
        sem.signal()
    }.resume()
    _ = sem.wait(timeout: .now() + wait + 1)
    return result
}

// ask sing-box to test every node in the auto group now; it switches to the best working one
@discardableResult
func retestAutoGroup(_ why: String) -> String {
    guard vpnRunning() else { return "vpn not running" }
    let g = autoGroup.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!
    let u = testURL.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
    let res = clash("GET", "/group/\(g)/delay?url=\(u)&timeout=5000", wait: 6)
    let now = clash("GET", "/proxies/\(g)")?["now"] as? String ?? "?"
    let delays = (res ?? [:]).map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ")
    let line = "retest (\(why)): \(delays.isEmpty ? "all failed" : delays) -> using \(now)"
    log(line)
    return line
}

func exitIPLine() -> String {
    let (code, out) = sh("/usr/bin/curl", ["-s", "--max-time", "6", "https://ipinfo.io/json"])
    guard code == 0, let d = out.data(using: .utf8),
          let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
          let ip = j["ip"] as? String else { return "查不到（网络不通？）" }
    let cc = j["country"] as? String ?? ""
    return ip == serverIP ? "\(ip) \(cc) ✓" : "\(ip) \(cc) ⚠︎ 不是\(exitName)出口"
}

func selectNode(_ name: String) {
    for g in groups { _ = clash("PUT", "/proxies/" + enc(g), body: ["name": name]) }
}

func applyMode(abroad: Bool) {
    _ = clash("PUT", "/proxies/" + enc(cnSites), body: ["name": abroad ? cnAuto : "direct"])
    _ = clash("PUT", "/proxies/" + enc(homeGroup), body: ["name": abroad ? "direct" : autoGroup])
    log("mode -> \(abroad ? "abroad (CN via desktop, rest direct)" : "in China (CN direct, rest via the server)")")
}

final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let menu = NSMenu()
    var exitLine = "出口 IP：点开菜单时查询"
    var busy = false
    let pathMonitor = NWPathMonitor()
    var lastPath = ""
    var pendingRetest: [DispatchWorkItem] = []

    func applicationDidFinishLaunching(_ n: Notification) {
        menu.delegate = self
        item.menu = menu
        refreshIcon()
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.refreshIcon() }

        // sing-box's urltest only re-checks on its own interval and pauses when idle, so after
        // sleep or a network switch (e.g. hotspot with IPv6 -> office Wi-Fi without) it can keep
        // using a node that cannot work. Force a re-test on wake and on every network change.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            self?.scheduleRetest("wake")
        }
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let desc = "\(path.status == .satisfied ? "up" : "down") v4=\(path.supportsIPv4) v6=\(path.supportsIPv6) " +
                path.availableInterfaces.map { $0.name }.joined(separator: ",")
            DispatchQueue.main.async {
                guard let self = self, desc != self.lastPath else { return }
                let first = self.lastPath.isEmpty
                self.lastPath = desc
                if !first && path.status == .satisfied { self.scheduleRetest("network \(desc)") }
            }
        }
        pathMonitor.start(queue: DispatchQueue.global())
        DistributedNotificationCenter.default().addObserver(forName: openSettingsNote, object: nil, queue: .main) { [weak self] n in
            guard let self = self else { return }
            self.panel.show(app: self, tab: n.object as? String)
        }
    }

    // test now-ish (network settles) and once more a bit later; newer events replace older ones
    func scheduleRetest(_ why: String) {
        pendingRetest.forEach { $0.cancel() }
        pendingRetest = [3.0, 12.0].map { delay in
            let w = DispatchWorkItem { [weak self] in self?.retest(why) }
            DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: w)
            return w
        }
    }

    func retest(_ why: String) {
        retestAutoGroup(why)
        DispatchQueue.main.async { self.exitLine = "出口 IP：点开菜单时查询" }
    }

    @objc func retestNow() { DispatchQueue.global().async { self.retest("manual") } }

    func refreshIcon() {
        let on = vpnRunning()
        let name = busy ? "arrow.triangle.2.circlepath" : (on ? "checkmark.shield.fill" : "shield.slash")
        let img = NSImage(systemSymbolName: name, accessibilityDescription: on ? "VPN 已连接" : "VPN 未连接")
        img?.isTemplate = true
        item.button?.image = img
        item.button?.toolTip = on ? "VPN 已连接（\(exitName)）" : "VPN 未连接：现在是直连"
    }

    func fetchExitIP() {
        DispatchQueue.global().async {
            let line = "出口 IP：" + exitIPLine()
            DispatchQueue.main.async {
                self.exitLine = line
                if let first = self.menu.items.dropFirst().first { first.title = line }
            }
        }
    }

    // rebuilt every time the menu opens, so it always shows the live state
    func menuNeedsUpdate(_ m: NSMenu) {
        m.removeAllItems()
        let on = vpnRunning()
        let state = NSMenuItem(title: on ? "● VPN 已连接" : "○ VPN 未连接（直连，中国 IP）", action: nil, keyEquivalent: "")
        state.isEnabled = false
        m.addItem(state)
        if userEdition && FileManager.default.fileExists(atPath: expiredPath) {
            let exp = NSMenuItem(title: "⚠︎ 账号已到期：找给你链接的人续期", action: nil, keyEquivalent: "")
            exp.isEnabled = false
            m.addItem(exp)
        }
        let ipItem = NSMenuItem(title: exitLine, action: nil, keyEquivalent: "")
        ipItem.isEnabled = false
        m.addItem(ipItem)
        fetchExitIP()
        m.addItem(.separator())

        let toggle = NSMenuItem(title: on ? "断开 VPN" : "连接 VPN", action: #selector(toggleVPN), keyEquivalent: "")
        toggle.target = self
        toggle.isEnabled = !busy
        m.addItem(toggle)

        if on, let home = clash("GET", "/proxies/" + groups[0].addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!),
           let all = home["all"] as? [String], let now = home["now"] as? String {
            let sub = NSMenu()
            for n in all {
                let it = NSMenuItem(title: n, action: #selector(pickNode(_:)), keyEquivalent: "")
                it.target = self
                it.state = n == now ? .on : .off
                sub.addItem(it)
            }
            var shown = now
            if now == autoGroup, let a = clash("GET", "/proxies/" + autoGroup.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!),
               let pick = a["now"] as? String {
                shown = "\(now) → \(pick)"
            }
            let nodes = NSMenuItem(title: "节点：\(shown)", action: nil, keyEquivalent: "")
            nodes.submenu = sub
            m.addItem(nodes)
            let rt = NSMenuItem(title: "立即重测节点", action: #selector(retestNow), keyEquivalent: "")
            rt.target = self
            m.addItem(rt)
            if let cn = clash("GET", "/proxies/" + enc(cnSites)), let cnNow = cn["now"] as? String {
                let abroad = cnNow == cnAuto
                let modes = NSMenu()
                for (title, value) in [("在国内：国内网站直连，其余走\(exitName)", false), ("在国外·回国：国内网站走国内家里台式机，其余直连", true)] {
                    let it = NSMenuItem(title: title, action: #selector(setMode(_:)), keyEquivalent: "")
                    it.target = self
                    it.representedObject = value
                    it.state = value == abroad ? .on : .off
                    modes.addItem(it)
                }
                let mi = NSMenuItem(title: abroad ? "模式：在国外·回国" : "模式：在国内", action: nil, keyEquivalent: "")
                mi.submenu = modes
                m.addItem(mi)
            }
        }
        m.addItem(.separator())
        let settings = NSMenuItem(title: "设置…", action: #selector(openPanel), keyEquivalent: ",")
        settings.target = self
        m.addItem(settings)
        if userEdition {
            let upd = NSMenuItem(title: "立即更新配置", action: #selector(updateNow), keyEquivalent: "")
            upd.target = self
            m.addItem(upd)
            let help = NSMenuItem(title: "使用说明", action: #selector(openHelp), keyEquivalent: "")
            help.target = self
            m.addItem(help)
            let uninstall = NSMenuItem(title: "卸载\(brand)…", action: #selector(uninstallAll), keyEquivalent: "")
            uninstall.target = self
            m.addItem(uninstall)
        }
        let quit = NSMenuItem(title: "退出菜单栏图标（不影响 VPN）", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        m.addItem(quit)
    }

    @objc func toggleVPN() {
        let on = vpnRunning()
        busy = true
        refreshIcon()
        DispatchQueue.global().async {
            let args = on ? ["-n", "/bin/launchctl", "kill", "SIGTERM", "system/\(label)"]
                          : ["-n", "/bin/launchctl", "kickstart", "system/\(label)"]
            let (code, out) = sh("/usr/bin/sudo", args)
            // wait for the state to actually change (up to 10 s)
            var ok = false
            for _ in 0..<20 {
                if vpnRunning() != on { ok = true; break }
                Thread.sleep(forTimeInterval: 0.5)
            }
            DispatchQueue.main.async {
                self.busy = false
                self.exitLine = "出口 IP：点开菜单时查询"
                self.refreshIcon()
                if code != 0 || !ok {
                    let a = NSAlert()
                    a.messageText = on ? "断开失败" : "连接失败"
                    a.informativeText = code != 0
                        ? "sudo 免密规则可能没装好：\n\(out)"
                        : "命令执行了，但状态没变。\(userEdition ? "重新运行一次安装命令可以修复。" : "看 \(errLogPath)")"
                    a.runModal()
                } else {
                    self.notify(on ? "VPN 已断开，现在是直连（中国 IP）" : "VPN 已连接（\(exitName)出口）")
                    if !on { self.scheduleRetest("connect") }
                }
            }
        }
    }

    @objc func pickNode(_ sender: NSMenuItem) {
        selectNode(sender.title)
        exitLine = "出口 IP：点开菜单时查询"
    }

    @objc func setMode(_ sender: NSMenuItem) {
        let abroad = sender.representedObject as? Bool ?? false
        applyMode(abroad: abroad)
        exitLine = "出口 IP：点开菜单时查询"
        notify(abroad ? "回国模式：国内网站走国内家里的台式机，其余直连" : "在国内模式：国内网站直连，其余走\(exitName)")
    }

    let panel = PanelWindow()
    @objc func openPanel() { panel.show(app: self) }
    @objc func quit() { NSApp.terminate(nil) }

    // the updater is a root LaunchDaemon (com.<app id>.update, next to `label` = com.<app id>.vpn);
    // /etc/sudoers.d/<app id> lets any user kick it
    var updateLabel: String { label.hasSuffix(".vpn") ? String(label.dropLast(4)) + ".update" : label + ".update" }
    @objc func updateNow() {
        DispatchQueue.global().async {
            let (code, _) = sh("/usr/bin/sudo", ["-n", "/bin/launchctl", "kickstart", "system/" + self.updateLabel])
            DispatchQueue.main.async {
                self.notify(code == 0 ? "正在更新配置，有变化会自动重连。" : "更新没启动：重新运行一次安装命令可以修复。")
            }
        }
    }

    @objc func openHelp() {
        if let s = try? String(contentsOfFile: helpPath, encoding: .utf8),
           let u = URL(string: s.trimmingCharacters(in: .whitespacesAndNewlines)) { NSWorkspace.shared.open(u) }
    }

    // the uninstaller is root's; macOS asks for the password in its own dialog
    @objc func uninstallAll() {
        let a = NSAlert()
        a.messageText = "确定要卸载「\(brand)」吗？"
        a.informativeText = "卸载后这台 Mac 就不走\(brand)了。以后想用，用订阅页上的安装命令再装一次。"
        a.addButton(withTitle: "卸载")
        a.addButton(withTitle: "取消")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let script = "do shell script \"/bin/bash '\(uninstallPath)'\" with administrator privileges with prompt \"卸载\(brand)需要这台 Mac 的密码。\""
        let (code, out) = sh("/usr/bin/osascript", ["-e", script])
        if code != 0 && !out.contains("-128") {   // -128 = the user pressed Cancel
            let e = NSAlert(); e.messageText = "卸载没完成"; e.informativeText = out; e.runModal()
        }
    }

    func notify(_ text: String) {
        _ = sh("/usr/bin/osascript", ["-e", "display notification \"\(text)\" with title \"\(userEdition ? brand : "VPN")\""])
    }
}

let openSettingsNote = Notification.Name(menubarLabel + ".open-settings")
if let i = CommandLine.arguments.firstIndex(of: "--settings") {   // ask the running app to open its settings window: --settings [status|users]
    let tab = CommandLine.arguments.dropFirst(i + 1).first ?? "status"
    DistributedNotificationCenter.default().postNotificationName(openSettingsNote, object: tab, userInfo: nil, deliverImmediately: true)
    exit(0)
}
if CommandLine.arguments.contains("--retest-once") {   // for checking from a terminal
    print(retestAutoGroup("cli"))
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = App()
app.delegate = delegate
app.run()
