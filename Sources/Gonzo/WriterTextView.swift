import AppKit
import GonzoCore

@MainActor
final class WriterTextView: NSTextView {
    var defaultTypingAttributes: [NSAttributedString.Key: Any] = [:]

    private var source: NSString { (textStorage as? EditorStorage)?.source ?? string as NSString }

    func apply(_ mutation: TextMutation, name: String) {
        guard shouldChangeText(in: mutation.range, replacementString: mutation.replacement) else { return }
        textStorage?.replaceCharacters(in: mutation.range, with: mutation.replacement)
        setSelectedRange(mutation.selection)
        didChangeText()
        undoManager?.setActionName(name)
        typingAttributes = defaultTypingAttributes
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
        apply(EditorCommands.newline(source, selection: selectedRange(), soft: soft), name: "New Paragraph")
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
        typingAttributes = defaultTypingAttributes
    }
}
