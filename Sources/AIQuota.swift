
import Cocoa

let DS_SERVICE        = "aiquota-deepseek"
let GROK_SERVICE      = "aiquota-grok"
let GROK_REFRESH_SVC  = "aiquota-grok-refresh"
let STATE_DB          = ProcessInfo.processInfo.environment["AIQUOTA_STATE_DB"]
                            ?? NSHomeDirectory() + "/.openclaw/state/openclaw.sqlite"
let SYNC_OPENCLAW     = ProcessInfo.processInfo.environment["AIQUOTA_SYNC_OPENCLAW"] != "0"
let REFRESH_SEC: TimeInterval = 60
let XAI_CLIENT_ID     = "b1a00492-073a-47ea-816f-4c329264a828"
let XAI_TOKEN_URL     = "https://auth.x.ai/oauth2/token"
let GROK_BILLING_URL  = "https://cli-chat-proxy.grok.com/v1/billing?format=credits"
let DS_BALANCE_URL    = "https://api.deepseek.com/user/balance"
let APP_SUPPORT       = NSHomeDirectory() + "/Library/Application Support/AIQuota"
let HISTORY_PATH      = APP_SUPPORT + "/history.json"

// MARK: - process / keychain / db

func runProcess(_ path: String, _ args: [String]) -> (Int32, Data) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = Pipe()
    do { try p.run() } catch { return (-1, Data()) }
    let d = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, d)
}

func keychainGet(_ service: String) -> String? {
    let (code, d) = runProcess("/usr/bin/security", ["find-generic-password", "-s", service, "-w"])
    guard code == 0, let s = String(data: d, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
    return s
}

func keychainSet(_ service: String, _ value: String) {
    _ = runProcess("/usr/bin/security", ["add-generic-password", "-U", "-s", service, "-a", "oleg", "-w", value])
}

func dbProfiles() -> [String: [String: Any]] {
    let (code, d) = runProcess("/usr/bin/sqlite3",
        ["-readonly", STATE_DB, "select value_json from config_machine_state where state_key='authProfiles.store'"])
    guard code == 0,
          let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
          let profiles = obj["profiles"] as? [String: [String: Any]] else { return [:] }
    return profiles
}

func dbGrokProfile() -> (id: String, access: String?, refresh: String?)? {
    for (id, p) in dbProfiles() where (p["provider"] as? String) == "xai" {
        return (id, p["access"] as? String, p["refresh"] as? String)
    }
    return nil
}

func dbGrokToken() -> String? { dbGrokProfile()?.access }

func dbDeepSeekKey() -> String? {
    for (_, p) in dbProfiles() where (p["provider"] as? String) == "deepseek" {
        if let k = p["key"] as? String, !k.isEmpty { return k }
    }
    return nil
}

func dbStoreGrok(access: String, refresh: String, expiresMs: Int) {
    guard SYNC_OPENCLAW, let prof = dbGrokProfile() else { return }
    let (_, d) = runProcess("/usr/bin/sqlite3",
        ["-readonly", STATE_DB, "select value_json from config_machine_state where state_key='authProfiles.store'"])
    guard var obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
          var profiles = obj["profiles"] as? [String: [String: Any]],
          var p = profiles[prof.id] else { return }
    p["access"] = access
    p["refresh"] = refresh
    p["expires"] = expiresMs
    profiles[prof.id] = p
    obj["profiles"] = profiles
    guard let out = try? JSONSerialization.data(withJSONObject: obj),
          let json = String(data: out, encoding: .utf8) else { return }
    let esc = json.replacingOccurrences(of: "'", with: "''")
    let now = Int(Date().timeIntervalSince1970 * 1000)
    let sql = "update config_machine_state set value_json='" + esc + "', updated_at_ms=" + String(now) + " where state_key='authProfiles.store';"
    let (code, _) = runProcess("/usr/bin/sqlite3", [STATE_DB, sql])
    logLine("token refresh written back status=" + String(code))
}

func logLine(_ s: String) {
    let p = NSHomeDirectory() + "/Library/Logs/AIQuota.log"
    if let attrs = try? FileManager.default.attributesOfItem(atPath: p),
       let size = attrs[.size] as? Int, size > 1_000_000 {
        try? FileManager.default.removeItem(atPath: p + ".1")
        try? FileManager.default.moveItem(atPath: p, toPath: p + ".1")
    }
    let line = ISO8601DateFormatter().string(from: Date()) + " " + s + "\n"
    if let h = FileHandle(forWritingAtPath: p) {
        h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
    } else {
        try? line.write(toFile: p, atomically: true, encoding: .utf8)
    }
}

let netSession: URLSession = {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.httpMaximumConnectionsPerHost = 1
    cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
    cfg.urlCache = nil
    cfg.httpCookieStorage = nil
    cfg.timeoutIntervalForRequest = 20
    return URLSession(configuration: cfg)
}()

func httpJSON(_ urlString: String, bearer: String, completion: @escaping (Int, Data?) -> Void) {
    guard let url = URL(string: urlString) else { completion(-1, nil); return }
    var req = URLRequest(url: url)
    req.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization")
    req.setValue("application/json", forHTTPHeaderField: "Accept")
    req.timeoutInterval = 20
    netSession.dataTask(with: req) { data, resp, _ in
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        DispatchQueue.main.async { completion(code, data) }
    }.resume()
}

func alphaBBox(_ cg: CGImage) -> CGRect? {
    let w = cg.width, h = cg.height
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    // flip so row 0 is the top row (matches CGImage cropping coords)
    ctx.translateBy(x: 0, y: CGFloat(h))
    ctx.scaleBy(x: 1, y: -1)
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    guard let data = ctx.data?.bindMemory(to: UInt8.self, capacity: w * h * 4) else { return nil }
    var minX = w, minY = h, maxX = -1, maxY = -1
    for y in 0..<h {
        for x in 0..<w {
            if data[(y * w + x) * 4 + 3] > 10 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
    }
    if maxX < minX { return nil }
    return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
}

var iconCache: [String: NSImage] = [:]

func menuIcon(_ name: String, _ color: NSColor, side: CGFloat = 256) -> NSImage? {
    let dark = NSApplication.shared.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    let key = name + (dark ? "-dark" : "-light")
    if let cached = iconCache[key] { return cached }
    guard let url = Bundle.main.url(forResource: name, withExtension: "svg"),
          let src = NSImage(contentsOf: url) else { return nil }
    let canvas = NSImage(size: NSSize(width: side, height: side))
    canvas.lockFocus()
    let ratio = src.size.width / max(src.size.height, 1)
    let drawW = ratio >= 1 ? side : side * ratio
    let drawH = ratio >= 1 ? side / ratio : side
    src.draw(in: NSRect(x: (side - drawW) / 2, y: (side - drawH) / 2, width: drawW, height: drawH))
    color.setFill()
    NSRect(x: 0, y: 0, width: side, height: side).fill(using: .sourceAtop)
    canvas.unlockFocus()

    guard let cg = canvas.cgImage(forProposedRect: nil, context: nil, hints: nil),
          let bb = alphaBBox(cg),
          let cropped = cg.cropping(to: bb) else { return canvas }
    let result = NSImage(cgImage: cropped, size: NSSize(width: cropped.width, height: cropped.height))
    iconCache[key] = result
    return result
}

let ICON_HEIGHTS: [String: CGFloat] = ["grok": 15.0, "deepseek": 12.0]

func iconAttachment(_ img: NSImage, height: CGFloat = 15, centerY: CGFloat = 4.5) -> NSAttributedString {
    let ratio = img.size.width / max(img.size.height, 1)
    let w = height * ratio
    let a = NSTextAttachment()
    a.image = img
    // align the vertical centre of both marks to the same optical centre above the baseline
    a.bounds = CGRect(x: 0, y: centerY - height / 2, width: w, height: height)
    return NSAttributedString(attachment: a)
}

// MARK: - history

struct Sample: Codable { var t: Int; var g: Double?; var d: Double? }

enum History {
    static func load() -> [Sample] {
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: HISTORY_PATH)),
              let s = try? JSONDecoder().decode([Sample].self, from: d) else { return [] }
        return s
    }
    static func save(_ samples: [Sample]) {
        try? FileManager.default.createDirectory(atPath: APP_SUPPORT, withIntermediateDirectories: true)
        let now = Int(Date().timeIntervalSince1970)
        let cutoff = now - 8 * 86400
        let denseFrom = now - 86400
        var trimmed: [Sample] = []
        var i = 0
        for s in samples where s.t >= cutoff {
            if s.t >= denseFrom || i % 5 == 0 { trimmed.append(s) }
            i += 1
        }
        if let d = try? JSONEncoder().encode(trimmed) {
            try? d.write(to: URL(fileURLWithPath: HISTORY_PATH), options: .atomic)
        }
    }
    static func todayStartSpend(_ samples: [Sample], current: Double) -> Double? {
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: Date())
        guard let first = samples.first(where: { $0.d != nil && Date(timeIntervalSince1970: TimeInterval($0.t)) >= dayStart && $0.t < Int(Date().timeIntervalSince1970) }),
              let start = first.d else { return nil }
        return current - start
    }
    static func firstSampleToday(_ samples: [Sample]) -> Date? {
        let dayStart = Calendar.current.startOfDay(for: Date())
        guard let f = samples.first(where: { $0.d != nil && Date(timeIntervalSince1970: TimeInterval($0.t)) >= dayStart }) else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(f.t))
    }

    static func last24h(_ samples: [Sample]) -> [Double] {
        let cutoff = Int(Date().timeIntervalSince1970) - 86400
        return samples.filter { $0.t >= cutoff }.compactMap { $0.d }
    }
}

// MARK: - models

struct GrokInfo {
    var percent: Double = 0
    var end: Date?
    var products: [(String, Double)] = []
}

struct DSInfo {
    var usd: Double?
    var cny: Double?
    var available: Bool = false
}

// MARK: - small views

final class BarView: NSView {
    var fraction: CGFloat = 0 { didSet { needsDisplay = true } }
    var barColor: NSColor = .controlAccentColor { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2).fill()
        var w = max(0, min(1, fraction)) * r.width
        if fraction > 0.001 { w = max(w, 3) }
        if w > 1 {
            barColor.setFill()
            NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: w, height: r.height),
                         xRadius: r.height / 2, yRadius: r.height / 2).fill()
        }
    }
}

func spendBuckets(_ samples: [Sample]) -> (week: [Double], day: [Double]) {
    var week = [Double](repeating: 0, count: 7)
    var day = [Double](repeating: 0, count: 24)
    let cal = Calendar.current
    let todayStart = cal.startOfDay(for: Date())
    var prev: (Date, Double)?
    for s in samples {
        guard let cur = s.d else { continue }
        let date = Date(timeIntervalSince1970: TimeInterval(s.t))
        if let p = prev {
            let spent = p.1 - cur
            if spent > 0.0001 {
                if date >= todayStart {
                    let h = cal.component(.hour, from: date)
                    day[min(23, max(0, h))] += spent
                }
                let daysAgo = cal.dateComponents([.day], from: cal.startOfDay(for: date), to: todayStart).day ?? 99
                if daysAgo >= 0 && daysAgo < 7 { week[6 - daysAgo] += spent }
            }
        }
        prev = (date, cur)
    }
    return (week, day)
}

final class BarsChartView: NSView {
    enum Mode { case week, day }

    var mode: Mode = .week
    var onToggle: (() -> Void)?
    var accent: NSColor = NSColor(srgbRed: 1.0, green: 0.58, blue: 0.16, alpha: 1.0) { didSet { needsDisplay = true } }

    private var weekValues = [Double](repeating: 0, count: 7)
    private var dayValues = [Double](repeating: 0, count: 24)
    private var shown: [CGFloat] = []
    private var animFrom: [CGFloat] = []
    private var animTo: [CGFloat] = []
    private var animTimer: Timer?
    private var animStart = Date()

    override func mouseDown(with event: NSEvent) { onToggle?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    func setData(week: [Double], day: [Double]) {
        let changed = week != weekValues || day != dayValues
        weekValues = week
        dayValues = day
        if changed { animateTo(targetValues()) }
    }

    func setMode(_ m: Mode, animated: Bool) {
        mode = m
        animateTo(targetValues(), duration: animated ? 0.32 : 0)
    }

    private func targetValues() -> [Double] {
        let raw = mode == .week ? weekValues : dayValues
        let mx = raw.max() ?? 0
        guard mx > 0.000001 else { return raw.map { _ in 0 } }
        return raw.map { $0 / mx }
    }

    private func animateTo(_ target: [Double], duration: TimeInterval = 0.35) {
        animTimer?.invalidate()
        animFrom = shown.count == target.count ? shown : target.map { _ in 0 }
        animTo = target.map { CGFloat($0) }
        if duration <= 0 {
            shown = animTo
            needsDisplay = true
            return
        }
        animStart = Date()
        animTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] t in
            guard let self = self else { t.invalidate(); return }
            let k = min(1.0, Date().timeIntervalSince(self.animStart) / duration)
            let e = 1 - pow(1 - k, 3)
            var cur = self.animFrom
            for i in 0..<min(cur.count, self.animTo.count) {
                cur[i] = self.animFrom[i] + (self.animTo[i] - self.animFrom[i]) * CGFloat(e)
            }
            self.shown = cur
            self.needsDisplay = true
            if k >= 1 { t.invalidate() }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let labelH: CGFloat = 11
        let area = NSRect(x: 1, y: labelH, width: max(1, bounds.width - 2), height: max(1, bounds.height - labelH - 1))
        let n = shown.count
        guard n > 0 else { return }

        let gap: CGFloat = n > 12 ? 2.0 : 4.0
        let bw = max(1, (area.width - gap * CGFloat(n - 1)) / CGFloat(n))
        let radius = min(2.0, bw / 2)

        for i in 0..<n {
            let v = max(0, min(1, shown[i]))
            let h = max(1.5, area.height * v)
            let x = area.minX + CGFloat(i) * (bw + gap)
            let r = NSRect(x: x, y: area.minY, width: bw, height: h)
            accent.withAlphaComponent(v > 0.02 ? 0.92 : 0.22).setFill()
            NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
        }

        // axis labels need real contrast on both dark and light menu bar themes
        let axisColor = NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark ? NSColor(calibratedWhite: 0.97, alpha: 0.92)
                          : NSColor(calibratedWhite: 0.12, alpha: 0.88)
        }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .semibold),
            .foregroundColor: axisColor,
        ]
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")

        func label(_ text: String, _ cx: CGFloat) {
            let sz = (text as NSString).size(withAttributes: attrs)
            (text as NSString).draw(at: NSPoint(x: cx - sz.width / 2, y: 0), withAttributes: attrs)
        }

        if mode == .week {
            df.dateFormat = "EEEEE"
            let today = Calendar.current.startOfDay(for: Date())
            for i in 0..<n {
                guard let d = Calendar.current.date(byAdding: .day, value: -(6 - i), to: today) else { continue }
                let cx = area.minX + CGFloat(i) * (bw + gap) + bw / 2
                label(df.string(from: d), cx)
            }
        } else {
            for h in [0, 6, 12, 18] where h < n {
                let cx = area.minX + CGFloat(h) * (bw + gap) + bw / 2
                label(String(h), cx)
            }
        }
    }
}

// MARK: - popover

final class PanelController: NSViewController {
    let grokTitle = NSTextField(labelWithString: "")
    let grokValue = NSTextField(labelWithString: "")
    let grokBar   = BarView()
    let grokReset = NSTextField(labelWithString: "")
    let buildName = NSTextField(labelWithString: "Grok Build")
    let buildPct  = NSTextField(labelWithString: "")
    let buildBar  = BarView()
    let chatName  = NSTextField(labelWithString: "Grok Chat")
    let chatPct   = NSTextField(labelWithString: "")
    let chatBar   = BarView()
    let dsTitle   = NSTextField(labelWithString: "DeepSeek")
    let dsValue   = NSTextField(labelWithString: "")
    let dsToday   = NSTextField(labelWithString: "")
    let dsWeek    = NSTextField(labelWithString: "")
    let spark     = BarsChartView()
    var chartMode: BarsChartView.Mode = .week
    var highContrast = false
    let footer    = NSTextField(labelWithString: "")
    var onRefresh: (() -> Void)?
    var onKeys: (() -> Void)?
    var onQuit: (() -> Void)?

    override func loadView() {
        let W: CGFloat = 340
        let H: CGFloat = 292
        let M: CGFloat = 16
        let CW = W - M * 2

        let root = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: W, height: H))
        root.material = .popover
        root.blendingMode = .behindWindow
        root.state = .active

        func mono(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
            return NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
        }
        func small(_ text: String, _ y: CGFloat, _ h: CGFloat, _ size: CGFloat = 10, weight: NSFont.Weight = .regular, color: NSColor = .secondaryLabelColor) -> NSTextField {
            let f = NSTextField(labelWithString: text)
            f.font = NSFont.systemFont(ofSize: size, weight: weight)
            f.textColor = color
            f.frame = NSRect(x: M, y: y, width: CW, height: h)
            return f
        }

        // ---- Grok block
        grokTitle.stringValue = "GROK · WEEKLY"
        grokTitle.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        grokTitle.textColor = .secondaryLabelColor
        grokTitle.frame = NSRect(x: M, y: 264, width: 160, height: 12)

        grokValue.font = mono(24, .bold)
        grokValue.alignment = .right
        grokValue.frame = NSRect(x: M + 160, y: 250, width: CW - 160, height: 28)

        grokBar.frame = NSRect(x: M, y: 238, width: CW, height: 6)
        grokBar.barColor = .systemGreen

        grokReset.font = NSFont.systemFont(ofSize: 11)
        grokReset.textColor = .tertiaryLabelColor
        grokReset.alignment = .left
        grokReset.frame = NSRect(x: M, y: 222, width: CW, height: 12)

        for (n, y) in [(buildName, CGFloat(200)), (chatName, CGFloat(182))] {
            n.font = NSFont.systemFont(ofSize: 11)
            n.textColor = .secondaryLabelColor
            n.frame = NSRect(x: M, y: y, width: 120, height: 13)
        }
        for (p, y) in [(buildPct, CGFloat(200)), (chatPct, CGFloat(182))] {
            p.font = mono(11)
            p.alignment = .right
            p.frame = NSRect(x: W - M - 60, y: y, width: 60, height: 13)
        }
        buildBar.frame = NSRect(x: M + 120, y: 202, width: 112, height: 6)
        buildBar.barColor = .systemTeal
        chatBar.frame = NSRect(x: M + 120, y: 184, width: 112, height: 6)
        chatBar.barColor = .systemTeal

        let sep = NSBox(frame: NSRect(x: M, y: 168, width: CW, height: 1))
        sep.boxType = .separator

        // ---- DeepSeek block (tight: value -> today -> sparkline)
        dsTitle.stringValue = "DEEPSEEK · 7 DAYS"
        dsTitle.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        dsTitle.textColor = .secondaryLabelColor
        dsTitle.frame = NSRect(x: M, y: 148, width: 160, height: 12)

        dsValue.font = mono(24, .bold)
        dsValue.alignment = .right
        dsValue.frame = NSRect(x: M + 180, y: 118, width: CW - 180, height: 28)

        dsToday.font = mono(10)
        dsToday.textColor = .secondaryLabelColor
        dsToday.alignment = .right
        dsToday.frame = NSRect(x: M + 100, y: 96, width: CW - 100, height: 12)

        dsWeek.font = mono(10)
        dsWeek.textColor = .secondaryLabelColor
        dsWeek.alignment = .right
        dsWeek.frame = NSRect(x: M + 100, y: 80, width: CW - 100, height: 12)

        spark.frame = NSRect(x: M, y: 86, width: 160, height: 56)
        spark.onToggle = { [weak self] in
            guard let self = self else { return }
            self.chartMode = self.chartMode == .week ? .day : .week
            self.spark.setMode(self.chartMode, animated: true)
            self.dsTitle.stringValue = self.chartMode == .week ? "DEEPSEEK · 7 DAYS" : "DEEPSEEK · TODAY"
        }

        let sep2 = NSBox(frame: NSRect(x: M, y: 52, width: CW, height: 1))
        sep2.boxType = .separator

        footer.font = NSFont.systemFont(ofSize: 11)
        footer.textColor = .tertiaryLabelColor
        footer.frame = NSRect(x: M, y: 18, width: 150, height: 12)

        let refreshBtn = NSButton(title: "Refresh", target: self, action: #selector(fireRefresh))
        refreshBtn.bezelStyle = .inline
        refreshBtn.isBordered = false
        refreshBtn.font = NSFont.systemFont(ofSize: 11)
        refreshBtn.frame = NSRect(x: 176, y: 12, width: 64, height: 22)

        let keysBtn = NSButton(title: "Keys", target: self, action: #selector(fireKeys))
        keysBtn.bezelStyle = .inline
        keysBtn.isBordered = false
        keysBtn.font = NSFont.systemFont(ofSize: 11)
        keysBtn.frame = NSRect(x: 244, y: 12, width: 44, height: 22)

        let quitBtn = NSButton(title: "Quit", target: self, action: #selector(fireQuit))
        quitBtn.bezelStyle = .inline
        quitBtn.isBordered = false
        quitBtn.font = NSFont.systemFont(ofSize: 11)
        quitBtn.frame = NSRect(x: 292, y: 12, width: 36, height: 22)

        for v: NSView in [grokTitle, grokValue, grokBar, grokReset, buildName, buildPct, buildBar,
                          chatName, chatPct, chatBar, sep, dsTitle, dsValue, dsToday, dsWeek, spark,
                          sep2, footer, refreshBtn, keysBtn, quitBtn] {
            root.addSubview(v)
        }
        self.view = root
    }

    @objc func fireRefresh() { onRefresh?() }
    @objc func fireKeys() { onKeys?() }
    @objc func fireQuit() { onQuit?() }

    func update(grok: GrokInfo?, ds: DSInfo?, grokErr: String?, dsErr: String?,
                updated: Date?, samples: [Sample]) {
        let headColor = highContrast ? NSColor(calibratedWhite: 0.16, alpha: 1) : NSColor.secondaryLabelColor
        let metaColor = highContrast ? NSColor(calibratedWhite: 0.26, alpha: 1) : NSColor.secondaryLabelColor
        let faintColor = highContrast ? NSColor(calibratedWhite: 0.38, alpha: 1) : NSColor.tertiaryLabelColor
        grokTitle.textColor = headColor
        dsTitle.textColor = headColor
        buildName.textColor = metaColor
        chatName.textColor = metaColor
        dsToday.textColor = metaColor
        dsWeek.textColor = faintColor
        grokReset.textColor = faintColor
        footer.textColor = faintColor
        if let g = grok {
            grokValue.stringValue = String(format: "%.0f%%", g.percent)
            grokBar.fraction = CGFloat(min(g.percent, 100) / 100)
            grokBar.barColor = g.percent >= 80 ? .systemRed : (g.percent >= 60 ? .systemOrange : .systemGreen)
            buildName.isHidden = false; chatName.isHidden = false
            buildBar.isHidden = false; chatBar.isHidden = false
            buildPct.isHidden = false; chatPct.isHidden = false
            let b = g.products.first(where: { $0.0 == "GrokBuild" })?.1 ?? 0
            let c = g.products.first(where: { $0.0 == "GrokChat" })?.1 ?? 0
            buildPct.stringValue = String(format: "%.0f%%", b)
            chatPct.stringValue = String(format: "%.0f%%", c)
            buildBar.fraction = CGFloat(min(b, 100) / 100)
            chatBar.fraction = CGFloat(min(c, 100) / 100)
            if let e = g.end {
                let s = Int(e.timeIntervalSinceNow)
                let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
                grokReset.stringValue = d > 0 ? "resets in \(d)d \(h)h" : (h > 0 ? "resets in \(h)h \(m)m" : "resets in \(m)m")
            } else {
                grokReset.stringValue = ""
            }
        } else {
            grokValue.stringValue = "—"
            grokBar.fraction = 0
            grokReset.stringValue = grokErr ?? "unavailable"
            for v: NSView in [buildName, chatName, buildBar, chatBar, buildPct, chatPct] { v.isHidden = true }
        }

        if let d = ds, let usd = d.usd {
            dsValue.stringValue = String(format: "$%.2f", usd)
            let b = spendBuckets(samples)
            spark.setData(week: b.week, day: b.day)
            dsTitle.stringValue = chartMode == .week ? "DEEPSEEK · 7 DAYS" : "DEEPSEEK · TODAY"
            let delta = History.todayStartSpend(samples, current: usd) ?? 0
            var label = delta < -0.004 ? String(format: "today  −$%.2f", -delta) : "today  $0.00"
            if let start = History.firstSampleToday(samples) {
                let cal = Calendar.current
                let dayStart = cal.startOfDay(for: Date())
                if start.timeIntervalSince(dayStart) > 900 {
                    let df = DateFormatter(); df.dateFormat = "HH:mm"
                    label += "  ·  since " + df.string(from: start)
                }
            }
            dsToday.stringValue = label
            let weekTotal = b.week.reduce(0, +)
            dsWeek.stringValue = weekTotal > 0.0004 ? String(format: "7 d  −$%.2f", weekTotal) : "7 d  $0.00"
        } else {
            dsValue.stringValue = "—"
            dsToday.stringValue = dsErr ?? "unavailable"
            dsWeek.stringValue = ""
            spark.setData(week: Array(repeating: 0, count: 7), day: Array(repeating: 0, count: 24))
        }

        if let u = updated {
            let df = DateFormatter(); df.dateFormat = "HH:mm:ss"
            footer.stringValue = "updated " + df.string(from: u)
        } else {
            footer.stringValue = "loading…"
        }
    }
}

// MARK: - app

final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var timer: Timer?
    var popover: NSPopover!
    var panel: PanelController!
    var grok: GrokInfo?
    var ds: DSInfo?
    var grokErr: String?
    var dsErr: String?
    var lastUpdate: Date?
    var settingsWindow: NSWindow?
    var refreshingGrok = false
    var cooldownUntil: Date?
    var lastAttempt: Date?
    var grokAuthFailedUntil: Date?
    var lastHistorySave: Date?
    var grokTokenCache: String?
    var dsKeyCache: String?
    var lastPayloadSignature = ""
    var stableCycles = 0
    var currentInterval: TimeInterval = 60
    var lastLogSignature = ""
    var samples: [Sample] = []

    func applicationDidFinishLaunching(_ n: Notification) {
        let bundleId = Bundle.main.bundleIdentifier ?? "com.oleg.aiquota"
        let siblings = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if !siblings.isEmpty {
            logLine("another instance is running, exiting")
            NSApp.terminate(nil)
            return
        }
        samples = History.load()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "…"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)

        panel = PanelController()
        panel.onRefresh = { [weak self] in self?.refresh(force: true) }
        panel.onKeys = { [weak self] in self?.openSettings() }
        panel.onQuit = { NSApp.terminate(nil) }

        popover = NSPopover()
        popover.contentViewController = panel
        popover.behavior = .transient
        popover.animates = false

        render()
        schedule()
        refresh()

        if ProcessInfo.processInfo.environment["AIQUOTA_POPOVER_DEMO"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.togglePopover() }
        }

        NotificationCenter.default.addObserver(forName: Notification.Name.NSProcessInfoPowerStateDidChange,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.schedule()
        }

        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        nc.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
    }

    @objc func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            logLine("popover hidden")
        } else {
            stableCycles = 0
            lastPayloadSignature = ""
            panel.update(grok: grok, ds: ds, grokErr: grokErr, dsErr: dsErr, updated: lastUpdate, samples: samples)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            logLine("popover shown frame=\(popover.contentViewController?.view.frame ?? .zero)")
            if let lu = lastUpdate, Date().timeIntervalSince(lu) > 10 { refresh(force: true) }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        History.save(samples)
    }

    @objc func willSleep() { timer?.invalidate(); timer = nil }
    @objc func didWake() { refresh(force: true); schedule() }

    func effectiveInterval() -> TimeInterval {
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return 180 }
        if stableCycles >= 3 && !(popover?.isShown ?? false) { return 180 }
        return REFRESH_SEC
    }

    func schedule() {
        timer?.invalidate()
        let interval = effectiveInterval()
        currentInterval = interval
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        timer?.tolerance = min(15, interval / 4)
    }

    // back off to 3 min when nothing changes and nobody is looking
    func noteCycle() {
        let sig = String(format: "%.0f|%.2f", grok?.percent ?? -1, ds?.usd ?? -1)
        if sig == lastPayloadSignature { stableCycles += 1 } else { lastPayloadSignature = sig; stableCycles = 0 }
        let target = effectiveInterval()
        if abs(target - currentInterval) > 1 {
            logLine("interval -> " + String(Int(target)) + "s")
            schedule()
        }
    }

    func refresh(force: Bool = false) {
        if !force, let c = cooldownUntil, c > Date() { return }
        if !force, let a = lastAttempt, Date().timeIntervalSince(a) < 5 { return }
        lastAttempt = Date()
        fetchGrok()
        fetchDeepSeek()
    }

    func cachedGrokToken() -> String? {
        if let t = grokTokenCache { return t }
        let t = keychainGet(GROK_SERVICE) ?? dbGrokToken()
        grokTokenCache = t
        return t
    }

    func cachedDeepSeekKey() -> String? {
        if let k = dsKeyCache { return k }
        let k = keychainGet(DS_SERVICE) ?? dbDeepSeekKey()
        dsKeyCache = k
        return k
    }

    // MARK: grok

    func fetchGrok(token explicit: String? = nil, allowRefresh: Bool = true) {
        if let blocked = grokAuthFailedUntil, blocked > Date() {
            grok = nil
            grokErr = "sign-in required"
            render()
            return
        }
        guard let token = explicit ?? cachedGrokToken() else {
            grokErr = "no Grok token"; render(); return
        }
        httpJSON(GROK_BILLING_URL, bearer: token) { [weak self] code, data in
            guard let self = self else { return }
            if code == 401 {
                self.grokTokenCache = nil
                if allowRefresh {
                    self.refreshGrokToken { fresh in
                        if let fresh = fresh {
                            self.fetchGrok(token: fresh, allowRefresh: false)
                        } else {
                            self.grokAuthFailedUntil = Date().addingTimeInterval(900)
                            self.grok = nil
                            self.grokErr = "sign-in required"
                            self.render()
                        }
                    }
                } else {
                    self.grok = nil
                    self.grokErr = "sign-in required"
                    self.render()
                }
                return
            }
            if code == 429 || code >= 500 { self.cooldownUntil = Date().addingTimeInterval(180) }
            guard code == 200, let data = data,
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let cfg = root["config"] as? [String: Any] else {
                self.grok = nil
                self.grokErr = "HTTP \(code)"
                self.render(); return
            }
            var info = GrokInfo()
            info.percent = (cfg["creditUsagePercent"] as? NSNumber)?.doubleValue ?? 0
            if let per = cfg["currentPeriod"] as? [String: Any], let e = per["end"] as? String {
                let f = ISO8601DateFormatter()
                f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                info.end = f.date(from: e) ?? ISO8601DateFormatter().date(from: e)
            }
            if let pu = cfg["productUsage"] as? [[String: Any]] {
                for p in pu {
                    if let name = p["product"] as? String,
                       let pct = (p["usagePercent"] as? NSNumber)?.doubleValue {
                        info.products.append((name, pct))
                    }
                }
            }
            self.grok = info
            self.grokErr = nil
            self.lastUpdate = Date()
            self.render()
        }
    }

    func refreshGrokToken(completion: @escaping (String?) -> Void) {
        guard !refreshingGrok else { completion(nil); return }
        refreshingGrok = true
        defer { refreshingGrok = false }

        if let dbAccess = dbGrokProfile()?.access, dbAccess != keychainGet(GROK_SERVICE) {
            keychainSet(GROK_SERVICE, dbAccess)
            completion(dbAccess)
            return
        }
        guard let refresh = keychainGet(GROK_REFRESH_SVC) ?? dbGrokProfile()?.refresh, !refresh.isEmpty else {
            completion(nil); return
        }
        var comps = URLComponents()
        comps.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "client_id", value: XAI_CLIENT_ID),
            URLQueryItem(name: "refresh_token", value: refresh),
        ]
        var req = URLRequest(url: URL(string: XAI_TOKEN_URL)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = comps.percentEncodedQuery?.data(using: .utf8)
        req.timeoutInterval = 20
        netSession.dataTask(with: req) { data, resp, err in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            guard code == 200, let data = data,
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let access = o["access_token"] as? String else {
                logLine("refresh failed http=" + String(code) + " " + (err?.localizedDescription ?? ""))
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let newRefresh = (o["refresh_token"] as? String) ?? refresh
            let ttl = (o["expires_in"] as? NSNumber)?.doubleValue ?? 3600
            keychainSet(GROK_SERVICE, access)
            keychainSet(GROK_REFRESH_SVC, newRefresh)
            dbStoreGrok(access: access, refresh: newRefresh,
                        expiresMs: Int(Date().timeIntervalSince1970 * 1000 + ttl * 1000))
            logLine("grok token refreshed")
            DispatchQueue.main.async { completion(access) }
        }.resume()
    }

    // MARK: deepseek

    func fetchDeepSeek(retry: Bool = false) {
        guard let key = cachedDeepSeekKey() else {
            dsErr = "no DeepSeek key"; render(); return
        }
        httpJSON(DS_BALANCE_URL, bearer: key) { [weak self] code, data in
            guard let self = self else { return }
            if code == 401 { self.dsKeyCache = nil }
            if code == 401 && !retry, let fresh = dbDeepSeekKey(), fresh != key {
                keychainSet(DS_SERVICE, fresh)
                self.fetchDeepSeek(retry: true)
                return
            }
            if code == 429 || code >= 500 { self.cooldownUntil = Date().addingTimeInterval(180) }
            guard code == 200, let data = data,
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                self.ds = nil
                self.dsErr = "HTTP \(code)"
                self.render(); return
            }
            var info = DSInfo()
            info.available = (root["is_available"] as? Bool) ?? false
            if let arr = root["balance_infos"] as? [[String: Any]] {
                for b in arr {
                    let cur = (b["currency"] as? String) ?? ""
                    let val = Double((b["total_balance"] as? String) ?? "0") ?? 0
                    if cur == "USD" { info.usd = val }
                    if cur == "CNY" { info.cny = val }
                }
            }
            self.ds = info
            self.dsErr = nil
            self.lastUpdate = Date()
            self.samples.append(Sample(t: Int(Date().timeIntervalSince1970), g: self.grok?.percent, d: info.usd))
            self.noteCycle()
            if self.samples.count > 6000 { self.samples = Array(self.samples.suffix(5000)) }
            if self.lastHistorySave == nil || Date().timeIntervalSince(self.lastHistorySave!) > 600 {
                History.save(self.samples)
                self.lastHistorySave = Date()
            }
            self.render()
        }
    }

    // MARK: render

    func render() {
        // Menu bar text and marks stay a single colour at all usage levels: no orange/red warning tints.
        let darkBar = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let color: NSColor = darkBar ? .white : .labelColor

        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        func txt(_ s: String) -> NSAttributedString {
            NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
        }
        let attr = NSMutableAttributedString()
        var parts: [String] = []
        if let g = grok {
            if let icon = menuIcon("grok", color) {
                attr.append(iconAttachment(icon, height: ICON_HEIGHTS["grok"] ?? 15))
                attr.append(txt(" "))
            }
            attr.append(txt(String(format: "%.0f%%", g.percent)))
            parts.append(String(format: "Grok %.0f%%", g.percent))
        }
        if let d = ds {
            if !attr.string.isEmpty && !attr.string.hasSuffix(" ") { attr.append(txt("  ")) }
            if let icon = menuIcon("deepseek", color) {
                attr.append(iconAttachment(icon, height: ICON_HEIGHTS["deepseek"] ?? 15))
                attr.append(txt(" "))
            }
            if let u = d.usd {
                attr.append(txt(String(format: "$%.2f", u)))
                parts.append(String(format: "DS $%.2f", u))
            } else if let c = d.cny {
                attr.append(txt(String(format: "¥%.2f", c)))
                parts.append(String(format: "DS ¥%.2f", c))
            }
        }
        if attr.length == 0 { attr.append(txt("AI —")) }
        let title = parts.isEmpty ? "AI —" : parts.joined(separator: " · ")
        statusItem.button?.attributedTitle = attr

        let sig = title + " grokErr=" + (grokErr ?? "-") + " dsErr=" + (dsErr ?? "-")
        if sig != lastLogSignature {
            lastLogSignature = sig
            logLine("title=" + sig)
        }
        if popover?.isShown == true {
            panel.update(grok: grok, ds: ds, grokErr: grokErr, dsErr: dsErr, updated: lastUpdate, samples: samples)
        }
    }

    // MARK: settings

    @objc func openSettings() {
        popover.performClose(nil)
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 250),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "AIQuota — keys"
            let v = NSView(frame: w.contentRect(forFrameRect: w.frame))
            func label(_ s: String, _ y: CGFloat) {
                let l = NSTextField(labelWithString: s)
                l.frame = NSRect(x: 20, y: y, width: 400, height: 16)
                l.font = NSFont.systemFont(ofSize: 11)
                l.textColor = .secondaryLabelColor
                v.addSubview(l)
            }
            func field(_ id: String, _ y: CGFloat) -> NSSecureTextField {
                let f = NSSecureTextField(frame: NSRect(x: 20, y: y, width: 400, height: 24))
                f.placeholderString = "blank = keep current"
                f.identifier = NSUserInterfaceItemIdentifier(id)
                v.addSubview(f)
                return f
            }
            label("DeepSeek API key (sk-…)", 214)
            _ = field("ds", 188)
            label("Grok access token (auto-refreshed)", 158)
            _ = field("grok", 132)
            label("Grok refresh token (offline_access)", 102)
            _ = field("grokrefresh", 76)
            let save = NSButton(title: "Save", target: self, action: #selector(saveKeys))
            save.frame = NSRect(x: 320, y: 20, width: 100, height: 30)
            save.bezelStyle = .rounded
            let close = NSButton(title: "Close", target: self, action: #selector(closeSettings))
            close.frame = NSRect(x: 220, y: 20, width: 90, height: 30)
            close.bezelStyle = .rounded
            v.addSubview(save); v.addSubview(close)
            w.contentView = v
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func closeSettings() { settingsWindow?.orderOut(nil) }

    @objc func saveKeys() {
        guard let v = settingsWindow?.contentView else { return }
        for sub in v.subviews {
            guard let f = sub as? NSSecureTextField else { continue }
            let t = f.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { continue }
            switch f.identifier?.rawValue {
            case "ds": keychainSet(DS_SERVICE, t)
            case "grok": keychainSet(GROK_SERVICE, t)
            case "grokrefresh": keychainSet(GROK_REFRESH_SVC, t)
            default: break
            }
            f.stringValue = ""
        }
        refresh(force: true)
    }
}

// MARK: - panel snapshot (layout verification)

if CommandLine.arguments.contains("--panel-shot") {
    let panel = PanelController()
    _ = panel.view
    var g = GrokInfo()
    g.percent = 27
    g.end = Date().addingTimeInterval(4 * 86400 + 2 * 3600)
    g.products = [("GrokBuild", 25), ("GrokChat", 2)]
    var d = DSInfo()
    d.usd = 10.32
    d.available = true
    panel.update(grok: g, ds: d, grokErr: nil, dsErr: nil, updated: Date(), samples: History.load())
    print("today label:", panel.dsToday.stringValue)
    for n in ["grok", "deepseek"] {
        if let img = menuIcon(n, .white) {
            print("icon", n, Int(img.size.width), "x", Int(img.size.height))
        } else {
            print("icon", n, "MISSING")
        }
    }
    let v = panel.view
    v.layoutSubtreeIfNeeded()
    if let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
        v.cacheDisplay(in: v.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            let out = CommandLine.arguments.last ?? "/tmp/panel.png"
            try? data.write(to: URL(fileURLWithPath: out))
            print("wrote", out, v.bounds)
            exit(0)
        }
    }
    print("render failed")
    exit(1)
}

// MARK: - marketing screenshot

func demoPanelImage(light: Bool = true) -> NSImage {
    let panel = PanelController()
    _ = panel.view
    let appearance = NSAppearance(named: light ? .aqua : .darkAqua)
    panel.view.appearance = appearance
    for sub in panel.view.subviews { sub.appearance = appearance }

    let cal = Calendar.current
    let now = Date()
    var samples: [Sample] = []
    var balance = 14.80
    for dayAgo in stride(from: 7, through: 0, by: -1) {
        for slot in 0..<24 {
            guard let d = cal.date(byAdding: .hour, value: -dayAgo * 24 + slot, to: now), d <= now else { continue }
            let hour = cal.component(.hour, from: d)
            if hour >= 9 && hour <= 23 { balance -= Double.random(in: 0.01...0.12) }
            samples.append(Sample(t: Int(d.timeIntervalSince1970), g: nil, d: max(1.2, balance)))
        }
    }

    var g = GrokInfo()
    g.percent = 62
    g.end = cal.date(byAdding: .day, value: 3, to: now)
    g.products = [("GrokBuild", 58), ("GrokChat", 4)]

    var d = DSInfo()
    d.usd = balance
    d.available = true

    panel.highContrast = true
    panel.update(grok: g, ds: d, grokErr: nil, dsErr: nil, updated: now, samples: samples)
    panel.view.layoutSubtreeIfNeeded()

    let size = panel.view.bounds.size
    let img = NSImage(size: size)
    img.lockFocus()
    let card = light ? NSColor(srgbRed: 0.976, green: 0.976, blue: 0.984, alpha: 1)
                     : NSColor(srgbRed: 0.125, green: 0.125, blue: 0.135, alpha: 1)
    card.setFill()
    NSRect(origin: .zero, size: size).fill()
    if let appearance = appearance {
        appearance.performAsCurrentDrawingAppearance {
            if let rep = panel.view.bitmapImageRepForCachingDisplay(in: panel.view.bounds) {
                panel.view.cacheDisplay(in: panel.view.bounds, to: rep)
                rep.draw(in: NSRect(origin: .zero, size: size))
            }
        }
    }
    img.unlockFocus()
    return img
}

if CommandLine.arguments.contains("--marketing-shot") {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    app.appearance = NSAppearance(named: .darkAqua)

    let W: CGFloat = 372, H: CGFloat = 358
    let canvas = NSImage(size: NSSize(width: W, height: H))
    canvas.lockFocus()

    let bg = NSGradient(colors: [
        NSColor(srgbRed: 0.055, green: 0.060, blue: 0.090, alpha: 1),
        NSColor(srgbRed: 0.105, green: 0.085, blue: 0.145, alpha: 1),
        NSColor(srgbRed: 0.045, green: 0.055, blue: 0.080, alpha: 1),
    ])!
    bg.draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -55)

    let glow = NSGradient(colors: [
        NSColor(srgbRed: 0.30, green: 0.42, blue: 0.99, alpha: 0.20),
        NSColor(srgbRed: 0.30, green: 0.42, blue: 0.99, alpha: 0.0),
    ])!
    glow.draw(in: NSRect(x: W * 0.15, y: H * 0.30, width: W * 1.1, height: H * 1.1),
              relativeCenterPosition: .zero)

    // menu bar strip
    let barH: CGFloat = 30
    NSColor(calibratedWhite: 1.0, alpha: 0.07).setFill()
    NSRect(x: 0, y: H - barH, width: W, height: barH).fill()
    NSColor(calibratedWhite: 0.0, alpha: 0.35).setFill()
    NSRect(x: 0, y: H - barH, width: W, height: 1).fill()

    // our item, to the left of the clock
    let itemFont = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
    let numAttrs: [NSAttributedString.Key: Any] = [.font: itemFont, .foregroundColor: NSColor.white]
    let pctText = "62%", usdText = "$8.41"
    let gi = menuIcon("grok", .white)
    let di = menuIcon("deepseek", .white)
    let gh: CGFloat = 15, dh: CGFloat = 12
    let gw: CGFloat = gh * (gi?.size.width ?? 1) / max(gi?.size.height ?? 1, 1)
    let dw: CGFloat = dh * (di?.size.width ?? 1) / max(di?.size.height ?? 1, 1)
    let itemW = gw + 5 + (pctText as NSString).size(withAttributes: numAttrs).width + 16 + dw + 5
        + (usdText as NSString).size(withAttributes: numAttrs).width
    let itemX = (W - itemW) / 2
    let itemY = H - barH + 7

    var cx = itemX
    gi?.draw(in: NSRect(x: cx, y: itemY, width: gw, height: gh)); cx += gw + 5
    (pctText as NSString).draw(at: NSPoint(x: cx, y: itemY + 0.5), withAttributes: numAttrs)
    cx += (pctText as NSString).size(withAttributes: numAttrs).width + 16
    di?.draw(in: NSRect(x: cx, y: itemY + 1.5, width: dw, height: dh)); cx += dw + 5
    (usdText as NSString).draw(at: NSPoint(x: cx, y: itemY + 0.5), withAttributes: numAttrs)

    // popover anchored under the item
    let prevAppearance = NSApp.appearance
    NSApp.appearance = NSAppearance(named: .aqua)
    let panel = demoPanelImage(light: true)
    NSApp.appearance = prevAppearance

    let pw: CGFloat = 340, ph: CGFloat = 292
    let anchor = itemX + itemW * 0.5
    let px = (W - pw) / 2
    let py = H - barH - ph - 10

    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.62)
    shadow.shadowBlurRadius = 42
    shadow.shadowOffset = NSSize(width: 0, height: -18)

    let panelRect = NSRect(x: px, y: py, width: pw, height: ph)
    let rounded = NSBezierPath(roundedRect: panelRect, xRadius: 12, yRadius: 12)

    // caret pointing at the status item
    let caret = NSBezierPath()
    let caretCX = min(max(anchor, px + 26), px + pw - 26)
    caret.move(to: NSPoint(x: caretCX - 8, y: py + ph - 1))
    caret.line(to: NSPoint(x: caretCX, y: py + ph + 8))
    caret.line(to: NSPoint(x: caretCX + 8, y: py + ph - 1))
    caret.close()

    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSColor(srgbRed: 0.975, green: 0.975, blue: 0.982, alpha: 1).setFill()
    rounded.fill()
    caret.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    rounded.addClip()
    panel.draw(in: panelRect)
    NSGraphicsContext.restoreGraphicsState()

    NSColor(calibratedWhite: 0.0, alpha: 0.10).setStroke()
    rounded.lineWidth = 1
    rounded.stroke()

    canvas.unlockFocus()

    if let tiff = canvas.tiffRepresentation,
       let rep = NSBitmapImageRep(data: tiff),
       let png = rep.representation(using: .png, properties: [:]) {
        let out = CommandLine.arguments.last ?? "hero.png"
        try? png.write(to: URL(fileURLWithPath: out))
        print("wrote", out, rep.pixelsWide, "x", rep.pixelsHigh)
        exit(0)
    }
    print("render failed")
    exit(1)
}

// MARK: - probe mode

if CommandLine.arguments.contains("--probe") {
    func syncGet(_ url: String, _ tok: String) -> String {
        var req = URLRequest(url: URL(string: url)!)
        req.setValue("Bearer " + tok, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 20
        let sem = DispatchSemaphore(value: 0)
        var out = ""
        URLSession.shared.dataTask(with: req) { d, r, e in
            let c = (r as? HTTPURLResponse)?.statusCode ?? -1
            out = "http=\(c) " + (d.flatMap { String(data: $0, encoding: .utf8) } ?? String(describing: e))
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 25)
        return out
    }
    if let t = keychainGet(GROK_SERVICE) ?? dbGrokToken() {
        print("grok " + syncGet(GROK_BILLING_URL, t).prefix(300))
    } else { print("grok: no token") }
    if let k = keychainGet(DS_SERVICE) ?? dbDeepSeekKey() {
        print("ds " + syncGet(DS_BALANCE_URL, k).prefix(300))
    } else { print("ds: no key") }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
