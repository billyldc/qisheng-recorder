import AppKit
import ReplayCore
import SwiftUI

@MainActor
func runSelfTest() {
    do {
        try checkCredentialSessionReuse()
        try checkKeyboardEventPairs()
        let old = Data(#"{"outputDirectory":"/tmp/old-output","targetBundleID":"com.apple.Safari","speed2x":true,"profiles":{"12-1000x700":{"label":"external","speed":{"x":0.9,"y":0.8}}}}"#.utf8)
        let migrated = try JSONDecoder().decode(Settings.self, from: old)
        guard migrated.outputDirectory == "/tmp/old-output", migrated.targetBundleID == "com.apple.Safari",
              migrated.speed2x, !migrated.bothPerspectives, migrated.captureMode == .region, !migrated.unattended, migrated.showHUD,
              migrated.cloudKeepAlive, migrated.keepAliveSeconds == 60,
              migrated.legacyCalibrationBundleID == "com.apple.Safari", !migrated.cloudAutoLogin, !migrated.cloudAutoAcceptAgreements,
              migrated.profiles["12-1000x700"]?.speed == UnitPoint(x: 0.9, y: 0.8) else {
            throw RecorderError.message("Existing settings migration failed")
        }
        let disabled = try JSONDecoder().decode(Settings.self, from: Data(#"{"cloudKeepAlive":false,"keepAliveSeconds":75}"#.utf8))
        let roundTrip = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(disabled))
        guard !roundTrip.cloudKeepAlive, roundTrip.keepAliveSeconds == 75 else { throw RecorderError.message("Keep-alive preferences not preserved") }
        let invalid = try JSONDecoder().decode(Settings.self, from: Data(#"{"keepAliveSeconds":1e90}"#.utf8))
        guard invalid.keepAliveSeconds == 60 else { throw RecorderError.message("Invalid keep-alive interval was not normalized") }
        var views = Settings(); views.bothPerspectives = true
        guard try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(views)).bothPerspectives else {
            throw RecorderError.message("Both-perspective preference was not preserved")
        }
        let idle = AppModel(persistent: false)
        for previousDuration in [0, 280, 375, 1200] {
            idle.elapsed = previousDuration
            idle.markRecordingStarted()
            guard idle.elapsed == 0, idle.recording else {
                throw RecorderError.message("Each new take must reset the previous duration before the first frame")
            }
        }
        idle.recording = false
        idle.screenAllowed = true; idle.accessibilityAllowed = true
        guard idle.canKeepAlive, idle.keepAliveAvailabilityNote.contains("选好即开始") else {
            throw RecorderError.message("Keep-alive must offer calibration rather than an unexplained disabled button")
        }
        idle.busy = true
        guard !idle.canKeepAlive, idle.keepAliveAvailabilityNote.contains("结束当前操作") else {
            throw RecorderError.message("Keep-alive must remain unavailable while another operation is active")
        }
        idle.busy = false; idle.accessibilityAllowed = false
        guard idle.canKeepAlive, idle.keepAliveAvailabilityNote.contains("辅助功能") else {
            throw RecorderError.message("Missing keep-alive permission must have a visible explanation")
        }
        idle.cancelWindowChoice()
        var consent = Settings()
        consent.cloudAutoLogin = true; consent.cloudAutoAcceptAgreements = true
        let allowed = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(consent))
        guard allowed.cloudAutoLogin, allowed.cloudAutoAcceptAgreements else { throw RecorderError.message("Explicit agreement preference was not preserved") }
        consent.cloudAutoAcceptAgreements = false
        let revoked = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(consent))
        guard revoked.cloudAutoLogin, !revoked.cloudAutoAcceptAgreements else { throw RecorderError.message("Agreement opt-out must not disable password login") }
        let point = CGPoint(x: -1300, y: 430)
        let moves = try PointerInput.keepAlive.events(at: point)
        guard moves.count == 2, moves.allSatisfy({ $0.type == .mouseMoved }),
              moves[0].location == CGPoint(x: point.x + 2, y: point.y), moves[1].location == point,
              moves[0].getIntegerValueField(.mouseEventDeltaX) == 2,
              moves[1].getIntegerValueField(.mouseEventDeltaX) == -2 else {
            throw RecorderError.message("Keep-alive must contain only two mouse moves")
        }
        let clicks = try PointerInput.click.events(at: point)
        guard clicks.map(\.type) == [.mouseMoved, .leftMouseDown, .leftMouseUp], clicks.allSatisfy({ $0.location == point }) else {
            throw RecorderError.message("Replay click event sequence changed")
        }
        let view = SelectionView(frame: CGRect(x: 0, y: 0, width: 1200, height: 800))
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        func mouse(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 120, y: 100)))
        view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 1120, y: 740)))
        view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 1120, y: 740)))
        guard view.selected == CGRect(x: 120, y: 100, width: 1000, height: 640) else { throw RecorderError.message("Native drag geometry failed") }
        var confirmed = false
        view.done = { region in confirmed = region == view.selected }
        let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        view.keyDown(with: enter)
        guard confirmed else { throw RecorderError.message("Enter confirmation failed") }
        view.displayIfNeeded()
        if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let path = FileManager.default.temporaryDirectory.appendingPathComponent("qisheng-selector-selftest.png")
            try bitmap.representation(using: .png, properties: [:])?.write(to: path)
        }
        print("PASS: per-character keyboard event pairs, credential-session reuse/invalidation, settings migration, agreement opt-in/opt-out, keep-alive preferences and move-only events, click event pairing, native drag, Enter confirmation")
        NSApp.terminate(nil)
    } catch {
        fputs("Self-test failed: \(error)\n", stderr)
        exit(1)
    }
}

@MainActor
func runVisualSelfTest() {
    let model = AppModel(persistent: false)
    model.screenAllowed = true; model.accessibilityAllowed = true
    model.settings.captureMode = .window
    model.settings.unattended = true
    model.region = CaptureRegion(displayID: CGMainDisplayID(), displaySize: CGSize(width: 1512, height: 982),
                                 sourceRect: CGRect(x: 100, y: 100, width: 1100, height: 700), scale: 2, windowID: 123)
    model.rows = [Replay(id: 1, date: "2000-02-03_0405", mode: "匹配模式",
                         left: ["诺艾尔", "安柏", "凯亚"], right: ["丽莎", "芭芭拉", "迪卢克"], play: UnitPoint(x: 0.94, y: 0.2))]
    model.status = "已读取 1 局。请核对角色、日期和模式，再试录检查边框与声音。"
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 780),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.contentView = NSHostingView(rootView: MainView(model: model))
    window.makeKeyAndOrderFront(nil)
    let hud = RecordingHUD()
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
        func save(_ view: NSView, _ filename: String) {
            view.layoutSubtreeIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/\(filename)"))
        }
        save(window.contentView!, "qisheng-main-selftest.png")
        model.busy = true; model.recording = true; model.activeRow = 1; model.elapsed = 95
        model.status = "已点击一次二倍速，图像识别未确认；保持当前速度继续录制，不重复点击。"
        hud.show(model: model, displayID: CGMainDisplayID())
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if let panel = NSApp.windows.first(where: { $0 is NSPanel && $0.isVisible }), let view = panel.contentView {
                save(view, "qisheng-hud-selftest.png")
            }
            hud.close()
            let setup = AppModel(persistent: false)
            setup.screenAllowed = false; setup.accessibilityAllowed = false
            setup.cloudAccountSaved = true
            window.contentView = NSHostingView(rootView: MainView(model: setup))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                save(window.contentView!, "qisheng-cloud-settings-selftest.png")
                setup.settings.cloudAutoAcceptAgreements = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    save(window.contentView!, "qisheng-cloud-settings-enabled-selftest.png")
                    print("Visual checks: main, HUD and cloud settings (opted out / opted in) saved in /tmp/qisheng-*-selftest.png")
                    window.orderOut(nil)
                    NSApp.terminate(nil)
                }
            }
        }
    }
}
