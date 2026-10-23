import AppKit
import ReplayCore

// Uses real AppKit windows and WindowServer ordering, but posts no input events.
@MainActor
func runInputSelfTest() {
    Task { @MainActor in
        let reportURL = FileManager.default.temporaryDirectory.appendingPathComponent("qisheng-input-selftest.txt")
        var report = ["screen=\(CGPreflightScreenCaptureAccess()) accessibility=\(AXIsProcessTrusted())"]
        let model = AppModel(persistent: false)
        let hud = RecordingHUD()
        let screen = NSScreen.main!
        let fixture = NSWindow(contentRect: screen.visibleFrame.insetBy(dx: 4, dy: 4),
                               styleMask: [.borderless], backing: .buffered, defer: false)
        fixture.title = "Qisheng input regression fixture"
        fixture.isReleasedWhenClosed = false
        fixture.animationBehavior = .none
        fixture.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1)
        fixture.backgroundColor = .windowBackgroundColor
        fixture.contentView = NSButton(title: "Input regression fixture (no clicks)", target: nil, action: nil)
        fixture.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer { hud.close(); fixture.orderOut(nil); fixture.close() }
        do {
            try await Task.sleep(for: .milliseconds(500))
            let target = CaptureWindow(id: CGWindowID(fixture.windowNumber), ownerPID: ProcessInfo.processInfo.processIdentifier,
                                       title: fixture.title, frame: CGRect(x: fixture.frame.minX,
                                       y: CGDisplayBounds(CGMainDisplayID()).height - fixture.frame.maxY,
                                       width: fixture.frame.width, height: fixture.frame.height), onScreen: true)
            for pass in 1...5 {
                hud.show(model: model, displayID: CGMainDisplayID())
                try await Task.sleep(for: .milliseconds(100))
                guard let panel = NSApp.windows.first(where: { $0 is NSPanel && $0.isVisible }) else {
                    throw RecorderError.message("HUD missing")
                }
                // Keep this fixture away from unrelated desktop corner overlays.
                panel.setFrameOrigin(CGPoint(x: screen.visibleFrame.midX - panel.frame.width / 2,
                                             y: screen.visibleFrame.midY - panel.frame.height / 2))
                try await Task.sleep(for: .milliseconds(100))
                let point = CGPoint(x: panel.frame.midX, y: CGDisplayBounds(CGMainDisplayID()).height - panel.frame.midY)
                let covered = target.checkClick(point)
                report.append("\(pass) HUD visible: allowed=\(covered.allowed) \(covered.detail)")
                guard !covered.allowed else { throw RecorderError.message("Visible HUD incorrectly treated as click-through") }
                try await hud.hideForClick()
                let clear = target.checkClick(point)
                report.append("\(pass) HUD hidden: allowed=\(clear.allowed) \(clear.detail)")
                guard clear.allowed else { throw RecorderError.message("Hidden HUD still blocks input") }
                hud.restore()
                try await Task.sleep(for: .milliseconds(100))
                guard panel.isVisible, !panel.ignoresMouseEvents else { throw RecorderError.message("HUD Stop button not restored") }
                guard !target.checkClick(point).allowed else { throw RecorderError.message("Restored HUD no longer blocks clicks") }
            }
            hud.close()
            let obstruction = NSPanel(contentRect: fixture.frame.insetBy(dx: 50, dy: 50),
                                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            obstruction.level = .popUpMenu
            obstruction.isReleasedWhenClosed = false
            obstruction.orderFrontRegardless()
            defer { obstruction.orderOut(nil); obstruction.close() }
            try await Task.sleep(for: .milliseconds(100))
            guard !target.checkClick(CGPoint(x: target.frame.midX, y: target.frame.midY)).allowed else {
                throw RecorderError.message("Another same-process panel incorrectly whitelisted")
            }
            report.append("PASS: five HUD show/hide/restore cycles and unrelated same-process panel protection")
        } catch { report.append("FAIL: \(error.localizedDescription)") }
        try? report.joined(separator: "\n").write(to: reportURL, atomically: true, encoding: .utf8)
        print(report.joined(separator: "\n"))
        if report.last?.hasPrefix("FAIL") == true { exit(1) }
        NSApp.terminate(nil)
    }
}
