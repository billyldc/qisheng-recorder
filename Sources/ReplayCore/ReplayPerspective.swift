import Foundation

public enum ReplayPerspective: String, Codable, CaseIterable, Sendable {
    case own, opponent
    public var label: String { self == .own ? "己方视角" : "对方视角" }
    public var requiresSwitch: Bool { self == .opponent }
}

public enum ReplayRecordingPlan {
    public static func jobs(rows: [Replay], bothPerspectives: Bool) -> [Replay] {
        let selected = rows.filter(\.selected).sorted { $0.id < $1.id }
        func take(_ row: Replay, _ view: ReplayPerspective) -> Replay {
            var result = row
            result.recordingPerspective = view
            result.confirmedPerspective = nil
            result.perspectiveStatus = nil
            return result
        }
        if bothPerspectives {
            return selected.map { take($0, .own) } + selected.map { take($0, .opponent) }
        }
        return selected.map { take($0, $0.preferredPerspective) }
    }
}

public struct ReplayPerspectiveMenu: Equatable, Sendable {
    // The switch label can stay unchanged after a toggle. It is not the current view.
    public let labelTarget: ReplayPerspective
    public let switchPoint: UnitPoint

    private static func localLines(_ lines: [TextLine]) -> [TextLine] {
        lines.filter {
            [$0.x, $0.y, $0.width, $0.height].allSatisfy(\.isFinite) &&
            $0.x > 0.55 && $0.y >= 0 && $0.y < 0.4 && $0.width > 0 && $0.height > 0 &&
            $0.x + $0.width <= 1 && $0.y + $0.height <= 1
        }
    }

    public static func isOpen(_ lines: [TextLine]) -> Bool {
        let local = localLines(lines)
        let rules = local.filter { $0.text.filter { !$0.isWhitespace } == "查看规则书" }
        let exits = local.filter { $0.text.filter { !$0.isWhitespace } == "退出观看" }
        guard rules.count == 1, exits.count == 1 else { return false }
        return abs(rules[0].x + rules[0].width / 2 - exits[0].x - exits[0].width / 2) < 0.08 &&
            (0.03...0.24).contains(exits[0].y + exits[0].height / 2 - rules[0].y - rules[0].height / 2)
    }

    public static func stable(_ first: Self?, _ second: Self?) -> Self? {
        guard let first, let second, first.labelTarget == second.labelTarget,
              abs(first.switchPoint.x - second.switchPoint.x) < 0.02,
              abs(first.switchPoint.y - second.switchPoint.y) < 0.02 else { return nil }
        return second
    }

    public static func detect(_ lines: [TextLine]) -> Self? {
        func compact(_ value: String) -> String { value.filter { !$0.isWhitespace } }
        let local = localLines(lines)
        let matches = local.compactMap { line -> Self? in
            let text = compact(line.text)
            let target: ReplayPerspective
            switch text {
            case "切换至对手视角", "切换至对方视角": target = .opponent
            case "切换至我方视角", "切换至己方视角", "切换至自身视角": target = .own
            default: return nil
            }
            let x = line.x + line.width / 2, y = line.y + line.height / 2
            func adjacent(_ text: String, above: Bool) -> Bool {
                local.contains {
                    compact($0.text) == text && abs($0.x + $0.width / 2 - x) < 0.08 &&
                    (above ? (0.015...0.12).contains(y - ($0.y + $0.height / 2))
                           : (0.015...0.12).contains($0.y + $0.height / 2 - y))
                }
            }
            guard adjacent("查看规则书", above: true), adjacent("退出观看", above: false) else { return nil }
            return Self(labelTarget: target, switchPoint: UnitPoint(x: x, y: y))
        }
        return matches.count == 1 ? matches[0] : nil
    }
}

public struct ReplayPlaybackControl: Decodable, Sendable {
    public enum State: String, Decodable, Sendable { case running, paused }
    public let point: UnitPoint
    public let state: State
    public init(point: UnitPoint, state: State) { self.point = point; self.state = state }
}

public struct ReplayPlaybackControls: Decodable, Sendable {
    public let gear: UnitPoint?
    public let playback: ReplayPlaybackControl?
    public let speed: ReplaySpeedControl?
    public init(gear: UnitPoint?, playback: ReplayPlaybackControl?, speed: ReplaySpeedControl? = nil) {
        self.gear = gear; self.playback = playback; self.speed = speed
    }
}

public struct ReplayPlaybackRecovery {
    public enum Action: Equatable { case wait, resume(UnitPoint), finished }
    private var previous: ReplayPlaybackControl?
    private var stable = 0
    private var resumeCount = 0
    private var lastResume = -Double.infinity
    public init() {}
    public mutating func observe(_ control: ReplayPlaybackControl?, at now: Double = 0) -> Action {
        guard let control, control.point.x.isFinite, control.point.y.isFinite,
              (0...1).contains(control.point.x), (0...1).contains(control.point.y) else {
            stable = 0; previous = nil; return .wait
        }
        let matches = previous.map {
            $0.state == control.state && abs($0.point.x - control.point.x) < 0.02 &&
                abs($0.point.y - control.point.y) < 0.02
        } ?? false
        stable = matches ? stable + 1 : 1
        previous = control
        guard stable >= 2 else { return .wait }
        if control.state == .running { return .finished }
        // Retry only with fresh, stable paused evidence after a network grace period.
        if resumeCount < 3, now - lastResume >= 5 {
            resumeCount += 1; lastResume = now; stable = 0; previous = nil
            return .resume(control.point)
        }
        return .wait
    }
}

public struct ReplayPlayerHeaders: Equatable {
    public let top: String
    public let bottom: String
    public var swapped: Self { Self(top: bottom, bottom: top) }

    private static func normalized(_ name: String) -> String {
        name.lowercased().filter { !$0.isWhitespace }
            .replacingOccurrences(of: "l", with: "i").replacingOccurrences(of: "1", with: "i")
    }

    private static func valid(_ line: TextLine) -> Bool {
        [line.x, line.y, line.width, line.height].allSatisfy(\.isFinite) &&
            line.x >= 0 && line.y >= 0 && line.width > 0 && line.height > 0 &&
            line.x + line.width <= 1 && line.y + line.height <= 1
    }

    // Names are only an in-memory orientation reference, never replay metadata.
    public static func fromFavorites(_ lines: [TextLine], date: String, play: UnitPoint) -> Self? {
        guard play.x.isFinite, play.y.isFinite, (0...1).contains(play.x), (0...1).contains(play.y) else { return nil }
        let local = lines.filter(valid)
        let dates = local.filter { ReplayText.date($0.text) == date && abs($0.y - play.y) < 0.15 }
        guard dates.count == 1 else { return nil }
        let anchor = dates[0]
        let names = local.filter {
            $0.height < 0.06 && $0.width < 0.3 && ReplayText.date($0.text) == nil &&
            abs(($0.y + $0.height / 2) - (anchor.y + anchor.height / 2)) < max(anchor.height, 0.012)
        }
        let own = names.filter { $0.x + $0.width < anchor.x - 0.02 }
        let opponent = names.filter { $0.x > anchor.x + anchor.width + 0.02 && $0.x + $0.width < play.x - 0.04 }
        guard own.count == 1, opponent.count == 1 else { return nil }
        let top = normalized(opponent[0].text), bottom = normalized(own[0].text)
        guard !top.isEmpty, !bottom.isEmpty, top != bottom else { return nil }
        return Self(top: top, bottom: bottom)
    }

    public static func stable(_ first: Self?, _ second: Self?) -> Self? {
        guard let first, first == second else { return nil }
        return first
    }

    public static func detect(_ lines: [TextLine], matching reference: Self? = nil) -> Self? {
        let left = lines.filter {
            valid($0) &&
            $0.x >= 0 && $0.x < 0.25 && $0.width > 0 && $0.width < 0.3 &&
            $0.height > 0 && $0.height < 0.06
        }
        func name(top: Bool) -> String? {
            if let reference {
                // Match the two known names directly: animation and OCR can hide
                // or corrupt the small action-status text below them.
                let matches = left.filter {
                    (top ? (0.04...0.4).contains($0.y) : (0.65...0.98).contains($0.y)) &&
                        [reference.top, reference.bottom].contains(normalized($0.text))
                }
                guard matches.count == 1 else { return nil }
                return normalized(matches[0].text)
            }
            let anchors = left.filter {
                ($0.text.hasPrefix("正在行动") || $0.text.hasPrefix("正在等待")) &&
                (top ? (0.04...0.4).contains($0.y) : (0.65...0.98).contains($0.y))
            }
            guard anchors.count == 1 else { return nil }
            let anchor = anchors[0]
            let names = left.filter {
                (0.003...0.04).contains(anchor.y - $0.y - $0.height) && abs(anchor.x - $0.x) < 0.03
            }
            guard names.count == 1 else { return nil }
            // Vision can read the same thin Latin glyph as I, l or 1.
            // Colliding/identical names are rejected below, never guessed.
            let result = normalized(names[0].text)
            return result.isEmpty ? nil : result
        }
        guard let top = name(top: true), let bottom = name(top: false), top != bottom else { return nil }
        return Self(top: top, bottom: bottom)
    }
}

/// Shared with sequence tests. The menu label is relative to the current viewer,
/// so only stable swapped player headers confirm the requested perspective.
public struct ReplayPerspectiveFlow {
    public enum CloseReason: Equatable { case confirmed, unavailable }
    public enum Action: Equatable {
        case wait, pause(UnitPoint), openMenu(UnitPoint), switchView(UnitPoint)
        case closeMenu(UnitPoint, CloseReason), resume(UnitPoint), finished
    }
    public private(set) var confirmedPerspective: ReplayPerspective?
    public private(set) var waitingForPlayback = false
    public var hasOrientationReference: Bool { originalHeaders != nil }
    private let desired: ReplayPerspective
    private var previousMenu: ReplayPerspectiveMenu?
    private var previousHeaders: ReplayPlayerHeaders?
    private var originalHeaders: ReplayPlayerHeaders?
    private var switchRequested = false
    private var switchAt = 0.0
    private var recovery = ReplayPlaybackRecovery()
    private var nextAttempt = 0.0
    private var openedAt: Double?
    private var menuGear: UnitPoint?
    private var closingMenu = false
    private var pausePreparation = ReplaySwitchPausePreparation()
    private var pausedForSwitch = false

    public init(desired: ReplayPerspective, originalHeaders: ReplayPlayerHeaders? = nil) {
        self.desired = desired
        self.originalHeaders = originalHeaders
    }

    public mutating func observe(lines: [TextLine], controls: ReplayPlaybackControls, at now: Double) -> Action {
        guard desired.requiresSwitch else { return .finished }
        let headers = ReplayPlayerHeaders.detect(lines, matching: originalHeaders)
        let stableHeaders = headers != nil && headers == previousHeaders ? headers : nil
        previousHeaders = headers
        if !switchRequested && originalHeaders == nil { originalHeaders = stableHeaders }
        if let originalHeaders, stableHeaders == originalHeaders.swapped {
            confirmedPerspective = desired
        }
        if let originalHeaders, stableHeaders == originalHeaders {
            confirmedPerspective = nil
        }
        if let gear = controls.gear { menuGear = gear }
        let open = ReplayPerspectiveMenu.isOpen(lines)
        let menu = ReplayPerspectiveMenu.detect(lines)
        if open {
            // Never use a pause/play glyph behind an open menu as playback evidence.
            if openedAt == nil { openedAt = now }
            guard now >= nextAttempt, let gear = menuGear else { return .wait }
            if closingMenu {
                nextAttempt = now + 3
                return .closeMenu(gear, confirmedPerspective == desired ? .confirmed : .unavailable)
            }
            if switchRequested || confirmedPerspective == desired {
                beginRecovery(at: now)
                closingMenu = true
                return .closeMenu(gear, confirmedPerspective == desired ? .confirmed : .unavailable)
            }
            let stableMenu = ReplayPerspectiveMenu.stable(previousMenu, menu)
            previousMenu = menu
            if let originalHeaders, headers == originalHeaders.swapped { return .wait }
            guard pausedForSwitch else {
                // An externally opened menu is not evidence that playback paused.
                beginRecovery(at: now)
                closingMenu = true
                return .closeMenu(gear, .unavailable)
            }
            if let stableMenu, originalHeaders != nil {
                // The game normally closes this menu and pauses after switching.
                // Recover playback independently of whether player headers are readable.
                switchRequested = true
                switchAt = now
                previousHeaders = nil
                beginRecovery(at: now)
                return .switchView(stableMenu.switchPoint)
            }
            if menu == nil || originalHeaders == nil, let openedAt, now - openedAt >= 2 {
                beginRecovery(at: now)
                closingMenu = true
                return .closeMenu(gear, .unavailable)
            }
            return .wait
        }
        openedAt = nil
        closingMenu = false
        previousMenu = nil
        guard now >= nextAttempt else { return .wait }
        if waitingForPlayback {
            switch recovery.observe(controls.playback, at: now) {
            case .resume(let point): return .resume(point)
            case .finished:
                waitingForPlayback = false
                if confirmedPerspective == desired { return .finished }
                // Let the replay advance before verifying headers or retrying a disabled switch.
                nextAttempt = now + 5
            case .wait: break
            }
            return .wait
        }
        if switchRequested || confirmedPerspective == desired {
            // Header verification can outlast the first playback check. Do not
            // finish using an old running observation if the replay paused again.
            switch recovery.observe(controls.playback, at: now) {
            case .resume(let point):
                waitingForPlayback = true
                return .resume(point)
            case .wait:
                waitingForPlayback = true
                return .wait
            case .finished: break
            }
            if confirmedPerspective == desired { return .finished }
            if let originalHeaders, stableHeaders == originalHeaders, now - switchAt >= 8 {
                // Retry only when both player names still occupy their original sides.
                switchRequested = false
            } else {
                // Keep observing while recording, instead of abandoning verification
                // after 20 seconds. Never retry without unchanged-side evidence.
                return .wait
            }
        }
        guard originalHeaders != nil else { return .wait }
        if let originalHeaders, headers == originalHeaders.swapped { return .wait }
        switch pausePreparation.observe(controls, at: now) {
        case .wait: return .wait
        case .pause(let point): return .pause(point)
        case .ready(let gear):
            pausedForSwitch = true
            openedAt = now
            nextAttempt = now + 1
            return .openMenu(gear)
        case .expired:
            // A frozen animation may still hide the menu. Advance the replay
            // before the next attempt instead of waiting forever while paused.
            beginRecovery(at: now)
            return .wait
        }
    }

    private mutating func beginRecovery(at now: Double) {
        waitingForPlayback = true
        recovery = ReplayPlaybackRecovery()
        previousMenu = nil
        nextAttempt = now + 3
        pausedForSwitch = false
        pausePreparation = ReplaySwitchPausePreparation()
    }
}

/// The playback toolbar also appears during dice rolls. Require a stable gear
/// and playback control together, then positively confirm Pause before opening it.
private struct ReplaySwitchPausePreparation {
    enum Action { case wait, pause(UnitPoint), ready(UnitPoint), expired }
    private var previous: ReplayPlaybackControls?
    private var startedAt: Double?
    private var lastPause = -Double.infinity
    private var pauseCount = 0

    mutating func observe(_ controls: ReplayPlaybackControls, at now: Double) -> Action {
        if let startedAt, now - startedAt >= 18 { return .expired }
        guard let gear = controls.gear, let playback = controls.playback,
              valid(gear), valid(playback.point) else {
            previous = nil
            return .wait
        }
        let stable = previous.map {
            guard let oldGear = $0.gear, let oldPlayback = $0.playback else { return false }
            return near(oldGear, gear) && near(oldPlayback.point, playback.point) &&
                oldPlayback.state == playback.state
        } ?? false
        previous = controls
        guard stable else { return .wait }
        if playback.state == .paused {
            if startedAt == nil { startedAt = now }
            return .ready(gear)
        }
        guard pauseCount < 3, now - lastPause >= 5 else { return .wait }
        if startedAt == nil { startedAt = now }
        pauseCount += 1
        lastPause = now
        previous = nil
        return .pause(playback.point)
    }

    private func valid(_ point: UnitPoint) -> Bool {
        point.x.isFinite && point.y.isFinite && (0...1).contains(point.x) && (0...1).contains(point.y)
    }

    private func near(_ first: UnitPoint, _ second: UnitPoint) -> Bool {
        abs(first.x - second.x) < 0.02 && abs(first.y - second.y) < 0.02
    }
}
