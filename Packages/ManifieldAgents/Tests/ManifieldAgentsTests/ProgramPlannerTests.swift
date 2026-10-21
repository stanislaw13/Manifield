import XCTest
import ManifieldCore
import ManifieldSandbox
@testable import ManifieldAgents

private final class ApproachCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var proposal: ApproachProposal?
    func set(_ p: ApproachProposal) { lock.lock(); proposal = p; lock.unlock() }
    var value: ApproachProposal? { lock.lock(); defer { lock.unlock() }; return proposal }
}

private final class OptionCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var option: PlanProposal.Option?
    func set(_ o: PlanProposal.Option) { lock.lock(); option = o; lock.unlock() }
    var value: PlanProposal.Option? { lock.lock(); defer { lock.unlock() }; return option }
}

final class ProposeApproachesToolTests: XCTestCase {

    private let validInput = """
    {"goal": "Settle conj-gamma2-doubling", "title": "T",
     "approaches": [
       {"title": "Hunt counterexamples", "mechanism": "Small dense graphs break it.",
        "prior": "Assume the conjecture is FALSE and the obstruction is local.",
        "challenges_leading_answer": true, "expected_payoff": "p", "ontology_cells": ["computational search", "Refuter"],
        "kill_criterion": "No counterexample below 12 vertices after an exhaustive scan",
        "cost_class": "cheap"},
       {"title": "Discharging", "mechanism": "Assign charges by degree and move them.",
        "prior": "Assume the conjecture is TRUE and the proof is a local charge argument.",
        "challenges_leading_answer": false, "expected_payoff": "p", "ontology_cells": ["extremal", "Constructor"],
        "kill_criterion": "Charge conservation fails on the δ=2 family",
        "cost_class": "expensive"},
       {"title": "Reframe the invariant", "mechanism": "The stated bound is the wrong object.",
        "prior": "Assume the definitions are the bug; look for the nearby true statement.",
        "challenges_leading_answer": false, "expected_payoff": "p", "ontology_cells": ["Skeptic-of-Framing"],
        "kill_criterion": "Every nearby reformulation is equivalent to the original",
        "cost_class": "standard"}
     ],
     "skipped_cells": [
       {"cell": "probabilistic", "why": "The graphs are too sparse for concentration."}
     ]}
    """

    func testValidProposalIsCapturedAndStops() async throws {
        let capture = ApproachCapture()
        let reply = try await ProgramPlanner.proposeApproachesTool { capture.set($0) }
            .execute(inputJSON: validInput)

        XCTAssertTrue(reply.contains("STOP"))
        let proposal = try XCTUnwrap(capture.value)
        XCTAssertEqual(proposal.goal, "Settle conj-gamma2-doubling")
        XCTAssertEqual(proposal.title, "T")
        XCTAssertEqual(proposal.approaches.count, 3)
        XCTAssertEqual(proposal.approaches[0].challengesLeadingAnswer, true)
        XCTAssertEqual(proposal.approaches[0].costClass, .cheap)
        XCTAssertEqual(proposal.approaches[1].challengesLeadingAnswer, false)
        XCTAssertEqual(proposal.approaches[2].ontologyCells, ["Skeptic-of-Framing"])
        XCTAssertTrue(proposal.approaches[0].prior.contains("FALSE"))
        XCTAssertEqual(proposal.skippedCells.count, 1)
        XCTAssertEqual(proposal.skippedCells[0].cell, "probabilistic")
    }

    /// Approaches default to activated, so a portfolio proposed by an older planner (or by
    /// a model that ignores the field) still runs exactly as it used to.
    func testActivationDefaultsToOn() async throws {
        let capture = ApproachCapture()
        _ = try await ProgramPlanner.proposeApproachesTool { capture.set($0) }
            .execute(inputJSON: validInput)
        let proposal = try XCTUnwrap(capture.value)
        XCTAssertTrue(proposal.approaches.allSatisfy(\.activate))
        XCTAssertNil(proposal.approaches[0].modelTier)
    }

    func testActivationAndModelTierAreCarried() async throws {
        let input = """
        {"goal": "g", "title": "T", "skipped_cells": [], "approaches": [
          {"title": "A", "mechanism": "t", "prior": "b", "challenges_leading_answer": true, "expected_payoff": "p",
           "ontology_cells": ["x"], "kill_criterion": "k", "cost_class": "cheap",
           "activate": true, "model_tier": "strong"},
          {"title": "B", "mechanism": "t", "prior": "b", "challenges_leading_answer": false, "expected_payoff": "p",
           "ontology_cells": ["y"], "kill_criterion": "k", "cost_class": "cheap",
           "activate": false, "model_tier": "default"},
          {"title": "C", "mechanism": "t", "prior": "b", "challenges_leading_answer": false, "expected_payoff": "p",
           "ontology_cells": ["z"], "kill_criterion": "k", "cost_class": "cheap",
           "activate": true}
        ]}
        """
        let capture = ApproachCapture()
        _ = try await ProgramPlanner.proposeApproachesTool { capture.set($0) }
            .execute(inputJSON: input)
        let proposal = try XCTUnwrap(capture.value)
        XCTAssertEqual(proposal.approaches.map(\.activate), [true, false, true])
        XCTAssertEqual(proposal.approaches[0].modelTier, "strong")
        XCTAssertNil(proposal.approaches[1].modelTier, "'default' is stored as no override")
    }

    /// The proposal tool records metadata; independent coverage review, not this schema,
    /// judges whether the actual mechanisms contain a falsification path.
    func testDoesNotUseTheChallengeLabelAsACoverageGate() async throws {
        let input = """
        {"goal": "g", "title": "T", "skipped_cells": [], "approaches": [
          {"title": "A", "mechanism": "t", "prior": "b", "challenges_leading_answer": true, "expected_payoff": "p",
           "ontology_cells": ["x"], "kill_criterion": "k", "cost_class": "cheap",
           "activate": false},
          {"title": "B", "mechanism": "t", "prior": "b", "challenges_leading_answer": false, "expected_payoff": "p",
           "ontology_cells": ["y"], "kill_criterion": "k", "cost_class": "cheap",
           "activate": true},
          {"title": "C", "mechanism": "t", "prior": "b", "challenges_leading_answer": false, "expected_payoff": "p",
           "ontology_cells": ["z"], "kill_criterion": "k", "cost_class": "cheap",
           "activate": true}
        ]}
        """
        let capture = ApproachCapture()
        _ = try await ProgramPlanner.proposeApproachesTool { capture.set($0) }
            .execute(inputJSON: input)
        XCTAssertNotNil(capture.value)
    }

    func testAWellJustifiedSingleRouteIsAllowed() async throws {
        let input = """
        {"goal": "g", "title": "T", "skipped_cells": [], "approaches": [
          {"title": "A", "mechanism": "t", "prior": "b", "challenges_leading_answer": true, "expected_payoff": "p",
           "ontology_cells": ["x"], "kill_criterion": "k", "cost_class": "cheap"}
        ]}
        """
        let capture = ApproachCapture()
        _ = try await ProgramPlanner.proposeApproachesTool { capture.set($0) }
            .execute(inputJSON: input)
        XCTAssertEqual(capture.value?.approaches.count, 1)
    }

    /// The whole point of the mechanism: a portfolio that only tries to confirm is the
    /// failure mode it exists to prevent.
    func testPortfolioWithoutAChallengeLabelReachesTheAuditor() async throws {
        let input = """
        {"goal": "g", "title": "T", "skipped_cells": [], "approaches": [
          {"title": "A", "mechanism": "t", "prior": "b", "challenges_leading_answer": false, "expected_payoff": "p",
           "ontology_cells": ["x"], "kill_criterion": "k", "cost_class": "cheap"},
          {"title": "B", "mechanism": "t", "prior": "b", "challenges_leading_answer": false, "expected_payoff": "p",
           "ontology_cells": ["y"], "kill_criterion": "k", "cost_class": "cheap"},
          {"title": "C", "mechanism": "t", "prior": "b", "challenges_leading_answer": false, "expected_payoff": "p",
           "ontology_cells": ["z"], "kill_criterion": "k", "cost_class": "cheap"}
        ]}
        """
        let capture = ApproachCapture()
        _ = try await ProgramPlanner.proposeApproachesTool { capture.set($0) }
            .execute(inputJSON: input)
        XCTAssertEqual(capture.value?.approaches.map(\.challengesLeadingAnswer),
                       [false, false, false])
    }

    func testRejectsMissingBiasNamingTheApproach() async {
        let input = """
        {"goal": "g", "title": "T", "skipped_cells": [], "approaches": [
          {"title": "A", "mechanism": "t", "prior": "b", "challenges_leading_answer": true, "expected_payoff": "p",
           "ontology_cells": ["x"], "kill_criterion": "k", "cost_class": "cheap"},
          {"title": "NoBias", "mechanism": "t", "challenges_leading_answer": false, "expected_payoff": "p",
           "ontology_cells": ["y"], "kill_criterion": "k", "cost_class": "cheap"},
          {"title": "C", "mechanism": "t", "prior": "b", "challenges_leading_answer": false, "expected_payoff": "p",
           "ontology_cells": ["z"], "kill_criterion": "k", "cost_class": "cheap"}
        ]}
        """
        await assertRejects(input, containing: "NoBias")
    }

    func testRejectsMissingKillCriterion() async {
        let input = """
        {"goal": "g", "title": "T", "skipped_cells": [], "approaches": [
          {"title": "A", "mechanism": "t", "prior": "b", "challenges_leading_answer": true, "expected_payoff": "p",
           "ontology_cells": ["x"], "kill_criterion": "k", "cost_class": "cheap"},
          {"title": "B", "mechanism": "t", "prior": "b", "challenges_leading_answer": false, "expected_payoff": "p",
           "ontology_cells": ["y"], "cost_class": "cheap"},
          {"title": "C", "mechanism": "t", "prior": "b", "challenges_leading_answer": false, "expected_payoff": "p",
           "ontology_cells": ["z"], "kill_criterion": "k", "cost_class": "cheap"}
        ]}
        """
        await assertRejects(input, containing: "kill_criterion")
    }

    func testRejectsMissingSkippedCells() async {
        let input = """
        {"goal": "g", "title": "T", "approaches": [
          {"title": "A", "mechanism": "t", "prior": "b", "challenges_leading_answer": true, "expected_payoff": "p",
           "ontology_cells": ["x"], "kill_criterion": "k", "cost_class": "cheap"},
          {"title": "B", "mechanism": "t", "prior": "b", "challenges_leading_answer": false, "expected_payoff": "p",
           "ontology_cells": ["y"], "kill_criterion": "k", "cost_class": "cheap"},
          {"title": "C", "mechanism": "t", "prior": "b", "challenges_leading_answer": false, "expected_payoff": "p",
           "ontology_cells": ["z"], "kill_criterion": "k", "cost_class": "cheap"}
        ]}
        """
        await assertRejects(input, containing: "skipped_cells")
    }


    func testRejectsUnknownCostClass() async {
        await assertRejects("""
        {"goal": "g", "title": "T", "skipped_cells": [], "approaches": [
          {"title": "A", "mechanism": "t", "prior": "b", "challenges_leading_answer": true, "expected_payoff": "p",
           "ontology_cells": ["x"], "kill_criterion": "k", "cost_class": "cheap"},
          {"title": "B", "mechanism": "t", "prior": "b", "challenges_leading_answer": false, "expected_payoff": "p",
           "ontology_cells": ["y"], "kill_criterion": "k", "cost_class": "free"},
          {"title": "C", "mechanism": "t", "prior": "b", "challenges_leading_answer": false, "expected_payoff": "p",
           "ontology_cells": ["z"], "kill_criterion": "k", "cost_class": "cheap"}
        ]}
        """, containing: "cost_class")
    }

    func testRejectsEmptyOntologyCells() async {
        let input = """
        {"goal": "g", "title": "T", "skipped_cells": [], "approaches": [
          {"title": "A", "mechanism": "t", "prior": "b", "challenges_leading_answer": true, "expected_payoff": "p",
           "ontology_cells": [], "kill_criterion": "k", "cost_class": "cheap"},
          {"title": "B", "mechanism": "t", "prior": "b", "challenges_leading_answer": false, "expected_payoff": "p",
           "ontology_cells": ["y"], "kill_criterion": "k", "cost_class": "cheap"},
          {"title": "C", "mechanism": "t", "prior": "b", "challenges_leading_answer": false, "expected_payoff": "p",
           "ontology_cells": ["z"], "kill_criterion": "k", "cost_class": "cheap"}
        ]}
        """
        await assertRejects(input, containing: "ontology_cells")
    }

    // MARK: - Goal kinds



    func testValidDetermineProposalIsAccepted() async throws {
        let capture = ApproachCapture()
        _ = try await ProgramPlanner.proposeApproachesTool { capture.set($0) }
            .execute(inputJSON: """
            {"goal": "Determine c + 1985/2", "title": "T", "skipped_cells": [], "approaches": [
              {"title": "Variational", "mechanism": "The constraints force a two-valued step function.",
               "prior": "Assume the extremum is attained by a step function.",
               "challenges_leading_answer": false, "expected_payoff": "p", "ontology_cells": ["direct / inductive"],
               "kill_criterion": "No step function meets all three constraints", "cost_class": "standard"},
              {"title": "Finite reduction", "mechanism": "Reduce to optimizing over the distribution of f.",
               "prior": "Assume only the distribution of f matters.",
               "challenges_leading_answer": false, "expected_payoff": "p", "ontology_cells": ["reduction / transfer"],
               "kill_criterion": "The local-variance constraint is not distribution-determined",
               "cost_class": "standard"},
              {"title": "Numerical adversary", "mechanism": "Discretize and try to beat any claimed value.",
               "prior": "Assume the leading candidate is not optimal; hunt a feasible f that beats it.",
               "challenges_leading_answer": true, "expected_payoff": "p", "ontology_cells": ["computational search"],
               "kill_criterion": "The search cannot exceed the candidate beyond discretization error",
               "cost_class": "cheap"}
            ]}
            """)

        let proposal = try XCTUnwrap(capture.value)
        XCTAssertEqual(proposal.approaches.map(\.challengesLeadingAnswer),
                       [false, false, true],
                       "a question asking for a value still needs something attacking the answer")
    }


    /// The program label names the problem; without it the list shows the planner's
    /// directive sentence, which reads like one branch's task.
    func testMissingTitleIsRejectedWithGuidance() async {
        let input = """
        {"goal": "g", "skipped_cells": [], "approaches": [
          {"title": "A", "mechanism": "t", "prior": "b", "challenges_leading_answer": true, "expected_payoff": "p",
           "ontology_cells": ["x"], "kill_criterion": "k", "cost_class": "cheap"},
          {"title": "B", "mechanism": "t", "prior": "b", "challenges_leading_answer": false, "expected_payoff": "p",
           "ontology_cells": ["y"], "kill_criterion": "k", "cost_class": "cheap"},
          {"title": "C", "mechanism": "t", "prior": "b", "challenges_leading_answer": false, "expected_payoff": "p",
           "ontology_cells": ["z"], "kill_criterion": "k", "cost_class": "cheap"}
        ]}
        """
        await assertRejects(input, containing: "title")
    }


    private func assertRejects(_ input: String, containing needle: String,
                               file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await ProgramPlanner.proposeApproachesTool { _ in }.execute(inputJSON: input)
            XCTFail("expected rejection", file: file, line: line)
        } catch {
            XCTAssertTrue(error.localizedDescription.contains(needle),
                          "error should mention '\(needle)': \(error.localizedDescription)",
                          file: file, line: line)
        }
    }
}

final class ProposeBranchPlanToolTests: XCTestCase {

    func testValidBranchPlanIsCaptured() async throws {
        let capture = OptionCapture()
        let reply = try await ProgramPlanner.proposeBranchPlanTool { capture.set($0) }
            .execute(inputJSON: """
            {"summary": "Scan first, then generalize.",
             "tasks": [
               {"title": "Exhaustive scan to n=12", "kind": "research"},
               {"title": "Prove the bound", "kind": "prove: lem-key", "depends_on": [1], "review": true}
             ]}
            """)

        XCTAssertTrue(reply.contains("STOP"))
        let option = try XCTUnwrap(capture.value)
        XCTAssertEqual(option.tasks.count, 2)
        XCTAssertEqual(option.tasks[1].kind, .prove(targetID: "lem-key"))
        XCTAssertEqual(option.tasks[1].dependsOn, [1])
        XCTAssertTrue(option.tasks[1].reviewGate)
    }

    /// Both plan tools share PlannerValidation, so the task rules cannot drift apart.
    func testSharesTaskValidationWithThePlanTool() async {
        await assertRejects("""
        {"summary": "s", "tasks": [
          {"title": "A", "kind": "research", "depends_on": [2]},
          {"title": "B", "kind": "research"}
        ]}
        """, containing: "EARLIER task")

        await assertRejects("""
        {"summary": "s", "tasks": [
          {"title": "A", "kind": "fly-to-moon"},
          {"title": "B", "kind": "research"}
        ]}
        """, containing: "prove: <item-id>")

    }

    private func assertRejects(_ input: String, containing needle: String,
                               file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await ProgramPlanner.proposeBranchPlanTool { _ in }.execute(inputJSON: input)
            XCTFail("expected rejection", file: file, line: line)
        } catch {
            XCTAssertTrue(error.localizedDescription.contains(needle),
                          "error should mention '\(needle)': \(error.localizedDescription)",
                          file: file, line: line)
        }
    }
}

final class ProgramPlannerPromptTests: XCTestCase {

    private let memory = """
    ## Goal
    Settle conj-gamma2-doubling.

    ## Key Insights
    BELIEF-SENTINEL: the conjecture looks true for δ ≥ 3.

    ## Eliminated Strategies
    ELIMINATED-SENTINEL: naive induction on n — the invariant is uncontrolled.
    """

    private let approach = ApproachProposal.Approach(
        title: "Hunt counterexamples",
        mechanism: "Small dense graphs break it.",
        prior: "LENS-SENTINEL: assume the conjecture is false.",
        expectedPayoff: "PAYOFF-SENTINEL: a counterexample, or a bound on where one cannot be.",
        challengesLeadingAnswer: true,
        ontologyCells: ["computational search"],
        killCriterion: "KILL-SENTINEL: nothing below 12 vertices",
        costClass: .cheap)

    /// Pass 1 is the one place beliefs help: you cannot design an approach that
    /// contradicts the consensus without seeing it.
    func testPass1SeesFullMemoryAndTheOntology() {
        let prompt = ProgramPlanner.pass1SystemPrompt(
            notation: "", items: [], userProfile: "", memory: memory)
        XCTAssertTrue(prompt.contains("BELIEF-SENTINEL"))
        XCTAssertTrue(prompt.contains("ELIMINATED-SENTINEL"))
        XCTAssertTrue(prompt.contains("Refuter"), "the lens archetypes must be in context")
        XCTAssertTrue(prompt.contains("Skeptic-of-Framing"))
    }

    func testPass1IncludesProjectOntologyWhenPresent() {
        let prompt = ProgramPlanner.pass1SystemPrompt(
            notation: "", items: [], userProfile: "", memory: memory,
            projectOntology: "PROJECT-ONTOLOGY-SENTINEL: our own lens.")
        XCTAssertTrue(prompt.contains("PROJECT-ONTOLOGY-SENTINEL"))
    }

    /// Pass 2 already sits inside a branch: facts and its own lens, never the project's
    /// beliefs — the same isolation the branch's tasks run under.
    func testPass2IsFactsOnlyPlusItsLens() {
        let prompt = ProgramPlanner.pass2SystemPrompt(
            approach: approach, goal: "Settle conj-gamma2-doubling",
            notation: "", items: [], userProfile: "", projectMemory: memory)

        XCTAssertTrue(prompt.contains("LENS-SENTINEL"))
        XCTAssertTrue(prompt.contains("KILL-SENTINEL"))
        XCTAssertTrue(prompt.contains("ELIMINATED-SENTINEL"), "eliminated strategies are facts")
        XCTAssertFalse(prompt.contains("BELIEF-SENTINEL"),
                       "project beliefs must not reach a branch's planning")
    }

    /// Pass 2 must see what would actually answer the question. A task list planned blind to
    /// the contract is how a branch ends up proving something true and unsurprising.
    func testPass2CarriesTheContract() {
        let contract = SuccessContract(
            statement: "FORMAL-TARGET-SENTINEL")
        let prompt = ProgramPlanner.pass2SystemPrompt(
            approach: approach, goal: "RAW-REQUEST-SENTINEL", notation: "", items: [],
            userProfile: "", projectMemory: memory, contract: contract)
        XCTAssertTrue(prompt.contains("RAW-REQUEST-SENTINEL"))
        XCTAssertTrue(prompt.contains("FORMAL-TARGET-SENTINEL"))
    }

    /// The route's payoff has to survive into the branch plan, or pass 2 quietly plans a
    /// different branch than the one the portfolio chose.
    func testPass2CarriesTheRoutesExpectedPayoff() {
        let prompt = ProgramPlanner.pass2SystemPrompt(
            approach: approach, goal: "g", notation: "", items: [],
            userProfile: "", projectMemory: memory)
        XCTAssertTrue(prompt.contains("PAYOFF-SENTINEL"))
    }

    /// A branch has to be told what it is *for*. Given only a prior, a branch meant to attack
    /// the leading answer drifts into extending it.
    func testLensSectionRendersTheRoleAndToleratesAMissingKill() {
        let building = ProgramPlanner.lensSection(
            prior: "B", challengesLeadingAnswer: false, kill: "")
        XCTAssertTrue(building.contains("builds toward an answer"))
        XCTAssertTrue(building.contains("none set"))
        XCTAssertFalse(building.contains("{{"), "no placeholder may survive rendering")

        let challenging = ProgramPlanner.lensSection(
            prior: "B", challengesLeadingAnswer: true, kill: "K")
        XCTAssertTrue(challenging.contains("attacks the leading answer"))
        XCTAssertTrue(challenging.contains("K"))
        XCTAssertFalse(challenging.contains("{{"))
    }

    // MARK: - Both passes are told what the sandbox can run

    /// The first automode run planned a "signed-relation SAT search" and an integer-programming
    /// certificate. Neither is installable — the sandbox is offline — so the branch was
    /// unrunnable as planned, which in an unattended run is budget spent before anyone notices.
    func testBothPlannerPassesCarryTheSandboxPackageList() {
        let pass1 = ProgramPlanner.pass1SystemPrompt(
            notation: "", items: [], userProfile: "", memory: "")
        let pass2 = ProgramPlanner.pass2SystemPrompt(
            approach: ApproachProposal.Approach(
                title: "T", mechanism: "t", prior: "b",
                ontologyCells: ["c"], killCriterion: "k"),
            goal: "g", notation: "", items: [],
            userProfile: "", projectMemory: "")

        for (name, prompt) in [("pass 1", pass1), ("pass 2", pass2)] {
            for package in PythonRuntime.packages {
                XCTAssertTrue(prompt.contains(package),
                              "\(name) must name the installed package '\(package)'")
            }
            XCTAssertTrue(prompt.contains("no network access"), "\(name)")
            XCTAssertTrue(prompt.contains("no SAT solver"), "\(name)")
        }
    }

    /// The list is read from the runtime, not restated in prose, so the two cannot drift apart.
    func testThePackageListComesFromTheRuntime() {
        XCTAssertTrue(ContextAssembly.computeEnvironment
            .contains(PythonRuntime.packages.joined(separator: ", ")))
    }
}
