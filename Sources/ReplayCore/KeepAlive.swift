import Foundation

public enum BrowserKeepAliveBinding: Equatable {
    case tab(Int), officialDocument

    public static func resolve(selections: [Bool?], hasUniqueOfficialDocument: Bool) -> Self? {
        let selected = selections.indices.filter { selections[$0] == true }
        if selected.count == 1 { return .tab(selected[0]) }
        guard selected.isEmpty, selections.count <= 1, hasUniqueOfficialDocument else { return nil }
        return .officialDocument
    }
}

public struct KeepAliveSchedule {
    public static let allowedInterval = 15.0...120.0
    private let interval: Double
    private var nextDue: Double?

    public init(interval: Double) {
        self.interval = Self.allowedInterval.contains(interval) ? interval : 60
    }
    public mutating func start(at uptime: Double) { nextDue = uptime + interval }
    public mutating func stop() { nextDue = nil }
    public mutating func takeDue(at uptime: Double) -> Bool {
        guard let nextDue, uptime >= nextDue else { return false }
        // Never replay missed heartbeats as a burst after a delayed iteration.
        self.nextDue = uptime + interval
        return true
    }
}
