import Foundation
import ReplayCore

// Standalone checks also run on Command Line Tools installations without XCTest.
private func XCTAssertEqual<T: Equatable>(_ a: T, _ b: T) { precondition(a == b, "Expected \(b), got \(a)") }
private func XCTAssertFalse(_ value: Bool) { precondition(!value) }
private func XCTAssertNil<T>(_ value: T?) { precondition(value == nil) }
private func XCTAssertLessThan<T: Comparable>(_ a: T, _ b: T) { precondition(a < b) }
private func XCTAssertLessThanOrEqual<T: Comparable>(_ a: T, _ b: T) { precondition(a <= b) }

@main
final class CoreTests {
    static func main() throws {
        let tests = CoreTests()
        tests.testSelectionSupportsReverseDragAndClampsDisplayEdges()
        tests.testRetinaSelectionKeepsEntireNonWidescreenRegion()
        tests.testClickUsesSelectedDisplayOriginAndRegionRatherThanMainScreen()
        tests.testDisplayChoiceUsesLargestWindowIntersection()
        tests.testChineseNamesStayUnderFilesystemByteLimit()
        tests.testDateRecognizesSpacesAndFullwidthColon()
        try tests.testDuplicateFilenamePreservesExistingTake()
        tests.testUnattendedDoesNotBypassSessionSafety()
        tests.testFocusGraceOnlyAppliesToWindowCapture()
        tests.testSpeedOCRRejectsCardNumbersAndAmbiguity()
        tests.testClickOcclusionRequiresEvidence()
        tests.testKeepAliveStartsAndStopsWithReplay()
        tests.testKeepAliveNeverBurstsAfterDelay()
        tests.testKeepAliveIntervalsAreBounded()
        tests.testSpeedCalibrationWinsAndUnknownCanContinue()
        tests.testUpdateVersionsAndDigests()
        try tests.testLegacyReplayAndManualCharacterProtection()
        tests.testCloudLaunchRequiresOfficialPageAndStableFavorites()
        tests.testCloudAgreementOnlySelectsOfficialLegalCheckbox()
        tests.testCloudStartRequiresUniqueVisibleExactLabel()
        tests.testCloudNavigationUsesActualReplayPath()
        tests.testPrincePromptSupportsMergedIconsAndLocalKey()
        tests.testPrinceGreetingMustAdvanceBeforeChoices()
        tests.testPrinceChoiceIconsDoNotHideReplay()
        tests.testPrinceChoicesOverrideLingeringGreeting()
        tests.testPrinceReplayRequiresTwoStableUnambiguousFrames()
        tests.testAlreadyLoggedInWorldStartsKeepalive()
        tests.testFinishedReplayCanReturnToFavorites()
        tests.testRecentCounterIsNeverFavorites()
        tests.testLaunchPreservesDeliberateReplayChoices()
        try tests.testPerspectivePlanAndLegacySidecars()
        tests.testPerspectiveMenuRequiresExactSafeEntry()
        tests.testLaunchPreservesPerspectiveChoices()
        try tests.testPlaybackRecoveryNeverBlindlyToggles()
        tests.testOwnPerspectiveAlwaysSkipsMenus()
        tests.testPerspectiveUnavailableKeepsWaiting()
        tests.testPerspectiveMenuCanBeClosedWithoutSwitchText()
        tests.testKeepAliveAllowsOnlyUniqueSafariDocumentFallback()
        tests.testPerspectiveFlowSequences()
        tests.testEachReplayHasFreshEntryGrace()
        print("PASS: 39 geometry, metadata, file-safety, update, launch, perspective and recording-policy regression checks")
    }

    func testEachReplayHasFreshEntryGrace() {
        for previousDuration in [0.0, 280, 375, 1200] {
            let start = 10_000 + previousDuration
            var check = ReplayEntryCheck(startedAt: start, graceSeconds: 12)
            XCTAssertEqual(check.elapsed(at: start), 0)
            XCTAssertFalse(check.failed(listVisible: true, at: start + 0.1))
            XCTAssertFalse(check.failed(listVisible: true, at: start + 0.5))
            XCTAssertFalse(check.failed(listVisible: false, at: start + 1))
            XCTAssertFalse(check.failed(listVisible: true, at: start + 12))
            XCTAssertFalse(check.failed(listVisible: false, at: start + 13))
            XCTAssertFalse(check.failed(listVisible: true, at: start + 14))
            XCTAssertEqual(check.failed(listVisible: true, at: start + 15), true)
        }
        var immediate = ReplayEntryCheck(startedAt: 100, graceSeconds: 0)
        XCTAssertFalse(immediate.failed(listVisible: true, at: 100))
        XCTAssertFalse(immediate.failed(listVisible: true, at: 100.5))
        XCTAssertFalse(immediate.failed(listVisible: true, at: 101))
        XCTAssertEqual(immediate.failed(listVisible: true, at: 102), true)
    }

    func testOwnPerspectiveAlwaysSkipsMenus() {
        var own = ReplayPerspectiveFlow(desired: .own)
        XCTAssertFalse(ReplayPerspective.own.requiresSwitch)
        XCTAssertEqual(ReplayPerspective.opponent.requiresSwitch, true)
        for second in 0..<100 {
            XCTAssertEqual(own.observe(lines: [], controls: .init(gear: nil, playback: nil), at: Double(second)), .finished)
        }
        let row = Replay(id: 1, date: "date", mode: "mode", left: [], right: [], play: UnitPoint(x: 0.9, y: 0.2))
        XCTAssertEqual(ReplayRecordingPlan.jobs(rows: [row], bothPerspectives: true).map { $0.preferredPerspective.requiresSwitch }, [false, true])
    }

    func testPerspectiveUnavailableKeepsWaiting() {
        var state = ReplayPerspectiveFlow(desired: .opponent)
        for second in 0..<100 {
            XCTAssertEqual(state.observe(lines: [], controls: .init(gear: nil, playback: nil), at: Double(second)), .wait)
        }
        XCTAssertNil(state.confirmedPerspective)
    }

    func testPerspectiveMenuCanBeClosedWithoutSwitchText() {
        let rule = TextLine(text: "查看规则书", x: 0.76, y: 0.10, width: 0.15, height: 0.025)
        var exit = TextLine(text: "退出观看", x: 0.76, y: 0.22, width: 0.15, height: 0.025)
        XCTAssertEqual(ReplayPerspectiveMenu.isOpen([rule, exit]), true)
        XCTAssertNil(ReplayPerspectiveMenu.detect([rule, exit]))
        XCTAssertFalse(ReplayPerspectiveMenu.isOpen([exit]))
        XCTAssertFalse(ReplayPerspectiveMenu.isOpen([rule, exit, exit]))
        exit.x = 0.1
        XCTAssertFalse(ReplayPerspectiveMenu.isOpen([rule, exit]))
    }

    func testKeepAliveAllowsOnlyUniqueSafariDocumentFallback() {
        XCTAssertEqual(BrowserKeepAliveBinding.resolve(selections: [], hasUniqueOfficialDocument: true), .officialDocument)
        XCTAssertEqual(BrowserKeepAliveBinding.resolve(selections: [nil], hasUniqueOfficialDocument: true), .officialDocument)
        XCTAssertEqual(BrowserKeepAliveBinding.resolve(selections: [false], hasUniqueOfficialDocument: true), .officialDocument)
        XCTAssertEqual(BrowserKeepAliveBinding.resolve(selections: [false, true], hasUniqueOfficialDocument: false), .tab(1))
        XCTAssertNil(BrowserKeepAliveBinding.resolve(selections: [], hasUniqueOfficialDocument: false))
        XCTAssertEqual(BrowserKeepAliveBinding.resolve(selections: [nil, nil], hasUniqueOfficialDocument: true), .officialDocument)
        XCTAssertEqual(BrowserKeepAliveBinding.resolve(selections: [false, false], hasUniqueOfficialDocument: true), .officialDocument)
        XCTAssertNil(BrowserKeepAliveBinding.resolve(selections: [nil, nil], hasUniqueOfficialDocument: false))
        XCTAssertNil(BrowserKeepAliveBinding.resolve(selections: [true, true], hasUniqueOfficialDocument: true))
    }
    func testPlaybackRecoveryNeverBlindlyToggles() throws {
        func control(_ state: String) throws -> ReplayPlaybackControl {
            try JSONDecoder().decode(ReplayPlaybackControl.self, from: Data("{\"point\":{\"x\":0.9,\"y\":0.9},\"state\":\"\(state)\"}".utf8))
        }
        let paused = try control("paused"), running = try control("running")
        var recovery = ReplayPlaybackRecovery()
        XCTAssertEqual(recovery.observe(paused), .wait)
        XCTAssertEqual(recovery.observe(nil), .wait)
        XCTAssertEqual(recovery.observe(paused), .wait)
        XCTAssertEqual(recovery.observe(paused), .resume(paused.point))
        for _ in 0..<6 { XCTAssertEqual(recovery.observe(paused), .wait) }
        XCTAssertEqual(recovery.observe(running), .wait)
        XCTAssertEqual(recovery.observe(running), .finished)
        recovery = ReplayPlaybackRecovery()
        XCTAssertEqual(recovery.observe(running), .wait)
        XCTAssertEqual(recovery.observe(running), .finished)
    }
    func testPerspectivePlanAndLegacySidecars() throws {
        let legacy = Data(#"{"id":1,"selected":true,"date":"2000-02-03_0405","mode":"匹配模式","left":["A","B","C"],"right":["D","E","F"],"play":{"x":0.94,"y":0.2},"playDetected":true}"#.utf8)
        let a = try JSONDecoder().decode(Replay.self, from: legacy)
        XCTAssertEqual(a.preferredPerspective, .own)
        XCTAssertNil(a.recordingPerspective)
        var b = a; b.id = 2; b.recordingPerspective = .opponent
        var skipped = a; skipped.id = 3; skipped.selected = false
        let single = ReplayRecordingPlan.jobs(rows: [b, skipped, a], bothPerspectives: false)
        XCTAssertEqual(single.map(\.id), [1, 2])
        XCTAssertEqual(single.map(\.preferredPerspective), [.own, .opponent])
        let both = ReplayRecordingPlan.jobs(rows: [b, skipped, a], bothPerspectives: true)
        XCTAssertEqual(both.map(\.id), [1, 2, 1, 2])
        XCTAssertEqual(both.map(\.preferredPerspective), [.own, .own, .opponent, .opponent])
        XCTAssertEqual(both.map(\.left), Array(repeating: a.left, count: 4))
        XCTAssertEqual(both.map(\.right), Array(repeating: a.right, count: 4))
        XCTAssertEqual(b.preferredPerspective, .opponent)
        XCTAssertEqual(Set(both.map(\.filename)).count, 4)
        XCTAssertEqual(both[0].filename.contains("己方视角"), true)
        XCTAssertEqual(both[2].filename.contains("对方视角"), true)
        let encoded = try JSONDecoder().decode(Replay.self, from: JSONEncoder().encode(both[2]))
        XCTAssertEqual(encoded.recordingPerspective, .opponent)
        XCTAssertNil(encoded.confirmedPerspective)
        XCTAssertEqual(ReplayRecordingPlan.jobs(rows: [skipped], bothPerspectives: true), [])
        var long = a; long.left = Array(repeating: String(repeating: "长角色", count: 50), count: 3)
        long.recordingPerspective = .opponent
        XCTAssertEqual(long.filename.contains("对方视角"), true)
        XCTAssertLessThanOrEqual(long.filename.utf8.count, 220)
    }

    func testPerspectiveMenuRequiresExactSafeEntry() {
        func line(_ text: String, _ y: Double) -> TextLine {
            TextLine(text: text, x: 0.76, y: y, width: 0.15, height: 0.025)
        }
        let rule = line("查看规则书", 0.10), exit = line("退出观看", 0.22)
        let own = line("切换至对手视角", 0.16), other = line("切换至我方视角", 0.16)
        XCTAssertEqual(ReplayPerspectiveMenu.detect([rule, own, exit])?.labelTarget, .opponent)
        XCTAssertEqual(ReplayPerspectiveMenu.detect([rule, other, exit])?.labelTarget, .own)
        XCTAssertNil(ReplayPerspectiveMenu.detect([own, exit]))
        XCTAssertNil(ReplayPerspectiveMenu.detect([rule, own]))
        XCTAssertNil(ReplayPerspectiveMenu.detect([rule, own, exit, other]))
        XCTAssertNil(ReplayPerspectiveMenu.detect([rule, line("切换至对手视角并退出", 0.16), exit]))
        var invalid = own; invalid.x = .nan
        XCTAssertNil(ReplayPerspectiveMenu.detect([rule, invalid, exit]))
        invalid = own; invalid.x = 0.1
        XCTAssertNil(ReplayPerspectiveMenu.detect([rule, invalid, exit]))
        invalid = own; invalid.y = 0.8
        XCTAssertNil(ReplayPerspectiveMenu.detect([rule, invalid, exit]))
    }

    func testLaunchPreservesPerspectiveChoices() {
        var row = Replay(id: 1, date: "2000-02-03_0405", mode: "匹配模式", left: ["A","B","C"], right: ["D","E","F"], play: UnitPoint(x: 0.9, y: 0.2))
        var refreshed = row; refreshed.play.y = 0.3
        row.recordingPerspective = .opponent
        XCTAssertEqual(CloudLaunchPolicy.restoringChoices([row], in: [refreshed])?.first?.preferredPerspective, .opponent)
        refreshed.date = "different"
        XCTAssertNil(CloudLaunchPolicy.restoringChoices([row], in: [refreshed]))
    }
    func testCloudNavigationUsesActualReplayPath() {
        func line(_ text: String, _ x: Double, _ y: Double) -> TextLine {
            TextLine(text: text, x: x, y: y, width: 0.05, height: 0.02)
        }
        let f = line("F", 0.55, 0.55), npc = line("「小王子」", 0.62, 0.55)
        XCTAssertEqual(CloudLaunchPolicy.state([f, npc]), .prince)
        XCTAssertEqual(CloudLaunchPolicy.navigationPoint([f, npc]), UnitPoint(x: 0.645, y: 0.56))
        XCTAssertEqual(CloudLaunchPolicy.state([npc]), .unknown)
        XCTAssertEqual(CloudLaunchPolicy.state([f, line("小王子", 0.6, 0.3)]), .unknown)
        XCTAssertEqual(CloudLaunchPolicy.state([f, npc, line("小王子", 0.7, 0.55)]), .unknown)
        let watch = line("观看一下对局回放。", 0.65, 0.6)
        XCTAssertEqual(CloudLaunchPolicy.state([npc, watch]), .princeDialogue)
        XCTAssertEqual(CloudLaunchPolicy.navigationPoint([npc, watch]), UnitPoint(x: 0.675, y: 0.61))
        XCTAssertEqual(CloudLaunchPolicy.state([watch]), .unknown)
        XCTAssertEqual(CloudLaunchPolicy.state([line("点击进入", 0.45, 0.8)]), .gameEntry)
        XCTAssertEqual(CloudLaunchPolicy.state([line("游戏启动中，请耐心等待", 0.4, 0.5)]), .loading)
        XCTAssertNil(CloudLaunchPolicy.navigationPoint([f, npc, line("验证码", 0.5, 0.5)]))
    }

    func testFinishedReplayCanReturnToFavorites() {
        let exit = TextLine(text: "退出观看", x: 0.8, y: 0.9, width: 0.1, height: 0.03)
        let win = TextLine(text: "对局胜利", x: 0.4, y: 0.5, width: 0.2, height: 0.1)
        XCTAssertEqual(CloudLaunchPolicy.state([win, exit]), .replayEnd)
        XCTAssertEqual(CloudLaunchPolicy.navigationPoint([win, exit]), UnitPoint(x: 0.8500000000000001, y: 0.915))
        XCTAssertEqual(CloudLaunchPolicy.state([exit]), .unknown)
        XCTAssertEqual(CloudLaunchPolicy.state([win]), .unknown)
        var login = win; login.text = "验证码"
        XCTAssertEqual(CloudLaunchPolicy.state([win, exit, login]), .login)
    }

    func testAlreadyLoggedInWorldStartsKeepalive() {
        let uid = TextLine(text: "UID:" + String(repeating: "0", count: 9), x: 0.85, y: 0.93, width: 0.12, height: 0.02)
        XCTAssertEqual(CloudLaunchPolicy.state([uid]), .unknown)
        XCTAssertEqual(CloudLaunchPolicy.hasGameSession([uid]), true)
        var wrong = uid; wrong.text = "UID:abc"
        XCTAssertFalse(CloudLaunchPolicy.hasGameSession([wrong]))
        wrong = uid; wrong.y = 0.2
        XCTAssertFalse(CloudLaunchPolicy.hasGameSession([wrong]))
        wrong = uid; wrong.text = "验证码"
        XCTAssertFalse(CloudLaunchPolicy.hasGameSession([uid, wrong]))
    }

    func testPrinceGreetingMustAdvanceBeforeChoices() {
        func line(_ text: String, _ x: Double, _ y: Double, _ width: Double = 0.08) -> TextLine {
            TextLine(text: text, x: x, y: y, width: width, height: 0.025)
        }
        // Observed on Mini after the successful F key: dialogue waits here indefinitely.
        let speaker = line("「小王子」", 0.464, 0.762)
        let auto = line("自动", 0.055, 0.153)
        let speech = line("喵？「欸呀，怎么了，有什么能够帮助到你的地方吗？」", 0.30, 0.82, 0.42)
        XCTAssertEqual(CloudLaunchPolicy.state([speaker, auto, speech]), .princeGreeting)
        XCTAssertEqual(CloudLaunchPolicy.navigationPoint([speaker, auto, speech]), UnitPoint(x: 0.51, y: 0.8324999999999999))
        XCTAssertEqual(CloudLaunchPolicy.state([speaker, speech]), .unknown)
        XCTAssertEqual(CloudLaunchPolicy.state([auto, speech]), .unknown)
        XCTAssertEqual(CloudLaunchPolicy.state([line("小王子", 0.46, 0.28), auto, speech]), .unknown)
        XCTAssertEqual(CloudLaunchPolicy.state([speaker, auto]), .unknown)
        XCTAssertEqual(CloudLaunchPolicy.state([speaker, auto, speech, line("观看一下对局回放。", 0.65, 0.6, 0.2)]), .princeDialogue)
        XCTAssertEqual(CloudLaunchPolicy.state([speaker, auto, speech, line("验证码", 0.5, 0.5)]), .login)
    }

    func testPrincePromptSupportsMergedIconsAndLocalKey() {
        func line(_ text: String, _ x: Double, _ y: Double, _ width: Double = 0.08) -> TextLine {
            TextLine(text: text, x: x, y: y, width: width, height: 0.025)
        }
        let floating = line("「小王子」", 0.5, 0.28)
        let prompt = line("F ●「小王子」", 0.59, 0.58, 0.15)
        XCTAssertEqual(CloudLaunchPolicy.state([floating, prompt]), .prince)
        XCTAssertEqual(CloudLaunchPolicy.state([line("F▶", 0.58, 0.58, 0.03), line("[小王子]", 0.65, 0.58), floating, line("F", 0.9, 0.9)]), .prince)
        XCTAssertEqual(CloudLaunchPolicy.state([floating]), .unknown)
        XCTAssertEqual(CloudLaunchPolicy.state([line("F", 0.58, 0.7), line("小王子", 0.65, 0.58)]), .unknown)
        XCTAssertEqual(CloudLaunchPolicy.state([prompt, line("F小王子", 0.77, 0.58, 0.15)]), .unknown)
        XCTAssertEqual(CloudLaunchPolicy.state([line("F小王子查询", 0.59, 0.58, 0.15)]), .unknown)
        XCTAssertEqual(CloudLaunchPolicy.state([line("E小王子", 0.59, 0.58, 0.15)]), .unknown)
        XCTAssertEqual(CloudLaunchPolicy.state([prompt, line("验证码", 0.5, 0.5)]), .login)
    }

    func testPrinceChoiceIconsDoNotHideReplay() {
        // Actual Vision output from the reported menu crop, not hand-corrected text.
        let menu = [
            TextLine(text: "查询「牌手等级」。", x: 0.294, y: 0.304, width: 0.304, height: 0.044),
            TextLine(text: "进行「铸境研炼』挑战。", x: 0.329, y: 0.389, width: 0.336, height: 0.048),
            TextLine(text: "t/进行酒馆牌局挑战。", x: 0.284, y: 0.481, width: 0.336, height: 0.044),
            TextLine(text: "4 看看卡牌商店的商品。", x: 0.280, y: 0.567, width: 0.377, height: 0.044),
            TextLine(text: "口观看一下对局回放。", x: 0.273, y: 0.655, width: 0.346, height: 0.048),
            TextLine(text: "日 暂时有别的事⋯", x: 0.277, y: 0.747, width: 0.294, height: 0.044)
        ]
        XCTAssertEqual(CloudLaunchPolicy.state(menu), .princeDialogue)
        let point = CloudLaunchPolicy.navigationPoint(menu)!
        XCTAssertLessThan(abs(point.x - 0.446), 0.0001)
        XCTAssertLessThan(abs(point.y - 0.679), 0.0001)
        XCTAssertEqual(CloudLaunchPolicy.state([menu[4]]), .unknown)
        var unsafe = menu[4]; unsafe.text = "请观看一下对局回放。"
        XCTAssertNil(CloudLaunchPolicy.navigationPoint([menu[0], menu[2], unsafe]))
        unsafe = menu[4]; unsafe.x = .nan
        XCTAssertNil(CloudLaunchPolicy.navigationPoint([menu[0], menu[2], menu[3], unsafe]))
    }

    func testPrinceChoicesOverrideLingeringGreeting() {
        let greeting = [
            TextLine(text: "「小王子」", x: 0.464, y: 0.762, width: 0.08, height: 0.025),
            TextLine(text: "自动", x: 0.055, y: 0.153, width: 0.08, height: 0.025),
            TextLine(text: "喵？「欸呀，怎么了，有什么能够帮助到你的地方吗？」", x: 0.30, y: 0.82, width: 0.42, height: 0.025)
        ]
        let choices = [
            TextLine(text: "查询「牌手等级」。", x: 0.68, y: 0.38, width: 0.18, height: 0.025),
            TextLine(text: "看看卡牌商店的商品。", x: 0.68, y: 0.54, width: 0.22, height: 0.025)
        ]
        XCTAssertEqual(CloudLaunchPolicy.state(greeting + choices), .princeDialogue)
        XCTAssertNil(CloudLaunchPolicy.navigationPoint(greeting + choices))
        XCTAssertNil(CloudLaunchPolicy.confirmedPrinceReplayPoint(greeting + choices, greeting + choices))
        var unrelated = choices[1]; unrelated.x = 0.1
        XCTAssertEqual(CloudLaunchPolicy.state(greeting + [choices[0], unrelated]), .princeGreeting)
        XCTAssertEqual(CloudLaunchPolicy.state(greeting + choices + [TextLine(text: "验证码", x: 0.4, y: 0.4, width: 0.1, height: 0.03)]), .login)
    }

    func testPrinceReplayRequiresTwoStableUnambiguousFrames() {
        let speaker = TextLine(text: "「小王子」", x: 0.46, y: 0.76, width: 0.08, height: 0.025)
        let watch = TextLine(text: "口观看一下对局回放。", x: 0.68, y: 0.60, width: 0.20, height: 0.025)
        let first = [speaker, watch]
        var moved = watch; moved.y += 0.01
        XCTAssertEqual(CloudLaunchPolicy.confirmedPrinceReplayPoint(first, [speaker, moved]), CloudLaunchPolicy.navigationPoint([speaker, moved]))
        moved.y += 0.08
        XCTAssertNil(CloudLaunchPolicy.confirmedPrinceReplayPoint(first, [speaker, moved]))
        XCTAssertNil(CloudLaunchPolicy.confirmedPrinceReplayPoint(first, [speaker]))
        XCTAssertNil(CloudLaunchPolicy.confirmedPrinceReplayPoint(first, [speaker, watch, moved]))
    }

    func testRecentCounterIsNeverFavorites() {
        func line(_ text: String, _ x: Double, _ y: Double) -> TextLine {
            TextLine(text: text, x: x, y: y, width: 0.06, height: 0.02)
        }
        let counter = line("收藏对局 5/5", 0.8, 0.15), date = line("2000年2月3日 04:05", 0.4, 0.4)
        let heading = line("对局回放 / 最近对局", 0.1, 0.15)
        let q = line("Q", 0.43, 0.15), e = line("E", 0.57, 0.15)
        XCTAssertEqual(CloudLaunchPolicy.state([heading, counter, date, q, e]), .recentReplays)
        XCTAssertEqual(CloudLaunchPolicy.recentTabKeyPoint([heading, counter, date, q, e]), UnitPoint(x: 0.13, y: 0.16))
        XCTAssertEqual(CloudLaunchPolicy.recentTabKeyPoint([heading, counter, date]), UnitPoint(x: 0.13, y: 0.16))
        XCTAssertNil(CloudLaunchPolicy.recentTabKeyPoint([heading, line("最近对局", 0.3, 0.15)]))
        XCTAssertEqual(CloudLaunchPolicy.state([counter, date]), .unknown)
        XCTAssertEqual(CloudLaunchPolicy.state([line("对局回放 / 收藏对局", 0.1, 0.15), counter, date]), .favorites)
        let replay = Replay(id: 1, date: "2000-02-03_0405", mode: "匹配模式", left: [], right: [], play: UnitPoint(x: 0.9, y: 0.4))
        XCTAssertFalse(CloudLaunchPolicy.verified([heading, counter, date], [heading, counter, date], rows: [replay]))
    }

    func testLaunchPreservesDeliberateReplayChoices() {
        var old = Replay(id: 1, date: "2000-02-03_0405", mode: "匹配模式", left: ["correct", "b", "c"], right: ["d", "e", "f"], play: UnitPoint(x: 0.9, y: 0.4))
        var fresh = old; fresh.left[0] = "wrong"; fresh.play = UnitPoint(x: 0.8, y: 0.4)
        old.selected = false; old.manualCharacters = [true, false, false, false, false, false]
        let merged = CloudLaunchPolicy.restoringChoices([old], in: [fresh])!
        XCTAssertFalse(merged[0].selected)
        XCTAssertEqual(merged[0].left[0], "correct")
        XCTAssertEqual(merged[0].play, fresh.play)
        fresh.date = "2000-02-03_0406"
        XCTAssertNil(CloudLaunchPolicy.restoringChoices([old], in: [fresh]))
        XCTAssertNil(CloudLaunchPolicy.restoringChoices([old], in: [old, old]))
        old.selected = true; old.manualCharacters = nil
        XCTAssertEqual(CloudLaunchPolicy.restoringChoices([old], in: [fresh]), [fresh])
        XCTAssertEqual(CloudLaunchPolicy.restoringChoices([], in: [fresh]), [fresh])
    }

    func testCloudStartRequiresUniqueVisibleExactLabel() {
        func line(_ text: String, _ x: Double = 0.4, _ y: Double = 0.8) -> TextLine {
            TextLine(text: text, x: x, y: y, width: 0.2, height: 0.05)
        }
        let start = line("进入游戏")
        XCTAssertEqual(CloudLaunchPolicy.startPoint([start]), UnitPoint(x: 0.5, y: 0.8250000000000001))
        XCTAssertEqual(CloudLaunchPolicy.startPoint([line("进 入 游 戏")]), CloudLaunchPolicy.startPoint([start]))
        XCTAssertEqual(CloudLaunchPolicy.startPoint([start, start]), CloudLaunchPolicy.startPoint([start]))
        XCTAssertNil(CloudLaunchPolicy.startPoint([start, line("开始游戏", 0.1)]))
        XCTAssertNil(CloudLaunchPolicy.startPoint([start, line("验证码")]))
        XCTAssertNil(CloudLaunchPolicy.startPoint([line("充值后进入游戏")]))
        XCTAssertNil(CloudLaunchPolicy.startPoint([line("进入游戏", -0.1)]))
        XCTAssertNil(CloudLaunchPolicy.startPoint([line("进入游戏", 0.9)]))
        XCTAssertNil(CloudLaunchPolicy.startPoint([line("进入游戏", .nan)]))
        XCTAssertNil(CloudLaunchPolicy.startPoint([line("进入游戏", .infinity)]))
        XCTAssertNil(CloudLaunchPolicy.startPoint([line("开始游戏", 0.4, 1.1)]))
    }
    func testCloudAgreementOnlySelectsOfficialLegalCheckbox() {
        let legal = "已阅读并同意《米哈游用户协议》《米哈游隐私政策》"
        XCTAssertEqual(CloudAgreementPolicy.requiresConfirmation([legal]), true)
        XCTAssertFalse(CloudAgreementPolicy.requiresConfirmation(["密码登录", "账号"]))
        XCTAssertEqual(CloudAgreementPolicy.checkboxIndex(labels: [legal], pageLabels: [legal]), 0)
        XCTAssertEqual(CloudAgreementPolicy.checkboxIndex(labels: ["", legal], pageLabels: [legal]), 1)
        XCTAssertEqual(CloudAgreementPolicy.checkboxIndex(labels: [""], pageLabels: [legal]), 0)
        XCTAssertEqual(CloudAgreementPolicy.checkboxIndex(labels: ["已阅读并同意"], pageLabels: [legal]), 0)
        XCTAssertNil(CloudAgreementPolicy.checkboxIndex(labels: [legal, legal], pageLabels: [legal]))
        XCTAssertNil(CloudAgreementPolicy.checkboxIndex(labels: ["", ""], pageLabels: [legal]))
        XCTAssertNil(CloudAgreementPolicy.checkboxIndex(labels: ["同意营销通知"], pageLabels: [legal]))
        XCTAssertNil(CloudAgreementPolicy.checkboxIndex(labels: [legal + "并预约游戏消息通知"], pageLabels: [legal]))
        XCTAssertNil(CloudAgreementPolicy.checkboxIndex(labels: [""], pageLabels: [legal, "预约游戏消息通知"]))
        XCTAssertNil(CloudAgreementPolicy.checkboxIndex(labels: [""], pageLabels: ["同意其他服务协议"]))
        XCTAssertNil(CloudAgreementPolicy.checkboxIndex(labels: [legal], pageLabels: ["米哈游用户协议"]))
    }
    func testCloudLaunchRequiresOfficialPageAndStableFavorites() {
        XCTAssertEqual(CloudLaunchPolicy.allowed(URL(string: "https://ys.mihoyo.com/cloud/")!), true)
        XCTAssertEqual(CloudLaunchPolicy.loginFrameAllowed(URL(string: "https://user.mihoyo.com/")!), true)
        XCTAssertFalse(CloudLaunchPolicy.loginFrameAllowed(URL(string: "https://user.mihoyo.com.evil.example/")!))
        XCTAssertFalse(CloudLaunchPolicy.loginFrameAllowed(URL(string: "http://user.mihoyo.com/")!))
        for address in ["http://ys.mihoyo.com/cloud/", "https://ys.mihoyo.com.evil.example/cloud/", "https://ys.mihoyo.com/news/"] {
            XCTAssertFalse(CloudLaunchPolicy.allowed(URL(string: address)!))
        }
        func lines(_ values: [String]) -> [TextLine] { values.map { TextLine(text: $0, x: 0, y: 0.2, width: 0.2, height: 0.1) } }
        let first = lines(["收藏对局", "2000年2月3日 04:05"])
        var replay = Replay(id: 1, date: "2000-02-03_0405", mode: "匹配模式", left: [], right: [], play: UnitPoint(x: 0.9, y: 0.2))
        XCTAssertFalse(CloudLaunchPolicy.verified(first, first, rows: [replay]))
        replay.playDetected = true
        XCTAssertEqual(CloudLaunchPolicy.verified(first, first, rows: [replay]), true)
        XCTAssertFalse(CloudLaunchPolicy.verified(first, lines(["收藏对局", "2000年2月3日 04:06"]), rows: [replay]))
        XCTAssertFalse(CloudLaunchPolicy.verified(first, lines(["收藏对局", "验证码", "2000年2月3日 04:05"]), rows: [replay]))
        XCTAssertEqual(CloudLaunchPolicy.state(lines(["开始游戏"])), .launcher)
        XCTAssertEqual(CloudLaunchPolicy.state(lines(["验证码", "开始游戏"])), .login)
        XCTAssertEqual(CloudLaunchPolicy.state(lines(["七圣召唤"])), .unknown)
    }
    func testLegacyReplayAndManualCharacterProtection() throws {
        let legacy = Data(#"{"id":1,"selected":true,"date":"test","mode":"test","left":["a","b","c"],"right":["d","e","f"],"play":{"x":0.9,"y":0.2},"playDetected":true}"#.utf8)
        var replay = try JSONDecoder().decode(Replay.self, from: legacy)
        XCTAssertNil(replay.manualCharacters)
        replay.manualCharacters = [true,false,false,false,false,true]
        let restored = try JSONDecoder().decode(Replay.self, from: JSONEncoder().encode(replay))
        XCTAssertEqual(restored.manualCharacters, replay.manualCharacters)
    }
    func testSpeedCalibrationWinsAndUnknownCanContinue() {
        let manual = UnitPoint(x: 0.9, y: 0.9), other = UnitPoint(x: 0.75, y: 0.7)
        XCTAssertEqual(SpeedPolicy.action(detected: nil, calibrated: nil), .skip)
        XCTAssertEqual(SpeedPolicy.action(detected: nil, calibrated: manual), .click(manual))
        XCTAssertEqual(SpeedPolicy.action(detected: ReplaySpeedControl(point: other, multiplier: 1), calibrated: manual), .click(manual))
        XCTAssertEqual(SpeedPolicy.action(detected: ReplaySpeedControl(point: other, multiplier: 2), calibrated: manual), .click(manual))
        XCTAssertEqual(SpeedPolicy.action(detected: ReplaySpeedControl(point: manual, multiplier: 2), calibrated: manual), .alreadyDouble)
        XCTAssertEqual(SpeedPolicy.action(detected: ReplaySpeedControl(point: other, multiplier: 2), calibrated: nil), .alreadyDouble)
    }
    func testUpdateVersionsAndDigests() {
        XCTAssertLessThan(AppVersion("1.2.9")!, AppVersion("v1.2.10")!)
        XCTAssertEqual(AppVersion("v1.2.0"), AppVersion("1.2.0"))
        for value in ["1.2", "1.2.0-beta", "../1.2.0", "1.2.0;echo", "1.2.-1", "1.2.9999999999999999999999999"] { XCTAssertNil(AppVersion(value)) }
        XCTAssertEqual(UpdatePolicy.validDigest("sha256:" + String(repeating: "a", count: 64)), true)
        XCTAssertFalse(UpdatePolicy.validDigest("sha256:" + String(repeating: "g", count: 64)))
        XCTAssertFalse(UpdatePolicy.validDigest("sha256:abc"))
        for version in ["1.2.0", "1.3.0"] {
            XCTAssertEqual(UpdatePolicy.canOfferLegacyExitRecovery(version: version, launchedByOldApp: true), true)
            XCTAssertFalse(UpdatePolicy.canOfferLegacyExitRecovery(version: version, launchedByOldApp: false))
        }
        for version in ["1.1.3", "1.3.1", "invalid"] {
            XCTAssertFalse(UpdatePolicy.canOfferLegacyExitRecovery(version: version, launchedByOldApp: true))
        }
    }
    func testKeepAliveStartsAndStopsWithReplay() {
        var schedule = KeepAliveSchedule(interval: 60)
        XCTAssertFalse(schedule.takeDue(at: 1000))
        schedule.start(at: 1000)
        XCTAssertFalse(schedule.takeDue(at: 1059.99))
        XCTAssertEqual(schedule.takeDue(at: 1060), true)
        XCTAssertFalse(schedule.takeDue(at: 1060))
        schedule.stop()
        XCTAssertFalse(schedule.takeDue(at: 5000))
        schedule.start(at: 5000)
        XCTAssertFalse(schedule.takeDue(at: 5059))
        XCTAssertEqual(schedule.takeDue(at: 5060), true)
    }
    func testKeepAliveNeverBurstsAfterDelay() {
        var schedule = KeepAliveSchedule(interval: 15)
        schedule.start(at: 0)
        XCTAssertEqual(schedule.takeDue(at: 1000), true)
        XCTAssertFalse(schedule.takeDue(at: 1000))
        XCTAssertFalse(schedule.takeDue(at: 1014))
        XCTAssertEqual(schedule.takeDue(at: 1015), true)
    }
    func testKeepAliveIntervalsAreBounded() {
        for interval in [-1.0, 0, 14, 121, .infinity, .nan] {
            var schedule = KeepAliveSchedule(interval: interval)
            schedule.start(at: 0)
            XCTAssertFalse(schedule.takeDue(at: 59))
            XCTAssertEqual(schedule.takeDue(at: 60), true)
        }
        var schedule = KeepAliveSchedule(interval: 120)
        schedule.start(at: 0)
        XCTAssertFalse(schedule.takeDue(at: 119))
        XCTAssertEqual(schedule.takeDue(at: 120), true)
    }
    func testClickOcclusionRequiresEvidence() {
        XCTAssertEqual(ClickSafety.allows(targetInStack: true, hasObstruction: false, onlyDockOverlays: false, accessibilityHit: .unavailable), true)
        XCTAssertEqual(ClickSafety.allows(targetInStack: true, hasObstruction: true, onlyDockOverlays: true, accessibilityHit: .targetWindow), true)
        for hit in [AccessibilityClickHit.targetWindow, .otherWindow, .unavailable] {
            // Real HUDs, sheets, and other apps are never whitelisted by PID.
            XCTAssertFalse(ClickSafety.allows(targetInStack: true, hasObstruction: true, onlyDockOverlays: false, accessibilityHit: hit))
            XCTAssertFalse(ClickSafety.allows(targetInStack: false, hasObstruction: false, onlyDockOverlays: false, accessibilityHit: hit))
        }
        XCTAssertFalse(ClickSafety.allows(targetInStack: true, hasObstruction: true, onlyDockOverlays: true, accessibilityHit: .unavailable))
        XCTAssertFalse(ClickSafety.allows(targetInStack: true, hasObstruction: true, onlyDockOverlays: true, accessibilityHit: .otherWindow))
        XCTAssertFalse(ClickSafety.allows(targetInStack: true, hasObstruction: false, onlyDockOverlays: false, accessibilityHit: .otherWindow))
    }
    func testUnattendedDoesNotBypassSessionSafety() {
        XCTAssertNil(RecordingSafety.interruption(unlocked: true, targetExists: true, fullWindow: true, unattended: true, focusLostSeconds: 3600))
        XCTAssertFalse(RecordingSafety.interruption(unlocked: false, targetExists: true, fullWindow: true, unattended: true, focusLostSeconds: 0) == nil)
        XCTAssertFalse(RecordingSafety.interruption(unlocked: true, targetExists: false, fullWindow: true, unattended: true, focusLostSeconds: 0) == nil)
    }
    func testFocusGraceOnlyAppliesToWindowCapture() {
        XCTAssertNil(RecordingSafety.interruption(unlocked: true, targetExists: true, fullWindow: true, unattended: false, focusLostSeconds: 14))
        XCTAssertFalse(RecordingSafety.interruption(unlocked: true, targetExists: true, fullWindow: true, unattended: false, focusLostSeconds: 15) == nil)
        XCTAssertFalse(RecordingSafety.interruption(unlocked: true, targetExists: true, fullWindow: false, unattended: true, focusLostSeconds: 1) == nil)
    }
    func testSpeedOCRRejectsCardNumbersAndAmbiguity() {
        let double = TextLine(text: "2.0×", x: 0.9, y: 0.88, width: 0.05, height: 0.03)
        XCTAssertEqual(ReplayControls.speed(in: [double])?.multiplier, 2)
        XCTAssertNil(ReplayControls.speed(in: [double, double]))
        XCTAssertNil(ReplayControls.speed(in: [TextLine(text: "2", x: 0.9, y: 0.88, width: 0.02, height: 0.03)]))
        XCTAssertNil(ReplayControls.speed(in: [TextLine(text: "1x", x: 0.2, y: 0.3, width: 0.03, height: 0.02)]))
    }
    func testDisplayChoiceUsesLargestWindowIntersection() {
        let displays = [CGRect(x: 0, y: 0, width: 1512, height: 982), CGRect(x: -1920, y: -100, width: 1920, height: 1080)]
        XCTAssertEqual(RegionGeometry.displayIndex(window: CGRect(x: -1100, y: 50, width: 1200, height: 700), displays: displays), 1)
        XCTAssertEqual(RegionGeometry.displayIndex(window: CGRect(x: 100, y: 100, width: 1200, height: 700), displays: displays), 0)
        XCTAssertNil(RegionGeometry.displayIndex(window: CGRect(x: 4000, y: 0, width: 500, height: 500), displays: displays))
    }
    func testSelectionSupportsReverseDragAndClampsDisplayEdges() {
        let result = RegionGeometry.drag(from: CGPoint(x: 1800, y: 900), to: CGPoint(x: -30, y: -40), bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        XCTAssertEqual(result, CGRect(x: 0, y: 0, width: 1800, height: 900))
    }
    func testRetinaSelectionKeepsEntireNonWidescreenRegion() {
        let selection = CGRect(x: 120, y: 75, width: 1062, height: 768)
        let source = RegionGeometry.sourceRect(selection: selection, displaySize: CGSize(width: 1512, height: 982))
        XCTAssertEqual(source, CGRect(x: 120, y: 139, width: 1062, height: 768))
        let output = RegionGeometry.outputSize(rect: source, scale: 2)
        XCTAssertEqual(output.height, 1080)
        XCTAssertLessThan(abs(output.width / output.height - source.width / source.height), 0.002)
    }
    func testClickUsesSelectedDisplayOriginAndRegionRatherThanMainScreen() {
        XCTAssertEqual(RegionGeometry.screenPoint(UnitPoint(x: 0.5, y: 0.5), source: CGRect(x: 120, y: 80, width: 1000, height: 700), displayOrigin: CGPoint(x: -1920, y: 0)), CGPoint(x: -1300, y: 430))
    }
    func testChineseNamesStayUnderFilesystemByteLimit() {
        let name = Filename.safe(String(repeating: "圣骸牙兽", count: 50) + "/foo:bar")
        XCTAssertLessThanOrEqual(name.utf8.count, 220)
        XCTAssertFalse(name.contains("/"))
        XCTAssertFalse(name.contains(":"))
        XCTAssertFalse(name.contains("�"))
    }
    func testDateRecognizesSpacesAndFullwidthColon() {
        XCTAssertEqual(ReplayText.date("2000年2月3日 04：05"), "2000-02-03_0405")
        XCTAssertNil(ReplayText.date("2000年99月3日 04:05"))
        XCTAssertNil(ReplayText.date("热斗模式"))
    }
    func testDuplicateFilenamePreservesExistingTake() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = folder.appendingPathComponent("第1局.mp4")
        try Data("original".utf8).write(to: original)
        XCTAssertEqual(Filename.uniqueURL(directory: folder, stem: "第1局").lastPathComponent, "第1局_2.mp4")
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "original")
    }
}
