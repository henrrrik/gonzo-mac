import AppKit
import Testing
@testable import Gonzo

@Suite(.serialized) @MainActor
struct DocumentTests {
    private static let documents = GonzoDocumentController()

    init() {
        _ = NSApplication.shared
        _ = Self.documents
    }

    @Test @MainActor func newDocumentDisplaysEditorWindow() throws {
        let documents = Self.documents
        let document = try #require(try documents.openUntitledDocumentAndDisplay(true) as? GonzoDocument)
        defer { document.close() }
        let controller = try #require(document.windowControllers.first as? EditorWindowController)
        #expect(controller.document === document)
        #expect(controller.window?.isVisible == true)
        #expect(controller.textView.textStorage === document.storage)
        #expect(controller.window?.firstResponder === controller.textView)
    }

    @Test @MainActor func documentRoundTripsUTF8AndRemovesBOM() throws {
        let document = GonzoDocument()
        let text = "# Gonzo\n\nFear, café and 東京 🦇\n"
        try document.read(from: Data(("\u{FEFF}" + text).utf8), ofType: "net.daringfireball.markdown")
        #expect(document.storage.string == text)
        #expect(try document.data(ofType: "net.daringfireball.markdown") == Data(text.utf8))
    }

    @Test @MainActor func invalidUTF8DoesNotReplaceDocument() throws {
        let document = GonzoDocument()
        try document.read(from: Data("Keep this story".utf8), ofType: "public.plain-text")
        #expect(throws: NSError.self) {
            try document.read(from: Data([0xFF, 0xFE]), ofType: "public.plain-text")
        }
        #expect(document.storage.string == "Keep this story")
    }

    @Test func headingHierarchyPreservesSourceAndResetsAfterEditing() throws {
        let document = GonzoDocument()
        let source = "# Title\n\n## A *subtitle*\n\n### Section\n\n#### Topic\n\n##### Detail\n\n###### Label\n\nBody text"
        try document.read(from: Data(source.utf8), ofType: "net.daringfireball.markdown")
        document.makeWindowControllers()
        defer { document.close() }
        let controller = try #require(document.windowControllers.first as? EditorWindowController)
        let storage = document.storage
        let revision = storage.revision
        let count = storage.wordCount
        let highlighter = MarkdownHighlighter(textView: controller.textView)
        highlighter.refreshEditedParagraphs()
        let text = source as NSString
        func font(_ word: String) throws -> NSFont {
            try #require(storage.attribute(.font, at: text.range(of: word).location, effectiveRange: nil) as? NSFont)
        }
        let sizes = try ["Title", "subtitle", "Section", "Topic", "Detail", "Label"].map { try font($0).pointSize }
        for (larger, smaller) in zip(sizes, sizes.dropFirst()) { #expect(larger > smaller) }
        #expect(try font("Label").pointSize >= font("Body").pointSize)
        #expect(try font("subtitle").pointSize == font("A ").pointSize)
        #expect(storage.string == source)
        #expect(storage.revision == revision)
        #expect(storage.wordCount == count)
        storage.replaceCharacters(in: NSRange(location: 0, length: 2), with: "")
        highlighter.refreshEditedParagraphs()
        let formerHeading = try #require(storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(formerHeading.pointSize == highlighter.baseFont.pointSize)
        #expect(!NSFontManager.shared.traits(of: formerHeading).contains(.boldFontMask))
    }

    @Test @MainActor func editorFormattingSupportsUndoAndDocumentChanges() throws {
        _ = NSApplication.shared
        let document = GonzoDocument()
        try document.read(from: Data("Fear and loathing".utf8), ofType: "net.daringfireball.markdown")
        Self.documents.addDocument(document)
        defer { document.close() }
        document.makeWindowControllers()
        let controller = try #require(document.windowControllers.first as? EditorWindowController)
        let editor = controller.textView
        #expect(controller.document === document)
        #expect(controller.window != nil)
        controller.window?.makeFirstResponder(editor)
        let undo = try #require(document.undoManager)
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        editor.setSelectedRange(NSRange(location: 0, length: 4))
        editor.markdownBold(nil)
        undo.endUndoGrouping()
        // NSDocument processes undo-group change notifications on the run loop.
        let deadline = Date(timeIntervalSinceNow: 1)
        while !document.isDocumentEdited && Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        #expect(document.storage.string == "**Fear** and loathing")
        #expect(document.storage.wordCount == 3)
        #expect(document.isDocumentEdited)
        #expect(undo.canUndo)
        undo.undo()
        #expect(document.storage.string == "Fear and loathing")
        #expect(document.storage.wordCount == 3)
        undo.redo()
        #expect(document.storage.string == "**Fear** and loathing")
    }
}
