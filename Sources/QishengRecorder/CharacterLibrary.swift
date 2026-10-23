import AppKit
import ImageIO
import SwiftUI

struct CharacterReference: Identifiable, Sendable {
    let id: String
    let name: String
    let imageURL: URL?
    let downloaded: Bool
    var source: String { imageURL == nil ? "图片缺失或损坏" : downloaded ? "更新下载" : "应用内置" }
}

enum CharacterLibrary {
    static func load(bundled: URL, extra: URL) throws -> [CharacterReference] {
        var result: [String: CharacterReference] = [:]
        for (root, downloaded) in [(bundled, false), (extra, true)] {
            let manifest = root.appendingPathComponent("names.json")
            guard FileManager.default.fileExists(atPath: manifest.path) else { continue }
            let names = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: manifest))
            for (stem, name) in names {
                guard stem.range(of: "^UI_Gcg_CardFace_Char_[A-Za-z0-9_]+$", options: .regularExpression) != nil else { continue }
                let file = root.appendingPathComponent("portraits").appendingPathComponent(stem + ".png")
                let valid = readableImage(file)
                if !valid && result[stem]?.imageURL != nil { continue }
                result[stem] = CharacterReference(id: stem, name: name, imageURL: valid ? file : nil, downloaded: downloaded)
            }
        }
        return result.values.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    static func readableImage(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return false }
        return min(image.width, image.height) >= 64 && max(image.width, image.height) <= 4096
    }
}

struct CharacterLibraryView: View {
    @ObservedObject var model: AppModel
    var bundled: URL = Bundle.main.resourceURL!.appendingPathComponent("Assets")
    var extra: URL = Settings.directory.appendingPathComponent("Portraits")
    @State private var entries: [CharacterReference] = []
    @State private var search = ""
    @State private var source = "all"
    @State private var selected: CharacterReference?
    @State private var loading = false
    @State private var failure: String?
    private var filtered: [CharacterReference] {
        entries.filter {
            (search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || $0.name.localizedStandardContains(search.trimmingCharacters(in: .whitespacesAndNewlines))) &&
            (source == "all" || (source == "missing" ? $0.imageURL == nil : $0.imageURL != nil && $0.downloaded == (source == "downloaded")))
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("角色库").font(.title2.bold())
                Text("\(entries.filter { $0.imageURL != nil }.count) 张可用图片").foregroundStyle(.secondary)
                Spacer()
                Button { Task { await reload() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("重新读取本地图库").disabled(loading)
                Button(action: model.updateAssets) { Label("更新角色库", systemImage: "arrow.down.circle") }
                    .disabled(model.busy || model.selectionActive || model.reviewingVideo != nil || model.editingReviewVideo != nil)
            }
            TextField("搜索角色名称", text: $search).textFieldStyle(.roundedBorder)
            Picker("图片来源", selection: $source) {
                Text("全部").tag("all")
                Text("内置").tag("bundled")
                Text("更新下载").tag("downloaded")
                Text("缺失或损坏").tag("missing")
            }.pickerStyle(.segmented)
            if let failure {
                Text(failure).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            if loading { ProgressView("正在读取本地图库…").frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if filtered.isEmpty {
                ContentUnavailableView(search.isEmpty ? "没有符合条件的图片" : "没有找到这个角色", systemImage: "photo.on.rectangle.angled")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 14)], spacing: 14) {
                        ForEach(filtered) { entry in
                            Button { selected = entry } label: {
                                VStack(spacing: 7) {
                                    referenceImage(entry).frame(height: 228)
                                    Text(entry.name).font(.body).lineLimit(2).frame(height: 40)
                                    Text(entry.source).font(.caption).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity).padding(10)
                                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain).help("查看\(entry.name)的参考图")
                        }
                    }.padding(.vertical, 4)
                }
            }
            Text("参考卡图，不是你的录像截图。浏览不联网；「更新角色库」才会检查并下载新图。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(22).background(Color(nsColor: .windowBackgroundColor))
            .task(id: model.assetDetails) { await reload() }
            .sheet(item: $selected) { entry in
                VStack(spacing: 12) {
                    HStack {
                        Text(entry.name).font(.title2.bold())
                        Spacer()
                        Button { selected = nil } label: { Image(systemName: "xmark") }.help("关闭大图")
                            .keyboardShortcut(.cancelAction)
                    }
                    referenceImage(entry).frame(maxWidth: .infinity, maxHeight: .infinity)
                    Text(entry.source).foregroundStyle(.secondary)
                }.padding(20).frame(width: 460, height: 620)
            }
    }
    private func referenceImage(_ entry: CharacterReference) -> some View {
        Group {
            if let url = entry.imageURL, let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().scaledToFit().accessibilityLabel(entry.name)
            } else {
                Image(systemName: "photo.badge.exclamationmark").font(.largeTitle).foregroundStyle(.secondary)
                    .accessibilityLabel("图片缺失或损坏")
            }
        }
    }
    @MainActor private func reload() async {
        guard !loading else { return }
        loading = true; failure = nil
        defer { loading = false }
        do {
            let base = bundled, additions = extra
            entries = try await Task.detached(priority: .utility) { try CharacterLibrary.load(bundled: base, extra: additions) }.value
        } catch { failure = "角色目录读取失败。已显示的图片保留，可重试或更新角色库。" }
    }
}
