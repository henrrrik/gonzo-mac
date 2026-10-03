import Foundation

public enum MarkdownStyle: Equatable, Sendable {
    case heading(level: Int)
    case marker, bold, italic, code, quote, link
}

public struct MarkdownSpan: Sendable {
    public let range: NSRange
    public let style: MarkdownStyle
}

/// Paragraph-local styling keeps an ordinary keystroke independent of document size.
/// Markers stay visible so source, selection, accessibility and saved text agree.
public enum Markdown {
    private struct Rule: @unchecked Sendable {
        let regex: NSRegularExpression
        let groups: [(Int, MarkdownStyle)]
    }

    private static let rules: [Rule] = [
        rule(#"^(#{1,6}[\t ]+)(.*)$"#, [(1, .marker), (2, .heading(level: 1))]),
        rule(#"^(\s*>+\s?)(.*)$"#, [(1, .marker), (2, .quote)]),
        rule(#"^(\s*(?:[-+*]|\d+[.)])\s+)"#, [(1, .marker)]),
        rule(#"^\s{0,3}([-*_])(?:\s*\1){2,}\s*$"#, [(0, .marker)]),
        rule(#"(\*\*|__)(.+?)(\1)"#, [(1, .marker), (2, .bold), (3, .marker)]),
        rule(#"(?<!\*)\*([^*\n]+)\*(?!\*)|(?<!_)_([^_\n]+)_(?!_)"#, [(0, .marker), (1, .italic), (2, .italic)]),
        // Code runs last so emphasis inside backticks is displayed as code.
        rule(#"`([^`]+)`"#, [(0, .code)])
    ]

    private static func rule(_ pattern: String, _ groups: [(Int, MarkdownStyle)]) -> Rule {
        Rule(regex: try! NSRegularExpression(pattern: pattern, options: .anchorsMatchLines), groups: groups)
    }

    public static func spans(in text: String) -> [MarkdownSpan] {
        // Bound every regex invocation, even for a file with a single huge line.
        // Long paragraphs remain editable as plain text.
        let source = text as NSString
        var spans: [MarkdownSpan] = []
        var start = 0
        for end in 0...source.length {
            let isEnd = end == source.length
            let isBreak = !isEnd && [10, 13, 0x2028, 0x2029].contains(Int(source.character(at: end)))
            if isEnd || isBreak {
                if end - start <= 4096, end > start {
                    for span in paragraphSpans(in: source.substring(with: NSRange(location: start, length: end - start))) {
                        spans.append(MarkdownSpan(range: NSRange(location: start + span.range.location, length: span.range.length), style: span.style))
                    }
                }
                start = end + 1
            }
        }
        return spans
    }

    private static func paragraphSpans(in text: String) -> [MarkdownSpan] {
        let range = NSRange(location: 0, length: (text as NSString).length)
        var spans: [MarkdownSpan] = []
        for rule in rules {
            if rule.groups.contains(where: { $0.1 == .code }) { spans.append(contentsOf: links(in: text as NSString)) }
            rule.regex.enumerateMatches(in: text, range: range) { match, _, _ in
                guard let match else { return }
                for (group, style) in rule.groups {
                    let range = match.range(at: group)
                    if range.location != NSNotFound && range.length > 0 {
                        if case .heading = style {
                            let prefix = (text as NSString).substring(with: match.range(at: 1))
                            spans.append(MarkdownSpan(range: range, style: .heading(level: prefix.prefix { $0 == "#" }.count)))
                        } else {
                            spans.append(MarkdownSpan(range: range, style: style))
                        }
                    }
                }
            }
        }
        return spans
    }

    // Each character is visited at most once. Escapes consume two characters;
    // incomplete destinations cannot trigger regex backtracking.
    private static func links(in text: NSString) -> [MarkdownSpan] {
        var result: [MarkdownSpan] = []
        var opening: Int?
        var index = 0
        while index < text.length {
            let character = text.character(at: index)
            if character == 92 { index += min(2, text.length - index); continue }
            if character == 91 { opening = index }
            if character == 93, let start = opening {
                opening = nil
                if index > start + 1, index + 1 < text.length, text.character(at: index + 1) == 40 {
                    let labelEnd = index
                    index += 2
                    let destinationStart = index
                    while index < text.length && text.character(at: index) != 41 {
                        index += text.character(at: index) == 92 ? min(2, text.length - index) : 1
                    }
                    if index < text.length, index > destinationStart {
                        result.append(MarkdownSpan(range: NSRange(location: start, length: index - start + 1), style: .marker))
                        result.append(MarkdownSpan(range: NSRange(location: start + 1, length: labelEnd - start - 1), style: .link))
                    }
                }
            }
            index += 1
        }
        return result
    }
}

public struct TextMutation: Equatable, Sendable {
    public let range: NSRange
    public let replacement: String
    public let selection: NSRange

    public init(range: NSRange, replacement: String, selection: NSRange) {
        self.range = range
        self.replacement = replacement
        self.selection = selection
    }
}

public enum EditorCommands {
    public static func wrap(_ text: NSString, selection: NSRange, marker: String) -> TextMutation {
        let selected = text.substring(with: selection)
        return TextMutation(range: selection, replacement: marker + selected + marker,
                            selection: NSRange(location: selection.location + (marker as NSString).length,
                                               length: selection.length))
    }

    public static func link(_ text: NSString, selection: NSRange, destination: String?) -> TextMutation {
        let label = selection.length == 0 ? "link text" : text.substring(with: selection)
        let escapedLabel = label.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
        let url = (destination ?? "https://").replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "(", with: "\\(").replacingOccurrences(of: ")", with: "\\)")
        let replacement = "[\(escapedLabel)](\(url))"
        let labelLength = (escapedLabel as NSString).length
        let newSelection: NSRange
        if selection.length == 0 {
            newSelection = NSRange(location: selection.location + 1, length: labelLength)
        } else if destination == nil {
            newSelection = NSRange(location: selection.location + labelLength + 3, length: (url as NSString).length)
        } else {
            newSelection = NSRange(location: selection.location + (replacement as NSString).length, length: 0)
        }
        return TextMutation(range: selection, replacement: replacement, selection: newSelection)
    }

    private static let list = try! NSRegularExpression(pattern: #"^(\s*)([-+*]|\d+[.)]|>+)\s+(.*)$"#)

    public static func newline(_ text: NSString, selection: NSRange, soft: Bool, paragraphRange: NSRange? = nil) -> TextMutation {
        var range = selection
        var insertion = soft ? "\n" : "\n\n"
        if !soft {
            let paragraph = paragraphRange ?? Paragraphs.range(in: text, covering: NSRange(location: selection.location, length: 0))
            let line = text.substring(with: NSRange(location: paragraph.location,
                                                    length: min(4096, selection.location - paragraph.location)))
            if let match = list.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) {
                let source = line as NSString
                if match.range(at: 3).length == 0, selection.location - paragraph.location <= 4096 {
                    range = NSRange(location: paragraph.location, length: NSMaxRange(selection) - paragraph.location)
                    insertion = "\n"
                } else {
                    var marker = source.substring(with: match.range(at: 2))
                    if let number = Int(marker.dropLast()), number < Int.max {
                        marker = "\(number + 1)\(marker.suffix(1))"
                    }
                    insertion = "\n" + source.substring(with: match.range(at: 1)) + marker + " "
                }
            }
        }
        return TextMutation(range: range, replacement: insertion,
                            selection: NSRange(location: range.location + (insertion as NSString).length, length: 0))
    }

    public static func normalize(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }
}
