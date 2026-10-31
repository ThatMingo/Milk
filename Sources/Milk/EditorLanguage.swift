import AppKit

struct SyntaxToken { let range:NSRange; let color:NSColor }
enum EditorLanguage {
    static func tokens(_ text:String, fileExtension ext:String) -> [SyntaxToken] {
        let code=["swift","js","jsx","ts","tsx","py","rb","rs","go","c","h","cpp","m","mm","java","sh","json","css","html","xml","yaml","yml","toml","md"]
        guard code.contains(ext.lowercased()), (text as NSString).length < 1_000_000 else { return [] }
        let purple=MilkTheme.codeKeyword, teal=MilkTheme.codeType
        let red=MilkTheme.codeString, muted=MilkTheme.codeComment
        var patterns:[(String,NSColor)] = [
            (#"\b(import|from|as|actor|private|public|internal|protected|open|static|var|let|const|func|function|def|class|struct|enum|interface|protocol|extension|async|await|throws|throw|try|catch|return|if|else|for|while|guard|switch|case|break|continue|default|in|of|init|self|super|this|true|false|nil|null|None|True|False|new|export|type|mut|fn|use|pub|impl|match|package|defer|do)\b"#,purple),
            (#"\b[A-Z][A-Za-z0-9_]*\b"#,teal),
            (#"\b\d+(?:\.\d+)?\b"#,MilkTheme.codeNumber)
        ]
        // One combined lexical expression prevents comment delimiters inside strings
        // and quote characters in comments from overriding each other's coloring.
        var lexical=#"(?s:/\*.*?\*/)|//[^\n\r]*|"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|`(?:\\.|[^`\\])*`"#
        if ["py","rb","sh","yaml","yml","toml"].contains(ext) { lexical += "|#[^\\n\\r]*" }
        if ext == "md" { patterns=[("(?m)^#{1,6} .*",purple),("`[^`]+`",teal),("\\*\\*[^*]+\\*\\*",red)] }
        else { patterns.append((lexical,red)) }
        let range=NSRange(location:0,length:(text as NSString).length)
        var result:[SyntaxToken]=[]
        for (pattern,color) in patterns {
            guard let regex=try? NSRegularExpression(pattern:pattern) else { continue }
            for match in regex.matches(in:text,range:range) {
                let segment=(text as NSString).substring(with:match.range)
                let comment=pattern == lexical && (segment.hasPrefix("//") || segment.hasPrefix("/*") || segment.hasPrefix("#"))
                result.append(SyntaxToken(range:match.range,color:comment ? muted:color))
            }
        }
        return result
    }
    static func bracePairs(_ text:String) -> [(Int,Int)] {
        let units=Array(text.utf16)
        var stack:[(UInt16,Int)]=[], result:[(Int,Int)]=[]
        var quote:UInt16?; var lineComment=false; var blockComment=false; var escaped=false; var i=0
        while i<units.count {
            let c=units[i], next=i+1<units.count ? units[i+1]:0
            if lineComment { if c == 10 || c == 13 { lineComment=false }; i += 1; continue }
            if blockComment { if c == 42 && next == 47 { blockComment=false; i += 2 } else { i += 1 }; continue }
            if let q=quote {
                if escaped { escaped=false } else if c == 92 { escaped=true } else if c == q { quote=nil }
                i += 1; continue
            }
            if c == 47 && next == 47 { lineComment=true; i += 2; continue }
            if c == 47 && next == 42 { blockComment=true; i += 2; continue }
            if c == 34 || c == 39 || c == 96 { quote=c; i += 1; continue }
            if [UInt16(123),91,40].contains(c) { stack.append((c,i)) }
            else if let last=stack.last, (last.0 == 123 && c == 125) || (last.0 == 91 && c == 93) || (last.0 == 40 && c == 41) {
                stack.removeLast(); result.append((last.1,i))
            }
            i += 1
        }
        return result
    }
}
