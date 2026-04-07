import AppKit
import Network

struct RefreshInterval: Equatable {
    let title: String
    let seconds: TimeInterval
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
            ollamaURL: "http://localhost:11434", ollamaModel: "gemma4:26b", dnsServer: "",
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

    private var timer: Timer?
    private(set) var isBusy = false
    private(set) var currentPhase = "Idle" // "Refreshing...", "Syncing...", "Categorizing..."
    private(set) var lastRefreshDate: Date?
    private(set) var lastSyncDate: Date?
    private(set) var lastResultText = "Idle"
    private(set) var lastSyncResultText = "Idle"
    private(set) var lastDurationSeconds: TimeInterval = 0
    private(set) var lastSuccessDate: Date?
    private var refreshStartTime: Date?

    var onStatusChange: (() -> Void)?

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
        scheduleTimer()
        onStatusChange?()
    }

    func updateInterval(_ interval: RefreshInterval) {
        defaults.set(interval.seconds, forKey: intervalKey)
        scheduleTimer()
        onStatusChange?()
    }

    func refreshNow() {
        guard !isBusy else { return }

        isBusy = true
        currentPhase = "Refreshing..."
        lastResultText = "Refreshing..."
        onStatusChange?()

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
        onStatusChange?()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            self.doSyncCategorize()
        }
    }

    private func doRefreshSyncCategorize() {
        refreshStartTime = Date()
        let refreshResult = runAppleScript()

        DispatchQueue.main.sync {
            lastRefreshDate = Date()
            lastResultText = refreshResult
            onStatusChange?()
        }

        guard refreshResult == "Success" else {
            DispatchQueue.main.sync { isBusy = false; onStatusChange?() }
            return
        }

        doSyncCategorize()
    }

    private func doSyncCategorize() {
        DispatchQueue.main.sync {
            currentPhase = "Syncing..."
            lastSyncResultText = "Syncing..."
            onStatusChange?()
        }

        let syncResult = runSync()

        guard syncResult == "Success" else {
            DispatchQueue.main.sync {
                isBusy = false
                lastSyncDate = Date()
                lastSyncResultText = syncResult
                onStatusChange?()
            }
            return
        }

        DispatchQueue.main.sync {
            currentPhase = "Categorizing..."
            lastSyncResultText = "Categorizing..."
            onStatusChange?()
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
            onStatusChange?()
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
        guard let scriptURL = Bundle.main.url(forResource: "refresh-moneymoney", withExtension: "applescript") else {
            return "Missing bundled AppleScript"
        }

        do {
            let source = try String(contentsOf: scriptURL, encoding: .utf8)
            var errorInfo: NSDictionary?
            let script = NSAppleScript(source: source)
            script?.executeAndReturnError(&errorInfo)

            if let errorInfo {
                return "Failed: \(describe(errorInfo))"
            }

            return "Success"
        } catch {
            return "Failed: \(error.localizedDescription)"
        }
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

    private func runSync() -> String {
        swiftLog("runSync start, nodeBinDir=\(nodeBinDir), scriptDir=\(scriptDir)")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "\(nodeBinDir)/actual-monmon")
        process.arguments = ["import"]
        process.currentDirectoryURL = URL(fileURLWithPath: scriptDir)

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "\(nodeBinDir):\(env["PATH"] ?? "/usr/bin:/bin")"
        process.environment = env

        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            swiftLog("runSync exit=\(process.terminationStatus)")
            if process.terminationStatus == 0 {
                return "Success"
            } else {
                return "Sync failed (exit \(process.terminationStatus))"
            }
        } catch {
            swiftLog("runSync error: \(error.localizedDescription)")
            return "Sync failed: \(error.localizedDescription)"
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
    private var listener: NWListener?
    private let port: UInt16
    private let controller: RefreshController

    init(port: UInt16, controller: RefreshController) {
        self.port = port
        self.controller = controller
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
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }

            let response: String
            if request.contains("GET /health") {
                response = self.httpResponse(status: "200 OK", contentType: "text/plain", body: "ok\n")
            } else if request.contains("GET /metrics") {
                let body = self.formatMetrics()
                response = self.httpResponse(status: "200 OK", contentType: "text/plain; version=0.0.4; charset=utf-8", body: body)
            } else {
                response = self.httpResponse(status: "404 Not Found", contentType: "text/plain", body: "not found\n")
            }

            connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    private func httpResponse(status: String, contentType: String, body: String) -> String {
        "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
    }

    private func formatMetrics() -> String {
        var lastSuccess: TimeInterval = 0
        var lastRefresh: TimeInterval = 0
        var duration: TimeInterval = 0
        var stateName = "idle"

        DispatchQueue.main.sync {
            lastSuccess = self.controller.lastSuccessDate?.timeIntervalSince1970 ?? 0
            lastRefresh = self.controller.lastRefreshDate?.timeIntervalSince1970 ?? 0
            duration = self.controller.lastDurationSeconds
            stateName = self.controller.visualStateName
        }

        var lines: [String] = []

        lines.append("# HELP bank_refresh_up Whether the bank-refresh app is running.")
        lines.append("# TYPE bank_refresh_up gauge")
        lines.append("bank_refresh_up 1")

        lines.append("# HELP bank_refresh_last_success_timestamp_seconds Unix timestamp of last successful refresh.")
        lines.append("# TYPE bank_refresh_last_success_timestamp_seconds gauge")
        lines.append("bank_refresh_last_success_timestamp_seconds \(Int(lastSuccess))")

        lines.append("# HELP bank_refresh_last_refresh_timestamp_seconds Unix timestamp of last refresh attempt.")
        lines.append("# TYPE bank_refresh_last_refresh_timestamp_seconds gauge")
        lines.append("bank_refresh_last_refresh_timestamp_seconds \(Int(lastRefresh))")

        lines.append("# HELP bank_refresh_duration_seconds Duration of last refresh cycle.")
        lines.append("# TYPE bank_refresh_duration_seconds gauge")
        lines.append("bank_refresh_duration_seconds \(String(format: "%.3f", duration))")

        lines.append("# HELP bank_refresh_state Current state of the refresh controller.")
        lines.append("# TYPE bank_refresh_state gauge")
        for state in ["idle", "refreshing", "syncing", "success", "failure"] {
            let val = state == stateName ? 1 : 0
            lines.append("bank_refresh_state{state=\"\(state)\"} \(val)")
        }

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

        controller.start()
        updateMenu()

        let config = SettingsStore(scriptDir: controller.scriptDir).load()
        let metricsPort = UInt16(config.metricsPort) ?? 9100
        metricsServer = MetricsServer(port: metricsPort, controller: controller)
        metricsServer?.start()
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
        lastSyncMenuItem.isEnabled = false
        nextRefreshMenuItem.isEnabled = false

        menu.addItem(statusMenuItem)
        menu.addItem(lastRefreshMenuItem)
        menu.addItem(syncStatusMenuItem)
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
