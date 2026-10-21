import XCTest
import ManifieldCore
@testable import ManifieldAgents

final class PortfolioAuditorTests: XCTestCase {
    private func proposal(activateSecond: Bool = false) -> ApproachProposal {
        ApproachProposal(
            goal: "Classify all groups in C.", title: "Classification",
            approaches: [
                .init(
                    title: "Boundary construction",
                    mechanism: "Construct examples at every boundary and search for a family omitted by the candidate classification.",
                    prior: "Assume the tentative list is incomplete.",
                    expectedPayoff: "Either an omitted family or evidence that closes a boundary case.",
                    challengesLeadingAnswer: false,
                    ontologyCells: ["construction"],
                    killCriterion: "Every boundary construction reduces to a listed family.",
                    activate: true),
                .init(
                    title: "Duplicate route",
                    mechanism: "Repeat the same constructions.",
                    prior: "Try again.", expectedPayoff: "little",
                    ontologyCells: ["construction"], killCriterion: "stop",
                    activate: activateSecond)
            ], skippedCells: [])
    }

    func testAuditAcceptsOneRouteByItsConcreteCompletenessTestNotALabel() async throws {
        let provider = PortfolioAuditProvider(json: #"""
        {"accepted":true,
         "falsification_path":"The boundary construction actively searches for an omitted family.",
         "gaps":[],"note":"One route is sufficient here."}
        """#)
        let audit = try await PortfolioAuditor.audit(
            runner: AgentLoop(provider: provider), goal: "Classify all groups in C.",
            contract: nil, proposal: proposal(), evidenceDigest: "Recognition isolated completeness.")
        XCTAssertTrue(audit.accepted)
        XCTAssertTrue(audit.falsificationPath.contains("omitted family"))
        let request = try XCTUnwrap(provider.requests.first)
        XCTAssertTrue(request.system.text.contains("no preferred route count"))
        XCTAssertTrue(request.system.text.contains("classification problem need not have a thesis"))
        XCTAssertTrue(request.system.text.contains("prospective planning gate"))
        XCTAssertTrue(request.system.text.contains("certificate, proof, exact value"))
        XCTAssertTrue(request.messages.first?.plainText.contains("proposed routes, not completed findings") == true)
        XCTAssertTrue(request.messages.first?.plainText.contains("Recognition isolated completeness") == true)
    }

    func testAuditReturnsConcreteGapsInsteadOfManufacturingRoutes() async throws {
        let provider = PortfolioAuditProvider(json: #"""
        {"accepted":false,"falsification_path":"",
         "gaps":["Both activated routes repeat the same construction."],
         "note":"No independent completeness test."}
        """#)
        let audit = try await PortfolioAuditor.audit(
            runner: AgentLoop(provider: provider), goal: "Classify all groups in C.",
            contract: nil, proposal: proposal(activateSecond: true))
        XCTAssertFalse(audit.accepted)
        XCTAssertEqual(audit.gaps, ["Both activated routes repeat the same construction."])
    }

    func testProposalSectionExcludesRoutesThePlannerDidNotActivate() {
        let section = PortfolioAuditor.proposalSection(proposal())
        XCTAssertTrue(section.contains("Boundary construction"))
        XCTAssertFalse(section.contains("Duplicate route"))
        XCTAssertTrue(section.contains("1 route(s)"))
    }
}

private final class PortfolioAuditProvider: LLMProvider, @unchecked Sendable {
    let description = "portfolio-audit-test"
    private let lock = NSLock()
    private var json: String?
    private var storedRequests: [LLMRequest] = []
    var requests: [LLMRequest] { lock.lock(); defer { lock.unlock() }; return storedRequests }

    init(json: String) { self.json = json }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        lock.lock()
        storedRequests.append(request)
        let next = json
        json = nil
        lock.unlock()
        return AsyncThrowingStream { continuation in
            if let next {
                continuation.yield(.toolUseFinished(
                    id: "audit", name: "report_portfolio_audit", inputJSON: next))
                continuation.yield(.finished(.toolUse))
            } else {
                continuation.yield(.finished(.endTurn))
            }
            continuation.finish()
        }
    }
}

final class BranchDeclineTests: XCTestCase {
    func testOneDecisiveTaskIsACompleteBranchPlan() async throws {
        let capture = BranchOptionBox()
        _ = try await ProgramPlanner.proposeBranchPlanTool { capture.set($0) }
            .execute(inputJSON: #"{"summary":"Run the decisive test.","tasks":[{"title":"Boundary scan","kind":"research"}]}"#)
        XCTAssertEqual(capture.value?.tasks.count, 1)
    }

    func testBranchCanDeclineWithConcreteEvidence() async throws {
        let reason = BranchReasonBox()
        let reply = try await ProgramPlanner.declineBranchTool { reason.set($0) }
            .execute(inputJSON: #"{"reason":"Item thm-7 already proves this route's payoff under the pinned target."}"#)
        XCTAssertTrue(reply.contains("STOP"))
        XCTAssertTrue(reason.value?.contains("thm-7") == true)
    }

    func testBranchCannotDeclineWithoutAReason() async {
        do {
            _ = try await ProgramPlanner.declineBranchTool { _ in }
                .execute(inputJSON: #"{"reason":"   "}"#)
            XCTFail("expected refusal")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("concrete reason"))
        }
    }
}

private final class BranchOptionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var option: PlanProposal.Option?
    func set(_ value: PlanProposal.Option) { lock.lock(); option = value; lock.unlock() }
    var value: PlanProposal.Option? { lock.lock(); defer { lock.unlock() }; return option }
}

private final class BranchReasonBox: @unchecked Sendable {
    private let lock = NSLock()
    private var reason: String?
    func set(_ value: String) { lock.lock(); reason = value; lock.unlock() }
    var value: String? { lock.lock(); defer { lock.unlock() }; return reason }
}
