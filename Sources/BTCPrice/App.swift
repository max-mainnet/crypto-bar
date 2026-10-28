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
    private let client: OKXClient
    private var timer: Timer?
    private var timerID = UUID()
    private var requestTask: Task<Void, Never>?
    private var requestID = UUID()
    private var quotes: [String: MarketQuote] = [:]
    private var missingQuoteIDs: Set<String> = []
    private var quote: MarketQuote? { quotes[selectedInstrument.instId] }
    private var selectedInstrument = SpotInstrument.bitcoin
    private let watchlistStore = WatchlistStore()
    private var watchlist = Watchlist()
    private var symbolPicker: SymbolPickerWindowController?
    private static let selectionKey = "selectedSpotInstrument"
    private var errorMessage: String?
    private var nextAllowedAttempt = Date.distantPast
    private var rateLimitCount = 0
    private var refreshInProgress = false
    private var refreshPending = false
    private var menuIsOpen = false
    private var activity: NSObjectProtocol?

    init(client: OKXClient = OKXClient()) {
        self.client = client
        super.init()
    }

    deinit {
        timer?.invalidate()
        requestTask?.cancel()
        if let activity = activity { ProcessInfo.processInfo.endActivity(activity) }
    }

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
        watchlist = watchlistStore.load(defaultInstrument: selectedInstrument)
        watchlistStore.save(watchlist)
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
                      "watchlistCount": String(watchlist.instruments.count),
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
        let id = UUID()
        timerID = id
        let timer = Timer(timeInterval: OKXClient.refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let owner = self, owner.timerID == id, owner.timer?.isValid == true else { return }
                owner.refresh()
            }
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
        showSymbolPicker(watchlistOnly: false)
    }

    @objc private func manageWatchlist() {
        showSymbolPicker(watchlistOnly: true)
    }

    private func showSymbolPicker(watchlistOnly: Bool) {
        if symbolPicker == nil {
            symbolPicker = SymbolPickerWindowController(
                selected: selectedInstrument, watchlist: watchlist.instruments,
                onWatchlistChange: { [weak self] instrument in self?.toggleWatchlist(instrument) },
                onInstrumentsLoaded: { [weak self] instruments in self?.reconcileInstruments(instruments) }
            ) { [weak self] instrument in
                self?.selectInstrument(instrument)
            }
        }
        symbolPicker?.updateWatchlist(watchlist.instruments)
        symbolPicker?.present(selected: selectedInstrument, showWatchlist: watchlistOnly)
    }

    @objc private func toggleCurrentWatchlist() { toggleWatchlist(selectedInstrument) }

    private func toggleWatchlist(_ instrument: SpotInstrument) {
        watchlist.toggle(instrument)
        watchlistStore.save(watchlist)
        symbolPicker?.updateWatchlist(watchlist.instruments)
        pruneQuotes()
        render()
        refresh()
    }

    private func reconcileInstruments(_ instruments: [SpotInstrument]) {
        let previousWatchlist = watchlist
        let previousSelection = selectedInstrument
        watchlist.updateKnownInstruments(instruments)
        if let updated = instruments.first(where: { $0.instId == selectedInstrument.instId && $0.quoteCcy == "USDT" }) {
            selectedInstrument = updated
        }
        guard watchlist != previousWatchlist || selectedInstrument != previousSelection else { return }
        watchlistStore.save(watchlist)
        if let data = try? JSONEncoder().encode(selectedInstrument) {
            UserDefaults.standard.set(data, forKey: Self.selectionKey)
        }
        symbolPicker?.updateWatchlist(watchlist.instruments)
        render()
        refresh()
    }

    @objc private func selectWatchlistItem(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let instrument = watchlist.instruments.first(where: { $0.instId == id }) else { return }
        selectInstrument(instrument)
    }

    private var instrumentsForQuotes: [SpotInstrument] {
        var instruments = watchlist.instruments
        if let index = instruments.firstIndex(where: { $0.instId == selectedInstrument.instId }) {
            instruments[index] = selectedInstrument
        } else {
            instruments.append(selectedInstrument)
        }
        return instruments
    }

    private func pruneQuotes() {
        let ids = Set(instrumentsForQuotes.map(\.instId))
        quotes = quotes.filter { ids.contains($0.key) }
        missingQuoteIDs.formIntersection(ids)
    }

    private func selectInstrument(_ instrument: SpotInstrument) {
        guard instrument.quoteCcy == "USDT" else { return }
        guard instrument != selectedInstrument else { return }
        requestTask?.cancel()
        requestID = UUID()
        requestTask = nil
        refreshInProgress = false
        refreshPending = false
        selectedInstrument = instrument
        watchlist.updateKnownInstruments([instrument])
        watchlistStore.save(watchlist)
        symbolPicker?.updateWatchlist(watchlist.instruments)
        pruneQuotes()
        if let data = try? JSONEncoder().encode(instrument) {
            UserDefaults.standard.set(data, forKey: Self.selectionKey)
        }
        startTimer()
        render()
        refresh()
    }

    private func refresh() {
        guard Date() >= nextAllowedAttempt else { render(); return }
        guard !refreshInProgress else { refreshPending = true; return }
        refreshInProgress = true
        refreshPending = false
        let id = UUID()
        requestID = id
        let requested = instrumentsForQuotes
        let client = self.client
        render()
        requestTask = Task { [weak self] in
            do {
                let result = try await client.fetchQuotes(for: requested)
                guard !Task.isCancelled, let self = self, self.requestID == id else { return }
                let currentIDs = Set(self.instrumentsForQuotes.map(\.instId))
                let requestedIDs = Set(requested.map(\.instId)).intersection(currentIDs)
                var receivedIDs: Set<String> = []
                for (instrumentID, quote) in result where requestedIDs.contains(instrumentID) {
                    guard quote.instrumentID == instrumentID else { continue }
                    self.quotes[instrumentID] = self.quotes[instrumentID]?.accepting(quote) ?? quote
                    receivedIDs.insert(instrumentID)
                }
                self.missingQuoteIDs.subtract(requestedIDs)
                self.missingQuoteIDs.formUnion(requestedIDs.subtracting(receivedIDs))
                self.errorMessage = nil
                self.rateLimitCount = 0
                self.nextAllowedAttempt = .distantPast
                self.finishRefresh()
            } catch {
                guard !Task.isCancelled, let self = self, self.requestID == id else { return }
                self.errorMessage = error.localizedDescription
                if case PriceError.rateLimited(let retryAfter) = error {
                    self.rateLimitCount += 1
                    let backoff = min(900, 60 * pow(2, Double(min(self.rateLimitCount - 1, 4))))
                    self.nextAllowedAttempt = Date().addingTimeInterval(max(retryAfter, backoff))
                }
                self.finishRefresh()
            }
        }
    }

    private func finishRefresh() {
        refreshInProgress = false
        requestTask = nil
        render()
        let pending = refreshPending
        refreshPending = false
        if pending { refresh() }
    }

    private var isStale: Bool {
        quoteIsStale(selectedInstrument.instId)
    }

    private func quoteIsStale(_ instrumentID: String) -> Bool {
        guard let quote = quotes[instrumentID] else { return true }
        return errorMessage != nil || missingQuoteIDs.contains(instrumentID)
            || Date().timeIntervalSince(quote.updatedAt) > 180
    }

    private func render() {
        guard let button = statusItem?.button else { return }
        let unavailable = errorMessage != nil || missingQuoteIDs.contains(selectedInstrument.instId)
        let priceText = quote?.formattedPrice ?? (unavailable ? "$—" : "$…")
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
        else if missingQuoteIDs.contains(selectedInstrument.instId) { details.append("OKX 暂未返回所选交易对的有效价格") }
        else if refreshInProgress && quote == nil { details.append("正在获取价格…") }
        button.toolTip = details.joined(separator: "\n")
        button.setAccessibilityValue(quote?.formattedPrice ?? "尚未获取")
        rebuildMenu()
        recordStatus()
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu()
        menuIsOpen = true
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
        rebuildMenu()
    }

    private func rebuildMenu() {
        if menuIsOpen { updateWatchlistMenuPrices(); return }
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
        } else if missingQuoteIDs.contains(selectedInstrument.instId) {
            add("所选交易对暂无有效报价", enabled: false)
        }
        if nextAllowedAttempt > Date() {
            add("请求受限，将于 \(time(nextAllowedAttempt)) 后重试", enabled: false)
        }
        menu.addItem(.separator())
        add("自选列表", enabled: false)
        if watchlist.instruments.isEmpty {
            add("暂无自选，点击“管理自选…”添加", enabled: false)
        } else {
            for instrument in watchlist.instruments {
                let item = add("", action: #selector(selectWatchlistItem(_:)))
                item.representedObject = instrument.instId
                configureWatchlistItem(item, instrument: instrument)
            }
        }
        menu.addItem(.separator())
        add(watchlist.contains(selectedInstrument.instId)
            ? "从自选移除 \(selectedInstrument.baseCcy)"
            : "将 \(selectedInstrument.baseCcy) 加入自选", action: #selector(toggleCurrentWatchlist))
        add("管理自选…", action: #selector(manageWatchlist))
        add("选择交易对…", action: #selector(chooseSymbol))
        add(refreshInProgress ? "正在刷新…" : "立即刷新", action: #selector(refreshNow), enabled: !refreshInProgress && nextAllowedAttempt <= Date())
        menu.addItem(.separator())
        let quit = add("退出 BTC Price", action: #selector(quit))
        quit.keyEquivalent = "q"
    }

    private func updateWatchlistMenuPrices() {
        for item in menu.items {
            guard let id = item.representedObject as? String else { continue }
            guard let instrument = watchlist.instruments.first(where: { $0.instId == id }) else {
                item.isEnabled = false
                continue
            }
            configureWatchlistItem(item, instrument: instrument)
        }
    }

    private func configureWatchlistItem(_ item: NSMenuItem, instrument: SpotInstrument) {
        let quote = quotes[instrument.instId]
        item.title = "\(instrument.baseCcy) \(quote?.formattedPrice ?? "$—")"
        item.attributedTitle = NSAttributedString(string: item.title, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular),
            .foregroundColor: quoteIsStale(instrument.instId) ? NSColor.secondaryLabelColor : NSColor.labelColor
        ])
        item.isEnabled = true
        item.state = instrument.instId == selectedInstrument.instId ? .on : .off
        var details = ["\(instrument.displayName) · 点击切换状态栏"]
        if let quote = quote { details.append("行情时间：\(time(quote.updatedAt))") }
        if quoteIsStale(instrument.instId) { details.append("行情暂不可用或已过期") }
        item.toolTip = details.joined(separator: "\n")
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
        timer = nil
        requestID = UUID()
        requestTask?.cancel()
        requestTask = nil
        refreshInProgress = false
        refreshPending = false
        symbolPicker?.close()
        symbolPicker = nil
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        if let activity = activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
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
