import AppKit
import SwiftUI

@MainActor
func runCharacterLibrarySelfTest() {
    do {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("qisheng-gallery-test-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let base = root.appendingPathComponent("base"), extra = root.appendingPathComponent("extra")
        for folder in [base, extra] { try fm.createDirectory(at: folder.appendingPathComponent("portraits"), withIntermediateDirectories: true) }
        let a = "UI_Gcg_CardFace_Char_Avatar_TestA", b = "UI_Gcg_CardFace_Char_Avatar_TestB"
        let c = "UI_Gcg_CardFace_Char_Avatar_TestC"
        try JSONEncoder().encode([a: "内置角色", c: "缺失角色", "../escape": "非法条目"]).write(to: base.appendingPathComponent("names.json"))
        try JSONEncoder().encode([a: "损坏覆盖", b: "新增角色"]).write(to: extra.appendingPathComponent("names.json"))
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 128, pixelsHigh: 200,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let png = bitmap.representation(using: .png, properties: [:])!
        try png.write(to: base.appendingPathComponent("portraits/\(a).png"))
        try png.write(to: extra.appendingPathComponent("portraits/\(b).png"))
        try Data("broken".utf8).write(to: extra.appendingPathComponent("portraits/\(a).png"))
        let entries = try CharacterLibrary.load(bundled: base, extra: extra)
        precondition(entries.count == 3)
        precondition(entries.first { $0.id == a }?.name == "内置角色")
        precondition(entries.first { $0.id == b }?.downloaded == true)
        precondition(entries.first { $0.id == c }?.imageURL == nil)
        try png.write(to: extra.appendingPathComponent("portraits/\(a).png"))
        let replaced = try CharacterLibrary.load(bundled: base, extra: extra)
        precondition(replaced.count == 3 && replaced.first { $0.id == a }?.downloaded == true)
        let resources = ProcessInfo.processInfo.environment["QISHENG_TEST_ASSETS"].map { URL(fileURLWithPath: $0) }
            ?? Bundle.main.resourceURL!.appendingPathComponent("Assets")
        let real = try CharacterLibrary.load(bundled: resources, extra: root.appendingPathComponent("none"))
        precondition(!real.isEmpty && real.allSatisfy { $0.imageURL != nil })
        let model = AppModel(persistent: false)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 700),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "角色库预览（测试）"
        window.contentView = NSHostingView(rootView: CharacterLibraryView(model: model, bundled: resources, extra: root.appendingPathComponent("none")))
        window.makeKeyAndOrderFront(nil)
        print("PASS: gallery merge, missing/corrupt images, path validation and \(real.count) bundled images")
        if CommandLine.arguments.contains("--interactive-preview") { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            let view = window.contentView!
            view.layoutSubtreeIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/qisheng-gallery-selftest.png"))
            window.orderOut(nil)
            NSApp.terminate(nil)
        }
    } catch { fputs("Gallery self-test failed: \(error)\n", stderr); exit(1) }
}
