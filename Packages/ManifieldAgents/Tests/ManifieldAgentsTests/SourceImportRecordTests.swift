import XCTest
import ManifieldCore
@testable import ManifieldAgents

final class SourceImportRecordTests: XCTestCase {

    private func makeRecord() -> SourceImportRecord {
        let chunks = [
            SourceImport.Chunk(title: "Part 1", section: "part-1", text: "one"),
            SourceImport.Chunk(title: "Part 2", section: "part-2", text: "two"),
            SourceImport.Chunk(title: "Part 3", section: "part-3", text: "three"),
        ]
        return SourceImportRecord(
            request: .init(name: "Book", authors: "A, B", citation: "A & B (2001)",
                           license: "", originalFileName: "original.pdf", convertToItems: true),
            fingerprint: .init(chunker: "pdf-pages-v1", chunkCount: 3,
                               chunkTextSHA256: SourceImportRecord.Fingerprint.hash(of: chunks)),
            chunks: chunks,
            warnings: ["extraction: something minor"])
    }

    func testQueriesReflectChunkStates() {
        var record = makeRecord()
        XCTAssertEqual(record.pendingIndices, [0, 1, 2])
        XCTAssertTrue(record.isResumable)

        record.chunks[1].status = .done
        record.chunks[1].itemIDs = ["thm-a", "def-b"]
        record.chunks[1].note = "chapter two note"
        record.chunks[2].status = .failed
        record.chunks[2].failureMessage = "bad JSON"

        XCTAssertEqual(record.pendingIndices, [0])
        XCTAssertEqual(record.failedIndices, [2])
        XCTAssertEqual(record.doneCount, 1)
        XCTAssertEqual(record.allItemIDs, ["thm-a", "def-b"])
        XCTAssertEqual(record.chunkNotes.map(\.note), ["chapter two note"])

        record.phase = .finished
        XCTAssertFalse(record.isResumable)
        XCTAssertTrue(record.hasRetryableFailures)
    }

    func testRoundTripThroughStore() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("record-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try ProjectStore.create(at: dir, name: "Book")

        var record = makeRecord()
        record.chunks[0].status = .done
        record.chunks[0].itemIDs = ["def-x"]
        record.phase = .paused
        record.save(to: store)

        let loaded = try XCTUnwrap(SourceImportRecord.load(from: store))
        XCTAssertEqual(loaded.phase, .paused)
        XCTAssertEqual(loaded.chunks.count, 3)
        XCTAssertEqual(loaded.chunks[0].itemIDs, ["def-x"])
        XCTAssertEqual(loaded.request.name, "Book")
        XCTAssertEqual(loaded.fingerprint, record.fingerprint)
        XCTAssertEqual(loaded.warnings, ["extraction: something minor"])

        // The store-less fast path used by the discovery scan reads the same file.
        let direct = try XCTUnwrap(SourceImportRecord.load(atSourceFolder: dir))
        XCTAssertEqual(direct.phase, .paused)

        SourceImportRecord.delete(atSourceFolder: dir)
        XCTAssertNil(SourceImportRecord.load(atSourceFolder: dir))
    }

    func testFingerprintDetectsTextDrift() {
        let chunks = [SourceImport.Chunk(title: "T", section: "s", text: "alpha")]
        let changed = [SourceImport.Chunk(title: "T", section: "s", text: "alpha!")]
        XCTAssertNotEqual(
            SourceImportRecord.Fingerprint.hash(of: chunks),
            SourceImportRecord.Fingerprint.hash(of: changed))
    }
}
