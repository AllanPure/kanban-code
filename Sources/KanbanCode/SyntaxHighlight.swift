import SwiftUI

/// Lightweight, per-line syntax highlighter for the diff view. Regex-based (not a full
/// parser): it colors comments, strings, numbers, keywords and types well enough to make
/// a diff readable, across the languages this project and Odoo work touch. Written from
/// scratch — no external highlighting library.
enum SyntaxHighlight {

    enum Language {
        case swift, python, javascript, xml, css, json, shell, go, rust, ruby, markdown, generic

        static func infer(fromPath path: String) -> Language {
            switch (path as NSString).pathExtension.lowercased() {
            case "swift": return .swift
            case "py": return .python
            case "js", "jsx", "ts", "tsx", "mjs", "cjs": return .javascript
            case "xml", "html", "htm", "qweb": return .xml
            case "css", "scss", "sass", "less": return .css
            case "json": return .json
            case "sh", "bash", "zsh": return .shell
            case "go": return .go
            case "rs": return .rust
            case "rb": return .ruby
            case "md", "markdown": return .markdown
            default: return .generic
            }
        }

        var lineComments: [String] {
            switch self {
            case .python, .shell, .ruby: return ["#"]
            case .swift, .javascript, .css, .go, .rust: return ["//"]
            default: return []
            }
        }

        var keywords: Set<String> {
            switch self {
            case .swift:
                return ["func","let","var","if","else","guard","return","for","while","in","switch","case","default","struct","class","enum","protocol","extension","import","public","private","internal","fileprivate","static","self","nil","true","false","async","await","try","throw","throws","do","catch","some","any","where","init","deinit","override","final","lazy","weak","unowned","mutating","associatedtype","typealias"]
            case .python:
                return ["def","class","if","elif","else","for","while","in","return","import","from","as","try","except","finally","with","lambda","yield","pass","break","continue","and","or","not","is","None","True","False","self","raise","global","nonlocal","assert","async","await"]
            case .javascript:
                return ["function","const","let","var","if","else","for","while","return","class","extends","import","export","from","default","new","this","null","undefined","true","false","async","await","try","catch","finally","throw","switch","case","break","continue","typeof","instanceof","interface","type","enum","public","private","readonly","void","as"]
            case .go:
                return ["func","package","import","var","const","type","struct","interface","if","else","for","range","return","go","defer","chan","map","switch","case","default","nil","true","false","break","continue"]
            case .rust:
                return ["fn","let","mut","if","else","for","while","loop","match","return","struct","enum","trait","impl","use","pub","mod","self","Self","true","false","async","await","move","ref","where","as","const","static"]
            case .ruby:
                return ["def","class","module","if","elsif","else","unless","end","do","return","yield","require","attr_accessor","nil","true","false","self","begin","rescue","ensure","then","while","for","in","case","when"]
            default:
                return []
            }
        }
    }

    // Token colors — chosen to stay legible on both themes and NOT clash with the
    // green/red diff row backgrounds (which convey add/remove).
    private static let keyword = Color.purple
    private static let string  = Color(red: 0.80, green: 0.45, blue: 0.16)
    private static let number  = Color(red: 0.16, green: 0.50, blue: 0.86)
    private static let comment = Color.secondary
    private static let type    = Color.teal
    private static let xmlTag  = Color(red: 0.16, green: 0.50, blue: 0.86)

    /// Highlight one line of code. Comments and strings are matched first and "consume"
    /// their characters so keywords/numbers inside them aren't recolored.
    static func highlight(_ line: String, language: Language) -> AttributedString {
        var attr = AttributedString(line)
        guard !line.isEmpty else { return attr }
        let ns = line as NSString
        var consumed = [Bool](repeating: false, count: ns.length)

        func apply(_ pattern: String, _ color: Color, options: NSRegularExpression.Options = []) {
            guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return }
            for m in re.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
                let r = m.range
                guard r.length > 0, r.location + r.length <= consumed.count else { continue }
                if (r.location..<(r.location + r.length)).contains(where: { consumed[$0] }) { continue }
                if let ar = Range(r, in: attr) { attr[ar].foregroundColor = color }
                for i in r.location..<(r.location + r.length) { consumed[i] = true }
            }
        }

        if language == .xml {
            apply("<!--.*?-->", comment)
            apply("\"(\\\\.|[^\"\\\\])*\"", string)
            apply("'(\\\\.|[^'\\\\])*'", string)
            apply("</?[A-Za-z][\\w:.-]*", xmlTag)     // opening/closing tag name
            apply("/?>", xmlTag)
            apply("\\b[\\w:-]+(?==)", keyword)         // attribute names
            return attr
        }
        if language == .markdown {
            apply("`[^`]*`", string)
            apply("^#{1,6} .*$", keyword)
            apply("\\*\\*[^*]+\\*\\*", type)
            return attr
        }

        // Comments (to end of line) — mask them first.
        for marker in language.lineComments {
            apply(NSRegularExpression.escapedPattern(for: marker) + ".*$", comment)
        }
        // Strings.
        apply("\"(\\\\.|[^\"\\\\])*\"", string)
        apply("'(\\\\.|[^'\\\\])*'", string)
        if language == .javascript { apply("`(\\\\.|[^`\\\\])*`", string) }
        // Keywords.
        let kws = language.keywords
        if !kws.isEmpty {
            let pattern = "\\b(" + kws.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|") + ")\\b"
            apply(pattern, keyword)
        }
        // Capitalized identifiers → types (Swift/TS/Go/Rust idiom).
        if [.swift, .javascript, .go, .rust].contains(language) {
            apply("\\b[A-Z][A-Za-z0-9_]*\\b", type)
        }
        // Numbers.
        apply("\\b\\d[\\d_]*(\\.\\d+)?\\b", number)
        return attr
    }
}
