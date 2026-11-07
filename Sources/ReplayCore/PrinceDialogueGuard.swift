import Foundation

/// Keep dialogue choices from being mistaken for another F prompt while the
/// replay page is opening. This guard never selects a dialogue option.
public struct PrinceDialogueGuard {
    public enum Decision: Equatable {
        case proceed, waitForChoice, waitForReplay, stop
    }

    private var choicesSeen = false
    private var lastProgressAt: Double?
    public private(set) var unconfirmedChoices = 0

    public init() {}

    public mutating func observe(_ state: CloudPageState, at now: Double) -> Decision {
        guard now.isFinite else { return .stop }
        if state == .recentReplays || state == .favorites {
            self = PrinceDialogueGuard()
            return .proceed
        }
        if state == .princeDialogue {
            choicesSeen = true
            return .proceed
        }
        if state == .loading, let previous = lastProgressAt {
            guard now >= previous else { return .stop }
            lastProgressAt = now
            return .proceed
        }
        guard choicesSeen, [.prince, .princeGreeting, .unknown].contains(state) else { return .proceed }
        if state == .unknown, let previous = lastProgressAt {
            guard now >= previous, now - previous <= 25 else { return .stop }
            return .waitForReplay
        }
        unconfirmedChoices += 1
        return unconfirmedChoices <= 3 ? .waitForChoice : .stop
    }

    public mutating func confirmationFailed() {
        unconfirmedChoices += 1
    }

    public mutating func replayClickSent(at now: Double) {
        choicesSeen = true
        unconfirmedChoices = 0
        lastProgressAt = now
    }
}
