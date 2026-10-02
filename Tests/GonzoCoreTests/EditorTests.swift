import Foundation
import Testing
@testable import GonzoCore

@Test func wrappingKeepsUnicodeSelection() {
    let text = "A 🦇 story" as NSString
    let selection = text.range(of: "🦇 story")
    let result = EditorCommands.wrap(text, selection: selection, marker: "**")
    #expect(result.replacement == "**🦇 story**")
    #expect(result.selection == NSRange(location: selection.location + 2, length: selection.length))
}

@Test func linksEscapeSyntaxAndSelectDestination() {
    let text = "[Fear]" as NSString
    let result = EditorCommands.link(text, selection: NSRange(location: 0, length: text.length), destination: nil)
    #expect(result.replacement == "[\\[Fear\\]](https://)")
    let replacement = result.replacement as NSString
    #expect(replacement.substring(with: result.selection) == "https://")
    let pasted = EditorCommands.link("story", selection: NSRange(location: 0, length: 5), destination: "https://example.com/(notes)")
    #expect(pasted.replacement == "[story](https://example.com/\\(notes\\))")
}

@Test(arguments: [
    ("The story", false, "\n\n"),
    ("The story", true, "\n"),
    ("- First", false, "\n- "),
    ("  9) First", false, "\n  10) "),
    ("> Quote", false, "\n> ")
]) func paragraphAndListReturn(input: String, soft: Bool, expected: String) {
    let text = input as NSString
    let result = EditorCommands.newline(text, selection: NSRange(location: text.length, length: 0), soft: soft)
    #expect(result.replacement == expected)
}

@Test func emptyListReturnExitsList() {
    let result = EditorCommands.newline("text\n\n- ", selection: NSRange(location: 8, length: 0), soft: false)
    #expect(result.range == NSRange(location: 6, length: 2))
    #expect(result.replacement == "\n")
}

@Test func newlineNormalization() {
    #expect(EditorCommands.normalize("a\r\nb\rc") == "a\nb\nc")
}

@Test func markdownRangesUseUTF16() {
    let text = "🦇 **fear** and `*code*`"
    let spans = Markdown.spans(in: text)
    let bold = spans.first { $0.style == .bold }!
    #expect((text as NSString).substring(with: bold.range) == "fear")
    #expect(bold.range.location == 5)
    #expect(spans.last?.style == .code)
}

@Test func headingsQuotesAndLinks() {
    let text = "# Heading\n> Quote\n[story](https://example.com)"
    let spans = Markdown.spans(in: text)
    #expect(spans.contains { $0.style == .heading(level: 1) })
    #expect(spans.contains { $0.style == .quote })
    #expect(spans.contains { $0.style == .link && (text as NSString).substring(with: $0.range) == "story" })
}

@Test func malformedMarkdownHasBoundedStylingWork() {
    let clock = ContinuousClock()
    let duration = clock.measure {
        for source in ["[a](" + String(repeating: "\\", count: 40),
                       String(repeating: "[", count: 20_000),
                       String(repeating: "`", count: 4096),
                       String(repeating: "_", count: 4096)] {
            _ = Markdown.spans(in: source)
        }
    }
    #expect(duration < .seconds(1))
    let source = "[🦇](https://example.com/\\(notes\\))\n# Title"
    let spans = Markdown.spans(in: source)
    #expect(spans.contains { $0.style == .link && (source as NSString).substring(with: $0.range) == "🦇" })
    #expect(spans.contains { $0.style == .heading(level: 1) })
    let longLine = String(repeating: "[", count: 20_000) + "\n**short**"
    #expect(Markdown.spans(in: longLine).contains { $0.style == .bold })
}

@Test(arguments: [
    ("", 0), ("# **Hello** world\n\n- story", 3),
    ("Fear & loathing — 1971", 3), ("🦇 ✍️", 0),
    ("Stockholm 東京 café", 3), ("𐐀", 1)
]) func wordCount(text: String, expected: Int) {
    #expect(WordCounter.count(text as NSString) == expected)
}
