import Foundation

/// Availability never authorizes an old click. The caller must obtain fresh page evidence.
public struct AutomationReadiness {
    public enum State: Equatable { case waiting, needsAssistance, readyForFreshEvidence }
    public private(set) var state = State.waiting
    private var startedAt: Double?
    private var lastTime: Double?
    private var readyAt: Double?
    private let helpAfter: Double
    private let maximumGap: Double
    public init(helpAfter: Double = 10, maximumGap: Double = 2) {
        self.helpAfter = helpAfter.isFinite && helpAfter > 0 ? helpAfter : 10
        self.maximumGap = maximumGap.isFinite && maximumGap >= 0.2 ? maximumGap : 2
    }
    public mutating func observe(available: Bool, at now: Double) -> State {
        guard now.isFinite, lastTime.map({ now >= $0 }) ?? true else {
            readyAt = nil; state = .needsAssistance
            return state
        }
        if startedAt == nil { startedAt = now }
        let duplicateTime = lastTime == now
        if let lastTime, now - lastTime > maximumGap { readyAt = nil }
        lastTime = now
        if available {
            if let readyAt, !duplicateTime, now - readyAt >= 0.2 {
                state = .readyForFreshEvidence
                return state
            }
            if readyAt == nil { readyAt = now }
        } else { readyAt = nil }
        state = now - (startedAt ?? now) >= helpAfter ? .needsAssistance : .waiting
        return state
    }
}
