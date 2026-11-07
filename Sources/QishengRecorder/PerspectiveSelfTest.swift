import AppKit
import SwiftUI
import ReplayCore

@MainActor
func runPerspectiveSelfTest() {
    Task {
        do {
            let resources = ProcessInfo.processInfo.environment["QISHENG_TEST_RESOURCES"].map {
                URL(fileURLWithPath: $0, isDirectory: true)
            } ?? Bundle.main.resourceURL!
            if let directory = ProcessInfo.processInfo.environment["QISHENG_PERSPECTIVE_FIXTURES"] {
                let sequenceURL = URL(fileURLWithPath: directory).appendingPathComponent("sequence.json")
                if FileManager.default.fileExists(atPath: sequenceURL.path) {
                    try checkPerspectiveSequence(at: sequenceURL, resources: resources)
                    NSApp.terminate(nil)
                    return
                }
                func load(_ name: String) throws -> CGImage {
                    guard let image = NSImage(contentsOfFile: directory + "/" + name)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                        throw RecorderError.message("Missing perspective fixture")
                    }
                    return image
                }
                let menu = try load("menu.png"), paused = try load("paused.png")
                guard try ReplayPerspectiveMenu.detect(Metadata.text(in: menu))?.labelTarget == .opponent else {
                    throw RecorderError.message("Real replay menu OCR did not identify the safe switch entry")
                }
                let playing = try Metadata.playback(image: menu, resources: resources)
                let stopped = try Metadata.playback(image: paused, resources: resources)
                guard playing.gear != nil, playing.playback?.state == .running,
                      stopped.gear != nil, stopped.playback?.state == .paused else {
                    throw RecorderError.message("Bundled worker did not recognize real replay controls")
                }
                print("PASS: real replay menu OCR, matched settings icon, running and paused playback controls; no live game input")
            } else {
                throw RecorderError.message("Provide a private fixture directory for this offline check")
            }
            NSApp.terminate(nil)
        } catch { fputs("Perspective self-test failed: \(error)\n", stderr); exit(1) }
    }
}

private struct PerspectiveFixtureSequence: Decodable {
    var desired: ReplayPerspective
    var requireFinished: Bool
    var referenceImage: String?
    var referenceFavorites: FavoriteReference?
    var frames: [Frame]
    struct FavoriteReference: Decodable {
        var lines: [TextLine]
        var date: String
        var play: ReplayCore.UnitPoint
    }
    struct Frame: Decodable {
        var image: String
        var at: Double
        var action: String
        var playback: String
        var menu: String
        var confirmed: String?
        var headers: String?
    }
}

/// Replays captured frames through the same OCR, worker and coordinator used by
/// AppModel. It reports intended actions but never captures or sends game input.
private func checkPerspectiveSequence(at url: URL, resources: URL) throws {
    let fixture = try JSONDecoder().decode(PerspectiveFixtureSequence.self, from: Data(contentsOf: url))
    guard !fixture.frames.isEmpty else { throw RecorderError.message("Empty perspective sequence") }
    var reference: ReplayPlayerHeaders?
    if let name = fixture.referenceImage {
        let path = url.deletingLastPathComponent().appendingPathComponent(name).path
        guard let image = NSImage(contentsOfFile: path)?.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let headers = ReplayPlayerHeaders.detect(try Metadata.text(in: image)) else {
            throw RecorderError.message("Cannot read the fixture's known own-view reference")
        }
        reference = headers
    } else if let fixtureReference = fixture.referenceFavorites {
        guard let headers = ReplayPlayerHeaders.fromFavorites(fixtureReference.lines, date: fixtureReference.date, play: fixtureReference.play) else {
            throw RecorderError.message("Cannot read the fixture's favorites orientation reference")
        }
        reference = headers
    }
    var flow = ReplayPerspectiveFlow(desired: fixture.desired, originalHeaders: reference)
    var previousTime = -Double.infinity
    var finished = false
    var confirmedRunning = false
    for frame in fixture.frames {
        guard frame.at.isFinite, frame.at > previousTime else {
            throw RecorderError.message("Perspective frame times must increase")
        }
        previousTime = frame.at
        let imageURL = url.deletingLastPathComponent().appendingPathComponent(frame.image)
        guard let image = NSImage(contentsOf: imageURL)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw RecorderError.message("Missing perspective frame: \(frame.image)")
        }
        let lines = try Metadata.text(in: image)
        let controls = try Metadata.playback(image: image, resources: resources)
        let menu = ReplayPerspectiveMenu.detect(lines)?.labelTarget.rawValue ??
            (ReplayPerspectiveMenu.isOpen(lines) ? "unavailable" : "closed")
        let playback = controls.playback?.state.rawValue ?? "unknown"
        let headers = ReplayPlayerHeaders.detect(lines, matching: reference)
        let orientation: String
        if let reference, headers == reference { orientation = "own" }
        else if let reference, headers == reference.swapped { orientation = "opponent" }
        else { orientation = "unknown" }
        let decision = flow.observe(lines: lines, controls: controls, at: frame.at)
        let action: String
        switch decision {
        case .wait: action = "wait"
        case .pause: action = "pause"
        case .openMenu: action = "openMenu"
        case .closeMenu: action = "closeMenu"
        case .switchView: action = "switchView"
        case .resume: action = "resume"
        case .finished:
            action = "finished"; finished = true
            confirmedRunning = flow.confirmedPerspective == fixture.desired && playback == "running" && menu == "closed"
        }
        let confirmed = flow.confirmedPerspective?.rawValue ?? "unknown"
        let trace: [String: Any] = ["at": frame.at, "image": frame.image, "menu": menu,
                                  "playback": playback, "action": action, "confirmed": confirmed, "headers": orientation]
        print(String(data: try JSONSerialization.data(withJSONObject: trace, options: [.sortedKeys]), encoding: .utf8)!)
        guard menu == frame.menu, playback == frame.playback, action == frame.action,
              (frame.confirmed == nil || frame.confirmed == confirmed),
              (frame.headers == nil || frame.headers == orientation) else {
            throw RecorderError.message("Perspective sequence mismatch at \(frame.image): expected \(frame.menu)/\(frame.playback)/\(frame.action)")
        }
    }
    guard !fixture.requireFinished || confirmedRunning else {
        throw RecorderError.message("Sequence did not reach confirmed, running opponent view")
    }
    let outcome = confirmedRunning ? "confirmed running flow" : (finished ? "unverified running flow" : "partial regression trace")
    print("PASS: \(fixture.frames.count) real-image perspective sequence frames; \(outcome); no live game input")
}

@MainActor
func runViewsUISelfTest() {
    let model = AppModel(persistent: false)
    model.screenAllowed = true; model.accessibilityAllowed = true
    model.settings.captureMode = .window
    model.settings.unattended = true
    model.rows = (1...5).map { index in
        var row = Replay(id: index, date: "2000-02-03_0405", mode: "匹配模式",
                         left: ["诺艾尔", "嘉明", "阿贝多"], right: ["菲林斯", "哥伦比娅", "伊涅芙"],
                         play: UnitPoint(x: 0.94, y: Double(index) * 0.15))
        row.playDetected = true
        return row
    }
    model.status = "本地界面检查，不连接账号或操作游戏。"
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1120, height: 850),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.title = "录制视角与保活 · 界面检查"
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(rootView: MainView(model: model, initialTab: "record"))
    model.mainWindow = window
    model.showWindow()
}
