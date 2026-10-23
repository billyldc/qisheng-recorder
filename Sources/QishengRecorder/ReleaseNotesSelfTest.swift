import AppKit

@MainActor
func checkReleaseNotesRendering() throws {
    let markdown = """
    # 更新标题

    正文与**加粗文字**、*斜体文字*、`inline_code`和~~删除文字~~。

    ## 更新内容

    - 第一项包含**重点**和补充文字
    - 第二项
      - 嵌套项

    1. 第一步
    2. 第二步

    > 重要提醒

    ```swift
    let value = 1
    print(value)
    ```

    [发布页](https://example.invalid/releases)

    [不安全链接](file:///etc/hosts)

    ![图片说明](https://example.invalid/tracking.png)

    | 项目 | 结果 |
    | --- | --- |
    | 角色库 | **正常** |
    """
    let rendered = ReleaseNotesPresentation.render(markdown)
    func attributes(_ text: String) throws -> [NSAttributedString.Key: Any] {
        let range = (rendered.string as NSString).range(of: text)
        guard range.location != NSNotFound else { throw RecorderError.message("Missing release-note content: \(text)") }
        return rendered.attributes(at: range.location, effectiveRange: nil)
    }
    guard !rendered.string.contains("# 更新"), !rendered.string.contains("**"),
          rendered.string.contains("更新标题\n正文"), rendered.string.contains("•\t第一项"),
          rendered.string.contains("1.\t第一步\n2.\t第二步"), rendered.string.contains("print(value)"),
          rendered.string.contains("图片说明") else { throw RecorderError.message("Markdown block rendering failed") }
    let heading = try attributes("更新标题")[.font] as! NSFont
    let body = try attributes("正文")[.font] as! NSFont
    let bold = try attributes("加粗文字")[.font] as! NSFont
    let italic = try attributes("斜体文字")[.font] as! NSFont
    guard heading.pointSize > body.pointSize,
          NSFontManager.shared.traits(of: bold).contains(.boldFontMask),
          NSFontManager.shared.traits(of: italic).contains(.italicFontMask),
          try attributes("删除文字")[.strikethroughStyle] != nil,
          try attributes("inline_code")[.backgroundColor] != nil,
          try attributes("重要提醒")[.paragraphStyle].map({ ($0 as! NSParagraphStyle).headIndent > 0 }) == true,
          try attributes("角色库")[.paragraphStyle].map({ !($0 as! NSParagraphStyle).textBlocks.isEmpty }) == true else {
        throw RecorderError.message("Markdown formatting attributes missing")
    }
    guard try attributes("发布页")[.link] != nil, try attributes("不安全链接")[.link] == nil,
          ReleaseNotesPresentation.webLink("javascript:alert(1)") == nil,
          ReleaseNotesPresentation.webLink("data:text/html,test") == nil,
          ReleaseNotesPresentation.webLink("qisheng://install") == nil,
          ReleaseNotesPresentation.webLink("https://github.com/") != nil,
          ReleaseNotesPresentation.render(nil).string == "该版本未提供更新说明。",
          ReleaseNotesPresentation.render(" \n ").string == "该版本未提供更新说明。" else {
        throw RecorderError.message("Release-note fallback or safe links failed")
    }
    let long = markdown + String(repeating: "\n\n- 长日志，保留完整内容。", count: 200) + "\n\n末尾检查"
    let alert = ReleaseNotesPresentation.alert(version: "v1.5.10", body: long)
    alert.layout()
    guard let view = alert.accessoryView as? ReleaseNotesView,
          view.notes.string.contains("末尾检查"), view.notes.frame.height > view.contentSize.height,
          view.hasVerticalScroller, view.notes.isSelectable, !view.notes.isEditable,
          alert.buttons.map(\.title) == ["下载并安装", "取消"],
          alert.buttons[1].keyEquivalent == "\u{1b}",
          alert.informativeText.contains("权限") else {
        throw RecorderError.message("Long release-note scrolling or update actions failed")
    }
    print("PASS: release-note Markdown blocks and inline styles, table, image alt text without loading, safe links, empty fallback, untruncated scrolling and update actions")
}
