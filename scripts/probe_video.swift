import AppKit
import AVFoundation
import Vision
import ImageIO

// Read a saved recording, not the live desktop; no screen or input permission needed.
guard CommandLine.arguments.count == 4 else {
    fputs("Usage: swift scripts/probe_video.swift VIDEO SECONDS OUTPUT.png\n", stderr)
    exit(2)
}
let asset = AVURLAsset(url: URL(fileURLWithPath: CommandLine.arguments[1]))
let generator = AVAssetImageGenerator(asset: asset)
generator.appliesPreferredTrackTransform = true
let image = try await generator.image(at: CMTime(seconds: Double(CommandLine.arguments[2]) ?? 0, preferredTimescale: 600)).image
let output = URL(fileURLWithPath: CommandLine.arguments[3])
let destination = CGImageDestinationCreateWithURL(output as CFURL, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else { exit(1) }
let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
request.recognitionLanguages = ["zh-Hans", "en-US"]
try VNImageRequestHandler(cgImage: image).perform([request])
let lines: [[String: Any]] = (request.results ?? []).compactMap { result in
    guard let text = result.topCandidates(1).first?.string else { return nil }
    let box = result.boundingBox
    return ["text": text, "x": box.minX, "y": 1 - box.maxY, "width": box.width, "height": box.height]
}
let data = try JSONSerialization.data(withJSONObject: lines, options: [.prettyPrinted, .sortedKeys])
try data.write(to: output.deletingPathExtension().appendingPathExtension("json"))
print("Frame: \(image.width)x\(image.height); OCR: \(lines.count) lines; saved to \(output.path)")
