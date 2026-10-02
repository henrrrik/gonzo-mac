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

    @Test func oversizedReadsKeepExistingText() throws {
        let document = GonzoDocument()
        try document.read(from: Data("Keep this story".utf8), ofType: "public.plain-text")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("large.md")
        let oversized = Data(repeating: 65, count: GonzoDocument.maximumFileBytes + 1)
        try oversized.write(to: url)
        #expect(throws: NSError.self) { try document.read(from: url, ofType: "public.plain-text") }
        #expect(throws: NSError.self) { try document.read(from: oversized, ofType: "public.plain-text") }
        #expect(document.storage.string == "Keep this story")
    }

    private func save(_ document: GonzoDocument, to url: URL, operation: NSDocument.SaveOperationType) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            document.save(to: url, ofType: "net.daringfireball.markdown", for: operation) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    @Test func safeSaveAutosaveAndRevertOnDisk() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("story.md")
        let document = GonzoDocument()
        Self.documents.addDocument(document)
        defer { document.close() }
        document.fileType = "net.daringfireball.markdown"
        try document.read(from: Data("First draft 🦇".utf8), ofType: document.fileType!)
        document.updateChangeCount(.changeDone)
        try await save(document, to: url, operation: .saveAsOperation)
        #expect(try String(contentsOf: url, encoding: .utf8) == "First draft 🦇")
        #expect(!document.isDocumentEdited)
        document.storage.replaceCharacters(in: NSRange(location: 0, length: document.storage.length), with: "Autosaved café")
        document.updateChangeCount(.changeDone)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            document.autosave(withImplicitCancellability: false) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
        #expect(try String(contentsOf: url, encoding: .utf8) == "Autosaved café")
        let reopened = try GonzoDocument(contentsOf: url, ofType: "net.daringfireball.markdown")
        defer { reopened.close() }
        #expect(reopened.storage.string == "Autosaved café")
        try Data("Edited externally".utf8).write(to: url, options: .atomic)
        try document.revert(toContentsOf: url, ofType: "net.daringfireball.markdown")
        #expect(document.storage.string == "Edited externally")
        #expect(!document.isDocumentEdited)
    }

    @Test func recoveryLoadsAutosavedContentsInsteadOfOriginal() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("original.md")
        let recovery = directory.appendingPathComponent("recovery.md")
        try Data("Original".utf8).write(to: original)
        let document = try GonzoDocument(contentsOf: original, ofType: "net.daringfireball.markdown")
        Self.documents.addDocument(document)
        defer { document.close() }
        document.storage.replaceCharacters(in: NSRange(location: 0, length: document.storage.length), with: "Recovered story 東京")
        document.updateChangeCount(.changeDone)
        try document.writeSafely(to: recovery, ofType: "net.daringfireball.markdown", for: .saveToOperation)
        #expect(try String(contentsOf: original, encoding: .utf8) == "Original")
        let restored = try GonzoDocument(for: original, withContentsOf: recovery, ofType: "net.daringfireball.markdown")
        defer { restored.close() }
        #expect(restored.storage.string == "Recovered story 東京")
        #expect(restored.isDocumentEdited)
        let untitled = try GonzoDocument(for: nil, withContentsOf: recovery, ofType: "net.daringfireball.markdown")
        defer { untitled.close() }
        #expect(untitled.fileURL == nil)
        #expect(untitled.storage.string == "Recovered story 東京")
        #expect(untitled.isDocumentEdited)
        let missing = directory.appendingPathComponent("missing-original.md")
        let orphan = try GonzoDocument(for: missing, withContentsOf: recovery, ofType: "net.daringfireball.markdown")
        defer { orphan.close() }
        #expect(orphan.storage.string == "Recovered story 東京")
        #expect(orphan.isDocumentEdited)
        Self.documents.addDocument(restored)
        try await save(restored, to: original, operation: .saveOperation)
        #expect(try String(contentsOf: original, encoding: .utf8) == "Recovered story 東京")
    }

    @Test func externalChangesAreNotOverwrittenAndSaveFailureRetainsEdits() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("story.md")
        try Data("Original".utf8).write(to: url)
        let document = try GonzoDocument(contentsOf: url, ofType: "net.daringfireball.markdown")
        Self.documents.addDocument(document)
        defer { document.close() }
        document.storage.replaceCharacters(in: NSRange(location: 0, length: document.storage.length), with: "Local edits")
        document.updateChangeCount(.changeDone)
        try Data("External edits".utf8).write(to: url, options: .atomic)
        do {
            try await save(document, to: url, operation: .saveOperation)
            Issue.record("A conflicting save should fail")
        } catch { }
        #expect(try String(contentsOf: url, encoding: .utf8) == "External edits")
        #expect(document.storage.string == "Local edits")
        #expect(document.isDocumentEdited)
        let copy = directory.appendingPathComponent("local.md")
        try await save(document, to: copy, operation: .saveAsOperation)
        #expect(try String(contentsOf: copy, encoding: .utf8) == "Local edits")
        document.storage.replaceCharacters(in: NSRange(location: 0, length: document.storage.length), with: "Still unsaved")
        document.updateChangeCount(.changeDone)
        do {
            try await save(document, to: copy.appendingPathComponent("child.md"), operation: .saveAsOperation)
            Issue.record("Saving below a regular file should fail")
        } catch { }
        #expect(document.storage.string == "Still unsaved")
        #expect(document.isDocumentEdited)
        #expect(document.fileURL == copy)
        #expect(try String(contentsOf: copy, encoding: .utf8) == "Local edits")
    }

    @Test func oversizedPasteIsRejectedBeforeStorageChanges() {
        let storage = EditorStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer()
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        let editor = WriterTextView(frame: .zero, textContainer: container)
        let oversized = String(repeating: "a", count: GonzoDocument.maximumFileBytes + 1)
        #expect(!editor.shouldChangeText(in: NSRange(location: 0, length: 0), replacementString: oversized))
        #expect(!editor.shouldChangeText(inRanges: [NSValue(range: NSRange(location: 0, length: 0))], replacementStrings: [oversized]))
        #expect(storage.length == 0)
        #expect(storage.utf8Count == 0)
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
