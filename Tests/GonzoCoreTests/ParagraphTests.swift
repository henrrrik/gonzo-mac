import Foundation
import Testing
import GonzoCore

@Test func localParagraphScanMatchesFoundation() {
    for input in ["", "hello", "one\ntwo\n", "one\n\ntwo\nthree", "one\r\ntwo\r\n", "one\u{2029}two"] {
        let text = input as NSString
        for start in 0...text.length {
            for end in start...text.length {
                let range = NSRange(location: start, length: end - start)
                #expect(Paragraphs.range(in: text, covering: range) == text.paragraphRange(for: range))
            }
        }
    }
}
