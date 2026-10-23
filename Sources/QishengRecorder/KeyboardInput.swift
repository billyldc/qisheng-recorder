import AppKit
import Carbon

enum KeyboardInput {
    static func validateText(_ text: String) throws {
        guard !text.isEmpty, text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
              text.allSatisfy({ String($0).utf16.count <= 20 }) else {
            throw RecorderError.message("账号或密码包含无法安全逐字输入的字符，请在 Safari 手动登录。")
        }
    }

    static func key(_ code: CGKeyCode, flags: CGEventFlags = []) throws -> [CGEvent] {
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else {
            throw RecorderError.message("无法创建键盘输入事件。")
        }
        down.flags = flags; up.flags = []
        return [down, up]
    }

    static func character(_ value: Character) throws -> [CGEvent] {
        let text = String(value)
        try validateText(text)
        let units = Array(text.utf16)
        let events = try key(CGKeyCode(kVK_ANSI_A))
        for event in events { event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units) }
        return events
    }

    private static func selectAll(in pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return false }
        func children(_ element: AXUIElement) -> [AXUIElement] {
            var value: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
            return value as? [AXUIElement] ?? []
        }
        func title(_ element: AXUIElement) -> String {
            var value: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value)
            return value as? String ?? ""
        }
        let edit = children(value as! AXUIElement).filter { ["Edit", "编辑"].contains(title($0)) }
        guard edit.count == 1 else { return false }
        var queue = [(edit[0], 0)], matches: [AXUIElement] = []
        while let (element, depth) = queue.popLast() {
            if ["Select All", "全选"].contains(title(element)) { matches.append(element) }
            if depth < 4 { queue.append(contentsOf: children(element).map { ($0, depth + 1) }) }
        }
        guard matches.count == 1 else { return false }
        var enabled: CFTypeRef?
        guard AXUIElementCopyAttributeValue(matches[0], kAXEnabledAttribute as CFString, &enabled) == .success,
              enabled as? Bool == true else { return false }
        return AXUIElementPerformAction(matches[0], kAXPressAction as CFString) == .success
    }

    @MainActor
    static func replaceText(_ text: String, pid: pid_t, validate: @MainActor () throws -> Void) async throws {
        try validateText(text)
        func post(_ events: [CGEvent]) async throws {
            try Task.checkCancellation()
            try validate()
            // Complete the release sequence even when cancellation arrives mid-key.
            for event in events {
                event.postToPid(pid)
                try? await Task.sleep(for: .milliseconds(12))
            }
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(45))
        }
        try Task.checkCancellation()
        try validate()
        guard selectAll(in: pid) else { throw RecorderError.message("无法确认目标输入框的全选操作，已停止输入。请在 Safari 手动登录。") }
        try await Task.sleep(for: .milliseconds(150))
        try await post(key(CGKeyCode(kVK_Delete)))
        for value in text { try await post(character(value)) }
        try validate()
    }
}
