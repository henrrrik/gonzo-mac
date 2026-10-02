import AppKit
import GonzoCore

@MainActor
@objc(GonzoDocument)
final class GonzoDocument: NSDocument {
    let storage = EditorStorage()
    private var editorController: EditorWindowController? { windowControllers.first as? EditorWindowController }

    // AppKit provides coordinated safe saves, recovery of untitled drafts,
    // document versions and conflict handling when another app changes a file.
    override nonisolated class var autosavesInPlace: Bool { true }
    override nonisolated class var autosavesDrafts: Bool { true }
    override nonisolated class var preservesVersions: Bool { true }

    override init() {
        super.init()
        hasUndoManager = true
    }

    override func makeWindowControllers() {
        let controller = EditorWindowController(document: self)
        addWindowController(controller)
    }

    override func read(from data: Data, ofType typeName: String) throws {
        guard var text = String(data: data, encoding: .utf8) else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadInapplicableStringEncodingError,
                          userInfo: [NSLocalizedDescriptionKey: "Gonzo opens UTF-8 Markdown and plain text files."])
        }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        // NSDocument reads on the main thread unless concurrent reading is
        // explicitly enabled; Gonzo deliberately keeps one owner for storage.
        MainActor.assumeIsolated {
            storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: text)
            editorController?.reloadFromDocument()
        }
    }

    override func data(ofType typeName: String) throws -> Data {
        MainActor.assumeIsolated { Data(storage.string.utf8) }
    }

    override func printOperation(withSettings printSettings: [NSPrintInfo.AttributeKey: Any]) throws -> NSPrintOperation {
        let info = printInfo.copy() as! NSPrintInfo
        info.dictionary().addEntries(from: printSettings)
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        let width = info.paperSize.width - info.leftMargin - info.rightMargin
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        text.isRichText = false
        text.string = storage.string
        text.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        text.textColor = .black
        text.textContainerInset = NSSize(width: 0, height: 0)
        text.textContainer?.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        text.layoutManager?.ensureLayout(for: text.textContainer!)
        text.setFrameSize(NSSize(width: width, height: max(100, text.layoutManager!.usedRect(for: text.textContainer!).height)))
        return NSPrintOperation(view: text, printInfo: info)
    }
}
