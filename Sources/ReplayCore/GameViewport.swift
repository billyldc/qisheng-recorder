import Foundation
import CoreGraphics

public enum GameViewport {
    public static func rgba(_ image: CGImage) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let ok = pixels.withUnsafeMutableBytes { data -> Bool in
            guard let context = CGContext(data: data.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        return ok ? pixels : nil
    }
    /// Only remove near-black edges surrounding a sufficiently bright interior.
    /// No assumed aspect ratio and no resolution-specific coordinates.
    public static func blackBorderBounds(rgba: [UInt8], width: Int, height: Int) -> CGRect? {
        guard width >= 160, height >= 90, rgba.count == width * height * 4 else { return nil }
        func lit(_ x: Int, _ y: Int) -> Bool {
            let i = (y * width + x) * 4
            return max(rgba[i], rgba[i + 1], rgba[i + 2]) > 10
        }
        func blackRow(_ y: Int) -> Bool { !(0..<width).contains { lit($0, y) } }
        func blackColumn(_ x: Int, _ top: Int, _ bottom: Int) -> Bool {
            !(top..<bottom).contains { lit(x, $0) }
        }
        var top = 0, bottom = height, left = 0, right = width
        while top < bottom && blackRow(top) { top += 1 }
        while bottom > top && blackRow(bottom - 1) { bottom -= 1 }
        guard bottom > top else { return nil }
        while left < right && blackColumn(left, top, bottom) { left += 1 }
        while right > left && blackColumn(right - 1, top, bottom) { right -= 1 }
        guard right - left >= width / 2, bottom - top >= height / 2,
              Double((right - left) * (bottom - top)) >= Double(width * height) * 0.55,
              top <= height / 4, height - bottom <= height / 4,
              left <= width / 4, width - right <= width / 4 else { return nil }
        var bright = 0, count = 0
        for y in stride(from: top, to: bottom, by: 8) {
            for x in stride(from: left, to: right, by: 8) {
                let i = (y * width + x) * 4
                if max(rgba[i], rgba[i + 1], rgba[i + 2]) > 45 { bright += 1 }
                count += 1
            }
        }
        guard bright * 5 > count else { return nil }
        // Preserve two source pixels around the content, including antialiased edges.
        left = max(0, left - 2); top = max(0, top - 2)
        right = min(width, right + 2); bottom = min(height, bottom + 2)
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    public static func stableBounds(_ samples: [CGRect?], size: CGSize) -> CGRect? {
        guard samples.count >= 3, samples.allSatisfy({ $0 != nil }), let first = samples[0] else { return nil }
        let bounds = CGRect(origin: .zero, size: size)
        var result = first
        for sample in samples.compactMap({ $0 }) {
            guard !sample.isEmpty, bounds.contains(sample),
                  abs(first.minX - sample.minX) <= 3, abs(first.minY - sample.minY) <= 3,
                  abs(first.maxX - sample.maxX) <= 3, abs(first.maxY - sample.maxY) <= 3 else { return nil }
            result = result.union(sample)
        }
        return result
    }

    public static func samePageBounds(_ first: CGRect, _ second: CGRect) -> Bool {
        let values = [first.minX, first.minY, first.width, first.height,
                      second.minX, second.minY, second.width, second.height]
        guard values.allSatisfy(\.isFinite), first.width > 0, first.height > 0,
              second.width > 0, second.height > 0 else { return false }
        return abs(first.minX - second.minX) <= 1 && abs(first.minY - second.minY) <= 1 &&
            abs(first.width - second.width) <= 1 && abs(first.height - second.height) <= 1
    }

    public static func pointRect(pixelRect: CGRect, imageSize: CGSize, source: CGRect) -> CGRect {
        CGRect(x: source.minX + pixelRect.minX / imageSize.width * source.width,
               y: source.minY + pixelRect.minY / imageSize.height * source.height,
               width: pixelRect.width / imageSize.width * source.width,
               height: pixelRect.height / imageSize.height * source.height)
    }

    public static func evenPixelBounds(normalized: CGRect, size: CGSize) -> CGRect {
        let x = max(0, floor(normalized.minX * size.width / 2) * 2)
        let y = max(0, floor(normalized.minY * size.height / 2) * 2)
        let right = min(floor(size.width / 2) * 2, ceil(normalized.maxX * size.width / 2) * 2)
        let bottom = min(floor(size.height / 2) * 2, ceil(normalized.maxY * size.height / 2) * 2)
        return CGRect(x: x, y: y, width: right - x, height: bottom - y)
    }
}
