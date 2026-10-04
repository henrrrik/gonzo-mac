import AppKit
import CryptoKit
import GonzoCore

// Only prepared load results, immutable save snapshots and the disk baseline cross threads.
// NSTextStorage, layout, undo, and windows remain owned by the main thread.
private final class DocumentIOState: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: EditorStorage.Prepared?
    private var digest: SHA256.Digest?
    private var saveSnapshot: String?
    func stageSave(_ text: String) { lock.lock(); defer { lock.unlock() }; saveSnapshot = text }
    func takeSave() -> String? {
        lock.lock(); defer { lock.unlock() }
        let text = saveSnapshot; saveSnapshot = nil; return text
    }
    func stage(_ value: EditorStorage.Prepared) { lock.lock(); defer { lock.unlock() }; pending = value }
    func takePrepared() -> EditorStorage.Prepared? {
        lock.lock(); defer { lock.unlock() }
        let value = pending; pending = nil; return value
    }
    func baseline() -> SHA256.Digest? { lock.lock(); defer { lock.unlock() }; return digest }
    func setBaseline(_ value: SHA256.Digest?) { lock.lock(); defer { lock.unlock() }; digest = value }
}

private final class MainThreadResult<Value: Sendable>: @unchecked Sendable {
    private let condition = NSCondition()
    private var value: Value?
    func set(_ value: Value) {
        condition.lock(); defer { condition.unlock() }
        self.value = value; condition.broadcast()
    }
    func get() -> Value {
        condition.lock(); defer { condition.unlock() }
        while value == nil { condition.wait() }
        return value!
    }
}

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
    private let editorStorage = EditorStorage()
    private nonisolated let ioState = DocumentIOState()
    private nonisolated let snapshotKey = "Gonzo.SaveSnapshot." + UUID().uuidString
    var storage: EditorStorage {
        if let prepared = ioState.takePrepared() { editorStorage.load(prepared) }
        return editorStorage
    }
    private var editorController: EditorWindowController? { windowControllers.first as? EditorWindowController }
    private(set) var saveGeneration: UInt64 = 0

    // AppKit provides coordinated safe saves, recovery of untitled drafts,
    // document versions and conflict handling when another app changes a file.
    override nonisolated class var autosavesInPlace: Bool { true }
    override nonisolated class var autosavesDrafts: Bool { true }
    override nonisolated class var preservesVersions: Bool { true }
    override nonisolated class func canConcurrentlyReadDocuments(ofType typeName: String) -> Bool { true }
    override func canAsynchronouslyWrite(to url: URL, ofType typeName: String, for operation: NSDocument.SaveOperationType) -> Bool {
        // AppKit asks on the main thread before starting its worker and
        // blocking user interaction. Capture the immutable value here; the
        // worker cannot ask the blocked main thread for NSTextStorage.
        ioState.stageSave(saveSnapshot())
        saveGeneration &+= 1
        return true
    }

    /// NSTextView coalesces typing into one undo action. End it exactly where
    /// the saved text is captured, beside AppKit's saved change token, so later
    /// typing registers a new change instead of joining one already saved.
    /// Ending it earlier, when a save is merely requested, is not enough:
    /// a queued save can snapshot typing that started after the request.
    private func saveSnapshot() -> String {
        for controller in windowControllers { (controller as? EditorWindowController)?.textView.breakUndoCoalescing() }
        return storage.string
    }

    override nonisolated init() {
        // NSDocument's concurrent-open contract initializes fresh documents
        // on its opening queue, despite the SDK's broad MainActor annotation.
        // No UI or mutable model escapes this initializer.
        super.init()
    }

    nonisolated convenience init(for url: URL?, withContentsOf contentsURL: URL, ofType typeName: String) throws {
        self.init()
        try read(from: contentsURL, ofType: typeName)
        onMain {
            self.fileType = typeName
            self.fileURL = url
            self.autosavedContentsFileURL = contentsURL
            if let url { self.fileModificationDate = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
            if url != contentsURL { self.updateChangeCount(.changeReadOtherContents) }
        }
        // Recovery contents differ from the original file by design. Compare
        // subsequent saves against the original as it exists when reopening.
        if let url, let original = try? Self.boundedData(from: url) {
            ioState.setBaseline(SHA256.hash(data: original))
        } else { ioState.setBaseline(nil) }
    }

    override func makeWindowControllers() {
        let controller = EditorWindowController(document: self)
        addWindowController(controller)
    }

    override func close() {
        super.close()
        undoManager?.removeAllActions()
        // A closed text view can remain retained by AppKit. Detach its text
        // network so it cannot keep an entire document and glyph cache alive.
        for layout in editorStorage.layoutManagers { editorStorage.removeLayoutManager(layout) }
    }

    override nonisolated func read(from url: URL, ofType typeName: String) throws {
        let data = try Self.boundedData(from: url)
        try read(from: data, ofType: typeName)
        ioState.setBaseline(SHA256.hash(data: data))
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

    override nonisolated func read(from data: Data, ofType typeName: String) throws {
        guard data.count <= Self.maximumFileBytes else { throw Self.oversizedFileError }
        guard var text = String(data: data, encoding: .utf8) else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadInapplicableStringEncodingError,
                          userInfo: [NSLocalizedDescriptionKey: "Gonzo opens UTF-8 Markdown and plain text files."])
        }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let prepared = EditorStorage.Prepared(text)
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                editorStorage.load(prepared)
                editorController?.reloadFromDocument()
            }
        } else {
            // Concurrent opening has no views yet. Transfer the prepared index
            // once when AppKit hands the document back to the main thread.
            ioState.stage(prepared)
        }
    }

    private nonisolated func onMain<Value: Sendable>(_ work: @escaping @MainActor @Sendable () -> Value) -> Value {
        if Thread.isMainThread { return MainActor.assumeIsolated { work() } }
        let result = MainThreadResult<Value>()
        // Used outside the blocked asynchronous save handoff. AppKit's bridge
        // also cooperates with document activity and file-access waits.
        continueAsynchronousWorkOnMainThread {
            result.set(MainActor.assumeIsolated { work() })
        }
        return result.get()
    }

    override nonisolated func data(ofType typeName: String) throws -> Data {
        if let snapshot = Thread.current.threadDictionary[snapshotKey] as? Data { return snapshot }
        return onMain { Data(self.saveSnapshot().utf8) }
    }

    override nonisolated func write(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType, originalContentsURL: URL?) throws {
        if saveOperation == .saveOperation || saveOperation == .autosaveInPlaceOperation,
           let digest = ioState.baseline(), let originalContentsURL {
            guard SHA256.hash(data: try Self.boundedData(from: originalContentsURL)) == digest else {
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteFileExistsError, userInfo: [
                    NSLocalizedDescriptionKey: "The file changed outside Gonzo. Your edits have not overwritten it.",
                    NSLocalizedRecoverySuggestionErrorKey: "Use Save As to keep your edits in another file, or Revert to Saved to load the external changes."
                ])
            }
        }
        try super.write(to: url, ofType: typeName, for: saveOperation, originalContentsURL: originalContentsURL)
    }

    override nonisolated func writeSafely(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType) throws {
        let text: String
        if !Thread.isMainThread, let pending = ioState.takeSave() { text = pending }
        else { text = onMain { self.saveSnapshot() } }
        let snapshot = Data(text.utf8)
        let dictionary = Thread.current.threadDictionary
        let previous = dictionary[snapshotKey]
        dictionary[snapshotKey] = snapshot
        defer {
            if let previous { dictionary[snapshotKey] = previous }
            else { dictionary.removeObject(forKey: snapshotKey) }
        }
        unblockUserInteraction()
        try super.writeSafely(to: url, ofType: typeName, for: saveOperation)
        if saveOperation != .saveToOperation && saveOperation != .autosaveElsewhereOperation {
            // Hash exactly the bytes that were saved, even if editing resumed
            // while the snapshot was being written. No second serialization.
            ioState.setBaseline(SHA256.hash(data: snapshot))
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
