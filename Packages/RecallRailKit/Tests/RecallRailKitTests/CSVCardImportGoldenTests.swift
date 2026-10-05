import Foundation
import XCTest
@testable import RecallRailKit

/// Golden-fixture coverage for the card CSV contract: commas, quotes,
/// multiline fields, BOM markers, Unicode, duplicate IDs, missing columns,
/// and malformed rows — plus the preview's add/update/skip/warning/error
/// classification the import UI is built on.
final class CSVCardImportGoldenTests: XCTestCase {

    static func fixture(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
        return try Data(contentsOf: url)
    }

    static func fixtureText(_ name: String) throws -> String {
        String(data: try fixture(name), encoding: .utf8)!
    }

    // MARK: CSVDocument parser golden behavior

    func testCommasAndQuotesGolden() throws {
        let doc = CSVDocument(text: try Self.fixtureText("commas_quotes.csv"))
        XCTAssertEqual(doc.rows.count, 4) // header + 3
        XCTAssertEqual(doc.rows[1].fields[1], "Question, with a comma")
        XCTAssertEqual(doc.rows[1].fields[2], "Answer, with, several, commas")
        XCTAssertEqual(doc.rows[2].fields[1], "She said \"hello\"")
        XCTAssertEqual(doc.rows[2].fields[4], "A \"quoted\" source")
        XCTAssertEqual(doc.lineEnding, .lf)
    }

    func testMultilineFieldsReportOriginalLineNumbers() throws {
        let doc = CSVDocument(text: try Self.fixtureText("multiline.csv"))
        XCTAssertEqual(doc.rows.count, 3) // header + 2 records spanning 5 lines
        XCTAssertEqual(doc.rows[1].fields[0], "First\nline\nbreak")
        XCTAssertEqual(doc.rows[1].fields[1], "Multi\nline\nanswer")
        XCTAssertEqual(doc.rows[1].lineNumber, 2)
        XCTAssertEqual(doc.rows[2].lineNumber, 7)
        XCTAssertEqual(doc.rows[2].fields[1], "Keeps \"quoted\"\nnewline inside")
    }

    func testBOMIsStrippedAndReported() throws {
        // Foundation may strip a byte BOM during Data -> String decoding.
        let doc = CSVDocument(text: "\u{FEFF}" + (try Self.fixtureText("bom_crlf.csv")))
        XCTAssertTrue(doc.hasBOM)
        XCTAssertEqual(doc.rows.first?.fields.first, "prompt")
        XCTAssertEqual(doc.lineEnding, .crlf)
    }

    func testUnicodeRoundTrips() throws {
        let doc = CSVDocument(text: try Self.fixtureText("unicode.csv"))
        XCTAssertEqual(doc.rows[1].fields[0], "Ωmega Γραμμή")
        XCTAssertEqual(doc.rows[1].fields[1], "Éàü 中文 🎓")
        XCTAssertEqual(doc.rows[2].fields[0], "naïve café")
    }

    func testMixedLineEndingsDetected() throws {
        let doc = CSVDocument(text: try Self.fixtureText("mixed_endings.csv"))
        XCTAssertEqual(doc.lineEnding, .mixed)
        XCTAssertEqual(doc.rows.count, 4) // header, A1, A2, A3
        XCTAssertEqual(doc.blankLines, 1) // the interior empty record
    }

    func testTrailingNewlineProducesNoPhantomRow() throws {
        let doc = CSVDocument(text: "a,b\n")
        XCTAssertEqual(doc.rows.count, 1)
        XCTAssertEqual(doc.blankLines, 0)
    }

    func testEmptyDocumentParsesToNoRows() {
        let doc = CSVDocument(text: "")
        XCTAssertTrue(doc.rows.isEmpty)
        XCTAssertEqual(doc.lineEnding, .none)
    }

    func testCROnlyTerminators() {
        let doc = CSVDocument(text: "a,b\rc,d\r")
        XCTAssertEqual(doc.rows.count, 2)
        XCTAssertEqual(doc.lineEnding, .cr)
    }

    func testSerializerQuotesAmbiguousFields() {
        let csv = CSVDocument.serialize(rows: [["a,b", "with \"quotes\"", " padded ", "plain"]])
        XCTAssertEqual(csv, "\"a,b\",\"with \"\"quotes\"\"\",\" padded \",plain\r\n")
        // Round-trip keeps whitespace-bearing fields intact.
        let back = CSVDocument(text: csv)
        XCTAssertEqual(back.rows.count, 1)
        XCTAssertEqual(back.rows[0].fields, ["a,b", "with \"quotes\"", " padded ", "plain"])
    }

    // MARK: Preview classification golden behavior

    func testPreviewClassifiesAdditionsUpdatesAndUnchanged() throws {
        let deckID = StableID()
        let knownID = StableID(parsing: "2A111111-1111-1111-1111-111111111111")!
        let now = Date(timeIntervalSince1970: 1_775_000_000)
        let existing = Card(id: knownID, deckID: deckID, prompt: "Old prompt",
                            answer: "Answer, with, several, commas", tags: ["quiz,ch1"],
                            sortOrder: 0, createdAt: now, updatedAt: now)
        let preview = CSVCardImport.preview(data: try Self.fixture("commas_quotes.csv"),
                                            existingCards: [existing])
        // Row 1 shares the known ID but changes the prompt -> update.
        // Rows 2-3 have fresh/absent IDs -> additions (row 3 has no id column value).
        XCTAssertEqual(preview.updates.count, 1)
        XCTAssertEqual(preview.updates.first?.existingID, knownID)
        XCTAssertEqual(preview.additions.count, 2)
        XCTAssertTrue(preview.errors.isEmpty)
        XCTAssertTrue(preview.canCommitAllOrNothing)
    }

    func testPreviewUnchangedRowIsSkipped() throws {
        let deckID = StableID()
        let id = StableID(parsing: "2A111111-1111-1111-1111-111111111111")!
        let now = Date(timeIntervalSince1970: 1_775_000_000)
        let text = """
        id,prompt,answer,tags,sort
        \(id.rawValue),Same,Same,"quiz,ch1",0
        """
        let stored = Card(id: id, deckID: deckID, prompt: "Same", answer: "Same",
                          tags: ["quiz,ch1"], sortOrder: 0, createdAt: now, updatedAt: now)
        let preview = CSVCardImport.preview(text: text, existingCards: [stored])
        XCTAssertEqual(preview.unchanged.count, 1)
        XCTAssertTrue(preview.additions.isEmpty)
        XCTAssertTrue(preview.updates.isEmpty)
    }

    func testDuplicateIDsAreErrorsWithLineNumbers() throws {
        let preview = CSVCardImport.preview(data: try Self.fixture("duplicate_ids.csv"),
                                            existingCards: [])
        XCTAssertEqual(preview.errors.count, 1)
        XCTAssertEqual(preview.errors.first?.lineNumber, 3)
        XCTAssertEqual(preview.errors.first?.field, "id")
        XCTAssertFalse(preview.canCommitAllOrNothing)
        // Row-level errors never poison the document itself.
        XCTAssertTrue(preview.documentIsValid)
        XCTAssertTrue(preview.canCommitValidRowsOnly)
    }

    func testMissingRequiredColumnIsDocumentLevelError() throws {
        let preview = CSVCardImport.preview(data: try Self.fixture("missing_answer.csv"),
                                            existingCards: [])
        XCTAssertEqual(preview.errors.count, 1)
        XCTAssertEqual(preview.errors.first?.field, "answer")
        XCTAssertFalse(preview.documentIsValid)
        XCTAssertFalse(preview.canCommitAllOrNothing)
        XCTAssertFalse(preview.canCommitValidRowsOnly)
    }

    func testUnknownColumnIsDocumentLevelError() throws {
        let preview = CSVCardImport.preview(text: "prompt,answer,brain_score\nA,B,5\n",
                                            existingCards: [])
        XCTAssertEqual(preview.errors.count, 1)
        XCTAssertEqual(preview.errors.first?.field, "brain_score")
        XCTAssertFalse(preview.documentIsValid)
    }

    func testShortRowWarnsAndPadsMissingTrailingColumns() throws {
        let preview = CSVCardImport.preview(data: try Self.fixture("short_row.csv"),
                                            existingCards: [])
        XCTAssertEqual(preview.additions.count, 2)
        XCTAssertTrue(preview.warnings.contains { $0.lineNumber == 2 })
        XCTAssertEqual(preview.errors.count, 0)
    }

    func testMalformedRowsCollectEveryErrorBeforeCommit() throws {
        let preview = CSVCardImport.preview(data: try Self.fixture("malformed_rows.csv"),
                                            existingCards: [])
        // line 2: missing prompt; line 3: invalid UUID; line 4: missing
        // prompt (and non-integer sort warning); line 5: OK row with a
        // non-integer sort warning only.
        XCTAssertEqual(preview.errors.count, 3)
        XCTAssertEqual(Set(preview.errors.compactMap(\.lineNumber)), [2, 3, 4])
        XCTAssertEqual(preview.additions.count, 1) // only the OK row survives
        XCTAssertEqual(preview.additions.first?.prompt, "OK row")
        XCTAssertFalse(preview.canCommitAllOrNothing)
        XCTAssertTrue(preview.canCommitValidRowsOnly)
    }

    func testBOMProducesWarningButStillImports() throws {
        let preview = CSVCardImport.preview(data: try Self.fixture("bom_crlf.csv"),
                                            existingCards: [])
        XCTAssertTrue(preview.hadBOM)
        XCTAssertEqual(preview.additions.count, 1)
        XCTAssertTrue(preview.errors.isEmpty)
        XCTAssertTrue(preview.warnings.contains { $0.message.contains("byte-order mark") })
    }

    func testTagCellParsesSemisTrimsAndDedupes() throws {
        let preview = CSVCardImport.preview(data: try Self.fixture("commas_quotes.csv"),
                                            existingCards: [])
        let tagged = preview.additions.first { $0.prompt == "Simple" }
        XCTAssertEqual(tagged?.tags, ["tag1", "tag2"])
    }

    func testMissingSortColumnAssignsSequentialOrder() throws {
        let preview = CSVCardImport.preview(text: "prompt,answer\nA,1\nB,2\nC,3\n",
                                            existingCards: [])
        XCTAssertEqual(preview.additions.map(\.sortOrder), [0, 1, 2])
    }

    func testDuplicateSortValuesNormalizeWithWarning() throws {
        let preview = CSVCardImport.preview(text: "prompt,answer,sort\nA,1,5\nB,2,5\nC,3,9\n",
                                            existingCards: [])
        XCTAssertEqual(preview.additions.map(\.sortOrder), [0, 1, 2])
        XCTAssertTrue(preview.warnings.contains { $0.field == "sort" })
    }

    func testNonIntegerSortWarnsButKeepsValidRows() throws {
        let preview = CSVCardImport.preview(data: try Self.fixture("malformed_rows.csv"),
                                            existingCards: [])
        XCTAssertTrue(preview.warnings.contains { $0.lineNumber == 5 && $0.field == "sort" })
    }

    func testUnterminatedQuoteSwallowsRestAndIsReported() throws {
        // RFC 4180 behavior: an opened quote never closes, so the rest of
        // the file becomes one record. The preview must surface it as an
        // error (missing answer / extra field), never silently import or
        // silently drop it.
        let preview = CSVCardImport.preview(data: try Self.fixture("unterminated_quote.csv"),
                                            existingCards: [])
        XCTAssertTrue(preview.additions.isEmpty)
        XCTAssertFalse(preview.errors.isEmpty)
        XCTAssertFalse(preview.canCommitAllOrNothing)
        XCTAssertEqual(preview.errors.first?.lineNumber, 2)
    }

    func testMalformedQuotingExcludesRowInValidRowsOnlyMode() {
        let preview = CSVCardImport.preview(text: "prompt,answer\nBad\"quote,answer\nGood,answer\n",
                                            existingCards: [])
        XCTAssertEqual(preview.errors.map(\.lineNumber), [2])
        XCTAssertEqual(preview.additions.map(\.prompt), ["Good"])
        XCTAssertFalse(preview.canCommitAllOrNothing)
        XCTAssertTrue(preview.canCommitValidRowsOnly)
    }

    func testDuplicateRequiredHeaderAndEmptyColumnAbortDocument() {
        let preview = CSVCardImport.preview(text: "prompt,answer,prompt,\nA,B,C,D\n",
                                            existingCards: [])
        XCTAssertFalse(preview.documentIsValid)
        XCTAssertTrue(preview.additions.isEmpty)
    }

    func testCRLFTerminatorsAndMultilineScalarBoundaries() {
        let doc = CSVDocument(text: "prompt,answer\r\n\"first\r\nsecond\",yes\r\nnext,ok\r\n")
        XCTAssertEqual(doc.rows.count, 3)
        XCTAssertEqual(doc.rows[1].fields[0], "first\r\nsecond")
        XCTAssertEqual(doc.rows[2].lineNumber, 4)
        XCTAssertEqual(doc.lineEnding, .crlf)
    }

    func testCommaOnlyRecordCannotSilentlyPassAllOrNothing() {
        let preview = CSVCardImport.preview(text: "prompt,answer\n,\nGood,answer\n",
                                            existingCards: [])
        XCTAssertEqual(preview.additions.map(\.prompt), ["Good"])
        XCTAssertEqual(Set(preview.errors.compactMap(\.field)), ["prompt", "answer"])
        XCTAssertFalse(preview.canCommitAllOrNothing)
        XCTAssertTrue(preview.canCommitValidRowsOnly)
    }

    func testNonUTF8DataIsDocumentError() {
        let broken = Data([0xFF, 0xFE, 0x00, 0x41]) // not valid UTF-8
        let preview = CSVCardImport.preview(data: broken, existingCards: [])
        XCTAssertEqual(preview.errors.count, 1)
        XCTAssertFalse(preview.documentIsValid)
    }

    func testAccessibilitySummaryCountsEveryBucket() throws {
        let preview = CSVCardImport.preview(data: try Self.fixture("malformed_rows.csv"),
                                            existingCards: [])
        let summary = preview.accessibilitySummary
        XCTAssertTrue(summary.contains("1 to add"))
        XCTAssertTrue(summary.contains("3 errors"))
    }

    // MARK: Save/import round-trip through stable IDs

    func testExportThenImportIsUpdateNotDuplicate() throws {
        let deckID = StableID()
        let now = Date(timeIntervalSince1970: 1_775_000_000)
        let cards = [
            Card(deckID: deckID, prompt: "Prompt, one", answer: "Answer \"A\"",
                 hint: "h", source: "s", tags: ["a", "b"], sortOrder: 0,
                 createdAt: now, updatedAt: now),
            Card(deckID: deckID, prompt: "第二", answer: "two 🎓",
                 tags: ["c"], sortOrder: 1, createdAt: now, updatedAt: now),
        ]
        let csv = CSVCardImport.exportCSV(cards: cards)
        let preview = CSVCardImport.preview(text: csv, existingCards: cards)
        XCTAssertTrue(preview.errors.isEmpty)
        XCTAssertEqual(preview.additions.count, 0)
        XCTAssertEqual(preview.updates.count, 0)
        XCTAssertEqual(preview.unchanged.count, 2)
    }

    func testMaterializedCardsPreserveIdentityAndCreationTime() throws {
        let deckID = StableID()
        let created = Date(timeIntervalSince1970: 1_600_000_000)
        let updated = Date(timeIntervalSince1970: 1_775_000_000)
        let commitAt = Date(timeIntervalSince1970: 1_800_000_000)
        let existing = Card(deckID: deckID, prompt: "Old", answer: "Old",
                            sortOrder: 0, createdAt: created, updatedAt: updated)
        let text = "id,prompt,answer\n\(existing.id.rawValue),New,New\n"
        let preview = CSVCardImport.preview(text: text, existingCards: [existing])
        let cards = CSVCardImport.cards(from: preview, deckID: deckID,
                                        existingCards: [existing], at: commitAt)
        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards[0].id, existing.id)
        XCTAssertEqual(cards[0].createdAt, created, "import must never rewrite creation time")
        XCTAssertEqual(cards[0].updatedAt, commitAt)
        XCTAssertEqual(cards[0].prompt, "New")
    }
}
