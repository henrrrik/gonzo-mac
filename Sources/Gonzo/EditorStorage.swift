import AppKit
import GonzoCore

final class EditorStorage: NSTextStorage {
    private let backing = NSMutableAttributedString(string: "")
    private(set) var wordCount = 0
    private(set) var utf8Count = 0
    private(set) var revision: UInt64 = 0
    private(set) var lastChangedRange = NSRange(location: 0, length: 0)
    var source: NSString { backing.mutableString }

    override var string: String { backing.string }

    override func attributes(at location: Int, effectiveRange range: NSRangePointer?) -> [NSAttributedString.Key: Any] {
        backing.attributes(at: location, effectiveRange: range)
    }

    override func replaceCharacters(in range: NSRange, with str: String) {
        // Include whole adjacent paragraphs on both sides of an edit, including
        // deletion of a newline. Only those words can have changed.
        let start = max(0, range.location - 1)
        let end = min(length, NSMaxRange(range) + 1)
        let oldParagraphs = Paragraphs.range(in: source, covering: NSRange(location: start, length: end - start))
        let oldCount = WordCounter.count(source, range: oldParagraphs)
        let insertedLength = (str as NSString).length
        utf8Count += str.utf8.count - source.substring(with: range).utf8.count
        beginEditing()
        backing.replaceCharacters(in: range, with: str)
        let newRange = NSRange(location: oldParagraphs.location,
                               length: oldParagraphs.length + insertedLength - range.length)
        wordCount += WordCounter.count(source, range: newRange) - oldCount
        revision &+= 1
        lastChangedRange = Paragraphs.range(in: source, covering: NSRange(location: range.location, length: insertedLength))
        edited(.editedCharacters, range: range, changeInLength: insertedLength - range.length)
        endEditing()
    }

    override func setAttributes(_ attrs: [NSAttributedString.Key: Any]?, range: NSRange) {
        beginEditing()
        backing.setAttributes(attrs, range: range)
        edited(.editedAttributes, range: range, changeInLength: 0)
        endEditing()
    }
}

@MainActor
final class MarkdownHighlighter {
    private weak var textView: NSTextView?
    private var styledRange = NSRange(location: NSNotFound, length: 0)
    private var revision: UInt64 = .max
    var fontSize: CGFloat = 19

    init(textView: NSTextView) { self.textView = textView }

    var baseFont: NSFont { NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular) }

    var baseAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 9
        paragraph.paragraphSpacing = 2
        return [.font: baseFont, .foregroundColor: NSColor.textColor, .paragraphStyle: paragraph]
    }

    func invalidate() { styledRange = NSRange(location: NSNotFound, length: 0) }

    func refreshVisible() {
        guard let view = textView, let storage = view.textStorage as? EditorStorage,
              let layout = view.layoutManager, let container = view.textContainer,
              let scroll = view.enclosingScrollView, storage.length > 0 else { return }
        var rect = scroll.contentView.bounds
        rect.origin.x -= view.textContainerOrigin.x
        rect.origin.y -= view.textContainerOrigin.y
        rect = rect.insetBy(dx: 0, dy: -160)
        let glyphs = layout.glyphRange(forBoundingRect: rect, in: container)
        let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let visible = Paragraphs.range(in: storage.source, covering: characters)
        if revision == storage.revision, styledRange.location != NSNotFound,
           NSIntersectionRange(styledRange, visible) == visible { return }
        style(visible)
        styledRange = visible
        revision = storage.revision
    }

    func refreshEditedParagraphs() {
        guard let storage = textView?.textStorage as? EditorStorage else { return }
        style(storage.lastChangedRange)
        revision = storage.revision
        invalidate()
    }

    private func style(_ range: NSRange) {
        guard let view = textView, let storage = view.textStorage, range.length > 0 else { return }
        let selection = view.selectedRanges
        let text = (storage as? EditorStorage)?.source.substring(with: range) ?? (storage.string as NSString).substring(with: range)
        storage.beginEditing()
        storage.setAttributes(baseAttributes, range: range)
        for span in Markdown.spans(in: text) {
            let absolute = NSRange(location: range.location + span.range.location, length: span.range.length)
            let attributes: [NSAttributedString.Key: Any]
            switch span.style {
            case .marker: attributes = [.foregroundColor: NSColor.tertiaryLabelColor]
            case .heading(let level):
                let scale: [CGFloat] = [1.75, 1.45, 1.25, 1.12, 1.06, 1]
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineSpacing = 4
                paragraph.paragraphSpacingBefore = level == 1 ? 0 : fontSize * 0.5
                paragraph.paragraphSpacing = fontSize * 0.25
                // Include the markers and newline so wrapped headings share
                // one font size and paragraph metrics.
                let localParagraph = Paragraphs.range(in: text as NSString, covering: span.range)
                storage.addAttributes([
                    .font: NSFont.monospacedSystemFont(ofSize: fontSize * scale[level - 1], weight: .bold),
                    .paragraphStyle: paragraph
                ], range: NSRange(location: range.location + localParagraph.location, length: localParagraph.length))
                attributes = [.foregroundColor: NSColor.textColor]
            case .bold, .italic:
                let font = storage.attribute(.font, at: absolute.location, effectiveRange: nil) as? NSFont ?? baseFont
                let trait: NSFontTraitMask = span.style == .bold ? .boldFontMask : .italicFontMask
                attributes = [.font: NSFontManager.shared.convert(font, toHaveTrait: trait), .foregroundColor: NSColor.textColor]
            case .quote: attributes = [.foregroundColor: NSColor.secondaryLabelColor, .font: NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)]
            case .code: attributes = [.font: baseFont, .foregroundColor: NSColor.textColor, .backgroundColor: NSColor.quaternaryLabelColor]
            case .link: attributes = [.foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue]
            }
            storage.addAttributes(attributes, range: absolute)
        }
        storage.endEditing()
        view.selectedRanges = selection
    }
}
