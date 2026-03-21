import AppKit

struct RefreshInterval: Equatable {
    let title: String
    let seconds: TimeInterval
}

enum RefreshVisualState {
    case idle
    case refreshing
    case success
    case failure
}

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
    private(set) var isRefreshing = false
    private(set) var lastRefreshDate: Date?
    private(set) var lastResultText = "Idle"

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
        if isRefreshing {
            return .refreshing
        }

        if lastResultText == "Success" {
            return .success
        }

        if lastResultText.hasPrefix("Failed:") {
            return .failure
        }

        return .idle
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
        guard !isRefreshing else {
            lastResultText = "Refresh already running"
            onStatusChange?()
            return
        }

        isRefreshing = true
        lastResultText = "Refreshing..."
        onStatusChange?()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else {
                return
            }

            let result = self.runAppleScript()

            DispatchQueue.main.async {
                self.isRefreshing = false
                self.lastRefreshDate = Date()
                self.lastResultText = result
                self.onStatusChange?()
            }
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

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller = RefreshController()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()

    private let statusMenuItem = NSMenuItem(title: "Status: Idle", action: nil, keyEquivalent: "")
    private let lastRefreshMenuItem = NSMenuItem(title: "Last refresh: Never", action: nil, keyEquivalent: "")
    private let nextRefreshMenuItem = NSMenuItem(title: "Next refresh: Waiting for timer", action: nil, keyEquivalent: "")
    private let refreshNowMenuItem = NSMenuItem(title: "Refresh now", action: #selector(refreshNow), keyEquivalent: "r")
    private let intervalMenuItem = NSMenuItem(title: "Refresh interval", action: nil, keyEquivalent: "")
    private let intervalSubmenu = NSMenu()

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureStatusItem()
        configureMenu()

        controller.onStatusChange = { [weak self] in
            self?.updateMenu()
        }

        controller.start()
        updateMenu()
    }

    @objc private func refreshNow() {
        controller.refreshNow()
    }

    @objc private func selectInterval(_ sender: NSMenuItem) {
        let availableIntervals = controller.allIntervals()

        guard sender.tag < availableIntervals.count else {
            return
        }

        controller.updateInterval(availableIntervals[sender.tag])
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
        nextRefreshMenuItem.isEnabled = false

        menu.addItem(statusMenuItem)
        menu.addItem(lastRefreshMenuItem)
        menu.addItem(nextRefreshMenuItem)
        menu.addItem(.separator())
        refreshNowMenuItem.target = self
        menu.addItem(refreshNowMenuItem)

        intervalMenuItem.submenu = intervalSubmenu
        menu.addItem(intervalMenuItem)

        for (index, interval) in controller.allIntervals().enumerated() {
            let item = NSMenuItem(title: interval.title, action: #selector(selectInterval(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            intervalSubmenu.addItem(item)
        }

        menu.addItem(.separator())

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

        if let nextDate = controller.nextScheduledRefreshDate {
            nextRefreshMenuItem.title = "Next refresh: \(formatter.string(from: nextDate))"
        } else {
            nextRefreshMenuItem.title = "Next refresh: Not scheduled"
        }

        refreshNowMenuItem.isEnabled = !controller.isRefreshing

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
        case .success:
            return ("checkmark.circle.fill", .systemGreen, "MoneyMoney refresh succeeded")
        case .failure:
            return ("exclamationmark.circle.fill", .systemRed, "MoneyMoney refresh failed")
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.setActivationPolicy(.prohibited)
app.delegate = delegate
app.run()
