import AppKit
import ApplicationServices
import AVFoundation
import ReplayCore

@MainActor
final class AppModel: ObservableObject {
    @Published var settings = Settings.load() { didSet { if persistent { settings.save() } } }
    @Published var screenAllowed = CGPreflightScreenCaptureAccess()
    @Published var accessibilityAllowed = AXIsProcessTrusted()
    @Published var region: CaptureRegion?
    @Published var preview: NSImage?
    @Published var rows: [Replay] = []
    @Published var status = "先完成权限设置，再选取游戏区域。" {
        didSet { if status != oldValue { addLog(status) } }
    }
    @Published var error: String?
    @Published var busy = false
    @Published var recording = false
    @Published var stopping = false
    @Published var selectionActive = false
    @Published var entries: [RecordingEntry] = []
    @Published var elapsed = 0
    @Published var activeRow: Int?
    @Published var activePerspective: ReplayPerspective?
    @Published private(set) var keepAliveCount = 0
    @Published private(set) var keepAliveOnly = false
    @Published private(set) var keepAliveTarget: KeepAliveTarget?
    @Published var choosingKeepAliveWindow = false
    @Published var cloudLaunchPhase = CloudLaunchPhase.idle
    @Published var configuringCloudAccount = false
    @Published var cloudAccountSaved = false
    @Published var canUndoCloudAccountRemoval = false
    private var removedCloudCredentials: CloudCredentials?
    private var removedCloudAutoLogin = false
    private var accountRemovalTask: Task<Void, Never>?
    let updater = AppUpdater()
    @Published var log: [String] = []
    @Published var windowChoices: [CaptureWindow] = []
    @Published var choosingWindow = false
    @Published var assetStatus = "内置离线角色库"
    @Published var assetDetails = ""
    @Published var reviewVideos: [URL] = []
    @Published var reviewMessages: [URL: String] = [:]
    @Published var reviewingVideo: URL?
    @Published var editingReviewVideo: URL?
    @Published var reviewQueue: [URL] = []
    private var lastAutomaticAssetCheck = Date.distantPast
    var mainWindow: NSWindow?
    private let selector = RegionSelector()
    private let recorder = ScreenRecorder()
    private let session = RecordingSession()
    private let hud = RecordingHUD()
    private var operation: Task<Void, Never>?
    private var startedAt: Date?
    private var permissionsTimer: Timer?
    private var stopRequested = false
    private var sessionRunning = false
    private var interruption: Error?
    private var focusLostAt: Date?
    private var startAfterKeepAliveSelection = false
    private let persistent: Bool

    init(persistent: Bool = true) {
        self.persistent = persistent
        if !persistent { settings = Settings() }
        else if let saved = try? String(contentsOf: Settings.directory.appendingPathComponent("session.log"), encoding: .utf8) {
            log = Array(saved.split(separator: "\n").suffix(200).map(String.init))
        }
        guard persistent else { return }
        cloudAccountSaved = CloudAccountKeychain.configured()
        if let data = try? Data(contentsOf: Settings.directory.appendingPathComponent("review-videos.json")),
           let videos = try? JSONDecoder().decode([URL].self, from: data) {
            reviewVideos = videos.filter { FileManager.default.fileExists(atPath: $0.path) }
            reviewQueue = reviewVideos.filter { VideoReview.load($0) == nil }
            for video in reviewVideos { reviewMessages[video] = VideoReview.load(video)?.summary ?? "待复核" }
        }
        refreshAssetStatus()
        permissionsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshPermissions()
                if let start = self?.startedAt { self?.elapsed = Int(Date().timeIntervalSince(start)) }
                self?.monitorSession()
                self?.runNextReview()
                self?.checkAutomaticAssets()
            }
        }
    }
    var ready: Bool { screenAllowed && accessibilityAllowed }
    var displays: [(id: UInt32, label: String)] {
        NSScreen.screens.compactMap { screen in
            guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { return nil }
            return (id, "\(screen.localizedName) · \(Int(screen.frame.width)) × \(Int(screen.frame.height))")
        }
    }
    private func selectionDisplay() throws -> UInt32 {
        let ids = displays.map(\.id)
        if let explicit = settings.captureDisplayID {
            guard ids.contains(explicit) else { throw RecorderError.message("指定的显示器已断开，请重新选择显示器。") }
            return explicit
        }
        guard let target = targetApplication() else { throw RecorderError.message("请先打开目标应用。") }
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for window in windows {
            guard (window[kCGWindowOwnerPID as String] as? Int32) == target.processIdentifier,
                  (window[kCGWindowLayer as String] as? Int) == 0,
                  let dictionary = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dictionary), bounds.width > 100, bounds.height > 100,
                  let index = RegionGeometry.displayIndex(window: bounds, displays: ids.map { CGDisplayBounds($0) }) else { continue }
            return ids[index]
        }
        throw RecorderError.message("找不到目标应用的可见窗口。请先显示游戏窗口，或指定选框显示器。")
    }
    var profileKey: String {
        guard let region else { return "unselected" }
        return "\(settings.targetBundleID)-\(region.windowID == nil ? "region" : "window")-\(legacyProfileKey)"
    }
    private var legacyProfileKey: String {
        guard let region else { return "unselected" }
        return "\(region.displayID)-\(Int(region.sourceRect.width))x\(Int(region.sourceRect.height))"
    }
    var calibration: Calibration {
        settings.profiles[profileKey] ?? (region?.windowID == nil && settings.legacyCalibrationBundleID == settings.targetBundleID ? settings.profiles[legacyProfileKey] : nil) ?? Calibration(label: profileKey)
    }
    var selectedRows: [Replay] { rows.filter(\.selected) }
    var canStart: Bool { ready && region != nil && !busy && !selectionActive && !selectedRows.isEmpty }
    var canKeepAlive: Bool { !busy && !selectionActive && editingReviewVideo == nil }
    var keepAliveAvailabilityNote: String {
        if !screenAllowed || !accessibilityAllowed { return "请先在「首次设置」开启屏幕录制和辅助功能权限；点击「只保活」会提示缺少的权限。" }
        if keepAliveOnly {
            return keepAliveTarget?.usesDocumentBinding == true
                ? "只保活正在运行，绑定 Safari 当前云原神页面；页面身份改变后停止并需重选。不录制，关闭主窗口仍继续，锁屏或退出时停止。"
                : "只保活正在运行，不录制；关闭主窗口仍继续，锁屏或退出应用时停止。"
        }
        if busy || selectionActive || editingReviewVideo != nil { return "请先结束当前操作，再启动只保活。" }
        if keepAliveTarget == nil { return "首次使用或重开应用后，点击「只保活」选择原神标签页所在窗口，选好即开始；不需要识别对局。" }
        if keepAliveTarget?.usesDocumentBinding == true {
            return "已绑定 Safari 当前云原神页面，不要求显示单标签栏；页面身份改变后停止并需重选。定期切回窗口，不录制；关闭主窗口仍继续，锁屏或退出时停止。"
        }
        return "只保活会定期切回已校准的游戏标签页，不录制；关闭主窗口仍继续，锁屏或退出应用时停止。"
    }

    func cloudAccountWasSaved() {
        accountRemovalTask?.cancel(); removedCloudCredentials = nil; canUndoCloudAccountRemoval = false
        cloudAccountSaved = true
        settings.cloudAutoLogin = true
        status = "云原神账号已保存到本机钥匙串，已开启自动密码登录。"
    }

    func removeCloudAccount() {
        do {
            guard let old = try CloudAccountKeychain.load() else { cloudAccountSaved = false; return }
            try CloudAccountKeychain.remove()
            accountRemovalTask?.cancel()
            removedCloudCredentials = old; canUndoCloudAccountRemoval = true
            removedCloudAutoLogin = settings.cloudAutoLogin
            cloudAccountSaved = false; settings.cloudAutoLogin = false
            status = "已移除云原神账号，5 秒内可撤回。"
            accountRemovalTask = Task {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                self.removedCloudCredentials = nil; self.canUndoCloudAccountRemoval = false
            }
        } catch { fail(error) }
    }

    func undoCloudAccountRemoval() {
        guard let credentials = removedCloudCredentials else { return }
        do {
            try CloudAccountKeychain.save(credentials)
            let enabled = removedCloudAutoLogin
            cloudAccountWasSaved()
            settings.cloudAutoLogin = enabled
            status = "已恢复云原神账号及原来的自动登录设置。"
        } catch { fail(error) }
    }

    func chooseKeepAliveWindow() {
        guard canKeepAlive else { return }
        startAfterKeepAliveSelection = false
        choosingKeepAliveWindow = true
        chooseWindow()
        if !choosingWindow { choosingKeepAliveWindow = false }
    }

    func cancelWindowChoice() {
        choosingWindow = false; choosingKeepAliveWindow = false; startAfterKeepAliveSelection = false
    }

    func refreshPermissions() {
        screenAllowed = CGPreflightScreenCaptureAccess()
        accessibilityAllowed = AXIsProcessTrusted()
    }
    func requestScreenPermission() {
        _ = CGRequestScreenCaptureAccess()
        openPrivacy("Privacy_ScreenCapture")
        refreshPermissions()
    }
    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        openPrivacy("Privacy_Accessibility")
        refreshPermissions()
    }
    func openPrivacy(_ key: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(key)") { NSWorkspace.shared.open(url) }
    }
    func showWindow() { NSApp.activate(ignoringOtherApps: true); mainWindow?.makeKeyAndOrderFront(nil) }
    func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: settings.outputDirectory)
        if panel.runModal() == .OK, let url = panel.url { settings.outputDirectory = url.path }
    }
    func openOutput() { NSWorkspace.shared.open(URL(fileURLWithPath: settings.outputDirectory)) }
    func targetApplication() -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: settings.targetBundleID).first
    }
    func focusTarget() throws {
        guard session.unlocked else { throw RecorderError.message("桌面已锁定或当前会话不可用，请先解锁。") }
        guard let app = targetApplication() else { throw RecorderError.message("请先打开目标应用，并进入七圣召唤收藏对局界面。") }
        let windows = CaptureWindow.list(pid: app.processIdentifier)
        if AXIsProcessTrusted(), let id = region?.anchorWindowID, let window = windows.first(where: { $0.id == id }),
           !app.isActive || windows.first(where: \.onScreen)?.id != id {
            try window.raise()
            return
        }
        app.activate(options: [])
    }

    func resetSelection(clearKeepAlive: Bool = false) {
        guard !busy && !selectionActive else { return }
        region = nil; preview = nil; rows = []; windowChoices = []
        if clearKeepAlive { keepAliveTarget = nil }
        status = settings.captureMode == .window ? "请选择收藏对局所在的完整窗口。" : "请选择完整游戏区域。"
    }

    func updateAssets() {
        guard !busy && !selectionActive && reviewingVideo == nil && editingReviewVideo == nil else { return }
        busy = true; stopRequested = false; stopping = false; status = "正在检查角色库更新…"; error = nil
        Metadata.beginOperation()
        operation = Task {
            defer { self.busy = false; self.operation = nil; self.stopping = false }
            do {
                let resources = Bundle.main.resourceURL!
                let report = try await Task.detached { try Metadata.updateAssets(resources: resources) }.value
                self.refreshAssetStatus()
                self.status = report.error ?? (report.failed.isEmpty ? "角色库已更新：\(self.assetStatus)" : "已保留可用角色库，\(report.failed.count) 张参考图下载失败，可稍后重试。")
                if !report.added.isEmpty {
                    for video in self.reviewVideos where VideoReview.load(video)?.status != "reviewed" {
                        self.queueReview(video)
                    }
                }
            } catch {
                if Task.isCancelled { self.status = "已取消更新，已下载的参考图保留。" }
                else { self.fail(error) }
            }
        }
    }

    func refreshAssetStatus() {
        let url = Settings.directory.appendingPathComponent("Portraits/update.json")
        guard let data = try? Data(contentsOf: url), let report = try? JSONDecoder().decode(AssetUpdate.self, from: data) else { return }
        assetStatus = "\(report.total) 张参考图 · 图库 \(report.libraryVersion ?? report.catalogVersion ?? "内置")"
        assetDetails = "最近检查：\(report.checkedAt)\n最近完整更新：\(report.lastSuccessAt ?? "尚无记录")"
        let missing = report.missing ?? report.failed
        if !missing.isEmpty { assetDetails += "\n图库缺失／下载失败：\(missing.joined(separator: "、"))" }
        if let error = report.error { assetDetails += "\n\(error)" }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: report.checkedAt) ?? ISO8601DateFormatter().date(from: report.checkedAt) {
            lastAutomaticAssetCheck = date
        }
    }

    private func checkAutomaticAssets() {
        guard settings.autoAssetUpdates && !busy && !selectionActive && reviewingVideo == nil && editingReviewVideo == nil,
              Date().timeIntervalSince(lastAutomaticAssetCheck) > 86400 else { return }
        lastAutomaticAssetCheck = Date()
        updateAssets()
    }

    func chooseWindow() {
        guard !busy && !selectionActive else { return }
        guard screenAllowed, let target = targetApplication() else { error = "请先授权屏幕录制并打开目标应用。"; return }
        windowChoices = CaptureWindow.list(pid: target.processIdentifier).filter(\.onScreen)
        guard !windowChoices.isEmpty else { error = "没有找到可见窗口，请还原游戏窗口。"; return }
        choosingWindow = true
    }

    func useWindow(_ window: CaptureWindow) {
        choosingWindow = false
        do {
            if choosingKeepAliveWindow {
                keepAliveTarget = try KeepAliveTarget(window: window, bundleID: settings.targetBundleID)
                choosingKeepAliveWindow = false
                let start = startAfterKeepAliveSelection
                startAfterKeepAliveSelection = false
                status = "已校准保活页面：\(keepAliveTarget!.label)"
                if start { startKeepAlive() }
                return
            }
            region = try window.region()
            rows = []; preview = nil
            scan()
        } catch { choosingKeepAliveWindow = false; startAfterKeepAliveSelection = false; fail(error) }
    }

    func selectRegion() {
        guard !busy && !selectionActive else { return }
        refreshPermissions()
        guard screenAllowed else { error = "请先开启屏幕与系统音频录制权限。"; return }
        do { try focusTarget() } catch { self.error = error.localizedDescription; return }
        mainWindow?.orderOut(nil)
        selectionActive = true
        status = "正在显示目标窗口…"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, self.selectionActive else { return }
            let displayID: UInt32
            do { displayID = try self.selectionDisplay() }
            catch { self.selectionActive = false; self.error = error.localizedDescription; self.showWindow(); return }
            self.status = "拖选游戏区域，回车确认。"
            self.selector.select(displayID: displayID) { [weak self] region in
                guard let self else { return }
                self.selectionActive = false
                guard var region else { self.showWindow(); self.status = "已取消选框。"; return }
                let windows = CaptureWindow.list(pid: self.targetApplication()?.processIdentifier).filter { $0.onScreen }
                guard let anchor = windows.filter({ !$0.frame.intersection(region.globalRect).isEmpty }).max(by: {
                    let a = $0.frame.intersection(region.globalRect), b = $1.frame.intersection(region.globalRect)
                    return a.width * a.height < b.width * b.height
                }) else { self.error = "所选区域不包含目标窗口，请重选。"; self.showWindow(); return }
                region.anchorWindowID = anchor.id; region.anchorFrame = anchor.frame; region.anchorOwnerPID = anchor.ownerPID
                self.region = region
                self.rows = []
                self.preview = nil
                self.scan()
            }
        }
    }

    func scan() {
        guard let region, !busy else { return }
        busy = true; stopping = false; stopRequested = false; status = "正在读取收藏对局…"
        Metadata.beginOperation()
        operation = Task { [weak self] in
            guard let self else { return }
            defer { self.busy = false; self.stopping = false; self.operation = nil; self.showWindow() }
            do {
                try self.focusTarget()
                self.mainWindow?.orderOut(nil)
                try await Task.sleep(for: .milliseconds(300))
                let image = try await self.recorder.screenshot(region: region.resolved())
                self.preview = NSImage(cgImage: image, size: .zero)
                let resources = Bundle.main.resourceURL!
                let rows = try await Task.detached(priority: .userInitiated) { try Metadata.scan(image: image, resources: resources) }.value
                try Task.checkCancellation()
                self.rows = CloudLaunchPolicy.restoringChoices(self.rows, in: rows) ?? rows
                self.status = rows.isEmpty ? "没有读到收藏对局。请确认游戏停在收藏列表，或手动添加。" : "已读取 \(rows.count) 局。请核对角色、日期和模式，再试录检查边框与声音。"
                self.addLog("识别收藏列表：\(rows.count) 局")
            } catch {
                if Task.isCancelled { self.status = "已取消识别。" }
                else { self.fail(error) }
            }
        }
    }

    func addManualRow() {
        let id = (rows.map(\.id).max() ?? 0) + 1
        rows.append(Replay(id: id, date: "未知日期", mode: "未知模式", left: Array(repeating: "未识别", count: 3),
                           right: Array(repeating: "未识别", count: 3), play: UnitPoint(x: 0.94, y: 0.2)))
    }

    func calibrate(_ key: String, rowID: Int? = nil) {
        guard let selected = region, !busy && !selectionActive else { return }
        let region: CaptureRegion
        do { region = try selected.resolved() } catch { fail(error); return }
        do { try focusTarget() } catch { self.error = error.localizedDescription; return }
        mainWindow?.orderOut(nil)
        selectionActive = true
        let title = key == "speed" ? "点击回放中的二倍速按钮" : key == "exit" ? "点击结束画面的退出观看按钮" : "点击本局的播放按钮"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, self.selectionActive else { return }
            self.selector.pickPoint(region: region, title: title) { point in
                self.selectionActive = false
                defer { self.showWindow() }
                guard let point else { return }
                if let id = rowID, let index = self.rows.firstIndex(where: { $0.id == id }) {
                    self.rows[index].play = point
                    self.rows[index].playDetected = true
                }
                else {
                    var profile = self.calibration
                    if key == "speed" { profile.speed = point } else { profile.exit = point }
                    self.settings.profiles[self.profileKey] = profile
                }
                self.status = "已校准\(key == "speed" ? "二倍速" : key == "exit" ? "退出观看" : "播放按钮")。开始批量录制前请返回收藏列表。"
            }
        }
    }

    @discardableResult
    private func sendPointerInput(_ point: UnitPoint, in region: CaptureRegion, kind: PointerInput = .click, clickHoldMilliseconds: Int = 80) async throws -> Bool {
        try Task.checkCancellation()
        guard AXIsProcessTrusted() else { throw RecorderError.message("辅助功能权限已关闭，录制已停止。") }
        guard session.unlocked else { throw RecorderError.message("桌面已锁定，已停止自动点击。") }
        let region = try region.resolved()
        guard let target = targetApplication(), let window = CaptureWindow.list(pid: target.processIdentifier).first(where: { $0.id == region.anchorWindowID }) else {
            throw RecorderError.message("找不到已选的游戏窗口，已停止自动点击。")
        }
        guard (0...1).contains(point.x), (0...1).contains(point.y) else { throw RecorderError.message("点击位置不在选框内。") }
        let position = RegionGeometry.screenPoint(point, source: region.sourceRect, displayOrigin: CGDisplayBounds(region.displayID).origin)
        if kind == .keepAlive && NSEvent.pressedMouseButtons != 0 {
            addLog("云原神保活暂缓：鼠标按键正被按住")
            return false
        }
        guard (80...500).contains(clickHoldMilliseconds) else { throw RecorderError.message("鼠标按下时长设置无效，尚未输入。") }
        let events = try kind.events(at: position)
        guard events.allSatisfy({ region.globalRect.contains($0.location) }) else {
            throw RecorderError.message("鼠标输入位置超出录制区域。")
        }
        defer { if sessionRunning { hud.restore() } }
        try await hud.hideForClick()
        var check = window.checkClick(events[0].location)
        if !target.isActive || !check.allowed {
            guard settings.unattended || keepAliveOnly || !recording else {
                addLog(check.detail)
                if kind == .keepAlive {
                    addLog("云原神保活暂缓：目标失焦或位置被遮挡")
                    return false
                }
                throw RecorderError.message(target.isActive ? "点击位置被其他窗口遮挡，已停止自动点击。" : "目标应用已离开前台，已停止自动点击。")
            }
            addLog(kind == .keepAlive ? "保活前恢复已选游戏窗口" : "点击前恢复已选游戏窗口")
            try window.raise()
            try await Task.sleep(for: .milliseconds(500))
            check = window.checkClick(events[0].location)
        }
        try Task.checkCancellation()
        guard session.unlocked, try region.resolved().globalRect == region.globalRect else {
            throw RecorderError.message("桌面或录制区域已改变，已停止自动输入。")
        }
        guard target.isActive, check.allowed else {
            addLog(check.detail)
            if kind == .keepAlive { addLog("云原神保活暂缓：目标窗口未就绪"); return false }
            throw RecorderError.message("目标窗口未就绪或点击位置被遮挡，已停止自动点击。")
        }
        if kind == .keepAlive && NSEvent.pressedMouseButtons != 0 { return false }
        if keepAliveOnly { try keepAliveTarget?.validateSelectedTab() }
        events[0].post(tap: .cghidEventTap)
        try await Task.sleep(for: .milliseconds(100))
        try Task.checkCancellation()
        check = window.checkClick(position)
        guard session.unlocked, try region.resolved().globalRect == region.globalRect else {
            throw RecorderError.message("鼠标移动期间桌面或录制区域已改变，已停止自动输入。")
        }
        guard target.isActive, check.allowed else {
            addLog(check.detail)
            if kind == .keepAlive { addLog("云原神保活暂缓：鼠标移动期间目标状态改变"); return false }
            throw RecorderError.message("点击前目标状态改变，已停止。")
        }
        if kind == .keepAlive {
            guard NSEvent.pressedMouseButtons == 0 else { return false }
            if keepAliveOnly { try keepAliveTarget?.validateSelectedTab() }
            events[1].post(tap: .cghidEventTap)
            return true
        }
        events[1].post(tap: .cghidEventTap)
        // Always release a posted mouse-down, including when Stop was pressed.
        try? await Task.sleep(for: .milliseconds(clickHoldMilliseconds))
        events[2].post(tap: .cghidEventTap)
        try Task.checkCancellation()
        return true
    }

    private func outputURL(stem: String) throws -> URL {
        let directory = URL(fileURLWithPath: settings.outputDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard FileManager.default.isWritableFile(atPath: directory.path) else { throw RecorderError.message("录像目录不可写，请重新选择目录。") }
        return Filename.uniqueURL(directory: directory, stem: stem)
    }

    private func saveReplayMetadata(_ replay: Replay, at video: URL) {
        do { try JSONEncoder().encode(replay).write(to: video.deletingPathExtension().appendingPathExtension("json"), options: .atomic) }
        catch { addLog("视角与角色信息保存失败，视频仍保留：\(error.localizedDescription)") }
    }

    func markRecordingStarted() {
        elapsed = 0
        startedAt = Date()
        recording = true
    }

    private func preparePerspective(_ replay: inout Replay, region: CaptureRegion, video: URL,
                                    originalHeaders: ReplayPlayerHeaders?, keepAlive: inout KeepAliveSchedule) async throws {
        guard replay.preferredPerspective.requiresSwitch else {
            replay.perspectiveStatus = "replayDefault"
            return
        }
        replay.perspectiveStatus = "waitingForAvailability"
        saveReplayMetadata(replay, at: video)
        status = "第 \(replay.id) 局：等待掷骰结束、牌桌菜单出现，再暂停并切换对方视角…"
        var flow = ReplayPerspectiveFlow(desired: replay.preferredPerspective, originalHeaders: originalHeaders)
        var speedPrepared = !settings.speed2x
        var nextDiagnostic = 0.0
        var endingHits = 0
        var entryCheck = ReplayEntryCheck(startedAt: ProcessInfo.processInfo.systemUptime,
                                          graceSeconds: settings.loadingSeconds)
        while true {
            try Task.checkCancellation()
            try recorder.checkFailure()
            guard session.unlocked else { throw RecorderError.message("桌面已锁定，已停止录制与视角检测。") }
            let now = ProcessInfo.processInfo.systemUptime
            guard entryCheck.elapsed(at: now) < settings.maxSeconds else {
                throw RecorderError.message("本局达到时长上限，已保存当前录像；对方视角尚未就绪时也不会无限录制。")
            }
            if keepAlive.takeDue(at: now), try await sendPointerInput(UnitPoint(x: 0.78, y: 0.27), in: region, kind: .keepAlive) {
                keepAliveCount += 1
                addLog("等待对方视角期间云原神保活移动 · 第 \(keepAliveCount) 次")
            }
            let image = try await recorder.screenshot(region: region.resolved())
            let resources = Bundle.main.resourceURL!
            let (lines, controls) = try await Task.detached {
                (try Metadata.text(in: image), try Metadata.playback(image: image, resources: resources))
            }.value
            try Task.checkCancellation()
            if entryCheck.failed(listVisible: lines.contains(where: { ReplayText.date($0.text) != nil }), at: now) {
                throw RecorderError.message("播放点击未进入回放。短片已保留，请校准这一局的播放位置后重试。")
            }
            if !speedPrepared, controls.playback != nil {
                // Share the first verified toolbar observation; do not delay the
                // perspective menu for a separate speed-confirmation loop.
                speedPrepared = true
                let action = SpeedPolicy.action(detected: controls.speed, calibrated: calibration.speed)
                if case .click(let point) = action {
                    status = "回放控件已出现，点击二倍速；等待牌桌菜单出现后暂停切换视角…"
                    try await sendPointerInput(point, in: region)
                    try await Task.sleep(for: .milliseconds(250))
                    continue
                }
                if action == .alreadyDouble { addLog("已确认当前为二倍速，无需点击") }
            }
            let ending = lines.contains { ["对局胜利", "对局失败"].contains($0.text.filter { !$0.isWhitespace }) } &&
                lines.contains { $0.text.contains("退出观看") }
            endingHits = ending ? endingHits + 1 : 0
            if endingHits >= 2 {
                replay.confirmedPerspective = flow.confirmedPerspective
                replay.perspectiveStatus = replay.confirmedPerspective == .opponent ? "playerHeadersConfirmed" : "needsReview"
                saveReplayMetadata(replay, at: video)
                addLog("第 \(replay.id) 局已到结束画面；\(replay.confirmedPerspective == .opponent ? "对方视角已确认" : "未能确认对方视角，录像保留并标记待核对")")
                return
            }
            if ending { try await Task.sleep(for: .seconds(1)); continue }
            let action = flow.observe(lines: lines, controls: controls, at: now)
            if now >= nextDiagnostic {
                let menuState = ReplayPerspectiveMenu.detect(lines) != nil ? "switchAvailable" :
                    (ReplayPerspectiveMenu.isOpen(lines) ? "unavailable" : "closed")
                addLog("视角检查：菜单=\(menuState)，视角=\(flow.confirmedPerspective?.rawValue ?? "unknown")，播放=\(controls.playback?.state.rawValue ?? "unknown")，等待恢复=\(flow.waitingForPlayback)，方向参照=\(flow.hasOrientationReference)")
                nextDiagnostic = now + 15
            }
            switch action {
            case .pause(let point):
                replay.perspectiveStatus = "pausingBeforeSwitch"
                saveReplayMetadata(replay, at: video)
                status = "牌桌菜单已出现，正在暂停；确认暂停后再切换对方视角…"
                addLog("已识别稳定牌桌菜单及暂停按钮，发送切换前暂停点击")
                try await sendPointerInput(point, in: region, clickHoldMilliseconds: 250)
            case .openMenu(let point):
                status = "已确认暂停，正在打开回放菜单切换对方视角…"
                addLog("已确认暂停，正在打开回放菜单寻找切换视角按钮…")
                try await sendPointerInput(point, in: region, clickHoldMilliseconds: 250)
            case .switchView(let point):
                replay.perspectiveStatus = "switchRequested"
                saveReplayMetadata(replay, at: video)
                status = "正在切换对方视角；切换后会检查暂停并点击继续…"
                addLog(String(format: "视角按钮点击位置（选框比例）：x=%.4f，y=%.4f", point.x, point.y))
                try await sendPointerInput(point, in: region, clickHoldMilliseconds: 250)
            case .closeMenu(let point, let reason):
                replay.confirmedPerspective = flow.confirmedPerspective
                if reason == .confirmed {
                    replay.perspectiveStatus = "playerHeadersConfirmed"
                    status = "对方视角已确认，正在关闭菜单并检查继续播放…"
                } else {
                    status = "正在关闭回放菜单并检查继续播放；视角尚待确认…"
                }
                saveReplayMetadata(replay, at: video)
                try await sendPointerInput(point, in: region, clickHoldMilliseconds: 250)
            case .resume(let point):
                status = "视角处理后检测到暂停，正在点击继续；未切换成功时会继续等待机会…"
                addLog("已识别继续按钮，发送恢复播放点击")
                try await sendPointerInput(point, in: region, clickHoldMilliseconds: 250)
            case .finished:
                replay.confirmedPerspective = flow.confirmedPerspective
                replay.perspectiveStatus = flow.confirmedPerspective == .opponent ? "playerHeadersConfirmed" : "unverified"
                saveReplayMetadata(replay, at: video)
                addLog(flow.confirmedPerspective == .opponent
                    ? "第 \(replay.id) 局 · 对方视角：上下牌手交换与继续播放均已确认"
                    : "第 \(replay.id) 局：回放已继续，视角证据不足，标记待核对；不重复切换")
                return
            case .wait:
                if !flow.hasOrientationReference {
                    status = "正在等待可辨认的双方牌手信息；确认切换方向后再点击，录制与保活继续…"
                }
            }
            try await Task.sleep(for: .seconds(1))
        }
    }

    func testRecording() {
        guard let region, !busy, screenAllowed else { return }
        busy = true; stopRequested = false; stopping = false; interruption = nil; error = nil
        deferReviewForRecording()
        Metadata.beginOperation()
        operation = Task {
            defer { self.finishOperation() }
            var url: URL?
            do {
                try self.focusTarget()
                self.mainWindow?.orderOut(nil)
                try await Task.sleep(for: .seconds(1))
                try self.beginSession(region: region)
                let path = try self.outputURL(stem: "试录_\(Int(Date().timeIntervalSince1970))")
                url = path
                try await self.recorder.start(region: region.resolved(), url: path, audio: self.settings.systemAudio)
                self.markRecordingStarted(); self.status = "试录中，10 秒后自动保存…"
                try await Task.sleep(for: .seconds(10))
                try await self.recorder.stop()
                try await self.verifyRecording(path, detail: "10 秒试录")
                self.status = "试录已保存，请检查四周边框与声音。"
            } catch {
                await self.stopAfterError(error, url: url)
            }
        }
    }

    func startBatch() {
        guard canStart, let region else { return }
        guard settings.loadingSeconds.isFinite, (2...60).contains(settings.loadingSeconds),
              settings.maxSeconds.isFinite, (120...7200).contains(settings.maxSeconds) else {
            error = "加载等待应为 2–60 秒，单局上限应为 120–7200 秒。"
            return
        }
        if settings.unattended && region.windowID == nil { error = "无人值守需要全窗口模式，请先选择完整游戏窗口。"; return }
        if settings.cloudKeepAlive && !KeepAliveSchedule.allowedInterval.contains(settings.keepAliveSeconds) {
            error = "保活间隔应为 15–120 秒。"
            return
        }
        let batch = ReplayRecordingPlan.jobs(rows: rows, bothPerspectives: settings.bothPerspectives)
        if let uncertain = batch.first(where: { !$0.playDetected }) {
            error = "第 \(uncertain.id) 局的播放按钮未确认，请点击该行准星校准位置。"
            return
        }
        busy = true; stopRequested = false; stopping = false; interruption = nil; error = nil
        deferReviewForRecording()
        Metadata.beginOperation()
        operation = Task {
            defer { self.finishOperation() }
            var currentURL: URL?
            do {
                try self.focusTarget()
                self.mainWindow?.orderOut(nil)
                try await Task.sleep(for: .seconds(1))
                try self.beginSession(region: region)
                var keepAlive = KeepAliveSchedule(interval: self.settings.keepAliveSeconds)
                if self.settings.cloudKeepAlive {
                    keepAlive.start(at: ProcessInfo.processInfo.systemUptime)
                    self.addLog("云原神保活持续开启：覆盖整批录制，每 \(Int(self.settings.keepAliveSeconds)) 秒移动鼠标，不点击、不按键")
                }
                defer { keepAlive.stop() }
                for (offset, planned) in batch.enumerated() {
                    var replay = planned
                    try Task.checkCancellation()
                    let shot = try await self.recorder.screenshot(region: region.resolved())
                    let lines = try await Task.detached { try Metadata.text(in: shot) }.value
                    guard lines.contains(where: { ReplayText.date($0.text) == replay.date && abs($0.y - replay.play.y) < 0.15 }) || replay.date == "未知日期" else {
                        throw RecorderError.message("当前收藏列表与第 \(replay.id) 局的日期不一致，已停止自动点击。请重新扫描。")
                    }
                    var originalHeaders: ReplayPlayerHeaders?
                    if replay.preferredPerspective.requiresSwitch {
                        let first = ReplayPlayerHeaders.fromFavorites(lines, date: replay.date, play: replay.play)
                        if first != nil {
                            try await Task.sleep(for: .milliseconds(350))
                            let confirmation = try await self.recorder.screenshot(region: region.resolved())
                            let confirmedLines = try await Task.detached { try Metadata.text(in: confirmation) }.value
                            guard confirmedLines.contains(where: { ReplayText.date($0.text) == replay.date && abs($0.y - replay.play.y) < 0.15 }) else {
                                throw RecorderError.message("收藏列表在复核期间已改变，请重新扫描后录制。")
                            }
                            originalHeaders = ReplayPlayerHeaders.stable(first,
                                ReplayPlayerHeaders.fromFavorites(confirmedLines, date: replay.date, play: replay.play))
                        }
                        self.addLog(originalHeaders == nil
                            ? "列表方向参照不明确，将在回放中确认后切换；牌手名字不写入录像信息"
                            : "已用两次列表画面建立方向参照；牌手名字仅在本局内存中使用")
                    }
                    self.activeRow = replay.id; self.activePerspective = replay.preferredPerspective
                    self.status = "第 \(replay.id) 局 · \(replay.preferredPerspective.label)：进入回放（\(offset + 1)/\(batch.count) 段）"
                    let path = try self.outputURL(stem: replay.filename)
                    currentURL = path
                    self.saveReplayMetadata(replay, at: path)
                    try await self.sendPointerInput(replay.play, in: region)
                    try await self.recorder.start(region: region.resolved(), url: path, audio: self.settings.systemAudio)
                    self.markRecordingStarted()
                    // Own takes never inspect menus, even in a mixed or two-pass batch.
                    if replay.preferredPerspective.requiresSwitch {
                        try await self.preparePerspective(&replay, region: region, video: path,
                                                         originalHeaders: originalHeaders, keepAlive: &keepAlive)
                    }
                    else {
                        try await Task.sleep(for: .seconds(self.settings.loadingSeconds))
                        let afterClick = try await self.recorder.screenshot(region: region.resolved())
                        let afterLines = try await Task.detached { try Metadata.text(in: afterClick) }.value
                        guard !afterLines.contains(where: { ReplayText.date($0.text) != nil }) else {
                            throw RecorderError.message("播放点击未进入回放。短片已保留，请校准这一局的播放位置后重试。")
                        }
                        if self.settings.speed2x { try await self.setDoubleSpeed(region: region) }
                        replay.perspectiveStatus = "replayDefault"
                    }
                    self.saveReplayMetadata(replay, at: path)
                    self.status = "正在录制第 \(replay.id) 局 · \(replay.preferredPerspective.label)（\(offset + 1)/\(batch.count) 段）"
                    var endHits = 0
                    var detectedExit: UnitPoint?
                    while true {
                        try await Task.sleep(for: .seconds(5))
                        try self.recorder.checkFailure()
                        if self.elapsed >= Int(self.settings.maxSeconds) { throw RecorderError.message("本局达到时长上限，已保存当前录像并停止后续自动点击。") }
                        if keepAlive.takeDue(at: ProcessInfo.processInfo.systemUptime) {
                            // Upper-right backdrop, relative to the capture rather than the main display.
                            if try await self.sendPointerInput(UnitPoint(x: 0.78, y: 0.27), in: region, kind: .keepAlive) {
                                self.keepAliveCount += 1
                                self.addLog("已发送云原神保活移动 · 第 \(self.keepAliveCount) 次")
                            }
                        }
                        if self.elapsed < 60 { continue }
                        let screenshot = try await self.recorder.screenshot(region: region.resolved())
                        let text = try await Task.detached { try Metadata.text(in: screenshot) }.value
                        let exit = text.first { $0.text.contains("退出观看") }
                        let ending = text.contains { $0.text.contains("对局胜利") || $0.text.contains("对局失败") }
                        endHits = (exit != nil || self.calibration.exit != nil) && ending ? endHits + 1 : 0
                        if let exit { detectedExit = UnitPoint(x: exit.x + exit.width / 2, y: exit.y + exit.height / 2) }
                        if endHits == 1 { self.status = "第 \(replay.id) 局：检测到结束画面，正在复核…" }
                        if endHits >= 3 { break }
                    }
                    try await Task.sleep(for: .seconds(1.5))
                    self.status = "第 \(replay.id) 局：正在保存视频…"
                    try await self.recorder.stop()
                    self.recording = false; self.startedAt = nil
                    do {
                        try JSONEncoder().encode(replay).write(to: path.deletingPathExtension().appendingPathExtension("json"), options: .atomic)
                    } catch { self.addLog("初始角色信息保存失败，视频仍保留：\(error.localizedDescription)") }
                    try await self.verifyRecording(path, detail: "第 \(replay.id) 局 · \(replay.preferredPerspective.label)")
                    if self.settings.autoReview { self.queueReview(path) }
                    currentURL = nil
                    if offset < batch.count - 1 {
                        guard let exit = detectedExit ?? self.calibration.exit else { throw RecorderError.message("没有识别到退出观看按钮，已保存录像，请手动返回收藏列表。") }
                        self.status = "第 \(replay.id) 局已保存，正在返回收藏列表…"
                        try await self.sendPointerInput(exit, in: region)
                        try await Task.sleep(for: .seconds(8))
                    }
                }
                self.status = "本批 \(batch.count) 段录制完成，保活已停止。"
            } catch { await self.stopAfterError(error, url: currentURL) }
        }
    }

    var canBeginRecording: Bool {
        return ready && !busy && !selectionActive && editingReviewVideo == nil && (rows.isEmpty || canStart)
    }

    func beginRecording() {
        if settings.targetBundleID == SafariLauncher.bundleID || rows.isEmpty { launchSafariAndRecord(preservingSelection: true) }
        else { startBatch() }
    }

    func launchSafariAndRecord() { launchSafariAndRecord(preservingSelection: false) }

    private func launchSafariAndRecord(preservingSelection: Bool) {
        refreshPermissions()
        guard ready, !busy, !selectionActive, editingReviewVideo == nil else {
            error = "请先完成屏幕录制和辅助功能授权，并结束其他操作。"
            return
        }
        let previousRows = preservingSelection ? rows : []
        // One-click Safari recording keeps the logged-in cloud session alive through navigation.
        settings.cloudKeepAlive = true
        guard KeepAliveSchedule.allowedInterval.contains(settings.keepAliveSeconds) else {
            error = "保活间隔应为 15–120 秒。"; return
        }
        busy = true; stopping = false; stopRequested = false; interruption = nil; error = nil
        cloudLaunchPhase = .opening
        status = "正在打开 Safari 云原神…"
        deferReviewForRecording()
        Metadata.beginOperation()
        operation = Task {
            var handoff = false
            defer {
                self.finishOperation()
                if handoff && self.canStart {
                    self.cloudLaunchPhase = .recording
                    self.startBatch()
                    if !self.busy { self.cloudLaunchPhase = .needsFavorites }
                }
            }
            do {
                guard self.session.unlocked else { throw RecorderError.message("请先解锁 Mac mini，再启动云原神。") }
                self.settings.targetBundleID = SafariLauncher.bundleID
                self.settings.captureMode = .window
                self.region = nil; self.rows = []; self.preview = nil; self.keepAliveTarget = nil
                let window = try await SafariLauncher.openCloudPage()
                try Task.checkCancellation()
                let region = try window.region()
                self.region = region
                self.mainWindow?.orderOut(nil)
                self.hud.show(model: self, displayID: region.displayID)
                self.cloudLaunchPhase = .checking
                self.status = "正在检查登录状态和收藏对局页面…"
                try await Task.sleep(for: .seconds(2))
                var actions: [CloudPageState: Int] = [:]
                let deadline = Date().addingTimeInterval(360)
                var navigationKeepAlive = KeepAliveSchedule(interval: self.settings.keepAliveSeconds)
                var navigationKeepAliveStarted = false
                var lastPrinceEvidence = ""
                var princeDiagnosticCount = 0
                var princeChoicesSeen = false
                var unconfirmedPrinceChoices = 0
                defer { navigationKeepAlive.stop() }
                var switchedPasswordTab = false
                var attemptedPasswordLogin = false
                while Date() < deadline {
                    try Task.checkCancellation()
                    guard self.session.unlocked else { throw RecorderError.message("桌面已锁定，启动已暂停。") }
                    guard SafariLauncher.pageURL(window).map(CloudLaunchPolicy.allowed) == true else {
                        throw RecorderError.message("Safari 已离开云原神标签页，请切回官方页面后继续检查。")
                    }
                    let image = try await self.recorder.screenshot(region: region.resolved())
                    let lines = try await Task.detached { try Metadata.cloudNavigationText(in: image) }.value
                    try Task.checkCancellation()
                    let state = CloudLaunchPolicy.state(lines)
                    if state == .princeDialogue { princeChoicesSeen = true }
                    if princeChoicesSeen && [.prince, .princeGreeting, .unknown].contains(state) {
                        unconfirmedPrinceChoices += 1
                        guard unconfirmedPrinceChoices <= 3 else {
                            throw RecorderError.message("小王子选项出现后无法稳定确认回放按钮，已停止；没有再次按 F 或选择其他选项。请检查页面后继续。")
                        }
                        self.status = "已看到小王子选项，正在重新确认回放按钮；不会再次按 F…"
                        try await Task.sleep(for: .seconds(1))
                        continue
                    }
                    if !navigationKeepAliveStarted && (state != .login && state != .unknown || CloudLaunchPolicy.hasGameSession(lines)) {
                        try self.session.begin()
                        self.sessionRunning = true
                        navigationKeepAlive.start(at: ProcessInfo.processInfo.systemUptime)
                        navigationKeepAliveStarted = true
                        self.addLog("已确认云原神登录页面：导航和录制保活开启，每 \(Int(self.settings.keepAliveSeconds)) 秒仅移动鼠标；本批结束或停止时关闭")
                    }
                    if navigationKeepAlive.takeDue(at: ProcessInfo.processInfo.systemUptime) {
                        if try await self.sendPointerInput(UnitPoint(x: 0.78, y: 0.27), in: region, kind: .keepAlive) {
                            self.keepAliveCount += 1
                            self.addLog("导航期间云原神保活移动 · 第 \(self.keepAliveCount) 次")
                        }
                    }
                    switch state {
                    case .login:
                        self.cloudLaunchPhase = .login
                        if self.settings.cloudAutoLogin && !attemptedPasswordLogin {
                            if !SafariLauncher.hasPasswordForm(window) {
                                let tabs = lines.filter { ["密码登录", "账号密码登录", "帐号密码登录"].contains($0.text.trimmingCharacters(in: .whitespacesAndNewlines)) }
                                let ocrPoint = tabs.count == 1 ? tabs.first.map { UnitPoint(x: $0.x + $0.width / 2, y: $0.y + $0.height / 2) } : nil
                                guard !switchedPasswordTab, let point = SafariLauncher.passwordLoginPoint(window) ?? ocrPoint else {
                                    throw RecorderError.message("未能确认密码登录入口。请在 Safari 手动切换到密码登录后继续检查。")
                                }
                                self.status = "正在从验证码登录切换到密码登录…"
                                try await self.sendPointerInput(point, in: region)
                                self.hud.restore()
                                switchedPasswordTab = true
                                try await Task.sleep(for: .seconds(1))
                                continue
                            }
                            guard let credentials = try CloudAccountKeychain.load() else {
                                self.cloudAccountSaved = false
                                throw RecorderError.message("请先在「首次设置 → 云原神账号」保存账号和密码。")
                            }
                            self.status = "正在逐字输入钥匙串中的云原神账号，请暂勿操作键盘或切换窗口…"
                            try await self.hud.hideForClick()
                            var result: SafariLoginResult
                            do {
                                guard self.session.unlocked else { throw RecorderError.message("桌面已锁定，已停止自动登录。") }
                                result = try await SafariLauncher.fillAndSubmit(window, credentials: credentials,
                                    validateSession: {
                                        guard self.session.unlocked else { throw RecorderError.message("桌面已锁定，已停止自动登录。") }
                                    }, click: { point in
                                        try await self.sendPointerInput(point, in: region)
                                    })
                                if result == .needsAgreement && self.settings.cloudAutoAcceptAgreements {
                                    self.status = "正在按首次设置中的授权勾选官方用户协议和隐私政策…"
                                    if !SafariLauncher.pressAgreement(window) {
                                        guard let point = SafariLauncher.agreementPoint(window) else {
                                            throw RecorderError.message("已开启自动勾选协议，但无法确认官方协议复选框。请在 Safari 手动确认后继续；没有点击其他授权。")
                                        }
                                        try await self.sendPointerInput(point, in: region)
                                    }
                                    try await Task.sleep(for: .milliseconds(400))
                                    try Task.checkCancellation()
                                    guard self.session.unlocked else { throw RecorderError.message("桌面已锁定，已停止自动登录。") }
                                    result = try SafariLauncher.submit(window)
                                }
                            }
                            catch { self.hud.restore(); throw error }
                            self.hud.restore()
                            guard result == .submitted else {
                                throw RecorderError.message(result == .needsAgreement
                                    ? (self.settings.cloudAutoAcceptAgreements
                                        ? "未能确认官方协议已勾选，尚未提交登录。请在 Safari 手动确认后继续。"
                                        : "账号和密码已填写。请在「首次设置 → 云原神账号」开启自动勾选官方协议，或在 Safari 手动确认并登录，再点「继续检查并录制」。")
                                    : "账号和密码已填写，但未能确认登录按钮。请在 Safari 完成登录后继续检查。")
                            }
                            attemptedPasswordLogin = true
                            self.status = "已提交一次密码登录，正在等待结果…"
                            try await Task.sleep(for: .seconds(3))
                            continue
                        }
                        throw RecorderError.message("需要登录或验证码。请在 Mac mini 的 Safari 中完成验证，并进入收藏对局列表，再点「继续检查并录制」。")
                    case .favorites:
                        self.status = "已找到收藏对局，正在复核页面和播放按钮…"
                        try await Task.sleep(for: .seconds(1.5))
                        let second = try await self.recorder.screenshot(region: region.resolved())
                        let resources = Bundle.main.resourceURL!
                        let (nextLines, found) = try await Task.detached {
                            (try Metadata.text(in: second), try Metadata.scan(image: second, resources: resources))
                        }.value
                        try Task.checkCancellation()
                        guard CloudLaunchPolicy.verified(lines, nextLines, rows: found) else {
                            throw RecorderError.message("收藏列表或播放按钮尚未稳定确认。请检查当前页面后继续，或使用原来的手动录制入口。")
                        }
                        guard let restored = CloudLaunchPolicy.restoringChoices(previousRows, in: found) else {
                            self.rows = previousRows
                            throw RecorderError.message("收藏列表与上次勾选或人工角色修正不一致。已保留原选择，请重新识别并确认后开始。")
                        }
                        self.rows = restored
                        guard !self.selectedRows.isEmpty else { throw RecorderError.message("没有勾选对局，尚未开始录制。") }
                        self.preview = NSImage(cgImage: second, size: .zero)
                        self.cloudLaunchPhase = .countdown
                        self.status = "已确认收藏页，共 \(self.selectedRows.count) 局已选，3 秒后开始录制；可随时停止。"
                        try await Task.sleep(for: .seconds(3))
                        try Task.checkCancellation()
                        handoff = true
                        return
                    case .princeDialogue:
                        let count = actions[state, default: 0]
                        guard count < 3, unconfirmedPrinceChoices < 3 else {
                            throw RecorderError.message("未能稳定确认小王子的回放选项，已停止；没有按 F、滚动盲选或开始录制。请检查页面后继续。")
                        }
                        self.status = "已进入小王子选项，正在复核“观看一下对局回放”…"
                        try await Task.sleep(for: .milliseconds(450))
                        let secondImage = try await self.recorder.screenshot(region: region.resolved())
                        let secondLines = try await Task.detached { try Metadata.cloudNavigationText(in: secondImage) }.value
                        try Task.checkCancellation()
                        if [.recentReplays, .favorites].contains(CloudLaunchPolicy.state(secondLines)) { continue }
                        guard let point = CloudLaunchPolicy.confirmedPrinceReplayPoint(lines, secondLines) else {
                            unconfirmedPrinceChoices += 1
                            self.status = "小王子选项已出现，回放按钮仍待确认；正在放大重读，不按 F…"
                            continue
                        }
                        try await self.hud.hideForClick()
                        do {
                            self.status = "已连续确认回放选项，正在点击“观看一下对局回放”…"
                            try await self.sendPointerInput(point, in: region, clickHoldMilliseconds: 250)
                        } catch { self.hud.restore(); throw error }
                        self.hud.restore()
                        actions[state] = count + 1
                        unconfirmedPrinceChoices = 0
                        try await Task.sleep(for: .seconds(4))
                    case .launcher, .gameEntry, .prince, .princeGreeting, .recentReplays, .replayEnd:
                        let count = actions[state, default: 0]
                        guard count < 3 else {
                            throw RecorderError.message("在“\(state.rawValue)”页面尝试 3 次后未进入下一步，已停止；没有开始录制。请检查页面提示后继续。")
                        }
                        let point = state == .launcher ? CloudLaunchPolicy.startPoint(lines)
                            : state == .recentReplays ? CloudLaunchPolicy.recentTabKeyPoint(lines)
                            : CloudLaunchPolicy.navigationPoint(lines)
                        guard point != nil || state == .launcher else {
                            throw RecorderError.message("已找到相关页面，但无法唯一确认下一步控件。请保持页面完整、无遮挡后继续。")
                        }
                        try await self.hud.hideForClick()
                        do {
                            switch state {
                            case .launcher:
                                self.status = "正在启动云原神，加载最多等待 6 分钟…"
                                if try !SafariLauncher.pressStart(window) {
                                    guard let point else { throw RecorderError.message("未能唯一确认官方启动按钮，尚未点击。") }
                                    try await self.sendPointerInput(point, in: region)
                                }
                            case .prince, .recentReplays:
                                guard let point else { throw RecorderError.message("游戏快捷键的页面依据已丢失，尚未发送。") }
                                self.status = state == .prince ? "已找到小王子，正在按 F 对话…"
                                    : "已进入最近对局，正在按 E 切换收藏…"
                                try window.raise()
                                try await Task.sleep(for: .milliseconds(300))
                                let current = try region.resolved()
                                let position = RegionGeometry.screenPoint(point, source: current.sourceRect, displayOrigin: CGDisplayBounds(current.displayID).origin)
                                guard window.checkClick(position).allowed else { throw RecorderError.message("游戏快捷键的目标位置被遮挡，已停止。") }
                                let key: SafariLauncher.GameKey = state == .recentReplays ? .favorites : .interact
                                try await SafariLauncher.pressGameKey(key, in: window) {
                                    guard self.session.unlocked, try region.resolved().globalRect == current.globalRect else {
                                        throw RecorderError.message("桌面或游戏窗口已改变，已停止快捷键。")
                                    }
                                }
                            default:
                                guard let point else { throw RecorderError.message("未能确认导航按钮，尚未点击。") }
                                self.status = state == .gameEntry ? "正在通过“点击进入”进入游戏…"
                                    : state == .replayEnd ? "正在返回上一场回放的收藏列表…" : "正在点击小王子首句台词，等待回放选项；不按 F…"
                                try await self.sendPointerInput(point, in: region, clickHoldMilliseconds: 250)
                            }
                        } catch { self.hud.restore(); throw error }
                        self.hud.restore()
                        actions[state] = count + 1
                        try await Task.sleep(for: .seconds(4))
                    case .loading:
                        self.status = "云原神正在加载或排队，最多等待 6 分钟；可随时停止。"
                    case .unknown:
                        // Narrow local diagnostics: never dump login OCR or whole-page text.
                        let relevant = lines.filter { $0.text.contains("小王") || $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == "F" }
                        if !relevant.isEmpty, princeDiagnosticCount < 8 {
                            let evidence = relevant.prefix(8).map {
                                "\($0.text.prefix(24))@" + String(format: "%.3f,%.3f,%.3f,%.3f", $0.x, $0.y, $0.width, $0.height)
                            }.joined(separator: " | ")
                            if evidence != lastPrinceEvidence {
                                self.addLog("小王子入口尚未匹配：" + evidence)
                                lastPrinceEvidence = evidence
                                princeDiagnosticCount += 1
                            }
                        }
                        self.status = "正在等待游戏页面；进入猫尾酒馆后将识别小王子的 F 对话入口…"
                    }
                    try await Task.sleep(for: .seconds(2))
                }
                throw RecorderError.message("等待 6 分钟后仍未确认收藏对局。请检查云原神网络或排队状态；游戏中需靠近小王子并出现 F 提示。对话选择“观看一下对局回放”，再按 E 切到收藏后继续。")
            } catch is CancellationError {
                self.cloudLaunchPhase = .cancelled
                self.status = "已取消启动，尚未开始录制。"
            } catch {
                if self.cloudLaunchPhase != .login { self.cloudLaunchPhase = .needsFavorites }
                self.fail(error)
                NSApp.requestUserAttention(.criticalRequest)
            }
        }
    }

    func startKeepAlive() {
        guard canKeepAlive else { return }
        refreshPermissions()
        guard ready else {
            error = "只保活尚未启动：请先在「首次设置」开启\(!screenAllowed ? "屏幕录制" : "")\(!screenAllowed && !accessibilityAllowed ? "和" : "")\(!accessibilityAllowed ? "辅助功能" : "")权限。"
            return
        }
        guard let target = keepAliveTarget else {
            startAfterKeepAliveSelection = true
            choosingKeepAliveWindow = true
            status = "请先在浏览器选中原神标签页，再选择该窗口；选好后立即开始只保活。"
            chooseWindow()
            if !choosingWindow { choosingKeepAliveWindow = false; startAfterKeepAliveSelection = false }
            return
        }
        guard KeepAliveSchedule.allowedInterval.contains(settings.keepAliveSeconds) else {
            error = "保活间隔应为 15–120 秒。"; return
        }
        busy = true; keepAliveOnly = true; stopRequested = false; stopping = false; interruption = nil; error = nil
        operation = Task {
            defer { self.finishOperation() }
            do {
                try self.session.begin()
                self.sessionRunning = true; self.keepAliveCount = 0; self.elapsed = 0; self.startedAt = Date()
                self.mainWindow?.orderOut(nil)
                if self.settings.showHUD { self.hud.show(model: self, displayID: try target.currentWindow().region().displayID) }
                self.status = "只保活：每 \(Int(self.settings.keepAliveSeconds)) 秒切回已校准页面，不录制、不点击游戏"
                var schedule = KeepAliveSchedule(interval: self.settings.keepAliveSeconds)
                defer { schedule.stop() }
                // First pulse is immediate; later pulses use the same cancellable task.
                var first = true
                schedule.start(at: ProcessInfo.processInfo.systemUptime)
                while true {
                    try Task.checkCancellation()
                    if first || schedule.takeDue(at: ProcessInfo.processInfo.systemUptime) {
                        first = false
                        if NSEvent.pressedMouseButtons == 0 {
                            try target.restore()
                            try await Task.sleep(for: .milliseconds(500))
                            let region = try target.currentWindow().region()
                            if try await self.sendPointerInput(UnitPoint(x: 0.78, y: 0.27), in: region, kind: .keepAlive) {
                                self.keepAliveCount += 1
                                self.addLog("只保活：已切回页面并发送鼠标移动 · 第 \(self.keepAliveCount) 次")
                            }
                        } else { self.addLog("只保活暂缓：鼠标按键正被按住") }
                    }
                    try await Task.sleep(for: .seconds(1))
                }
            } catch {
                if let interruption = self.interruption { self.fail(interruption) }
                else if self.stopRequested || error is CancellationError { self.status = "只保活已停止，未录制视频。" }
                else { self.fail(error) }
            }
        }
    }

    private func beginSession(region: CaptureRegion) throws {
        _ = try region.resolved()
        try session.begin()
        sessionRunning = true; focusLostAt = nil; elapsed = 0; keepAliveCount = 0
        addLog(region.windowID == nil ? "区域录制：窗口失焦会保护性停止" : settings.unattended ? "全窗口无人值守：远程连接可断开，桌面必须保持解锁" : "全窗口录制：允许 15 秒暂时失焦")
        addLog("录制期间已启用临时防睡眠；不会阻止主动锁屏")
        if settings.showHUD { hud.show(model: self, displayID: region.displayID) }
    }

    private func monitorSession() {
        if !session.unlocked { CloudAccountKeychain.clearSession() }
        guard sessionRunning, !stopping else { return }
        if keepAliveOnly {
            do {
                guard session.unlocked, AXIsProcessTrusted() else { throw RecorderError.message("只保活已停止：桌面锁定、会话切换或辅助功能权限失效。") }
                _ = try keepAliveTarget?.currentWindow()
            } catch {
                interruption = error; stopping = true; operation?.cancel()
            }
            return
        }
        guard let region else { return }
        let app = targetApplication()
        let window = CaptureWindow.list(pid: app?.processIdentifier).first { $0.id == region.anchorWindowID }
        if app?.isActive == true {
            if focusLostAt != nil { addLog("目标应用已回到前台") }
            focusLostAt = nil
        } else if focusLostAt == nil {
            focusLostAt = Date()
            addLog(settings.unattended && region.windowID != nil ? "目标暂时失焦，继续捕获指定窗口；点击前重新验证" : "目标应用暂时失焦")
        }
        do {
            if let reason = RecordingSafety.interruption(unlocked: session.unlocked, targetExists: app != nil && window != nil,
                                                        fullWindow: region.windowID != nil, unattended: settings.unattended,
                                                        focusLostSeconds: focusLostAt.map { Date().timeIntervalSince($0) } ?? 0) {
                throw RecorderError.message(reason)
            }
            _ = try region.resolved()
            if window?.onScreen == false { throw RecorderError.message("目标窗口已最小化或离开当前桌面。已保存片段，请还原窗口后重新开始。") }
            if recording && recorder.isRecording { try recorder.checkFailure() }
        } catch {
            interruption = error; stopping = true
            status = "正在安全保存：\(error.localizedDescription)"
            operation?.cancel()
            Metadata.cancelOperation()
        }
    }

    private func setDoubleSpeed(region: CaptureRegion) async throws {
        status = "正在确认二倍速控件…"
        var control: ReplaySpeedControl?
        for _ in 0..<(calibration.speed == nil ? 3 : 1) {
            let image = try await recorder.screenshot(region: region.resolved())
            let resources = Bundle.main.resourceURL!
            do { control = try await Task.detached { try Metadata.speed(image: image, resources: resources) }.value }
            catch {
                try Task.checkCancellation()
                addLog("倍速识别暂不可用，将优先使用手动校准坐标。")
                break
            }
            try Task.checkCancellation()
            if control != nil { break }
            try await Task.sleep(for: .seconds(1))
        }
        let action = SpeedPolicy.action(detected: control, calibrated: calibration.speed)
        if action == .alreadyDouble { addLog("已确认当前为二倍速，无需点击"); return }
        guard case .click(let point) = action else {
            addLog("未能定位二倍速，保持当前速度继续录制。可在下次录制前手动校准。")
            return
        }
        status = "正在切换二倍速…"
        try await sendPointerInput(point, in: region)
        for _ in 0..<2 {
            try await Task.sleep(for: .seconds(1))
            let image = try await recorder.screenshot(region: region.resolved())
            let resources = Bundle.main.resourceURL!
            let verified: ReplaySpeedControl?
            do { verified = try await Task.detached { try Metadata.speed(image: image, resources: resources) }.value }
            catch { try Task.checkCancellation(); break }
            try Task.checkCancellation()
            if verified?.multiplier == 2 { addLog("已确认二倍速"); return }
        }
        addLog("已点击一次二倍速，图像识别未确认；保持当前速度继续录制，不重复点击。")
    }

    func stop() {
        if updater.working { updater.cancel(); return }
        if selectionActive { selector.cancel(); selectionActive = false; showWindow() }
        guard busy else { return }
        stopRequested = true
        stopping = true
        operation?.cancel()
        Metadata.cancelOperation()
        status = keepAliveOnly ? "正在停止保活…" : "正在停止并保存视频…"
    }
    private func stopAfterError(_ error: Error, url: URL?) async {
        stopping = true
        // A detached task is not cancelled with the controller and can finalize the MP4.
        let result = await Task { @MainActor in
            do { try await self.recorder.stop(); return nil as Error? } catch { return error }
        }.value
        if let url, FileManager.default.fileExists(atPath: url.path) {
            do { try await verifyRecording(url, detail: "中途停止") }
            catch { fail(error); return }
        }
        if let result { fail(result) }
        else if let interruption { fail(interruption) }
        else if stopRequested || error is CancellationError { status = "已停止，当前片段已保存。" }
        else { fail(error) }
    }
    private func finishOperation() {
        if cloudLaunchPhase == .recording { cloudLaunchPhase = .complete }
        if sessionRunning && settings.cloudKeepAlive { addLog("本批结束或停止：云原神保活与临时防睡眠已关闭") }
        sessionRunning = false; session.end(); hud.close(); focusLostAt = nil
        busy = false; recording = false; keepAliveOnly = false; startedAt = nil; activeRow = nil; activePerspective = nil; operation = nil
        stopping = false
        if session.unlocked { showWindow() }
    }
    private func verifyRecording(_ url: URL, detail: String) async throws {
        try await Task { @MainActor in
            let asset = AVURLAsset(url: url)
            let video = try await asset.loadTracks(withMediaType: .video)
            guard let track = video.first else { throw RecorderError.message("导出文件没有视频轨道：\(url.lastPathComponent)") }
            let size = try await track.load(.naturalSize)
            let audio = try await asset.loadTracks(withMediaType: .audio)
            let duration = try await asset.load(.duration).seconds
            guard duration > 0 else { throw RecorderError.message("导出文件时长为零。") }
            let report = "\(detail) · \(Int(size.width))×\(Int(size.height)) · \(Int(duration)) 秒 · \(audio.isEmpty ? "无音轨" : "有音轨")"
            entries.insert(RecordingEntry(url: url, detail: report), at: 0)
            addLog(report)
        }.value
    }
    func addLog(_ message: String) {
        let line = "\(Date().formatted(date: .numeric, time: .standard)) \(message)"
        log.append(line)
        if log.count > 200 { log.removeFirst() }
        guard persistent else { return }
        try? FileManager.default.createDirectory(at: Settings.directory, withIntermediateDirectories: true)
        try? log.joined(separator: "\n").write(to: Settings.directory.appendingPathComponent("session.log"), atomically: true, encoding: .utf8)
    }
    private func fail(_ error: Error) { self.error = error.localizedDescription; status = error.localizedDescription }
}
