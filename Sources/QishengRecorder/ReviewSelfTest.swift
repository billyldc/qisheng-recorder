import AppKit
import SwiftUI

@MainActor
func runReviewSelfTest() {
    do {
        let settings = try JSONDecoder().decode(Settings.self, from: Data("{}".utf8))
        precondition(settings.autoReview && !settings.autoAssetUpdates)
        let names = ["诺艾尔", "嘉明", "阿贝多", "伊涅芙", "哥伦比娅", "菲林斯"]
        let slots = names.map { ReviewSlot(value: $0, initial: "未识别", manual: false,
                                           state: "confirmed", candidates: []) }
        let review = VideoReview(schemaVersion: 1, videoSHA256: String(repeating: "0", count: 64),
                                 slots: slots, frames: [], perspectiveOverride: "auto",
                                 assetVersion: "test", missing: [], status: "reviewed")
        let decoded = try JSONDecoder().decode(VideoReview.self, from: JSONEncoder().encode(review))
        precondition(decoded.slots.count == 6 && decoded.slots[4].value == "哥伦比娅")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 720),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: VideoReviewEditor(video: URL(fileURLWithPath: "/tmp/review-test.mp4"),
                                                                     review: decoded, rerun: {}))
        window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            let view = window.contentView!
            view.layoutSubtreeIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds),
                  let _ = view.window else { exit(1) }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/qisheng-review-selftest.png"))
            print("PASS: review settings migration, report round-trip, editor layout")
            window.orderOut(nil)
            NSApp.terminate(nil)
        }
    } catch { fputs("Review self-test failed: \(error)\n", stderr); exit(1) }
}
