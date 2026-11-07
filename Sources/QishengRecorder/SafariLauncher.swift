import AppKit
import ApplicationServices
import ReplayCore

@MainActor
enum SafariLauncher {
    static let bundleID = "com.apple.Safari"
    static let cloudURL = URL(string: "https://ys.mihoyo.com/cloud/")!
    static let userAgreementURL = URL(string: "https://user.mihoyo.com/#/agreement?hideBack=true")!
    static let privacyAgreementURL = URL(string: "https://user.mihoyo.com/#/privacyAgreement?hideBack=true")!

    static func openCloudPage() async throws -> CaptureWindow {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            app.activate(options: [])
            try await Task.sleep(for: .milliseconds(400))
            let candidates = CaptureWindow.list(pid: app.processIdentifier).filter { window in
                pageURL(window).map(CloudLaunchPolicy.allowed) == true
            }
            guard candidates.count < 2 else { throw RecorderError.message("Safari 中有多个云原神窗口。请只保留一个目标窗口，再点继续检查。") }
            if let window = candidates.first { try window.raise(); return window }
        }
        guard let safari = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            throw RecorderError.message("没有找到 Safari。")
        }
        _ = try await NSWorkspace.shared.open([cloudURL], withApplicationAt: safari, configuration: NSWorkspace.OpenConfiguration())
        for _ in 0..<15 {
            try await Task.sleep(for: .seconds(1))
            try Task.checkCancellation()
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
               let window = CaptureWindow.list(pid: app.processIdentifier).first(where: { pageURL($0).map(CloudLaunchPolicy.allowed) == true }) {
                try window.raise()
                return window
            }
        }
        throw RecorderError.message("Safari 页面尚未就绪。请确认已打开官方云原神网页，再点继续检查。")
    }

    static func pageURL(_ window: CaptureWindow) -> URL? {
        for element in elements(window) where string(element, kAXRoleAttribute) == "AXWebArea" {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXURLAttribute as CFString, &value) == .success {
                if let url = value as? URL { return url }
                if let text = value as? String, let url = URL(string: text) { return url }
            }
        }
        return nil
    }

    static func cloudDocumentForKeepAlive(_ window: CaptureWindow) -> AXUIElement? {
        guard let root = try? window.accessibilityWindow() else { return nil }
        var queue = [(root, 0)], pages: [AXUIElement] = []
        var visited = 0
        while let (element, depth) = queue.popLast(), visited < 1500 {
            visited += 1
            if string(element, kAXRoleAttribute) == "AXWebArea" {
                var hidden: CFTypeRef?
                _ = AXUIElementCopyAttributeValue(element, "AXHidden" as CFString, &hidden)
                if (hidden as? NSNumber)?.boolValue != true, let frame = bounds(element),
                   frame.width > 100, frame.height > 100, window.frame.intersects(frame) { pages.append(element) }
                // Frames inside the document are not additional browser tabs.
                continue
            }
            guard depth < 14 else { continue }
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
               let children = value as? [AXUIElement] { queue.append(contentsOf: children.map { ($0, depth + 1) }) }
        }
        guard visited < 1500, queue.isEmpty, pages.count == 1,
              elementURL(pages[0]).map(CloudLaunchPolicy.allowed) == true else { return nil }
        return pages[0]
    }

    static func cloudContentRect(_ window: CaptureWindow) -> CGRect? {
        guard let page = cloudDocumentForKeepAlive(window), let rect = bounds(page) else { return nil }
        let visible = rect.intersection(window.frame)
        guard !visible.isEmpty, visible.width >= 320, visible.height >= 180 else { return nil }
        return visible.offsetBy(dx: -window.frame.minX, dy: -window.frame.minY)
    }

    static func pressStart(_ window: CaptureWindow) throws -> Bool {
        guard pageURL(window).map(CloudLaunchPolicy.allowed) == true else {
            throw RecorderError.message("当前标签页不是已确认的官方云原神页面，已暂停启动。")
        }
        let buttons = elements(window).filter { element in
            guard string(element, kAXRoleAttribute) == kAXButtonRole else { return false }
            return [kAXTitleAttribute, kAXDescriptionAttribute].contains { key in
                ["开始游戏", "进入游戏"].contains(string(element, key)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
            }
        }
        guard buttons.count == 1 else { return false }
        guard AXUIElementPerformAction(buttons[0], kAXPressAction as CFString) == .success else { return false }
        return true
    }

    enum GameKey { case interact, favorites, advanceDialogue, map, forward }

    static func pressGameKey(_ key: GameKey, in window: CaptureWindow,
                             validateSession: @MainActor () throws -> Void) async throws {
        let root = try window.accessibilityWindow()
        let app = AXUIElementCreateApplication(window.ownerPID)
        guard let page = elements(window).first(where: {
            string($0, kAXRoleAttribute) == "AXWebArea" && elementURL($0).map(CloudLaunchPolicy.allowed) == true
        }) else { throw RecorderError.message("无法确认游戏页面，尚未发送快捷键。") }
        func validate() throws {
            try Task.checkCancellation()
            try validateSession()
            guard AXIsProcessTrusted(), NSWorkspace.shared.frontmostApplication?.processIdentifier == window.ownerPID,
                  pageURL(window).map(CloudLaunchPolicy.allowed) == true,
                  attributeElement(app, kAXFocusedWindowAttribute).map({ CFEqual($0, root) }) == true,
                  NSEvent.pressedMouseButtons == 0,
                  CGEventSource.flagsState(.hidSystemState).intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty else {
                throw RecorderError.message("游戏窗口或键盘状态已改变，已停止快捷键。")
            }
            var focused = attributeElement(app, kAXFocusedUIElementAttribute)
            for _ in 0..<20 {
                guard let value = focused else { break }
                if ["AXTextField", "AXSecureTextField", "AXTextArea", "AXComboBox"].contains(string(value, kAXRoleAttribute) ?? "") {
                    throw RecorderError.message("焦点仍在输入框，尚未发送游戏快捷键。")
                }
                if CFEqual(value, page) { return }
                focused = attributeElement(value, kAXParentAttribute)
            }
            throw RecorderError.message("未能确认游戏获得键盘焦点，尚未发送快捷键。")
        }
        try Task.checkCancellation(); try validateSession()
        guard pageURL(window).map(CloudLaunchPolicy.allowed) == true else { throw RecorderError.message("已离开官方云原神页面。") }
        _ = AXUIElementSetAttributeValue(page, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        try await Task.sleep(for: .milliseconds(150))
        try validate()
        let code: CGKeyCode
        switch key {
        case .interact: code = 3 // F
        case .favorites: code = 14 // E
        case .advanceDialogue: code = 49 // Space
        case .map: code = 46 // M
        case .forward: code = 13 // W
        }
        let events = try KeyboardInput.key(code) // Physical game keys, never text injection.
        events[0].post(tap: .cghidEventTap)
        // Always release a posted key even when cancellation or focus change occurs mid-key.
        try? await Task.sleep(for: .milliseconds(key == .forward ? 650 : 180))
        events[1].post(tap: .cghidEventTap)
        try validate()
    }

    static func hasPasswordForm(_ window: CaptureWindow) -> Bool { passwordForm(window) != nil }

    static func passwordLoginPoint(_ window: CaptureWindow) -> UnitPoint? {
        guard pageURL(window).map(CloudLaunchPolicy.allowed) == true else { return nil }
        let matches = loginElements(window).filter { element in
            [kAXTitleAttribute, kAXDescriptionAttribute].contains { key in
                ["密码登录", "账号密码登录", "帐号密码登录"].contains(string(element, key)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
            }
        }
        var points: [UnitPoint] = []
        for element in matches {
            guard let bounds = bounds(element), window.frame.contains(bounds) else { continue }
            let point = UnitPoint(x: (bounds.midX - window.frame.minX) / window.frame.width,
                                  y: (bounds.midY - window.frame.minY) / window.frame.height)
            if !points.contains(where: { abs($0.x - point.x) < 0.005 && abs($0.y - point.y) < 0.005 }) { points.append(point) }
        }
        return points.count == 1 ? points[0] : nil
    }

    static func fillAndSubmit(_ window: CaptureWindow, credentials: CloudCredentials,
                              validateSession: @MainActor () throws -> Void,
                              click: @MainActor (UnitPoint) async throws -> Void) async throws -> SafariLoginResult {
        try KeyboardInput.validateText(credentials.account)
        try KeyboardInput.validateText(credentials.password)
        guard pageURL(window).map(CloudLaunchPolicy.allowed) == true, let form = passwordForm(window) else {
            throw RecorderError.message("未能确认官方密码登录表单，尚未填写账号密码。")
        }
        try validateSession()
        try window.raise()
        try await Task.sleep(for: .milliseconds(200))
        let root = try window.accessibilityWindow()
        guard let page = elements(window).first(where: { string($0, kAXRoleAttribute) == "AXWebArea" && elementURL($0).map(CloudLaunchPolicy.allowed) == true }) else {
            throw RecorderError.message("登录页面已变化，已停止填写。")
        }
        let app = AXUIElementCreateApplication(window.ownerPID)
        AXUIElementSetMessagingTimeout(app, 0.3)
        func validateTarget(_ field: AXUIElement? = nil) throws {
            try Task.checkCancellation()
            try validateSession()
            guard AXIsProcessTrusted(), NSWorkspace.shared.frontmostApplication?.processIdentifier == window.ownerPID,
                  NSEvent.pressedMouseButtons == 0,
                  CGEventSource.flagsState(.hidSystemState).intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty,
                  elementURL(page).map(CloudLaunchPolicy.allowed) == true,
                  let focusedWindow = attributeElement(app, kAXFocusedWindowAttribute), CFEqual(focusedWindow, root) else {
                throw RecorderError.message("登录窗口、页面或键盘状态已变化，已停止输入。请切回官方密码登录页后重试。")
            }
            if let field {
                guard let focused = attributeElement(app, kAXFocusedUIElementAttribute), CFEqual(focused, field) else {
                    throw RecorderError.message("登录输入框已失去焦点，已停止输入；未切换到其他位置继续填写。")
                }
            }
        }
        for (element, value) in [(form.account, credentials.account), (form.password, credentials.password)] {
            try validateTarget()
            _ = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            try await Task.sleep(for: .milliseconds(120))
            if attributeElement(app, kAXFocusedUIElementAttribute).map({ CFEqual($0, element) }) != true {
                try validateTarget()
                guard let frame = bounds(element), window.frame.contains(frame) else {
                    throw RecorderError.message("无法确认登录输入框的位置，已停止填写。")
                }
                try await click(UnitPoint(x: (frame.midX - window.frame.minX) / window.frame.width,
                                          y: (frame.midY - window.frame.minY) / window.frame.height))
                try await Task.sleep(for: .milliseconds(120))
            }
            try await KeyboardInput.replaceText(value, pid: window.ownerPID) { try validateTarget(element) }
        }
        try validateTarget(form.password)
        try validateSession()
        return try submit(window)
    }

    static func submit(_ window: CaptureWindow) throws -> SafariLoginResult {
        try Task.checkCancellation()
        guard pageURL(window).map(CloudLaunchPolicy.allowed) == true, hasPasswordForm(window) else {
            throw RecorderError.message("登录页面已变化，尚未提交。")
        }
        let controls = loginElements(window)
        if CloudAgreementPolicy.requiresConfirmation(controls.map(label)) {
            guard let agreement = agreementCheckbox(controls), checked(agreement) == true else { return .needsAgreement }
        }
        let buttons = controls.filter { element in
            [kAXButtonRole, "AXLink"].contains(string(element, kAXRoleAttribute) ?? "") &&
            [kAXTitleAttribute, kAXDescriptionAttribute].contains { key in
                string(element, key)?.filter { !$0.isWhitespace } == "登录"
            }
        }
        guard buttons.count == 1, enabled(buttons[0]),
              pageURL(window).map(CloudLaunchPolicy.allowed) == true,
              AXUIElementPerformAction(buttons[0], kAXPressAction as CFString) == .success else { return .needsManualSubmit }
        return .submitted
    }

    private static func elementURL(_ element: AXUIElement) -> URL? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXURLAttribute as CFString, &value) == .success else { return nil }
        return (value as? URL) ?? (value as? String).flatMap(URL.init(string:))
    }

    private static func attributeElement(_ element: AXUIElement, _ key: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func enabled(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, kAXEnabledAttribute as CFString, &value) == .success &&
            (value as? Bool) == true
    }

    static func pressAgreement(_ window: CaptureWindow) -> Bool {
        guard pageURL(window).map(CloudLaunchPolicy.allowed) == true, hasPasswordForm(window),
              let agreement = agreementCheckbox(loginElements(window)), checked(agreement) == false else { return false }
        return AXUIElementPerformAction(agreement, kAXPressAction as CFString) == .success
    }

    static func agreementPoint(_ window: CaptureWindow) -> UnitPoint? {
        guard pageURL(window).map(CloudLaunchPolicy.allowed) == true, hasPasswordForm(window),
              let agreement = agreementCheckbox(loginElements(window)), checked(agreement) == false,
              let frame = bounds(agreement), frame.width <= 40, frame.height <= 40, window.frame.contains(frame),
              pageURL(window).map(CloudLaunchPolicy.allowed) == true else { return nil }
        return UnitPoint(x: (frame.midX - window.frame.minX) / window.frame.width,
                         y: (frame.midY - window.frame.minY) / window.frame.height)
    }

    private static func agreementCheckbox(_ controls: [AXUIElement]) -> AXUIElement? {
        let boxes = controls.filter { string($0, kAXRoleAttribute) == kAXCheckBoxRole }
        guard let index = CloudAgreementPolicy.checkboxIndex(labels: boxes.map(label), pageLabels: controls.map(label)) else { return nil }
        return boxes[index]
    }

    private static func checked(_ element: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
              let number = value as? NSNumber, [0, 1].contains(number.intValue) else { return nil }
        return number.intValue == 1
    }

    private struct PasswordForm { let account: AXUIElement; let password: AXUIElement }
    private static func passwordForm(_ window: CaptureWindow) -> PasswordForm? {
        guard pageURL(window).map(CloudLaunchPolicy.allowed) == true else { return nil }
        let fields = loginElements(window).filter {
            [kAXTextFieldRole, kAXComboBoxRole, "AXSecureTextField"].contains(string($0, kAXRoleAttribute) ?? "")
        }
        func secure(_ field: AXUIElement) -> Bool {
            string(field, kAXSubroleAttribute) == "AXSecureTextField" || string(field, kAXRoleAttribute) == "AXSecureTextField"
        }
        let passwords = fields.filter(secure)
        let plain = fields.filter { !secure($0) && !label($0).contains("验证码") }
        let preferred = plain.filter { field in ["手机", "账号", "帐号", "邮箱", "用户名"].contains(where: label(field).contains) }
        let accounts = preferred.count == 1 ? preferred : plain
        guard passwords.count == 1, accounts.count == 1 else { return nil }
        return PasswordForm(account: accounts[0], password: passwords[0])
    }

    private static func label(_ element: AXUIElement) -> String {
        var keys = [kAXTitleAttribute, kAXDescriptionAttribute, "AXPlaceholderValue"]
        if string(element, kAXRoleAttribute) == kAXStaticTextRole { keys.append(kAXValueAttribute) }
        return keys.compactMap { string(element, $0) }.joined(separator: " ")
    }

    private static func loginElements(_ window: CaptureWindow) -> [AXUIElement] {
        guard let root = try? window.accessibilityWindow() else { return [] }
        var result: [AXUIElement] = [], queue = [(root, false, 0)], visited = 0
        while let (element, trusted, depth) = queue.popLast(), visited < 1500 {
            visited += 1
            var trusted = trusted
            if string(element, kAXRoleAttribute) == "AXWebArea" {
                var value: CFTypeRef?
                guard AXUIElementCopyAttributeValue(element, kAXURLAttribute as CFString, &value) == .success else { continue }
                let url = (value as? URL) ?? (value as? String).flatMap(URL.init(string:))
                guard let url, CloudLaunchPolicy.loginFrameAllowed(url) else { continue }
                trusted = true
            }
            if trusted, visible(element, in: window.frame) { result.append(element) }
            guard depth < 22 else { continue }
            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
               let children = children as? [AXUIElement] {
                queue.append(contentsOf: children.map { ($0, trusted, depth + 1) })
            }
        }
        return result
    }

    private static func visible(_ element: AXUIElement, in window: CGRect) -> Bool {
        guard let frame = bounds(element) else { return false }
        return frame.width > 1 && frame.height > 1 && window.intersects(frame)
    }

    private static func bounds(_ element: AXUIElement) -> CGRect? {
        var position: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size, CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point), AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    private static func string(_ element: AXUIElement, _ key: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func elements(_ window: CaptureWindow) -> [AXUIElement] {
        guard let root = try? window.accessibilityWindow() else { return [] }
        var result: [AXUIElement] = [], queue = [(root, 0)]
        while let (element, depth) = queue.popLast(), result.count < 1200 {
            result.append(element)
            guard depth < 20 else { continue }
            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
               let children = children as? [AXUIElement] {
                queue.append(contentsOf: children.map { ($0, depth + 1) })
            }
        }
        return result
    }
}

enum CloudLaunchPhase: String {
    case idle, opening, checking, login, needsFavorites, countdown, recording, complete, cancelled
    var needsUser: Bool { self == .login || self == .needsFavorites }
}

enum SafariLoginResult { case submitted, needsAgreement, needsManualSubmit }
