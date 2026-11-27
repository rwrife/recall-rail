import Foundation

/// Strict UTF-8 CSV syntax with source-line diagnostics. Field values are
/// parsed exactly; serialization adds spreadsheet safety escaping.
public struct CSVDocument: Equatable, Sendable {
    public enum LineEnding: String, Equatable, Sendable {
        case crlf, lf, cr, mixed, none
    }

    public struct Row: Equatable, Sendable {
        public let fields: [String]
        public let lineNumber: Int
    }

    public struct SyntaxError: Equatable, Sendable {
        public let lineNumber: Int
        public let message: String
    }

    public let rows: [Row]
    public let syntaxErrors: [SyntaxError]
    public let blankLines: Int
    public let hasBOM: Bool
    public let lineEnding: LineEnding

    public init(text: String) {
        // Character coalesces CRLF into one extended grapheme cluster. CSV
        // delimiters are Unicode scalars, not grapheme clusters.
        var scalars = Array(text.unicodeScalars)
        let hasBOM = scalars.first == "\u{FEFF}"
        if hasBOM { scalars.removeFirst() }

        enum FieldState { case start, unquoted, quoted, closed }
        var state: FieldState = .start
        var rows: [Row] = []
        var errors: [SyntaxError] = []
        var fields: [String] = []
        var field = ""
        var line = 1
        var startLine = 1
        var recordHasContent = false
        var recordInvalid = false
        var blankLines = 0
        var sawLF = false
        var sawCR = false
        var sawCRLF = false

        func finishField() {
            fields.append(field)
            field = ""
            state = .start
        }
        func finishRecord(terminated: Bool) {
            finishField()
            if recordHasContent || fields.count > 1 {
                if !recordInvalid { rows.append(Row(fields: fields, lineNumber: startLine)) }
            } else if terminated {
                blankLines += 1
            }
            fields = []
            recordHasContent = false
            recordInvalid = false
        }
        func syntax(_ message: String) {
            if !recordInvalid { errors.append(SyntaxError(lineNumber: startLine, message: message)) }
            recordInvalid = true
        }

        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            let nextIsLF = index + 1 < scalars.count && scalars[index + 1] == "\n"
            if scalar == "\r" || scalar == "\n" {
                let crlf = scalar == "\r" && nextIsLF
                if state == .quoted {
                    field.append(String(scalar))
                    if crlf { index += 1; field.append("\n") }
                } else {
                    if crlf { sawCRLF = true; index += 1 }
                    else if scalar == "\r" { sawCR = true }
                    else { sawLF = true }
                    finishRecord(terminated: true)
                    startLine = line + 1
                }
                line += 1
            } else if scalar == "," && state != .quoted {
                finishField()
                recordHasContent = true
            } else if scalar == "\"" {
                recordHasContent = true
                switch state {
                case .start: state = .quoted
                case .unquoted: syntax("Quote inside an unquoted field.")
                case .quoted:
                    if index + 1 < scalars.count && scalars[index + 1] == "\"" {
                        field.append("\"")
                        index += 1
                    } else { state = .closed }
                case .closed: syntax("Unexpected quote after a closed field.")
                }
            } else {
                recordHasContent = true
                switch state {
                case .start: state = .unquoted; field.append(String(scalar))
                case .unquoted, .quoted: field.append(String(scalar))
                case .closed: syntax("Characters after a closing quote.")
                }
            }
            index += 1
        }
        if state == .quoted { syntax("Unterminated quoted field.") }
        if recordHasContent || !fields.isEmpty { finishRecord(terminated: false) }
        let kinds = [sawLF, sawCR, sawCRLF].filter { $0 }.count
        self.rows = rows
        self.syntaxErrors = errors
        self.blankLines = blankLines
        self.hasBOM = hasBOM
        self.lineEnding = kinds == 0 ? .none : (kinds > 1 ? .mixed : (sawLF ? .lf : (sawCR ? .cr : .crlf)))
    }

    /// RFC 4180 quoting and CRLF serialization; every cell is spreadsheet-safe.
    /// Quoting alone does not stop formula execution. Dangerous leading characters
    /// (including after whitespace) receive an apostrophe; literal leading
    /// apostrophes are doubled so marked card exports can decode without ambiguity.
    /// Parsing itself never unescapes: external CSV apostrophes remain literal.
    public static func serialize(rows: [[String]], lineEnding: String = "\r\n") -> String {
        guard !rows.isEmpty else { return "" }
        return rows.map { $0.map(escapeField).joined(separator: ",") }
            .joined(separator: lineEnding) + lineEnding
    }

    private static func needsSpreadsheetPrefix(_ field: String) -> Bool {
        for scalar in field.unicodeScalars {
            if "=+-@\t\r\n".unicodeScalars.contains(scalar) { return true }
            if !CharacterSet.whitespacesAndNewlines.contains(scalar) { return false }
        }
        return false
    }

    public static func spreadsheetSafeField(_ field: String) -> String {
        field.hasPrefix("'") || needsSpreadsheetPrefix(field) ? "'" + field : field
    }

    // Only the explicitly marked card CSV dialect may call this inverse.
    static func decodeSpreadsheetField(_ field: String) -> String {
        guard field.hasPrefix("'") else { return field }
        let remainder = String(field.dropFirst())
        return remainder.hasPrefix("'") || needsSpreadsheetPrefix(remainder) ? remainder : field
    }

    public static func escapeField(_ field: String) -> String {
        let field = spreadsheetSafeField(field)
        let quoted = field.contains(",") || field.contains("\"") || field.contains("\r")
            || field.contains("\n") || field.first == " " || field.last == " "
        return quoted ? "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : field
    }
}
