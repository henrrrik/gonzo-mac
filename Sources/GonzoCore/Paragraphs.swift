import Foundation

public enum Paragraphs {
    private static func isBreak(_ character: unichar) -> Bool {
        character == 10 || character == 13 || character == 0x2028 || character == 0x2029
    }

    /// NSString's Foundation paragraphRange may materialize the entire string
    /// when it is an attributed-string proxy. Scan only neighboring characters.
    public static func range(in text: NSString, covering range: NSRange) -> NSRange {
        var start = range.location
        var end = NSMaxRange(range)
        // Treat CRLF as a single boundary even when the caret is between them.
        if start > 0, start < text.length, text.character(at: start) == 10, text.character(at: start - 1) == 13 {
            start -= 1
        }
        while start > 0 && !isBreak(text.character(at: start - 1)) { start -= 1 }
        if end > 0 && range.length > 0 && isBreak(text.character(at: end - 1)) {
            if end < text.length, text.character(at: end - 1) == 13, text.character(at: end) == 10 { end += 1 }
        } else {
            while end < text.length && !isBreak(text.character(at: end)) { end += 1 }
            if end < text.length {
                let delimiter = text.character(at: end)
                end += 1
                if delimiter == 13, end < text.length, text.character(at: end) == 10 { end += 1 }
            }
        }
        return NSRange(location: start, length: end - start)
    }
}
