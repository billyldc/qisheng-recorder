import AppKit
import ReplayCore

@MainActor
enum GameCaptureRegion {
    static func prepare(_ selected: CaptureRegion, recorder: ScreenRecorder) async throws -> CaptureRegion {
        guard selected.windowID != nil,
              let window = CaptureWindow.list(pid: selected.anchorOwnerPID).first(where: { $0.id == selected.windowID }) else {
            return try selected.resolved()
        }
        let browser = NSRunningApplication(processIdentifier: window.ownerPID)?.bundleIdentifier
        let isBrowser = ["com.apple.Safari", "com.google.Chrome"].contains(browser ?? "")
        let page: CGRect
        if isBrowser {
            guard let content = SafariLauncher.cloudContentRect(window) else {
                throw RecorderError.message("未能确认浏览器内的游戏区域，尚未开始录制。请切到官方云原神收藏列表，或改用手动选框；不会把工具栏当作游戏录入。")
            }
            page = content
        } else { page = CGRect(origin: .zero, size: window.frame.size) }
        let pageRegion = try window.region(crop: page)
        var candidates: [CGRect?] = []
        var size = CGSize.zero
        for _ in 0..<3 {
            try Task.checkCancellation()
            let image = try await recorder.screenshot(region: pageRegion.resolved())
            let nextSize = CGSize(width: image.width, height: image.height)
            if size != .zero && nextSize != size { throw RecorderError.message("检测期间窗口尺寸发生变化，请重新选择。") }
            size = nextSize
            let rgba = GameViewport.rgba(image)
            candidates.append(rgba.flatMap { GameViewport.blackBorderBounds(rgba: $0, width: image.width, height: image.height) })
            try await Task.sleep(for: .milliseconds(350))
        }
        guard let pixels = GameViewport.stableBounds(candidates, size: size) else {
            // The document boundary is authoritative; uncertain image edges are kept.
            return pageRegion
        }
        let crop = GameViewport.pointRect(pixelRect: pixels, imageSize: size, source: page)
        return try window.region(crop: crop)
    }
}
