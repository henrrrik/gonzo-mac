import AppKit
import CryptoKit
import GonzoCore

@MainActor
@objc(GonzoDocument)
final class GonzoDocument: NSDocument {
    nonisolated static let maximumFileBytes = 16 * 1024 * 1024

    nonisolated static var oversizedFileError: NSError {
        NSError(domain: NSCocoaErrorDomain, code: NSFileReadTooLargeError, userInfo: [
            NSLocalizedDescriptionKey: "This document exceeds Gonzo’s 16 MB limit.",
            NSLocalizedRecoverySuggestionErrorKey: "Split it into smaller files before opening it in Gonzo."
        ])
    }
    let storage = EditorStorage()
    private var onDiskDigest: SHA256.Digest?
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

    convenience init(for url: URL?, withContentsOf contentsURL: URL, ofType typeName: String) throws {
        try self.init(contentsOf: contentsURL, ofType: typeName)
        fileURL = url
        autosavedContentsFileURL = contentsURL
        if let url { fileModificationDate = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
        if url != contentsURL { updateChangeCount(.changeReadOtherContents) }
        // Recovery contents differ from the original file by design. Compare
        // subsequent saves against the original as it exists when reopening.
        if let url, let original = try? Self.boundedData(from: url) {
            onDiskDigest = SHA256.hash(data: original)
        } else { onDiskDigest = nil }
    }

    override func makeWindowControllers() {
        let controller = EditorWindowController(document: self)
        addWindowController(controller)
    }

    override func read(from url: URL, ofType typeName: String) throws {
        let data = try Self.boundedData(from: url)
        try read(from: data, ofType: typeName)
        MainActor.assumeIsolated { onDiskDigest = SHA256.hash(data: data) }
    }

    private nonisolated static func boundedData(from url: URL) throws -> Data {
        guard url.isFileURL, try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnsupportedSchemeError,
                          userInfo: [NSLocalizedDescriptionKey: "Gonzo opens regular local files."])
        }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var data = Data()
        // Bound actual bytes read, including files that grow after opening.
        while let chunk = try file.read(upToCount: min(256 * 1024, Self.maximumFileBytes + 1 - data.count)), !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= Self.maximumFileBytes else { throw Self.oversizedFileError }
        }
        return data
    }

    override func read(from data: Data, ofType typeName: String) throws {
        guard data.count <= Self.maximumFileBytes else { throw Self.oversizedFileError }
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

    override func write(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType, originalContentsURL: URL?) throws {
        try MainActor.assumeIsolated {
            if saveOperation == .saveOperation || saveOperation == .autosaveInPlaceOperation,
               let onDiskDigest, let originalContentsURL {
                guard SHA256.hash(data: try Self.boundedData(from: originalContentsURL)) == onDiskDigest else {
                    throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteFileExistsError, userInfo: [
                        NSLocalizedDescriptionKey: "The file changed outside Gonzo. Your edits have not overwritten it.",
                        NSLocalizedRecoverySuggestionErrorKey: "Use Save As to keep your edits in another file, or Revert to Saved to load the external changes."
                    ])
                }
            }
            try super.write(to: url, ofType: typeName, for: saveOperation, originalContentsURL: originalContentsURL)
        }
    }

    override func writeSafely(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType) throws {
        try super.writeSafely(to: url, ofType: typeName, for: saveOperation)
        if saveOperation != .saveToOperation && saveOperation != .autosaveElsewhereOperation {
            MainActor.assumeIsolated { onDiskDigest = SHA256.hash(data: Data(storage.string.utf8)) }
        }
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
