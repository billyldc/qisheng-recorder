import AppKit
import ReplayCore

struct CaptureRegion {
    let displayID: CGDirectDisplayID
    let displaySize: CGSize
    let sourceRect: CGRect
    let scale: CGFloat
    var windowID: CGWindowID? = nil
    var anchorWindowID: CGWindowID? = nil
    var anchorFrame: CGRect? = nil
    var anchorOwnerPID: pid_t? = nil
    var windowCrop: CGRect? = nil
    var globalRect: CGRect {
        sourceRect.offsetBy(dx: CGDisplayBounds(displayID).minX, dy: CGDisplayBounds(displayID).minY)
    }

    func resolved() throws -> CaptureRegion {
        guard let anchorWindowID, let anchorFrame,
              let window = CaptureWindow.list(pid: anchorOwnerPID).first(where: { $0.id == anchorWindowID }) else {
            throw RecorderError.message("目标窗口已关闭，请重新选取画面。")
        }
        if windowID != nil {
            guard abs(window.frame.width - anchorFrame.width) < 2, abs(window.frame.height - anchorFrame.height) < 2 else {
                throw RecorderError.message("目标窗口尺寸已改变，已停止点击。请重新选择窗口并识别收藏列表。")
            }
            return try window.region(crop: windowCrop)
        }
        guard window.frame == anchorFrame, NSScreen.screens.contains(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }) else { throw RecorderError.message("选框对应的窗口或显示器已移动，请重新选框。") }
        return self
    }
}

private final class SelectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class RegionSelector {
    private var panels: [NSPanel] = []
    private var completion: ((CaptureRegion?) -> Void)?

    func pickPoint(region: CaptureRegion, title: String, completion: @escaping (UnitPoint?) -> Void) {
        cancel()
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == region.displayID
        }) else { completion(nil); return }
        let panel = SelectionPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.hidesOnDeactivate = false
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let view = SelectionView(frame: CGRect(origin: .zero, size: screen.frame.size))
        view.pointOnly = true
        view.title = title + " · 单击目标 · Esc 取消"
        view.done = { [weak self] rect in
            self?.finish(nil)
            guard let rect else { completion(nil); return }
            let p = CGPoint(x: rect.minX, y: screen.frame.height - rect.minY)
            guard region.sourceRect.contains(p) else { completion(nil); return }
            completion(UnitPoint(x: (p.x - region.sourceRect.minX) / region.sourceRect.width,
                                 y: (p.y - region.sourceRect.minY) / region.sourceRect.height))
        }
        panel.contentView = view
        panels = [panel]
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(view)
    }

    func select(displayID: CGDirectDisplayID, completion: @escaping (CaptureRegion?) -> Void) {
        cancel()
        self.completion = completion
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }) else { finish(nil); return }
        do {
            let panel = SelectionPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.hidesOnDeactivate = false
            panel.level = .screenSaver
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isReleasedWhenClosed = false
            let view = SelectionView(frame: CGRect(origin: .zero, size: screen.frame.size))
            view.done = { [weak self] rect in
                self?.finish(rect.map {
                    CaptureRegion(displayID: displayID, displaySize: screen.frame.size,
                                  sourceRect: RegionGeometry.sourceRect(selection: $0, displaySize: screen.frame.size),
                                  scale: screen.backingScaleFactor)
                })
            }
            panel.contentView = view
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(view)
            panels.append(panel)
        }
    }

    func cancel() { finish(nil) }
    private func finish(_ region: CaptureRegion?) {
        let callback = completion
        completion = nil
        for panel in panels { panel.orderOut(nil); panel.close() }
        panels.removeAll()
        callback?(region)
    }
}

// AppKit owns the whole drag sequence (mouseDown/mouseDragged/mouseUp), as in
// native screenshot editors. No event tap or accessibility grant is needed.
final class SelectionView: NSView {
    var done: ((CGRect?) -> Void)?
    var pointOnly = false
    var title = "拖出完整游戏区域 · 回车确认 · 重新拖动可重选 · Esc 取消"
    private var anchor: CGPoint?
    private(set) var selected: CGRect?
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func mouseDown(with event: NSEvent) {
        anchor = convert(event.locationInWindow, from: nil)
        selected = nil
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard let anchor else { return }
        selected = RegionGeometry.drag(from: anchor, to: convert(event.locationInWindow, from: nil), bounds: bounds)
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        if pointOnly {
            done?(CGRect(origin: convert(event.locationInWindow, from: nil), size: CGSize(width: 1, height: 1)))
            return
        }
        mouseDragged(with: event)
        anchor = nil
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { done?(nil) }
        if event.keyCode == 36 || event.keyCode == 76, let selected, selected.width >= 160, selected.height >= 90 {
            done?(selected)
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.38).setFill()
        bounds.fill()
        if let selected {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.compositingOperation = .clear
            selected.fill()
            NSGraphicsContext.restoreGraphicsState()
            NSColor.systemCyan.setStroke()
            let path = NSBezierPath(rect: selected.insetBy(dx: 1, dy: 1))
            path.lineWidth = 2
            path.stroke()
            let label = "\(Int(selected.width)) × \(Int(selected.height))"
            drawLabel(label, at: CGPoint(x: selected.minX + 8, y: max(10, selected.minY - 28)))
        }
        drawLabel(title, at: CGPoint(x: 24, y: bounds.height - 52))
    }
    private func drawLabel(_ text: String, at point: CGPoint) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 17, weight: .medium), .foregroundColor: NSColor.white]
        let size = (text as NSString).size(withAttributes: attrs)
        NSColor.black.withAlphaComponent(0.82).setFill()
        NSBezierPath(roundedRect: CGRect(x: point.x - 8, y: point.y - 5, width: size.width + 16, height: size.height + 10), xRadius: 5, yRadius: 5).fill()
        (text as NSString).draw(at: point, withAttributes: attrs)
    }
}
