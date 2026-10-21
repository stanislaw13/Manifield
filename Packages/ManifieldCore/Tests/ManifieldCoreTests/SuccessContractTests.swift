import XCTest
@testable import ManifieldCore

final class SuccessContractTests: XCTestCase {

    /// The fixture's contract. Two forms, because the question is binary — but the point of
    /// the type is that it does not have to be, so the multi-case fixture below matters more.
    private func binaryContract() -> SuccessContract {
        SuccessContract(
            statement: "Does every k-element set with distinct subset sums have max ≥ c·2^k?",
            completeAnswers: [
                .init(id: "A1", statement: "A proof that m(k) ≥ c·2^k for an absolute constant c",
                      evidence: "a reviewed proof"),
                .init(id: "A2", statement: "A family of sets with max = o(2^k)",
                      evidence: "the family, plus a verified check of distinct subset sums")
            ],
            completenessRationale: "The statement is a universally quantified inequality: it "
                + "either holds for some absolute constant or a family witnesses that it does "
                + "not. There is no third possibility.")
    }

    /// A question whose complete answers do not divide into two sides at all — the shape the
    /// old rung ladder and its obvious repair (a positive/negative axis) both got wrong.
    private func multiCaseContract() -> SuccessContract {
        SuccessContract(
            statement: "For which n does a Steiner triple system on n points exist?",
            completeAnswers: [
                .init(id: "A1", statement: "A construction for every n ≡ 1 or 3 (mod 6)",
                      evidence: "an explicit construction, verified for the residue classes"),
                .init(id: "A2", statement: "A proof that no system exists for any other n",
                      evidence: "a counting or divisibility argument, reviewed"),
                .init(id: "A3", statement: "A complete classification answering both at once",
                      evidence: "a reviewed proof covering every residue class")
            ],
            completenessRationale: "The question asks for a characterisation of a set of n. "
                + "It is answered by settling membership in both directions, either "
                + "separately or in one classification.")
    }

    // MARK: - Shape

    func testAWellFormedContractHasNoProblems() {
        XCTAssertEqual(binaryContract().validationProblems, [])
        XCTAssertEqual(multiCaseContract().validationProblems, [])
    }

    func testAnswerLookupIsCaseInsensitive() {
        XCTAssertEqual(binaryContract().answer(id: "a2")?.id, "A2")
    }

    func testCitableIDsAreTheAnswerIDs() {
        XCTAssertEqual(binaryContract().citableAnswerIDs, ["A1", "A2"])
    }

    /// A contract with only one form is legitimate — some questions really do have one — but
    /// only when the drafter has said why, which is exactly what the rationale is for.
    func testASingleFormContractIsAllowedWithARationale() {
        var contract = binaryContract()
        contract.completeAnswers = [contract.completeAnswers[0]]
        XCTAssertEqual(contract.validationProblems, [])
    }

    // MARK: - Legacy metadata validation

    /// The guard the whole type exists for. A drafter that mirrors the imperative grammar of
    /// the request ("find a number with property P") admits only the answer that grammar
    /// suggests, and a branch that correctly proves no such number exists then has no way to
    /// report success. Requiring the argument is what makes that visible before it binds.
    func testAContractWithoutACompletenessArgumentIsRejected() {
        var contract = binaryContract()
        contract.completenessRationale = ""
        XCTAssertTrue(contract.validationProblems.contains { $0.contains("completeness rationale") })
    }

    func testAWhitespaceOnlyRationaleIsRejected() {
        var contract = binaryContract()
        contract.completenessRationale = "   \n  "
        XCTAssertFalse(contract.validationProblems.isEmpty)
    }

    func testAStatementOnlyTargetNeedsNoAnswerTaxonomy() {
        var contract = binaryContract()
        contract.completeAnswers = []
        contract.completenessRationale = ""
        XCTAssertEqual(contract.validationProblems, [])
    }

    func testDuplicateAnswerIDsAreRejected() {
        var contract = binaryContract()
        contract.completeAnswers[1].id = "a1"
        XCTAssertTrue(contract.validationProblems.contains { $0.contains("unique") })
    }

    func testABlankAnswerIDIsRejected() {
        var contract = binaryContract()
        contract.completeAnswers[0].id = "  "
        XCTAssertFalse(contract.validationProblems.isEmpty)
    }

    /// "How would anyone know" is the discipline. A form nobody can check is not a form.
    func testAnAnswerWithoutAnEvidenceRuleIsRejected() {
        var contract = binaryContract()
        contract.completeAnswers[0].evidence = ""
        XCTAssertTrue(contract.validationProblems.contains { $0.contains("how a claim") })
    }

    func testAnAnswerWithoutAStatementIsRejected() {
        var contract = binaryContract()
        contract.completeAnswers[1].statement = ""
        XCTAssertFalse(contract.validationProblems.isEmpty)
    }

    func testAContractWithoutAStatementIsRejected() {
        var contract = binaryContract()
        contract.statement = ""
        XCTAssertTrue(contract.validationProblems.contains { $0.contains("no statement") })
    }

    // MARK: - Review

    func testAContractIsUnreviewedUntilAHumanApprovesIt() {
        var contract = binaryContract()
        XCTAssertFalse(contract.isReviewed)
        contract.reviewedAt = Date()
        XCTAssertTrue(contract.isReviewed)
    }

    func testNewTargetsDoNotWriteExclusions() {
        XCTAssertEqual(binaryContract().notCounted, [])
        XCTAssertTrue(SuccessContract.standardExclusions
            .contains { $0.contains("novelty claim") })
    }

    // MARK: - Persistence

    func testAContractSurvivesAProgramRoundTrip() throws {
        var contract = multiCaseContract()
        contract.recommendedReading = "Take system to mean the combinatorial design."
        contract.ambiguities = ["'system' could mean a design or its automorphism group — took the design"]
        let program = ResearchProgram(id: "p", goal: "g", contract: contract)
        let data = try JSONEncoder().encode(program)
        let decoded = try JSONDecoder().decode(ResearchProgram.self, from: data)
        XCTAssertEqual(decoded.contract, contract)
        XCTAssertEqual(decoded.contract?.completeAnswers.count, 3)
        XCTAssertEqual(decoded.contract?.recommendedReading,
                       "Take system to mean the combinatorial design.")
        XCTAssertEqual(decoded.contract?.ambiguities.count, 1)
    }

    func testAManifestWrittenBeforeContractsExistedStillDecodes() throws {
        let json = #"{"id":"p","goal":"g","status":"active","maxConcurrentBranches":1,"programTokenBudget":1000,"branches":[],"findings":[],"skippedCells":[],"created":"2026-01-01T00:00:00Z","updated":"2026-01-01T00:00:00Z"}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let program = try decoder.decode(ResearchProgram.self, from: Data(json.utf8))
        XCTAssertNil(program.contract)
        XCTAssertTrue(program.routings.isEmpty)
        XCTAssertTrue(program.solutions.isEmpty)
    }

    /// A contract written under the rung ladder decodes with its answers empty rather than
    /// throwing. Deliberately not migrated: a target rung promoted to a "complete answer"
    /// with no completeness argument behind it is more misleading than an absent contract,
    /// and `validationProblems` will say so the moment anyone looks.
    func testALadderEraContractDecodesWithoutItsLadder() throws {
        let json = #"{"statement":"S","affirmative":"A","negative":"N","notCounted":["x"],"ladder":[{"id":"L1","statement":"r","requiresArtifact":false,"achieved":false}],"version":1}"#
        let contract = try JSONDecoder().decode(SuccessContract.self, from: Data(json.utf8))
        XCTAssertEqual(contract.statement, "S")
        XCTAssertEqual(contract.notCounted, ["x"])
        XCTAssertTrue(contract.completeAnswers.isEmpty)
        XCTAssertEqual(contract.validationProblems, [])
    }
}
