import AppKit
import ApplicationServices
import ReplayCore

@MainActor
protocol RecordingFocusBackend {
    func read() async throws -> SystemFocusState
    func set(_ desired: SystemFocusState, expecting previous: SystemFocusState) async throws
}

/// Uses the public accessibility actions exposed by Control Center, not its private preferences.
@MainActor
final class SystemRecordingFocus: RecordingFocusBackend {
    private let menuID = "com.apple.menuextra.controlcenter"
    private let moduleID = "controlcenter-focus-modes"
    private let headerID = "focus-modes-header"

    private func trace(_ message: String) {
        if ProcessInfo.processInfo.environment["QISHENG_FOCUS_DIAGNOSTICS"] == "1" {
            fputs("Focus AX: \(message)\n", stderr)
        }
    }

    private func value(_ element: AXUIElement, _ attribute: String) -> Any? {
        AXUIElementSetMessagingTimeout(element, 0.2)
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
        return result
    }
    private func nodes(_ root: AXUIElement) -> [AXUIElement] {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        var queue: [(AXUIElement, Int)] = [(root, 0)], result: [AXUIElement] = []
        while !queue.isEmpty {
            let (element, depth) = queue.removeLast()
            // A panel can be reachable through both AXChildren and its menu tree.
            // Deduplicate element identity, never identifiers of distinct controls.
            if result.contains(where: { CFEqual($0, element) }) { continue }
            guard result.count < 240, ProcessInfo.processInfo.systemUptime < deadline else {
                trace("tree budget reached (\(result.count) nodes)")
                return []
            }
            result.append(element)
            if depth < 9, let children = value(element, "AXChildren") as? [AXUIElement] {
                queue += children.map { ($0, depth + 1) }
            }
        }
        return result
    }
    private func unique(_ id: String, in root: AXUIElement) -> AXUIElement? {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        var found: [AXUIElement] = []
        for node in nodes(root) {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            if value(node, "AXIdentifier") as? String == id { found.append(node) }
        }
        // The heading and its container share an ID. Both expose only panel
        // navigation actions, not a mode toggle; snapshot() validates mode rows.
        if id == headerID { return found.first }
        return found.count == 1 ? found[0] : nil
    }
    private func action(_ element: AXUIElement, containing names: [String]) -> String? {
        var values: CFArray?
        guard AXUIElementCopyActionNames(element, &values) == .success else { return nil }
        let matches = (values as? [String] ?? []).filter { value in
            names.contains { value.localizedCaseInsensitiveContains($0) }
        }
        return matches.count == 1 ? matches[0] : nil
    }
    private func press(_ element: AXUIElement, action: String = kAXPressAction) throws {
        guard AXUIElementPerformAction(element, action as CFString) == .success else {
            throw RecorderError.message("系统未响应勿扰控件，未继续尝试切换。")
        }
    }
    private func modeRows(_ root: AXUIElement) throws -> [AXUIElement] {
        var elements: [AXUIElement] = [], rows: [SystemFocusRow] = []
        for row in nodes(root) {
            guard let id = value(row, "AXIdentifier") as? String,
                  id.hasPrefix("focus-mode-activity-"),
                  value(row, "AXRole") as? String == kAXCheckBoxRole else { continue }
            guard let positionValue = value(row, "AXPosition"), let sizeValue = value(row, "AXSize"),
                  CFGetTypeID(positionValue as CFTypeRef) == AXValueGetTypeID(),
                  CFGetTypeID(sizeValue as CFTypeRef) == AXValueGetTypeID() else {
                throw RecorderError.message("系统专注模式行的边界不可用，没有切换。")
            }
            var position = CGPoint.zero, size = CGSize.zero
            guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
                  AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else {
                throw RecorderError.message("系统专注模式行的边界无效，没有切换。")
            }
            elements.append(row); rows.append(.init(id: id, frame: CGRect(origin: position, size: size)))
        }
        guard let indices = SystemFocusRow.primaryIndices(rows) else {
            throw RecorderError.message("专注模式与定时选项无法区分，没有切换。")
        }
        return indices.map { elements[$0] }
    }
    private func snapshot(_ root: AXUIElement) throws -> SystemFocusState {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        var states: [(id: String, value: Int)] = []
        for row in try modeRows(root) {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw RecorderError.message("读取系统勿扰状态超时，没有继续切换。")
            }
            guard let id = value(row, "AXIdentifier") as? String,
                  id.hasPrefix("focus-mode-activity-"),
                  value(row, "AXRole") as? String == kAXCheckBoxRole else { continue }
            guard
                  let checked = value(row, "AXValue") as? NSNumber,
                  checked.doubleValue == 0 || checked.doubleValue == 1 else {
                throw RecorderError.message("无法读取系统专注模式状态，没有切换。")
            }
            states.append((id, checked.intValue))
        }
        guard let result = SystemFocusState.confirmed(rows: states) else {
            throw RecorderError.message("无法唯一确认系统勿扰状态，没有切换。")
        }
        return result
    }
    private func withPanel<T>(_ body: (AXUIElement) async throws -> T) async throws -> T {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]
        guard AXIsProcessTrusted(), session[kCGSessionOnConsoleKey as String] as? Bool == true,
              session["CGSSessionScreenIsLocked"] as? Bool != true,
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier != "com.apple.loginwindow",
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.controlcenter").first else {
            throw RecorderError.message("当前无法访问系统勿扰控件，请解锁并检查辅助功能权限。")
        }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        guard let menu = unique(menuID, in: root) else {
            throw RecorderError.message("找不到控制中心入口，没有切换系统设置。")
        }
        var opened = false, expanded = false
        trace("enter panel")
        func cleanup() async {
            await Task { @MainActor in
                if opened, self.unique(self.headerID, in: root) != nil || self.unique(self.moduleID, in: root) != nil {
                    try? self.press(menu)
                    for _ in 0..<12 {
                        try? await Task.sleep(for: .milliseconds(100))
                        if self.unique(self.headerID, in: root) == nil && self.unique(self.moduleID, in: root) == nil { break }
                    }
                } else if expanded, let header = self.unique(self.headerID, in: root),
                          let hide = self.action(header, containing: ["hide details", "隐藏详情", "隐藏详细信息"]) {
                    try? self.press(header, action: hide)
                    for _ in 0..<12 {
                        try? await Task.sleep(for: .milliseconds(100))
                        if self.unique(self.headerID, in: root) == nil { break }
                    }
                }
                // Closing is animated; do not let the next read reuse its outgoing AX tree.
                try? await Task.sleep(for: .milliseconds(500))
            }.value
        }
        do {
            if unique(moduleID, in: root) == nil && unique(headerID, in: root) == nil {
                try Task.checkCancellation()
                try press(menu); opened = true
                try await Task.sleep(for: .milliseconds(400))
            }
            let deadline = ProcessInfo.processInfo.systemUptime + 6
            for attempt in 0..<15 {
                try Task.checkCancellation()
                guard ProcessInfo.processInfo.systemUptime < deadline else { break }
                let header = unique(headerID, in: root) != nil
                trace("panel poll \(attempt): header=\(header), expansion_sent=\(expanded)")
                if header {
                    let result = try await body(root)
                    await cleanup()
                    return result
                }
                if !expanded, let module = unique(moduleID, in: root),
                   let show = action(module, containing: ["show details", "显示详情", "显示详细信息"]) {
                    try press(module, action: show); expanded = true
                    trace("sent show-details action")
                }
                try await Task.sleep(for: .milliseconds(150))
            }
            throw RecorderError.message("系统专注模式面板未就绪，没有盲目切换。")
        } catch {
            await cleanup()
            throw error
        }
    }
    func read() async throws -> SystemFocusState {
        try await withPanel { try self.snapshot($0) }
    }
    func set(_ desired: SystemFocusState, expecting previous: SystemFocusState) async throws {
        try await withPanel { root in
            guard try self.snapshot(root) == previous else {
                throw RecorderError.message("专注模式已被其他操作改变，保留你的当前设置。")
            }
            guard desired != previous else { return }
            let targetID = desired.activeID ?? previous.activeID
            let targets = try self.modeRows(root).filter { self.value($0, "AXIdentifier") as? String == targetID }
            guard targetID != nil, targets.count == 1 else {
                throw RecorderError.message("原来的专注模式已不可用，没有切换其他模式。")
            }
            try Task.checkCancellation()
            try self.press(targets[0])
            // AXPress is a toggle: never send it again on a delayed acknowledgement.
            let deadline = ProcessInfo.processInfo.systemUptime + 3
            for _ in 0..<15 {
                guard ProcessInfo.processInfo.systemUptime < deadline else { break }
                if self.unique(self.headerID, in: root) == nil,
                   let module = self.unique(self.moduleID, in: root),
                   let show = self.action(module, containing: ["show details", "显示详情", "显示详细信息"]) {
                    try self.press(module, action: show)
                }
                if (try? self.snapshot(root)) == desired { return }
                try await Task.sleep(for: .milliseconds(150))
            }
            throw RecorderError.message("未确认系统勿扰切换结果，请在控制中心核对。")
        }
    }
}

@MainActor
final class NotificationQuietSession {
    private let backend: RecordingFocusBackend
    private let journal: URL?
    private var lease: NotificationQuietLease?
    private var savedRecovery: NotificationQuietLease?
    private var unreadableRecovery = false
    var needsCleanup: Bool { lease != nil }
    var canRecover: Bool { savedRecovery != nil || lease != nil || unreadableRecovery }

    init(backend: RecordingFocusBackend? = nil, journal: URL?) {
        self.backend = backend ?? SystemRecordingFocus(); self.journal = journal
        if let journal, FileManager.default.fileExists(atPath: journal.path) {
            if let data = try? Data(contentsOf: journal),
               let recovery = try? JSONDecoder().decode(NotificationQuietLease.self, from: data) {
                savedRecovery = recovery
            } else { unreadableRecovery = true }
        }
    }
    private func remember(_ lease: NotificationQuietLease) throws {
        guard let journal else { return }
        try FileManager.default.createDirectory(at: journal.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(lease).write(to: journal, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journal.path)
    }
    private func clear() throws {
        if let journal, FileManager.default.fileExists(atPath: journal.path) {
            try FileManager.default.removeItem(at: journal)
        }
        lease = nil; savedRecovery = nil; unreadableRecovery = false
    }
    func begin() async -> String {
        guard !canRecover else { return "上次勿扰恢复记录仍在；本次保留系统现状，可在录制结束后恢复。" }
        do {
            try Task.checkCancellation()
            let original = try await backend.read()
            if let active = original.activeID, active != SystemFocusState.doNotDisturb {
                return "已有系统专注模式，保持原模式及定时计划；消息仍遵循该模式的允许清单。"
            }
            guard let change = NotificationQuietLease(previous: original) else {
                return "系统勿扰原本已开启，结束后保持开启。"
            }
            try Task.checkCancellation()
            try remember(change)
            lease = change
            try await backend.set(.init(activeID: SystemFocusState.doNotDisturb), expecting: original)
            return "本批已开启系统勿扰；录完或停止后恢复录制前的专注模式。"
        } catch {
            return "未能确认自动勿扰：\(error.localizedDescription) 录制不会因此退出。"
        }
    }
    func end(recoverPreviousSession: Bool = false) async -> String? {
        if unreadableRecovery && recoverPreviousSession {
            do {
                guard try await backend.read().activeID != SystemFocusState.doNotDisturb else {
                    return "上次恢复记录已损坏，无法确定原状态。请在控制中心手动恢复后再点这里；没有自动切换模式。"
                }
                try clear()
                return "已确认系统不在勿扰模式，清除了损坏的恢复记录；没有改动当前模式。"
            } catch { return "暂时无法核对损坏的恢复记录，请在控制中心手动检查；没有切换模式。" }
        }
        guard let change = lease ?? (recoverPreviousSession ? savedRecovery : nil) else { return nil }
        do {
            let current = try await backend.read()
            switch change.restoration(current: current) {
            case .restore(let previous):
                try await backend.set(previous, expecting: current)
                try clear()
                return "已恢复录制前的系统消息设置。"
            case .leaveUserChange:
                try clear()
                return "专注模式已改变，保留你的当前设置，没有覆盖。"
            }
        } catch {
            savedRecovery = change; lease = nil
            return "系统消息设置尚未恢复：\(error.localizedDescription) 可在录制页点击「恢复消息设置」。"
        }
    }
}
