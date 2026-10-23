import AppKit
import SwiftUI

private final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class RecordingHUD {
    private var panel: NSPanel?
    func show(model: AppModel, displayID: UInt32) {
        if let panel { panel.orderFrontRegardless(); return }
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1000, height: 700)
        let width = min(380.0, visible.width - 24)
        let frame = CGRect(x: visible.minX + 12, y: visible.minY + 12, width: width, height: 238)
        let panel = HUDPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.contentView = NSHostingView(rootView: RecordingHUDView(model: model))
        self.panel = panel
        panel.orderFrontRegardless()
    }
    func hideForClick() async throws {
        guard let panel else { return }
        panel.ignoresMouseEvents = true
        panel.orderOut(nil)
        // orderOut is not a WindowServer synchronization barrier.
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(50))
            let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
            if !windows.contains(where: { ($0[kCGWindowNumber as String] as? Int) == panel.windowNumber }) { return }
        }
        throw RecorderError.message("录制悬浮窗未能及时隐藏，已停止点击。")
    }
    func restore() { panel?.ignoresMouseEvents = false; panel?.orderFrontRegardless() }
    func close() { panel?.orderOut(nil); panel?.close(); panel = nil }
}

private struct RecordingHUDView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "record.circle.fill").foregroundStyle(model.recording ? .red : .orange)
                Text(model.keepAliveOnly ? "只保活" : model.activeRow.map { "第 \($0) 局 · \(model.activePerspective?.label ?? "")" } ?? "七圣召唤录制器").font(.headline)
                Spacer()
                Text(String(format: "%02d:%02d", model.elapsed / 60, model.elapsed % 60)).monospacedDigit()
            }
            Text(model.status).font(.callout).lineLimit(3).frame(height: 48, alignment: .topLeading)
            Divider()
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(model.log.suffix(3).enumerated()), id: \.offset) { _, entry in
                    Text(entry).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }.frame(height: 49, alignment: .topLeading)
            HStack {
                Label(model.keepAliveOnly ? "未录制" : "不进入录像", systemImage: "eye.slash").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if model.keepAliveOnly || (model.settings.cloudKeepAlive && model.activeRow != nil) {
                    Text("保活 \(model.keepAliveCount) 次").font(.caption).monospacedDigit()
                }
                Button(action: model.stop) {
                    Label(model.keepAliveOnly ? "停止保活" : "停止并保存", systemImage: "stop.fill")
                        .font(.callout.weight(.semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 10).frame(height: 30)
                        .background(model.stopping ? Color.secondary : Color.red, in: RoundedRectangle(cornerRadius: 6))
                }.buttonStyle(.plain).disabled(model.stopping)
                    .help("立即停止自动操作并保存当前视频。Cmd+Shift+S")
            }
        }.padding(14).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.35)))
            .environment(\.controlActiveState, .active)
    }
}
