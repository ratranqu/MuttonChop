// stage 1 parsing
public enum Token: Equatable {
    // some text
    case text(String)
    // {{ variable }}
    case variable(String)
    // {{{ variable }}}
    case unescapedVariable(String)
    // {{! comment }}
    case comment
    // {{> partial }}
    case partial(String, indentation: String)
    // {{# variable }}
    case openSection(variable: String)
    // {{^ variable }}
    case openInvertedSection(variable: String)
    // {{$ identifier }}
    case openOverrideSection(identifier: String)
    // {{< identifier }}
    case openParentSection(identifier: String)
    // {{/ variable }}
    case closeSection(variable: String)
}

public func ==(lhs: Token, rhs: Token) -> Bool {
    switch (lhs, rhs) {
    case let (.text(l), .text(r)): return l == r
    case let (.variable(l), .variable(r)): return l == r
    case let (.openSection(l), .openSection(r)): return l == r
    case let (.closeSection(l), .closeSection(r)): return l == r
    case let (.openInvertedSection(l), .openInvertedSection(r)): return l == r
    default: return false
    }
}

public struct SyntaxError: Error {
    let line: Int
    let column: Int
    let reason: Reason

    init(reader: Reader, reason: Reason) {
        self.line = reader.line
        self.column = reader.column
        self.reason = reason
    }
}

public enum Reason: Error {
    case missingEndOfToken
}

final class Parser {
    private var tokens = [Token]()
    private let reader: Reader

    var delimiters: (open: [Character], close: [Character]) = (["{", "{"], ["}", "}"])
    init(reader: Reader) {
        self.reader = reader
    }

    func parse() throws -> [Token] {
        do {

            while !reader.done {
                if reader.peek(delimiters.open.count) == delimiters.open {
                    try tokens.append(parseExpression())
                    continue
                }

                try tokens.append(parseText())
            }

            return tokens

        } catch let reason as Reason {
            throw SyntaxError(reader: reader, reason: reason)
        }
    }

    func parseText() throws -> Token {
        let text = reader.pop(upTo: delimiters.open, discarding: false)!
        return .text(String(text))
    }

    func parseExpression() throws -> Token {
        // whitespace up to newline before the tag
        // nil = not only whitespace
        let leading = reader.leadingWhitespace()

        // opening braces
        precondition(reader.pop(delimiters.open.count) == delimiters.open)

        reader.consume(using: String.whitespaceAndNewLineCharacterSet)

        // char = token type
        guard
            let char = reader.pop(),
            let content = reader.pop(upTo: delimiters.close)
            else {
                throw Reason.missingEndOfToken
        }

        // closing braces
        precondition(reader.pop(delimiters.close.count) == delimiters.close)

        // whitespace up to newline after the tag
        // nil = not only whitespace
        let trailing = reader.trailingWhitespace()

        func stripIfStandalone() {
            // if just whitespace until newline on both sides, tag is standalone
            guard let _ = leading, let trailing = trailing else {
                return
            }

            // get rid of trailing whitespace
            reader.pop(trailing.count)
            // get rid of newline
            reader.consume(using: String.newLineCharacterSet, upTo: 1)

            // get the token before it (should be text)
            if case let .text(prev)? = tokens.last {
                // get rid of trailing whitespace on that token
                let newText = prev.trimRight(using: String.whitespaceCharacterSet)
                // put it back in
                tokens[tokens.endIndex - 1] = .text(newText)
            }
        }

        let trimmed = String(content).trim(using: String.whitespaceAndNewLineCharacterSet)

        switch char {

        // comment
        case "!":
            defer { stripIfStandalone() }
            return .comment

        // open section
        case "#":
            defer { stripIfStandalone() }
            return .openSection(variable: trimmed)

        // open inverted section
        case "^":
            defer { stripIfStandalone() }
            return .openInvertedSection(variable: trimmed)

        // open inherit section
        case "$":
            defer { stripIfStandalone() }
            return .openOverrideSection(identifier: trimmed)

        // open overwrite section
        case "<":
            defer { stripIfStandalone() }
            return .openParentSection(identifier: trimmed)

        // close section
        case "/":
            defer { stripIfStandalone() }
            return .closeSection(variable: trimmed)

        // partial
        case ">":
            defer { stripIfStandalone() }
            let indentation = leading.map(String.init(_:)) ?? ""
            return .partial(trimmed, indentation: indentation)

        // unescaped variable
        case "{":
            // pop the third brace
            guard reader.pop() == "}" else {
                throw Reason.missingEndOfToken
            }
            return .unescapedVariable(trimmed)

        // unescaped variable
        case "&":
            return .unescapedVariable(trimmed)

        // change delimiter:
        case "=":
            defer { stripIfStandalone() }

            // make a reader for the contents of the tag (code reuse FTW)
            let reader = Reader(AnyIterator(content.makeIterator()))

            // strip any whitespace before the delimiter
            reader.consume(using: String.whitespaceCharacterSet)

            // delimiter ends upon whitespace
            guard let open = reader.pop(upTo: " ") else {
                throw Reason.missingEndOfToken
            }

            // delimiter ends upon whitespace
            // also strip any whitespace before/afterwards
            guard let close = reader.pop(upTo: "=")?.filter({!String.whitespaceCharacterSet.contains($0)}) else {
                throw Reason.missingEndOfToken
            }

            self.delimiters = (open: open, close: close)

            // TODO: find a better way to return nothing
            return .comment

        // normal variable
        default:
            return .variable(String([char] + content).trim(using: String.whitespaceAndNewLineCharacterSet))
        }
    }
}
