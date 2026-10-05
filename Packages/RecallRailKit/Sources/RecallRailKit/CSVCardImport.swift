import Foundation

/// Strict, previewed UTF-8 CSV import for cards.
///
/// ## Card CSV schema (documented contract)
///
/// - **Encoding:** UTF-8 only. A UTF-8 BOM is accepted and stripped (with a
///   warning). Text that is not valid UTF-8 is a document-level error; the
///   importer never guesses another encoding.
/// - **Header:** the first record is a header row. Required columns:
///   `prompt`, `answer`. Optional columns: `hint`, `source`, `tags`,
///   `id`, `sort`. Column ORDER is free; unknown columns are an ERROR —
///   a strict preview must not silently discard user data.
/// - **Quoting / line endings:** see `CSVDocument`. CRLF, LF, and CR all
///   parse; a document mixing terminator styles warns. Quoted fields may
///   contain commas, quotes, and newlines.
/// - **Blank lines:** completely empty records are ignored (reported as
///   `skippedBlankLines`), never imported as empty cards.
/// - **`tags`:** semicolon-separated (`exam;ch1`). Empty segments are
///   dropped; whitespace is trimmed; exact-case duplicates are removed,
///   order preserved.
/// - **`id`:** the stable card UUID exactly as exported. An `id` that is
///   not a valid UUID is an error. Re-importing exported rows with their
///   `id`s updates the matching card instead of duplicating it.
/// - **`sort`:** integer stable sort order. A missing column or missing
///   values assign sequential order by row. Non-integer values warn and
///   fall back to sequential order; duplicate values warn and are
///   normalized to sequential order preserving row order.
/// - **Row classification (preview):** against the deck's existing cards —
///   no matching ID → *addition*; matching ID with identical editable
///   fields → *skip* (unchanged); matching ID with any change → *update*.
/// - **Stable-ID behavior:** additions with no usable `id` receive fresh
///   UUIDs at commit time; identity never depends on row position, so a
///   re-export → re-import round-trip is update-safe.
/// - **Commit policy:** all-or-nothing is the default. A valid-rows-only
///   commit is available ONLY when the user explicitly opts in; rows with
///   errors are then reported and excluded, never partially applied within
///   a single valid row.
public enum CSVCardImport {

    // MARK: Preview types

    public enum RowOutcome: String, Equatable, Sendable {
        case addition
        case update
        case unchanged
    }

    public struct ProposedRow: Equatable, Sendable {
        public let lineNumber: Int
        public var outcome: RowOutcome
        /// The existing card this row updates/leaves unchanged, when any.
        public var existingID: StableID?
        /// The stable ID the committed card will carry (existing ID for
        /// updates, or the file-provided ID for additions with an `id`
        /// column; `nil` means a fresh UUID is assigned at commit).
        public let newID: StableID?
        public let prompt: String
        public let answer: String
        public let hint: String?
        public let source: String?
        public let tags: [String]
        public var sortOrder: Int
    }

    public struct Issue: Equatable, Sendable, Error {
        /// 1-based original file line; `nil` for document-level issues.
        public let lineNumber: Int?
        public let field: String?
        public let message: String

        public init(lineNumber: Int?, field: String?, message: String) {
            self.lineNumber = lineNumber
            self.field = field
            self.message = message
        }
    }

    public struct Preview: Equatable, Sendable {
        public let additions: [ProposedRow]
        public let updates: [ProposedRow]
        /// Rows whose content is identical to the stored card.
        public let unchanged: [ProposedRow]
        /// Completely blank records ignored by the parser.
        public let skippedBlankLines: Int
        public let warnings: [Issue]
        public let errors: [Issue]
        /// True when the source carried a UTF-8 BOM that was stripped.
        public let hadBOM: Bool

        /// Whether an all-or-nothing commit may proceed.
        public var canCommitAllOrNothing: Bool { errors.isEmpty }

        /// Document-level failures (bad encoding, missing/unknown header
        /// columns) make the whole file unusable — even valid-rows-only
        /// mode refuses to run on top of them. Row-level errors do not.
        public var documentIsValid: Bool {
            !errors.contains { $0.lineNumber == nil }
        }

        /// Whether a valid-rows-only commit still has work to do.
        public var canCommitValidRowsOnly: Bool {
            documentIsValid && !proposedRows.isEmpty
        }

        /// Rows that would be written in a commit.
        public var proposedRows: [ProposedRow] { additions + updates }

        /// Human-readable summary for VoiceOver / validation display.
        public var accessibilitySummary: String {
            var parts = [
                "\(additions.count) to add",
                "\(updates.count) to update",
                "\(unchanged.count) unchanged",
            ]
            if skippedBlankLines > 0 {
                parts.append("\(skippedBlankLines) blank lines skipped")
            }
            parts.append("\(warnings.count) warnings")
            parts.append("\(errors.count) errors")
            return parts.joined(separator: ", ")
        }

        init(additions: [ProposedRow], updates: [ProposedRow], unchanged: [ProposedRow],
             skippedBlankLines: Int, warnings: [Issue], errors: [Issue], hadBOM: Bool) {
            self.additions = additions
            self.updates = updates
            self.unchanged = unchanged
            self.skippedBlankLines = skippedBlankLines
            self.warnings = warnings
            self.errors = errors
            self.hadBOM = hadBOM
        }
    }

    // MARK: Decoding

    /// Decodes import bytes. UTF-8 is the ONLY accepted encoding.
    public static func decodeText(_ data: Data) -> Result<(text: String, hadBOM: Bool), Issue> {
        var hadBOM = false
        var bytes = data
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            hadBOM = true
            bytes = bytes.dropFirst(3)
        }
        guard let text = String(data: bytes, encoding: .utf8) else {
            return .failure(Issue(lineNumber: nil, field: nil,
                                  message: "File is not valid UTF-8. Re-export as UTF-8 and try again."))
        }
        return .success((text, hadBOM))
    }

    // MARK: Parsing + validation

    /// Parses CSV bytes and classifies every row against the deck's
    /// existing cards WITHOUT writing anything. All errors are collected
    /// so the user sees every problem before deciding to commit.
    public static func preview(data: Data, existingCards: [Card]) -> Preview {
        switch decodeText(data) {
        case let .failure(issue):
            return Preview(additions: [], updates: [], unchanged: [],
                           skippedBlankLines: 0, warnings: [], errors: [issue], hadBOM: false)
        case let .success(decoded):
            return preview(text: decoded.text, existingCards: existingCards, hadBOM: decoded.hadBOM)
        }
    }

    public static func preview(text: String, existingCards: [Card], hadBOM: Bool = false) -> Preview {
        let doc = CSVDocument(text: text)
        var warnings: [Issue] = []
        var errors: [Issue] = doc.syntaxErrors.map {
            Issue(lineNumber: $0.lineNumber, field: nil, message: $0.message)
        }
        if hadBOM || doc.hasBOM {
            warnings.append(Issue(lineNumber: nil, field: nil,
                                  message: "Removed UTF-8 byte-order mark before parsing."))
        }
        if doc.lineEnding == .mixed {
            warnings.append(Issue(lineNumber: nil, field: nil,
                                  message: "File mixes CRLF, LF, and CR line endings; all were accepted."))
        }

        guard let headerRow = doc.rows.first, headerRow.lineNumber == 1 else {
            return Preview(additions: [], updates: [], unchanged: [],
                           skippedBlankLines: 0, warnings: warnings,
                           errors: errors + [Issue(lineNumber: nil, field: nil,
                                          message: "A valid header row is required on line 1.")],
                           hadBOM: hadBOM)
        }

        let columns = headerRow.fields.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        let required = ["prompt", "answer"]
        let known = Set(required + ["hint", "source", "tags", "id", "sort"])
        // Header failures are DOCUMENT-level (lineNumber nil): even
        // valid-rows-only mode cannot run without a usable header.
        for name in required where !columns.contains(name) {
            errors.append(Issue(lineNumber: nil, field: name,
                                message: "Required column '\(name)' is missing (header line \(headerRow.lineNumber))."))
        }
        for (index, name) in columns.enumerated() where !name.isEmpty && !known.contains(name) {
            errors.append(Issue(lineNumber: nil, field: name,
                                message: "Unknown column '\(name)' in position \(index + 1); strict import refuses to discard columns."))
        }
        for name in Set(columns) where columns.filter({ $0 == name }).count > 1 {
            errors.append(Issue(lineNumber: nil, field: name,
                                message: "Duplicate '\(name)' column."))
        }
        if columns.contains("") {
            errors.append(Issue(lineNumber: nil, field: nil, message: "Empty header column."))
        }

        // A broken header makes row classification meaningless.
        guard !errors.contains(where: { $0.lineNumber == nil }) else {
            return Preview(additions: [], updates: [], unchanged: [],
                           skippedBlankLines: 0, warnings: warnings, errors: errors, hadBOM: hadBOM)
        }

        func column(_ name: String) -> Int? { columns.firstIndex(of: name) }
        let promptIdx = column("prompt")!
        let answerIdx = column("answer")!
        let hintIdx = column("hint")
        let sourceIdx = column("source")
        let tagsIdx = column("tags")
        let idIdx = column("id")
        let sortIdx = column("sort")

        var rows: [ProposedRow] = []
        var seenIDs: [StableID: Int] = [:] // file id -> first line using it
        var blankLines = doc.blankLines

        for row in doc.rows.dropFirst() {
            let line = row.lineNumber
            func trimmed(_ index: Int?) -> String {
                guard let index, index < row.fields.count else { return "" }
                return row.fields[index].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            // A record whose every field is whitespace-only (e.g. ",,")
            // is a blank line, not a card.
            if row.fields.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                blankLines += 1
                continue
            }
            // Extra fields beyond the header are data the user could lose.
            if row.fields.count > columns.count {
                errors.append(Issue(lineNumber: line, field: nil,
                                    message: "Row has \(row.fields.count) fields but the header defines \(columns.count)."))
                continue
            }
            if row.fields.count < columns.count {
                warnings.append(Issue(lineNumber: line, field: nil,
                                      message: "Row has \(row.fields.count) fields; missing trailing columns treated as empty."))
            }

            let prompt = trimmed(promptIdx)
            let answer = trimmed(answerIdx)
            var rowHasError = false
            if prompt.isEmpty {
                errors.append(Issue(lineNumber: line, field: "prompt", message: "Prompt is required."))
                rowHasError = true
            }
            if answer.isEmpty {
                errors.append(Issue(lineNumber: line, field: "answer", message: "Answer is required."))
                rowHasError = true
            }

            var stableID: StableID?
            let idText = trimmed(idIdx)
            if !idText.isEmpty {
                if let parsed = StableID(parsing: idText) {
                    stableID = parsed
                } else {
                    errors.append(Issue(lineNumber: line, field: "id",
                                        message: "'\(idText)' is not a valid UUID."))
                    rowHasError = true
                }
            }
            if let stableID {
                if let firstLine = seenIDs[stableID] {
                    errors.append(Issue(lineNumber: line, field: "id",
                                        message: "Duplicate stable ID also used on line \(firstLine)."))
                    rowHasError = true
                } else {
                    seenIDs[stableID] = line
                }
            }

            let tags = tagsIdx.flatMap { idx in
                idx < row.fields.count ? parseTags(row.fields[idx]) : nil
            } ?? []

            var sortOrder = -1
            let sortText = trimmed(sortIdx)
            if !sortText.isEmpty {
                if let value = Int(sortText) {
                    sortOrder = value
                } else {
                    warnings.append(Issue(lineNumber: line, field: "sort",
                                          message: "'\(sortText)' is not an integer; sequential order will be used."))
                }
            }
            if rowHasError { continue }
            rows.append(ProposedRow(lineNumber: line, outcome: .addition, existingID: nil,
                                    newID: stableID, prompt: prompt, answer: answer,
                                    hint: trimmed(hintIdx).nilIfEmpty,
                                    source: trimmed(sourceIdx).nilIfEmpty,
                                    tags: tags, sortOrder: sortOrder))
        }

        // Normalize sort order: sequential where missing or duplicated.
        var needsSequentialFallback = sortIdx == nil
        if sortIdx != nil {
            let present = rows.filter { $0.sortOrder >= 0 }.map(\.sortOrder)
            needsSequentialFallback = rows.contains { $0.sortOrder < 0 }
                || Set(present).count != present.count
            if needsSequentialFallback {
                warnings.append(Issue(lineNumber: nil, field: "sort",
                                      message: "Missing or duplicate sort values normalized to sequential row order."))
            }
        }
        if needsSequentialFallback {
            rows = rows.enumerated().map { index, row in
                var fixed = row
                fixed.sortOrder = index
                return fixed
            }
        }

        // Classify against stored cards.
        let existingByID = Dictionary(existingCards.map { ($0.id, $0) },
                                      uniquingKeysWith: { first, _ in first })
        var additions: [ProposedRow] = []
        var updates: [ProposedRow] = []
        var unchanged: [ProposedRow] = []
        for var row in rows {
            if let id = row.newID, let existing = existingByID[id] {
                let sameContent = existing.prompt == row.prompt
                    && existing.answer == row.answer
                    && (existing.hint ?? "") == (row.hint ?? "")
                    && (existing.source ?? "") == (row.source ?? "")
                    && existing.tags == row.tags
                    && existing.sortOrder == row.sortOrder
                row.outcome = sameContent ? .unchanged : .update
                row.existingID = id
                if sameContent { unchanged.append(row) } else { updates.append(row) }
            } else {
                row.outcome = .addition
                additions.append(row)
            }
        }

        return Preview(additions: additions, updates: updates, unchanged: unchanged,
                       skippedBlankLines: blankLines, warnings: warnings, errors: errors,
                       hadBOM: hadBOM)
    }

    /// Splits the semicolon-delimited `tags` cell.
    public static func parseTags(_ cell: String) -> [String] {
        var seen = Set<String>()
        var tags: [String] = []
        for piece in cell.components(separatedBy: ";") {
            let tag = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tag.isEmpty, !seen.contains(tag) else { continue }
            seen.insert(tag)
            tags.append(tag)
        }
        return tags
    }

    // MARK: Commit materialization

    /// Builds the domain cards a preview would write. `deckID` and the
    /// injected clock keep this deterministic and offline; persistence is
    /// the caller's transactional step (see `RecallRepository.importCards`).
    /// Update rows carry over the stored card's identity, creation time,
    /// and archived flag — an import edits content, never history.
    public static func cards(from preview: Preview, deckID: StableID,
                             existingCards: [Card], at instant: Date) -> [Card] {
        let existingByID = Dictionary(existingCards.map { ($0.id, $0) },
                                      uniquingKeysWith: { first, _ in first })
        return preview.proposedRows.map { row in
            if let id = row.existingID, var updated = existingByID[id] {
                updated.prompt = row.prompt
                updated.answer = row.answer
                updated.hint = row.hint
                updated.source = row.source
                updated.tags = row.tags
                updated.sortOrder = row.sortOrder
                updated.updatedAt = instant
                return updated
            }
            let id = row.newID ?? StableID()
            return Card(id: id, deckID: deckID, prompt: row.prompt, answer: row.answer,
                        hint: row.hint, source: row.source, tags: row.tags,
                        sortOrder: row.sortOrder, createdAt: instant, updatedAt: instant)
        }
    }

    // MARK: Export

    /// Serializes cards with their stable IDs so an export → edit → import
    /// round-trip updates instead of duplicating.
    public static func exportCSV(cards: [Card]) -> String {
        var rows: [[String]] = [["id", "prompt", "answer", "hint", "source", "tags", "sort"]]
        for card in cards.sorted(by: { $0.sortOrder < $1.sortOrder }) {
            rows.append([
                card.id.rawValue,
                card.prompt,
                card.answer,
                card.hint ?? "",
                card.source ?? "",
                card.tags.joined(separator: ";"),
                String(card.sortOrder),
            ])
        }
        return CSVDocument.serialize(rows: rows)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
