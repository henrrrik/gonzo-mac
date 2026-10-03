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
            if let window {
                NSAlert(error: GonzoDocument.oversizedFileError).beginSheetModal(for: window)
            } else { NSSound.beep() }
            return false
        }
        return true
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

    private var clipboardURL: String? {
        guard let text = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              ["https", "http", "mailto"].contains(scheme) else { return nil }
        return text
    }

    override func paste(_ sender: Any?) {
        if selectedRange().length > 0, let destination = clipboardURL {
            apply(EditorCommands.link(source, selection: selectedRange(), destination: destination), name: "Paste Link")
        } else if let text = NSPasteboard.general.string(forType: .string) {
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
