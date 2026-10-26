import AppKit
import BTCPriceCore

@MainActor
final class SymbolPickerWindowController: NSWindowController, NSWindowDelegate,
    NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let client = OKXClient()
    private let quoteCurrency: String?
    private let onSelect: (SpotInstrument) -> Void
    private let onInstrumentsLoaded: (([SpotInstrument]) -> Void)?
    private let onWatchlistChange: ((SpotInstrument) -> Void)?
    private let searchField = NSSearchField()
    private let scopeControl = NSSegmentedControl(labels: ["全部现货", "自选列表"],
                                                  trackingMode: .selectOne, target: nil, action: nil)
    private let table = SymbolPickerTableView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let progress = NSProgressIndicator()
    private let refreshButton = NSButton(title: "刷新列表", target: nil, action: nil)
    private let selectButton = NSButton(title: "使用此交易对", target: nil, action: nil)
    private var instruments: [SpotInstrument] = []
    private var watchlist: [SpotInstrument]
    private var filtered: [SpotInstrument] = []
    private var selectedID: String
    private var loadTask: Task<Void, Never>?
    private var loadGeneration = 0
    private var isLoading = false
    private var loadError: String?
    private var nextDirectoryAttempt = Date.distantPast
    private var directoryRateLimitCount = 0
    private var prices: [String: MarketQuote] = [:]
    private var missingPriceIDs: Set<String> = []
    private var priceTask: Task<Void, Never>?
    private var priceGeneration = 0
    private var priceTimer: Timer?
    private var isLoadingPrices = false
    private var priceRefreshPending = false
    private var priceError: String?
    private var nextPriceAttempt = Date.distantPast
    private var priceRateLimitCount = 0
    private var lastPriceRefresh: Date?
    private var isPresented = false

    init(selected: SpotInstrument, quoteCurrency: String? = "USDT",
         watchlist: [SpotInstrument] = [],
         onWatchlistChange: ((SpotInstrument) -> Void)? = nil,
         onInstrumentsLoaded: (([SpotInstrument]) -> Void)? = nil,
         onSelect: @escaping (SpotInstrument) -> Void) {
        let normalizedQuote = quoteCurrency?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        self.quoteCurrency = normalizedQuote?.isEmpty == false ? normalizedQuote : nil
        self.selectedID = selected.instId
        self.onSelect = onSelect
        self.onInstrumentsLoaded = onInstrumentsLoaded
        self.onWatchlistChange = onWatchlistChange
        self.watchlist = Self.uniqueWatchlist(watchlist)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 460),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "选择现货交易对"
        window.minSize = NSSize(width: 590, height: 420)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildInterface(in: window)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func updateWatchlist(_ instruments: [SpotInstrument]) {
        let updated = Self.uniqueWatchlist(instruments)
        guard updated != watchlist else { return }
        let preservedID = selectedRowInstrument?.instId
        watchlist = updated
        let availableIDs = Set(availableInstruments.map(\.instId))
        prices = prices.filter { availableIDs.contains($0.key) }
        missingPriceIDs.formIntersection(availableIDs)
        applyFilter(preferredID: preservedID, selectFirstIfMissing: false, scrollToSelection: false)
        if availableIDs.contains(where: { prices[$0] == nil }) { refreshPrices() }
    }

    private static func uniqueWatchlist(_ instruments: [SpotInstrument]) -> [SpotInstrument] {
        var seen = Set<String>()
        return instruments.filter { seen.insert($0.instId).inserted }
    }

    func present(selected: SpotInstrument, showWatchlist: Bool = false) {
        isPresented = true
        selectedID = selected.instId
        searchField.stringValue = ""
        scopeControl.selectedSegment = showWatchlist ? 1 : 0
        applyFilter(preferredID: selectedID)
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(searchField)
        startPriceTimer()
        loadInstruments()
        refreshPrices()
    }

    private func buildInterface(in window: NSWindow) {
        guard let content = window.contentView else { return }
        content.setAccessibilityIdentifier("symbolPicker.windowContent")
        searchField.placeholderString = "搜索币种，例如 BTC、ETH、SOL"
        searchField.sendsSearchStringImmediately = true
        searchField.delegate = self
        searchField.setAccessibilityIdentifier("symbolPicker.search")
        searchField.setAccessibilityLabel("搜索现货交易对")
        searchField.translatesAutoresizingMaskIntoConstraints = false

        refreshButton.target = self
        refreshButton.action = #selector(refreshList)
        refreshButton.bezelStyle = .rounded
        refreshButton.setAccessibilityIdentifier("symbolPicker.refresh")

        scopeControl.selectedSegment = 0
        scopeControl.segmentStyle = .rounded
        scopeControl.target = self
        scopeControl.action = #selector(changeScope)
        scopeControl.setAccessibilityIdentifier("symbolPicker.scope")
        scopeControl.setAccessibilityLabel("交易对列表范围")

        let description = NSTextField(labelWithString: quoteCurrency.map {
            "OKX \($0) 现货 · 点击 ☆ 加入自选 · 价格每 30 秒刷新。"
        } ?? "OKX 现货 · 点击 ☆ 加入自选 · 价格每 30 秒刷新。")
        description.textColor = .secondaryLabelColor
        description.font = .systemFont(ofSize: 12)

        let favoriteColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("favorite"))
        favoriteColumn.title = "自选"
        favoriteColumn.width = 42
        favoriteColumn.minWidth = 42
        favoriteColumn.maxWidth = 42
        favoriteColumn.resizingMask = []
        favoriteColumn.headerCell.alignment = .center
        let pairColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("pair"))
        pairColumn.title = "交易对"
        pairColumn.width = 205
        pairColumn.minWidth = 160
        let baseColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("base"))
        baseColumn.title = "币种"
        baseColumn.width = 100
        baseColumn.minWidth = 85
        let priceColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("price"))
        priceColumn.title = "最新价格"
        priceColumn.width = 230
        priceColumn.minWidth = 175
        priceColumn.headerCell.alignment = .right
        table.addTableColumn(favoriteColumn)
        table.addTableColumn(pairColumn)
        table.addTableColumn(baseColumn)
        table.addTableColumn(priceColumn)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.style = .inset
        table.rowHeight = 29
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.allowsColumnReordering = false
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(confirmDoubleClick)
        table.setAccessibilityIdentifier("symbolPicker.table")
        table.setAccessibilityLabel("OKX 现货交易对搜索结果")
        table.onConfirm = { [weak self] in self?.confirmSelection() }
        table.onCancel = { [weak self] in self?.cancelSelection() }

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        progress.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 2
        statusLabel.setAccessibilityIdentifier("symbolPicker.status")
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let cancelButton = NSButton(title: "取消", target: self, action: #selector(cancelSelection))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.setAccessibilityIdentifier("symbolPicker.cancel")
        selectButton.target = self
        selectButton.action = #selector(confirmSelection)
        selectButton.bezelStyle = .rounded
        selectButton.keyEquivalent = "\r"
        selectButton.isEnabled = false
        selectButton.setAccessibilityIdentifier("symbolPicker.select")

        let searchRow = NSStackView(views: [searchField, refreshButton])
        searchRow.orientation = .horizontal
        searchRow.spacing = 10
        searchRow.alignment = .centerY
        let statusRow = NSStackView(views: [progress, statusLabel])
        statusRow.orientation = .horizontal
        statusRow.spacing = 8
        statusRow.alignment = .centerY
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttonRow = NSStackView(views: [spacer, cancelButton, selectButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.alignment = .centerY

        let stack = NSStackView(views: [searchRow, scopeControl, description, scroll, statusRow, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 11
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            searchRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            searchField.heightAnchor.constraint(equalToConstant: 28),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 150),
            statusRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusRow.heightAnchor.constraint(greaterThanOrEqualToConstant: 28),
            progress.widthAnchor.constraint(equalToConstant: 16),
            progress.heightAnchor.constraint(equalToConstant: 16),
            buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            selectButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 112),
            cancelButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 76)
        ])
        window.initialFirstResponder = searchField
    }

    @objc private func refreshList() {
        loadInstruments()
        refreshPrices()
    }

    private func loadInstruments() {
        guard isPresented, !isLoading, Date() >= nextDirectoryAttempt else {
            updateStatus()
            return
        }
        loadTask?.cancel()
        loadGeneration += 1
        let generation = loadGeneration
        let client = self.client
        isLoading = true
        loadError = nil
        updateStatus()
        loadTask = Task { [weak self] in
            do {
                let result = try await client.fetchInstruments()
                guard !Task.isCancelled, let owner = self,
                      owner.loadGeneration == generation else { return }
                let preservedID = owner.selectedRowInstrument?.instId ?? owner.selectedID
                owner.instruments = result
                owner.onInstrumentsLoaded?(result)
                owner.isLoading = false
                owner.loadTask = nil
                owner.directoryRateLimitCount = 0
                owner.nextDirectoryAttempt = .distantPast
                let availableIDs = Set(owner.availableInstruments.map(\.instId))
                owner.prices = owner.prices.filter { availableIDs.contains($0.key) }
                owner.missingPriceIDs.formIntersection(availableIDs)
                owner.applyFilter(preferredID: preservedID)
                owner.refreshPrices()
            } catch {
                guard !Task.isCancelled, let owner = self,
                      owner.loadGeneration == generation else { return }
                owner.isLoading = false
                owner.loadTask = nil
                owner.loadError = error.localizedDescription
                if case PriceError.rateLimited(let retryAfter) = error {
                    owner.directoryRateLimitCount += 1
                    owner.nextDirectoryAttempt = Date().addingTimeInterval(
                        owner.backoff(retryAfter: retryAfter, failures: owner.directoryRateLimitCount))
                }
                owner.updateStatus()
            }
        }
    }

    private func startPriceTimer() {
        priceTimer?.invalidate()
        let timer = Timer(timeInterval: OKXClient.refreshInterval, repeats: true) { [weak self] _ in
            guard let owner = self else { return }
            Task { @MainActor in owner.priceTimerFired() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        priceTimer = timer
    }

    private func priceTimerFired() {
        guard isPresented else { return }
        if loadError != nil && !isLoading && Date() >= nextDirectoryAttempt {
            loadInstruments()
        }
        refreshPrices()
        // Re-evaluate the age even while requests are delayed by rate limiting.
        reloadPriceColumn()
        updateStatus()
    }

    private func refreshPrices() {
        guard isPresented else { return }
        guard !isLoadingPrices else {
            priceRefreshPending = true
            return
        }
        guard Date() >= nextPriceAttempt else {
            reloadPriceColumn()
            updateStatus()
            return
        }
        let requestedInstruments = availableInstruments
        guard !requestedInstruments.isEmpty else { updateStatus(); return }
        priceGeneration += 1
        let generation = priceGeneration
        let client = self.client
        isLoadingPrices = true
        priceRefreshPending = false
        updateStatus()
        priceTask = Task { [weak self] in
            do {
                let result = try await client.fetchQuotes(for: requestedInstruments)
                guard !Task.isCancelled, let owner = self,
                      owner.priceGeneration == generation, owner.isPresented else { return }
                let requestedIDs = Set(requestedInstruments.map(\.instId))
                let currentIDs = Set(owner.availableInstruments.map(\.instId))
                var receivedIDs: Set<String> = []
                for (id, quote) in result where requestedIDs.contains(id) && currentIDs.contains(id) {
                    guard quote.instrumentID == id else { continue }
                    owner.prices[id] = owner.prices[id]?.accepting(quote) ?? quote
                    receivedIDs.insert(id)
                }
                owner.missingPriceIDs = requestedIDs.intersection(currentIDs).subtracting(receivedIDs)
                owner.priceError = nil
                owner.priceRateLimitCount = 0
                owner.nextPriceAttempt = .distantPast
                owner.lastPriceRefresh = Date()
                owner.finishPriceRefresh()
            } catch {
                guard !Task.isCancelled, let owner = self,
                      owner.priceGeneration == generation, owner.isPresented else { return }
                owner.priceError = error.localizedDescription
                if case PriceError.rateLimited(let retryAfter) = error {
                    owner.priceRateLimitCount += 1
                    owner.nextPriceAttempt = Date().addingTimeInterval(
                        owner.backoff(retryAfter: retryAfter, failures: owner.priceRateLimitCount))
                }
                owner.finishPriceRefresh()
            }
        }
    }

    private func finishPriceRefresh() {
        isLoadingPrices = false
        priceTask = nil
        reloadPriceColumn()
        updateStatus()
        let shouldRefreshAgain = priceRefreshPending
        priceRefreshPending = false
        if shouldRefreshAgain { refreshPrices() }
    }

    private func reloadPriceColumn() {
        let column = table.column(withIdentifier: NSUserInterfaceItemIdentifier("price"))
        guard column >= 0, !filtered.isEmpty else { return }
        table.reloadData(forRowIndexes: IndexSet(integersIn: 0..<filtered.count),
                         columnIndexes: IndexSet(integer: column))
    }

    private func backoff(retryAfter: TimeInterval, failures: Int) -> TimeInterval {
        let exponential = min(900, 60 * pow(2, Double(min(max(0, failures - 1), 4))))
        return max(retryAfter, exponential)
    }

    private func priceIsStale(_ instrumentID: String, now: Date = Date()) -> Bool {
        guard let quote = prices[instrumentID] else { return true }
        return priceError != nil || missingPriceIDs.contains(instrumentID)
            || now.timeIntervalSince(quote.updatedAt) > 180
    }

    private func shortTime(_ date: Date) -> String {
        DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .medium)
    }

    private var availableInstruments: [SpotInstrument] {
        // Keep saved entries manageable even if the latest directory omits them.
        let combined = Self.uniqueWatchlist(instruments + watchlist)
        guard let quoteCurrency = quoteCurrency else { return combined }
        return combined.filter { $0.quoteCcy.uppercased() == quoteCurrency }
    }

    private var watchlistIDs: Set<String> { Set(watchlist.map(\.instId)) }

    private var isWatchlistScope: Bool { scopeControl.selectedSegment == 1 }

    private var scopedInstruments: [SpotInstrument] {
        let available = availableInstruments
        guard isWatchlistScope else { return available }
        let watched = watchlistIDs
        return available.filter { watched.contains($0.instId) }
    }

    private var selectedRowInstrument: SpotInstrument? {
        let row = table.selectedRow
        return filtered.indices.contains(row) ? filtered[row] : nil
    }

    private func applyFilter(preferredID: String? = nil, selectFirstIfMissing: Bool = true,
                             scrollToSelection: Bool = true) {
        let preservedID = preferredID ?? selectedRowInstrument?.instId
            ?? (selectFirstIfMissing ? selectedID : nil)
        filtered = SpotInstrument.matching(query: searchField.stringValue, in: scopedInstruments)
        table.reloadData()
        if let row = filtered.firstIndex(where: { $0.instId == preservedID }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            if scrollToSelection { table.scrollRowToVisible(row) }
        } else if selectFirstIfMissing && !filtered.isEmpty {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            if scrollToSelection { table.scrollRowToVisible(0) }
        } else {
            table.deselectAll(nil)
        }
        updateStatus()
    }

    @objc private func changeScope() {
        applyFilter(preferredID: selectedRowInstrument?.instId)
    }

    @objc private func toggleWatchlist(_ sender: WatchlistStarButton) {
        guard let instrument = availableInstruments.first(where: { $0.instId == sender.instrumentID }) else { return }
        var updated = watchlist
        if updated.contains(where: { $0.instId == instrument.instId }) {
            updated.removeAll { $0.instId == instrument.instId }
        } else {
            updated.append(instrument)
        }
        // Optimistic UI is reconciled by the app's updateWatchlist callback.
        updateWatchlist(updated)
        onWatchlistChange?(instrument)
    }

    private func updateStatus() {
        refreshButton.isEnabled = !isLoading && Date() >= nextDirectoryAttempt
        refreshButton.title = loadError == nil && priceError == nil ? "刷新列表" : "重试"
        // A background refresh must not block selecting a row already on screen.
        selectButton.isEnabled = selectedRowInstrument != nil
        if isLoading || isLoadingPrices {
            progress.startAnimation(nil)
        } else {
            progress.stopAnimation(nil)
        }
        var directoryStatus: String
        if isWatchlistScope && scopedInstruments.isEmpty {
            directoryStatus = "自选列表为空，切换到“全部现货”并点击 ☆ 添加。"
        } else if isLoading {
            directoryStatus = instruments.isEmpty ? "正在从 OKX 加载现货交易对…" : "正在刷新交易对列表 · 已显示 \(filtered.count) 个"
        } else if let error = loadError {
            directoryStatus = "列表加载失败：\(error)"
            directoryStatus += nextDirectoryAttempt > Date()
                ? " 最早 \(shortTime(nextDirectoryAttempt)) 重试。"
                : (instruments.isEmpty ? " 请点击“重试”。" : " 仍显示上次列表。")
        } else if filtered.isEmpty {
            directoryStatus = isWatchlistScope
                ? "自选中没有匹配的交易对，请调整搜索或切换到“全部现货”。"
                : searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "OKX 暂未返回可用的现货交易对。请刷新列表重试。"
                : "没有匹配的交易对，请尝试其他币种或完整交易对。"
        } else {
            directoryStatus = "找到 \(filtered.count) 个\(isWatchlistScope ? "自选" : "交易对") · 双击或按回车选择"
        }
        var priceStatus: [String] = []
        if let error = priceError {
            priceStatus.append("价格刷新失败，旧价已灰显：\(error)")
        } else if isLoadingPrices {
            priceStatus.append("正在刷新最新价格…")
        } else if !missingPriceIDs.isEmpty {
            priceStatus.append("部分价格暂不可用，保留上次价格")
        }
        if nextPriceAttempt > Date() {
            priceStatus.append("最早 \(shortTime(nextPriceAttempt)) 重试")
        }
        if let refreshed = lastPriceRefresh {
            priceStatus.append("最近刷新 \(shortTime(refreshed))")
        }
        priceStatus.append("每 30 秒刷新")
        statusLabel.stringValue = directoryStatus + "\n" + priceStatus.joined(separator: " · ")
        statusLabel.textColor = loadError != nil || priceError != nil ? .systemRed : .secondaryLabelColor
        statusLabel.toolTip = statusLabel.stringValue
    }

    func controlTextDidChange(_ notification: Notification) { applyFilter() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            confirmSelection()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            cancelSelection()
            return true
        }
        if commandSelector == #selector(NSResponder.moveDown(_:)) || commandSelector == #selector(NSResponder.moveUp(_:)) {
            guard !filtered.isEmpty else { return true }
            let change = commandSelector == #selector(NSResponder.moveDown(_:)) ? 1 : -1
            let row = max(0, min(filtered.count - 1, table.selectedRow + change))
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row)
            return true
        }
        return false
    }

    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard filtered.indices.contains(row), let column = tableColumn else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("symbolPicker.\(column.identifier.rawValue)Cell")
        let instrument = filtered[row]
        if column.identifier.rawValue == "favorite" {
            let button = tableView.makeView(withIdentifier: identifier, owner: self) as? WatchlistStarButton
                ?? WatchlistStarButton(frame: .zero)
            let watched = watchlistIDs.contains(instrument.instId)
            button.identifier = identifier
            button.instrumentID = instrument.instId
            button.setButtonType(.momentaryChange)
            button.isBordered = false
            button.font = .systemFont(ofSize: 20)
            button.title = watched ? "★" : "☆"
            button.contentTintColor = watched ? .systemYellow : .secondaryLabelColor
            button.target = self
            button.action = #selector(toggleWatchlist(_:))
            button.toolTip = watched ? "从自选移除 \(instrument.displayName)" : "将 \(instrument.displayName) 加入自选"
            button.setAccessibilityIdentifier("symbolPicker.favorite.\(instrument.instId)")
            button.setAccessibilityLabel(button.toolTip)
            return button
        }
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = identifier
            let label = NSTextField(labelWithString: "")
            label.font = .systemFont(ofSize: 13)
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            cell.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }
        if column.identifier.rawValue == "price" {
            let quote = prices[instrument.instId]
            cell.textField?.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
            cell.textField?.alignment = .right
            cell.textField?.stringValue = quote?.formattedPrice ?? "—"
            cell.textField?.textColor = priceIsStale(instrument.instId) ? .tertiaryLabelColor : .labelColor
            if let quote = quote {
                var details = ["\(instrument.displayName) · \(instrument.quoteCcy)", "行情时间：\(shortTime(quote.updatedAt))"]
                if priceIsStale(instrument.instId) { details.append("当前显示上次价格，行情可能已过期") }
                cell.toolTip = details.joined(separator: "\n")
            } else {
                cell.toolTip = "尚未获取 \(instrument.displayName) 的价格"
            }
        } else {
            cell.textField?.font = .systemFont(ofSize: 13)
            cell.textField?.alignment = .left
            cell.textField?.textColor = .labelColor
            cell.textField?.stringValue = column.identifier.rawValue == "pair" ? instrument.displayName : instrument.baseCcy
            cell.toolTip = watchlistIDs.contains(instrument.instId)
                && !instruments.contains(where: { $0.instId == instrument.instId })
                ? "自选交易对暂未在最新目录中返回，仍可点击 ★ 从自选移除。" : nil
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateStatus() }

    @objc private func confirmDoubleClick() {
        let favoriteColumn = table.column(withIdentifier: NSUserInterfaceItemIdentifier("favorite"))
        guard table.clickedRow >= 0, table.clickedColumn != favoriteColumn else { return }
        confirmSelection()
    }

    @objc private func confirmSelection() {
        guard let instrument = selectedRowInstrument else { return }
        selectedID = instrument.instId
        onSelect(instrument)
        close()
    }

    @objc private func cancelSelection() { close() }

    func windowWillClose(_ notification: Notification) {
        isPresented = false
        loadGeneration += 1
        loadTask?.cancel()
        loadTask = nil
        isLoading = false
        priceGeneration += 1
        priceTask?.cancel()
        priceTask = nil
        isLoadingPrices = false
        priceRefreshPending = false
        priceTimer?.invalidate()
        priceTimer = nil
        progress.stopAnimation(nil)
    }
}

@MainActor
private final class SymbolPickerTableView: NSTableView {
    var onConfirm: (() -> Void)?
    var onCancel: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let column = self.column(at: point)
        let row = self.row(at: point)
        if column >= 0, row >= 0, tableColumns[column].identifier.rawValue == "favorite",
           let button = view(atColumn: column, row: row, makeIfNecessary: true) as? WatchlistStarButton {
            // Track the control directly so a star click never selects its row.
            button.mouseDown(with: event)
            return
        }
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: onConfirm?()
        case 53: onCancel?()
        default: super.keyDown(with: event)
        }
    }
}

@MainActor
private final class WatchlistStarButton: NSButton {
    var instrumentID = ""

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
