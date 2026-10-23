import AppKit

@MainActor
enum ReleaseNotesPresentation {
    static func alert(version: String, body: String?) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "安装 \(version)？"
        alert.informativeText = "安装后会重新打开应用，旧版保留为备份。macOS 仍可能要求确认权限。"
        let height = min(400, max(220, (NSScreen.main?.visibleFrame.height ?? 900) - 360))
        let width = min(560, max(320, (NSScreen.main?.visibleFrame.width ?? 900) - 220))
        alert.accessoryView = ReleaseNotesView(markdown: body, size: NSSize(width: width, height: height))
        alert.addButton(withTitle: "下载并安装")
        alert.addButton(withTitle: "取消")
        alert.buttons[1].keyEquivalent = "\u{1b}"
        return alert
    }

    static func webLink(_ value: Any) -> URL? {
        let url = (value as? URL) ?? (value as? String).flatMap(URL.init(string:))
        guard let url, ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              url.host?.isEmpty == false else { return nil }
        return url
    }

    static func render(_ markdown: String?) -> NSAttributedString {
        let source = markdown?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let base: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor]
        guard !source.isEmpty else { return NSAttributedString(string: "该版本未提供更新说明。", attributes: base) }
        var options = AttributedString.MarkdownParsingOptions()
        options.failurePolicy = .throwError
        guard let parsed = try? AttributedString(markdown: source, options: options,
            baseURL: URL(string: "https://github.com/\(AppUpdater.repository)/")) else {
            return NSAttributedString(string: source, attributes: base)
        }
        let output = NSMutableAttributedString(string: "")
        var previousBlock: Int?
        var previousAttributes = base
        var listedItems: Set<Int> = []
        var listMarkerForBlock = false
        var tables: [Int: NSTextTable] = [:]
        var cells: [Int: NSTextTableBlock] = [:]
        for run in parsed.runs {
            let components = run.presentationIntent?.components ?? []
            let block = components.first?.identity
            let newBlock = output.length == 0 || block != previousBlock
            if newBlock { listMarkerForBlock = false }
            let paragraph = NSMutableParagraphStyle()
            paragraph.paragraphSpacing = 8
            paragraph.lineSpacing = 2
            paragraph.lineBreakMode = .byWordWrapping
            var attributes = base
            var font = NSFont.systemFont(ofSize: 13)
            var codeBlock = false
            var listDepth = 0
            var listItem: (id: Int, ordinal: Int)?
            var ordered: Bool?
            var quoted = false
            var table: NSTextTable?
            var row = 0, column: Int?
            var cellIdentity: Int?
            var tableHeader = false
            for component in components {
                switch component.kind {
                case .header(let level):
                    font = .systemFont(ofSize: level == 1 ? 19 : level == 2 ? 16 : 14, weight: .semibold)
                    paragraph.paragraphSpacingBefore = 10
                    paragraph.paragraphSpacing = 6
                case .codeBlock:
                    codeBlock = true
                    paragraph.lineSpacing = 1
                    paragraph.paragraphSpacing = 3
                    paragraph.lineBreakMode = .byCharWrapping
                case .blockQuote: quoted = true
                case .listItem(let ordinal):
                    if listItem == nil { listItem = (component.identity, ordinal) }
                case .orderedList:
                    listDepth += 1
                    if ordered == nil { ordered = true }
                case .unorderedList:
                    listDepth += 1
                    if ordered == nil { ordered = false }
                case .table(let columns):
                    if tables[component.identity] == nil {
                        let value = NSTextTable()
                        value.numberOfColumns = columns.count
                        value.collapsesBorders = true
                        value.setContentWidth(100, type: .percentageValueType)
                        tables[component.identity] = value
                    }
                    table = tables[component.identity]
                case .tableHeaderRow: tableHeader = true
                case .tableRow(let index): row = index
                case .tableCell(let index): column = index; cellIdentity = component.identity
                default: break
                }
            }
            var prefix = ""
            if quoted {
                paragraph.firstLineHeadIndent = 12
                paragraph.headIndent = 12
                attributes[.foregroundColor] = NSColor.secondaryLabelColor
            }
            if let item = listItem {
                let indent = CGFloat(max(0, listDepth - 1)) * 18 + (quoted ? 12 : 0)
                paragraph.firstLineHeadIndent = indent
                paragraph.headIndent = indent + 24
                paragraph.tabStops = [NSTextTab(textAlignment: .left, location: indent + 24)]
                if newBlock {
                    listMarkerForBlock = listedItems.insert(item.id).inserted
                    if listMarkerForBlock { prefix = ordered == true ? "\(item.ordinal).\t" : "•\t" }
                }
                if !listMarkerForBlock { paragraph.firstLineHeadIndent = paragraph.headIndent }
            }
            if let table, let column, let cellIdentity {
                if cells[cellIdentity] == nil {
                    let cell = NSTextTableBlock(table: table, startingRow: row, rowSpan: 1, startingColumn: column, columnSpan: 1)
                    cell.setWidth(1, type: .absoluteValueType, for: .border)
                    cell.setBorderColor(.separatorColor)
                    cell.setWidth(6, type: .absoluteValueType, for: .padding)
                    cells[cellIdentity] = cell
                }
                let cell = cells[cellIdentity]!
                paragraph.textBlocks = [cell]
                paragraph.paragraphSpacing = 0
                if tableHeader { font = .systemFont(ofSize: 13, weight: .semibold) }
            }
            let inline = run.inlinePresentationIntent ?? []
            if codeBlock || inline.contains(.code) {
                font = .monospacedSystemFont(ofSize: 12, weight: .regular)
                attributes[.backgroundColor] = NSColor.quaternaryLabelColor
            }
            if inline.contains(.stronglyEmphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
            if inline.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            if inline.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            attributes[.font] = font
            attributes[.paragraphStyle] = paragraph
            if let link = run.link, let url = webLink(link) {
                attributes[.link] = url
                attributes[.foregroundColor] = NSColor.linkColor
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            // Foundation parses block structure but does not insert paragraph
            // separators when bridged to AppKit. Keep those boundaries explicitly.
            if newBlock, output.length > 0, !output.string.hasSuffix("\n") {
                output.append(NSAttributedString(string: "\n", attributes: previousAttributes))
            }
            if !prefix.isEmpty { output.append(NSAttributedString(string: prefix, attributes: attributes)) }
            output.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
            previousBlock = block
            previousAttributes = attributes
        }
        return output.length > 0 ? output : NSAttributedString(string: source, attributes: base)
    }
}

@MainActor
final class ReleaseNotesView: NSScrollView, NSTextViewDelegate {
    let notes = NSTextView()

    init(markdown: String?, size: NSSize) {
        super.init(frame: NSRect(origin: .zero, size: size))
        hasVerticalScroller = true
        autohidesScrollers = true
        borderType = .bezelBorder
        notes.isEditable = false
        notes.isSelectable = true
        notes.isRichText = true
        notes.drawsBackground = false
        notes.textContainerInset = NSSize(width: 12, height: 12)
        notes.isVerticallyResizable = true
        notes.isHorizontallyResizable = false
        notes.autoresizingMask = [.width]
        notes.minSize = .zero
        notes.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        notes.textContainer?.widthTracksTextView = true
        notes.textContainer?.containerSize = NSSize(width: contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        notes.frame = NSRect(origin: .zero, size: contentSize)
        notes.delegate = self
        notes.setAccessibilityLabel("更新日志")
        notes.textStorage?.setAttributedString(ReleaseNotesPresentation.render(markdown))
        documentView = notes
        if let container = notes.textContainer, let layout = notes.layoutManager {
            layout.ensureLayout(for: container)
            notes.setFrameSize(NSSize(width: contentSize.width, height: max(contentSize.height, layout.usedRect(for: container).height + 24)))
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        if let url = ReleaseNotesPresentation.webLink(link) { NSWorkspace.shared.open(url) }
        return true
    }
}
