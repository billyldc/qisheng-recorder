import AppKit
import ApplicationServices
import ReplayCore

@MainActor
func runKeepAliveSelfTest() {
    Task {
        var liveModel: AppModel?
        @MainActor func stopLiveModel() async {
            guard let model = liveModel else { return }
            model.stop()
            let deadline = ProcessInfo.processInfo.systemUptime + 10
            while model.busy && ProcessInfo.processInfo.systemUptime < deadline {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        do {
            var identities = AccessibilityIdentitySet()
            let first = AXUIElementCreateApplication(getpid())
            precondition(identities.insert(first))
            precondition(!identities.insert(first))
            precondition(!identities.insert(AXUIElementCreateApplication(getpid())))
            for offset in 1...100 {
                let element = AXUIElementCreateApplication(getpid() + Int32(offset))
                precondition(identities.insert(element))
                for _ in 0..<4 { precondition(!identities.insert(element)) }
            }
            precondition(identities.count == 101)
            let selections: [Bool?] = [true, false, false, false, false, false, false]
            precondition(BrowserKeepAliveBinding.resolve(selections: Array(repeating: selections, count: 4).flatMap { $0 },
                hasUniqueOfficialDocument: true) == nil, "The old four-path tree reproduces the rejection")
            precondition(BrowserKeepAliveBinding.resolve(selections: selections, hasUniqueOfficialDocument: true) == .tab(0))
            precondition(BrowserKeepAliveBinding.resolve(selections: [true, true], hasUniqueOfficialDocument: true) == nil,
                "Two genuinely selected controls must not become one by name or geometry")
            print("PASS: AX element identity, repeated paths, distinct elements and ambiguous-selection rejection; no input posted")

            if ProcessInfo.processInfo.environment["QISHENG_LIVE_KEEPALIVE_BINDING"] == "1" {
                guard AXIsProcessTrusted(),
                      let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome").first else {
                    throw RecorderError.message("Read-only live check needs existing accessibility access and Chrome")
                }
                var windows: [CaptureWindow] = []
                for _ in 0..<6 {
                    windows = CaptureWindow.list(pid: app.processIdentifier).filter {
                        SafariLauncher.cloudDocumentForKeepAlive($0) != nil
                    }
                    if windows.count != 0 { break }
                    try await Task.sleep(for: .milliseconds(250))
                }
                guard windows.count == 1 else { throw RecorderError.message("Read-only live check needs one unique official game window") }
                let window = windows[0]
                let tabs = try window.browserTabs()
                let selections = tabs.map(KeepAliveTarget.selection)
                guard selections.filter({ $0 == true }).count == 1 else {
                    throw RecorderError.message("Production traversal did not find one selected tab")
                }
                let stale = CaptureWindow(id: window.id, ownerPID: window.ownerPID, title: window.title,
                    frame: window.frame.offsetBy(dx: 0, dy: -122), onScreen: window.onScreen)
                let target = try await KeepAliveTarget.bind(window: stale, bundleID: app.bundleIdentifier!)
                try target.validateSelectedTab()
                guard try target.currentWindow().id == window.id else { throw RecorderError.message("Window identity changed") }
                print("PASS: production live binding: \(tabs.count) unique tabs / one selected; stale fullscreen snapshot reacquired; no activation, capture, input, login or settings changes")
                if ProcessInfo.processInfo.environment["QISHENG_LIVE_KEEPALIVE_PULSES"] == "1" {
                    let model = AppModel(persistent: false)
                    liveModel = model
                    model.settings.targetBundleID = "com.google.Chrome"
                    model.settings.keepAliveSeconds = 15
                    model.settings.showHUD = false
                    model.startKeepAlive()
                    guard model.choosingWindow, model.choosingKeepAliveWindow else {
                        throw RecorderError.message(model.error ?? "Live keep-alive did not reach window selection")
                    }
                    model.useWindow(stale)
                    let deadline = ProcessInfo.processInfo.systemUptime + 50
                    while model.keepAliveCount < 3 && ProcessInfo.processInfo.systemUptime < deadline {
                        if let error = model.error { throw RecorderError.message(error) }
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    let pulses = model.keepAliveCount
                    guard model.keepAliveOnly, !model.recording, pulses >= 3 else {
                        throw RecorderError.message("Live keep-alive did not produce three confirmed move-only pulses")
                    }
                    await stopLiveModel()
                    guard !model.busy, !model.keepAliveOnly, !model.recording else {
                        throw RecorderError.message("Live keep-alive did not stop cleanly")
                    }
                    try await Task.sleep(for: .seconds(1))
                    guard model.keepAliveCount == pulses else { throw RecorderError.message("Input continued after Stop") }
                    try window.raise()
                    print("PASS: production AppModel window selection/binding -> \(pulses) real move-only pulses -> Stop; no recording, click, key, login or saved settings; temporary session protection released")
                }
            }
            NSApp.terminate(nil)
        } catch {
            await stopLiveModel()
            fputs("Keep-alive self-test failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
