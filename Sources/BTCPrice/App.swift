import AppKit
import BTCPriceCore

private enum Diagnostics {
    static func record(_ event: String, _ values: [String: String] = [:]) {
        guard let path = ProcessInfo.processInfo.environment["BTC_PRICE_DIAGNOSTICS_PATH"] else { return }
        var entry = values
        entry["event"] = event
        entry["time"] = ISO8601DateFormatter().string(from: Date())
        guard let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
        if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        handle.seekToEndOfFile()
        handle.write(data)
        handle.write(Data([10]))
        handle.closeFile()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let client = OKXClient()
    private var timer: Timer?
    private var requestTask: Task<Void, Never>?
    private var requestID = UUID()
    private var quote: MarketQuote?
    private var selectedInstrument = SpotInstrument.bitcoin
    private var symbolPicker: SymbolPickerWindowController?
    private static let selectionKey = "selectedSpotInstrument"
    private var errorMessage: String?
    private var nextAllowedAttempt = Date.distantPast
    private var rateLimitCount = 0
    private var refreshInProgress = false
    private var activity: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Diagnostics.record("didFinishLaunching")
        // LaunchServices normally reuses the running instance; also protect direct launches.
        let identifier = Bundle.main.bundleIdentifier ?? "local.BTCPrice"
        if NSRunningApplication.runningApplications(withBundleIdentifier: identifier).contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            Diagnostics.record("duplicateInstance")
            NSApp.terminate(nil)
            return
        }
        if let data = UserDefaults.standard.data(forKey: Self.selectionKey),
           let saved = try? JSONDecoder().decode(SpotInstrument.self, from: data),
           saved.quoteCcy == "USDT", !saved.baseCcy.isEmpty,
           saved.instId == saved.baseCcy + "-USDT",
           let tickSize = Double(saved.tickSz), tickSize.isFinite, tickSize > 0 {
            selectedInstrument = saved
        }
        let itemName = "BTCPrice.Price"
        // AppKit restores this item's last position. Seed a right-side position
        // once, then preserve any position chosen by Command-dragging the item.
        // The preference is a best-effort compatibility hint; visibility does
        // not rely on a private selector or modifications to another app.
        let positionKey = "NSStatusItem Preferred Position \(itemName)"
        if UserDefaults.standard.object(forKey: positionKey) == nil {
            UserDefaults.standard.set(0, forKey: positionKey)
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = itemName
        statusItem.isVisible = true
        statusItem.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        statusItem.button?.setAccessibilityLabel("\(selectedInstrument.displayName) 现货价格")
        statusItem.menu = menu
        menu.delegate = self
        menu.autoenablesItems = false
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "每 30 秒刷新 OKX 现货菜单栏价格")
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        render()
        startTimer()
        refresh()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.recordStatus() }
    }

    private func recordStatus() {
        var values = ["visible": String(statusItem.isVisible), "title": statusItem.button?.title ?? "nil",
                      "activationPolicy": String(NSApp.activationPolicy().rawValue),
                      "presentationOptions": String(NSApp.currentSystemPresentationOptions.rawValue)]
        if let window = statusItem.button?.window {
            values["windowFrame"] = NSStringFromRect(window.frame)
            values["windowVisible"] = String(window.isVisible)
            values["windowOcclusion"] = String(window.occlusionState.rawValue)
            values["screenFrame"] = window.screen.map { NSStringFromRect($0.frame) } ?? "nil"
        }
        values["buttonFrame"] = statusItem.button.map { NSStringFromRect($0.frame) } ?? "nil"
        for (index, screen) in NSScreen.screens.enumerated() {
            values["screen\(index)"] = NSStringFromRect(screen.frame)
            values["safeTop\(index)"] = String(describing: screen.safeAreaInsets.top)
            values["leftSafe\(index)"] = screen.auxiliaryTopLeftArea.map(NSStringFromRect) ?? "nil"
            values["rightSafe\(index)"] = screen.auxiliaryTopRightArea.map(NSStringFromRect) ?? "nil"
        }
        Diagnostics.record("status", values)
    }

    private func startTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: OKXClient.refreshInterval, repeats: true) { [weak self] _ in
            guard let owner = self else { return }
            Task { @MainActor in owner.refresh() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    @objc private func didWake() {
        startTimer()
        refresh()
    }

    @objc private func refreshNow() { refresh() }

    @objc private func chooseSymbol() {
        if symbolPicker == nil {
            symbolPicker = SymbolPickerWindowController(selected: selectedInstrument) { [weak self] instrument in
                self?.selectInstrument(instrument)
            }
        }
        symbolPicker?.present(selected: selectedInstrument)
    }

    private func selectInstrument(_ instrument: SpotInstrument) {
        guard instrument.quoteCcy == "USDT" else { return }
        guard instrument != selectedInstrument else { return }
        requestTask?.cancel()
        requestID = UUID()
        requestTask = nil
        refreshInProgress = false
        selectedInstrument = instrument
        quote = nil
        errorMessage = nil
        if let data = try? JSONEncoder().encode(instrument) {
            UserDefaults.standard.set(data, forKey: Self.selectionKey)
        }
        startTimer()
        render()
        refresh()
    }

    private func refresh() {
        guard !refreshInProgress, Date() >= nextAllowedAttempt else { render(); return }
        refreshInProgress = true
        let id = UUID()
        requestID = id
        let instrument = selectedInstrument
        render()
        requestTask = Task { [weak self] in
            guard let self = self else { return }
            do {
                let quote = try await self.client.fetch(instrument: instrument)
                guard !Task.isCancelled, self.requestID == id,
                      self.selectedInstrument.instId == instrument.instId else { return }
                self.quote = self.quote?.accepting(quote) ?? quote
                self.errorMessage = nil
                self.rateLimitCount = 0
                self.nextAllowedAttempt = .distantPast
            } catch {
                guard !Task.isCancelled, self.requestID == id else { return }
                self.errorMessage = error.localizedDescription
                if case PriceError.rateLimited(let retryAfter) = error {
                    self.rateLimitCount += 1
                    let backoff = min(900, 60 * pow(2, Double(min(self.rateLimitCount - 1, 4))))
                    self.nextAllowedAttempt = Date().addingTimeInterval(max(retryAfter, backoff))
                }
            }
            self.refreshInProgress = false
            self.requestTask = nil
            self.render()
        }
    }

    private var isStale: Bool {
        guard let quote = quote else { return true }
        return errorMessage != nil || Date().timeIntervalSince(quote.updatedAt) > 180
    }

    private func render() {
        guard let button = statusItem?.button else { return }
        let priceText = quote?.formattedPrice ?? (errorMessage == nil ? "$…" : "$—")
        button.title = "\(selectedInstrument.baseCcy) \(priceText)"
        button.appearsDisabled = quote != nil && isStale
        button.setAccessibilityLabel("\(selectedInstrument.displayName) 现货价格")
        var details = ["\(selectedInstrument.displayName) · OKX 现货最新价", "计价单位：USDT · 每 30 秒刷新"]
        if let quote = quote {
            details.append("行情时间：\(time(quote.updatedAt))")
            details.append("最近获取：\(time(quote.receivedAt))")
            if isStale { details.append("当前显示上次价格，行情可能已过期") }
        }
        if let error = errorMessage { details.append(error) }
        else if refreshInProgress && quote == nil { details.append("正在获取价格…") }
        button.toolTip = details.joined(separator: "\n")
        button.setAccessibilityValue(quote?.formattedPrice ?? "尚未获取")
        rebuildMenu()
        recordStatus()
    }

    func menuWillOpen(_ menu: NSMenu) { rebuildMenu() }

    private func rebuildMenu() {
        menu.removeAllItems()
        add("\(selectedInstrument.displayName) · OKX 现货最新价", enabled: false)
        add("每 30 秒自动刷新", enabled: false)
        if let quote = quote {
            add("行情时间：\(time(quote.updatedAt))", enabled: false)
            if isStale { add("行情已过期，显示上次价格", enabled: false) }
        }
        if let error = errorMessage {
            let message = error.count > 68 ? String(error.prefix(68)) + "…" : error
            let item = add(message, enabled: false)
            item.toolTip = error
        }
        if nextAllowedAttempt > Date() {
            add("请求受限，将于 \(time(nextAllowedAttempt)) 后重试", enabled: false)
        }
        menu.addItem(.separator())
        add("选择交易对…", action: #selector(chooseSymbol))
        add(refreshInProgress ? "正在刷新…" : "立即刷新", action: #selector(refreshNow), enabled: !refreshInProgress && nextAllowedAttempt <= Date())
        menu.addItem(.separator())
        let quit = add("退出 BTC Price", action: #selector(quit))
        quit.keyEquivalent = "q"
    }

    @discardableResult
    private func add(_ title: String, action: Selector? = nil, enabled: Bool = true) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = enabled
        menu.addItem(item)
        return item
    }

    private func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }

    @objc private func quit() { NSApp.terminate(nil) }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        requestTask?.cancel()
        symbolPicker?.close()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        if let activity = activity { ProcessInfo.processInfo.endActivity(activity) }
    }
}

@main
enum BTCPriceApplication {
    @MainActor
    static func main() {
        Diagnostics.record("main")
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
