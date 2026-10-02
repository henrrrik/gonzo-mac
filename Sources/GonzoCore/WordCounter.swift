import Foundation

public enum WordCounter {
    private static let wordCharacters = CharacterSet.alphanumerics.subtracting(.nonBaseCharacters)
    /// Whitespace-separated tokens containing a letter or number; Markdown-only
    /// tokens and punctuation don't count. Works directly on storage's UTF-16 view.
    public static func count(_ text: NSString, range: NSRange? = nil) -> Int {
        let range = range ?? NSRange(location: 0, length: text.length)
        let whitespace = NSCharacterSet.whitespacesAndNewlines as NSCharacterSet
        let letters = wordCharacters as NSCharacterSet
        var count = 0
        var inWord = false
        for index in range.location..<NSMaxRange(range) {
            let character = text.character(at: index)
            if whitespace.characterIsMember(character) {
                inWord = false
            } else if !inWord && letters.characterIsMember(character) {
                count += 1
                inWord = true
            } else if !inWord && (0xD800...0xDBFF).contains(character), index + 1 < NSMaxRange(range) {
                let low = text.character(at: index + 1)
                if (0xDC00...0xDFFF).contains(low) {
                    let scalar = UInt32(character - 0xD800) * 0x400 + UInt32(low - 0xDC00) + 0x10000
                    if letters.longCharacterIsMember(scalar) {
                        count += 1
                        inWord = true
                    }
                }
            }
        }
        return count
    }
}
