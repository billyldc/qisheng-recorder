import Foundation
import ReplayCore

func checkInterruptionPolicies() {
    let dnd = SystemFocusState.doNotDisturb
    let off = SystemFocusState(activeID: nil)
    let work = SystemFocusState(activeID: "focus-mode-activity-test-work")
    let personal = SystemFocusState(activeID: "focus-mode-activity-test-personal")
    precondition(NotificationQuietLease(previous: .init(activeID: dnd)) == nil)
    for before in [off, work, personal] {
        let lease = NotificationQuietLease(previous: before)!
        precondition(lease.restoration(current: .init(activeID: dnd)) == .restore(before))
        for manual in [off, work, personal] {
            precondition(lease.restoration(current: manual) == .leaveUserChange)
        }
    }
    precondition(SystemFocusState.confirmed(rows: [(dnd, 0)]) == off)
    precondition(SystemFocusState.confirmed(rows: [(dnd, 1), ("focus-mode-activity-test-work", 0)]) == .init(activeID: dnd))
    precondition(SystemFocusState.confirmed(rows: []) == nil)
    precondition(SystemFocusState.confirmed(rows: [(dnd, 0), (dnd, 1)]) == nil)
    precondition(SystemFocusState.confirmed(rows: [(dnd, 1), ("focus-mode-activity-test-work", 1)]) == nil)
    for invalid in [-100, -1, 2, 100] {
        precondition(SystemFocusState.confirmed(rows: [(dnd, invalid)]) == nil)
    }
    func focusRow(_ id: String, _ y: Double, _ height: Double = 32, _ x: Double = 100) -> SystemFocusRow {
        .init(id: id, frame: CGRect(x: x, y: y, width: 270, height: height))
    }
    let expanded = [focusRow(dnd, 80), focusRow(dnd, 122, 22), focusRow(dnd, 144, 22), focusRow("work", 190)]
    precondition(SystemFocusRow.primaryIndices(expanded) == [0, 3])
    precondition(SystemFocusRow.primaryIndices([expanded[1], expanded[3], expanded[0], expanded[2]]) == [1, 2])
    precondition(SystemFocusRow.primaryIndices([expanded[0], expanded[0]]) == nil)
    precondition(SystemFocusRow.primaryIndices([expanded[0], focusRow(dnd, 90, 22)]) == nil)
    precondition(SystemFocusRow.primaryIndices([expanded[0], focusRow(dnd, 122, 22, 500)]) == nil)
    precondition(SystemFocusRow.primaryIndices([focusRow(dnd, .nan)]) == nil)

    var gate = AutomationReadiness()
    precondition(gate.observe(available: true, at: 0) == .waiting)
    precondition(gate.observe(available: true, at: 0) == .waiting)
    precondition(gate.observe(available: true, at: 0.25) == .readyForFreshEvidence)
    precondition(gate.observe(available: false, at: 1) == .waiting)
    precondition(gate.observe(available: true, at: 1.25) == .waiting)
    precondition(gate.observe(available: true, at: 10) == .needsAssistance, "A long gap is not stable evidence")
    precondition(gate.observe(available: true, at: 10.25) == .readyForFreshEvidence)
    precondition(gate.observe(available: true, at: .nan) == .needsAssistance)
    precondition(gate.observe(available: true, at: .infinity) == .needsAssistance)
    precondition(gate.observe(available: true, at: 9) == .needsAssistance)
    precondition(gate.observe(available: true, at: 11) == .needsAssistance)
    precondition(gate.observe(available: true, at: 11.3) == .readyForFreshEvidence)
    for length in [1, 5, 30, 120, 1200] {
        var interrupted = AutomationReadiness()
        for time in 0..<length {
            precondition(interrupted.observe(available: false, at: Double(time)) != .readyForFreshEvidence)
        }
        precondition(interrupted.observe(available: true, at: Double(length)) != .readyForFreshEvidence)
        precondition(interrupted.observe(available: true, at: Double(length) + 0.3) == .readyForFreshEvidence)
    }
    var entry = ReplayEntryGate(at: 0, grace: 12)
    precondition(entry.observe(listVisible: true, sameRow: true, playbackVisible: false, at: 0) == .wait)
    precondition(entry.observe(listVisible: true, sameRow: true, playbackVisible: false, at: 1) == .wait)
    let beforeUnsentClick = entry
    precondition(entry.observe(listVisible: true, sameRow: true, playbackVisible: false, at: 12) == .retry)
    entry = beforeUnsentClick
    entry.suspend(for: 100)
    precondition(entry.observe(listVisible: true, sameRow: true, playbackVisible: false, at: 112) == .retry)
    precondition(entry.observe(listVisible: false, sameRow: false, playbackVisible: true, at: 113) == .wait)
    precondition(entry.observe(listVisible: false, sameRow: false, playbackVisible: true, at: 114) == .entered)
    var delayed = ReplayEntryGate(at: 0, grace: 12)
    precondition(delayed.observe(listVisible: false, sameRow: false, playbackVisible: false, at: 80) == .failed)
    precondition(delayed.observe(listVisible: false, sameRow: false, playbackVisible: true, at: 90) == .failed)
    precondition(delayed.observe(listVisible: false, sameRow: false, playbackVisible: true, at: 91) == .entered)
    var slowVision = AutomationReadiness(maximumGap: 15)
    precondition(slowVision.observe(available: true, at: 0) == .waiting)
    precondition(slowVision.observe(available: true, at: 5) == .readyForFreshEvidence)

    for unattended in [false, true] {
        for lost in [0.0, 1, 15, 60, 3600] {
            precondition(RecordingSafety.interruption(unlocked: true, targetExists: true,
                fullWindow: true, unattended: unattended, focusLostSeconds: lost) == nil)
        }
        precondition(RecordingSafety.interruption(unlocked: false, targetExists: true,
            fullWindow: true, unattended: unattended, focusLostSeconds: 0) != nil)
        precondition(RecordingSafety.interruption(unlocked: true, targetExists: false,
            fullWindow: true, unattended: unattended, focusLostSeconds: 0) != nil)
    }
    for x in [-1920.0, 0, 1280] {
        for y in [-900.0, 0, 720] {
            let window = CGRect(x: x, y: y, width: 1200, height: 800)
            let selected = CGRect(x: x + 10, y: y + 20, width: 1170, height: 750)
            let cropped = RegionGeometry.validatedWindowCrop(selection: selected, window: window)
            precondition(cropped == CGRect(x: 10, y: 20, width: 1170, height: 750))
            precondition(RegionGeometry.validatedWindowCrop(selection: window, window: window) == CGRect(x: 0, y: 0, width: 1200, height: 800))
            precondition(RegionGeometry.validatedWindowCrop(selection: window.insetBy(dx: -1, dy: -1), window: window) == nil)
        }
    }
    print("PASS: interruption recovery, stale-evidence rejection, quiet ownership, lock safety and window-crop boundaries")
}
