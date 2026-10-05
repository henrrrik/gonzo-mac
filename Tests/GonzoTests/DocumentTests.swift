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

    @Test func horizontalResizingReflowsTextWithoutLosingContent() throws {
        let document = try #require(try Self.documents.openUntitledDocumentAndDisplay(true) as? GonzoDocument)
        defer { document.close() }
        let controller = try #require(document.windowControllers.first as? EditorWindowController)
        let window = try #require(controller.window)
        let view = controller.textView
        let container = try #require(view.textContainer)
        let layout = try #require(view.layoutManager)
        let text = String(repeating: "Words wrap across the writing column. ", count: 40)
        view.insertText(text, replacementRange: NSRange(location: 0, length: 0))
        view.setSelectedRange(NSRange(location: 0, length: 0))
        var heights: [CGFloat] = []
        for width: CGFloat in [1100, 480, 860, 600, 1100] {
            window.setContentSize(NSSize(width: width, height: 700))
            window.contentView?.layoutSubtreeIfNeeded()
            layout.ensureLayout(for: container)
            let scroll = try #require(view.enclosingScrollView)
            #expect(abs(view.frame.width - scroll.contentSize.width) < 1)
            #expect(abs(container.containerSize.width - (view.frame.width - 2 * view.textContainerInset.width)) < 1)
            let used = layout.usedRect(for: container)
            #expect(used.width > 0 && used.width <= container.containerSize.width + 1)
            #expect(view.frame.height >= used.maxY + view.textContainerInset.height)
            heights.append(used.height)
            #expect(document.storage.string == text)
            #expect(view.selectedRange() == NSRange(location: 0, length: 0))
        }
        #expect(heights[1] > heights[0])
        #expect(abs(heights[4] - heights[0]) < 1)
    }

    @Test func mouseInsertionMatchesRenderedGlyphsAfterResizeAndScroll() throws {
        let document = try #require(try Self.documents.openUntitledDocumentAndDisplay(true) as? GonzoDocument)
        defer { document.close() }
        let controller = try #require(document.windowControllers.first as? EditorWindowController)
        let window = try #require(controller.window)
        let view = controller.textView
        let layout = try #require(view.layoutManager)
        let container = try #require(view.textContainer)
        let text = "# Heading\n\n" + String(repeating: "## Section\n\nA paragraph with **bold** and *italic* words that wraps onto several lines.\n\n", count: 20)
        view.insertText(text, replacementRange: NSRange(location: 0, length: 0))
        for width: CGFloat in [1060, 480, 800, 1060] {
            window.setContentSize(NSSize(width: width, height: 500))
            window.contentView?.layoutSubtreeIfNeeded()
            for index in [0, 150, 700, 1200] {
                view.scrollRangeToVisible(NSRange(location: index, length: 1))
                layout.ensureLayout(for: container)
                let glyph = layout.glyphIndexForCharacter(at: index)
                let rect = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
                let point = NSPoint(x: rect.minX + rect.width * 0.2 + view.textContainerOrigin.x,
                                    y: rect.midY + view.textContainerOrigin.y)
                #expect(view.characterIndexForInsertion(at: point) == index)
            }
        }
    }

    @Test func highlightingPreservesSelectionAffinityDuringDrag() throws {
        let document = try #require(try Self.documents.openUntitledDocumentAndDisplay(true) as? GonzoDocument)
        defer { document.close() }
        let controller = try #require(document.windowControllers.first as? EditorWindowController)
        let view = controller.textView
        view.insertText("# Heading\n\nSelect these words with the mouse.", replacementRange: NSRange(location: 0, length: 0))
        let selection = NSRange(location: 12, length: 15)
        view.setSelectedRange(selection, affinity: .upstream, stillSelecting: true)
        view.selectionGranularity = .selectByWord
        let highlighter = MarkdownHighlighter(textView: view)
        highlighter.refreshVisible()
        #expect(view.selectedRange() == selection)
        #expect(view.selectionAffinity == .upstream)
        #expect(view.selectionGranularity == .selectByWord)
    }

    @Test func insertionFontFollowsHeadingBodyAndTextSizeChanges() throws {
        let document = try #require(try Self.documents.openUntitledDocumentAndDisplay(true) as? GonzoDocument)
        defer { document.close() }
        let controller = try #require(document.windowControllers.first as? EditorWindowController)
        let view = controller.textView
        #expect(view.font?.pointSize == 13)
        view.insertText("# Heading\n\nBody text\n", replacementRange: NSRange(location: 0, length: 0))
        func expectInsertionFont(at index: Int, size: CGFloat) {
            view.setSelectedRange(NSRange(location: index, length: 0))
            let font = view.typingAttributes[.font] as? NSFont
            #expect(font?.pointSize == size)
        }
        expectInsertionFont(at: 5, size: 13 * 1.75)
        expectInsertionFont(at: 15, size: 13)
        expectInsertionFont(at: view.string.utf16.count, size: 13)
        view.setSelectedRange(NSRange(location: 5, length: 0))
        controller.biggerText(nil)
        #expect((view.typingAttributes[.font] as? NSFont)?.pointSize == 14 * 1.75)
        controller.resetTextSize(nil)
        #expect((view.typingAttributes[.font] as? NSFont)?.pointSize == 13 * 1.75)
        view.setSelectedRange(NSRange(location: 0, length: view.string.utf16.count))
        view.insertText("", replacementRange: view.selectedRange())
        #expect((view.typingAttributes[.font] as? NSFont)?.pointSize == 13)
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

    @Test func editsAndTextSizeStyleTheViewportAndScrolledInText() throws {
        let document = try #require(try Self.documents.openUntitledDocumentAndDisplay(true) as? GonzoDocument)
        defer { document.close() }
        let controller = try #require(document.windowControllers.first as? EditorWindowController)
        let view = controller.textView
        let storage = document.storage
        let layout = try #require(view.layoutManager)
        let container = try #require(view.textContainer)
        func size(at location: Int) -> CGFloat? {
            (storage.attribute(.font, at: location, effectiveRange: nil) as? NSFont)?.pointSize
        }
        func expectViewportStyled(heading: CGFloat, body: CGFloat) {
            let glyphs = layout.glyphRange(forBoundingRect: view.visibleRect, in: container)
            let visible = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            let source = storage.source
            source.enumerateSubstrings(in: visible, options: .byParagraphs) { paragraph, range, _, _ in
                guard let paragraph, !paragraph.isEmpty else { return }
                let expected = paragraph.hasPrefix("# ") ? heading : body
                #expect(size(at: range.location + range.length - 1) == expected, "\(paragraph)")
            }
        }
        // A bulk paste styles what is in view; the far end is styled once scrolled to.
        view.insertText(String(repeating: "# Heading\n\nBody text\n\n", count: 2000), replacementRange: NSRange(location: 0, length: 0))
        let last = storage.source.range(of: "# Heading", options: .backwards).location
        view.scrollRangeToVisible(NSRange(location: last, length: 0))
        expectViewportStyled(heading: 13 * 1.75, body: 13)
        // One change replacing several ranges, as Replace All does, restyles each.
        // Mid-document, so shrinking headings cannot move the viewport and
        // trigger a full viewport refresh that would mask a missed range.
        let first = storage.source.range(of: "# Heading", range: NSRange(location: storage.length / 2, length: storage.length / 2)).location
        let second = storage.source.range(of: "# Heading", range: NSRange(location: first + 1, length: storage.length - first - 1)).location
        view.scrollRangeToVisible(NSRange(location: second, length: 0))
        let ranges = [NSRange(location: first, length: 2), NSRange(location: second, length: 2)]
        #expect(view.shouldChangeText(inRanges: ranges.map { NSValue(range: $0) }, replacementStrings: ["", ""]))
        storage.beginEditing()
        for range in ranges.reversed() { storage.replaceCharacters(in: range, with: "") }
        storage.endEditing()
        view.didChangeText()
        #expect(size(at: first) == 13)
        #expect(size(at: second - 2) == 13)
        // A smaller text size brings more text into view; all of it is restyled.
        for _ in 0..<19 { controller.biggerText(nil) }
        controller.resetTextSize(nil)
        expectViewportStyled(heading: 13 * 1.75, body: 13)
    }

    @Test func revertGivesOffscreenTextTheEditorFontAndColor() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(String(repeating: "A paragraph of body text.\n\n", count: 5000).utf8).write(to: url)
        let document = try #require(try Self.documents.openUntitledDocumentAndDisplay(true) as? GonzoDocument)
        defer { document.close() }
        let controller = try #require(document.windowControllers.first as? EditorWindowController)
        controller.biggerText(nil)
        try document.revert(toContentsOf: url, ofType: "net.daringfireball.markdown")
        // Unstyled text would lay out in a default font, shifting heights while
        // scrolling, and draw without a color that follows the appearance.
        let end = document.storage.length - 1
        let font = document.storage.attribute(.font, at: end, effectiveRange: nil) as? NSFont
        #expect(font?.pointSize == 14)
        #expect(font?.isFixedPitch == true)
        #expect(document.storage.attribute(.foregroundColor, at: end, effectiveRange: nil) as? NSColor == .textColor)
    }

    @Test func restylingUnchangedFallbackTextMakesNoAttributeEdits() throws {
        let document = try #require(try Self.documents.openUntitledDocumentAndDisplay(true) as? GonzoDocument)
        defer { document.close() }
        let controller = try #require(document.windowControllers.first as? EditorWindowController)
        let text = "# 東京 🦇 heading\n\n**太字** and *斜体* with مرحبا\n\n> 引用 ✍️\n\n`コード` [リンク](https://example.com)\n"
        controller.textView.insertText(text, replacementRange: NSRange(location: 0, length: 0))
        final class Counter: NSObject, NSTextStorageDelegate {
            var attributeEdits = 0
            func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                             range: NSRange, changeInLength delta: Int) {
                if editedMask.contains(.editedAttributes) { attributeEdits += 1 }
            }
        }
        // The fallback font chosen while typing can be a distinct, unequal
        // object for the same face as the one chosen for the restyled copy;
        // let one restyle settle that, then every restyle must find the
        // paragraphs equal rather than rewriting and refixing their fonts.
        controller.reloadFromDocument()
        let counter = Counter()
        document.storage.delegate = counter
        defer { document.storage.delegate = nil }
        controller.reloadFromDocument()
        controller.reloadFromDocument()
        #expect(counter.attributeEdits == 0)
        #expect(document.storage.string == text)
    }

    @Test func readingUpwardFromTheEndMatchesEagerFixing() throws {
        let paragraph = "## 東京の夜\n\nFear and loathing 🦇 in 東京, **café** and *naïve* prose ✍️.\n\n"
        let text = String(repeating: paragraph, count: 2000)
        let attributes = MarkdownHighlighter.baseAttributes(fontSize: 13)
        let storage = EditorStorage()
        storage.load(EditorStorage.Prepared(text), attributes: attributes)
        let reference = NSTextStorage(string: text, attributes: attributes)
        reference.fixAttributes(in: NSRange(location: 0, length: reference.length))
        // Read the end first, then step upward: each read fixes a base window
        // below or around unfixed text. Fonts must match eager fixing, and a
        // reported run must not extend over text whose fonts differ.
        for location in stride(from: storage.length - 1, through: 0, by: -3001) {
            var run = NSRange()
            let font = storage.attribute(.font, at: location, effectiveRange: &run) as? NSFont
            #expect(NSLocationInRange(location, run))
            for edge in [run.location, NSMaxRange(run) - 1] {
                #expect(font?.fontName == (reference.attribute(.font, at: edge, effectiveRange: nil) as? NSFont)?.fontName)
            }
        }
        for location in stride(from: 0, to: storage.length, by: 7) {
            let font = storage.attribute(.font, at: location, effectiveRange: nil) as? NSFont
            let expected = reference.attribute(.font, at: location, effectiveRange: nil) as? NSFont
            if font?.fontName != expected?.fontName {
                Issue.record("Font differs at \(location)")
                break
            }
        }
        #expect(storage.string == text)
    }

    @Test func fixingALongParagraphAboveFixedTextMatchesEagerFixing() throws {
        // A long single-line paragraph above text that was already read is
        // fixed in one large call; it must equal fixing everything up front.
        let text = String(repeating: "Line of text\n", count: 3000)
            + String(repeating: "a東🦇b", count: 20_000) + "\n"
            + String(repeating: "x東 🦇 y\n", count: 8000)
        let attributes = MarkdownHighlighter.baseAttributes(fontSize: 13)
        let storage = EditorStorage()
        storage.load(EditorStorage.Prepared(text), attributes: attributes)
        let reference = NSMutableAttributedString(string: text, attributes: attributes)
        reference.fixAttributes(in: NSRange(location: 0, length: reference.length))
        storage.enumerateAttributes(in: NSRange(location: 140_000, length: storage.length - 140_000)) { _, _, _ in }
        storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) { _, _, _ in }
        #expect(storage.attributedSubstring(from: NSRange(location: 0, length: storage.length)).isEqual(to: reference))
        #expect(storage.string == text)
    }

    @Test func deferredAttributeFixingFixesReadParagraphsAndClipsRuns() throws {
        let storage = EditorStorage()
        // Filler wider than one fix window keeps the CJK paragraph pending
        // after the first read.
        let text = "Plain words\n" + String(repeating: "Filler line\n", count: 3000) + "東京 🦇 text\nMore plain words"
        storage.load(EditorStorage.Prepared(text), attributes: MarkdownHighlighter.baseAttributes(fontSize: 13))
        let revision = storage.revision
        func expectDrawable(_ word: String) throws {
            let source = storage.source
            let location = source.range(of: word).location
            let font = try #require(storage.attribute(.font, at: location, effectiveRange: nil) as? NSFont)
            var unit = source.character(at: location)
            var glyph = CGGlyph()
            #expect(CTFontGetGlyphsForCharacters(font, &unit, &glyph, 1))
        }
        // A run read from fixed text must not extend over text not yet fixed,
        // or layout would draw that text with fonts that lack its glyphs.
        var run = NSRange()
        _ = storage.attributes(at: 0, effectiveRange: &run)
        #expect(NSMaxRange(run) <= (text as NSString).range(of: "東京").location)
        try expectDrawable("東京")
        // Pending fixes follow edits made before and inside unfixed text.
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "Intro 大阪\n")
        storage.replaceCharacters(in: NSRange(location: storage.length, length: 0), with: "\n京都")
        try expectDrawable("大阪")
        try expectDrawable("京都")
        #expect(storage.string == "Intro 大阪\n" + text + "\n京都")
        #expect(storage.revision == revision + 2)
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
    @Test func concurrentOpenInstallsPreparedTextBeforeCreatingViews() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        defer { try? FileManager.default.removeItem(at: url) }
        let text = String(repeating: "café 東京 🦇\n", count: 10_000)
        try Data(text.utf8).write(to: url)
        let document: GonzoDocument = try await withCheckedThrowingContinuation { continuation in
            Self.documents.openDocument(withContentsOf: url, display: true) { document, _, error in
                if let error { continuation.resume(throwing: error) }
                else if let document = document as? GonzoDocument { continuation.resume(returning: document) }
                else { continuation.resume(throwing: CocoaError(.fileReadUnknown)) }
            }
        }
        defer { document.close() }
        #expect(document.storage.string == text)
        #expect(document.storage.wordCount == 20_000)
        #expect((document.windowControllers.first as? EditorWindowController)?.textView.string == text)
    }

    @Test func backgroundRecoveryTransfersPreparedTextAndOriginalBaseline() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("original.md")
        let recovery = directory.appendingPathComponent("recovery.md")
        try Data("Original".utf8).write(to: original)
        try Data("Recovered café 東京".utf8).write(to: recovery)
        // Transfer a freshly opened document once, as NSDocumentController
        // does. No worker retains or accesses it after this handoff.
        struct Opened: @unchecked Sendable { let document: GonzoDocument }
        let opened = try await Task.detached {
            Opened(document: try GonzoDocument(for: original, withContentsOf: recovery, ofType: "net.daringfireball.markdown"))
        }.value
        let document = opened.document
        Self.documents.addDocument(document)
        defer { document.close() }
        #expect(document.storage.string == "Recovered café 東京")
        #expect(document.storage.wordCount == 3)
        #expect(document.isDocumentEdited)
        try await save(document, to: original, operation: .saveOperation)
        #expect(try String(contentsOf: original, encoding: .utf8) == "Recovered café 東京")
    }

    @Test func asynchronousSaveKeepsSnapshotAndLaterEditsDirty() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        defer { try? FileManager.default.removeItem(at: url) }
        let document = GonzoDocument()
        Self.documents.addDocument(document)
        defer { document.close() }
        document.fileType = "net.daringfireball.markdown"
        let first = String(repeating: "First draft\n", count: 100_000)
        try document.read(from: Data(first.utf8), ofType: document.fileType!)
        document.updateChangeCount(.changeDone)
        let saving = Task { @MainActor in
            try await save(document, to: url, operation: .saveAsOperation)
        }
        // The save request can be queued by AppKit. Wait for its actual
        // snapshot handoff, rather than changing text before saving starts.
        while document.saveGeneration == 0 { await Task.yield() }
        document.storage.replaceCharacters(in: NSRange(location: 0, length: document.storage.length), with: "Later edits")
        document.updateChangeCount(.changeDone)
        try await saving.value
        #expect(try String(contentsOf: url, encoding: .utf8) == first)
        #expect(document.storage.string == "Later edits")
        #expect(document.isDocumentEdited)
        // The conflict baseline must describe the snapshot, not later edits.
        try await save(document, to: url, operation: .saveOperation)
        #expect(try String(contentsOf: url, encoding: .utf8) == "Later edits")
        #expect(!document.isDocumentEdited)
    }

    @Test func openingFollowsSymlinksButRejectsSpecialFilesWithoutBlocking() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("notes.md")
        try Data("# Linked 東京".utf8).write(to: target)
        let link = directory.appendingPathComponent("link.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let document = GonzoDocument()
        try document.read(from: link, ofType: "net.daringfireball.markdown")
        #expect(document.storage.string == "# Linked 東京")
        // A FIFO with no writer would block a plain open forever.
        let fifo = directory.appendingPathComponent("pipe.md")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        let fifoLink = directory.appendingPathComponent("pipe-link.md")
        try FileManager.default.createSymbolicLink(at: fifoLink, withDestinationURL: fifo)
        for url in [fifo, fifoLink, directory] {
            #expect(throws: (any Error).self) { try GonzoDocument().read(from: url, ofType: "net.daringfireball.markdown") }
        }
        #expect(document.storage.string == "# Linked 東京")
    }

    @Test func documentOpenedThroughSymlinkSavesToItsTarget() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("notes.md")
        try Data("Original".utf8).write(to: target)
        let link = directory.appendingPathComponent("link.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let opened = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NSDocument, Error>) in
            Self.documents.openDocument(withContentsOf: link, display: false) { document, _, error in
                if let document { continuation.resume(returning: document) }
                else { continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
            }
        }
        let document = try #require(opened as? GonzoDocument)
        defer { document.close() }
        document.storage.replaceCharacters(in: NSRange(location: 0, length: document.storage.length), with: "Edited")
        document.updateChangeCount(.changeDone)
        try await save(document, to: try #require(document.fileURL), operation: .saveOperation)
        #expect(!document.isDocumentEdited)
        #expect(try String(contentsOf: target, encoding: .utf8) == "Edited")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == target.path)
        // The conflict check still guards the target against external changes.
        try Data("External".utf8).write(to: target)
        document.storage.replaceCharacters(in: NSRange(location: 0, length: document.storage.length), with: "Mine")
        document.updateChangeCount(.changeDone)
        await #expect(throws: (any Error).self) {
            try await save(document, to: try #require(document.fileURL), operation: .saveOperation)
        }
        #expect(try String(contentsOf: target, encoding: .utf8) == "External")
    }

    @Test func typingAfterSaveAndAutosaveStaysDirtyAndUndoesSeparately() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try #require(try Self.documents.openUntitledDocumentAndDisplay(true) as? GonzoDocument)
        defer { document.close() }
        let view = try #require((document.windowControllers.first as? EditorWindowController)?.textView)
        let undo = try #require(document.undoManager)
        // Type through NSTextView's coalescing path, letting each event's undo group close.
        func type(_ text: String) {
            for character in text {
                view.insertText(String(character), replacementRange: view.selectedRange())
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
            }
        }
        type("abc")
        try await save(document, to: url, operation: .saveAsOperation)
        #expect(!document.isDocumentEdited)
        type("def")
        #expect(document.isDocumentEdited)
        #expect(document.hasUnautosavedChanges)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            document.autosave(withImplicitCancellability: false) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        #expect(try String(contentsOf: url, encoding: .utf8) == "abcdef")
        type("ghi")
        #expect(document.hasUnautosavedChanges)
        // Each save point is a separate undo step, so undo returns to saved text.
        undo.undo()
        #expect(document.storage.string == "abcdef")
        undo.undo()
        #expect(document.storage.string == "abc")
    }

    @Test func typingWhileSavesAreQueuedNeverLeavesUnsavedTextClean() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try #require(try Self.documents.openUntitledDocumentAndDisplay(true) as? GonzoDocument)
        defer { document.close() }
        let view = try #require((document.windowControllers.first as? EditorWindowController)?.textView)
        // A large document keeps each write in flight long enough for AppKit to
        // queue the autosave behind the save, then snapshot after more typing.
        view.insertText(String(repeating: "Draft line\n", count: 30_000), replacementRange: NSRange(location: 0, length: 0))
        try await save(document, to: url, operation: .saveAsOperation)
        let finished = SaveCounter()
        func type(_ text: String) {
            for character in text {
                view.insertText(String(character), replacementRange: view.selectedRange())
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
            }
        }
        func waitForSaves(_ count: Int) throws {
            let deadline = Date(timeIntervalSinceNow: 30)
            while finished.count < count {
                try #require(Date() < deadline, "Saves did not complete")
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
            }
        }
        for round in 1...3 {
            type("d")
            document.save(to: url, ofType: "net.daringfireball.markdown", for: .saveOperation) { finished.record($0) }
            document.autosave(withImplicitCancellability: false) { finished.record($0) }
            type("ee")
            try waitForSaves(2 * round)
            // Failed saves would leave the document dirty and pass vacuously.
            #expect(finished.errors.isEmpty)
            let disk = try String(contentsOf: url, encoding: .utf8)
            #expect(disk.filter { $0 == "d" }.count == round)
            #expect(disk == document.storage.string || document.hasUnautosavedChanges)
            type("f")
            #expect(document.hasUnautosavedChanges)
        }
    }

    @Test func closeReleasesDocumentStorageDespiteNativeViewCaching() throws {
        weak var survivingDocument: GonzoDocument?
        weak var survivingStorage: EditorStorage?
        try autoreleasepool {
            let document = GonzoDocument()
            survivingDocument = document
            survivingStorage = document.storage
            try document.read(from: Data(String(repeating: "word ", count: 200_000).utf8), ofType: "net.daringfireball.markdown")
            document.makeWindowControllers()
            let view = try #require((document.windowControllers.first as? EditorWindowController)?.textView)
            view.insertText("x", replacementRange: NSRange(location: 500_000, length: 0))
            document.close()
            #expect(document.storage.layoutManagers.isEmpty)
            #expect(document.undoManager?.canUndo == false)
        }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        #expect(survivingDocument == nil)
        #expect(survivingStorage == nil)
    }

    @Test func paragraphStylingCacheSurvivesEditsAndPlainModeTransitions() throws {
        let document = GonzoDocument()
        try document.read(from: Data("# Title\nBody\n".utf8), ofType: "net.daringfireball.markdown")
        document.makeWindowControllers()
        defer { document.close() }
        let view = try #require((document.windowControllers.first as? EditorWindowController)?.textView)
        let highlighter = MarkdownHighlighter(textView: view)
        highlighter.refreshEditedParagraphs()
        let styled = highlighter.styledParagraphCount
        highlighter.refreshEditedParagraphs()
        #expect(highlighter.styledParagraphCount == styled)
        document.storage.replaceCharacters(in: NSRange(location: 2, length: 0), with: "x")
        highlighter.refreshEditedParagraphs()
        #expect(highlighter.styledParagraphCount == styled + 1)
        document.storage.replaceCharacters(in: NSRange(location: 0, length: document.storage.length), with: "# " + String(repeating: "a", count: 5000))
        highlighter.refreshEditedParagraphs()
        let plainCount = highlighter.styledParagraphCount
        for _ in 0..<10 {
            document.storage.replaceCharacters(in: NSRange(location: 10, length: 0), with: "x")
            highlighter.refreshEditedParagraphs()
        }
        #expect(highlighter.styledParagraphCount == plainCount)
        #expect((document.storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize == 13)
        document.storage.replaceCharacters(in: NSRange(location: 20, length: document.storage.length - 20), with: "")
        highlighter.refreshEditedParagraphs()
        #expect(highlighter.styledParagraphCount == plainCount + 1)
        #expect((document.storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize == 13 * 1.75)
        document.storage.replaceCharacters(in: NSRange(location: 0, length: document.storage.length), with: String(repeating: "A paragraph\n", count: 1000))
        highlighter.refreshEditedParagraphs()
        #expect(highlighter.cachedParagraphCount <= 256)
    }

}

private final class SaveCounter: @unchecked Sendable {
    // AppKit invokes save completion handlers on the main thread.
    private(set) var count = 0
    private(set) var errors: [Error] = []
    func record(_ error: Error?) {
        count += 1
        if let error { errors.append(error) }
    }
}
