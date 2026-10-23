import Foundation

public enum AccessibilityClickHit {
    case targetWindow, otherWindow, unavailable
}

public enum ClickSafety {
    public static func allows(targetInStack: Bool, hasObstruction: Bool, onlyDockOverlays: Bool,
                              accessibilityHit: AccessibilityClickHit) -> Bool {
        guard targetInStack, accessibilityHit != .otherWindow else { return false }
        if !hasObstruction { return true }
        // Dock can report a display-sized transparent surface. It is safe only
        // when hit-testing independently confirms the selected target window.
        return onlyDockOverlays && accessibilityHit == .targetWindow
    }
}

public enum RecordingSafety {
    // Window capture tolerates occlusion; display-region capture does not.
    public static func interruption(unlocked: Bool, targetExists: Bool, fullWindow: Bool,
                                    unattended: Bool, focusLostSeconds: Double) -> String? {
        if !unlocked { return "桌面已锁定或用户会话已切换。当前片段已保存；解锁后返回收藏列表重新开始。" }
        if !targetExists { return "目标窗口已关闭。当前片段已保存，请重新选择窗口。" }
        if focusLostSeconds > 0 && !fullWindow { return "区域录制的目标已离开前台。已保存片段；无人值守请使用全窗口模式。" }
        if fullWindow && !unattended && focusLostSeconds >= 15 {
            return "目标应用离开前台超过 15 秒，已保存片段。无人值守录制需在开始前开启。"
        }
        return nil
    }
}

public struct ReplayEntryCheck {
    private let startedAt: Double
    private let graceSeconds: Double
    private var listHits = 0

    public init(startedAt: Double, graceSeconds: Double) {
        self.startedAt = startedAt
        self.graceSeconds = max(1, graceSeconds)
    }

    public func elapsed(at now: Double) -> Double { max(0, now - startedAt) }

    // The HUD refresh timer can still show the previous take's duration.
    // Entry decisions use a fresh monotonic clock and consecutive observations.
    public mutating func failed(listVisible: Bool, at now: Double) -> Bool {
        guard elapsed(at: now) >= graceSeconds, listVisible else {
            listHits = 0
            return false
        }
        listHits += 1
        return listHits >= 2
    }
}

public struct ReplaySpeedControl: Codable, Equatable, Sendable {
    public let point: UnitPoint
    public let multiplier: Int?
    public init(point: UnitPoint, multiplier: Int?) { self.point = point; self.multiplier = multiplier }
}

public enum ReplayControls {
    // Restrict OCR to the replay toolbar; never treat a card's numeric text as speed.
    public static func speed(in lines: [TextLine]) -> ReplaySpeedControl? {
        let matches = lines.compactMap { line -> ReplaySpeedControl? in
            guard line.x > 0.70, line.y > 0.65, line.width < 0.25, line.height < 0.12 else { return nil }
            let text = line.text.lowercased().filter { !$0.isWhitespace }
                .replacingOccurrences(of: "×", with: "x")
            let one = ["1x", "x1", "1.0x", "x1.0", "1倍", "1倍速", "1.0倍", "1.0倍速"]
            let two = ["2x", "x2", "2.0x", "x2.0", "2倍", "2倍速", "2.0倍", "2.0倍速"]
            let multiplier = one.contains(text) ? 1 : two.contains(text) ? 2 : nil
            guard multiplier != nil || text == "倍速" || text == "播放速度" else { return nil }
            return ReplaySpeedControl(point: UnitPoint(x: line.x + line.width / 2, y: line.y + line.height / 2), multiplier: multiplier)
        }
        return matches.count == 1 ? matches[0] : nil
    }
}
