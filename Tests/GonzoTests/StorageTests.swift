import AppKit
import Foundation
import Testing
@testable import Gonzo
import GonzoCore

@Test func incrementalCountAcrossParagraphBoundaries() {
    let storage = EditorStorage()
    storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "one\n\ntwo three\nlast")
    #expect(storage.wordCount == 4)
    storage.replaceCharacters(in: NSRange(location: 3, length: 2), with: "")
    #expect(storage.wordCount == 3)
    storage.replaceCharacters(in: NSRange(location: 1, length: 5), with: " brave\nnew ")
    #expect(storage.wordCount == WordCounter.count(storage.source))
    storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: "")
    #expect(storage.wordCount == 0)
}

@Test func incrementalCountMatchesFullScanForRandomEdits() {
    let storage = EditorStorage()
    var seed: UInt64 = 42
    func random(_ maximum: Int) -> Int {
        seed = seed &* 6364136223846793005 &+ 1
        return Int((seed >> 32) % UInt64(maximum))
    }
    let insertions = ["fear", " ", "\n", "\n\n", " **story** ", "> ", "café"]
    for _ in 0..<500 {
        let start = random(storage.length + 1)
        let length = random(min(8, storage.length - start) + 1)
        storage.replaceCharacters(in: NSRange(location: start, length: length), with: insertions[random(insertions.count)])
        #expect(storage.wordCount == WordCounter.count(storage.source))
        #expect(storage.utf8Count == storage.string.utf8.count)
    }
}

@Test func stylingDoesNotChangeRevisionOrWordCount() {
    let storage = EditorStorage()
    storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "fear and loathing")
    let revision = storage.revision
    storage.addAttribute(.foregroundColor, value: NSColor.red, range: NSRange(location: 0, length: 4))
    #expect(storage.wordCount == 3)
    #expect(storage.revision == revision)
}

@Test func deletingSingleNewlineCountsJoinedWordOnce() {
    let storage = EditorStorage()
    storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "one\ntwo\nthree")
    storage.replaceCharacters(in: NSRange(location: 3, length: 1), with: "")
    #expect(storage.string == "onetwo\nthree")
    #expect(storage.wordCount == 2)
}

@Test func largeDocumentEditingBenchmark() {
    let storage = EditorStorage()
    let paragraph = "# Gonzo\n\nA fast editor keeps the story moving. **Fear and loathing**, in plain text.\n\n"
    let fixture = String(repeating: paragraph, count: 60_000)
    storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: fixture)
    let clock = ContinuousClock()
    let duration = clock.measure {
        for _ in 0..<500 {
            let range = NSRange(location: storage.length / 2, length: 0)
            storage.replaceCharacters(in: range, with: "x")
            storage.replaceCharacters(in: NSRange(location: range.location, length: 1), with: "")
        }
    }
    #expect(storage.wordCount == WordCounter.count(fixture as NSString))
    print("Gonzo benchmark: 1,000 edits in \(fixture.utf8.count) bytes: \(duration)")
}
