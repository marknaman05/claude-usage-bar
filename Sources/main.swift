import AppKit
import Security
import ServiceManagement

// MARK: - Model

struct LimitEntry {
    var kind: String
    var group: String
    var percent: Double
    var severity: String
    var resetsAt: Date?
    var isActive: Bool

    var label: String {
        switch kind {
        case "session": return "Session (5h)"
        case "weekly_all": return "Weekly (all models)"
        case "weekly_opus": return "Weekly (Opus)"
        case "weekly_sonnet": return "Weekly (Sonnet)"
        default:
            return kind.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

struct Snapshot {
    var limits: [LimitEntry]
    var creditsUsed: String?
    var fetchedAt: Date

    var session: LimitEntry? { limits.first { $0.group == "session" } }
    var weeklyPeak: LimitEntry? {
        limits.filter { $0.group == "weekly" }.max { $0.percent < $1.percent }
    }
}

enum FetchState {
    case loading
    case ok(Snapshot)
    case noAuth(String)
    case failed(String)
}

// MARK: - Formatting

func isoDate(_ s: String?) -> Date? {
    guard let s, !s.isEmpty else { return nil }
    let f1 = ISO8601DateFormatter()
    f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f1.date(from: s) { return d }
    let f2 = ISO8601DateFormatter()
    f2.formatOptions = [.withInternetDateTime]
    if let d = f2.date(from: s) { return d }
    // Fall back: strip a fractional-seconds component of any length.
    if let dot = s.firstIndex(of: "."),
       let tz = s[dot...].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) {
        var t = s
        t.removeSubrange(dot..<tz)
        return f2.date(from: t)
    }
    return nil
}

/// "2h 13m", "47m", "1d 3h", "now"
func countdown(to date: Date) -> String {
    let secs = Int(date.timeIntervalSinceNow)
    if secs <= 0 { return "now" }
    let m = secs / 60, h = m / 60, d = h / 24
    if d >= 1 { return "\(d)d \(h % 24)h" }
    if h >= 1 { return "\(h)h \(m % 60)m" }
    if m >= 1 { return "\(m)m" }
    return "<1m"
}

func clockTime(_ date: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "EEE HH:mm"
    return f.string(from: date)
}

func bar(_ pct: Double, width: Int = 14) -> String {
    let filled = max(0, min(width, Int((pct / 100.0 * Double(width)).rounded())))
    return String(repeating: "\u{2588}", count: filled)
         + String(repeating: "\u{2591}", count: width - filled)
}

func tintFor(_ pct: Double) -> NSColor {
    if pct >= 95 { return .systemRed }
    if pct >= 80 { return .systemOrange }
    return .labelColor
}

// MARK: - Credentials

struct Credentials {
    var token: String
    var expiresAt: Date?
    var isExpired: Bool {
        guard let expiresAt else { return false }
        return expiresAt <= Date()
    }
}

func readCredentials() -> Credentials? {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "Claude Code-credentials",
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
          let data = item as? Data,
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }

    let oauth = (root["claudeAiOauth"] as? [String: Any]) ?? root
    guard let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }

    var expires: Date?
    if let ms = oauth["expiresAt"] as? Double, ms > 0 {
        expires = Date(timeIntervalSince1970: ms / 1000.0)
    }
    return Credentials(token: token, expiresAt: expires)
}

// MARK: - API

func fetchUsage(completion: @escaping (FetchState) -> Void) {
    guard let creds = readCredentials() else {
        completion(.noAuth("No Claude Code credentials in Keychain"))
        return
    }
    if creds.isExpired {
        completion(.noAuth("Token expired \u{2014} run `claude` to refresh"))
        return
    }

    var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
    req.timeoutInterval = 15
    req.setValue("Bearer \(creds.token)", forHTTPHeaderField: "Authorization")
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

    URLSession.shared.dataTask(with: req) { data, response, error in
        if let error {
            completion(.failed(error.localizedDescription))
            return
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard let data, (200..<300).contains(status) else {
            if status == 401 || status == 403 {
                completion(.noAuth("Not authorized (HTTP \(status)) \u{2014} run `claude`"))
            } else {
                completion(.failed("HTTP \(status)"))
            }
            return
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            completion(.failed("Bad response"))
            return
        }
        completion(.ok(parse(json)))
    }.resume()
}

func parse(_ json: [String: Any]) -> Snapshot {
    var limits: [LimitEntry] = []

    if let raw = json["limits"] as? [[String: Any]] {
        for l in raw {
            guard let kind = l["kind"] as? String else { continue }
            limits.append(LimitEntry(
                kind: kind,
                group: (l["group"] as? String) ?? kind,
                percent: (l["percent"] as? NSNumber)?.doubleValue ?? 0,
                severity: (l["severity"] as? String) ?? "normal",
                resetsAt: isoDate(l["resets_at"] as? String),
                isActive: (l["is_active"] as? Bool) ?? true
            ))
        }
    }

    // Fallback for older payloads that only carry the named buckets.
    if limits.isEmpty {
        let named: [(String, String, String)] = [
            ("five_hour", "session", "session"),
            ("seven_day", "weekly_all", "weekly"),
            ("seven_day_opus", "weekly_opus", "weekly"),
            ("seven_day_sonnet", "weekly_sonnet", "weekly"),
        ]
        for (key, kind, group) in named {
            guard let b = json[key] as? [String: Any],
                  let util = (b["utilization"] as? NSNumber)?.doubleValue else { continue }
            limits.append(LimitEntry(
                kind: kind, group: group, percent: util,
                severity: "normal",
                resetsAt: isoDate(b["resets_at"] as? String),
                isActive: true
            ))
        }
    }

    // Session first, then weeklies by descending usage.
    limits.sort { a, b in
        if (a.group == "session") != (b.group == "session") { return a.group == "session" }
        return a.percent > b.percent
    }

    var credits: String?
    if let spend = json["spend"] as? [String: Any], (spend["enabled"] as? Bool) == true {
        if let used = spend["used"] as? [String: Any],
           let minor = (used["amount_minor"] as? NSNumber)?.doubleValue {
            let exp = (used["exponent"] as? NSNumber)?.intValue ?? 2
            let amount = minor / pow(10, Double(exp))
            let cur = (used["currency"] as? String) ?? "USD"
            let pct = (spend["percent"] as? NSNumber)?.doubleValue
            let base = String(format: "%.2f %@", amount, cur)
            credits = pct != nil ? "\(base) (\(Int(pct!))%)" : base
        }
    }

    return Snapshot(limits: limits, creditsUsed: credits, fetchedAt: Date())
}

// MARK: - App

let kShowWeekly = "showWeeklyInMenuBar"

final class Controller: NSObject, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var state: FetchState = .loading
    var timer: Timer?
    var tickTimer: Timer?

    override init() {
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        item.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)

        render()
        refresh()

        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        // Keep the "resets in" countdown honest between fetches.
        tickTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.render()
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.refresh() }
    }

    func refresh() {
        fetchUsage { [weak self] newState in
            DispatchQueue.main.async {
                self?.state = newState
                self?.render()
            }
        }
    }

    // MARK: Menu bar title

    func render() {
        guard let button = item.button else { return }
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)

        switch state {
        case .loading:
            button.attributedTitle = NSAttributedString(
                string: "\u{2026}", attributes: [.font: font])
        case .noAuth:
            button.attributedTitle = NSAttributedString(
                string: "\u{26A0}\u{FE0E} auth",
                attributes: [.font: font, .foregroundColor: NSColor.systemOrange])
        case .failed:
            button.attributedTitle = NSAttributedString(
                string: "\u{2014}",
                attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])
        case .ok(let snap):
            // Menu bar space is scarce (a notched display leaves only the strip
            // right of the notch, and macOS silently hides items that no longer
            // fit). So the weekly reading *replaces* the countdown rather than
            // being appended to it - the title never grows.
            let small = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
            let showWeekly = UserDefaults.standard.bool(forKey: kShowWeekly)
            let title = NSMutableAttributedString()

            if let s = snap.session {
                title.append(NSAttributedString(
                    string: "\(Int(s.percent.rounded()))%",
                    attributes: [.font: font, .foregroundColor: tintFor(s.percent)]))

                if showWeekly, let w = snap.weeklyPeak {
                    let wTint = w.percent >= 80 ? tintFor(w.percent) : NSColor.secondaryLabelColor
                    title.append(NSAttributedString(
                        string: " \(Int(w.percent.rounded()))%",
                        attributes: [.font: small, .foregroundColor: wTint]))
                } else if let r = s.resetsAt {
                    title.append(NSAttributedString(
                        string: " \u{00B7} \(countdown(to: r))",
                        attributes: [.font: font, .foregroundColor: tintFor(s.percent)]))
                }
            } else if let w = snap.weeklyPeak {
                title.append(NSAttributedString(
                    string: "7d \(Int(w.percent.rounded()))%",
                    attributes: [.font: font, .foregroundColor: tintFor(w.percent)]))
            }

            button.attributedTitle = title
        }
    }

    // MARK: Dropdown

    func menuWillOpen(_ menu: NSMenu) {
        if case .ok(let s) = state, Date().timeIntervalSince(s.fetchedAt) > 20 { refresh() }
        rebuild(menu)
    }

    private func info(_ text: String) -> NSMenuItem {
        let mi = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        mi.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        mi.isEnabled = false
        return mi
    }

    private func limitItem(_ l: LimitEntry) -> NSMenuItem {
        let mi = NSMenuItem(title: l.label, action: nil, keyEquivalent: "")
        let pct = Int(l.percent.rounded())

        let line1 = NSMutableAttributedString(
            string: "\(l.label)\n",
            attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium),
                         .foregroundColor: NSColor.labelColor])

        let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let line2 = NSMutableAttributedString(
            string: bar(l.percent),
            attributes: [.font: mono, .foregroundColor: tintFor(l.percent)])
        line2.append(NSAttributedString(
            string: String(format: "  %3d%%", pct),
            attributes: [.font: mono, .foregroundColor: tintFor(l.percent)]))

        var tail = ""
        if let r = l.resetsAt {
            tail = "   resets \(clockTime(r)) \u{00B7} in \(countdown(to: r))"
        }
        if !tail.isEmpty {
            line2.append(NSAttributedString(
                string: tail,
                attributes: [.font: NSFont.systemFont(ofSize: 11),
                             .foregroundColor: NSColor.secondaryLabelColor]))
        }

        line1.append(line2)
        mi.attributedTitle = line1
        mi.isEnabled = false
        return mi
    }

    func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()

        switch state {
        case .loading:
            menu.addItem(info("Loading\u{2026}"))
        case .noAuth(let msg):
            menu.addItem(info(msg))
        case .failed(let msg):
            menu.addItem(info("Couldn't fetch usage: \(msg)"))
        case .ok(let snap):
            if snap.limits.isEmpty {
                menu.addItem(info("No limit data reported"))
            }
            for l in snap.limits {
                menu.addItem(limitItem(l))
            }
            if let c = snap.creditsUsed {
                menu.addItem(.separator())
                menu.addItem(info("Extra usage credits: \(c)"))
            }
            menu.addItem(.separator())
            menu.addItem(info("Updated \(clockTime(snap.fetchedAt))"))
        }

        menu.addItem(.separator())

        let r = NSMenuItem(title: "Refresh Now", action: #selector(doRefresh), keyEquivalent: "r")
        r.target = self
        menu.addItem(r)

        let weekly = NSMenuItem(title: "Show Weekly Instead of Countdown",
                                action: #selector(toggleWeekly), keyEquivalent: "")
        weekly.target = self
        weekly.state = UserDefaults.standard.bool(forKey: kShowWeekly) ? .on : .off
        menu.addItem(weekly)

        let login = NSMenuItem(title: "Launch at Login",
                               action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        let web = NSMenuItem(title: "Open Usage Settings\u{2026}",
                             action: #selector(openWeb), keyEquivalent: "")
        web.target = self
        menu.addItem(web)

        menu.addItem(.separator())
        let q = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)),
                           keyEquivalent: "q")
        menu.addItem(q)
    }

    @objc func doRefresh() { refresh() }

    @objc func toggleWeekly() {
        let d = UserDefaults.standard
        d.set(!d.bool(forKey: kShowWeekly), forKey: kShowWeekly)
        render()
    }

    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let a = NSAlert()
            a.messageText = "Couldn't change the Launch at Login setting"
            a.informativeText = error.localizedDescription
            a.runModal()
        }
    }

    @objc func openWeb() {
        NSWorkspace.shared.open(URL(string: "https://claude.ai/settings/usage")!)
    }
}

// `--probe` runs one fetch, prints the result, and exits. Useful for verifying
// Keychain access and the API path without the menu bar.
if CommandLine.arguments.contains("--reset") {
    UserDefaults.standard.removeObject(forKey: kShowWeekly)
    UserDefaults.standard.synchronize()
    print("Preferences reset. Relaunch the app.")
    exit(0)
}

if CommandLine.arguments.contains("--probe") {
    let sem = DispatchSemaphore(value: 0)
    fetchUsage { state in
        switch state {
        case .ok(let s):
            for l in s.limits {
                let reset = l.resetsAt.map { "resets \(clockTime($0)) (in \(countdown(to: $0)))" } ?? "no reset time"
                let name = l.label.padding(toLength: max(22, l.label.count), withPad: " ", startingAt: 0)
                print(String(format: "%@ %3d%%  %@", name, Int(l.percent.rounded()), reset))
            }
            if let c = s.creditsUsed { print("Extra usage credits: \(c)") }
        case .noAuth(let m): print("NO AUTH: \(m)")
        case .failed(let m): print("FAILED: \(m)")
        case .loading: print("loading")
        }
        sem.signal()
    }
    _ = sem.wait(timeout: .now() + 20)
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = Controller()
app.run()
