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
    case rateLimited(TimeInterval?)
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
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        guard let data, (200..<300).contains(status) else {
            if status == 401 || status == 403 {
                completion(.noAuth("Not authorized (HTTP \(status)) \u{2014} run `claude`"))
            } else if status == 429 {
                let retry = (http?.value(forHTTPHeaderField: "Retry-After")).flatMap(TimeInterval.init)
                completion(.rateLimited(retry))
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

// MARK: - GitHub contributions

struct ContribDay {
    var date: Date
    var count: Int
    var level: Int
}

struct Contributions {
    var user: String
    var days: [ContribDay]          // ascending by date, ~one year
    var fetchedAt: Date

    var total: Int { days.reduce(0) { $0 + $1.count } }
    var today: ContribDay? { days.last }

    /// Consecutive days ending today that have at least one contribution. A day
    /// with nothing on it yet doesn't break a streak that's still live, so today
    /// is allowed to be empty; any earlier gap ends the count.
    var streak: Int {
        var n = 0
        for (i, d) in days.enumerated().reversed() {
            if d.count > 0 { n += 1; continue }
            if i == days.count - 1 { continue }
            break
        }
        return n
    }
}

func attrValue(_ tag: String, _ name: String) -> String? {
    guard let r = tag.range(of: "\(name)=\"") else { return nil }
    let rest = tag[r.upperBound...]
    guard let end = rest.firstIndex(of: "\"") else { return nil }
    return String(rest[..<end])
}

/// Parses dates as noon local time. GitHub reports plain calendar dates, and
/// noon keeps the weekday stable across DST shifts.
func contribDate(_ s: String) -> Date? {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.timeZone = .current
    guard let d = f.date(from: s) else { return nil }
    return Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: d) ?? d
}

/// Scrapes the public contributions calendar. This is the same fragment the
/// profile page loads, needs no token, and only works for public activity.
func parseContributions(_ html: String, user: String) -> Contributions? {
    let ns = html as NSString
    let full = NSRange(location: 0, length: ns.length)

    // Tooltips carry the counts, keyed to each cell's id.
    var counts: [String: Int] = [:]
    let tipRe = try? NSRegularExpression(
        pattern: "for=\"(contribution-day-component-[^\"]+)\"[^>]*>([^<]*)</tool-tip>")
    tipRe?.enumerateMatches(in: html, range: full) { m, _, _ in
        guard let m, m.numberOfRanges == 3 else { return }
        let id = ns.substring(with: m.range(at: 1))
        let text = ns.substring(with: m.range(at: 2))
        let digits = text.prefix { $0.isNumber || $0 == "," }
            .replacingOccurrences(of: ",", with: "")
        counts[id] = Int(digits) ?? 0
    }

    var days: [ContribDay] = []
    let tdRe = try? NSRegularExpression(pattern: "<td\\b[^>]*>")
    tdRe?.enumerateMatches(in: html, range: full) { m, _, _ in
        guard let m else { return }
        let tag = ns.substring(with: m.range)
        guard tag.contains("ContributionCalendar-day"),
              let dateStr = attrValue(tag, "data-date"),
              let date = contribDate(dateStr) else { return }
        let level = Int(attrValue(tag, "data-level") ?? "0") ?? 0
        let count = attrValue(tag, "id").flatMap { counts[$0] } ?? 0
        days.append(ContribDay(date: date, count: count, level: level))
    }

    guard !days.isEmpty else { return nil }
    days.sort { $0.date < $1.date }
    return Contributions(user: user, days: days, fetchedAt: Date())
}

enum ContribResult {
    case ok(Contributions)
    case failed(String)
}

func fetchContributions(user: String, completion: @escaping (ContribResult) -> Void) {
    let escaped = user.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? user
    guard let url = URL(string: "https://github.com/users/\(escaped)/contributions") else {
        completion(.failed("Bad username"))
        return
    }
    var req = URLRequest(url: url)
    req.timeoutInterval = 15
    req.setValue("ClaudeUsageBar", forHTTPHeaderField: "User-Agent")

    URLSession.shared.dataTask(with: req) { data, response, error in
        if let error {
            completion(.failed(error.localizedDescription))
            return
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard let data, (200..<300).contains(status) else {
            completion(.failed(status == 404 ? "No such GitHub user" : "HTTP \(status)"))
            return
        }
        guard let html = String(data: data, encoding: .utf8),
              let contribs = parseContributions(html, user: user) else {
            completion(.failed("Couldn't read the contribution graph"))
            return
        }
        completion(.ok(contribs))
    }.resume()
}

/// Best guess at the user's GitHub handle so the heatmap works without setup:
/// the `gh` CLI's stored host config first, then a git config fallback.
func detectGitHubUser() -> String? {
    let hosts = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/gh/hosts.yml")
    if let text = try? String(contentsOf: hosts, encoding: .utf8) {
        for line in text.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("user:") {
                let name = t.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { return name }
            }
        }
    }
    let cfg = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".gitconfig")
    if let text = try? String(contentsOf: cfg, encoding: .utf8) {
        for line in text.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("user =") || t.hasPrefix("user=") {
                let name = t.drop { $0 != "=" }.dropFirst()
                    .trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { return name }
            }
        }
    }
    return nil
}

// MARK: - Heatmap view

/// The familiar 53x7 calendar: weeks run left to right, weekdays top to bottom.
final class HeatmapView: NSView {
    private let cell: CGFloat = 7
    private let gap: CGFloat = 2
    private let leftInset: CGFloat = 24
    private let topInset: CGFloat = 12
    private let padding: CGFloat = 14

    private var pitch: CGFloat { cell + gap }
    private var days: [ContribDay] = []
    private var columns = 53
    /// Days keyed by their offset from the grid's first cell, so drawing is a
    /// lookup per cell instead of a scan of the whole year.
    private var byOffset: [Int: ContribDay] = [:]
    private var origin = Date()

    init(days: [ContribDay]) {
        self.days = days
        let cal = Calendar.current
        if let first = days.first, let last = days.last {
            origin = cal.dateInterval(of: .weekOfYear, for: first.date)?.start ?? first.date
            let b = cal.dateInterval(of: .weekOfYear, for: last.date)?.start ?? last.date
            let weeks = cal.dateComponents([.weekOfYear], from: origin, to: b).weekOfYear ?? 52
            columns = max(1, weeks + 1)
            for d in days {
                let start = cal.startOfDay(for: d.date)
                if let off = cal.dateComponents([.day], from: cal.startOfDay(for: origin), to: start).day {
                    byOffset[off] = d
                }
            }
        }
        super.init(frame: .zero)
        let w = leftInset + CGFloat(columns) * pitch - gap + padding
        let h = topInset + 7 * pitch - gap + 8
        setFrameSize(NSSize(width: w, height: h))
    }

    required init?(coder: NSCoder) { fatalError() }

    private func palette(_ dark: Bool) -> [NSColor] {
        func hex(_ v: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                    green: CGFloat((v >> 8) & 0xFF) / 255,
                    blue: CGFloat(v & 0xFF) / 255, alpha: 1)
        }
        // GitHub's own scales, with a lifted empty cell so it stays visible on
        // the translucent menu background.
        return dark
            ? [NSColor(white: 1, alpha: 0.10), hex(0x0E4429), hex(0x006D32), hex(0x26A641), hex(0x39D353)]
            : [NSColor(white: 0, alpha: 0.08), hex(0x9BE9A8), hex(0x40C463), hex(0x30A14E), hex(0x216E39)]
    }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let colors = palette(dark)
        let cal = Calendar.current

        guard !days.isEmpty else { return }

        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]

        // Weekday gutter - Mon/Wed/Fri only, like the profile page.
        let symbols = cal.veryShortStandaloneWeekdaySymbols
        for row in [1, 3, 5] {
            let idx = (cal.firstWeekday - 1 + row) % 7
            let y = bounds.height - topInset - CGFloat(row) * pitch - cell
            (symbols[idx] as NSString).draw(at: NSPoint(x: 6, y: y - 1), withAttributes: labelAttrs)
        }

        var lastMonth = -1
        for col in 0..<columns {
            guard let weekStart = cal.date(byAdding: .weekOfYear, value: col, to: origin) else { continue }
            let x = leftInset + CGFloat(col) * pitch

            // Month label on the first column that lands in a new month.
            let month = cal.component(.month, from: weekStart)
            if month != lastMonth, cal.component(.day, from: weekStart) <= 7 {
                lastMonth = month
                let name = cal.shortStandaloneMonthSymbols[month - 1]
                (name as NSString).draw(at: NSPoint(x: x, y: bounds.height - topInset + 1),
                                        withAttributes: labelAttrs)
            }

            for row in 0..<7 {
                // Cells before the first day or after today have no entry and
                // aren't drawn at all, so the grid ends where the year does.
                guard let day = byOffset[col * 7 + row] else { continue }

                let y = bounds.height - topInset - CGFloat(row) * pitch - cell
                let rect = NSRect(x: x, y: y, width: cell, height: cell)
                let level = min(4, max(0, day.level))
                colors[level].setFill()
                NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5).fill()
            }
        }
    }
}

// MARK: - App

let kShowWeekly = "showWeeklyInMenuBar"
let kShowHeatmap = "showGitHubHeatmap"
let kGitHubUser = "gitHubUser"

final class Controller: NSObject, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var state: FetchState = .loading
    /// Last successful reading. Kept so a transient failure shows stale numbers
    /// rather than blanking the menu bar.
    var lastGood: Snapshot?
    var backoff: TimeInterval = 0
    var nextAllowedFetch: Date?
    var inFlight = false
    var timer: Timer?
    var tickTimer: Timer?

    var contribs: Contributions?
    var contribError: String?
    var contribInFlight = false
    var nextContribFetch: Date?

    override init() {
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        item.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)

        render()
        refresh()
        refreshContribs()

        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            // Fires often, but refresh() itself enforces the real interval and
            // any rate-limit backoff, so this is just a cheap heartbeat.
            self?.refresh()
            self?.refreshContribs()
        }
        // Keep the "resets in" countdown honest between fetches.
        tickTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.render()
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.refresh() }
    }

    /// Usage windows are 5 hours and 7 days wide, so polling fast buys nothing
    /// and risks a 429 from the endpoint. The countdown is recomputed locally by
    /// tickTimer, which needs no network at all.
    static let normalInterval: TimeInterval = 300      // 5 minutes
    static let minBackoff: TimeInterval = 600          // after a 429
    static let maxBackoff: TimeInterval = 3600

    func refresh(force: Bool = false) {
        if inFlight { return }
        if !force, let next = nextAllowedFetch, Date() < next { return }

        inFlight = true
        fetchUsage { [weak self] newState in
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlight = false

                switch newState {
                case .ok(let snap):
                    self.lastGood = snap
                    self.backoff = 0
                    self.nextAllowedFetch = Date().addingTimeInterval(Self.normalInterval)
                case .rateLimited(let retryAfter):
                    // Grow the wait each time we're told to slow down.
                    self.backoff = self.backoff == 0
                        ? Self.minBackoff
                        : min(self.backoff * 2, Self.maxBackoff)
                    let wait = max(retryAfter ?? 0, self.backoff)
                    self.nextAllowedFetch = Date().addingTimeInterval(wait)
                default:
                    self.nextAllowedFetch = Date().addingTimeInterval(Self.normalInterval)
                }

                self.state = newState
                self.render()
            }
        }
    }

    // MARK: GitHub

    /// The contribution graph only changes when you push, so a slow poll is
    /// plenty - and it keeps the scrape well clear of anything GitHub would
    /// consider abusive.
    static let contribInterval: TimeInterval = 900     // 15 minutes

    var gitHubUser: String? {
        if let saved = UserDefaults.standard.string(forKey: kGitHubUser), !saved.isEmpty {
            return saved
        }
        return nil
    }

    func refreshContribs(force: Bool = false) {
        guard UserDefaults.standard.bool(forKey: kShowHeatmap), let user = gitHubUser else { return }
        if contribInFlight { return }
        if !force, contribs?.user == user, let next = nextContribFetch, Date() < next { return }

        contribInFlight = true
        fetchContributions(user: user) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.contribInFlight = false
                self.nextContribFetch = Date().addingTimeInterval(Self.contribInterval)
                switch result {
                case .ok(let c):
                    self.contribs = c
                    self.contribError = nil
                case .failed(let msg):
                    // Keep the last graph on screen; note the problem instead.
                    self.contribError = msg
                }
            }
        }
    }

    // MARK: Menu bar title

    func render() {
        guard let button = item.button else { return }
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)

        // A failed refresh must not wipe numbers we already have: keep showing the
        // last good reading, just dimmed, so a transient 429 or dropped network
        // doesn't blank the menu bar.
        var stale = false
        switch state {
        case .ok:
            break
        case .noAuth:
            button.attributedTitle = NSAttributedString(
                string: "\u{26A0}\u{FE0E} auth",
                attributes: [.font: font, .foregroundColor: NSColor.systemOrange])
            return
        case .loading, .failed, .rateLimited:
            if lastGood == nil {
                let mark = { if case .loading = state { return "\u{2026}" } else { return "\u{2014}" } }()
                button.attributedTitle = NSAttributedString(
                    string: mark,
                    attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])
                return
            }
            stale = true
        }

        if let snap = lastGood {
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
                    attributes: [.font: font,
                                 .foregroundColor: stale ? NSColor.tertiaryLabelColor
                                                         : tintFor(s.percent)]))

                if showWeekly, let w = snap.weeklyPeak {
                    let wTint = stale ? NSColor.tertiaryLabelColor
                        : (w.percent >= 80 ? tintFor(w.percent) : NSColor.secondaryLabelColor)
                    title.append(NSAttributedString(
                        string: " \(Int(w.percent.rounded()))%",
                        attributes: [.font: small, .foregroundColor: wTint]))
                } else if let r = s.resetsAt {
                    title.append(NSAttributedString(
                        string: " \u{00B7} \(countdown(to: r))",
                        attributes: [.font: font,
                                     .foregroundColor: stale ? NSColor.tertiaryLabelColor
                                                             : tintFor(s.percent)]))
                }
            } else if let w = snap.weeklyPeak {
                title.append(NSAttributedString(
                    string: "7d \(Int(w.percent.rounded()))%",
                    attributes: [.font: font,
                                 .foregroundColor: stale ? NSColor.tertiaryLabelColor
                                                         : tintFor(w.percent)]))
            }

            button.attributedTitle = title
        }
    }

    // MARK: Dropdown

    func menuWillOpen(_ menu: NSMenu) {
        if let s = lastGood, Date().timeIntervalSince(s.fetchedAt) > Self.normalInterval {
            refresh()
        } else if lastGood == nil {
            refresh()
        }
        refreshContribs()
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

    private func addHeatmap(to menu: NSMenu) {
        guard let user = gitHubUser else {
            let mi = NSMenuItem(title: "Set GitHub Username\u{2026}",
                                action: #selector(setGitHubUser), keyEquivalent: "")
            mi.target = self
            menu.addItem(mi)
            return
        }

        menu.addItem(info("GitHub \u{00B7} @\(user)"))

        if let c = contribs, !c.days.isEmpty {
            let view = HeatmapView(days: c.days)
            let mi = NSMenuItem()
            mi.view = view
            menu.addItem(mi)

            let nf = NumberFormatter()
            nf.numberStyle = .decimal
            let total = nf.string(from: NSNumber(value: c.total)) ?? "\(c.total)"
            var line = "\(total) contributions in the last year"
            if c.streak > 0 { line += " \u{00B7} \(c.streak) day streak" }
            if let t = c.today, t.count > 0 { line += " \u{00B7} \(t.count) today" }
            menu.addItem(info(line))
        } else if contribError == nil {
            menu.addItem(info("Loading contributions\u{2026}"))
        }

        if let err = contribError {
            menu.addItem(info("Couldn't load contributions: \(err)"))
        }
    }

    func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()

        // Always show the last good reading if we have one, with the current
        // problem (if any) noted underneath rather than replacing it.
        if let snap = lastGood {
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

        if UserDefaults.standard.bool(forKey: kShowHeatmap) {
            menu.addItem(.separator())
            addHeatmap(to: menu)
        }

        switch state {
        case .ok:
            break
        case .loading:
            if lastGood == nil { menu.addItem(info("Loading\u{2026}")) }
        case .noAuth(let msg):
            menu.addItem(info(msg))
        case .failed(let msg):
            menu.addItem(info("Couldn't refresh: \(msg)"))
        case .rateLimited:
            var line = "Rate limited by the API"
            if let next = nextAllowedFetch, next > Date() {
                line += " \u{2014} retrying in \(countdown(to: next))"
            }
            menu.addItem(info(line))
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

        let heat = NSMenuItem(title: "Show GitHub Heatmap",
                              action: #selector(toggleHeatmap), keyEquivalent: "")
        heat.target = self
        heat.state = UserDefaults.standard.bool(forKey: kShowHeatmap) ? .on : .off
        menu.addItem(heat)

        if UserDefaults.standard.bool(forKey: kShowHeatmap), gitHubUser != nil {
            let ghUser = NSMenuItem(title: "GitHub Username\u{2026}",
                                    action: #selector(setGitHubUser), keyEquivalent: "")
            ghUser.target = self
            menu.addItem(ghUser)
        }

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

    @objc func doRefresh() {
        refresh(force: true)
        refreshContribs(force: true)
    }

    @objc func toggleHeatmap() {
        let d = UserDefaults.standard
        let on = !d.bool(forKey: kShowHeatmap)
        d.set(on, forKey: kShowHeatmap)
        if on { refreshContribs(force: true) }
    }

    @objc func setGitHubUser() {
        let a = NSAlert()
        a.messageText = "GitHub Username"
        a.informativeText = "Whose contribution graph to show. Only public contributions are visible."
        a.addButton(withTitle: "Save")
        a.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.stringValue = gitHubUser ?? ""
        field.placeholderString = "octocat"
        a.accessoryView = field

        NSApp.activate(ignoringOtherApps: true)
        a.window.initialFirstResponder = field
        guard a.runModal() == .alertFirstButtonReturn else { return }

        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(name, forKey: kGitHubUser)
        contribs = nil
        contribError = nil
        nextContribFetch = nil
        refreshContribs(force: true)
    }

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
UserDefaults.standard.register(defaults: [kShowHeatmap: true])
// Seed the handle once from whatever the machine already knows, so the heatmap
// shows up without a setup step. After that it's whatever the user chose.
if UserDefaults.standard.string(forKey: kGitHubUser) == nil, let detected = detectGitHubUser() {
    UserDefaults.standard.set(detected, forKey: kGitHubUser)
}

if CommandLine.arguments.contains("--reset") {
    UserDefaults.standard.removeObject(forKey: kShowWeekly)
    UserDefaults.standard.removeObject(forKey: kShowHeatmap)
    UserDefaults.standard.removeObject(forKey: kGitHubUser)
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
        case .rateLimited(let retry):
            let extra = retry.map { " (retry after \(Int($0))s)" } ?? ""
            print("RATE LIMITED: HTTP 429\(extra)")
        case .loading: print("loading")
        }
        sem.signal()
    }
    _ = sem.wait(timeout: .now() + 20)

    if let user = UserDefaults.standard.string(forKey: kGitHubUser), !user.isEmpty {
        let ghSem = DispatchSemaphore(value: 0)
        fetchContributions(user: user) { result in
            switch result {
            case .ok(let c):
                let today = c.today.map { "\($0.count) today" } ?? "no data for today"
                print("GitHub @\(user): \(c.total) contributions in the last year, "
                      + "\(c.streak) day streak, \(today)")
            case .failed(let m):
                print("GitHub @\(user): \(m)")
            }
            ghSem.signal()
        }
        _ = ghSem.wait(timeout: .now() + 20)
    } else {
        print("GitHub: no username set")
    }
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = Controller()
app.run()
