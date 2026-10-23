import AppKit
import ApplicationServices
import ReplayCore

@MainActor
final class KeepAliveTarget {
    let windowID: CGWindowID
    let ownerPID: pid_t
    let bundleID: String
    let label: String
    private let tab: AXUIElement?
    private let document: AXUIElement?
    var usesDocumentBinding: Bool { document != nil }

    init(window: CaptureWindow, bundleID: String) throws {
        windowID = window.id; ownerPID = window.ownerPID; self.bundleID = bundleID
        let tabs = try window.browserTabs()
        if ["com.google.Chrome", "com.apple.Safari"].contains(bundleID) {
            let page = bundleID == SafariLauncher.bundleID ? SafariLauncher.cloudDocumentForKeepAlive(window) : nil
            guard let binding = BrowserKeepAliveBinding.resolve(selections: tabs.map(Self.selection), hasUniqueOfficialDocument: page != nil) else {
                throw RecorderError.message("未能确认保活标签页或当前官方云原神页面。请切到原神；多标签时显示标签栏后重选，无需新增浏览器权限。")
            }
            switch binding {
            case .tab(let index): tab = tabs[index]; document = nil
            case .officialDocument: tab = nil; document = page
            }
        } else { tab = nil; document = nil }
        label = window.title
    }

    func currentWindow() throws -> CaptureWindow {
        guard NSRunningApplication(processIdentifier: ownerPID)?.bundleIdentifier == bundleID,
              let window = CaptureWindow.list(pid: ownerPID).first(where: { $0.id == windowID }) else {
            throw RecorderError.message("保活目标窗口已关闭，请重新校准。")
        }
        if let tab, !(try window.browserTabs()).contains(where: { CFEqual($0, tab) }) {
            throw RecorderError.message("保活标签页已关闭或身份改变，请重新校准。")
        }
        if let document, SafariLauncher.cloudDocumentForKeepAlive(window).map({ CFEqual($0, document) }) != true {
            throw RecorderError.message("保活页面已切换、刷新或无法确认，已停止；请回到原神并重新选择保活窗口。")
        }
        return window
    }

    func restore() throws {
        let window = try currentWindow()
        try window.raise()
        if let tab, !Self.selected(tab) {
            var settable = DarwinBoolean(false)
            let result: AXError
            if AXUIElementIsAttributeSettable(tab, kAXValueAttribute as CFString, &settable) == .success, settable.boolValue {
                result = AXUIElementSetAttributeValue(tab, kAXValueAttribute as CFString, kCFBooleanTrue)
            } else { result = AXUIElementPerformAction(tab, kAXPressAction as CFString) }
            guard result == .success else { throw RecorderError.message("无法切回保活标签页，已停止。") }
        }
    }

    func validateSelectedTab() throws {
        _ = try currentWindow()
        if let tab, !Self.selected(tab) { throw RecorderError.message("保活标签页未处于选中状态，已停止鼠标移动。") }
    }

    private static func selected(_ element: AXUIElement) -> Bool {
        selection(element) == true
    }

    private static func selection(_ element: AXUIElement) -> Bool? {
        var known = false
        for key in [kAXValueAttribute, kAXSelectedAttribute] {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success,
               let value = value as? NSNumber {
                if value.boolValue { return true }
                known = true
            }
        }
        return known ? false : nil
    }
}
