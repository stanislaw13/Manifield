import XCTest
import ManifieldCore
@testable import ManifieldAgents

final class PromptLibraryTests: XCTestCase {

    func testValidateAllFindsNoProblems() {
        XCTAssertEqual(PromptLibrary.validateAll(), [])
    }

    func testRenderSubstitutesPlaceholders() throws {
        let template = PromptTemplate(name: "t", raw: "Project {{NAME}} has {{COUNT}} items.")
        let rendered = try template.render(["NAME": "X", "COUNT": "3"])
        XCTAssertEqual(rendered, "Project X has 3 items.")
    }

    func testRenderThrowsOnUnresolvedPlaceholder() {
        let template = PromptTemplate(name: "t", raw: "Hello {{WHO}}")
        XCTAssertThrowsError(try template.render()) { error in
            XCTAssertEqual(error as? PromptError,
                           .unresolvedPlaceholder(template: "t", key: "WHO"))
        }
    }

    func testPlaceholderScanIgnoresLaTeXBraces() {
        // Double braces occur in LaTeX; only {{UPPER_SNAKE}} counts as a placeholder.
        let raw = "The bound $x^{{n+1}}$ and \\frac{{a}}{b} are fine; {{REAL_KEY}} is not."
        XCTAssertEqual(PromptTemplate.placeholders(in: raw), ["REAL_KEY"])
    }

    func testMissingTemplateThrows() {
        XCTAssertThrowsError(try PromptLibrary.template("no-such-template"))
    }

    func testTemplateStripsTrailingNewline() throws {
        let template = try PromptLibrary.template("latex_rules")
        XCTAssertFalse(template.raw.hasSuffix("\n"))
        XCTAssertTrue(template.raw.hasPrefix("Formatting:"))
        XCTAssertTrue(template.raw.contains("every LaTeX backslash"))
        XCTAssertTrue(template.raw.contains(#"\\to"#))
        XCTAssertTrue(template.raw.contains("rejected"))
    }
}

/// Characterization tests: the migrated prompts must still contain the key wording the
/// agents were tuned on. Sentence-level anchors per template catch text corruption
/// without freezing every character.
final class PromptCharacterizationTests: XCTestCase {

    func testChatSystemPrompt() {
        let prompt = ContextAssembly.chatSystemPrompt(
            projectName: "k-Domination", notation: "", items: [], userProfile: "",
            checkerAvailable: true
        ).text
        XCTAssertTrue(prompt.contains(#"working on the project "k-Domination""#))
        XCTAssertTrue(prompt.contains("use propose_theory_edit — the user confirms every write"))
        XCTAssertTrue(prompt.contains("Epistemic contract (non-negotiable):"))
        XCTAssertTrue(prompt.contains("never inflate it"))           // checker rules present
        XCTAssertTrue(prompt.contains("$$...$$ for display math"))   // latex rules present
        XCTAssertTrue(prompt.contains("start_research"))             // persistent-research escalation
        XCTAssertTrue(prompt.contains("Lead with the outcome."))
        XCTAssertTrue(prompt.contains("Communicating with the user:"))
        // Capability discoverability: a found fix must be offered, named concretely.
        XCTAssertTrue(prompt.contains("Name what you are offering"))
        XCTAssertTrue(prompt.contains("Do not re-offer something they passed over."))
        XCTAssertTrue(prompt.contains("Lead with the idea."))        // explaining mathematics
        XCTAssertTrue(prompt.contains("Write prose."))               // formatting rules
    }

    /// The user's name reaches chat and nothing else, is hedged where it lands (told only a
    /// name, models open every reply with it), and shares one "About the user" block with
    /// the profile rather than splitting it in two.
    func testChatPromptCarriesUserNameOnlyWhenSet() {
        let anonymous = ContextAssembly.chatSystemPrompt(
            projectName: "P", notation: "", items: [], userProfile: "").text
        XCTAssertFalse(anonymous.contains("About the user:"))

        let named = ContextAssembly.chatSystemPrompt(
            projectName: "P", notation: "", items: [],
            userName: "  Staszek  ", userProfile: "extremal graph theory").text
        XCTAssertTrue(named.contains("Their name is Staszek."))
        XCTAssertTrue(named.contains("not in every message"))
        XCTAssertTrue(named.contains("extremal graph theory"))

        // A profile with no name behaves exactly as it did before the name existed.
        let profileOnly = ContextAssembly.chatSystemPrompt(
            projectName: "P", notation: "", items: [],
            userProfile: "extremal graph theory").text
        XCTAssertFalse(profileOnly.contains("Their name is"))
        XCTAssertTrue(profileOnly.contains("Adapt your explanations"))
    }

    /// The referee stance, the taste criteria and the citation guard are the three
    /// additions that make chat a research assistant rather than an agreeable one.
    func testChatPromptCarriesResearchAssistantStance() {
        let prompt = ContextAssembly.chatSystemPrompt(
            projectName: "P", notation: "", items: [], userProfile: ""
        ).text
        // critical_reading
        XCTAssertTrue(prompt.contains("try to break it before you endorse it"))
        XCTAssertTrue(prompt.contains("Cheap refutation before expensive proof."))
        XCTAssertTrue(prompt.contains("When the question is built on a confusion"))
        XCTAssertTrue(prompt.contains("Inconsistencies worth interrupting for"))
        // Grounding fidelity: a restatement must not quietly rewrite the item's notation,
        // and a symbol collision counts even when context makes it unambiguous.
        XCTAssertTrue(prompt.contains("keep the notation the item uses"))
        XCTAssertTrue(prompt.contains("even where context disambiguates"))
        // provenance_rules
        XCTAssertTrue(prompt.contains("Never invent bibliographic detail."))
        // mathematical_taste, and the clause that keeps it subordinate to correctness
        XCTAssertTrue(prompt.contains("shows *why* a statement is true"))
        XCTAssertTrue(prompt.contains("None of this outranks correctness."))
        // Never rank what you have not read — the grounding guarantee the app exists for.
        XCTAssertTrue(prompt.contains("Taste applies to mathematics you have actually read."))
        XCTAssertTrue(prompt.contains("judge, rank, endorse or reject an argument you have not actually read"))
        // taste must follow the epistemic contract, never precede it
        guard let contract = prompt.range(of: "Epistemic contract"),
              let taste = prompt.range(of: "Mathematical taste:") else {
            return XCTFail("expected both sections in the chat prompt")
        }
        XCTAssertLessThan(contract.lowerBound, taste.lowerBound)
    }

    /// Auto mode removes the human confirmation gate, so the directive must carry what
    /// that gate was doing: honest statuses, and the cases that still stop and ask.
    func testAutoModeDirective() {
        let prompt = ContextAssembly.chatSystemPrompt(
            projectName: "P", notation: "", items: [], userProfile: "",
            modeDirective: ContextAssembly.autoModeDirective
        ).text
        XCTAssertTrue(prompt.contains("Auto mode is active"))
        XCTAssertTrue(prompt.contains("write_theory_item"))
        XCTAssertTrue(prompt.contains("Never inflate a status"))
        XCTAssertTrue(prompt.contains("Writing directly does not mean acting unilaterally."))
        XCTAssertTrue(prompt.contains("Close your reply with what you changed"))
        // The epistemic contract still governs — Auto relaxes permission, never honesty.
        XCTAssertTrue(prompt.contains("Epistemic contract (non-negotiable):"))
        XCTAssertTrue(prompt.contains("try to break it before you endorse it"))
    }

    func testPlanModeTargetsPersistentResearchAndRequiresConfirmation() {
        let prompt = ContextAssembly.chatSystemPrompt(
            projectName: "P", notation: "", items: [], userProfile: "",
            modeDirective: ContextAssembly.planModeDirective
        ).text
        XCTAssertTrue(prompt.contains("Your only planning output is a proposed target prompt"))
        XCTAssertTrue(prompt.contains("continuing director conversation"))
        XCTAssertTrue(prompt.contains("focused direct workers or planned assignments"))
        XCTAssertTrue(prompt.contains("always a two-turn hand-off"))
        XCTAssertTrue(prompt.contains("passing it unchanged"))
        XCTAssertTrue(prompt.contains("start_research"))
        XCTAssertFalse(prompt.contains("call propose_approaches"))
    }

    /// Ask mode disables the write tools but must keep the reading discipline — it is
    /// exactly where a proof gets pasted for discussion.
    func testAskModeKeepsCriticalReading() {
        let prompt = ContextAssembly.chatSystemPrompt(
            projectName: "P", notation: "", items: [], userProfile: "",
            modeDirective: ContextAssembly.askModeDirective
        ).text
        XCTAssertTrue(prompt.contains("Ask mode is active"))
        XCTAssertTrue(prompt.contains("try to break it before you endorse it"))
        XCTAssertTrue(prompt.contains("Never invent bibliographic detail."))
        // Ask must route a wanted edit to the gated mode, never to direct-write Auto.
        XCTAssertTrue(prompt.contains("switching the composer to Propose"))
        XCTAssertFalse(prompt.contains("switching the composer to Auto"))
    }

    func testFocusedItemSection() {
        let item = TheoryItem(
            id: "thm-a", type: .theorem, name: "A", status: .proofDrafted,
            dependsOn: ["lem-b"], body: "## Statement\n$x$"
        )
        let section = ContextAssembly.focusedItemSection(item)
        XCTAssertTrue(section.contains("The user has loaded a specific item"))
        XCTAssertTrue(section.contains("thm-a [theorem, status: proof-drafted] — A"))
        XCTAssertTrue(section.contains("depends on: lem-b"))
        XCTAssertTrue(section.hasSuffix("## Statement\n$x$"))
    }

    func testProverSystemBothPolicies() {
        let restricted = ProverPrompts.proverSystem(
            policy: .restricted, notation: "", outline: "(empty)", userProfile: "")
        XCTAssertTrue(restricted.contains("You are the Prover agent in Manifield"))
        XCTAssertTrue(restricted.contains("Knowledge policy — RESTRICTED"))
        XCTAssertTrue(restricted.contains("The use_external_result tool will refuse in this mode."))
        XCTAssertTrue(restricted.contains("ONLY the proof body in markdown+LaTeX"))

        let auto = ProverPrompts.proverSystem(
            policy: .autoExternal, notation: "", outline: "(empty)", userProfile: "")
        XCTAssertTrue(auto.contains("Knowledge policy — AUTO"))
        XCTAssertTrue(auto.contains("you MUST declare it with the use_external_result tool"))
        XCTAssertFalse(auto.contains("RESTRICTED"))

        // The Prover shares chat's taste criteria — with the correctness guard, since
        // "prefer fewer cases" is otherwise an invitation to drop one. It does NOT carry
        // honesty_rules, so the don't-rank-what-you-haven't-read clause has to reach it
        // through the taste fragment.
        XCTAssertTrue(restricted.contains("Mathematical taste:"))
        XCTAssertTrue(restricted.contains("None of this outranks correctness."))
        XCTAssertTrue(restricted.contains("Taste applies to mathematics you have actually read."))
        XCTAssertFalse(restricted.contains("Epistemic contract (non-negotiable):"))
        XCTAssertTrue(restricted.contains("Say where each hypothesis of the target is used."))
    }

    func testReviewerSystem() {
        let prompt = ProverPrompts.reviewerSystem(notation: "", outline: "(empty)")
        XCTAssertTrue(prompt.contains("Your ONLY job is to find flaws in a proof."))
        XCTAssertTrue(prompt.contains(#"{"verdict": "no-errors-found"}"#))
        XCTAssertTrue(prompt.contains("never approve out of agreeableness"))
        XCTAssertTrue(prompt.contains("name the weakest repair you can see"))
        // The reviewer stays adversarial: taste is the Prover's brief, not the gate's.
        XCTAssertFalse(prompt.contains("Mathematical taste:"))
    }

    func testOrganizerSystemPrompt() {
        let items = [TheoryItem(id: "def-a", type: .definition, name: "A")]
        let prompt = Organizer.systemPrompt(existingItems: items, notation: "")
        XCTAssertTrue(prompt.contains("You are the Organizer agent in Manifield."))
        XCTAssertTrue(prompt.contains("ONLY a JSON array (no prose, no code fence)"))
        XCTAssertTrue(prompt.contains(#"\emph{x}/\textit{x} → *x*"#))
        XCTAssertTrue(prompt.contains("The project already contains these items"))
        XCTAssertTrue(prompt.contains("def-a"))
    }

    func testOrganizerSourceSystemPrompt() {
        let prompt = Organizer.sourceSystemPrompt(
            existingIDs: ["thm-x"], chunkSection: "weierstrass-theory", citation: "Book (1991)")
        XCTAssertTrue(prompt.contains("importing published mathematical literature (Book (1991)) into"))
        XCTAssertTrue(prompt.contains(#"section: "weierstrass-theory" for every item"#))
        XCTAssertTrue(prompt.contains("Already-imported ids (do not reuse):\nthm-x"))

        let uncited = Organizer.sourceSystemPrompt(existingIDs: [], chunkSection: "s", citation: nil)
        XCTAssertTrue(uncited.contains("published mathematical literature into"))
        XCTAssertFalse(uncited.contains("Already-imported"))
        XCTAssertTrue(uncited.contains("never complete or invent the missing part"),
                      "every chunk is cut from a longer work; the standing rule says so")
        XCTAssertFalse(uncited.contains("Chunk boundary warning"),
                       "the explicit warning is only for chunks actually cut mid-item")
    }

    /// Only chunks the splitter had to cut inside an environment carry the warning, and
    /// it must say which end is ragged.
    func testOrganizerChunkBoundaryWarning() {
        let opening = Organizer.sourceSystemPrompt(
            existingIDs: [], chunkSection: "s", citation: nil, startsMidStructure: true)
        XCTAssertTrue(opening.contains("Chunk boundary warning"))
        XCTAssertTrue(opening.contains("BEGINS in the middle"))
        XCTAssertFalse(opening.contains("ENDS in the middle"))
        XCTAssertTrue(opening.contains("skip that fragment entirely"))

        let closing = Organizer.sourceSystemPrompt(
            existingIDs: [], chunkSection: "s", citation: nil, endsMidStructure: true)
        XCTAssertTrue(closing.contains("ENDS in the middle"))
        XCTAssertTrue(closing.contains("*(abridged)*"))
    }

    /// A book-length import accumulates thousands of ids; the whole list would crowd out
    /// the chunk it is supposed to be helping.
    func testTakenIDsAreCappedAndTheOmissionIsDeclared() {
        let ids = (1...900).map { "thm-result-\($0)" }
        let prompt = Organizer.sourceSystemPrompt(
            existingIDs: ids, chunkSection: "s", citation: nil)
        XCTAssertFalse(prompt.contains("thm-result-1,"), "oldest ids are dropped")
        XCTAssertTrue(prompt.contains("thm-result-900"), "newest ids are kept")
        XCTAssertTrue(prompt.contains("\(900 - Organizer.maxTakenIDsInPrompt) earlier ids omitted"))
    }

    func testExplorerSystemPrompt() {
        let prompt = Explorer.systemPrompt(
            notation: "", items: [], userProfile: "", candidateCount: 3)
        XCTAssertTrue(prompt.contains("You are the Explorer agent in Manifield."))
        XCTAssertTrue(prompt.contains("propose exactly 3 candidate(s)"))
        XCTAssertTrue(prompt.contains("Novelty is mandatory"))
        XCTAssertTrue(prompt.contains("Epistemic contract (non-negotiable):"))
        XCTAssertTrue(prompt.contains("Mathematical taste:"))
    }

    /// Taste travels with the epistemic contract to every agent that generates
    /// mathematics — the approach portfolio especially, where "prefer genuinely different
    /// programmes over variations of one idea" is the whole job.
    func testPlannerPromptsCarryTaste() {
        let pass1 = ProgramPlanner.pass1SystemPrompt(
            notation: "", items: [], userProfile: "", memory: "")
        XCTAssertTrue(pass1.contains("Mathematical taste:"))
        XCTAssertTrue(pass1.contains("None of this outranks correctness."))
        // Ordering holds here too: the contract is established before taste qualifies it.
        guard let contract = pass1.range(of: "Epistemic contract"),
              let taste = pass1.range(of: "Mathematical taste:") else {
            return XCTFail("expected both sections in the planner prompt")
        }
        XCTAssertLessThan(contract.lowerBound, taste.lowerBound)
    }
}
