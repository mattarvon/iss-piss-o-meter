// ============================================================================
//  ISS PISS-O-METER  —  macOS menu-bar edition
//
//  A lightweight macOS menu-bar gauge showing the ISS urine-tank fill level,
//  driven by NASA's public ISS live telemetry feed (Lightstreamer, ISSLIVE
//  adapter set, item NODE3000005 = "Urine Tank Qty", in percent).
//
//  Pure AppKit + Foundation — no third-party packages. Run it with the
//  Apple-signed Swift toolchain (so Gatekeeper is happy):
//
//      swift IssPissOMeter.swift
//
//  Requires the Xcode Command Line Tools (`xcode-select --install`) and
//  macOS 12+ (uses URLSession async streaming).
// ============================================================================

import AppKit
import Foundation

// ---------------------------------------------------------------------------
//  Shared "piss tank" rendering — the macOS twin of the Windows TankArt.
// ---------------------------------------------------------------------------
enum TankArt {
    static func liquid(_ pct: Double) -> NSColor {
        if pct >= 95 { return NSColor(srgbRed: 214/255, green: 170/255, blue: 0/255,  alpha: 1) }
        if pct >= 80 { return NSColor(srgbRed: 230/255, green: 188/255, blue: 12/255, alpha: 1) }
        return            NSColor(srgbRed: 242/255, green: 208/255, blue: 39/255, alpha: 1)
    }

    static func accent(_ pct: Double) -> NSColor {
        if pct >= 95 { return NSColor(srgbRed: 229/255, green: 57/255,  blue: 53/255,  alpha: 1) }
        if pct >= 80 { return NSColor(srgbRed: 255/255, green: 152/255, blue: 0/255,   alpha: 1) }
        if pct >= 60 { return NSColor(srgbRed: 255/255, green: 213/255, blue: 79/255,  alpha: 1) }
        return            NSColor(srgbRed: 124/255, green: 214/255, blue: 120/255, alpha: 1)
    }

    static func status(_ pct: Double, _ hasData: Bool) -> String {
        if !hasData { return "AWAITING SIGNAL" }
        if pct >= 95 { return "CRITICAL - FLUSH!" }
        if pct >= 80 { return "DUMP SOON" }
        if pct >= 60 { return "FILLING UP" }
        return "NOMINAL"
    }

    /// Draws a tank with a fill level into an NSImage (coordinates: y-up).
    static func image(percent: Double, hasData: Bool, size: NSSize) -> NSImage {
        let img = NSImage(size: size, flipped: false) { rect in
            let capH = rect.height * 0.16
            let body = NSRect(x: rect.minX + 0.75, y: rect.minY + 0.75,
                              width: rect.width - 1.5, height: rect.height - capH - 1.5)
            let radius = min(body.width, body.height) * 0.22

            // Cap / neck on top of the tank.
            let capW = rect.width * 0.42
            let cap = NSRect(x: rect.midX - capW / 2, y: body.maxY - radius * 0.4,
                             width: capW, height: capH + radius * 0.4)
            NSColor(srgbRed: 0.36, green: 0.39, blue: 0.42, alpha: 1).setFill()
            NSBezierPath(roundedRect: cap, xRadius: capH * 0.4, yRadius: capH * 0.4).fill()

            // Tank body interior.
            let bodyPath = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)
            NSColor(srgbRed: 0.15, green: 0.16, blue: 0.19, alpha: 1).setFill()
            bodyPath.fill()

            // Liquid fill from the bottom up.
            let p = max(0, min(100, percent))
            if hasData && p > 0 {
                let fillH = body.height * CGFloat(p / 100.0)
                let fillRect = NSRect(x: body.minX, y: body.minY, width: body.width, height: fillH)
                NSGraphicsContext.saveGraphicsState()
                bodyPath.addClip()
                let liq = TankArt.liquid(p)
                let top = liq.blended(withFraction: 0.28, of: .white) ?? liq
                if let grad = NSGradient(starting: liq, ending: top) {
                    grad.draw(in: fillRect, angle: 90) // 90° = bottom→top
                }
                // Meniscus highlight at the liquid surface.
                (liq.blended(withFraction: 0.5, of: .white) ?? liq).setStroke()
                let m = NSBezierPath()
                m.move(to: NSPoint(x: fillRect.minX, y: fillRect.maxY))
                m.line(to: NSPoint(x: fillRect.maxX, y: fillRect.maxY))
                m.lineWidth = 1
                m.stroke()
                NSGraphicsContext.restoreGraphicsState()
            }

            // Outline.
            NSColor(white: 0.88, alpha: 1).setStroke()
            bodyPath.lineWidth = 1.2
            bodyPath.stroke()
            return true
        }
        img.isTemplate = false
        return img
    }
}

// ---------------------------------------------------------------------------
//  Telemetry client: keeps a live Lightstreamer streaming session open via
//  URLSession async bytes and publishes the latest urine-tank percentage.
// ---------------------------------------------------------------------------
final class Tracker {
    private let lock = NSLock()
    private var _percent = 0.0
    private var _hasData = false
    private var _conn = "connecting"
    private var _lastUpdate = Date.distantPast

    var percent: Double  { lock.lock(); defer { lock.unlock() }; return _percent }
    var hasData: Bool    { lock.lock(); defer { lock.unlock() }; return _hasData }
    var conn: String     { lock.lock(); defer { lock.unlock() }; return _conn }
    var lastUpdate: Date { lock.lock(); defer { lock.unlock() }; return _lastUpdate }

    private let server = "https://push.lightstreamer.com"
    private let cid = "mgQkwtwdysogQz2BJ4Ji kOj2Bg"  // standard public client id
    private let item = "NODE3000005"                 // Urine Tank Qty (%)

    private var loopTask: Task<Void, Never>?
    private var sessionTask: Task<Void, Error>?

    func start() {
        loopTask = Task { [weak self] in await self?.runLoop() }
    }

    func stop() {
        loopTask?.cancel()
        sessionTask?.cancel()
    }

    /// Force a fresh session (and snapshot) by cancelling the current one.
    func refreshNow() { sessionTask?.cancel() }

    private func setValue(_ pct: Double) {
        lock.lock(); _percent = pct; _hasData = true; _lastUpdate = Date(); lock.unlock()
    }
    private func setConn(_ s: String) { lock.lock(); _conn = s; lock.unlock() }

    private func runLoop() async {
        var backoff: UInt64 = 2
        while !Task.isCancelled {
            do {
                setConn("connecting")
                let t = Task { try await self.session() }
                sessionTask = t
                try await t.value
                backoff = 2
            } catch {
                setConn("offline")
            }
            if Task.isCancelled { break }
            try? await Task.sleep(nanoseconds: backoff * 1_000_000_000)
            backoff = min(backoff * 2, 30)
        }
    }

    private static func form(_ s: String) -> Data? { s.data(using: .ascii) }

    private static func enc(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s
    }

    private func session() async throws {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = TimeInterval.infinity
        let urlSession = URLSession(configuration: cfg)

        // 1) create_session — streaming connection stays open and pushes data.
        var req = URLRequest(url: URL(string: "\(server)/lightstreamer/create_session.txt?LS_protocol=TLCP-2.1.0")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Tracker.form("LS_cid=\(Tracker.enc(cid))&LS_adapter_set=ISSLIVE&LS_send_sync=false&LS_polling=false")

        let (bytes, response) = try await urlSession.bytes(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        var sessionId: String? = nil
        var controlLink = server
        var fields: [String?] = [nil, nil] // [TimeStamp, Value]

        for try await line in bytes.lines {
            if Task.isCancelled { return }

            if sessionId == nil {
                if line.hasPrefix("CONOK,") {
                    let p = line.components(separatedBy: ",")
                    sessionId = p.count > 1 ? p[1] : nil
                    if p.count > 4, p[4] != "*", !p[4].isEmpty { controlLink = "https://\(p[4])" }
                    setConn("live")
                    if let sid = sessionId {
                        let link = controlLink
                        // Fire the subscribe control request concurrently.
                        Task { try? await self.subscribe(urlSession: urlSession, controlLink: link, sessionId: sid) }
                    }
                } else if line.hasPrefix("CONERR") {
                    throw URLError(.userAuthenticationRequired)
                }
                continue
            }

            // Data lines: U,<sub>,<item>,<value-payload>
            if line.hasPrefix("U,") {
                let parts = splitMax4(line)
                if parts.count == 4 {
                    applyDelta(&fields, parts[3])
                    if let v = fields[1], let d = Double(v) {
                        setValue(max(0, min(100, d)))
                    }
                }
            } else if line.hasPrefix("LOOP") || line.hasPrefix("END") {
                return // server asked us to rebind -> reconnect
            }
        }
    }

    private func subscribe(urlSession: URLSession, controlLink: String, sessionId: String) async throws {
        var req = URLRequest(url: URL(string: "\(controlLink)/lightstreamer/control.txt?LS_protocol=TLCP-2.1.0")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let ctrl = "LS_session=\(Tracker.enc(sessionId))"
            + "&LS_op=add&LS_subId=1&LS_reqId=1&LS_mode=MERGE"
            + "&LS_group=\(item)"
            + "&LS_schema=\(Tracker.enc("TimeStamp Value"))"
            + "&LS_data_adapter=DEFAULT&LS_snapshot=true&LS_requested_max_frequency=1"
        req.httpBody = Tracker.form(ctrl)
        _ = try await urlSession.data(for: req)
    }

    /// Split "U,1,1,payload" into 4 parts, keeping commas inside the payload.
    private func splitMax4(_ line: String) -> [String] {
        var out: [String] = []
        var rest = Substring(line)
        for _ in 0..<3 {
            if let idx = rest.firstIndex(of: ",") {
                out.append(String(rest[..<idx]))
                rest = rest[rest.index(after: idx)...]
            } else { break }
        }
        out.append(String(rest))
        return out
    }

    /// Lightstreamer MERGE delta decoding for the "a|b|..." value payload.
    private func applyDelta(_ last: inout [String?], _ payload: String) {
        let parts = payload.components(separatedBy: "|")
        var idx = 0
        for f in parts {
            if idx >= last.count { break }
            if f.isEmpty { idx += 1; continue }                 // unchanged
            if f.hasPrefix("^") { if let n = Int(f.dropFirst()) { idx += n }; continue }
            if f == "#" { last[idx] = nil; idx += 1; continue }  // null
            if f == "$" { last[idx] = ""; idx += 1; continue }   // empty
            last[idx] = f.removingPercentEncoding ?? f
            idx += 1
        }
    }
}

// ---------------------------------------------------------------------------
//  Menu-bar application.
// ---------------------------------------------------------------------------
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let tracker = Tracker()
    private var timer: Timer?
    private var headerItem: NSMenuItem!
    private var detailItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let menu = NSMenu()
        headerItem = NSMenuItem(title: "ISS PISS-O-METER", action: nil, keyEquivalent: "")
        detailItem = NSMenuItem(title: "connecting…", action: nil, keyEquivalent: "")
        menu.addItem(headerItem)
        menu.addItem(detailItem)
        menu.addItem(.separator())
        let refresh = NSMenuItem(title: "Refresh now", action: #selector(refreshNow), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit ISS PISS-O-METER", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu

        updateUI()
        tracker.start()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateUI()
        }
    }

    private func updateUI() {
        let has = tracker.hasData
        let pct = tracker.percent
        let rounded = Int(pct.rounded())

        if let button = statusItem.button {
            button.image = TankArt.image(percent: pct, hasData: has, size: NSSize(width: 14, height: 17))
            button.imagePosition = .imageLeading
            button.font = NSFont.menuBarFont(ofSize: 0)
            button.title = has ? " \(rounded)%" : " —"
            button.toolTip = has
                ? "ISS urine tank: \(rounded)% (\(TankArt.status(pct, true)))"
                : "ISS PISS-O-METER — \(tracker.conn)"
        }

        headerItem.title = has ? "Urine Tank: \(rounded)%" : "ISS PISS-O-METER"
        if has {
            let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
            detailItem.title = "\(TankArt.status(pct, true)) · updated \(f.string(from: tracker.lastUpdate))"
        } else {
            detailItem.title = "feed: \(tracker.conn)"
        }
    }

    @objc private func refreshNow() { tracker.refreshNow() }

    @objc private func quit() {
        tracker.stop()
        NSApp.terminate(nil)
    }
}

// ---------------------------------------------------------------------------
//  Entry point (top-level code; runs under `swift IssPissOMeter.swift`).
// ---------------------------------------------------------------------------
let app = NSApplication.shared
app.setActivationPolicy(.accessory)        // menu-bar accessory, no Dock icon
let delegate = AppDelegate()
app.delegate = delegate
app.run()
