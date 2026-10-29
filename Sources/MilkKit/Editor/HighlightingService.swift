import Foundation
import SwiftTreeSitter
import TreeSitterJSON

public struct SyntaxToken: Sendable {
    public enum Kind: Sendable { case string, number, keyword, comment }
    public let range: NSRange
    public let kind: Kind
}
public actor HighlightingService {
    private let parser = Parser()
    public init() { try? parser.setLanguage(tree_sitter_json()) }
    public func tokens(text: String, extension suffix: String) -> [SyntaxToken] {
        guard text.utf8.count < 2_000_000 else { return [] }
        if ["json", "jsonc"].contains(suffix), let tree = parser.parse(text) {
            var tokens: [SyntaxToken] = []
            func visit(_ node: Node) {
                let kind: SyntaxToken.Kind? = switch node.nodeType { case "string": .string; case "number": .number; case "true", "false", "null": .keyword; case "comment": .comment; default: nil }
                if let kind { tokens.append(.init(range: node.range, kind: kind)); return }
                for i in 0..<node.childCount { if let child = node.child(at: i) { visit(child) } }
            }
            if let root = tree.rootNode { visit(root) }
            return tokens
        }
        // Lexical fallback remains independent of LSP; parser providers can be added per language.
        let patterns: [(String, SyntaxToken.Kind)] = [
            (#"\b(?:import|let|var|func|class|struct|enum|actor|public|private|if|else|return|async|await|throw|throws|try|case|switch|for|while|true|false|nil|const|function|def)\b"#, .keyword),
            (#"\b\d+(?:\.\d+)?\b"#, .number), (#"\"(?:\\.|[^\"\\])*\""#, .string), (#"//[^\n]*"#, .comment)
        ]
        let range = NSRange(location: 0, length: text.utf16.count)
        return patterns.flatMap { pattern, kind in (try? NSRegularExpression(pattern: pattern).matches(in: text, range: range).map { SyntaxToken(range: $0.range, kind: kind) }) ?? [] }
    }
}
