import Foundation
import ReplayCore

func checkReplayRecordingChoices() throws {
    let ids = [3, 1, 5, 2, 4]
    var cases = 0
    for encodedChoices in 0..<243 {
        var number = encodedChoices
        var rows = ids.map { id in
            Replay(id: id, date: "2000-01-01_0101", mode: "匹配模式",
                   left: [], right: [], play: UnitPoint(x: 0.9, y: 0.2))
        }
        for index in rows.indices {
            rows[index].recordingChoice = ReplayRecordingChoice.allCases[number % 3]
            number /= 3
        }
        for mask in 0..<32 {
            for index in rows.indices { rows[index].selected = mask & (1 << index) != 0 }
            let original = rows
            for globalBoth in [false, true] {
                let plan = ReplayRecordingPlan.jobs(rows: rows, bothPerspectives: globalBoth)
                let selected = rows.filter(\.selected).sorted { $0.id < $1.id }
                var expected: [(Int, ReplayPerspective)] = []
                if globalBoth || selected.contains(where: { $0.preferredRecordingChoice == .both }) {
                    for side in ReplayPerspective.allCases {
                        expected += selected.filter { globalBoth || $0.preferredRecordingChoice.includes(side) }
                            .map { ($0.id, side) }
                    }
                } else {
                    expected = selected.map { ($0.id, $0.preferredRecordingChoice == .opponent ? .opponent : .own) }
                }
                precondition(plan.count == expected.count)
                for (job, (id, side)) in zip(plan, expected) {
                    precondition(job.id == id && job.preferredPerspective == side)
                    precondition(job.recordingChoice == nil && job.confirmedPerspective == nil)
                    precondition(job.recordingOutcome == nil && job.perspectiveStatus == nil)
                    precondition(rows.contains { $0.id == job.id && $0.selected })
                }
                precondition(rows == original, "Planning must not overwrite manual choices")
                cases += 1
            }
        }
    }
    var legacy = Replay(id: 1, date: "old", mode: "old", left: [], right: [], play: .init(x: 0.9, y: 0.2))
    legacy.recordingPerspective = .opponent
    precondition(legacy.preferredRecordingChoice == .opponent)
    legacy.recordingChoice = .both
    let roundTrip = try JSONDecoder().decode(Replay.self, from: JSONEncoder().encode(legacy))
    precondition(roundTrip.preferredRecordingChoice == .both)
    let found = Replay(id: 1, date: "old", mode: "old", left: [], right: [], play: .init(x: 0.9, y: 0.2))
    let restored = CloudLaunchPolicy.restoringChoices([legacy], in: [found])
    precondition(restored?.first?.preferredRecordingChoice == .both)
    print("PASS: \(cases) exhaustive per-replay choice/selection/global-override plans and choice migration")
}
