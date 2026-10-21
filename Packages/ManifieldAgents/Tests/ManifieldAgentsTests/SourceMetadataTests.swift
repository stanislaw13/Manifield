import XCTest
@testable import ManifieldAgents

final class SourceMetadataTests: XCTestCase {

    func testParsesFencedObject() throws {
        let response = """
        Here you go:
        ```json
        {"name": "Introduction to Complex Analytic Geometry",
         "authors": ["Stanisław Łojasiewicz"],
         "citation": "Łojasiewicz, Birkhäuser 1991"}
        ```
        """
        let extracted = try SourceMetadata.parse(response)
        XCTAssertEqual(extracted.name, "Introduction to Complex Analytic Geometry")
        XCTAssertEqual(extracted.authors, ["Stanisław Łojasiewicz"])
        XCTAssertEqual(extracted.citation, "Łojasiewicz, Birkhäuser 1991")
    }

    func testEmptyAndNullFieldsCollapseToNil() throws {
        let extracted = try SourceMetadata.parse(
            #"{"name": "  ", "authors": ["", "  A. Author "], "citation": null}"#)
        XCTAssertNil(extracted.name)
        XCTAssertEqual(extracted.authors, ["A. Author"])
        XCTAssertNil(extracted.citation)
    }

    func testNoObjectThrows() {
        XCTAssertThrowsError(try SourceMetadata.parse("sorry, no metadata found"))
    }

    func testObjectExtractionRespectsStrings() {
        let text = #"noise {"name": "a } b"} trailing"#
        XCTAssertEqual(SourceMetadata.extractJSONObject(from: text), #"{"name": "a } b"}"#)
    }
}
