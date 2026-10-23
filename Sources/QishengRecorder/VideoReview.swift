import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct VideoReview: Codable, Sendable {
    var schemaVersion: Int
    var videoSHA256: String
    var slots: [ReviewSlot]
    var frames: [ReviewFrame]
    var perspectiveOverride: String
    var assetVersion: String
    var missing: [String]
    var status: String

    static func directory(_ video: URL) -> URL { video.deletingPathExtension().appendingPathExtension("review") }
    static func load(_ video: URL) -> Self? {
        guard let data = try? Data(contentsOf: directory(video).appendingPathComponent("review.json")) else { return nil }
        guard let result = try? JSONDecoder().decode(Self.self, from: data), result.schemaVersion == 1,
              result.slots.count == 6, result.frames.count <= 64,
              result.frames.allSatisfy({ $0.cards.count == 6 }) else { return nil }
        return result
    }
    func save(_ video: URL) throws {
        try JSONEncoder().encode(self).write(to: Self.directory(video).appendingPathComponent("review.json"), options: .atomic)
    }
    var summary: String {
        let confirmed = slots.filter { $0.state == "confirmed" || $0.manual }.count
        return "\(confirmed)/6 已确认 · \(frames.count) 个稳定画面" + (status == "reviewed" ? "" : " · 待核对")
    }
}

struct ReviewSlot: Codable, Sendable {
    var value: String
    var initial: String
    var manual: Bool
    var state: String
    var candidates: [ReviewCandidate]
}
struct ReviewCandidate: Codable, Sendable {
    var name: String
    var count: Int
    var evidence: [ReviewEvidence]
}
struct ReviewEvidence: Codable, Sendable { var time: Double; var crop: String }
struct ReviewFrame: Codable, Sendable {
    var time: Double
    var perspective: String
    var cards: [ReviewCard]
}
struct ReviewCard: Codable, Sendable {
    var name: String
    var box: [Double]
    var score: Double
    var crop: String
}

extension AppModel {
    func deferReviewForRecording() {
        guard let video = reviewingVideo else { return }
        if !reviewQueue.contains(video) { reviewQueue.insert(video, at: 0) }
        Metadata.cancelReview()
    }
    func importReviewVideos() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if !reviewVideos.contains(url) { reviewVideos.append(url) }
            queueReview(url)
        }
    }

    func queueReview(_ url: URL) {
        guard !reviewQueue.contains(url), reviewingVideo != url else { return }
        if !reviewVideos.contains(url) { reviewVideos.append(url) }
        try? FileManager.default.createDirectory(at: Settings.directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(reviewVideos) {
            try? data.write(to: Settings.directory.appendingPathComponent("review-videos.json"), options: .atomic)
        }
        reviewQueue.append(url)
        runNextReview()
    }

    func runNextReview() {
        guard !busy && !selectionActive && editingReviewVideo == nil && reviewingVideo == nil && !reviewQueue.isEmpty else { return }
        let video = reviewQueue.removeFirst()
        reviewingVideo = video
        Metadata.beginReview()
        reviewMessages[video] = "正在后台抽帧复核"
        Task {
            defer { reviewingVideo = nil; runNextReview() }
            do {
                let resources = Bundle.main.resourceURL!
                let review = try await Task.detached(priority: .utility) { try Metadata.review(video: video, resources: resources) }.value
                reviewMessages[video] = review.summary
                addLog("录像复核：\(video.lastPathComponent) · \(review.summary)")
            } catch {
                reviewMessages[video] = reviewQueue.contains(video) ? "录制优先，稍后继续复核" : "复核已取消或失败，原视频保留；可重试"
                addLog("录像复核失败（不影响录制）：\(error.localizedDescription)")
            }
        }
    }
}

struct VideoReviewEditor: View {
    var video: URL
    @State var review: VideoReview
    var rerun: () -> Void
    var saved: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var failure: String?
    @State private var frameIndex = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("角色复核").font(.title2.bold())
            Text(video.lastPathComponent).font(.caption).lineLimit(2)
            Picker("己方所在位置（整段一致时可指定）", selection: $review.perspectiveOverride) {
                Text("自动判断").tag("auto")
                Text("上方").tag("top")
                Text("下方").tag("bottom")
            }
            ScrollView {
                ForEach(review.slots.indices, id: \.self) { index in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("\(index < 3 ? "己方" : "对方") \(index % 3 + 1)").frame(width: 70)
                            TextField("角色", text: $review.slots[index].value)
                                .onChange(of: review.slots[index].value) { _, _ in review.slots[index].manual = true }
                            Toggle("人工确认", isOn: $review.slots[index].manual).toggleStyle(.checkbox)
                        }
                        Text("列表：\(review.slots[index].initial) · \(label(review.slots[index].state))").font(.caption).foregroundStyle(.secondary)
                        ForEach(review.slots[index].candidates, id: \.name) { candidate in
                            Text("\(candidate.name) · \(candidate.count) 帧").font(.caption)
                            HStack {
                                ForEach(Array(candidate.evidence.prefix(3).enumerated()), id: \.offset) { _, evidence in
                                    evidenceImage(evidence.crop, caption: "\(Int(evidence.time))s")
                                }
                            }
                        }
                    }.padding(.vertical, 8)
                    Divider()
                }
                if !review.frames.isEmpty {
                    let frame = review.frames[min(frameIndex, review.frames.count-1)]
                    Text("原始画面证据").font(.headline)
                    Stepper("\(frameIndex+1)/\(review.frames.count) · \(Int(frame.time)) 秒 · 己方\(frame.perspective == "top" ? "在上方" : frame.perspective == "bottom" ? "在下方" : "位置未确认")",
                            value: $frameIndex, in: 0...max(0, review.frames.count-1))
                    ForEach(0..<2) { row in
                        HStack {
                            Text(row == 0 ? "上方" : "下方")
                            ForEach(0..<3) { col in
                                let card = frame.cards[row*3+col]
                                evidenceImage(card.crop, caption: card.name)
                            }
                        }
                    }
                }
            }
            if let failure { Text(failure).foregroundStyle(.red) }
            HStack {
                Text(review.summary).font(.caption)
                Spacer()
                Button("取消") { dismiss() }
                Button("保存并重跑") { if save() { dismiss(); rerun() } }
                Button("保存") { if save() { dismiss() } }.buttonStyle(.borderedProminent)
            }
        }.padding(20).frame(width: 800, height: 720).background(Color(nsColor: .windowBackgroundColor))
    }
    private func label(_ state: String) -> String {
        switch state {
        case "confirmed": return "多帧一致"
        case "conflict": return "结果冲突"
        case "manual": return "人工确认"
        default: return "证据不足／图库可能缺失"
        }
    }
    private func evidenceImage(_ name: String, caption: String) -> some View {
        VStack {
            if name == (name as NSString).lastPathComponent,
               let image = NSImage(contentsOf: VideoReview.directory(video).appendingPathComponent(name)) {
                Image(nsImage: image).resizable().scaledToFit().frame(width: 84, height: 130)
            }
            Text(caption).font(.caption2).lineLimit(2).frame(width: 84)
        }
    }
    private func save() -> Bool {
        do {
            guard !review.slots.contains(where: { $0.manual && ($0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || $0.value == "未识别") }) else {
                failure = "请填写角色名称后再标记人工确认。"
                return false
            }
            for index in review.slots.indices {
                if review.slots[index].manual { review.slots[index].state = "manual" }
                else if review.slots[index].state == "manual" { review.slots[index].state = "unconfirmed" }
            }
            review.status = review.slots.allSatisfy { $0.manual || $0.state == "confirmed" } ? "reviewed" : "needsReview"
            try review.save(video)
            saved()
            return true
        } catch { failure = error.localizedDescription; return false }
    }
}
