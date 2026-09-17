import AppKit
import ApplicationServices
import Network

struct RefreshInterval: Equatable {
    let title: String
    let seconds: TimeInterval
}

/// Outcome of the Sure sync stage.
///
/// A dedicated type rather than prefix-matching `lastSureSyncResultText`: the
/// UI string is presentation, and visualState already shows what happens when
/// control flow depends on it. These names are exported as metric label values,
/// so they are API — do not rename them without updating any alert rule.
enum SureSyncState: String {
    case unknown          // never run this session (e.g. just after a restart)
    case syncing
    case ok
    case failed           // real failure: retried and still broken
    case notConfigured    = "not_configured"   // sure-monmon exit 2 — steady state
    case notInstalled     = "not_installed"    // binary absent — steady state

    static let allCases: [SureSyncState] =
        [.unknown, .syncing, .ok, .failed, .notConfigured, .notInstalled]
}

enum RefreshVisualState {
    case idle
    case refreshing
    case syncing
    case success
    case failure
}

// ─── Settings ────────────────────────────────────────────────────────────────

final class SettingsStore {
    private let envFilePath: String

    struct EnvConfig {
        var actualURL: String
        var actualPassword: String
        var actualSyncId: String
        var actualAccountId: String
        var ollamaURL: String
        var ollamaModel: String
        var dnsServer: String
        var metricsPort: String
    }

    init(scriptDir: String) {
        envFilePath = "\(scriptDir)/.env"
    }

    func load() -> EnvConfig {
        var config = EnvConfig(
            actualURL: "", actualPassword: "", actualSyncId: "", actualAccountId: "",
            ollamaURL: "http://localhost:11434", ollamaModel: "gemma4:26b-mlx", dnsServer: "",
            metricsPort: "9100"
        )

        guard let contents = try? String(contentsOfFile: envFilePath, encoding: .utf8) else {
            return config
        }

        for line in contents.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"),
                  let eqIdx = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[trimmed.startIndex..<eqIdx]).trimmingCharacters(in: .whitespaces)
            let val = String(trimmed[trimmed.index(after: eqIdx)...]).trimmingCharacters(in: .whitespaces)
            switch key {
            case "ACTUAL_URL": config.actualURL = val
            case "ACTUAL_PASSWORD": config.actualPassword = val
            case "ACTUAL_SYNC_ID": config.actualSyncId = val
            case "ACTUAL_ACCOUNT_ID": config.actualAccountId = val
            case "OLLAMA_URL": config.ollamaURL = val
            case "OLLAMA_MODEL": config.ollamaModel = val
            case "DNS_SERVER": config.dnsServer = val
            case "METRICS_PORT": config.metricsPort = val
            default: break
            }
        }
        return config
    }

    func save(_ config: EnvConfig) {
        let lines = [
            "ACTUAL_URL=\(config.actualURL)",
            "ACTUAL_PASSWORD=\(config.actualPassword)",
            "ACTUAL_SYNC_ID=\(config.actualSyncId)",
            "ACTUAL_ACCOUNT_ID=\(config.actualAccountId)",
            "OLLAMA_URL=\(config.ollamaURL)",
            "OLLAMA_MODEL=\(config.ollamaModel)",
            "DNS_SERVER=\(config.dnsServer)",
            "METRICS_PORT=\(config.metricsPort)",
        ]
        try? lines.joined(separator: "\n").appending("\n").write(toFile: envFilePath, atomically: true, encoding: .utf8)
    }
}

final class SettingsWindowController {
    private var window: NSWindow?
    private let store: SettingsStore

    // Fields
    private let actualURLField = NSTextField()
    private let actualPasswordField = NSSecureTextField()
    private let actualSyncIdField = NSTextField()
    private let actualAccountIdField = NSTextField()
    private let ollamaURLField = NSTextField()
    private let ollamaModelField = NSTextField()
    private let dnsServerField = NSTextField()
    private let metricsPortField = NSTextField()
    private let statusLabel = NSTextField(labelWithString: "")

    init(store: SettingsStore) {
        self.store = store
    }

    func show() {
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 460),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        w.title = "Settings"
        w.center()
        w.isReleasedWhenClosed = false

        let content = NSView(frame: w.contentView!.bounds)
        content.autoresizingMask = [.width, .height]
        w.contentView = content

        var y: CGFloat = 425

        func addSection(_ title: String) {
            let label = NSTextField(labelWithString: title)
            label.font = .boldSystemFont(ofSize: 13)
            label.frame = NSRect(x: 20, y: y, width: 480, height: 20)
            content.addSubview(label)
            y -= 30
        }

        func addRow(_ title: String, field: NSTextField, secure: Bool = false) {
            let label = NSTextField(labelWithString: title)
            label.frame = NSRect(x: 20, y: y, width: 150, height: 22)
            label.alignment = .right
            content.addSubview(label)

            field.frame = NSRect(x: 180, y: y, width: 320, height: 22)
            field.isEditable = true
            field.isBezeled = true
            field.bezelStyle = .roundedBezel
            field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            content.addSubview(field)
            y -= 30
        }

        addSection("Actual Budget")
        addRow("Server URL", field: actualURLField)
        addRow("Password", field: actualPasswordField, secure: true)
        addRow("Sync ID", field: actualSyncIdField)
        addRow("Account ID", field: actualAccountIdField)

        y -= 10
        addSection("Ollama (AI Categorizer)")
        addRow("Ollama URL", field: ollamaURLField)
        addRow("Model", field: ollamaModelField)

        y -= 10
        addSection("Advanced")
        addRow("DNS Server", field: dnsServerField)
        addRow("Metrics Port", field: metricsPortField)

        y -= 15
        statusLabel.frame = NSRect(x: 20, y: y, width: 300, height: 20)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 11)
        content.addSubview(statusLabel)

        let saveButton = NSButton(title: "Save", target: self, action: #selector(save))
        saveButton.frame = NSRect(x: 410, y: y - 3, width: 90, height: 28)
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        content.addSubview(saveButton)

        let testButton = NSButton(title: "Test", target: self, action: #selector(testConnection))
        testButton.frame = NSRect(x: 320, y: y - 3, width: 80, height: 28)
        testButton.bezelStyle = .rounded
        content.addSubview(testButton)

        // Load current values
        let config = store.load()
        actualURLField.stringValue = config.actualURL
        actualPasswordField.stringValue = config.actualPassword
        actualSyncIdField.stringValue = config.actualSyncId
        actualAccountIdField.stringValue = config.actualAccountId
        ollamaURLField.stringValue = config.ollamaURL
        ollamaModelField.stringValue = config.ollamaModel
        dnsServerField.stringValue = config.dnsServer
        metricsPortField.stringValue = config.metricsPort

        self.window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func save() {
        let config = SettingsStore.EnvConfig(
            actualURL: actualURLField.stringValue,
            actualPassword: actualPasswordField.stringValue,
            actualSyncId: actualSyncIdField.stringValue,
            actualAccountId: actualAccountIdField.stringValue,
            ollamaURL: ollamaURLField.stringValue,
            ollamaModel: ollamaModelField.stringValue,
            dnsServer: dnsServerField.stringValue,
            metricsPort: metricsPortField.stringValue
        )
        store.save(config)
        statusLabel.stringValue = "Saved"
        statusLabel.textColor = .systemGreen
    }

    @objc private func testConnection() {
        statusLabel.stringValue = "Testing..."
        statusLabel.textColor = .secondaryLabelColor

        DispatchQueue.global(qos: .userInitiated).async { [self] in
            var results: [String] = []

            // Test Ollama
            let ollamaOk = Self.httpGet("\(ollamaURLField.stringValue)/api/tags", timeout: 5)
            results.append(ollamaOk ? "Ollama: OK" : "Ollama: unreachable")

            // Test Actual Budget (via curl for DNS)
            let abOk = Self.curlTest(actualURLField.stringValue + "/info")
            results.append(abOk ? "Actual Budget: OK" : "Actual Budget: unreachable")

            DispatchQueue.main.async {
                let allOk = ollamaOk && abOk
                self.statusLabel.stringValue = results.joined(separator: "  |  ")
                self.statusLabel.textColor = allOk ? .systemGreen : .systemOrange
            }
        }
    }

    private static func httpGet(_ urlString: String, timeout: TimeInterval) -> Bool {
        guard let url = URL(string: urlString) else { return false }
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        let session = URLSession(configuration: config)
        session.dataTask(with: url) { _, response, _ in
            ok = (response as? HTTPURLResponse)?.statusCode == 200
            sem.signal()
        }.resume()
        sem.wait()
        return ok
    }

    private static func curlTest(_ urlString: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = ["-sf", "--connect-timeout", "5", urlString]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}

// ─── Metrics Snapshot ────────────────────────────────────────────────────────

/// Thread-safe copy of the controller state that the metrics server serves.
///
/// The scrape path MUST NOT touch the main queue. Prometheus scrapes /metrics
/// every 60s from the cluster; when formatMetrics() blocked on
/// `DispatchQueue.main.sync`, any main-thread stall (a modal menu, a slow
/// redraw, a spinning UI) would stall the scrape, drop `bank_refresh_up` to 0
/// and fire BankRefreshDown for a perfectly healthy app. That couples "the UI
/// is busy" to "monitoring says the app is down" — a false-signal class worth
/// designing out rather than tuning around.
///
/// The controller writes this on every state change; the metrics server reads
/// it under the same lock. Neither side ever waits on the other's queue.
final class MetricsSnapshot {
    struct Value {
        var lastSuccess: TimeInterval = 0
        var lastRefresh: TimeInterval = 0
        var duration: TimeInterval = 0
        var stateName: String = "idle"
        var sureStateName: String = SureSyncState.unknown.rawValue
        var sureLastSuccess: TimeInterval = 0
    }

    private let lock = NSLock()
    private var value = Value()

    func update(_ newValue: Value) {
        lock.lock()
        defer { lock.unlock() }
        value = newValue
    }

    func read() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

// ─── Refresh Controller ──────────────────────────────────────────────────────

final class RefreshController {
    private let defaults = UserDefaults.standard
    private let intervalKey = "refreshIntervalSeconds"
    private let intervals = [
        RefreshInterval(title: "15 min", seconds: 15 * 60),
        RefreshInterval(title: "2 h", seconds: 2 * 60 * 60),
        RefreshInterval(title: "6 h", seconds: 6 * 60 * 60),
        RefreshInterval(title: "12 h", seconds: 12 * 60 * 60),
    ]

    /// Read by MetricsServer on the scrape queue — never via the main queue.
    let metricsSnapshot = MetricsSnapshot()

    private var timer: Timer?
    private(set) var isBusy = false
    private(set) var currentPhase = "Idle" // "Refreshing...", "Syncing...", "Syncing to Sure...", "Categorizing..."
    private(set) var lastRefreshDate: Date?
    private(set) var lastSyncDate: Date?
    private(set) var lastResultText = "Idle"
    private(set) var lastSyncResultText = "Idle"
    private(set) var lastSureSyncResultText = "Idle"
    private(set) var sureSyncState: SureSyncState = .unknown
    private(set) var lastSureSyncSuccessDate: Date?
    private(set) var lastDurationSeconds: TimeInterval = 0
    private(set) var lastSuccessDate: Date?
    private var refreshStartTime: Date?

    var onStatusChange: (() -> Void)?

    /// Single funnel for state changes: refresh the metrics snapshot, then tell
    /// the UI. Anything that mutates observable state must go through here, or
    /// the exported metrics silently drift from reality.
    private func notifyStatusChanged() {
        metricsSnapshot.update(MetricsSnapshot.Value(
            lastSuccess: lastSuccessDate?.timeIntervalSince1970 ?? 0,
            lastRefresh: lastRefreshDate?.timeIntervalSince1970 ?? 0,
            duration: lastDurationSeconds,
            stateName: visualStateName,
            sureStateName: sureSyncState.rawValue,
            sureLastSuccess: lastSureSyncSuccessDate?.timeIntervalSince1970 ?? 0
        ))
        onStatusChange?()
    }

    var selectedInterval: RefreshInterval {
        let storedValue = defaults.double(forKey: intervalKey)
        return intervals.first(where: { $0.seconds == storedValue }) ?? intervals[1]
    }

    func allIntervals() -> [RefreshInterval] {
        intervals
    }

    var nextScheduledRefreshDate: Date? {
        timer?.fireDate
    }

    var visualState: RefreshVisualState {
        if isBusy && currentPhase == "Refreshing..." {
            return .refreshing
        }

        if isBusy {
            return .syncing
        }

        if lastResultText == "Success" && !lastSyncResultText.hasPrefix("Sync failed") && !lastSyncResultText.hasPrefix("Categorize failed") {
            return .success
        }

        if lastResultText.hasPrefix("Failed:") || lastSyncResultText.hasPrefix("Sync failed") || lastSyncResultText.hasPrefix("Categorize failed") {
            return .failure
        }

        return .idle
    }

    var visualStateName: String {
        switch visualState {
        case .idle: return "idle"
        case .refreshing: return "refreshing"
        case .syncing: return "syncing"
        case .success: return "success"
        case .failure: return "failure"
        }
    }

    func start() {
        swiftLog("app start — build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?")")
        logPermissionDiagnostics()
        scheduleTimer()
        notifyStatusChanged()
    }

    func updateInterval(_ interval: RefreshInterval) {
        defaults.set(interval.seconds, forKey: intervalKey)
        scheduleTimer()
        notifyStatusChanged()
    }

    func refreshNow() {
        guard !isBusy else { return }

        isBusy = true
        currentPhase = "Refreshing..."
        lastResultText = "Refreshing..."
        notifyStatusChanged()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            self.doRefreshSyncCategorize()
        }
    }

    func syncNow() {
        guard !isBusy else { return }

        isBusy = true
        currentPhase = "Syncing..."
        lastSyncResultText = "Syncing..."
        notifyStatusChanged()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            self.doSyncCategorize()
        }
    }

    private func doRefreshSyncCategorize() {
        swiftLog("=== cycle start ===")
        refreshStartTime = Date()
        let refreshResult = runAppleScript()

        DispatchQueue.main.sync {
            lastRefreshDate = Date()
            lastResultText = refreshResult
            notifyStatusChanged()
        }

        guard refreshResult == "Success" else {
            DispatchQueue.main.sync { isBusy = false; notifyStatusChanged() }
            return
        }

        doSyncCategorize()
    }

    private func doSyncCategorize() {
        DispatchQueue.main.sync {
            currentPhase = "Syncing..."
            lastSyncResultText = "Syncing..."
            notifyStatusChanged()
        }

        let syncResult = runSync()

        guard syncResult == "Success" else {
            DispatchQueue.main.sync {
                isBusy = false
                lastSyncDate = Date()
                lastSyncResultText = syncResult
                notifyStatusChanged()
            }
            return
        }

        DispatchQueue.main.sync {
            currentPhase = "Syncing to Sure..."
            lastSureSyncResultText = "Syncing..."
            sureSyncState = .syncing
            notifyStatusChanged()
        }

        let sureResult = runSureSync()

        DispatchQueue.main.sync {
            lastSureSyncResultText = sureResult.text
            sureSyncState = sureResult.state
            if sureResult.state == .ok { lastSureSyncSuccessDate = Date() }
            notifyStatusChanged()
        }

        DispatchQueue.main.sync {
            currentPhase = "Categorizing..."
            lastSyncResultText = "Categorizing..."
            notifyStatusChanged()
        }

        let catResult = runCategorize()

        DispatchQueue.main.sync {
            isBusy = false
            lastSyncDate = Date()
            lastSyncResultText = catResult
            if let start = refreshStartTime {
                lastDurationSeconds = Date().timeIntervalSince(start)
            }
            if catResult == "Success" {
                lastSuccessDate = Date()
            }
            notifyStatusChanged()
        }
    }

    private func scheduleTimer() {
        timer?.invalidate()

        let interval = selectedInterval.seconds
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.refreshNow()
        }
    }

    private func runAppleScript() -> String {
        swiftLog("runAppleScript start")

        guard let scriptURL = Bundle.main.url(forResource: "refresh-moneymoney", withExtension: "applescript") else {
            // NOTE: this previously returned "Missing bundled AppleScript", which
            // has no "Failed:" prefix, so visualState fell through to .idle — a
            // broken bundle reported itself as healthy.
            swiftLog("runAppleScript FAILED: bundled AppleScript resource missing")
            return "Failed: bundled AppleScript missing"
        }

        do {
            let source = try String(contentsOf: scriptURL, encoding: .utf8)
            var errorInfo: NSDictionary?
            let script = NSAppleScript(source: source)
            let started = Date()
            script?.executeAndReturnError(&errorInfo)
            let elapsed = Date().timeIntervalSince(started)

            if let errorInfo {
                // Log the WHOLE error, not just describe()'s message+number. The
                // errorNumber is what separates a TCC denial from a missing menu
                // item from a timeout, and discarding it is why this stage could
                // not say why it failed.
                let number = errorInfo[NSAppleScript.errorNumber] as? Int ?? 0
                let message = errorInfo[NSAppleScript.errorMessage] as? String ?? ""
                let brief = errorInfo[NSAppleScript.errorBriefMessage] as? String ?? ""
                let appName = errorInfo[NSAppleScript.errorAppName] as? String ?? ""
                swiftLog("runAppleScript FAILED after \(String(format: "%.1f", elapsed))s "
                    + "errorNumber=\(number) app=\(appName) brief=\(brief) message=\(message)")
                swiftLog("runAppleScript hint: \(Self.appleScriptHint(for: number))")
                logPermissionDiagnostics()
                return "Failed: \(describe(errorInfo))"
            }

            swiftLog("runAppleScript OK in \(String(format: "%.1f", elapsed))s")
            return "Success"
        } catch {
            swiftLog("runAppleScript FAILED to read script: \(error.localizedDescription)")
            return "Failed: \(error.localizedDescription)"
        }
    }

    /// Plain-language meaning of the common AppleScript/Apple Event errors this
    /// pipeline can hit, so the log says what to DO rather than just a number.
    private static func appleScriptHint(for number: Int) -> String {
        switch number {
        case -1743:
            return "TCC Automation DENIED. The app is ad-hoc signed, so replacing the bundle revokes it. "
                + "Fix: System Settings > Privacy & Security > Automation > RefreshMoneyMoney, re-enable MoneyMoney + System Events."
        case -1744:
            return "TCC consent not yet given — macOS wants to prompt. Trigger one refresh manually and approve the dialog."
        case -600:
            return "Target application not running."
        case -1728:
            return "Object not found: the menu item/menu/process did not resolve. Causes: MoneyMoney UI not in English, "
                + "a modal dialog (password/TAN) covering the menu, or Accessibility permission missing so the process tree is invisible."
        case -1719:
            return "Index out of range (e.g. 'menu bar 1' absent) — usually Accessibility permission missing."
        case -1712:
            return "Apple event timed out — MoneyMoney was busy or blocked on a dialog."
        case -25211:
            return "Accessibility API disabled for this app. Fix: System Settings > Privacy & Security > Accessibility."
        case -10004:
            return "Privilege violation sending the Apple event."
        case 0:
            return "no error number reported"
        default:
            return "unmapped AppleScript error \(number)"
        }
    }

    /// Reports the macOS privacy (TCC) status for everything the refresh script
    /// touches, WITHOUT sending an Apple event and WITHOUT prompting:
    /// `AXIsProcessTrusted()` and `AEDeterminePermissionToAutomateTarget(...,
    /// askUserIfNeeded: false)` are pure status reads, so this is safe to run
    /// unattended and can never raise a dialog on the operator's desktop.
    ///
    /// This matters because the app is ad-hoc signed (no Team ID): TCC keys on
    /// the code identity, so rebuilding and replacing the bundle silently
    /// revokes these grants.
    ///
    /// Deliberately only `AXIsProcessTrusted()`, which is a pure, immediate,
    /// non-prompting status read. An earlier version also probed Apple Event
    /// (Automation) permission via AEDeterminePermissionToAutomateTarget with
    /// askUserIfNeeded:false — that does not prompt, but it BLOCKS
    /// indefinitely, and calling it from start() hung the app before the
    /// metrics server existed. The Automation cases are reported by the
    /// -1743/-1744 hints above when they actually occur, which costs nothing
    /// and cannot hang.
    func logPermissionDiagnostics() {
        swiftLog("permissions: Accessibility (AXIsProcessTrusted) = \(AXIsProcessTrusted() ? "GRANTED" : "DENIED")")
    }

    private lazy var nodeBinDir: String = {
        let candidates = [
            "\(NSHomeDirectory())/.local/share/mise/installs/node/\(Self.findMiseNodeVersion(scriptDir: scriptDir))/bin",
            "/usr/local/bin",
            "/opt/homebrew/bin",
        ]
        return candidates.first { FileManager.default.fileExists(atPath: "\($0)/node") }
            ?? "/usr/local/bin"
    }()

    private static func findMiseNodeVersion(scriptDir: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/mise")
        process.arguments = ["which", "node"]
        // Run mise from the project dir so it picks up .mise.toml
        process.currentDirectoryURL = URL(fileURLWithPath: scriptDir)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               let match = path.range(of: #"installs/node/([^/]+)"#, options: .regularExpression) {
                return String(path[match]).replacingOccurrences(of: "installs/node/", with: "")
            }
        } catch {}
        return "latest"
    }

    lazy var scriptDir: String = {
        let candidates = [
            Bundle.main.bundlePath.replacingOccurrences(of: "/RefreshMoneyMoney.app", with: ""),
            "\(NSHomeDirectory())/code/bank-refresh",
        ]
        return candidates.first { FileManager.default.fileExists(atPath: "\($0)/categorize-transactions.mjs") }
            ?? "\(NSHomeDirectory())/code/bank-refresh"
    }()

    private func swiftLog(_ msg: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "[\(ts)] [SWIFT] \(msg)\n"
        let logPath = "\(scriptDir)/.categorizer/swift-debug.log"
        try? FileManager.default.createDirectory(atPath: "\(scriptDir)/.categorizer", withIntermediateDirectories: true)
        if let handle = FileHandle(forWritingAtPath: logPath) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8)!)
            handle.closeFile()
        } else {
            FileManager.default.createFile(atPath: logPath, contents: line.data(using: .utf8))
        }
    }

    // ─── Transient-failure handling ──────────────────────────────────────────
    //
    // The sync stages below shell out to processes that talk to cluster-hosted
    // backends (Actual Budget and Sure, both behind the `internal` ingress).
    // A planned Kubernetes node roll takes those away for minutes at a time:
    // during the 2026-09-06 Talos roll the internal ingress controller was
    // rescheduled and had not published its ingress status for ~85s, and the
    // actual-budget Service had no active endpoint for a further 3m10s.
    //
    // A single-shot child process that lands in one of those windows exits
    // non-zero, which latches `visualState` to .failure until the next 2h tick
    // — that is exactly what tripped the BankRefreshFailing alert, ~1h45m of
    // "failure" for one unlucky second of scheduling.
    //
    // Fix: retry across a window wider than a node roll. This does NOT paper
    // over a real outage — a genuine provider/credential failure fails on every
    // attempt and is still reported, just ~4.5 min later than before. This
    // mirrors what categorize-transactions.mjs already does for its own Actual
    // Budget connect ("Connecting to Actual Budget (attempt 1/5)").
    private enum RetryPolicy {
        /// For a stage whose failure LATCHES the exported failure state, and so
        /// pages. Sum (275s) comfortably exceeds the 3m10s backend gap measured
        /// during a full three-node roll. Worth spending to avoid a false page.
        static let latching: [TimeInterval] = [5, 15, 45, 90, 120]

        /// For a stage that is ISOLATED by design. runSureSync's result is not
        /// read by visualState, so a Sure failure never reaches the metrics or
        /// the alert — it only costs data freshness until the next 2h cycle.
        /// Spending 275s per cycle to chase a persistently-down Sure would add
        /// ~4.5 min to every cycle for no signal. 65s still rides out the ~85s
        /// ingress convergence that caused the common case.
        static let isolated: [TimeInterval] = [5, 15, 45]
    }

    private struct StageResult {
        let status: Int32
        let stderr: String
    }

    /// Runs `binary args` once, capturing stderr so a failure is diagnosable.
    private func runStageOnce(label: String, binary: String, arguments: [String], attempt: Int) -> StageResult {
        let errPath = NSTemporaryDirectory() + "bank-refresh-\(label)-\(UUID().uuidString).err"
        FileManager.default.createFile(atPath: errPath, contents: nil)
        defer { try? FileManager.default.removeItem(atPath: errPath) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: scriptDir)

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "\(nodeBinDir):\(env["PATH"] ?? "/usr/bin:/bin")"
        process.environment = env

        process.standardOutput = FileHandle.nullDevice
        // stderr goes to a FILE, not a Pipe: waitUntilExit() with an undrained
        // Pipe deadlocks as soon as the child fills the 64K buffer.
        if let handle = FileHandle(forWritingAtPath: errPath) {
            process.standardError = handle
        } else {
            process.standardError = FileHandle.nullDevice
        }

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            swiftLog("\(label) attempt \(attempt + 1) failed to launch: \(error.localizedDescription)")
            return StageResult(status: -1, stderr: error.localizedDescription)
        }

        var tail = (try? String(contentsOfFile: errPath, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if tail.count > 500 { tail = String(tail.suffix(500)) }

        let status = process.terminationStatus
        swiftLog("\(label) attempt \(attempt + 1) exit=\(status)" + (tail.isEmpty ? "" : " stderr=\(tail)"))
        return StageResult(status: status, stderr: tail)
    }

    /// Runs a stage, retrying while `isRetryable(exitCode)` holds.
    private func runStage(
        label: String,
        binary: String,
        arguments: [String],
        backoff: [TimeInterval],
        isRetryable: (Int32) -> Bool
    ) -> StageResult {
        var attempt = 0
        while true {
            let result = runStageOnce(label: label, binary: binary, arguments: arguments, attempt: attempt)
            if result.status == 0 { return result }
            guard isRetryable(result.status), attempt < backoff.count else { return result }
            let delay = backoff[attempt]
            swiftLog("\(label) exit=\(result.status) treated as transient — retrying in \(Int(delay))s "
                + "(attempt \(attempt + 2)/\(backoff.count + 1))")
            Thread.sleep(forTimeInterval: delay)
            attempt += 1
        }
    }

    /// First line of a stderr blob, clipped for the menu bar.
    private func firstLine(_ text: String) -> String {
        guard let line = text.split(separator: "\n").first.map(String.init) else { return "" }
        return line.count > 120 ? String(line.prefix(120)) + "…" : line
    }

    private func runSync() -> String {
        swiftLog("runSync start, nodeBinDir=\(nodeBinDir), scriptDir=\(scriptDir)")
        let result = runStage(
            label: "runSync",
            binary: "\(nodeBinDir)/actual-monmon",
            arguments: ["import"],
            backoff: RetryPolicy.latching,
            // actual-monmon has no dedicated exit code for "backend unreachable",
            // so every non-zero exit is retried. A genuinely broken config fails
            // all 6 attempts and is still surfaced.
            isRetryable: { $0 != 0 }
        )

        guard result.status != 0 else { return "Success" }
        // NOTE: the "Sync failed" prefix is load-bearing — visualState matches on it.
        return result.stderr.isEmpty
            ? "Sync failed (exit \(result.status))"
            : "Sync failed (exit \(result.status)): \(firstLine(result.stderr))"
    }

    private func runSureSync() -> (text: String, state: SureSyncState) {
        swiftLog("runSureSync start")
        let sureBin = "\(nodeBinDir)/sure-monmon"
        guard FileManager.default.isExecutableFile(atPath: sureBin) else {
            swiftLog("runSureSync skipped: sure-monmon not installed at \(sureBin)")
            return ("Not installed", .notInstalled)
        }

        let result = runStage(
            label: "runSureSync",
            binary: sureBin,
            arguments: ["import"],
            // Isolated stage: short backoff on purpose (see RetryPolicy.isolated).
            backoff: RetryPolicy.isolated,
            // exit 2 is "not configured" — a config error, never transient.
            // Retrying it would just delay a report the operator needs now.
            isRetryable: { $0 != 0 && $0 != 2 }
        )

        switch result.status {
        case 0: return ("Success", .ok)
        case 2: return ("Not configured — run sure-monmon validate", .notConfigured)
        default:
            // NOTE: the "Sure sync failed" prefix is load-bearing for the UI.
            let text = result.stderr.isEmpty
                ? "Sure sync failed (exit \(result.status))"
                : "Sure sync failed (exit \(result.status)): \(firstLine(result.stderr))"
            return (text, .failed)
        }
    }
    private func runCategorize() -> String {
        swiftLog("runCategorize start")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "\(nodeBinDir)/node")
        process.arguments = ["\(scriptDir)/categorize-transactions.mjs"]
        process.currentDirectoryURL = URL(fileURLWithPath: scriptDir)

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "\(nodeBinDir):\(env["PATH"] ?? "/usr/bin:/bin")"
        // Suppress noisy @actual-app/api Breadcrumb output
        env["NODE_NO_WARNINGS"] = "1"
        process.environment = env

        // Discard stdout/stderr — results go to .categorizer/status.json and log
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                return "Success"
            } else {
                // Read error from status file instead of noisy pipe
                let statusPath = "\(scriptDir)/.categorizer/status.json"
                if let data = try? Data(contentsOf: URL(fileURLWithPath: statusPath)),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let lastError = json["lastError"] as? String, !lastError.isEmpty {
                    return "Categorize failed: \(lastError)"
                }
                return "Categorize failed (exit \(process.terminationStatus))"
            }
        } catch {
            return "Categorize failed: \(error.localizedDescription)"
        }
    }

    private func describe(_ errorInfo: NSDictionary) -> String {
        let message = errorInfo[NSAppleScript.errorMessage] as? String
        let number = errorInfo[NSAppleScript.errorNumber] as? Int

        if let message, let number {
            return "\(message) (\(number))"
        }

        if let message {
            return message
        }

        return "Unknown AppleScript error"
    }
}

// ─── Metrics Server ─────────────────────────────────────────────────────────

final class MetricsServer {
    /// A client that opens a socket and never completes a request must not pin
    /// that connection forever. Without this, connections leak one per probe.
    private static let requestTimeout: TimeInterval = 10
    /// Cap on request-header bytes so a client streaming junk cannot grow the
    /// read buffer without bound.
    private static let maxRequestBytes = 16 * 1024

    private var listener: NWListener?
    private let port: UInt16
    private let snapshot: MetricsSnapshot

    /// Takes the snapshot, NOT the controller — the scrape path then *cannot*
    /// reach main-thread-owned state, even by a later accident.
    init(port: UInt16, snapshot: MetricsSnapshot) {
        self.port = port
        self.snapshot = snapshot
    }

    func start() {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        let params = NWParameters.tcp
        guard let listener = try? NWListener(using: params, on: nwPort) else { return }
        self.listener = listener

        listener.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }
        listener.start(queue: .global(qos: .utility))
    }

    func stop() {
        listener?.cancel()
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .utility))

        let timeout = DispatchWorkItem { connection.cancel() }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + Self.requestTimeout, execute: timeout)

        receiveRequest(on: connection, accumulated: Data(), timeout: timeout)
    }

    /// An HTTP request can arrive split across TCP segments, so read until the
    /// end of the header block instead of assuming a single `receive` got all
    /// of it. The previous single-shot read 404'd on a segmented request.
    private func receiveRequest(on connection: NWConnection, accumulated: Data, timeout: DispatchWorkItem) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self else {
                timeout.cancel()
                connection.cancel()
                return
            }

            if error != nil {
                timeout.cancel()
                connection.cancel()
                return
            }

            var buffer = accumulated
            if let data { buffer.append(data) }

            // We serve GET only, so the headers are the whole request.
            if let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                timeout.cancel()
                self.respond(to: String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self), on: connection)
                return
            }

            if buffer.count > Self.maxRequestBytes {
                timeout.cancel()
                self.send(self.httpResponse(status: "431 Request Header Fields Too Large",
                                            contentType: "text/plain", body: "too large\n"),
                          on: connection)
                return
            }

            if isComplete {
                timeout.cancel()
                connection.cancel()
                return
            }

            self.receiveRequest(on: connection, accumulated: buffer, timeout: timeout)
        }
    }

    private func respond(to head: String, on connection: NWConnection) {
        // Parse the request LINE. The old `request.contains("GET /metrics")`
        // matched that string anywhere, including inside a header value.
        let requestLine = head.components(separatedBy: "\r\n").first ?? ""
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let method = parts.first ?? ""
        let target = parts.count > 1 ? parts[1] : ""
        let path = target.components(separatedBy: "?").first ?? target

        let response: String
        switch (method, path) {
        case ("GET", "/health"):
            response = httpResponse(status: "200 OK", contentType: "text/plain", body: "ok\n")
        case ("GET", "/metrics"):
            response = httpResponse(status: "200 OK",
                                    contentType: "text/plain; version=0.0.4; charset=utf-8",
                                    body: formatMetrics())
        case ("GET", _):
            response = httpResponse(status: "404 Not Found", contentType: "text/plain", body: "not found\n")
        default:
            response = httpResponse(status: "405 Method Not Allowed",
                                    contentType: "text/plain", body: "method not allowed\n")
        }

        send(response, on: connection)
    }

    private func send(_ response: String, on connection: NWConnection) {
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func httpResponse(status: String, contentType: String, body: String) -> String {
        "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
    }

    private func formatMetrics() -> String {
        // Lock-protected snapshot read. Never touches the main queue, so a
        // stalled UI can no longer make monitoring report the app as down.
        let current = snapshot.read()

        var lines: [String] = []

        lines.append("# HELP bank_refresh_up Whether the bank-refresh app is running.")
        lines.append("# TYPE bank_refresh_up gauge")
        lines.append("bank_refresh_up 1")

        lines.append("# HELP bank_refresh_last_success_timestamp_seconds Unix timestamp of last successful refresh.")
        lines.append("# TYPE bank_refresh_last_success_timestamp_seconds gauge")
        lines.append("bank_refresh_last_success_timestamp_seconds \(Int(current.lastSuccess))")

        lines.append("# HELP bank_refresh_last_refresh_timestamp_seconds Unix timestamp of last refresh attempt.")
        lines.append("# TYPE bank_refresh_last_refresh_timestamp_seconds gauge")
        lines.append("bank_refresh_last_refresh_timestamp_seconds \(Int(current.lastRefresh))")

        lines.append("# HELP bank_refresh_duration_seconds Duration of last refresh cycle.")
        lines.append("# TYPE bank_refresh_duration_seconds gauge")
        lines.append("bank_refresh_duration_seconds \(String(format: "%.3f", current.duration))")

        lines.append("# HELP bank_refresh_state Current state of the refresh controller.")
        lines.append("# TYPE bank_refresh_state gauge")
        for state in ["idle", "refreshing", "syncing", "success", "failure"] {
            let val = state == current.stateName ? 1 : 0
            lines.append("bank_refresh_state{state=\"\(state)\"} \(val)")
        }

        // Sure sync is ISOLATED by design (62e7e0a): its failure must not fail the
        // pipeline or block the Actual sync / categorization, and so it is absent
        // from bank_refresh_state. Isolated must not mean invisible, hence its own
        // state set. Steady states (not_configured / not_installed) are modelled
        // distinctly from failed so an alert can ignore them.
        lines.append("# HELP bank_refresh_sure_sync_state Current state of the Sure sync stage.")
        lines.append("# TYPE bank_refresh_sure_sync_state gauge")
        for state in SureSyncState.allCases {
            let val = state.rawValue == current.sureStateName ? 1 : 0
            lines.append("bank_refresh_sure_sync_state{state=\"\(state.rawValue)\"} \(val)")
        }

        lines.append("# HELP bank_refresh_sure_sync_last_success_timestamp_seconds Unix timestamp of last successful Sure sync.")
        lines.append("# TYPE bank_refresh_sure_sync_last_success_timestamp_seconds gauge")
        lines.append("bank_refresh_sure_sync_last_success_timestamp_seconds \(Int(current.sureLastSuccess))")

        lines.append("")
        return lines.joined(separator: "\n")
    }
}

// ─── App Delegate ────────────────────────────────────────────────────────────

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller = RefreshController()
    private var metricsServer: MetricsServer?
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()

    private let statusMenuItem = NSMenuItem(title: "Status: Idle", action: nil, keyEquivalent: "")
    private let lastRefreshMenuItem = NSMenuItem(title: "Last refresh: Never", action: nil, keyEquivalent: "")
    private let syncStatusMenuItem = NSMenuItem(title: "Sync: Idle", action: nil, keyEquivalent: "")
    private let sureStatusMenuItem = NSMenuItem(title: "Sure: Idle", action: nil, keyEquivalent: "")
    private let lastSyncMenuItem = NSMenuItem(title: "Last sync: Never", action: nil, keyEquivalent: "")
    private let nextRefreshMenuItem = NSMenuItem(title: "Next refresh: Waiting for timer", action: nil, keyEquivalent: "")
    private let refreshNowMenuItem = NSMenuItem(title: "Refresh now", action: #selector(refreshNow), keyEquivalent: "r")
    private let syncNowMenuItem = NSMenuItem(title: "Sync now", action: #selector(syncNow), keyEquivalent: "s")
    private let intervalMenuItem = NSMenuItem(title: "Refresh interval", action: nil, keyEquivalent: "")
    private let intervalSubmenu = NSMenu()

    private lazy var settingsController = SettingsWindowController(
        store: SettingsStore(scriptDir: controller.scriptDir)
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureStatusItem()
        configureMenu()

        controller.onStatusChange = { [weak self] in
            self?.updateMenu()
        }

        // Start the exporter BEFORE the controller. Monitoring must not be
        // hostage to anything in controller startup: when a startup probe once
        // blocked here, controller.start() never returned, the metrics server
        // was never created, and a healthy-but-stalled app went dark to
        // Prometheus instead of reporting its state.
        let config = SettingsStore(scriptDir: controller.scriptDir).load()
        let metricsPort = UInt16(config.metricsPort) ?? 9100
        metricsServer = MetricsServer(port: metricsPort, snapshot: controller.metricsSnapshot)
        metricsServer?.start()

        controller.start()
        updateMenu()
    }

    @objc private func refreshNow() {
        controller.refreshNow()
    }

    @objc private func syncNow() {
        controller.syncNow()
    }

    @objc private func openSettings() {
        settingsController.show()
    }

    @objc private func selectInterval(_ sender: NSMenuItem) {
        let availableIntervals = controller.allIntervals()

        guard sender.tag < availableIntervals.count else {
            return
        }

        controller.updateInterval(availableIntervals[sender.tag])
    }

    @objc private func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func configureStatusItem() {
        if let button = statusItem.button {
            button.imagePosition = .imageOnly
            button.title = ""
        }
        statusItem.menu = menu
        updateStatusIcon()
    }

    private func configureMenu() {
        statusMenuItem.isEnabled = false
        lastRefreshMenuItem.isEnabled = false
        syncStatusMenuItem.isEnabled = false
        sureStatusMenuItem.isEnabled = false
        lastSyncMenuItem.isEnabled = false
        nextRefreshMenuItem.isEnabled = false

        menu.addItem(statusMenuItem)
        menu.addItem(lastRefreshMenuItem)
        menu.addItem(syncStatusMenuItem)
        menu.addItem(sureStatusMenuItem)
        menu.addItem(lastSyncMenuItem)
        menu.addItem(nextRefreshMenuItem)
        menu.addItem(.separator())
        refreshNowMenuItem.target = self
        menu.addItem(refreshNowMenuItem)
        syncNowMenuItem.target = self
        menu.addItem(syncNowMenuItem)

        intervalMenuItem.submenu = intervalSubmenu
        menu.addItem(intervalMenuItem)

        for (index, interval) in controller.allIntervals().enumerated() {
            let item = NSMenuItem(title: interval.title, action: #selector(selectInterval(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            intervalSubmenu.addItem(item)
        }

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let accessibilityItem = NSMenuItem(title: "Grant Accessibility Access...", action: #selector(openAccessibilitySettings), keyEquivalent: "")
        accessibilityItem.target = self
        menu.addItem(accessibilityItem)

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    private func updateMenu() {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short

        statusMenuItem.title = "Status: \(controller.lastResultText)"

        if let lastRefreshDate = controller.lastRefreshDate {
            lastRefreshMenuItem.title = "Last refresh: \(formatter.string(from: lastRefreshDate))"
        } else {
            lastRefreshMenuItem.title = "Last refresh: Never"
        }

        syncStatusMenuItem.title = "Sync: \(controller.lastSyncResultText)"
        sureStatusMenuItem.title = "Sure: \(controller.lastSureSyncResultText)"

        if let lastSyncDate = controller.lastSyncDate {
            lastSyncMenuItem.title = "Last sync: \(formatter.string(from: lastSyncDate))"
        } else {
            lastSyncMenuItem.title = "Last sync: Never"
        }

        if let nextDate = controller.nextScheduledRefreshDate {
            nextRefreshMenuItem.title = "Next refresh: \(formatter.string(from: nextDate))"
        } else {
            nextRefreshMenuItem.title = "Next refresh: Not scheduled"
        }

        refreshNowMenuItem.isEnabled = !controller.isBusy
        syncNowMenuItem.isEnabled = !controller.isBusy

        for (index, item) in intervalSubmenu.items.enumerated() {
            item.state = controller.allIntervals()[index] == controller.selectedInterval ? .on : .off
        }

        updateStatusIcon()
    }

    private func updateStatusIcon() {
        guard let button = statusItem.button else {
            return
        }

        let configuration = symbolConfiguration(for: controller.visualState)
        let image = NSImage(
            systemSymbolName: configuration.symbolName,
            accessibilityDescription: configuration.accessibilityDescription
        )
        image?.isTemplate = false
        image?.withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
        button.image = image
        button.contentTintColor = configuration.tintColor
    }

    private func symbolConfiguration(for state: RefreshVisualState) -> (symbolName: String, tintColor: NSColor, accessibilityDescription: String) {
        switch state {
        case .idle:
            return ("arrow.clockwise.circle", .secondaryLabelColor, "MoneyMoney refresh idle")
        case .refreshing:
            return ("arrow.triangle.2.circlepath.circle.fill", .systemBlue, "MoneyMoney refresh running")
        case .syncing:
            return ("arrow.triangle.2.circlepath.circle.fill", .systemOrange, "Syncing to Actual Budget")
        case .success:
            return ("checkmark.circle.fill", .systemGreen, "MoneyMoney refresh succeeded")
        case .failure:
            return ("exclamationmark.circle.fill", .systemRed, "MoneyMoney refresh failed")
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.setActivationPolicy(.accessory)
app.delegate = delegate
app.run()
