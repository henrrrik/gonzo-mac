import AppKit
import GonzoCore

final class EditorStorage: NSTextStorage {
    private let backing = NSMutableAttributedString(string: "")
    // The owner's Swift view of the text (save snapshots, printing), bridged
    // from the immutable snapshot once per edit. AppKit reads -string through
    // the replaced Objective-C getter below instead.
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

    /// Installs prepared text with uniform attributes. Highlighting restyles
    /// paragraphs as they become visible; until then they lay out with these.
    func load(_ prepared: Prepared, attributes: [NSAttributedString.Key: Any]) {
        let oldLength = length
        beginEditing()
        cachedText = prepared.text
        snapshotIsCurrent = false
        backing.setAttributedString(NSAttributedString(string: prepared.text, attributes: attributes))
        unfixed.removeAll()
        lastWindowEnd = nil
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

    // AppKit reads -string on every edit (layout invalidation, input methods),
    // and the find bar reads it on a background thread. A Swift String getter
    // would bridge the whole store, transcoding non-ASCII text to UTF-8 and
    // indexing it back to UTF-16, on every keystroke; the live mutable store
    // would race background readers. Objective-C callers get an immutable copy
    // of the underlying CFString instead, a plain memory copy. Only the owner
    // builds it (the main thread for AppKit), once per batch of edits when first
    // read; other threads take the last published snapshot under a lock and
    // never touch the store.
    private static let objectiveCStringGetter: Void = {
        let getter: @convention(block) (EditorStorage) -> NSString = { $0.objectiveCString }
        let selector = #selector(getter: NSAttributedString.string)
        class_replaceMethod(EditorStorage.self, selector, imp_implementationWithBlock(getter), "@@:")
    }()
    private let snapshotLock = NSLock()
    private nonisolated(unsafe) var publishedSnapshot: NSString = ""
    // Owner only: whether the published snapshot matches the store.
    private var snapshotIsCurrent = false
    private var objectiveCString: NSString {
        guard Thread.isMainThread else {
            snapshotLock.lock(); defer { snapshotLock.unlock() }
            return publishedSnapshot
        }
        return currentSnapshot
    }
    // The storage's owner rebuilds a stale snapshot; called from the main
    // thread for AppKit, and by the Swift getter that only the owner uses.
    private var currentSnapshot: NSString {
        if !snapshotIsCurrent {
            // The backing store's own -string, not its mutableString proxy,
            // whose copies go character by character.
            let backingString = backing.perform(#selector(getter: NSAttributedString.string))!.takeUnretainedValue() as! NSString
            let snapshot = backingString.copy() as! NSString
            snapshotLock.lock(); publishedSnapshot = snapshot; snapshotLock.unlock()
            snapshotIsCurrent = true
        }
        return publishedSnapshot
    }
    // Installed once, the first time any storage is initialized.
    private let installsObjectiveCStringGetter: Void = EditorStorage.objectiveCStringGetter

    override var length: Int { backing.length }
    override var string: String {
        if let cachedText { return cachedText }
        // Bridge the immutable UTF-16 snapshot AppKit already reads, rather
        // than converting the whole store on the main thread at save time.
        let text = currentSnapshot as String
        cachedText = text
        return text
    }

    // Attribute fixing (font fallback for scripts and emoji the base font
    // lacks, uniform paragraph styles) is deferred to the first read of each
    // paragraph, as NSTextStorage's concrete class does. Installing or pasting
    // a large document then costs only what layout reads. Fixing on the
    // backing store changes no characters, revision or selection. Reads fix a
    // paragraph's pending text before reporting runs from it, so layout never
    // sees unfixed attributes and no edit notification is needed.
    private var unfixed = IndexSet()
    private var lastWindowEnd: Int?
    private var lastReach = 0

    override func fixAttributes(in range: NSRange) {
        guard range.length > 0 else { return }
        unfixed.insert(integersIn: range.location..<NSMaxRange(range))
    }

    override func ensureAttributesAreFixed(in range: NSRange) { fixUnfixed(in: range) }

    /// Fixes pending text in a paragraph-aligned window around a range. Each
    /// AppKit fix call costs time proportional to the attribute runs already
    /// in the store, so fixing one paragraph per read would make traversals of
    /// fallback-font text quadratic: enumeration, undo registration for Replace
    /// All or replacing everything, and scrolling down. While reads continue
    /// forward from the previous window, the window doubles, so a full
    /// traversal makes a logarithmic number of calls. Other reads use the base
    /// window, including typing and layout reading backwards: AppKit inserts
    /// runs ahead of all later runs, so large backward fixes are costly. Window edges stay at paragraph boundaries, so the typesetter
    /// never sees runs end mid-paragraph at a fix boundary, and a giant
    /// paragraph is fixed in one call. Only pending pieces are fixed.
    private func fixUnfixed(in range: NSRange) {
        guard !unfixed.isEmpty, length > 0 else { return }
        let base = 8192
        // A forward traversal's next fixing read lands on the first pending text
        // at or after the previous window's end, having read only fixed text in
        // between; allow a small stride for range-by-range readers. Typing and
        // layout look-behind read inside or before that window, and jumps skip
        // pending text, so neither grows the window.
        let continuesTraversal = lastWindowEnd.map { end in
            range.location >= end && range.location < (unfixed.integerGreaterThanOrEqualTo(end) ?? length) + 512
        } ?? false
        // Cap growth so one frame's work stays bounded in large documents.
        let reach = continuesTraversal ? min(lastReach * 2, 16 * base, length) : base
        // A traversal grows the window forward only, never before the read's paragraph.
        let lower = continuesTraversal ? range.location : max(0, range.location - reach)
        let upper = min(length, NSMaxRange(range) + reach)
        let window = paragraphRange(covering: NSRange(location: min(lower, length - 1), length: upper - lower))
        var start = window.location
        // Reading upward into pending text above a long stretch below detaches
        // that stretch once per fix (see fixBacking). Fix a larger, bounded
        // chunk above so the detach cost is spread over many pages.
        let below = length - NSMaxRange(window)
        if !continuesTraversal, start > 0, below >= 32_768, unfixed.contains(start - 1),
           let above = unfixed.rangeView(of: 0..<start).last {
            let chunk = min(start - above.lowerBound, max(16 * base, below / 4))
            start = paragraphRange(covering: NSRange(location: start - chunk, length: 0)).location
        }
        let pending = unfixed.rangeView(of: start..<NSMaxRange(window))
        guard let first = pending.first, let last = pending.last else { return }
        if pending.count <= 8, last.upperBound - first.lowerBound > 4 * base {
            for piece in pending {
                fixBacking(NSRange(location: piece.lowerBound, length: piece.count))
            }
        } else {
            // Nearby or fragmented pending text, as after restyling or Replace
            // All: one call over the span, since each call pays for later runs.
            fixBacking(NSRange(location: first.lowerBound, length: last.upperBound - first.lowerBound))
        }
        unfixed.remove(integersIn: first.lowerBound..<last.upperBound)
        lastWindowEnd = NSMaxRange(window)
        lastReach = reach
    }

    /// AppKit inserts each new attribute run ahead of all later runs, so one
    /// large fix ahead of much text, such as a long paragraph above text that
    /// was already read, costs its length times the runs after it. Detach the
    /// text after the range's paragraph while fixing and append it back. The
    /// backing store is private, so no characters, revisions or notifications
    /// change, and the result equals fixing in place.
    private func fixBacking(_ range: NSRange) {
        guard range.length >= 1024, NSMaxRange(range) < length else {
            backing.fixAttributes(in: range)
            return
        }
        let tailStart = NSMaxRange(paragraphRange(covering: NSRange(location: NSMaxRange(range) - 1, length: 0)))
        guard length - tailStart >= 32_768 else {
            backing.fixAttributes(in: range)
            return
        }
        let tailRange = NSRange(location: tailStart, length: length - tailStart)
        let tail = backing.attributedSubstring(from: tailRange)
        backing.deleteCharacters(in: tailRange)
        backing.fixAttributes(in: range)
        backing.append(tail)
    }

    /// Fixes text at a read location and clips the reported run so it never
    /// extends over text whose attributes have not been fixed yet.
    private func fixedRead<Value>(at location: Int, _ range: NSRangePointer?, _ read: (NSRangePointer?) -> Value) -> Value {
        if unfixed.contains(location) { fixUnfixed(in: NSRange(location: location, length: 0)) }
        let value = read(range)
        if let range, !unfixed.isEmpty {
            let lower = (unfixed.integerLessThan(location) ?? -1) + 1
            let upper = min(NSMaxRange(range.pointee), unfixed.integerGreaterThan(location) ?? Int.max)
            let start = max(range.pointee.location, lower)
            range.pointee = NSRange(location: start, length: upper - start)
        }
        return value
    }

    // Forward every read to the backing store. NSAttributedString's generic
    // subclass versions rebuild runs one primitive call at a time, which made
    // attribute fixing on each keystroke scale with fallback-font runs.
    override func attributes(at location: Int, effectiveRange range: NSRangePointer?) -> [NSAttributedString.Key: Any] {
        fixedRead(at: location, range) { backing.attributes(at: location, effectiveRange: $0) }
    }
    override func attributes(at location: Int, longestEffectiveRange range: NSRangePointer?, in rangeLimit: NSRange) -> [NSAttributedString.Key: Any] {
        fixedRead(at: location, range) { backing.attributes(at: location, longestEffectiveRange: $0, in: rangeLimit) }
    }
    override func attribute(_ name: NSAttributedString.Key, at location: Int, effectiveRange range: NSRangePointer?) -> Any? {
        fixedRead(at: location, range) { backing.attribute(name, at: location, effectiveRange: $0) }
    }
    override func attribute(_ name: NSAttributedString.Key, at location: Int, longestEffectiveRange range: NSRangePointer?, in rangeLimit: NSRange) -> Any? {
        fixedRead(at: location, range) { backing.attribute(name, at: location, longestEffectiveRange: $0, in: rangeLimit) }
    }
    override func attributedSubstring(from range: NSRange) -> NSAttributedString {
        if range.length > 0, unfixed.intersects(integersIn: range.location..<NSMaxRange(range)) { fixUnfixed(in: range) }
        return backing.attributedSubstring(from: range)
    }

    override func replaceCharacters(in range: NSRange, with str: String) {
        let finishMetrics = metrics.prepareEdit(in: source, range: range)
        let insertedLength = (str as NSString).length
        utf8Count += str.utf8.count - source.substring(with: range).utf8.count
        beginEditing()
        cachedText = nil
        snapshotIsCurrent = false
        backing.replaceCharacters(in: range, with: str)
        // Keep pending fixes aligned with the text; processEditing marks the
        // inserted characters through fixAttributes(in:).
        unfixed.remove(integersIn: range.location..<NSMaxRange(range))
        unfixed.shift(startingAt: NSMaxRange(range), by: insertedLength - range.length)
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
    var fontSize: CGFloat = MarkdownHighlighter.defaultFontSize {
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
        let attributes = Self.baseAttributes(fontSize: fontSize)
        cachedBase = attributes
        return attributes
    }
    static let defaultFontSize: CGFloat = 13
    static func baseAttributes(fontSize: CGFloat) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 9
        paragraph.paragraphSpacing = 2
        return [
            .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
            .foregroundColor: NSColor.textColor, .paragraphStyle: paragraph.copy() as! NSParagraphStyle
        ]
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

    /// Paragraph-aligned characters in the viewport plus a margin.
    private func visibleParagraphs(_ storage: EditorStorage) -> NSRange? {
        guard let view = textView, let layout = view.layoutManager, let container = view.textContainer,
              let scroll = view.enclosingScrollView else { return nil }
        var rect = scroll.contentView.bounds
        rect.origin.x -= view.textContainerOrigin.x
        rect.origin.y -= view.textContainerOrigin.y
        rect = rect.insetBy(dx: 0, dy: -160)
        let glyphs = layout.glyphRange(forBoundingRect: rect, in: container)
        let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        return storage.paragraphRange(covering: characters)
    }

    func refreshVisible() {
        guard let storage = textView?.textStorage as? EditorStorage, storage.length > 0 else { return }
        synchronize(storage)
        // Styling changes line heights and can bring more text into view, for
        // example after a smaller text size. Repeat until the viewport is styled.
        var styled: NSRange?
        for _ in 0..<4 {
            guard let visible = visibleParagraphs(storage), visible != styled else { return }
            style(visible, storage: storage)
            styled = visible
        }
    }

    func refreshEditedParagraphs() {
        guard let storage = textView?.textStorage as? EditorStorage else { return }
        // Several replacements since the last refresh, such as Replace All,
        // leave only the final one in lastChangedRange.
        let missedEdits = revision &+ 1 != storage.revision
        synchronize(storage)
        guard textView?.window?.isVisible == true, let visible = visibleParagraphs(storage) else {
            style(storage.lastChangedRange, storage: storage)
            return
        }
        // Style edited paragraphs within the viewport only. Synchronizing drops
        // the rest from the cache, so refreshVisible styles them when scrolled in;
        // a large paste or undo no longer restyles off-screen text up front.
        let range = missedEdits ? visible : NSIntersectionRange(storage.lastChangedRange, visible)
        if range.length > 0 { style(range, storage: storage) }
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
        // when a cache miss reconstructs an already identical paragraph. Fix the
        // local copy first, so fallback fonts the storage already chose compare
        // equal instead of being rewritten and refixed on every restyle.
        styled.fixAttributes(in: NSRange(location: 0, length: styled.length))
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
