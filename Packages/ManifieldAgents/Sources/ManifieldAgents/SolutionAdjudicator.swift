import Foundation
import ManifieldCore

/// Decides whether a claimed result, **assuming its mathematics is correct**, completely
/// answers the user's question as the frozen contract defines it.
///
/// It is the cheap half of the two-pass completion check, and it runs first on purpose. A
/// branch that has spent its whole run inside one route is the last context that can judge
/// whether that route's result answers the original question — it knows the result too well
/// and the question too long ago. One fresh-context turn against the contract catches the
/// common failure (a real theorem about a neighbouring question) before anyone pays for
/// review or parks a branch.
///
/// It deliberately does no mathematics. Correctness is the review gate's job, and an
/// adjudicator that starts checking proofs stops checking scope.
public enum SolutionAdjudicator {

    public struct Ruling: Equatable, Sendable {
        public var accepted: Bool
        public var note: String
        /// Which complete-answer forms the adjudicator judges are satisfied. Its own finding,
        /// not an echo of the claim: a result can span several forms, and a claimant can name
        /// the wrong one while still being right.
        public var satisfiedCompletionIDs: [String]

        public init(accepted: Bool, note: String, satisfiedCompletionIDs: [String] = []) {
            self.accepted = accepted
            self.note = note
            self.satisfiedCompletionIDs = satisfiedCompletionIDs
        }
    }

    public static func systemPrompt(
        goal: String,
        contract: SuccessContract?,
        targetRevision: ResearchTargetRevision? = nil,
        candidate: SolutionCandidate,
        items: [TheoryItem]
    ) -> String {
        var parts = [PromptLibrary.text("solution_adjudicator")]
        parts.append(ContextAssembly.honestyRules)
        parts.append(ContextAssembly.researchTargetSection(
            originalRequest: goal, contract: contract))
        if let targetRevision {
            parts.append(ContextAssembly.pinnedTargetSection(targetRevision))
        }

        var claim = ["The claim under adjudication:", "Primary result: `\(candidate.primaryItemID)`"]
        if !candidate.supportingItemIDs.isEmpty {
            claim.append("Supporting items: \(candidate.supportingItemIDs.joined(separator: ", "))")
        }
        if let named = candidate.claimedCompletionIDs, !named.isEmpty {
            claim.append("""
            The branch believes this satisfies: \(named.joined(separator: ", ")). \
            That is its guess, not a constraint on you — decide for yourself which forms are \
            satisfied, including none, including several it did not name.
            """)
        }
        claim.append("\nThe branch's argument that this answers the question:\n\(candidate.argument)")
        parts.append(claim.joined(separator: "\n"))

        // The statements themselves, so the adjudicator can read what is actually claimed
        // rather than take the branch's description of it.
        let cited = candidate.citedItemIDs.compactMap { id in items.first { $0.id == id } }
        if !cited.isEmpty {
            parts.append("The cited items, as they currently stand:\n\n" + cited.map { item in
                "### `\(item.id)` [\(item.status.rawValue)] \(item.name)\n\(item.statement)"
            }.joined(separator: "\n\n"))
        }
        return parts.joined(separator: "\n\n")
    }

    /// Runs one adjudication turn. Nil when the turn produced no ruling — the caller treats
    /// that as "not adjudicated" and leaves the candidate for the director and the user,
    /// never as an acceptance.
    public static func adjudicate(
        runner: AgentRunner,
        goal: String,
        contract: SuccessContract?,
        targetRevision: ResearchTargetRevision? = nil,
        candidate: SolutionCandidate,
        items: [TheoryItem],
        tools: [AgentTool] = [],
        thinking: ThinkingLevel = .off,
        programID: String = "",
        record: RecordTurn? = nil,
        onActivity: @escaping @Sendable (AgentActivity) -> Void = { _ in }
    ) async throws -> Ruling? {
        let signals = ContractAdjudicationSignals()
        let config = AgentConfig(
            systemPrompt: SystemPrompt(systemPrompt(
                goal: goal, contract: contract, targetRevision: targetRevision,
                candidate: candidate, items: items)),
            tools: tools + [ReportContractAdjudicationTool(
                signals: signals, contract: contract)],
            maxIterations: 10,
            thinking: thinking)
        _ = try await runRecordedTurn(
            runner: runner, config: config,
            history: [.user("""
            Decide whether this claim, assuming its mathematics is correct, completely answers \
            the user's question. Call report_contract_adjudication once.
            """)],
            programID: programID, role: .contractAdjudication, subjectID: candidate.id,
            title: "Does \(candidate.primaryItemID) answer the question?",
            record: record,
            outcome: { _ in
                guard let ruling = signals.ruling else { return "no ruling" }
                let forms = ruling.satisfiedCompletionIDs.joined(separator: ", ")
                return (ruling.accepted ? "accepted" : "rejected")
                    + (forms.isEmpty ? "" : " — satisfies \(forms)")
                    + " — \(ruling.note.prefix(160))"
            },
            onActivity: onActivity)
        return signals.ruling
    }
}

final class ContractAdjudicationSignals: @unchecked Sendable {
    private let lock = NSLock()
    private var _ruling: SolutionAdjudicator.Ruling?
    var ruling: SolutionAdjudicator.Ruling? {
        lock.lock(); defer { lock.unlock() }; return _ruling
    }
    func set(_ ruling: SolutionAdjudicator.Ruling) { lock.lock(); _ruling = ruling; lock.unlock() }
}

struct ReportContractAdjudicationTool: AgentTool {
    var turnEffect: AgentToolEffect { .finish }
    let signals: ContractAdjudicationSignals
    let contract: SuccessContract?

    var spec: ToolSpec {
        let ids = contract?.citableAnswerIDs ?? []
        let idField = ids.isEmpty ? "" : """
            "satisfied_completion_ids":{"type":"array","items":{"type":"string","enum":[\
            \(ids.map { "\"\($0)\"" }.joined(separator: ","))]},\
            "description":"The forms of complete answer this claim satisfies, as YOU judge them. May be several. Required when accepting."},
            """
        return ToolSpec(
            name: "report_contract_adjudication",
            description: """
            Record whether the claim, assuming its mathematics is correct, completely answers \
            the user's original question under the frozen contract.
            """,
            inputSchemaJSON: """
            {"type":"object","properties":{\
            "verdict":{"type":"string","enum":["accepted","rejected"]},\
            \(idField)\
            "note":{"type":"string","description":"Accepted: which form(s) it satisfies and why the question is fully answered. Rejected: precisely what the question asks that this does not deliver — the quantifier, the case, the hypothesis, or the listed non-solution condition it falls under. The branch reads this and may repair the claim, so name the gap, not just the verdict."}\
            },"required":["verdict","note"]}
            """
        )
    }

    func execute(inputJSON: String) async throws -> String {
        let input = jsonObject(inputJSON)
        guard let verdict = input["verdict"] as? String,
              ["accepted", "rejected"].contains(verdict) else {
            throw ResearchError(message: "'verdict' must be 'accepted' or 'rejected'")
        }
        guard let note = (input["note"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty else {
            throw ResearchError(message: """
            missing 'note' — a verdict with no reasoning is unusable. On a rejection the \
            branch reads this to decide what to fix.
            """)
        }

        var satisfied = (input["satisfied_completion_ids"] as? [Any] ?? [])
            .compactMap { $0 as? String }
        if let contract {
            satisfied = satisfied.filter { contract.answer(id: $0) != nil }
        }
        // Accepting without naming what was answered leaves the program unable to say what it
        // settled — and is the shape an over-agreeable acceptance takes.
        if verdict == "accepted", satisfied.isEmpty, !(contract?.completeAnswers.isEmpty ?? true) {
            throw ResearchError(message: """
            REJECTED — you accepted the claim but named no form of complete answer it \
            satisfies. Name at least one of \
            \(contract?.citableAnswerIDs.joined(separator: ", ") ?? "the contract's forms"), \
            or reject the claim and say what the question still asks for.
            """)
        }

        signals.set(SolutionAdjudicator.Ruling(
            accepted: verdict == "accepted",
            note: String(note.prefix(1500)),
            satisfiedCompletionIDs: satisfied))
        return "Adjudication recorded. End your turn."
    }
}
