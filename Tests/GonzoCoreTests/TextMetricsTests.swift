import Foundation
import Testing
import GonzoCore

@Test func indexedMetricsMatchReferenceAfterRandomUnicodeEdits() {
    let source = NSMutableString(string: String(repeating: "café **word** 東京 𐐀 🦇\r\n\n", count: 160))
    let index = TextMetrics(source)
    var seed: UInt64 = 27
    func random(_ maximum: Int) -> Int {
        seed = seed &* 6364136223846793005 &+ 1
        return Int((seed >> 32) % UInt64(maximum))
    }
    let insertions = ["", "fear", " ", "\n", "\r\n", "\u{2028}", " **𐐀** ", "café", "東京", "🦇"]
    for _ in 0..<1000 {
        let start = random(source.length + 1)
        let range = NSRange(location: start, length: random(min(30, source.length - start) + 1))
        let replacement = insertions[random(insertions.count)]
        let finish = index.prepareEdit(in: source, range: range)
        source.replaceCharacters(in: range, with: replacement)
        finish(source, (replacement as NSString).length)
        #expect(index.wordCount == WordCounter.count(source))
        let location = random(source.length + 1)
        let probe = NSRange(location: location, length: random(min(60, source.length - location) + 1))
        #expect(index.paragraphRange(in: source, covering: probe) == Paragraphs.range(in: source, covering: probe))
    }
}

@Test func indexedMetricsHandleUnbrokenWordsAndBlockBoundaries() {
    for text in [String(repeating: "!", count: 1023) + "𐐀", String(repeating: "a", count: 100_000),
                 String(repeating: "!", count: 8192) + "a" + String(repeating: "!", count: 8192)] {
        let source = NSMutableString(string: text)
        let index = TextMetrics(source)
        #expect(index.wordCount == 1)
        let range = NSRange(location: source.length / 2, length: 1)
        let finish = index.prepareEdit(in: source, range: range)
        source.replaceCharacters(in: range, with: " \n ")
        finish(source, 3)
        #expect(index.wordCount == WordCounter.count(source))
        for location in [0, range.location, range.location + 1, source.length] {
            let probe = NSRange(location: location, length: 0)
            #expect(index.paragraphRange(in: source, covering: probe) == Paragraphs.range(in: source, covering: probe))
        }
    }
}
