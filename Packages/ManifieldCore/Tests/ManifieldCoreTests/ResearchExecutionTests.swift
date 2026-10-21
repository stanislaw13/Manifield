import XCTest
@testable import ManifieldCore

final class ResearchExecutionTests: XCTestCase {
    func testProgramRoundTripPreservesUnlimitedAssignmentOwnershipAndReports() throws {
        var program = ResearchProgram(id: "p", goal: "g", execution: .init(limits: .unlimited))
        var assignment = ResearchAssignment(id: "a", operationID: "op", programID: program.id,
            targetRevisionID: program.activeTargetRevisionID, mode: .direct, objective: "Inspect a lemma")
        assignment.reports = [.init(outcome: .partial, summary: "Reduction found", unresolved: "Midpoint gap",
                                    stopReason: .question, itemIDs: ["lem-local"])]
        program.execution!.assignments.append(assignment)
        program.execution!.append(.reported, target: program.activeTargetRevisionID, assignmentID: assignment.id,
                                  summary: "Reduction", references: ["lem-local"])
        let decoded = try JSONDecoder().decode(ResearchProgram.self, from: JSONEncoder().encode(program))
        XCTAssertEqual(decoded.execution, program.execution)
        XCTAssertNil(decoded.execution?.assignments[0].planID)
        XCTAssertFalse(decoded.execution!.limits.programTokens.reached(Int.max))
        XCTAssertEqual(decoded.execution?.events.last?.sequence, 1)
    }

    func testHeadlineIsFirstSentenceOutsideMathAndAbbreviations() {
        XCTAssertEqual(ResearchText.headline("The frozen statement is false. Let $E=\\mathbb{R}$ and $F=\\mathbb{R}^2$."),
                       "The frozen statement is false.")
        XCTAssertEqual(ResearchText.headline("Take $x = 1. y$ and e.g. the norm. Then more follows."),
                       "Take $x = 1. y$ and e.g. the norm.")
        XCTAssertEqual(ResearchText.headline("Both sets are open and connected in U. But no affine map is onto."),
                       "Both sets are open and connected in U.")
        XCTAssertEqual(ResearchText.headline("## Result\nIgnored second line."), "Result")
    }

    func testClampNeverLeavesMathUnbalanced() {
        let text = "Short words then $\\sum_{i=1}^{n} a_i b_i \\le \\sqrt{\\sum a_i^2}\\sqrt{\\sum b_i^2}$ afterwards"
        let clamped = ResearchText.clamp(text, maxLength: 40)
        XCTAssertEqual(clamped, "Short words then…")
        XCTAssertEqual(ResearchText.clamp("fits", maxLength: 40), "fits")
    }

    func testAssignmentsAndReportsSavedBeforeShortLabelsFallBackToTheirText() throws {
        let assignment = ResearchAssignment(id: "a", operationID: "op", programID: "p", targetRevisionID: "t",
            mode: .direct, objective: "Independently test the exact frozen problem for a counterexample. If false, submit a challenge.")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(assignment)) as? [String: Any])
        object.removeValue(forKey: "title")
        let decoded = try JSONDecoder().decode(ResearchAssignment.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.title)
        XCTAssertEqual(decoded.displayTitle, "Independently test the exact frozen problem for a counterexample.")

        let titled = ResearchAssignment(operationID: "op2", programID: "p", targetRevisionID: "t", mode: .direct,
                                        objective: "Long objective.", title: "  Midpoint identity  ")
        XCTAssertEqual(titled.displayTitle, "Midpoint identity")

        let report = AssignmentReport(outcome: .partial, summary: "Reduced to the midpoint identity. The rest is open.")
        XCTAssertNil(report.headline)
        XCTAssertEqual(report.displayHeadline, "Reduced to the midpoint identity.")
    }

    func testLegacyManifestDoesNotInventExecutionOrAssignments() throws {
        let program = ResearchProgram(id: "legacy", goal: "old test")
        let decoded = try JSONDecoder().decode(ResearchProgram.self, from: JSONEncoder().encode(program))
        XCTAssertNil(decoded.execution)
    }
}
