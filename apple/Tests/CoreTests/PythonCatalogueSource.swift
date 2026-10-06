import Foundation

/// The `MESSAGES` mapping of `src/binaural/locales/ru.py`, read at test time.
///
/// CONTRACT rule 3 makes `ru.py` the single source of truth for Russian text, and
/// `apple/Tools/generate_russian_catalogue.py` ports it into
/// `Sources/Core/Locales/RussianCatalogue.swift`. A generated artefact is only trustworthy
/// while something checks it against its source — and a *literal* key count in the test
/// checks nothing at all: editing `ru.py` without regenerating leaves the literal just as
/// true as before, and the app silently loses the new strings in Russian. So the check
/// reads the source itself.
///
/// The parser is deliberately small and deliberately loud: it understands exactly the
/// Python that `ru.py` uses — one `MESSAGES` dict, keys and values as string literals that
/// may be implicitly concatenated across lines, `#` comments, the handful of escapes the
/// catalogue uses — and it *throws* on anything else (triple-quoted strings, f-strings,
/// `+` concatenation, an unknown escape, a non-literal key). A parser that guessed would
/// turn this guard into a second source of truth; one that stops is a test failure telling
/// whoever wrote the new syntax to extend this file.
enum PythonCatalogueSource {

    /// `<repo>` — four levels up from `apple/Tests/CoreTests`: CoreTests, Tests, apple, root.
    static let repositoryRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // CoreTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // apple
        .deletingLastPathComponent()   // the repository

    /// The catalogue the Python app ships, parsed fresh.
    static func messageKeys(
        at url: URL = repositoryRoot.appendingPathComponent("src/binaural/locales/ru.py")
    ) throws -> Set<String> {
        let source = try String(contentsOf: url, encoding: .utf8)
        return try messageKeys(in: source)
    }

    /// Parse the `MESSAGES` dict out of Python source, returning its keys.
    ///
    /// Order is not preserved on purpose: the Swift catalogue is a dictionary, so the
    /// invariant worth pinning is the *set* of keys, which is what a stale catalogue
    /// actually gets wrong.
    static func messageKeys(in source: String) throws -> Set<String> {
        let characters = Array(source)
        var keys: Set<String> = []
        var index = try dictionaryBodyStart(in: characters)
        while true {
            try skipTrivia(characters, &index)
            guard index < characters.count else {
                throw ParseError.unterminatedDictionary(line: line(characters, at: index))
            }
            if characters[index] == "}" { return keys }

            // A key: one string literal, or a run of them joined the way the Python parser
            // joins implicit concatenation.
            var key = try stringLiteral(characters, &index)
            while true {
                var lookahead = index
                try skipTrivia(characters, &lookahead)
                guard lookahead < characters.count, isQuote(characters[lookahead]) else { break }
                index = lookahead
                key += try stringLiteral(characters, &index)
            }
            keys.insert(key)

            var afterKey = index
            try skipTrivia(characters, &afterKey)
            guard afterKey < characters.count, characters[afterKey] == ":" else {
                throw ParseError.expectedColon(line: line(characters, at: afterKey))
            }
            index = try skipValue(characters, afterKey + 1)
            if index < characters.count, characters[index] == "," { index += 1 }
        }
    }

    // MARK: - Scanning

    /// The index just past the `{` that opens the `MESSAGES` dict.
    ///
    /// Between the name and the brace only the annotation may appear — `MESSAGES:
    /// dict[str, str] = {` — so the scan accepts exactly the characters that spelling uses
    /// and refuses anything else. A literal `"MESSAGES"` inside a string would be found
    /// first and the refusal would name the line, which is what a reader needs.
    private static func dictionaryBodyStart(in characters: [Character]) throws -> Int {
        let name = "MESSAGES"
        guard var index = indexOfName(name, in: characters) else {
            throw ParseError.noMessages
        }
        index += name.count
        // `dict[str, str]`: letters, digits, spaces, underscore, `[`, `]`, `,` and `:`.
        let annotation: Set<Character> = [
            " ", "\t", "\n", "\r", "_", "[", "]", ",", ":",
        ]
        while index < characters.count, characters[index] != "{" {
            let character = characters[index]
            if character == "=" || character.isLetter || character.isNumber
                || annotation.contains(character) {
                index += 1
                continue
            }
            throw ParseError.unexpectedBeforeDictionary(
                "\(character)", line: line(characters, at: index)
            )
        }
        guard index < characters.count else {
            throw ParseError.noMessages
        }
        guard characters[(index + 1)...].contains("}") else {
            throw ParseError.unterminatedDictionary(line: line(characters, at: index))
        }
        return index + 1
    }

    /// The index of `name` appearing outside a string literal and outside a comment.
    ///
    /// Skipping strings *tolerantly* is the point here: `ru.py` opens with a `"""` module
    /// docstring, and this scan has to get past it to reach the dict. The tolerant skip is
    /// safe because the only thing it feeds is "where does `MESSAGES` start" — every string
    /// inside the dict itself is read by ``stringLiteral(_:_:)``, which is strict.
    private static func indexOfName(_ name: String, in characters: [Character]) -> Int? {
        let target = Array(name)
        var index = 0
        while index + target.count <= characters.count {
            let character = characters[index]
            if isQuote(character) {
                skipStringLiteral(characters, &index)
                continue
            }
            if character == "#" {
                while index < characters.count, characters[index] != "\n" { index += 1 }
                continue
            }
            if Array(characters[index..<(index + target.count)]) == target {
                return index
            }
            index += 1
        }
        return nil
    }

    /// Skip whitespace and `#` comments.
    private static func skipTrivia(_ characters: [Character], _ index: inout Int) throws {
        while index < characters.count {
            let character = characters[index]
            if character.isWhitespace {
                index += 1
            } else if character == "#" {
                while index < characters.count, characters[index] != "\n" { index += 1 }
            } else {
                return
            }
        }
    }

    /// The index just past the end of the value that starts at `index`.
    ///
    /// Values are skipped rather than read: only the keys are compared. Strings inside a
    /// value are still parsed, because a value may hold `,`, `:` or `}` inside quotes and
    /// the scan must not mistake those for structure.
    private static func skipValue(_ characters: [Character], _ index: Int) throws -> Int {
        var cursor = index
        var depth = 0
        while cursor < characters.count {
            let character = characters[cursor]
            if isQuote(character) {
                _ = try stringLiteral(characters, &cursor)
            } else if character == "(" || character == "[" || character == "{" {
                depth += 1
                cursor += 1
            } else if character == ")" || character == "]" {
                depth -= 1
                cursor += 1
                if depth < 0 {
                    throw ParseError.unbalancedBracket(line: line(characters, at: cursor))
                }
            } else if character == "}" {
                if depth == 0 { return cursor }
                depth -= 1
                cursor += 1
            } else if character == "," && depth == 0 {
                return cursor
            } else if character == "#" {
                while cursor < characters.count, characters[cursor] != "\n" { cursor += 1 }
            } else {
                cursor += 1
            }
        }
        throw ParseError.unterminatedValue(line: line(characters, at: cursor))
    }

    /// Read one Python string literal starting at `index`, returning its value.
    ///
    /// Only the escapes `ru.py` uses are accepted, and an unknown one throws rather than
    /// being passed through: Python would decode it, and a value this parser reads
    /// differently from the interpreter is a key-set comparison that silently rots.
    private static func stringLiteral(
        _ characters: [Character], _ index: inout Int
    ) throws -> String {
        guard index < characters.count, isQuote(characters[index]) else {
            throw ParseError.expectedStringLiteral(line: line(characters, at: index))
        }
        let quote = characters[index]
        var cursor = index + 1
        if cursor + 1 < characters.count,
           characters[cursor] == quote, characters[cursor + 1] == quote {
            throw ParseError.tripleQuotedString(line: line(characters, at: index))
        }
        var value = ""
        while cursor < characters.count {
            let character = characters[cursor]
            if character == quote {
                index = cursor + 1
                return value
            }
            if character == "\\" {
                let decoded = try decodeEscape(characters, at: cursor)
                value += decoded.text
                cursor = decoded.end
                continue
            }
            value.append(character)
            cursor += 1
        }
        throw ParseError.unterminatedString(line: line(characters, at: index))
    }

    /// One backslash escape: the text it stands for and the index just past it.
    ///
    /// `ru.py` needs almost none of these — a single `\"` in the MIT licence text — but a
    /// parser that handles only the ones present today silently misreads the first escape
    /// somebody adds, which is exactly the drift this file exists to catch. Unknown escapes
    /// therefore throw.
    private static func decodeEscape(
        _ characters: [Character], at index: Int
    ) throws -> (text: String, end: Int) {
        func line() -> Int { self.line(characters, at: index) }
        guard index + 1 < characters.count else {
            throw ParseError.danglingEscape(line: line())
        }
        let escaped = characters[index + 1]
        switch escaped {
        case "\\", "\"", "'":
            return (String(escaped), index + 2)
        case "n":
            return ("\n", index + 2)
        case "t":
            return ("\t", index + 2)
        case "r":
            return ("\r", index + 2)
        case "\n":
            return ("", index + 2)                            // a line continuation
        case "x", "u", "U":
            let digits = escaped == "x" ? 2 : escaped == "u" ? 4 : 8
            let start = index + 2
            guard start + digits <= characters.count else {
                throw ParseError.truncatedEscape(line: line())
            }
            let text = String(characters[start..<(start + digits)])
            guard let value = UInt32(text, radix: 16), let scalar = Unicode.Scalar(value) else {
                throw ParseError.unsupportedEscape("\\\(text)", line: line())
            }
            return (String(Character(scalar)), start + digits)
        default:
            throw ParseError.unsupportedEscape("\\\(escaped)", line: line())
        }
    }

    /// Advance past a string literal of any quoting, decoding nothing.
    ///
    /// Only used to walk *over* Python text — the module docstring before `MESSAGES`, and
    /// the `#` inside it. Inside the dict, ``stringLiteral(_:_:)`` does the reading.
    private static func skipStringLiteral(_ characters: [Character], _ index: inout Int) {
        let quote = characters[index]
        var cursor = index + 1
        // `"""` and `'''` run to the matching triple.
        if cursor + 1 < characters.count,
           characters[cursor] == quote, characters[cursor + 1] == quote {
            let terminator = String(repeating: quote, count: 3)
            var search = cursor + 2
            while search < characters.count {
                if characters[search] == "\\" {
                    search += 2
                    continue
                }
                if String(characters[search...].prefix(3)) == terminator {
                    index = search + 3
                    return
                }
                search += 1
            }
            index = characters.count
            return
        }
        while cursor < characters.count {
            if characters[cursor] == "\\" {
                cursor += 2
                continue
            }
            if characters[cursor] == quote {
                index = cursor + 1
                return
            }
            cursor += 1
        }
        index = characters.count
    }

    private static func isQuote(_ character: Character) -> Bool {
        character == "\"" || character == "'"
    }

    /// 1-based line number, so a parse error names a place a human can open.
    private static func line(_ characters: [Character], at index: Int) -> Int {
        var count = 1
        for position in characters.indices where position < min(index, characters.count) {
            if characters[position] == "\n" { count += 1 }
        }
        return count
    }

    /// Every way this parser can refuse to answer, named.
    enum ParseError: Error, CustomStringConvertible {
        case noMessages
        case unexpectedBeforeDictionary(String, line: Int)
        case unterminatedDictionary(line: Int)
        case unterminatedValue(line: Int)
        case unterminatedString(line: Int)
        case tripleQuotedString(line: Int)
        case expectedStringLiteral(line: Int)
        case expectedColon(line: Int)
        case unbalancedBracket(line: Int)
        case danglingEscape(line: Int)
        case truncatedEscape(line: Int)
        case unsupportedEscape(String, line: Int)

        var description: String {
            func at(_ line: Int) -> String { " (ru.py line \(line))" }
            switch self {
            case .noMessages:
                return "no MESSAGES dict found in src/binaural/locales/ru.py"
            case .unexpectedBeforeDictionary(let character, let line):
                return "unexpected \(character) between MESSAGES and its dict" + at(line)
            case .unterminatedDictionary(let line):
                return "the MESSAGES dict is never closed" + at(line)
            case .unterminatedValue(let line):
                return "a MESSAGES value runs to the end of the file" + at(line)
            case .unterminatedString(let line):
                return "an unterminated string literal" + at(line)
            case .tripleQuotedString(let line):
                return "a triple-quoted string" + at(line)
                    + "; extend PythonCatalogueSource rather than guessing"
            case .expectedStringLiteral(let line):
                return "expected a string literal" + at(line)
                    + "; extend PythonCatalogueSource rather than guessing"
            case .expectedColon(let line):
                return "expected ':' after a catalogue key" + at(line)
            case .unbalancedBracket(let line):
                return "an unbalanced bracket" + at(line)
            case .danglingEscape(let line):
                return "a string ending in a backslash" + at(line)
            case .truncatedEscape(let line):
                return "a truncated \\x/\\u/\\U escape" + at(line)
            case .unsupportedEscape(let escape, let line):
                return "unsupported escape \(escape)" + at(line)
                    + "; extend PythonCatalogueSource rather than guessing"
            }
        }
    }
}