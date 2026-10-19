import AppKit
import GonzoCore

@MainActor
final class WriterTextView: NSTextView {
    var defaultTypingAttributes: [NSAttributedString.Key: Any] = [:]
    var writingColumnWidth: CGFloat = 507 {
        didSet { updateWrappingWidth() }
    }
    private var isUpdatingWrappingWidth = false
    private(set) var isTrackingMouseSelection = false
    var didFinishMouseSelection: (() -> Void)?

    static let spellCheckingDidChange = Notification.Name("GonzoSpellCheckingDidChange")
    static let spellCheckingKey = "ContinuousSpellChecking"
    static var prefersSpellChecking: Bool { UserDefaults.standard.object(forKey: spellCheckingKey) as? Bool ?? true }

    override func toggleContinuousSpellChecking(_ sender: Any?) {
        super.toggleContinuousSpellChecking(sender)
        UserDefaults.standard.set(isContinuousSpellCheckingEnabled, forKey: Self.spellCheckingKey)
        NotificationCenter.default.post(name: Self.spellCheckingDidChange, object: self)
    }

    // Like the continuous checker, Check Document Now and the spelling panel
    // skip code and link destinations, so neither offers to rewrite them. The
    // search checks windows of about 16K UTF-16 units with those ranges blanked,
    // so its work follows the text actually searched and a misspelling never
    // yields fragments of a skipped token. Between windows the run loop handles
    // input; an edit, a selection change or a new search abandons it.
    var isSearchingSpelling: Bool { spellingSearch != nil }
    private var spellingSearch: SpellingSearch?

    private struct SpellingSearch {
        let storage: EditorStorage
        let revision: UInt64
        let selection: NSRange
        let start: Int
        let wrapEnd: Int
        var location: Int
        var wrapped = false
    }

    override func checkSpelling(_ sender: Any?) {
        guard let storage = textStorage as? EditorStorage else { return super.checkSpelling(sender) }
        let selection = selectedRange()
        let start = min(NSMaxRange(selection), storage.length)
        let paragraph = storage.paragraphRange(covering: NSRange(location: start, length: 0))
        var location = paragraph.location, wrapEnd = NSMaxRange(paragraph)
        if paragraph.length > Markdown.maximumParagraphLength + 2 {
            // Long paragraphs are plain text and are searched in slices, so start
            // and end at the whitespace around the caret's word: the checker
            // needs the whole word to judge it, never a fragment.
            let source = storage.source
            let before = NSRange(location: max(paragraph.location, start - 4096), length: start - max(paragraph.location, start - 4096))
            let space = source.rangeOfCharacter(from: .whitespacesAndNewlines, options: .backwards, range: before)
            if space.location != NSNotFound { location = NSMaxRange(space) }
            let after = NSRange(location: start, length: min(NSMaxRange(paragraph), start + 4096) - start)
            let next = source.rangeOfCharacter(from: .whitespacesAndNewlines, range: after)
            if next.location != NSNotFound { wrapEnd = NSMaxRange(next) }
        }
        // A new search replaces one in progress.
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(continueSpellingSearch), object: nil)
        spellingSearch = SpellingSearch(storage: storage, revision: storage.revision, selection: selection, start: start,
                                        wrapEnd: wrapEnd, location: location)
        continueSpellingSearch()
    }

    @objc private func continueSpellingSearch() {
        guard var search = spellingSearch else { return }
        let storage = search.storage
        guard textStorage === storage, storage.revision == search.revision, selectedRange() == search.selection else {
            spellingSearch = nil
            return
        }
        let limit = search.wrapped ? search.wrapEnd : storage.length
        if search.location >= limit {
            guard !search.wrapped else { return finishSpellingSearch(nil, in: storage) }
            search.wrapped = true
            search.location = 0
        }
        let window = spellingWindow(from: search.location, limit: search.wrapped ? search.wrapEnd : limit, in: storage)
        let offset = search.wrapped ? 0 : max(0, search.start - window.range.location)
        if offset < window.range.length {
            // The checker skips a word that begins at its start position, so a
            // word starting at the caret needs the search to begin one character
            // earlier: a whole composed character, never inside a surrogate pair.
            let text = blanked(window.range, parse: window.parse, source: storage.source)
            let from = offset > 0 ? (text as NSString).rangeOfComposedCharacterSequence(at: offset - 1).location : 0
            let found = NSSpellChecker.shared.checkSpelling(of: text, startingAt: from, language: nil, wrap: false, inSpellDocumentWithTag: spellCheckerDocumentTag, wordCount: nil)
            if found.location != NSNotFound, found.length > 0 {
                let range = NSRange(location: window.range.location + found.location, length: found.length)
                return finishSpellingSearch(search.wrapped && range.location >= search.start ? nil : range, in: storage)
            }
        }
        search.location = NSMaxRange(window.range)
        spellingSearch = search
        perform(#selector(continueSpellingSearch), with: nil, afterDelay: 0, inModes: [.default, .modalPanel])
    }

    private func finishSpellingSearch(_ found: NSRange?, in storage: EditorStorage) {
        spellingSearch = nil
        guard let found else { return NSSpellChecker.shared.updateSpellingPanel(withMisspelledWord: "") }
        setSelectedRange(found)
        scrollRangeToVisible(found)
        NSSpellChecker.shared.updateSpellingPanel(withMisspelledWord: storage.source.substring(with: found))
    }

    /// Whole paragraphs up to about 16K units. Inside a longer paragraph, which
    /// is plain text and never parsed, a window ends at whitespace instead.
    private func spellingWindow(from location: Int, limit: Int, in storage: EditorStorage) -> (range: NSRange, parse: Bool) {
        let source = storage.source
        let longest = Markdown.maximumParagraphLength + 2
        let containing = storage.paragraphRange(covering: NSRange(location: location, length: 0))
        let target = min(location + 16_384, limit)
        if containing.length > longest {
            var end = min(target, NSMaxRange(containing))
            if end < NSMaxRange(containing) {
                let tail = NSRange(location: max(location, end - 4096), length: end - max(location, end - 4096))
                let space = source.rangeOfCharacter(from: .whitespacesAndNewlines, options: .backwards, range: tail)
                if space.location != NSNotFound, space.location > location {
                    end = space.location + 1
                } else if end - 1 > location, CFStringIsSurrogateHighCharacter(source.character(at: end - 1)) {
                    end -= 1
                }
            }
            return (NSRange(location: location, length: end - location), false)
        }
        guard target < limit else {
            // The wrapped search can end inside a long paragraph, which is never
            // parsed. Stop before it, so the next window treats it as plain text.
            let last = storage.paragraphRange(covering: NSRange(location: limit - 1, length: 0))
            if last.length > longest, last.location > location {
                return (NSRange(location: location, length: last.location - location), true)
            }
            return (NSRange(location: location, length: limit - location), last.length <= longest)
        }
        let around = storage.paragraphRange(covering: NSRange(location: target, length: 0))
        let end = around.length > longest ? max(around.location, NSMaxRange(containing)) : NSMaxRange(around)
        return (NSRange(location: location, length: min(end, limit) - location), true)
    }

    private func blanked(_ window: NSRange, parse: Bool, source: NSString) -> String {
        var units = [unichar](repeating: 0, count: window.length)
        source.getCharacters(&units, range: window)
        if parse {
            for range in Markdown.spellingExclusions(in: source.substring(with: window) as NSString) {
                units.replaceSubrange(range.location..<NSMaxRange(range), with: repeatElement(0x20, count: range.length))
            }
        }
        return String(utf16CodeUnits: units, count: units.count)
    }

    override func mouseDown(with event: NSEvent) {
        // AppKit tracks dragging inside this call. Defer viewport styling
        // until it returns so heading metrics cannot change under the mouse.
        isTrackingMouseSelection = true
        defer {
            isTrackingMouseSelection = false
            didFinishMouseSelection?()
        }
        super.mouseDown(with: event)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateWrappingWidth()
    }

    private func updateWrappingWidth() {
        guard !isUpdatingWrappingWidth, let container = textContainer, frame.width > 0 else { return }
        isUpdatingWrappingWidth = true
        defer { isUpdatingWrappingWidth = false }
        let inset = NSSize(width: max(24, (frame.width - writingColumnWidth) / 2), height: 48)
        if textContainerInset != inset { textContainerInset = inset }
        let size = NSSize(width: max(1, frame.width - 2 * inset.width), height: CGFloat.greatestFiniteMagnitude)
        if container.containerSize != size { container.containerSize = size }
        needsDisplay = true
    }

    private var source: NSString { (textStorage as? EditorStorage)?.source ?? string as NSString }

    func updateInsertionAttributes() {
        var attributes = defaultTypingAttributes
        let position = selectedRange().location
        let length = source.length
        // A new empty paragraph must use the body font, rather than inherit
        // the heading on the preceding line. Else follow the styled text.
        if length > 0, position <= length,
           !(position == length && source.substring(from: length - 1).rangeOfCharacter(from: .newlines) != nil) {
            let index = min(position, length - 1)
            if let storage = textStorage {
                for key in [NSAttributedString.Key.font, .paragraphStyle] {
                    if let value = storage.attribute(key, at: index, effectiveRange: nil) { attributes[key] = value }
                }
            }
        }
        if !NSDictionary(dictionary: typingAttributes).isEqual(to: attributes) {
            typingAttributes = attributes
            updateInsertionPointStateAndRestartTimer(true)
        }
    }

    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        guard validateSize(ranges: [affectedCharRange], replacements: replacementString.map { [$0] }) else { return false }
        return super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
    }

    override func shouldChangeText(inRanges affectedRanges: [NSValue], replacementStrings: [String]?) -> Bool {
        guard validateSize(ranges: affectedRanges.map(\.rangeValue), replacements: replacementStrings) else { return false }
        return super.shouldChangeText(inRanges: affectedRanges, replacementStrings: replacementStrings)
    }

    private func validateSize(ranges: [NSRange], replacements: [String]?) -> Bool {
        guard let replacements, let storage = textStorage as? EditorStorage else { return true }
        guard ranges.count == replacements.count else { return false }
        var bytes = storage.utf8Count
        for (range, replacement) in zip(ranges, replacements) {
            guard range.location <= storage.length, range.length <= storage.length - range.location else { return false }
            bytes += replacement.utf8.count - source.substring(with: range).utf8.count
        }
        if bytes > GonzoDocument.maximumFileBytes {
            presentOversized()
            return false
        }
        return true
    }

    private func presentOversized() {
        if let window {
            NSAlert(error: GonzoDocument.oversizedFileError).beginSheetModal(for: window)
        } else { NSSound.beep() }
    }

    func apply(_ mutation: TextMutation, name: String) {
        guard shouldChangeText(in: mutation.range, replacementString: mutation.replacement) else { return }
        textStorage?.replaceCharacters(in: mutation.range, with: mutation.replacement)
        setSelectedRange(mutation.selection)
        didChangeText()
        undoManager?.setActionName(name)
        scrollRangeToVisible(selectedRange())
    }

    @objc func markdownBold(_ sender: Any?) { apply(EditorCommands.wrap(source, selection: selectedRange(), marker: "**"), name: "Bold") }
    @objc func markdownItalic(_ sender: Any?) { apply(EditorCommands.wrap(source, selection: selectedRange(), marker: "*"), name: "Italic") }
    @objc func markdownLink(_ sender: Any?) { apply(EditorCommands.link(source, selection: selectedRange(), destination: clipboardURL), name: "Link") }

    private var clipboardURL: String? { NSPasteboard.general.string(forType: .string).flatMap(Self.linkDestination) }

    private static func linkDestination(_ text: String) -> String? {
        guard (text as NSString).length <= 2048 else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              ["https", "http", "mailto"].contains(scheme) else { return nil }
        return trimmed
    }

    override func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        // Each UTF-16 unit is at least one UTF-8 byte. Reject oversized text
        // before trimming, normalizing or counting bytes copies it again.
        guard (text as NSString).length <= GonzoDocument.maximumFileBytes else {
            presentOversized()
            return
        }
        if selectedRange().length > 0, let destination = Self.linkDestination(text) {
            apply(EditorCommands.link(source, selection: selectedRange(), destination: destination), name: "Paste Link")
        } else {
            insertText(EditorCommands.normalize(text), replacementRange: selectedRange())
        }
    }

    override func pasteAsPlainText(_ sender: Any?) { paste(sender) }

    override func insertNewline(_ sender: Any?) {
        // Marked text belongs to the input method. Let AppKit commit it first.
        if hasMarkedText() { super.insertNewline(sender); return }
        let soft = NSApp.currentEvent?.modifierFlags.contains(.shift) == true
        let paragraph = (textStorage as? EditorStorage)?.paragraphRange(covering: NSRange(location: selectedRange().location, length: 0))
        apply(EditorCommands.newline(source, selection: selectedRange(), soft: soft, paragraphRange: paragraph), name: "New Paragraph")
    }

    override func deleteBackward(_ sender: Any?) {
        let selection = selectedRange()
        if !hasMarkedText(), selection.length == 0, selection.location >= 2,
           source.substring(with: NSRange(location: selection.location - 2, length: 2)) == "\n\n" {
            let range = NSRange(location: selection.location - 2, length: 2)
            apply(TextMutation(range: range, replacement: "", selection: NSRange(location: range.location, length: 0)), name: "Delete Paragraph Break")
        } else { super.deleteBackward(sender) }
    }

    override func didChangeText() {
        super.didChangeText()
        updateInsertionAttributes()
    }
}

/// Code spans and link destinations by paragraph, computed once per checking pass.
struct SpellingExclusions {
    private var paragraphs: [NSRange: [NSRange]] = [:]

    mutating func excludes(_ range: NSRange, in storage: EditorStorage) -> Bool {
        let source = storage.source
        guard range.location != NSNotFound, NSMaxRange(range) <= source.length else { return false }
        let paragraph = storage.paragraphRange(covering: range)
        let excluded = paragraphs[paragraph] ?? {
            // A terminator may follow the longest parsed paragraph.
            guard paragraph.length <= Markdown.maximumParagraphLength + 2 else { return [] }
            return Markdown.spellingExclusions(in: source.substring(with: paragraph) as NSString)
                .map { NSRange(location: paragraph.location + $0.location, length: $0.length) }
        }()
        paragraphs[paragraph] = excluded
        return excluded.contains { NSIntersectionRange($0, range).length > 0 }
    }
}
