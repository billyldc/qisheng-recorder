import AVFoundation
import AppKit
import ReplayCore

enum GameVideoExport {
    static func export(_ source: URL, to output: URL, normalized: CGRect) async throws {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw RecorderError.message("原录像缺少视频轨道，未裁切。")
        }
        let size = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        guard transform.isIdentity, CGRect(x: 0, y: 0, width: 1, height: 1).contains(normalized),
              normalized.width > 0, normalized.height > 0 else {
            throw RecorderError.message("录像方向或裁切范围不符合本次捕获，原片保留。")
        }
        let rect = GameViewport.evenPixelBounds(normalized: normalized, size: size)
        guard rect.width >= 160, rect.height >= 90 else { throw RecorderError.message("裁切范围过小，原片保留。") }
        let duration = try await asset.load(.duration)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layer.setTransform(CGAffineTransform(translationX: -rect.minX, y: -rect.minY), at: .zero)
        instruction.layerInstructions = [layer]
        let composition = AVMutableVideoComposition()
        composition.instructions = [instruction]
        composition.renderSize = rect.size
        composition.frameDuration = CMTime(value: 1, timescale: 30)
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw RecorderError.message("无法创建游戏画面导出器，原片保留。")
        }
        exporter.videoComposition = composition
        let watchdog = Task {
            try await Task.sleep(for: .seconds(900))
            exporter.cancelExport()
        }
        defer { watchdog.cancel() }
        try await exporter.export(to: output, as: .mp4)
        let result = AVURLAsset(url: output)
        let outputDuration = try await result.load(.duration).seconds
        let audioCount = try await asset.loadTracks(withMediaType: .audio).count
        let outputAudioCount = try await result.loadTracks(withMediaType: .audio).count
        guard let outputTrack = try await result.loadTracks(withMediaType: .video).first,
              try await outputTrack.load(.naturalSize) == rect.size,
              abs(outputDuration - duration.seconds) < 0.25, audioCount == outputAudioCount else {
            throw RecorderError.message("裁切成片的尺寸、时长或音轨未通过校验，原片保留。")
        }
    }

    static func cropPreservingOriginal(_ source: URL, normalized: CGRect) async throws {
        if normalized == CGRect(x: 0, y: 0, width: 1, height: 1) { return }
        let manager = FileManager.default
        let temporary = source.deletingLastPathComponent().appendingPathComponent(".crop-\(UUID().uuidString).mp4")
        defer { try? manager.removeItem(at: temporary) }
        do { try await export(source, to: temporary, normalized: normalized) }
        catch { throw RecorderError.message("游戏画面裁切失败，未裁切原片仍保留在输出目录：\(error.localizedDescription)") }
        let originals = source.deletingLastPathComponent().appendingPathComponent("原始窗口", isDirectory: true)
        try manager.createDirectory(at: originals, withIntermediateDirectories: true)
        let backup = Filename.uniqueURL(directory: originals, stem: source.deletingPathExtension().lastPathComponent)
        try manager.moveItem(at: source, to: backup)
        do { try manager.moveItem(at: temporary, to: source) }
        catch {
            try? manager.moveItem(at: backup, to: source)
            throw RecorderError.message("无法保存裁切结果；原片保留在输出目录或「原始窗口」子目录。")
        }
    }
}

@MainActor
func runCropExportSelfTest() {
    Task {
        do {
            let arguments = CommandLine.arguments
            guard let index = arguments.firstIndex(of: "--crop-export-self-test"), arguments.count == index + 7,
                  let x = Double(arguments[index + 3]), let y = Double(arguments[index + 4]),
                  let width = Double(arguments[index + 5]), let height = Double(arguments[index + 6]) else {
                throw RecorderError.message("Usage: --crop-export-self-test source output x y width height (normalized)")
            }
            let source = URL(fileURLWithPath: arguments[index + 1])
            let normalized = CGRect(x: x, y: y, width: width, height: height)
            try await GameVideoExport.export(source, to: URL(fileURLWithPath: arguments[index + 2]), normalized: normalized)
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("Qisheng-CropCheck-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: scratch) }
            let copy = scratch.appendingPathComponent("fixture.mp4")
            try FileManager.default.copyItem(at: source, to: copy)
            try await GameVideoExport.cropPreservingOriginal(copy, normalized: normalized)
            let backup = scratch.appendingPathComponent("原始窗口/fixture.mp4")
            if normalized != CGRect(x: 0, y: 0, width: 1, height: 1) {
                guard try AppUpdater.sha256(backup) == AppUpdater.sha256(source) else {
                    throw RecorderError.message("Original bytes were not preserved by crop finalization")
                }
            }
            let before = try AppUpdater.sha256(copy)
            var rejected = false
            do { try await GameVideoExport.cropPreservingOriginal(copy, normalized: CGRect(x: -1, y: 0, width: 1, height: 1)) }
            catch { rejected = true }
            guard rejected, try AppUpdater.sha256(copy) == before else {
                throw RecorderError.message("Failed crop must preserve its original")
            }
            print("PASS: native crop export dimensions, duration and audio track preservation")
            print("PASS: original bytes preserved in backup; rejected crop does not alter input")
            NSApp.terminate(nil)
        } catch { fputs("Crop self-test failed: \(error)\n", stderr); exit(1) }
    }
}
