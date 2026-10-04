import AppKit
import Testing
import GonzoCore
import Darwin
@testable import Gonzo

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["GONZO_PERFORMANCE_TESTS"] == "1")) @MainActor
struct PerformanceTests {
    private func footprint(_ label: String) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        if result == KERN_SUCCESS { print("REVIEW footprint \(label): \(Double(info.phys_footprint) / 1048576) MiB") }
    }
    private func measure(_ label: String, _ work: () throws -> Void) rethrows {
        let start = ContinuousClock.now
        try work()
        let d = start.duration(to: .now).components
        let milliseconds = Double(d.seconds) * 1000 + Double(d.attoseconds) / 1e15
        print("REVIEW \(label): \(milliseconds) ms")
    }

    @Test func editorWorkloads() throws {
        _ = NSApplication.shared
        footprint("AppKit/test harness baseline")
        let paragraph = "# Gonzo\n\nA fast editor keeps the story moving. **Fear and loathing**, in plain text.\n\n"
        for repetitions in [600, 6000, 60000, 190000] {
            let text = String(repeating: paragraph, count: repetitions)
            let document = GonzoDocument()
            defer { document.close() }
            let bytes = text.utf8.count
            try measure("\(bytes) read") {
                try document.read(from: Data(text.utf8), ofType: "net.daringfireball.markdown")
            }
            measure("\(bytes) create/show window") {
                document.makeWindowControllers()
                document.showWindows()
            }
            footprint("\(bytes) after window")
            let controller = try #require(document.windowControllers.first as? EditorWindowController)
            let view = controller.textView
            let window = try #require(controller.window)
            let middle = document.storage.length / 2
            measure("\(bytes) scroll middle") {
                view.scrollRangeToVisible(NSRange(location: middle, length: 0))
            }
            measure("\(bytes) 10 native edits") {
                for _ in 0..<5 {
                    view.insertText("x", replacementRange: NSRange(location: middle, length: 0))
                    view.insertText("", replacementRange: NSRange(location: middle, length: 1))
                }
            }
            measure("\(bytes) 10 wrap resizes") {
                for width: CGFloat in [480, 1060, 480, 1060, 480, 1060, 480, 1060, 480, 1060] {
                    window.setContentSize(NSSize(width: width, height: 700))
                    window.contentView?.layoutSubtreeIfNeeded()
                }
            }
            let undo = try #require(document.undoManager)
            undo.removeAllActions()
            undo.groupsByEvent = false
            let pasted = EditorCommands.normalize(String(repeating: "Pasted café\r\n", count: 100))
            measure("\(bytes) multiline paste/undo/redo") {
                undo.beginUndoGrouping()
                view.insertText(pasted, replacementRange: NSRange(location: middle, length: 0))
                undo.endUndoGrouping()
                undo.undo()
                undo.redo()
                undo.undo()
            }
            #expect(document.storage.string == text)
            #expect(document.storage.wordCount == WordCounter.count(text as NSString))
            if repetitions == 600 {
                try measure("\(bytes) create native print layout") {
                    _ = try document.printOperation(withSettings: [:])
                }
            }
            footprint("\(bytes) after edits and resizing")
            measure("\(bytes) 1000 insertion attribute updates") {
                for _ in 0..<1000 { view.updateInsertionAttributes() }
            }
            measure("\(bytes) serialize") { _ = try? document.data(ofType: "net.daringfireball.markdown") }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
            defer { try? FileManager.default.removeItem(at: url) }
            document.fileType = "net.daringfireball.markdown"
            try measure("\(bytes) safe saveAs") { try document.writeSafely(to: url, ofType: document.fileType!, for: .saveAsOperation) }
            document.fileURL = url
            try measure("\(bytes) safe save/conflict check") { try document.writeSafely(to: url, ofType: document.fileType!, for: .saveOperation) }
        }
        for bytes in [100_000, 1_000_000, 5_000_000] {
            let text = String(repeating: "word ", count: bytes / 5)
            let storage = EditorStorage()
            storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: text)
            measure("\(bytes) single-paragraph 10 storage edits") {
                for _ in 0..<5 {
                    let p = storage.length / 2
                    storage.replaceCharacters(in: NSRange(location: p, length: 0), with: "x")
                    storage.replaceCharacters(in: NSRange(location: p, length: 1), with: "")
                }
            }
            measure("\(bytes) single-paragraph styling scan") { _ = Markdown.spans(in: text) }
            measure("\(bytes) single-paragraph 10 word-count scans") {
                for _ in 0..<10 { _ = WordCounter.count(storage.source) }
            }
        }
        let document = GonzoDocument()
        defer { document.close() }
        try document.read(from: Data(String(repeating: "word ", count: 200_000).utf8), ofType: "net.daringfireball.markdown")
        document.makeWindowControllers()
        document.showWindows()
        let controller = try #require(document.windowControllers.first as? EditorWindowController)
        let view = controller.textView
        measure("1000000 single-paragraph 2 native edits") {
            view.insertText("x", replacementRange: NSRange(location: 500_000, length: 0))
            view.insertText("", replacementRange: NSRange(location: 500_000, length: 1))
        }
        view.delegate = nil
        view.enclosingScrollView?.contentView.postsBoundsChangedNotifications = false
        measure("1000000 single-paragraph 2 native edits without highlighting callbacks") {
            view.insertText("x", replacementRange: NSRange(location: 500_000, length: 0))
            view.insertText("", replacementRange: NSRange(location: 500_000, length: 1))
        }
        view.delegate = controller
        view.enclosingScrollView?.contentView.postsBoundsChangedNotifications = true
        footprint("after long-paragraph native edits")
    }

    // Fallback fonts split CJK and emoji text into many attribute runs, and every
    // native edit fixes attributes. Compare how per-keystroke time scales with size.
    @Test func nonASCIITypingBenchmark() throws {
        _ = NSApplication.shared
        let paragraph = "## 東京の夜\n\nFear and loathing 🦇 in 東京, **café** and *naïve* prose ✍️.\n\n"
        for repetitions in [1_000, 10_000] {
            let text = String(repeating: paragraph, count: repetitions)
            let bytes = text.utf8.count
            try autoreleasepool {
                let document = GonzoDocument()
                defer { document.close() }
                try document.read(from: Data(text.utf8), ofType: "net.daringfireball.markdown")
                document.makeWindowControllers()
                document.showWindows()
                let controller = try #require(document.windowControllers.first as? EditorWindowController)
                let view = controller.textView
                let window = try #require(controller.window)
                let middle = document.storage.length / 2
                view.scrollRangeToVisible(NSRange(location: middle, length: 0))
                window.display()
                for run in ["cold", "warm"] {
                    measure("\(bytes) non-ASCII 10 native keystrokes with display (\(run))") {
                        for offset in 0..<10 {
                            autoreleasepool {
                                view.insertText("x", replacementRange: NSRange(location: middle + offset, length: 0))
                                window.display()
                            }
                        }
                    }
                }
                #expect(document.storage.length == (text as NSString).length + 20)
            }
        }
    }

    @Test func windowLifetimeFootprint() throws {
        _ = NSApplication.shared
        footprint("fresh lifecycle baseline")
        for iteration in 1...5 {
            weak var survivingDocument: GonzoDocument?
            weak var survivingController: EditorWindowController?
            weak var survivingView: WriterTextView?
            weak var survivingStorage: EditorStorage?
            try autoreleasepool {
                let document = GonzoDocument()
                survivingDocument = document
                survivingStorage = document.storage
                defer { document.close() }
                try document.read(from: Data(String(repeating: "word ", count: 200_000).utf8), ofType: "net.daringfireball.markdown")
                document.makeWindowControllers()
                document.showWindows()
                let view = try #require((document.windowControllers.first as? EditorWindowController)?.textView)
                survivingController = document.windowControllers.first as? EditorWindowController
                survivingView = view
                view.insertText("x", replacementRange: NSRange(location: 500_000, length: 0))
                footprint("lifecycle \(iteration) open/edited")
            }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 1))
            footprint("lifecycle \(iteration) after close/autorelease pool")
            #expect(survivingDocument == nil)
            #expect(survivingStorage == nil)
            print("REVIEW lifecycle retained objects \(iteration): document=\(survivingDocument != nil), controller=\(survivingController != nil), view=\(survivingView != nil), storage=\(survivingStorage != nil)")
        }
    }
}
