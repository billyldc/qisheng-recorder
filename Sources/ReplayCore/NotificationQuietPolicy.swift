import Foundation

public struct FocusPanelNavigation {
    public enum Action: Equatable { case wait, open, expand, ready }
    private var opened = false
    private var expanded = false
    private var headerHits = 0
    private var sawPanel = false
    private var emptyHits = 0
    public init() {}

    public mutating func observe(header: Bool, module: Bool) -> Action {
        headerHits = header ? headerHits + 1 : 0
        emptyHits = header || module ? 0 : emptyHits + 1
        if header || module { sawPanel = true }
        if headerHits >= 2 { return .ready }
        if header { return .wait }
        if module && !expanded { expanded = true; return .expand }
        // Closing panels can leave one outgoing AX snapshot. Reopen only after
        // observing that it has gone, never by toggling an unobserved mode.
        if !module && !opened && (!sawPanel || emptyHits >= 6) {
            opened = true; expanded = false; return .open
        }
        return .wait
    }
}

public struct SystemFocusRow {
    public let id: String
    public let frame: CGRect
    public init(id: String, frame: CGRect) { self.id = id; self.frame = frame }

    /// Expanded duration options reuse their parent mode's AX identifier.
    /// Accept only a taller top row followed by smaller, aligned child rows.
    public static func primaryIndices(_ rows: [Self]) -> [Int]? {
        guard rows.allSatisfy({ [$0.frame.minX, $0.frame.minY, $0.frame.width, $0.frame.height].allSatisfy(\.isFinite)
            && $0.frame.width > 0 && $0.frame.height > 0 }) else { return nil }
        let groups = Dictionary(grouping: rows.indices, by: { rows[$0].id })
        var result: [Int] = []
        for group in groups.values {
            let sorted = group.sorted { rows[$0].frame.minY < rows[$1].frame.minY }
            let first = sorted[0], parent = rows[first].frame
            if sorted.count > 1 {
                guard sorted.count <= 4, sorted.dropFirst().allSatisfy({ index in
                    let child = rows[index].frame
                    return child.minY >= parent.maxY && child.height < parent.height - 2 &&
                        abs(child.minX - parent.minX) < 2 && abs(child.width - parent.width) < 2
                }) else { return nil }
            }
            result.append(first)
        }
        return result.sorted()
    }
}

public struct SystemFocusState: Codable, Equatable, Sendable {
    public static let doNotDisturb = "focus-mode-activity-com.apple.donotdisturb.mode.default"
    public let activeID: String?
    public init(activeID: String?) { self.activeID = activeID }

    public static func confirmed(rows: [(id: String, value: Int)]) -> Self? {
        guard rows.contains(where: { $0.id == doNotDisturb }),
              Set(rows.map(\.id)).count == rows.count,
              rows.allSatisfy({ $0.id.hasPrefix("focus-mode-activity-") && (0...1).contains($0.value) }),
              rows.filter({ $0.value == 1 }).count <= 1 else { return nil }
        return Self(activeID: rows.first(where: { $0.value == 1 })?.id)
    }
}

public struct NotificationQuietLease: Codable, Equatable, Sendable {
    public let previous: SystemFocusState
    public init?(previous: SystemFocusState) {
        guard previous.activeID != SystemFocusState.doNotDisturb else { return nil }
        self.previous = previous
    }
    public enum Restoration: Equatable {
        case restore(SystemFocusState), leaveUserChange
    }
    public func restoration(current: SystemFocusState) -> Restoration {
        current.activeID == SystemFocusState.doNotDisturb ? .restore(previous) : .leaveUserChange
    }
}
