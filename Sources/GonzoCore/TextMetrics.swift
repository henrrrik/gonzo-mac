import Foundation

/// An implicit treap of small UTF-16 blocks. It stores summaries, not a second
/// copy of the document. Edits rebuild only boundary blocks and inserted text.
/// A prepared index may be handed between threads; mutation has one owner.
public final class TextMetrics: @unchecked Sendable {
    private struct Summary {
        var length = 0
        var words = 0
        var startsSpace = true
        var endsSpace = true
        var hasSpace = false
        var firstWord = false
        var lastWord = false
        var firstBreak: Int?
        var lastBreak: Int?

        static func joined(_ a: Self, _ b: Self) -> Self {
            if a.length == 0 { return b }
            if b.length == 0 { return a }
            let merge = !a.endsSpace && !b.startsSpace
            return Self(length: a.length + b.length,
                        words: a.words + b.words - (merge && a.lastWord && b.firstWord ? 1 : 0),
                        startsSpace: a.startsSpace, endsSpace: b.endsSpace,
                        hasSpace: a.hasSpace || b.hasSpace,
                        firstWord: a.firstWord || (!a.hasSpace && !b.startsSpace && b.firstWord),
                        lastWord: b.lastWord || (!b.hasSpace && !a.endsSpace && a.lastWord),
                        firstBreak: a.firstBreak ?? b.firstBreak.map { a.length + $0 },
                        lastBreak: b.lastBreak.map { a.length + $0 } ?? a.lastBreak)
        }
    }

    private final class Node {
        let priority: UInt64
        let block: Summary
        var total: Summary
        var left: Node?
        var right: Node?
        init(_ block: Summary, priority: UInt64) {
            self.block = block; total = block; self.priority = priority
        }
        func update() { total = .joined(.joined(left?.total ?? Summary(), block), right?.total ?? Summary()) }
    }

    private var root: Node?
    private var seed: UInt64 = 42
    private static let whitespace = CharacterSet.whitespacesAndNewlines
    private static let letters = CharacterSet.alphanumerics.subtracting(.nonBaseCharacters)
    public var wordCount: Int { root?.total.words ?? 0 }

    public init(_ text: NSString = "") { root = build(text, range: NSRange(location: 0, length: text.length)) }

    private func node(_ summary: Summary) -> Node {
        seed = seed &* 6364136223846793005 &+ 1
        return Node(summary, priority: seed)
    }

    private static func isBreak(_ c: unichar) -> Bool { c == 10 || c == 13 || c == 0x2028 || c == 0x2029 }

    private func summarize(_ text: NSString, range: NSRange) -> Summary {
        var result = Summary(length: range.length)
        let bufferStart = max(0, range.location - 1)
        let bufferEnd = min(text.length, NSMaxRange(range) + 1)
        var units = [unichar](repeating: 0, count: bufferEnd - bufferStart)
        text.getCharacters(&units, range: NSRange(location: bufferStart, length: units.count))
        let whitespace = Self.whitespace as NSCharacterSet
        let letters = Self.letters as NSCharacterSet
        var inWord = false
        var firstToken = true
        for i in range.location..<NSMaxRange(range) {
            let c = units[i - bufferStart]
            let space = c < 128 ? (c == 32 || (9...13).contains(c)) : whitespace.characterIsMember(c)
            if i == range.location { result.startsSpace = space }
            result.endsSpace = space
            if Self.isBreak(c) {
                if result.firstBreak == nil { result.firstBreak = i - range.location }
                result.lastBreak = i - range.location
            }
            if space {
                result.hasSpace = true; inWord = false; firstToken = false; result.lastWord = false
            } else {
                var letter = c < 128 ? ((48...57).contains(c) || (65...90).contains(c) || (97...122).contains(c)) : letters.characterIsMember(c)
                // Classify both halves so summaries compose across a block
                // boundary inside a supplementary Unicode letter.
                if (0xD800...0xDFFF).contains(c) {
                    let highIndex = c <= 0xDBFF ? i : i - 1
                    if highIndex >= 0, highIndex + 1 < text.length {
                        let high = units[highIndex - bufferStart], low = units[highIndex + 1 - bufferStart]
                        if (0xD800...0xDBFF).contains(high), (0xDC00...0xDFFF).contains(low) {
                            letter = letters.longCharacterIsMember(UInt32(high - 0xD800) * 0x400 + UInt32(low - 0xDC00) + 0x10000)
                        }
                    }
                }
                if letter {
                    if !inWord { result.words += 1; inWord = true }
                    if firstToken { result.firstWord = true }
                    result.lastWord = true
                }
            }
        }
        return result
    }

    private func build(_ text: NSString, range: NSRange) -> Node? {
        var tree: Node?
        var start = range.location
        while start < NSMaxRange(range) {
            let length = min(1024, NSMaxRange(range) - start)
            tree = join(tree, node(summarize(text, range: NSRange(location: start, length: length))))
            start += length
        }
        return tree
    }

    private func join(_ a: Node?, _ b: Node?) -> Node? {
        guard let a else { return b }
        guard let b else { return a }
        if a.priority > b.priority { a.right = join(a.right, b); a.update(); return a }
        b.left = join(a, b.left); b.update(); return b
    }

    private func split(_ tree: Node?, at position: Int, text: NSString, offset: Int = 0) -> (Node?, Node?) {
        guard let tree else { return (nil, nil) }
        let leftLength = tree.left?.total.length ?? 0
        if position < leftLength {
            let (a, b) = split(tree.left, at: position, text: text, offset: offset)
            tree.left = b; tree.update(); return (a, tree)
        }
        if position > leftLength + tree.block.length {
            let (a, b) = split(tree.right, at: position - leftLength - tree.block.length,
                               text: text, offset: offset + leftLength + tree.block.length)
            tree.right = a; tree.update(); return (tree, b)
        }
        let cut = position - leftLength
        let start = offset + leftLength
        let a = cut == 0 ? nil : node(summarize(text, range: NSRange(location: start, length: cut)))
        let b = cut == tree.block.length ? nil : node(summarize(text, range: NSRange(location: start + cut, length: tree.block.length - cut)))
        return (join(tree.left, a), join(b, tree.right))
    }

    private func blockRange(at position: Int) -> NSRange {
        var tree = root, offset = 0
        while let current = tree {
            let start = offset + (current.left?.total.length ?? 0)
            let end = start + current.block.length
            if position < start { tree = current.left }
            else if position >= end { offset = end; tree = current.right }
            else { return NSRange(location: start, length: current.block.length) }
        }
        return NSRange(location: offset, length: 0)
    }

    /// Call before changing the source, then the returned closure immediately
    /// afterward. Include neighboring units whose surrogate pairing may change.
    public func prepareEdit(in text: NSString, range: NSRange) -> (NSString, Int) -> Void {
        let start = blockRange(at: max(0, range.location - 1)).location
        let end = NSMaxRange(blockRange(at: min(max(0, text.length - 1), NSMaxRange(range))))
        let (prefix, rest) = split(root, at: start, text: text)
        let (_, suffix) = split(rest, at: end - start, text: text, offset: start)
        root = nil
        return { [self] newText, insertedLength in
            let middle = build(newText, range: NSRange(location: start, length: end - start + insertedLength - range.length))
            root = join(join(prefix, middle), suffix)
        }
    }

    // Locate the containing block and scan at most 1024 units within it, then
    // use subtree summaries to skip all other blocks.
    private func breakBefore(_ position: Int, in text: NSString) -> Int? {
        var tree = root, offset = 0
        var candidate: Int?
        while let current = tree {
            let start = offset + (current.left?.total.length ?? 0)
            if position <= start { tree = current.left; continue }
            if let last = current.left?.total.lastBreak { candidate = offset + last }
            let end = start + current.block.length
            if position <= end {
                for i in stride(from: position - 1, through: start, by: -1) { if Self.isBreak(text.character(at: i)) { return i } }
                return candidate
            }
            if let last = current.block.lastBreak { candidate = start + last }
            offset = end; tree = current.right
        }
        return candidate
    }

    private func breakAfter(_ position: Int, in text: NSString) -> Int? {
        var tree = root, offset = 0
        var candidate: Int?
        while let current = tree {
            let start = offset + (current.left?.total.length ?? 0), end = start + current.block.length
            if position >= end { offset = end; tree = current.right; continue }
            if let first = current.right?.total.firstBreak { candidate = end + first }
            if position >= start {
                for i in position..<end { if Self.isBreak(text.character(at: i)) { return i } }
                return candidate
            }
            if let first = current.block.firstBreak { candidate = start + first }
            tree = current.left
        }
        return candidate
    }

    public func paragraphRange(in text: NSString, covering range: NSRange) -> NSRange {
        var position = range.location
        if position > 0, position < text.length, text.character(at: position) == 10, text.character(at: position - 1) == 13 { position -= 1 }
        let start = (breakBefore(position, in: text) ?? -1) + 1
        var end = NSMaxRange(range)
        if end > 0, range.length > 0, Self.isBreak(text.character(at: end - 1)) {
            if end < text.length, text.character(at: end - 1) == 13, text.character(at: end) == 10 { end += 1 }
        } else if let next = breakAfter(end, in: text) {
            end = next + 1
            if end < text.length, text.character(at: next) == 13, text.character(at: end) == 10 { end += 1 }
        } else { end = text.length }
        return NSRange(location: start, length: end - start)
    }
}
