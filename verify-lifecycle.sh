#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHECK_DIR="$PROJECT_DIR/.build/lifecycle"
mkdir -p "$CHECK_DIR/core" "$CHECK_DIR/module-cache"

# Keep the production classes intact and put their private test extensions in
# the same generated file. Only the application's process entry point is omitted.
python3 - "$PROJECT_DIR" "$CHECK_DIR" <<'PYTHON'
import pathlib
import sys

project = pathlib.Path(sys.argv[1])
output = pathlib.Path(sys.argv[2])
app = (project / 'Sources/BTCPrice/App.swift').read_text()
marker = '\n@main\n'
if app.count(marker) != 1:
    raise SystemExit('Expected exactly one application entry point')
picker = (project / 'Sources/BTCPrice/SymbolPickerWindow.swift').read_text()
(output / 'LifecycleVerification.swift').write_text(app.split(marker)[0] + '\n' + picker + '\n')
PYTHON

cat >> "$CHECK_DIR/LifecycleVerification.swift" <<'SWIFT'

// These extensions exercise the real lifecycle methods without creating a
// status-bar item, activating a window, or reading/writing app preferences.
@MainActor
private extension AppDelegate {
    func lifecycleStartTimer() -> Timer { startTimer(); return timer! }
    func lifecycleRefresh() -> Task<Void, Never>? { refresh(); return requestTask }
    var lifecycleRequest: Task<Void, Never>? { requestTask }
    var lifecycleStopped: Bool { timer == nil && requestTask == nil && !refreshInProgress }
    func lifecycleStop() {
        applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
    }
}

@MainActor
private extension SymbolPickerWindowController {
    func lifecyclePrepareHidden() {
        isPresented = true
        instruments = [.bitcoin]
    }
    func lifecycleStartTimer() -> Timer { startPriceTimer(); return priceTimer! }
    func lifecycleStartRequests() -> [Task<Void, Never>] {
        loadInstruments()
        refreshPrices()
        return [loadTask, priceTask].compactMap { $0 }
    }
    var lifecycleRequests: [Task<Void, Never>] { [loadTask, priceTask].compactMap { $0 } }
    var lifecycleStopped: Bool {
        !isPresented && priceTimer == nil && loadTask == nil && priceTask == nil
            && !isLoading && !isLoadingPrices && !priceRefreshPending
    }
    func lifecycleClose() { window?.close() }
}

private final class RequestLedger {
    private let lock = NSLock()
    private var starts = 0
    private var stops = 0
    func started() { lock.lock(); defer { lock.unlock() }; starts += 1 }
    func stopped() { lock.lock(); defer { lock.unlock() }; stops += 1 }
    var counts: (started: Int, stopped: Int) {
        lock.lock(); defer { lock.unlock() }
        return (starts, stops)
    }
}

/// Every request is intercepted locally and intentionally never completed.
/// Cancellation must reach stopLoading; there is no remote network fallback.
private final class HangingURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var installed: RequestLedger?
    private var ledger: RequestLedger?

    static func install(_ ledger: RequestLedger) {
        lock.lock(); defer { lock.unlock() }
        installed = ledger
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        ledger = Self.installed
        Self.lock.unlock()
        ledger?.started()
    }
    override func stopLoading() { ledger?.stopped() }
}

private struct LocalClient {
    let ledger = RequestLedger()
    let session: URLSession
    let client: OKXClient
    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HangingURLProtocol.self]
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 60
        session = URLSession(configuration: configuration)
        client = OKXClient(session: session)
        HangingURLProtocol.install(ledger)
    }
}

@MainActor
private enum Check {
    static var assertions = 0
    static var failures = 0
    static func expect(_ condition: Bool, _ message: String) {
        assertions += 1
        if !condition { failures += 1; print("FAIL: \(message)") }
    }
    static func run(_ name: String, _ body: () async -> Void) async {
        let previous = failures
        await body()
        if failures == previous { print("PASS: \(name)") }
    }
}

@MainActor
private func eventually(timeout: TimeInterval = 1, _ condition: () -> Bool) async -> Bool {
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    repeat {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    } while ProcessInfo.processInfo.systemUptime < deadline
    return condition()
}

@MainActor
private func drainQueuedCallbacks() async {
    try? await Task.sleep(nanoseconds: 80_000_000)
}

@main
private enum LifecycleVerification {
    @MainActor
    static func main() async {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)

        await Check.run("App timer resets and queued callback after stop") {
            let local = LocalClient()
            defer { local.session.invalidateAndCancel() }
            let owner = AppDelegate(client: local.client)
            var timers: [Timer] = []
            for _ in 0..<12 {
                timers.append(owner.lifecycleStartTimer())
                Check.expect(timers.dropLast().allSatisfy { !$0.isValid }, "App reset left an earlier timer valid")
            }
            Check.expect(timers.filter(\.isValid).count == 1, "App must have exactly one active timer")
            timers.last?.fire()
            owner.lifecycleStop()
            await drainQueuedCallbacks()
            Check.expect(timers.allSatisfy { !$0.isValid }, "App stop did not invalidate every timer")
            Check.expect(owner.lifecycleStopped, "App stop left refresh state active")
            Check.expect(local.ledger.counts.started == 0, "Queued App timer refreshed after stop")
        }

        await Check.run("App old callback after restart is ignored; current timer still works") {
            let local = LocalClient()
            defer { local.session.invalidateAndCancel() }
            let owner = AppDelegate(client: local.client)
            let old = owner.lifecycleStartTimer()
            old.fire()
            let current = owner.lifecycleStartTimer()
            await drainQueuedCallbacks()
            Check.expect(!old.isValid && current.isValid, "App restart did not replace the timer")
            Check.expect(local.ledger.counts.started == 0, "Old App timer refreshed after replacement")
            current.fire()
            let began = await eventually { local.ledger.counts.started == 1 }
            Check.expect(began, "Current App timer failed to start the local request")
            let task = owner.lifecycleRequest
            owner.lifecycleStop()
            Check.expect(task?.isCancelled == true, "App stop did not cancel its request task")
            let canceled = await eventually { local.ledger.counts.stopped == 1 }
            Check.expect(canceled, "App request cancellation did not reach URLProtocol")
            Check.expect(!current.isValid && owner.lifecycleStopped, "App stop did not clear current lifecycle state")
        }

        await Check.run("App releases during a hanging request before timeout") {
            let local = LocalClient()
            defer { local.session.invalidateAndCancel() }
            var owner: AppDelegate? = AppDelegate(client: local.client)
            weak var released = owner
            var timer: Timer?
            var task: Task<Void, Never>?
            autoreleasepool {
                timer = owner?.lifecycleStartTimer()
                task = owner?.lifecycleRefresh()
            }
            let began = await eventually { local.ledger.counts.started == 1 }
            Check.expect(began, "App release test did not reach a hanging request")
            autoreleasepool { owner = nil }
            let deallocated = await eventually { released == nil }
            Check.expect(deallocated, "App is retained across the network await")
            Check.expect(timer?.isValid == false, "App deinit did not invalidate its timer")
            Check.expect(task?.isCancelled == true, "App deinit did not cancel its request task")
            let canceled = await eventually { local.ledger.counts.stopped == 1 }
            Check.expect(canceled, "Released App left its hanging URLProtocol request alive")
            timer?.invalidate()
        }

        await Check.run("Picker timer resets and queued callback after hidden close") {
            let local = LocalClient()
            defer { local.session.invalidateAndCancel() }
            let owner = SymbolPickerWindowController(selected: .bitcoin, client: local.client) { _ in }
            Check.expect(owner.window?.isVisible == false, "Picker test unexpectedly displayed a window")
            owner.lifecyclePrepareHidden()
            var timers: [Timer] = []
            for _ in 0..<12 {
                timers.append(owner.lifecycleStartTimer())
                Check.expect(timers.dropLast().allSatisfy { !$0.isValid }, "Picker reset left an earlier timer valid")
            }
            Check.expect(timers.filter(\.isValid).count == 1, "Picker must have exactly one active timer")
            timers.last?.fire()
            owner.lifecycleClose()
            await drainQueuedCallbacks()
            Check.expect(timers.allSatisfy { !$0.isValid }, "Picker close did not invalidate its timer")
            Check.expect(owner.lifecycleStopped, "Picker close left requests or presentation state active")
            Check.expect(local.ledger.counts.started == 0, "Queued Picker timer refreshed after close")
        }

        await Check.run("Picker old callback after restart is ignored; current timer still works") {
            let local = LocalClient()
            defer { local.session.invalidateAndCancel() }
            let owner = SymbolPickerWindowController(selected: .bitcoin, client: local.client) { _ in }
            owner.lifecyclePrepareHidden()
            let old = owner.lifecycleStartTimer()
            old.fire()
            let current = owner.lifecycleStartTimer()
            await drainQueuedCallbacks()
            Check.expect(!old.isValid && current.isValid, "Picker restart did not replace the timer")
            Check.expect(local.ledger.counts.started == 0, "Old Picker timer refreshed after replacement")
            current.fire()
            let began = await eventually { local.ledger.counts.started == 1 }
            Check.expect(began, "Current Picker timer failed to start its local price request")
            let tasks = owner.lifecycleRequests
            owner.lifecycleClose()
            Check.expect(tasks.count == 1 && tasks.allSatisfy(\.isCancelled), "Picker close did not cancel its price task")
            let canceled = await eventually { local.ledger.counts.stopped == 1 }
            Check.expect(canceled, "Picker price cancellation did not reach URLProtocol")
            Check.expect(!current.isValid && owner.lifecycleStopped, "Picker close did not clear current lifecycle state")
        }

        await Check.run("Repeated hidden Picker present/close/release cancels both requests") {
            for cycle in 1...20 {
                let local = LocalClient()
                defer { local.session.invalidateAndCancel() }
                var owner: SymbolPickerWindowController? = SymbolPickerWindowController(selected: .bitcoin, client: local.client) { _ in }
                weak var released = owner
                owner?.lifecyclePrepareHidden()
                let timer = owner!.lifecycleStartTimer()
                let tasks = owner!.lifecycleStartRequests()
                let began = await eventually { local.ledger.counts.started == 2 }
                Check.expect(began && tasks.count == 2, "Picker cycle \(cycle) did not start directory and price requests")
                owner?.lifecycleClose()
                Check.expect(!timer.isValid && owner?.lifecycleStopped == true, "Picker cycle \(cycle) left its timer or state active")
                Check.expect(tasks.allSatisfy(\.isCancelled), "Picker cycle \(cycle) did not cancel both tasks")
                let canceled = await eventually { local.ledger.counts.stopped == 2 }
                Check.expect(canceled, "Picker cycle \(cycle) left a request alive after close")
                autoreleasepool { owner = nil }
                let deallocated = await eventually { released == nil }
                Check.expect(deallocated, "Picker cycle \(cycle) remained retained after close")
            }
        }

        await Check.run("Picker deinit is a fallback for a missing close notification") {
            let local = LocalClient()
            defer { local.session.invalidateAndCancel() }
            var owner: SymbolPickerWindowController? = SymbolPickerWindowController(selected: .bitcoin, client: local.client) { _ in }
            weak var released = owner
            owner?.lifecyclePrepareHidden()
            let timer = owner!.lifecycleStartTimer()
            let tasks = owner!.lifecycleStartRequests()
            let began = await eventually { local.ledger.counts.started == 2 }
            Check.expect(began && tasks.count == 2, "Picker deinit test did not start both hanging requests")
            autoreleasepool { owner = nil }
            let deallocated = await eventually { released == nil }
            Check.expect(deallocated, "Picker is retained across a network await")
            Check.expect(!timer.isValid, "Picker deinit did not invalidate its timer")
            Check.expect(tasks.allSatisfy(\.isCancelled), "Picker deinit did not cancel both request tasks")
            let canceled = await eventually { local.ledger.counts.stopped == 2 }
            Check.expect(canceled, "Picker deinit left a hanging URLProtocol request alive")
            timer.invalidate()
        }

        print("\nLifecycle verification: 7 scenarios, \(Check.assertions) assertions, \(Check.failures) failures.")
        exit(Check.failures == 0 ? 0 : 1)
    }
}
SWIFT

xcrun swiftc -parse-as-library -target "$(uname -m)-apple-macosx13.0" \
  -module-cache-path "$CHECK_DIR/module-cache" \
  -emit-library -static -emit-module -module-name BTCPriceCore \
  -emit-module-path "$CHECK_DIR/core/BTCPriceCore.swiftmodule" \
  "$PROJECT_DIR"/Sources/BTCPriceCore/*.swift \
  -o "$CHECK_DIR/core/libBTCPriceCore.a"

xcrun swiftc -parse-as-library -target "$(uname -m)-apple-macosx13.0" \
  -module-cache-path "$CHECK_DIR/module-cache" \
  -I "$CHECK_DIR/core" -L "$CHECK_DIR/core" -lBTCPriceCore -framework AppKit \
  "$CHECK_DIR/LifecycleVerification.swift" -o "$CHECK_DIR/verify-lifecycle"

unset BTC_PRICE_DIAGNOSTICS_PATH
"$CHECK_DIR/verify-lifecycle"
