import AppKit
import GonzoCore

final class EditorStorage: NSTextStorage {
    private let backing = NSMutableAttributedString(string: "")
    // TextKit can ask for string thousands of times per layout pass. Bridge
    // once per text edit rather than copying the full source on every call.
    private var cachedText: String?
    private var metrics = TextMetrics()
    var wordCount: Int { metrics.wordCount }
    private(set) var utf8Count = 0
    private(set) var revision: UInt64 = 0
    private(set) var lastChangedRange = NSRange(location: 0, length: 0)
    private(set) var lastEditRange = NSRange(location: 0, length: 0)
    private(set) var lastEditDelta = 0

    struct Prepared: Sendable {
        let text: String
        let metrics: TextMetrics
        let utf8Count: Int
        init(_ text: String) {
            self.text = text
            metrics = TextMetrics(text as NSString)
            utf8Count = text.utf8.count
        }
    }

    func load(_ prepared: Prepared) {
        let oldLength = length
        beginEditing()
        cachedText = prepared.text
        backing.setAttributedString(NSAttributedString(string: prepared.text))
        metrics = prepared.metrics
        utf8Count = prepared.utf8Count
        revision &+= 1
        lastEditRange = NSRange(location: 0, length: oldLength)
        lastEditDelta = length - oldLength
        lastChangedRange = NSRange(location: 0, length: length)
        edited(.editedCharacters, range: lastEditRange, changeInLength: lastEditDelta)
        endEditing()
    }
    var source: NSString { backing.mutableString }
    func paragraphRange(covering range: NSRange) -> NSRange { metrics.paragraphRange(in: source, covering: range) }

    override var length: Int { backing.length }
    override var string: String {
        if let cachedText { return cachedText }
        let text = backing.string
        cachedText = text
        return text
    }

    override func attributes(at location: Int, effectiveRange range: NSRangePointer?) -> [NSAttributedString.Key: Any] {
        backing.attributes(at: location, effectiveRange: range)
    }

    override func replaceCharacters(in range: NSRange, with str: String) {
        let finishMetrics = metrics.prepareEdit(in: source, range: range)
        let insertedLength = (str as NSString).length
        utf8Count += str.utf8.count - source.substring(with: range).utf8.count
        beginEditing()
        cachedText = nil
        backing.replaceCharacters(in: range, with: str)
        finishMetrics(source, insertedLength)
        revision &+= 1
        lastEditRange = range
        lastEditDelta = insertedLength - range.length
        lastChangedRange = paragraphRange(covering: NSRange(location: range.location, length: insertedLength))
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
    private struct CachedParagraph {
        let length: Int
        let plain: Bool
        let stamp: UInt64
    }
    private var paragraphs: [Int: CachedParagraph] = [:]
    private var revision: UInt64 = .max
    private var stamp: UInt64 = 0
    private var cachedBase: [NSAttributedString.Key: Any]?
    private var headings: [Int: [NSAttributedString.Key: Any]] = [:]
    private var fonts: [String: NSFont] = [:]
    private(set) var styledParagraphCount = 0
    var cachedParagraphCount: Int { paragraphs.count }
    var fontSize: CGFloat = 13 {
        didSet {
            if oldValue != fontSize {
                cachedBase = nil; headings.removeAll(); fonts.removeAll(); invalidate()
            }
        }
    }

    init(textView: NSTextView) { self.textView = textView }
    var baseFont: NSFont { baseAttributes[.font] as! NSFont }
    var baseAttributes: [NSAttributedString.Key: Any] {
        if let cachedBase { return cachedBase }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 9
        paragraph.paragraphSpacing = 2
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
            .foregroundColor: NSColor.textColor, .paragraphStyle: paragraph.copy() as! NSParagraphStyle
        ]
        cachedBase = attributes
        return attributes
    }

    func invalidate() { paragraphs.removeAll(); revision = .max }

    private func synchronize(_ storage: EditorStorage) {
        guard revision != storage.revision else { return }
        if revision &+ 1 != storage.revision { paragraphs.removeAll() }
        else {
            let edit = storage.lastEditRange
            let delta = storage.lastEditDelta
            var updated: [Int: CachedParagraph] = [:]
            for (start, entry) in paragraphs {
                let end = start + entry.length
                if end < edit.location { updated[start] = entry }
                else if start > NSMaxRange(edit) { updated[start + delta] = entry }
                else if entry.plain, start == storage.lastChangedRange.location,
                        storage.lastChangedRange.length > 4096,
                        entry.length + delta == storage.lastChangedRange.length {
                    updated[start] = CachedParagraph(length: entry.length + delta, plain: true, stamp: entry.stamp)
                }
            }
            paragraphs = updated
        }
        revision = storage.revision
    }

    func refreshVisible() {
        guard let view = textView, let storage = view.textStorage as? EditorStorage,
              let layout = view.layoutManager, let container = view.textContainer,
              let scroll = view.enclosingScrollView, storage.length > 0 else { return }
        synchronize(storage)
        var rect = scroll.contentView.bounds
        rect.origin.x -= view.textContainerOrigin.x
        rect.origin.y -= view.textContainerOrigin.y
        rect = rect.insetBy(dx: 0, dy: -160)
        let glyphs = layout.glyphRange(forBoundingRect: rect, in: container)
        let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        style(storage.paragraphRange(covering: characters), storage: storage)
    }

    func refreshEditedParagraphs() {
        guard let storage = textView?.textStorage as? EditorStorage else { return }
        synchronize(storage)
        style(storage.lastChangedRange, storage: storage)
    }

    private func headingAttributes(_ level: Int) -> [NSAttributedString.Key: Any] {
        if let attributes = headings[level] { return attributes }
        let scale: [CGFloat] = [1.75, 1.45, 1.25, 1.12, 1.06, 1]
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        paragraph.paragraphSpacingBefore = level == 1 ? 0 : fontSize * 0.5
        paragraph.paragraphSpacing = fontSize * 0.25
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: fontSize * scale[level - 1], weight: .bold),
            .paragraphStyle: paragraph.copy() as! NSParagraphStyle
        ]
        headings[level] = attributes
        return attributes
    }

    private func converted(_ font: NSFont, trait: NSFontTraitMask) -> NSFont {
        let key = "\(font.fontName):\(font.pointSize):\(trait.rawValue)"
        if let cached = fonts[key] { return cached }
        let converted = NSFontManager.shared.convert(font, toHaveTrait: trait)
        fonts[key] = converted
        return converted
    }

    private func style(_ range: NSRange, storage: EditorStorage) {
        var start = range.location
        storage.beginEditing()
        defer { storage.endEditing() }
        while start < NSMaxRange(range) {
            let paragraph = storage.paragraphRange(covering: NSRange(location: start, length: 0))
            guard paragraph.length > 0 else { break }
            stamp &+= 1
            if let cached = paragraphs[start], cached.length == paragraph.length {
                paragraphs[start] = CachedParagraph(length: cached.length, plain: cached.plain, stamp: stamp)
            } else {
                styleParagraph(paragraph, storage: storage)
                paragraphs[start] = CachedParagraph(length: paragraph.length, plain: paragraph.length > 4096, stamp: stamp)
            }
            // Trim during bulk edits too, so a large paste never creates a
            // temporary document-sized cache. Evict in batches to amortize sorting.
            if paragraphs.count > 256 {
                for key in paragraphs.sorted(by: { $0.value.stamp < $1.value.stamp }).prefix(128).map(\.key) {
                    paragraphs.removeValue(forKey: key)
                }
            }
            start = NSMaxRange(paragraph)
        }
    }

    private func styleParagraph(_ range: NSRange, storage: EditorStorage) {
        styledParagraphCount += 1
        if range.length > 4096 {
            // Do not copy or parse giant paragraphs. Clear stale formatting
            // once when entering plain mode, then preserve it across edits.
            var effective = NSRange()
            let attributes = storage.attributes(at: range.location, effectiveRange: &effective)
            if NSMaxRange(effective) < NSMaxRange(range) || !NSDictionary(dictionary: attributes).isEqual(to: baseAttributes) {
                storage.setAttributes(baseAttributes, range: range)
            }
            return
        }
        let text = storage.source.substring(with: range)
        let styled = NSMutableAttributedString(string: text, attributes: baseAttributes)
        for span in Markdown.spans(in: text) {
            let attributes: [NSAttributedString.Key: Any]
            switch span.style {
            case .marker: attributes = [.foregroundColor: NSColor.tertiaryLabelColor]
            case .heading(let level):
                styled.addAttributes(headingAttributes(level), range: NSRange(location: 0, length: styled.length))
                attributes = [.foregroundColor: NSColor.textColor]
            case .bold, .italic:
                let font = styled.attribute(.font, at: span.range.location, effectiveRange: nil) as? NSFont ?? baseFont
                attributes = [.font: converted(font, trait: span.style == .bold ? .boldFontMask : .italicFontMask), .foregroundColor: NSColor.textColor]
            case .quote: attributes = [.foregroundColor: NSColor.secondaryLabelColor, .font: converted(baseFont, trait: .italicFontMask)]
            case .code: attributes = [.font: baseFont, .foregroundColor: NSColor.textColor, .backgroundColor: NSColor.quaternaryLabelColor]
            case .link: attributes = [.foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue]
            }
            styled.addAttributes(attributes, range: span.range)
        }
        // Keep native selection state untouched and avoid layout invalidation
        // when a cache miss reconstructs an already identical paragraph.
        let current = storage.attributedSubstring(from: range)
        if !current.isEqual(to: styled) {
            styled.enumerateAttributes(in: NSRange(location: 0, length: styled.length)) { attributes, local, _ in
                current.enumerateAttributes(in: local) { existing, changed, _ in
                    if !NSDictionary(dictionary: existing).isEqual(to: attributes) {
                        storage.setAttributes(attributes, range: NSRange(location: range.location + changed.location, length: changed.length))
                    }
                }
            }
        }
    }
}
