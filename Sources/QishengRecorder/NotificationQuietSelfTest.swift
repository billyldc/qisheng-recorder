import AppKit
import ReplayCore

@MainActor
private final class FakeRecordingFocus: RecordingFocusBackend {
    var state = SystemFocusState(activeID: nil)
    var writes: [SystemFocusState] = []
    var failRead = false
    var failBeforeChange = false
    var cancelAfterChange = false
    var failRestore = false
    func read() async throws -> SystemFocusState {
        if failRead { throw RecorderError.message("Synthetic unavailable Control Center") }
        return state
    }
    func set(_ desired: SystemFocusState, expecting previous: SystemFocusState) async throws {
        guard !failBeforeChange, state == previous else { throw RecorderError.message("Synthetic state conflict") }
        if failRestore && desired.activeID != SystemFocusState.doNotDisturb { throw RecorderError.message("Synthetic restore failure") }
        state = desired; writes.append(desired)
        if cancelAfterChange { cancelAfterChange = false; throw CancellationError() }
    }
}

@MainActor
func runNotificationQuietSelfTest() {
    Task {
        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("qisheng-quiet-test-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            let journal = directory.appendingPathComponent("focus.json")
            let fake = FakeRecordingFocus()
            let quiet = NotificationQuietSession(backend: fake, journal: journal)
            let dnd = SystemFocusState(activeID: SystemFocusState.doNotDisturb)
            _ = await quiet.begin()
            precondition(quiet.needsCleanup && fake.state == dnd)
            _ = await quiet.begin()
            precondition(fake.writes.count == 1, "Repeated begin must not overwrite the original state")
            _ = await quiet.end()
            precondition(fake.state.activeID == nil && !quiet.canRecover)
            precondition(!FileManager.default.fileExists(atPath: journal.path))
            _ = await quiet.end()
            precondition(fake.writes.count == 2)

            fake.state = dnd; fake.writes = []
            _ = await quiet.begin(); _ = await quiet.end()
            precondition(fake.state == dnd && fake.writes.isEmpty)
            let work = SystemFocusState(activeID: "focus-mode-activity-test-work")
            fake.state = work
            _ = await quiet.begin(); _ = await quiet.end()
            precondition(fake.state == work)
            precondition(fake.writes.isEmpty, "Do not replace an existing focus and its schedule")

            fake.state = .init(activeID: nil)
            _ = await quiet.begin()
            fake.state = work
            _ = await quiet.end()
            precondition(fake.state == work && !quiet.canRecover, "Never override a manual focus change")

            fake.state = .init(activeID: nil); fake.failBeforeChange = true
            _ = await quiet.begin()
            precondition(fake.state.activeID == nil)
            fake.failBeforeChange = false
            _ = await quiet.end()
            precondition(!quiet.canRecover)

            fake.cancelAfterChange = true
            _ = await quiet.begin()
            precondition(fake.state == dnd && quiet.needsCleanup)
            _ = await quiet.end()
            precondition(fake.state.activeID == nil && !quiet.canRecover)

            _ = await quiet.begin()
            fake.failRestore = true
            _ = await quiet.end()
            precondition(quiet.canRecover && !quiet.needsCleanup)
            let reopened = NotificationQuietSession(backend: fake, journal: journal)
            precondition(reopened.canRecover)
            let writes = fake.writes.count
            _ = await reopened.begin()
            precondition(fake.writes.count == writes, "A crash journal requires deliberate recovery")
            fake.failRestore = false
            _ = await reopened.end(recoverPreviousSession: true)
            precondition(fake.state.activeID == nil && !reopened.canRecover)

            fake.failRead = true
            _ = await reopened.begin()
            precondition(!reopened.needsCleanup && fake.state.activeID == nil)
            fake.failRead = false
            let broken = Data("not valid JSON".utf8)
            try broken.write(to: journal)
            let corrupt = NotificationQuietSession(backend: fake, journal: journal)
            let beforeCorrupt = fake.writes.count
            _ = await corrupt.begin()
            precondition(corrupt.canRecover && fake.writes.count == beforeCorrupt)
            let preserved = try Data(contentsOf: journal)
            precondition(preserved == broken)
            fake.state = dnd
            _ = await corrupt.end(recoverPreviousSession: true)
            precondition(corrupt.canRecover && fake.writes.count == beforeCorrupt)
            fake.state = .init(activeID: nil) // Simulate the user restoring it in Control Center.
            _ = await corrupt.end(recoverPreviousSession: true)
            precondition(!corrupt.canRecover && fake.writes.count == beforeCorrupt)
            let legacy = try JSONDecoder().decode(Settings.self, from: Data("{}".utf8))
            precondition(legacy.quietNotifications)
            print("PASS: quiet lifecycle, original focus, cancellation-after-apply, manual change, crash recovery, failure isolation and settings migration; no system settings changed")
            NSApp.terminate(nil)
        } catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
    }
}
