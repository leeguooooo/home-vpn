// 设置面板（菜单「设置…」）：「状态」看连接、切节点和模式；「用户」看服务器上每个账号有几台设备在用、从哪里连、连了多少。
// 「用户」的数据来自 ssh $serverSSH 跑 server/audit.py --json，所以只有能 ssh 到服务器的电脑（管理员）看得到。
import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

struct NodeRow: Identifiable { let id: String; let delay: Int? }

struct Source: Decodable, Identifiable {
    let net: String, ip: String, `where`: String, devices: Int, conns: Int, first: String, last: String, idle: Int
    var id: String { net }
}
struct UserUsage: Decodable, Identifiable {
    let name: String, created: String?, expires: String?, shared: Bool
    let sub: Bool?
    let conns: Int, blocked: Int, online: Int, last: String?
    let sources: [Source]
    let top: [[Top]]
    var id: String { name }
    enum Top: Decodable {
        case s(String), n(Int)
        init(from d: Decoder) throws {
            let c = try d.singleValueContainer()
            if let n = try? c.decode(Int.self) { self = .n(n) } else { self = .s(try c.decode(String.self)) }
        }
        var text: String { switch self { case .s(let s): return s; case .n(let n): return "\(n)" } }
    }
}
struct Usage: Decodable { let generated: String; let hours: Int; let users: [UserUsage] }

extension ISO8601DateFormatter {
    static let day: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        f.timeZone = .current
        return f
    }()
}

func ago(_ secs: Int) -> String {
    switch secs {
    case ..<60: return "刚刚"
    case ..<3600: return "\(secs / 60) 分钟前"
    case ..<86400: return "\(secs / 3600) 小时前"
    default: return "\(secs / 86400) 天前"
    }
}

// stdout only (ssh warnings on stderr must not end up in the JSON)
func run(_ path: String, _ args: [String]) -> (Int32, Data, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let out = Pipe(), err = Pipe()
    p.standardOutput = out
    p.standardError = err
    do { try p.run() } catch { return (-1, Data(), "\(error)") }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    let e = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    p.waitUntilExit()
    return (p.terminationStatus, data, e.trimmingCharacters(in: .whitespacesAndNewlines))
}

final class PanelModel: ObservableObject {
    weak var app: App?
    @Published var running = false
    @Published var busy = false
    @Published var exitLine = ""
    @Published var nodes: [NodeRow] = []
    @Published var current = ""        // 🏠 Home's choice
    @Published var autoPick = ""       // what the auto group is using
    @Published var abroad: Bool? = nil // nil = this config has no 回国 groups
    @Published var retesting = false
    @Published var delays: [String: Int] = [:]   // measured here: sing-box keeps no delay history for the API

    @Published var tab = "status"      // "status" | "users"
    @Published var hours = 24
    @Published var usage: Usage? = nil
    @Published var usageError = ""
    @Published var loadingUsage = false
    @Published var savingExpiry = false
    @Published var subURL: [String: String] = [:]
    @Published var subBusy = ""

    var timer: Timer?

    func start() {
        refresh()
        refreshExit()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.refresh() }
        if usage == nil && !serverSSH.isEmpty { loadUsage() }
        if delays.isEmpty { measure() }
    }
    func stop() { timer?.invalidate(); timer = nil }

    func refresh() {
        DispatchQueue.global().async {
            let on = vpnRunning()
            var rows: [NodeRow] = [], cur = "", pick = "", ab: Bool? = nil
            if on, let all = clash("GET", "/proxies")?["proxies"] as? [String: [String: Any]] {
                cur = all[homeGroup]?["now"] as? String ?? ""
                pick = all[autoGroup]?["now"] as? String ?? ""
                rows = ((all[homeGroup]?["all"] as? [String]) ?? []).map { NodeRow(id: $0, delay: nil) }
                if let cn = all[cnSites]?["now"] as? String { ab = cn == cnAuto }
            }
            DispatchQueue.main.async {
                self.running = on
                self.nodes = rows.map { NodeRow(id: $0.id, delay: self.delays[$0.id == autoGroup ? pick : $0.id]) }
                self.current = cur
                self.autoPick = pick
                self.abroad = ab
                self.busy = self.app?.busy ?? false
            }
        }
    }

    func refreshExit() {
        exitLine = "查询中…"
        DispatchQueue.global().async {
            let line = exitIPLine()
            DispatchQueue.main.async { self.exitLine = line }
        }
    }

    func pick(_ name: String) {
        DispatchQueue.global().async {
            selectNode(name)
            self.refresh()
            DispatchQueue.main.async { self.refreshExit() }
        }
    }

    func setAbroad(_ v: Bool) {
        DispatchQueue.global().async {
            applyMode(abroad: v)
            self.refresh()
            DispatchQueue.main.async { self.refreshExit() }
        }
    }

    // test every node once (in parallel); 0 / missing = failed
    func measure() {
        guard running || vpnRunning() else { return }
        retesting = true
        DispatchQueue.global().async {
            let names = ((clash("GET", "/proxies/" + enc(homeGroup))?["all"] as? [String]) ?? []).filter { $0 != "direct" && $0 != autoGroup }
            let u = testURL.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
            var got: [String: Int] = [:]
            let lock = NSLock(), g = DispatchGroup()
            for n in names {
                DispatchQueue.global().async(group: g) {
                    let d = clash("GET", "/proxies/\(enc(n))/delay?url=\(u)&timeout=5000", wait: 6)?["delay"] as? Int ?? 0
                    lock.lock(); if d > 0 { got[n] = d }; lock.unlock()
                }
            }
            g.wait()
            DispatchQueue.main.async { self.delays = got; self.retesting = false; self.refresh() }
        }
    }

    func retest() {
        retesting = true
        DispatchQueue.global().async {
            retestAutoGroup("panel")
            DispatchQueue.main.async { self.measure() }
        }
    }

    func toggle() {
        app?.toggleVPN()
        busy = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.refresh() }
    }

    func setExpiry(_ name: String, _ value: String) {
        savingExpiry = true
        DispatchQueue.global().async {
            let (code, data, err) = run("/usr/bin/ssh", ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", serverSSH,
                                                         "\(serverRepo)/server/users.sh expire \(name) \(value)"])
            let out = (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            log("expire \(name) \(value): \(code) \(out) \(err)")
            DispatchQueue.main.async {
                self.savingExpiry = false
                if code != 0 {
                    let a = NSAlert()
                    a.messageText = "改到期日失败"
                    a.informativeText = [out, err].filter { !$0.isEmpty }.joined(separator: "\n")
                    a.runModal()
                }
                self.loadUsage()
            }
        }
    }

    // server/sub.py url|reset <name>: prints the link (url creates one when the user has none yet)
    func subscription(_ name: String, reset: Bool = false, then: ((String) -> Void)? = nil) {
        if !reset, let u = subURL[name] { then?(u); return }
        subBusy = name
        DispatchQueue.global().async {
            let (code, data, err) = run("/usr/bin/ssh", ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", serverSSH,
                                                         "/usr/bin/python3 \(serverRepo)/server/sub.py \(reset ? "reset" : "url") \(name)"])
            let out = (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let link = out.split(separator: "\n").last.map(String.init) ?? ""
            log("sub \(reset ? "reset" : "url") \(name): \(code) \(err)")
            DispatchQueue.main.async {
                self.subBusy = ""
                if code == 0, link.hasPrefix("https://") {
                    self.subURL[name] = link
                    then?(link)
                    if reset { self.loadUsage() }
                } else {
                    let a = NSAlert()
                    a.messageText = "拿不到订阅链接"
                    a.informativeText = [out, err].filter { !$0.isEmpty }.joined(separator: "\n")
                    a.runModal()
                }
            }
        }
    }

    func loadUsage() {
        loadingUsage = true
        usageError = ""
        let h = hours
        DispatchQueue.global().async {
            let (code, data, err) = run("/usr/bin/ssh", ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", serverSSH,
                                                         "/usr/bin/python3 \(serverRepo)/server/audit.py --json --hours \(h)"])
            var u: Usage? = nil, e = ""
            if code == 0 {
                do { u = try JSONDecoder().decode(Usage.self, from: data) } catch { e = "服务器返回的数据看不懂：\(error)" }
            } else {
                e = "连不上服务器（ssh \(serverSSH)）：\(err.isEmpty ? "退出码 \(code)" : err)\n只有能 ssh 到服务器的电脑（管理员）才能看用户情况。"
            }
            DispatchQueue.main.async {
                if let u = u { self.usage = u }
                self.usageError = e
                self.loadingUsage = false
            }
        }
    }
}

struct StatusTab: View {
    @ObservedObject var m: PanelModel
    var body: some View {
        Form {
            Section {
                HStack {
                    Image(systemName: m.running ? "checkmark.shield.fill" : "shield.slash")
                        .foregroundColor(m.running ? .green : .orange)
                    Text(m.running ? "VPN 已连接" : "VPN 未连接（直连，中国 IP）").font(.headline)
                    Spacer()
                    Button(m.busy ? "处理中…" : (m.running ? "断开" : "连接")) { m.toggle() }.disabled(m.busy)
                }
                HStack {
                    Text("出口 IP")
                    Spacer()
                    Text(m.exitLine).foregroundColor(.secondary).textSelection(.enabled)
                    Button { m.refreshExit() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless)
                }
            }
            if m.running {
                Section {
                    ForEach(m.nodes) { n in
                        HStack {
                            Image(systemName: n.id == m.current ? "largecircle.fill.circle" : "circle")
                                .foregroundColor(n.id == m.current ? .accentColor : .secondary)
                            Text(n.id == autoGroup && !m.autoPick.isEmpty ? "\(n.id) → \(m.autoPick)" : n.id)
                            Spacer()
                            Text(n.delay.map { "\($0) ms" } ?? (n.id == "direct" || m.retesting ? "" : "不通"))
                                .foregroundColor(n.delay == nil ? .secondary : (n.delay! < 300 ? .green : .orange))
                                .monospacedDigit()
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { m.pick(n.id) }
                    }
                } header: {
                    HStack {
                        Text("节点（Home 和 Claude 一起切）")
                        Spacer()
                        Button(m.retesting ? "测速中…" : "立即重测") { m.retest() }.disabled(m.retesting)
                    }
                }
                if let ab = m.abroad {
                    Section("模式") {
                        Picker("", selection: Binding(get: { ab }, set: { m.setAbroad($0) })) {
                            Text("在国内").tag(false)
                            Text("在国外·回国").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        Text(ab ? "国内网站走国内家里的台式机，其余直连。Claude 始终走\(exitName)。"
                                : "国内网站直连，其余走\(exitName)。")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct UsersTab: View {
    @ObservedObject var m: PanelModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("", selection: $m.hours) {
                    Text("24 小时").tag(24)
                    Text("7 天").tag(168)
                    Text("30 天").tag(720)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 240)
                .onChange(of: m.hours) { _ in m.loadUsage() }   // one-parameter form: still runs on macOS 13
                Spacer()
                if m.loadingUsage { ProgressView().controlSize(.small) }
                else if let u = m.usage { Text("更新于 \(String(u.generated.suffix(8)))").font(.caption).foregroundColor(.secondary) }
                Button { m.loadUsage() } label: { Image(systemName: "arrow.clockwise") }.disabled(m.loadingUsage)
            }
            if !m.usageError.isEmpty {
                Text(m.usageError).font(.caption).foregroundColor(.orange).textSelection(.enabled)
            }
            if let u = m.usage {
                let active = u.users.filter { $0.conns > 0 }
                Text("\(u.users.count) 个账号，\(active.count) 个在用，现在在线 \(u.users.reduce(0) { $0 + $1.online }) 台设备")
                    .font(.subheadline)
                List {
                    ForEach(u.users) { user in UserRow(user: user, m: m) }
                }
                .listStyle(.inset)
            } else if m.loadingUsage {
                Spacer(); HStack { Spacer(); Text("正在从服务器读日志…").foregroundColor(.secondary); Spacer() }; Spacer()
            } else {
                Spacer()
            }
            Text("在线 = 10 分钟内有流量（测速不算）；一台 HY2 客户端算一台，同一个宽带后面的几台分得开；同一台电脑的 v4 和 v6 线路会分成两处。IPv6 按 /64 合并（手机会换地址）。")
                .font(.caption2).foregroundColor(.secondary)
        }
        .padding(12)
    }
}

struct UserRow: View {
    let user: UserUsage
    var m: PanelModel
    @State var open: Bool
    @State var picking = false
    @State var date = Date().addingTimeInterval(30 * 86400)
    init(user: UserUsage, m: PanelModel) { self.user = user; self.m = m; _open = State(initialValue: user.online > 0) }
    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(user.sources) { s in
                    HStack(alignment: .firstTextBaseline) {
                        Circle().fill(s.devices > 0 ? Color.green : Color.secondary.opacity(0.4)).frame(width: 7, height: 7)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(s.net == "?" ? "ShadowTLS 线路（日志里看不到来源 IP）" : s.net).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            Text(s.where.isEmpty ? (s.net == "?" ? "" : "归属地查不到") : s.where).font(.caption2).foregroundColor(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(s.devices > 0 ? "在线 \(s.devices) 台" : ago(s.idle)).font(.caption)
                                .foregroundColor(s.devices > 0 ? .green : .secondary)
                            Text("\(s.conns) 次连接").font(.caption2).foregroundColor(.secondary)
                        }
                    }
                }
                if !user.top.isEmpty {
                    Text("常去：" + user.top.map { $0.map(\.text).joined(separator: " ×") }.joined(separator: "，"))
                        .font(.caption2).foregroundColor(.secondary).lineLimit(3)
                }
                subRow
                if user.blocked > 0 {
                    Text("被拦截 \(user.blocked) 次（25 端口 / BT）").font(.caption2).foregroundColor(.orange)
                }
            }
            .padding(.leading, 4)
        } label: {
            HStack {
                Text(user.name).font(.body.weight(.medium))
                if user.shared { tag("共用", .blue) }
                else { expiryMenu }
                Spacer()
                if user.online > 0 {
                    Text("在线 \(user.online) 台").foregroundColor(.green)
                } else if let l = user.sources.first {
                    Text("最近 \(ago(l.idle))").foregroundColor(.secondary)
                } else {
                    Text("这段时间没用").foregroundColor(.secondary)
                }
                Text("\(user.sources.count) 处 · \(user.conns) 次").foregroundColor(.secondary).monospacedDigit()
                    .frame(minWidth: 110, alignment: .trailing)
            }
        }
    }
    @State var qr: String? = nil
    @State var confirmReset = false

    // subscription link: the user opens it on the phone (install page with one-tap import for Shadowrocket / sing-box)
    var subRow: some View {
        HStack(spacing: 8) {
            Text("订阅").font(.caption).foregroundColor(.secondary)
            if m.subBusy == user.name {
                ProgressView().controlSize(.small)
            } else if user.sub == true || m.subURL[user.name] != nil {
                Button("复制链接") {
                    m.subscription(user.name) { link in
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(link, forType: .string)
                    }
                }
                Button("二维码") { m.subscription(user.name) { qr = $0 } }
                Button("换新链接…") { confirmReset = true }
            } else {
                Button("生成订阅链接") { m.subscription(user.name) { qr = $0 } }
            }
            Spacer()
        }
        .controlSize(.small)
        .popover(isPresented: Binding(get: { qr != nil }, set: { if !$0 { qr = nil } })) {
            VStack(spacing: 8) {
                if let q = qr, let img = qrImage(q) {
                    Image(nsImage: img).interpolation(.none).resizable().frame(width: 240, height: 240)
                    Text("\(user.name) 用手机相机扫一下，打开的页面里一键导入").font(.caption)
                    Text(q).font(.system(.caption2, design: .monospaced)).textSelection(.enabled).frame(width: 260)
                }
            }
            .padding(14)
        }
        .alert("给 \(user.name) 换新订阅链接？", isPresented: $confirmReset) {
            Button("换新链接", role: .destructive) { m.subscription(user.name, reset: true) { qr = $0 } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("旧链接立刻失效（已经导入的 App 下次更新订阅会失败），要把新链接再发给对方。账号密码不变，正在用的连接不会断。")
        }
    }

    func qrImage(_ s: String) -> NSImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(s.utf8)
        f.correctionLevel = "M"
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)) else { return nil }
        let rep = NSCIImageRep(ciImage: out)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        return img
    }

    // click the tag to change when the account stops working (server/users.sh expire; no restart needed)
    var expiryMenu: some View {
        let left = user.expires.flatMap { e -> Int? in
            guard let d = ISO8601DateFormatter.day.date(from: e) else { return nil }
            return Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: Date()), to: d).day
        }
        let text = user.expires.map { e in "到期 \(e)" + (left.map { $0 <= 0 ? "（今天最后一天）" : "（还剩 \($0) 天）" } ?? "") } ?? "永不到期"
        return Menu {
            Section("从今天起") {
                ForEach([(7, "7 天"), (30, "30 天"), (90, "90 天"), (365, "1 年")], id: \.0) { d in
                    Button(d.1) { m.setExpiry(user.name, "\(d.0)") }
                }
            }
            Button("选日期…") { picking = true }
            Divider()
            Button("永不到期") { m.setExpiry(user.name, "never") }
        } label: {
            Text(text).font(.caption).foregroundColor((left ?? 99) <= 3 ? .orange : .secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(m.savingExpiry)
        .popover(isPresented: $picking) {
            VStack(alignment: .trailing, spacing: 8) {
                DatePicker("", selection: $date, in: Date()..., displayedComponents: .date)
                    .datePickerStyle(.graphical).labelsHidden()
                HStack {
                    Text("当天还能用，第二天 04:00 停用").font(.caption).foregroundColor(.secondary)
                    Spacer()
                    Button("取消") { picking = false }
                    Button("设为到期日") {
                        picking = false
                        m.setExpiry(user.name, ISO8601DateFormatter.day.string(from: date))
                    }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(12).frame(width: 300)
        }
    }

    func tag(_ t: String, _ c: Color) -> some View {
        Text(t).font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(c.opacity(0.15))).foregroundColor(c)
    }
}

struct PanelView: View {
    @ObservedObject var m: PanelModel
    var body: some View {
        TabView(selection: $m.tab) {
            StatusTab(m: m).tabItem { Text("状态") }.tag("status")
            if !serverSSH.isEmpty {   // owner only: the users page reads the server over ssh
                UsersTab(m: m).tabItem { Text("用户") }.tag("users")
            }
        }
        .padding(.top, 6)
        .frame(minWidth: 560, minHeight: 460)
        .onAppear { m.start() }
        .onDisappear { m.stop() }
    }
}

final class PanelWindow: NSObject, NSWindowDelegate {
    let model = PanelModel()
    var window: NSWindow?

    func show(app: App, tab: String? = nil) {
        model.app = app
        if let t = tab { model.tab = t }
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 520),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = userEdition ? brand : "VPN 设置"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: PanelView(m: model))
            w.center()
            w.setFrameAutosaveName("vpn-panel")
            w.delegate = self
            window = w
        } else {
            model.start()
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ n: Notification) { model.stop() }
}
