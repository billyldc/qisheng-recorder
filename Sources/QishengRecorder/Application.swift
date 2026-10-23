import SwiftUI
import AppKit
import Carbon

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel(persistent: !CommandLine.arguments.contains(where: { $0.hasSuffix("self-test") || $0 == "--install-update" }))
    private var menuItem: NSStatusItem?
    private var hotkeys: [EventHotKeyRef?] = []
    private var handler: EventHandlerRef?
    private var selectorTest: RegionSelector?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--install-update") {
            AppUpdater.runInstaller()
            return
        }
        if CommandLine.arguments.contains("--update-exit-self-test") {
            model.busy = true
            Task { model.updater.terminateForInstaller() }
            return
        }
        if CommandLine.arguments.contains("--self-test") {
            runSelfTest()
            return
        }
        if CommandLine.arguments.contains("--perspective-self-test") {
            runPerspectiveSelfTest()
            return
        }
        if CommandLine.arguments.contains("--views-ui-self-test") {
            runViewsUISelfTest()
            return
        }
        if CommandLine.arguments.contains("--update-self-test") {
            runUpdateSelfTest()
            return
        }
        if CommandLine.arguments.contains("--input-self-test") {
            runInputSelfTest()
            return
        }
        if CommandLine.arguments.contains("--visual-self-test") {
            runVisualSelfTest()
            return
        }
        if CommandLine.arguments.contains("--review-self-test") {
            runReviewSelfTest()
            return
        }
        if CommandLine.arguments.contains("--gallery-self-test") {
            runCharacterLibrarySelfTest()
            return
        }
        if CommandLine.arguments.contains("--credentials-self-test") {
            runCloudAccountSelfTest()
            return
        }
        if CommandLine.arguments.contains("--keyboard-self-test") {
            runKeyboardInputSelfTest()
            return
        }
        if CommandLine.arguments.contains("--selector-test") {
            selectorTest = RegionSelector()
            let argument = CommandLine.arguments.first(where: { $0.hasPrefix("--display-id=") })
            let display = argument.flatMap { UInt32($0.dropFirst("--display-id=".count)) } ?? CGMainDisplayID()
            selectorTest?.select(displayID: display) { region in
                if let region { print("SELECTED: display=\(region.displayID) sourceRect=\(region.sourceRect)") }
                else { print("CANCELLED") }
                NSApp.terminate(nil)
            }
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 780), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "七圣召唤录制器"
        window.contentView = NSHostingView(rootView: MainView(model: model))
        window.isReleasedWhenClosed = false
        window.center()
        model.mainWindow = window
        model.showWindow()
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "显示录制器", action: #selector(showMain), keyEquivalent: "0").target = self
        appMenu.addItem(withTitle: "检查更新…", action: #selector(checkUpdate), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出七圣召唤录制器", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu; mainMenu.addItem(editItem); NSApp.mainMenu = mainMenu

        menuItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        menuItem?.button?.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "七圣召唤录制器")
        let menu = NSMenu()
        menu.addItem(withTitle: "显示录制器", action: #selector(showMain), keyEquivalent: "").target = self
        menu.addItem(withTitle: "停止保活 / 停止并保存", action: #selector(stop), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        menuItem?.menu = menu
        registerHotkeys()
    }
    @objc private func showMain() { model.showWindow() }
    @objc private func checkUpdate() {
        guard !model.busy && !model.selectionActive && model.reviewingVideo == nil else { return }
        model.busy = true
        Task { defer { model.busy = false }; await model.updater.checkAndOffer() }
    }
    @objc private func stop() { model.stop() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { CloudAccountKeychain.clearSession() }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model.reviewQueue.removeAll()
        Metadata.cancelReview()
        if model.updater.installerLaunched { return .terminateNow }
        guard model.busy else { return .terminateNow }
        model.stop()
        Task {
            while model.busy { try? await Task.sleep(for: .milliseconds(200)) }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    private func registerHotkeys() {
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context -> OSStatus in
            guard let event, let context else { return noErr }
            var key = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &key)
            let delegate = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in if key.id == 2 { delegate.model.stop() } else { delegate.model.showWindow() } }
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
        for (id, key) in [(1, kVK_ANSI_R), (2, kVK_ANSI_S)] {
            var reference: EventHotKeyRef?
            let result = RegisterEventHotKey(UInt32(key), UInt32(cmdKey | shiftKey), EventHotKeyID(signature: 0x51535243, id: UInt32(id)), GetApplicationEventTarget(), 0, &reference)
            if result == noErr { hotkeys.append(reference) }
            else { model.addLog("全局快捷键注册失败：\(id)，仍可使用菜单栏。") }
        }
    }
}

@main
struct RecorderApplication {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}
