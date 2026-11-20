import AppKit
import ApplicationServices
import ReplayCore

struct CaptureWindow: Identifiable {
    let id: CGWindowID
    let ownerPID: pid_t
    let title: String
    let frame: CGRect
    let onScreen: Bool

    static func list(pid: pid_t? = nil) -> [CaptureWindow] {
        let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.compactMap { item in
            guard let owner = item[kCGWindowOwnerPID as String] as? Int32, pid == nil || pid == owner,
                  let id = item[kCGWindowNumber as String] as? UInt32,
                  (item[kCGWindowLayer as String] as? Int) == 0,
                  let dictionary = item[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: dictionary), frame.width > 100, frame.height > 100 else { return nil }
            return CaptureWindow(id: id, ownerPID: owner, title: item[kCGWindowName as String] as? String ?? "未命名窗口",
                                 frame: frame, onScreen: item[kCGWindowIsOnscreen as String] as? Bool ?? false)
        }
    }

    func region(crop: CGRect? = nil) throws -> CaptureRegion {
        let screens = NSScreen.screens.compactMap { screen -> (screen: NSScreen, id: UInt32)? in
            guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { return nil }
            return (screen, id)
        }
        let ids = screens.map(\.id)
        guard let index = RegionGeometry.displayIndex(window: frame, displays: ids.map { CGDisplayBounds($0) }) else {
            throw RecorderError.message("窗口不在已连接的显示器上。")
        }
        let bounds = CGDisplayBounds(ids[index])
        let local = crop ?? CGRect(origin: .zero, size: frame.size)
        guard RegionGeometry.validatedWindowCrop(selection: local, window: CGRect(origin: .zero, size: frame.size)) != nil else {
            throw RecorderError.message("游戏区域已超出窗口，请重新选择窗口。")
        }
        return CaptureRegion(displayID: ids[index], displaySize: bounds.size,
                             sourceRect: local.offsetBy(dx: frame.minX - bounds.minX, dy: frame.minY - bounds.minY),
                             scale: screens[index].screen.backingScaleFactor, windowID: id, anchorWindowID: id,
                             anchorFrame: frame, anchorOwnerPID: ownerPID, windowCrop: crop)
    }

    var minimized: Bool {
        guard let window = try? accessibilityWindow() else { return false }
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &value) == .success &&
            (value as? NSNumber)?.boolValue == true
    }

    func raise() throws {
        let window = try accessibilityWindow()
        NSRunningApplication(processIdentifier: ownerPID)?.activate(options: [])
        guard AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success else {
            throw RecorderError.message("无法将游戏窗口置前，已停止点击。")
        }
    }

    func accessibilityWindow() throws -> AXUIElement {
        let app = AXUIElementCreateApplication(ownerPID)
        AXUIElementSetMessagingTimeout(app, 0.3)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { throw RecorderError.message("无法访问目标窗口，请检查辅助功能权限。") }
        var uniqueWindows: [AXUIElement] = []
        var windowIdentities = AccessibilityIdentitySet()
        for window in windows where windowIdentities.insert(window) { uniqueWindows.append(window) }
        var matches = uniqueWindows.filter { window in
            var position: CFTypeRef?, size: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &position) == .success,
                  AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &size) == .success,
                  let position, let size, CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return false }
            var point = CGPoint.zero, dimensions = CGSize.zero
            AXValueGetValue(position as! AXValue, .cgPoint, &point)
            AXValueGetValue(size as! AXValue, .cgSize, &dimensions)
            return abs(point.x - frame.minX) < 2 && abs(point.y - frame.minY) < 2 &&
                abs(dimensions.width - frame.width) < 2 && abs(dimensions.height - frame.height) < 2
        }
        if matches.count > 1 && !title.isEmpty {
            matches = matches.filter { window in
                var value: CFTypeRef?
                return AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &value) == .success && value as? String == title
            }
        }
        guard matches.count == 1 else { throw RecorderError.message("无法唯一确认目标窗口，已停止点击。请将游戏窗口置前后重试。") }
        return matches[0]
    }

    func browserTabs() throws -> [AXUIElement] {
        var result: [AXUIElement] = []
        var queue: [(AXUIElement, Bool, Int)] = [(try accessibilityWindow(), false, 0)]
        var visited = AccessibilityIdentitySet()
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while let (element, inGroup, depth) = queue.popLast() {
            // Chrome exposes the same tab through several AXChildren paths.
            // Deduplicate identity, not titles: distinct same-named tabs remain distinct.
            if !visited.insert(element) { continue }
            guard visited.count <= 1500, ProcessInfo.processInfo.systemUptime < deadline else {
                throw RecorderError.message("读取浏览器标签超时或信息不完整，请稍后重试；没有猜测标签。")
            }
            var roleValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue) == .success,
                  let role = roleValue as? String else {
                throw RecorderError.message("浏览器控件正在变化，尚未确认保活标签。")
            }
            if role == "AXWebArea" { continue }
            let group = inGroup || role == "AXTabGroup"
            if group && ["AXRadioButton", "AXTab", "AXTabButton"].contains(role) { result.append(element); continue }
            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
               let children = children as? [AXUIElement] {
                guard children.isEmpty || depth < 14 else {
                    throw RecorderError.message("浏览器标签结构过深，信息不完整；请显示标签栏后重试。")
                }
                queue.append(contentsOf: children.map { ($0, group, depth + 1) })
            }
        }
        return result
    }

    struct ClickCheck {
        let allowed: Bool
        let detail: String
    }

    func checkClick(_ point: CGPoint) -> ClickCheck {
        let items = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var blockers: [[String: Any]] = []
        var targetInStack = false
        for item in items {
            guard (item[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let dictionary = item[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dictionary), bounds.contains(point) else { continue }
            if (item[kCGWindowNumber as String] as? UInt32) == id { targetInStack = true; break }
            blockers.append(item)
        }
        let onlyDockOverlays = !blockers.isEmpty && blockers.allSatisfy { item in
            guard let pid = item[kCGWindowOwnerPID as String] as? Int32,
                  NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.apple.dock",
                  (item[kCGWindowLayer as String] as? Int) == Int(CGWindowLevelForKey(.dockWindow)) else { return false }
            return true
        }
        let hit = accessibilityHit(at: point)
        let allowed = ClickSafety.allows(targetInStack: targetInStack, hasObstruction: !blockers.isEmpty,
                                        onlyDockOverlays: onlyDockOverlays, accessibilityHit: hit)
        let owners = blockers.prefix(3).map {
            "\($0[kCGWindowOwnerName as String] as? String ?? "未知应用")#\($0[kCGWindowNumber as String] as? Int ?? 0)"
        }.joined(separator: ", ")
        return ClickCheck(allowed: allowed, detail: "目标#\(id)，坐标 \(Int(point.x)),\(Int(point.y))，上层窗口：\(owners.isEmpty ? "无" : owners)，命中：\(hit)")
    }

    private func accessibilityHit(at point: CGPoint) -> AccessibilityClickHit {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.3)
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &element) == .success,
              let element else { return .unavailable }
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return .unavailable }
        guard pid == ownerPID else { return .otherWindow }
        var value: CFTypeRef?
        let window: AXUIElement
        if AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &value) == .success,
           let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
            window = value as! AXUIElement
        } else {
            var role: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
                  role as? String == kAXWindowRole else { return .unavailable }
            window = element
        }
        guard let expected = try? accessibilityWindow() else { return .unavailable }
        return CFEqual(window, expected) ? .targetWindow : .otherWindow
    }
}
