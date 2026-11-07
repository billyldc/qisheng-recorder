import Foundation
import ReplayCore

extension CoreTests {
    func testPerspectiveFlowSequences() {
        checkReplayScenario("switch closes menu and pauses", .init())
        checkReplayScenario("start as soon as controls appear", .init(controlsAppearAt: 5))
        checkReplayScenario("switch leaves menu open", .init(closesOnSwitch: false))
        checkReplayScenario("dice hide the switch for 20 seconds", .init(availableAt: 20))
        checkReplayScenario("disabled switch requires playback before retry", .init(disableFirstSwitch: true))
        checkReplayScenario("first resume click is dropped", .init(dropFirstResume: true))
        checkReplayScenario("delayed resume must not pause again", .init(resumeDelay: 4))
        checkReplayScenario("controls disappear after switch", .init(missingAfterSwitch: 12))
        checkReplayScenario("switch already resumes itself", .init(pausesOnSwitch: false))
        checkReplayScenario("first menu-close click is dropped", .init(closesOnSwitch: false, dropFirstClose: true))
        checkReplayScenario("unreadable names never cause another toggle", .init(missingNames: true))
        checkReplayScenario("pause again while headers are unreadable", .init(headersDelay: 10, pauseAgainAfterResume: 5))
        checkReplayScenario("list reference allows early switch during animation", .init(initialHeadersDelay: 15, useListReference: true))
        checkReplayScenario("dropped switch closes menu before names appear", .init(disableFirstSwitch: true,
            initialHeadersDelay: 45, useListReference: true, failedSwitchClosesMenu: true))
        checkReplayScenario("known names survive corrupted status labels", .init(useListReference: true, corruptStatus: true))
        checkReplayScenario("no list reference waits for live names", .init(initialHeadersDelay: 15))
        checkReplayScenario("successful switch waits beyond 20 seconds for names", .init(headersDelay: 45))
        checkReplayScenario("missing evidence keeps recording without a blind retry", .init(missingNames: true, useListReference: true))
        checkReplayScenario("dice toolbar alone must not pause", .init(gearAppearsAt: 20))
        checkReplayScenario("first pause click is dropped", .init(dropFirstPause: true))
        checkReplayScenario("pause takes four seconds to apply", .init(pauseDelay: 4))
        checkReplayScenario("controls disappear before pause confirmation", .init(missingAfterPause: 8))
        checkReplayScenario("pause confirmation timeout resumes before retry", .init(missingAfterPause: 20))
        checkReplayScenario("menu cannot open until animation advances", .init(menuBlockedUntilResume: true))
        checkReplayScenario("switch unavailable until animation advances", .init(switchBlockedUntilResume: true))
        checkReplayScenario("first menu-open click is dropped", .init(dropFirstOpen: true))
        checkReplayScenario("already paused must not toggle to running", .init(initiallyPaused: true))
        checkReplayScenario("all pause clicks dropped never open menu", .init(dropAllPauses: true))
        testPausePreparationSafety()
        testFavoritesOrientationReference()

        let gear = UnitPoint(x: 0.97, y: 0.12)
        var own = ReplayPerspectiveFlow(desired: .own)
        for second in 0..<100 {
            precondition(own.observe(lines: replayMenu(.opponent), controls: .init(gear: gear, playback: nil),
                                     at: Double(second)) == .finished, "Own-side take must never open a menu")
        }
        var recovery = ReplayPlaybackRecovery()
        for second in 0..<20 {
            let moving = ReplayPlaybackControl(point: .init(x: second % 2 == 0 ? 0.8 : 0.9, y: 0.9), state: .paused)
            precondition(recovery.observe(moving, at: Double(second)) == .wait, "Moving controls are not stable evidence")
        }
        precondition(ReplayPlayerHeaders.detect(playerHeaders(.own, sameNames: true)) == nil)
        precondition(ReplayPlayerHeaders.detect(playerHeaders(.own) + playerHeaders(.own)) == nil)
        var stalled = ReplayPlaybackRecovery()
        var retries = 0
        for second in 0..<100 {
            switch stalled.observe(.init(point: .init(x: 0.9, y: 0.9), state: .paused), at: Double(second)) {
            case .resume: retries += 1
            case .finished: preconditionFailure("Paused replay must not be declared running")
            case .wait: break
            }
        }
        precondition(retries == 3, "Resume retries must be bounded")
        print("PASS: 28 perspective/playback scenarios, pause-before-switch ordering, dice gating, dropped/delayed pause, frozen-menu recovery and own-side no-input")
    }

    private func testPausePreparationSafety() {
        let reference = ReplayPlayerHeaders.detect(playerHeaders(.own))
        for kind in ["movingGear", "movingPlayback", "invalidGear", "unknownPlayback"] {
            var flow = ReplayPerspectiveFlow(desired: .opponent, originalHeaders: reference)
            for second in 0..<40 {
                var gear = UnitPoint(x: 0.97, y: 0.12)
                var play = UnitPoint(x: 0.87, y: 0.9)
                if kind == "movingGear" { gear.x = second % 2 == 0 ? 0.9 : 0.97 }
                if kind == "movingPlayback" { play.x = second % 2 == 0 ? 0.8 : 0.87 }
                if kind == "invalidGear" { gear.x = .nan }
                let control: ReplayPlaybackControl? = kind == "unknownPlayback" ? nil : .init(point: play, state: .running)
                precondition(flow.observe(lines: playerHeaders(.own), controls: .init(gear: gear, playback: control),
                                          at: Double(second)) == .wait, "Unsafe preparation: \(kind)")
            }
        }
        var unexpectedMenu = ReplayPerspectiveFlow(desired: .opponent, originalHeaders: reference)
        let gear = UnitPoint(x: 0.97, y: 0.12)
        let action = unexpectedMenu.observe(lines: replayMenu(.own) + playerHeaders(.own),
            controls: .init(gear: gear, playback: .init(point: .init(x: 0.87, y: 0.9), state: .paused)), at: 0)
        precondition(action == .closeMenu(gear, .unavailable), "Menu glyph cannot establish a prior pause")
    }

    private func testFavoritesOrientationReference() {
        let play = UnitPoint(x: 0.94, y: 0.2)
        let date = "2000-02-03_0405"
        let reference = ReplayPlayerHeaders.fromFavorites(favoriteRow(), date: date, play: play)
        precondition(reference == ReplayPlayerHeaders.detect(playerHeaders(.own)))
        precondition(ReplayPlayerHeaders.stable(reference, reference) == reference)
        precondition(ReplayPlayerHeaders.stable(reference, nil) == nil)
        precondition(ReplayPlayerHeaders.fromFavorites(favoriteRow(), date: "2000-02-03_0406", play: play) == nil)
        precondition(ReplayPlayerHeaders.fromFavorites(favoriteRow(), date: date, play: .init(x: 0.94, y: 0.7)) == nil)
        var duplicate = favoriteRow(); duplicate.append(duplicate[1])
        precondition(ReplayPlayerHeaders.fromFavorites(duplicate, date: date, play: play) == nil)
        var same = favoriteRow(); same[2].text = same[1].text
        precondition(ReplayPlayerHeaders.fromFavorites(same, date: date, play: play) == nil)
        var collision = favoriteRow(); collision[2].text = "player1"
        precondition(ReplayPlayerHeaders.fromFavorites(collision, date: date, play: play) == nil)
        var malformed = favoriteRow(); malformed[1].x = .nan
        precondition(ReplayPlayerHeaders.fromFavorites(malformed, date: date, play: play) == nil)
        var statuses = playerHeaders(.opponent)
        statuses[1].text = "正在等同："; statuses[3].text = "动画"
        precondition(ReplayPlayerHeaders.detect(statuses) == nil)
        precondition(ReplayPlayerHeaders.detect(statuses, matching: reference) == reference?.swapped)
        var nearTop = statuses
        nearTop[0].y = 0.0317
        precondition(ReplayPlayerHeaders.detect(nearTop, matching: reference) == reference?.swapped)
        nearTop[0].y = 0.01
        precondition(ReplayPlayerHeaders.detect(nearTop, matching: reference) == nil)
        statuses.append(statuses[0])
        precondition(ReplayPlayerHeaders.detect(statuses, matching: reference) == nil)
        precondition(ReplayPlayerHeaders.detect(playerHeaders(.own, sameNames: true), matching: reference) == nil)

        var misreadList = favoriteRow()
        misreadList[1].text = "misread"
        let misreadReference = ReplayPlayerHeaders.fromFavorites(misreadList, date: date, play: play)!
        let observedOwn = ReplayPlayerHeaders.detect(playerHeaders(.own))!
        let observedOpponent = ReplayPlayerHeaders.detect(playerHeaders(.opponent))!
        precondition(observedOwn.perspective(relativeTo: misreadReference) == .own)
        precondition(observedOpponent.perspective(relativeTo: misreadReference) == .opponent)
        var unrelated = playerHeaders(.own)
        unrelated[0].text = "otherA"; unrelated[2].text = "otherB"
        precondition(ReplayPlayerHeaders.detect(unrelated)?.perspective(relativeTo: misreadReference) == nil)
        precondition(ReplayPlayerHeaders.detect(playerHeaders(.own, sameNames: true)) == nil)
        var misreadFlow = ReplayPerspectiveFlow(desired: .opponent, originalHeaders: misreadReference)
        let running = ReplayPlaybackControls(gear: .init(x: 0.97, y: 0.12),
            playback: .init(point: .init(x: 0.87, y: 0.9), state: .running))
        precondition(misreadFlow.observe(lines: playerHeaders(.opponent), controls: running, at: 0) == .wait)
        precondition(misreadFlow.observe(lines: playerHeaders(.opponent), controls: running, at: 1) == .wait)
        precondition(misreadFlow.confirmedPerspective == .opponent)
        precondition(misreadFlow.observe(lines: playerHeaders(.opponent), controls: running, at: 2) == .finished)

        var alreadySwapped = ReplayPerspectiveFlow(desired: .opponent, originalHeaders: reference)
        let controls = ReplayPlaybackControls(gear: .init(x: 0.97, y: 0.12),
            playback: .init(point: .init(x: 0.87, y: 0.9), state: .paused))
        let swappedMenu = replayMenu(.own) + playerHeaders(.opponent)
        precondition(alreadySwapped.observe(lines: swappedMenu, controls: controls, at: 0) == .wait)
        precondition(alreadySwapped.observe(lines: swappedMenu, controls: controls, at: 1) ==
            .closeMenu(controls.gear!, .confirmed), "An already-swapped view must not be toggled back")
        precondition(alreadySwapped.confirmedPerspective == .opponent)
        _ = alreadySwapped.observe(lines: playerHeaders(.own), controls: controls, at: 2)
        _ = alreadySwapped.observe(lines: playerHeaders(.own), controls: controls, at: 3)
        precondition(alreadySwapped.confirmedPerspective == nil, "A later manual swap invalidates old confirmation")
    }
}

private struct Scenario {
    var controlsAppearAt = 0
    var closesOnSwitch = true
    var pausesOnSwitch = true
    var availableAt = 0
    var disableFirstSwitch = false
    var dropFirstResume = false
    var resumeDelay = 0
    var missingAfterSwitch = 0
    var dropFirstClose = false
    var missingNames = false
    var headersDelay = 0
    var pauseAgainAfterResume = 0
    var initialHeadersDelay = 0
    var useListReference = false
    var failedSwitchClosesMenu = false
    var corruptStatus = false
    var gearAppearsAt = 0
    var dropFirstPause = false
    var pauseDelay = 0
    var missingAfterPause = 0
    var menuBlockedUntilResume = false
    var switchBlockedUntilResume = false
    var dropFirstOpen = false
    var initiallyPaused = false
    var dropAllPauses = false
}

private func favoriteRow() -> [TextLine] {
    [TextLine(text: "2000年2月3日 04:05", x: 0.35, y: 0.25, width: 0.15, height: 0.02),
     TextLine(text: "PlayerI", x: 0.15, y: 0.247, width: 0.06, height: 0.025),
     TextLine(text: "guest", x: 0.58, y: 0.247, width: 0.06, height: 0.025)]
}

private func playerHeaders(_ current: ReplayPerspective, sameNames: Bool = false) -> [TextLine] {
    let top = current == .own ? "guest" : "PlayerL"
    let bottom = sameNames ? top : (current == .own ? "PlayerI" : "guest")
    return [TextLine(text: top, x: 0.075, y: 0.155, width: 0.03, height: 0.02),
            TextLine(text: "正在等待…", x: 0.075, y: 0.185, width: 0.06, height: 0.015),
            TextLine(text: bottom, x: 0.075, y: 0.864, width: 0.03, height: 0.02),
            TextLine(text: "正在行动", x: 0.075, y: 0.894, width: 0.06, height: 0.015)]
}

private func replayMenu(_ current: ReplayPerspective, available: Bool = true) -> [TextLine] {
    var lines = [TextLine(text: "查看规则书", x: 0.76, y: 0.10, width: 0.15, height: 0.025),
                 TextLine(text: "退出观看", x: 0.76, y: 0.22, width: 0.15, height: 0.025)]
    if available {
        lines.append(TextLine(text: current == .own ? "切换至对手视角" : "切换至我方视角",
                              x: 0.76, y: 0.16, width: 0.15, height: 0.025))
    }
    return lines
}

private func checkReplayScenario(_ name: String, _ scenario: Scenario) {
    var flow = ReplayPerspectiveFlow(desired: .opponent, originalHeaders: scenario.useListReference
        ? ReplayPlayerHeaders.fromFavorites(favoriteRow(), date: "2000-02-03_0405", play: .init(x: 0.94, y: 0.2)) : nil)
    let gear = UnitPoint(x: 0.97, y: 0.12), play = UnitPoint(x: 0.87, y: 0.9)
    var current = ReplayPerspective.own
    var menuOpen = false, paused = scenario.initiallyPaused
    var switchCount = 0, resumeCount = 0, closeCount = 0, pauseCount = 0, openCount = 0
    var hiddenUntil = 0, headersHiddenUntil = scenario.initialHeadersDelay, resumeAt: Int?, pauseAgainAt: Int?
    var pauseAt: Int?
    var pauseTimes: [Int] = []
    var resumeTimes: [Int] = []
    var trace: [String] = []
    for second in 0..<180 {
        if let due = pauseAt, second >= due { paused = true; pauseAt = nil }
        if let due = resumeAt, second >= due {
            paused = false; resumeAt = nil
            if resumeCount == 1 && scenario.pauseAgainAfterResume > 0 {
                pauseAgainAt = second + scenario.pauseAgainAfterResume
            }
        }
        if let due = pauseAgainAt, second >= due { paused = true; pauseAgainAt = nil }
        let missing = second < hiddenUntil || second < scenario.controlsAppearAt
        // Real-game verification showed this label does NOT change with the side.
        let switchAvailable = second >= scenario.availableAt && (!scenario.switchBlockedUntilResume || resumeCount > 0)
        var lines = missing || !menuOpen ? [] : replayMenu(.own, available: switchAvailable)
        if !missing && !scenario.missingNames && second >= headersHiddenUntil {
            var headers = playerHeaders(current)
            if scenario.corruptStatus { headers[1].text = "正在等同："; headers[3].text = "正在等同：" }
            lines += headers
        }
        let controls = ReplayPlaybackControls(gear: missing || second < scenario.gearAppearsAt ? nil : gear,
            playback: missing ? nil : .init(point: play, state: paused ? .paused : .running))
        let action = flow.observe(lines: lines, controls: controls, at: Double(second))
        if action != .wait { trace.append("\(second): \(action)") }
        switch action {
        case .wait: break
        case .pause(let point):
            precondition(!menuOpen && !paused && !missing && point == play && second >= scenario.gearAppearsAt,
                         "\(name): unsafe pause toggle; \(trace)")
            pauseCount += 1
            pauseTimes.append(second)
            if scenario.dropAllPauses || (scenario.dropFirstPause && pauseCount == 1) { break }
            pauseAt = second + scenario.pauseDelay
            if pauseCount == 1 { hiddenUntil = second + scenario.missingAfterPause }
        case .openMenu(let point):
            precondition(point == gear && paused && !missing && second >= scenario.gearAppearsAt,
                         "\(name): menu opened before confirmed pause; \(trace)")
            openCount += 1
            if scenario.dropFirstOpen && openCount == 1 { break }
            // This is the proposed game behavior, not a live-game acceptance test.
            // Also model a frozen animation that cannot open a menu until resumed.
            if !scenario.menuBlockedUntilResume || resumeCount > 0 { menuOpen = true }
        case .switchView(let point):
            precondition(menuOpen && paused && !missing && switchAvailable,
                         "\(name): switch must follow confirmed pause; \(trace)")
            precondition(point == ReplayPerspectiveMenu.detect(lines)!.switchPoint, name)
            precondition(current == .own, "\(name): toggled back to own side; \(trace)")
            switchCount += 1
            if switchCount == 1 && scenario.availableAt == 0 && scenario.pauseDelay == 0 &&
                !scenario.dropFirstPause && scenario.missingAfterPause == 0 && !scenario.menuBlockedUntilResume &&
                !scenario.switchBlockedUntilResume && !scenario.dropFirstOpen &&
                (scenario.initialHeadersDelay == 0 || scenario.useListReference) {
                precondition(second <= max(scenario.controlsAppearAt, scenario.gearAppearsAt) + (scenario.useListReference ? 5 : 6),
                             "\(name): needless startup delay; \(trace)")
            }
            if scenario.disableFirstSwitch && switchCount == 1 {
                if scenario.failedSwitchClosesMenu { menuOpen = false }
                break
            }
            current = .opponent
            paused = scenario.pausesOnSwitch
            menuOpen = !scenario.closesOnSwitch
            hiddenUntil = second + scenario.missingAfterSwitch
            headersHiddenUntil = max(headersHiddenUntil, second + scenario.headersDelay)
        case .closeMenu(let point, _):
            precondition(menuOpen && !missing && point == gear, name)
            closeCount += 1
            if scenario.dropFirstClose && closeCount == 1 { break }
            menuOpen = false
        case .resume(let point):
            precondition(!menuOpen && paused && !missing && point == play,
                         "\(name): unsafe play toggle; \(trace)")
            resumeCount += 1
            resumeTimes.append(second)
            if scenario.dropFirstResume && resumeCount == 1 { break }
            resumeAt = second + scenario.resumeDelay
        case .finished:
            precondition(!scenario.missingNames, "\(name): must not finish verification without evidence")
            precondition(current == .opponent && !paused && !menuOpen &&
                         flow.confirmedPerspective == (scenario.missingNames ? nil : .opponent),
                         "\(name): finished without actual running opponent view; \(trace)")
            precondition(switchCount == (scenario.disableFirstSwitch ? 2 : 1), name)
            let expectedResumes = (scenario.pausesOnSwitch ? (scenario.dropFirstResume ? 2 : 1) : 0) +
                (scenario.pauseAgainAfterResume > 0 ? 1 : 0) + (scenario.disableFirstSwitch ? 1 : 0)
            if scenario.availableAt > 0 || scenario.missingAfterPause >= 18 ||
                scenario.menuBlockedUntilResume || scenario.switchBlockedUntilResume {
                precondition(resumeCount >= expectedResumes + 1, name)
            } else {
                precondition(resumeCount == expectedResumes, "\(name): unexpected resume count; \(trace)")
            }
            if scenario.initiallyPaused { precondition(pauseCount == 0, name) }
            for (first, second) in zip(pauseTimes, pauseTimes.dropFirst()) {
                precondition(second - first >= 5, "\(name): repeated pause without delay")
            }
            for (first, second) in zip(resumeTimes, resumeTimes.dropFirst()) {
                precondition(second - first >= 5, "\(name): repeated resume without delay")
            }
            return
        }
    }
    if scenario.dropAllPauses {
        precondition(switchCount == 0 && openCount == 0 && resumeCount == 0 && !paused && pauseCount > 0, name)
        for (first, second) in zip(pauseTimes, pauseTimes.dropFirst()) {
            precondition(second - first >= 5, "\(name): repeated pause without delay")
        }
        return
    }
    if scenario.missingNames {
        precondition(flow.confirmedPerspective == nil && !paused, "\(name): keep recording without claiming confirmation")
        precondition(switchCount == (scenario.useListReference ? 1 : 0), "\(name): must not toggle without a reference or blindly retry")
        return
    }
    preconditionFailure("\(name): replay never resumed and completed verification; \(trace)")
}
