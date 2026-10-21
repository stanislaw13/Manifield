import Foundation
import ManifieldCore

struct ProgramError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// The one channel between research branches. Branches run under contradictory priors
/// and never see each other's reasoning — that isolation is the whole point — but hard
/// results have to cross, or the portfolio wastes work re-deriving the same facts.
public enum ProgramTools {

    /// `publish_finding`, given only to branches of a real program.
    ///
    /// It submits to a pool rather than broadcasting. Which branches receive a finding is the
    /// director's call: the publishing branch knows the result but not its siblings' routes,
    /// and injecting every finding into every branch is what collapses a portfolio of
    /// deliberately contradictory approaches back into one line of thought.
    ///
    /// `adjudicate`, when set, verifies a route-killing claim in fresh context *before* it is
    /// submitted: a rejected claim becomes a typed refusal the branch can repair, and a
    /// confirmed one carries its independent verdict into routing. Nil keeps the manual
    /// behaviour — the claim is submitted unverified and the user rules on it.
    public static func publishFindingTool(
        branchPlanID: String,
        targetRevisionID: String? = nil,
        adjudicate: (@Sendable (ProgramFinding) async throws -> FindingAdjudicator.Ruling?)? = nil,
        publish: @escaping @Sendable (ProgramFinding) async throws -> Void
    ) -> AgentTool {
        PublishFindingTool(branchPlanID: branchPlanID, targetRevisionID: targetRevisionID,
                           adjudicate: adjudicate, publish: publish)
    }

    /// Freeform challenge to the fixed goal statement. Unlike a solution claim, this says that the
    /// request cannot be solved as written; it does not classify why and does not rewrite it.
    static func problemChallengeTool(
        branchPlanID: String,
        signals: TaskSignals,
        file: @escaping @Sendable (_ description: String, _ replacementRequest: String?,
                                   _ proposedTargetItemID: String?,
                                   _ evidenceItemIDs: [String]) async throws -> String
    ) -> AgentTool {
        SubmitProblemChallengeTool(
            branchPlanID: branchPlanID, signals: signals, file: file)
    }

}

struct SubmitProblemChallengeTool: AgentTool {
    var turnEffect: AgentToolEffect { .suspend }
    let branchPlanID: String
    let signals: TaskSignals
    let file: @Sendable (_ description: String, _ replacementRequest: String?,
                         _ proposedTargetItemID: String?,
                         _ evidenceItemIDs: [String]) async throws -> String

    var spec: ToolSpec {
        ToolSpec(
            name: "submit_problem_challenge",
            description: """
            Challenge the fixed research-goal Statement itself when you have found a concrete defect that
            makes a solution impossible as written. Describe freely what is wrong and the
            mathematical evidence. This is not for a hard problem, a costly route, an
            inconvenient scope, missing progress, or a version you would prefer to solve.
            Do not weaken, strengthen, generalize, specialize, or otherwise replace a valid
            request to suit your method. A replacement is optional and must be the smallest
            correction forced by the defect; omit it when the right repair is not established.
            You may point to a newly created target item of any natural theory type. Filing
            settles nothing: fresh mathematical and scope reviews run separately, then the
            director decides which branches or parts of the research stop, continue, or replan.
            An accepted challenge may leave other parts of the request unresolved. This ends
            the current task.
            """,
            inputSchemaJSON: #"{"type":"object","properties":{"description":{"type":"string","description":"What is wrong, the evidence, and why it makes the fixed goal Statement impossible as written"},"proposed_replacement_request":{"type":"string","description":"Optional minimal corrected statement forced by the defect"},"proposed_target_item_id":{"type":"string","description":"Optional newly created library item that should represent the corrected goal; any fitting item type is allowed"},"evidence_item_ids":{"type":"array","items":{"type":"string"},"description":"Durable items supporting the challenge"}},"required":["description"]}"#)
    }

    func execute(inputJSON: String) async throws -> String {
        let input = jsonObject(inputJSON)
        guard let description = (input["description"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !description.isEmpty else {
            throw ProgramError(message: "missing 'description' — name the actual defect and why it makes the fixed goal Statement impossible")
        }
        let replacement = (input["proposed_replacement_request"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let targetItem = (input["proposed_target_item_id"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let evidence = (input["evidence_item_ids"] as? [Any] ?? [])
            .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let id = try await file(
            description,
            replacement?.isEmpty == false ? replacement : nil,
            targetItem?.isEmpty == false ? targetItem : nil,
            evidence)
        signals.setProblemChallenge(id)
        signals.setOutcome(TaskOutcome(
            kind: .completed,
            summary: "Filed problem challenge \(id): \(description)"))
        return "Challenge filed against the fixed goal revision. It changes nothing yet. End your turn now while independent mathematical and scope reviews run."
    }
}

extension ProgramTools {

    /// `close_branch`, given to a chat that is working on a branch. Closing out an approach
    /// that has clearly died is bookkeeping the mathematician should not have to do by
    /// hand — but it is a verdict, so the reason is required and lands in the plan log.
    ///
    /// Deliberately narrow: it can only reach the branch the conversation is attached to,
    /// and only the closed-out statuses. Reopening and deleting stay with the user.
    public static func closeBranchTool(
        branchPlanID: String,
        branchTitle: String,
        close: @escaping @Sendable (PlanStatus, String) async throws -> Void
    ) -> AgentTool {
        CloseBranchTool(branchPlanID: branchPlanID, branchTitle: branchTitle, close: close)
    }
}

/// Statuses `close_branch` may set — a subset of what the user can do by hand.
private let closableStatuses: [PlanStatus] = [.done, .failed, .paused]

struct CloseBranchTool: AgentTool {
    let branchPlanID: String
    let branchTitle: String
    let close: @Sendable (PlanStatus, String) async throws -> Void

    var spec: ToolSpec {
        ToolSpec(
            name: "close_branch",
            description: """
            Close out the research branch this conversation is attached to ('\(branchTitle)'). \
            Use 'failed' when the approach was tried and did not work — that is a real \
            result and the archive is read to learn what has been ruled out — 'done' when \
            it finished its job, and 'paused' to set it aside without a verdict. State the \
            reason plainly; it is written to the plan's log and is what the next program \
            will read. Do not use this to tidy up a branch that is merely slow or \
            unfinished, and do not close a branch the user has not agreed is over.
            """,
            inputSchemaJSON: """
            {"type":"object","properties":{\
            "status":{"type":"string","enum":[\(closableStatuses.map { "\"\($0.rawValue)\"" }.joined(separator: ","))],\
            "description":"failed = tried and did not work; done = finished; paused = set aside without a verdict"},\
            "reason":{"type":"string","description":"Why, in one or two sentences — the evidence, not a summary of effort"}\
            },"required":["status","reason"]}
            """
        )
    }

    func execute(inputJSON: String) async throws -> String {
        let input = jsonObject(inputJSON)
        guard let rawStatus = input["status"] as? String,
              let status = PlanStatus(rawValue: rawStatus),
              closableStatuses.contains(status) else {
            throw ProgramError(message: "'status' must be one of "
                + closableStatuses.map(\.rawValue).joined(separator: ", "))
        }
        guard let reason = (input["reason"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty else {
            throw ProgramError(message: """
            missing 'reason' — a closed branch without a recorded reason is worse than an \
            open one, because the next program cannot tell what was ruled out
            """)
        }
        try await close(status, reason)
        return "Branch '\(branchTitle)' marked \(status.rawValue). The reason is in its plan log, "
            + "and it now sits in the Research tab's archive."
    }
}

struct PublishFindingTool: AgentTool {
    let branchPlanID: String
    let targetRevisionID: String?
    /// Fresh-context verification of a route-killing claim, run before it is submitted.
    let adjudicate: (@Sendable (ProgramFinding) async throws -> FindingAdjudicator.Ruling?)?
    let publish: @Sendable (ProgramFinding) async throws -> Void

    /// Kinds whose circulation could stop or redirect another branch, and which are therefore
    /// checked in fresh context before they are allowed anywhere near one. Everything else
    /// travels with its honest, unverified status attached.
    static let decisiveKinds: Set<ProgramFinding.Kind> = [.counterexample]

    var spec: ToolSpec {
        let kinds = ProgramFinding.Kind.allCases.map(\.rawValue)
        let decisiveFlow = adjudicate == nil
            ? "A claim that would kill another branch's route — a counterexample above all — is checked by the user before anything acts on it."
            : "A claim that would kill another branch's route — a counterexample above all — is verified by an independent fresh-context adjudicator before it is submitted at all (this can take a few minutes). If the adjudicator rejects it you will be told exactly why and can repair the claim; nothing wrong ever reaches the pool."
        return ToolSpec(
            name: "publish_finding",
            description: """
            Submit a hard result to this research program's finding pool. Submit FACTS only — \
            a structural obstruction, a reduction, decisive computational evidence, a candidate \
            answer, a counterexample, or the outcome of a proof attempt. Never submit hunches, \
            plans or reasoning: sibling branches work under deliberately different assumptions \
            and must reach their own conclusions. Use 'lens_abandoned' when the evidence has \
            forced you off your research lens, and say what forced it. \
            This does NOT broadcast: the research director reads what you submit and decides \
            which branches, if any, should receive it, because you cannot see their routes and \
            it cannot see your reasoning. Submit anything a sibling could waste work without; \
            do not submit route-specific progress that is only meaningful inside your own \
            approach. \(decisiveFlow) \
            Submitting is not finishing — end the task afterwards with finish_task as usual, \
            and if you believe the result actually answers the user's whole question, use \
            claim_solution rather than assuming a finding settles it.
            """,
            inputSchemaJSON: """
            {"type":"object","properties":{\
            "kind":{"type":"string","enum":[\(kinds.map { "\"\($0)\"" }.joined(separator: ","))]},\
            "statement":{"type":"string","description":"The result itself, ≤600 chars — precise and self-contained"},\
            "item_ids":{"type":"array","items":{"type":"string"},"description":"Theory item ids this concerns"},\
            "artifact_path":{"type":"string","description":"Project-relative path of supporting evidence, e.g. artifacts/<run>/stdout.txt"}\
            },"required":["kind","statement"]}
            """
        )
    }

    func execute(inputJSON: String) async throws -> String {
        let input = jsonObject(inputJSON)
        guard let rawKind = input["kind"] as? String else {
            throw ProgramError(message: "missing 'kind'")
        }
        guard let kind = ProgramFinding.Kind(rawValue: rawKind) else {
            throw ProgramError(message: "unknown kind '\(rawKind)' — valid kinds: "
                + ProgramFinding.Kind.allCases.map(\.rawValue).joined(separator: ", "))
        }
        guard let statement = (input["statement"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !statement.isEmpty else {
            throw ProgramError(message: "missing 'statement' — say what the result actually is")
        }

        var finding = ProgramFinding(
            branchPlanID: branchPlanID,
            targetRevisionID: targetRevisionID,
            kind: kind,
            statement: statement,
            itemIDs: (input["item_ids"] as? [Any] ?? []).compactMap { $0 as? String },
            artifactPath: input["artifact_path"] as? String)

        // A route-killing claim is verified in fresh context *before* it exists as a finding.
        // A rejected claim never enters the pool — the refusal carries the adjudicator's note,
        // and the branch gets to repair the claim instead of poisoning its siblings with it.
        // Publishing first and pausing afterwards was the old flow, and it was strictly worse.
        if Self.decisiveKinds.contains(kind), let adjudicate {
            guard let ruling = try await adjudicate(finding) else {
                try await publish(finding)
                return """
                Submitted, but the independent adjudication turn did not reach a ruling, so it \
                carries no verification. The director will weigh it accordingly. Finish the \
                CURRENT task with finish_task now, reporting what you established.
                """
            }
            guard ruling.confirmed else {
                throw ProgramError(message: """
                REJECTED — an independent fresh-context adjudicator could not confirm this \
                \(kind.rawValue): \(ruling.note) Nothing was submitted. Repair the claim and \
                submit again, or report honestly in finish_task that it did not survive \
                verification.
                """)
            }
            finding.verdict = .confirmed
            finding.verdictNote = "independent adjudication: \(ruling.note)"
            try await publish(finding)
            return """
            Submitted and independently CONFIRMED by a fresh-context adjudication \
            (\(ruling.note.prefix(300))). The director decides which branches receive it. \
            Finish the CURRENT task with finish_task now, citing the items and the artifact. \
            If you believe this answers the user's whole question, call claim_solution — a \
            confirmed finding is not by itself a solution.
            """
        }

        try await publish(finding)
        return """
        Submitted to the program's finding pool. The director decides which branches receive \
        it and when; siblings do not see it automatically. Carry on with your own route.
        """
    }
}

struct ClaimSolutionTool: AgentTool {
    var turnEffect: AgentToolEffect { .suspend }
    let branchPlanID: String
    let contract: SuccessContract?
    let signals: TaskSignals
    /// Files the candidate and returns its id. Snapshotting the cited items is the caller's
    /// job — it holds the store, and the hashes are what make a review reusable later.
    let claim: @Sendable (_ primaryItemID: String, _ supporting: [String],
                          _ completionIDs: [String]?, _ argument: String) async throws -> String

    var spec: ToolSpec {
        let completions = contract?.citableAnswerIDs ?? []
        let completionField = completions.isEmpty ? "" : """
            "claimed_completion_ids":{"type":"array","items":{"type":"string","enum":[\
            \(completions.map { "\"\($0)\"" }.joined(separator: ","))]},\
            "description":"Which forms of complete answer you believe this satisfies. Optional, and not binding — say what you think and let the adjudicator decide; one result may satisfy several."},
            """
        return ToolSpec(
            name: "claim_solution",
            description: """
            Claim that specific durable results in the library completely answer the user's \
            question. This does NOT settle the program and does not end your branch. It files \
            a candidate, which is then checked twice, independently of you: once against the \
            success contract (does this answer the question that was actually asked?) and once \
            by review (is the mathematics right, and does the argument actually assemble?). \
            Only after both pass may the director settle anything. \
            Use this when the fixed goal Statement remains valid and your result answers it. If your \
            result instead establishes that the goal Statement or requested object is \
            defective and the task is impossible as written, use submit_problem_challenge; \
            that follows parallel independent review but lets the director preserve unresolved \
            parts and replan under a governed revision. \
            Claim when the work exists in the library and you believe it closes the question — \
            not when you expect it to close, and not because your tasks are finished. If the \
            claim is rejected you will be told exactly why and your branch carries on, so an \
            honest early claim costs little; a claim with nothing behind it costs your \
            credibility on the next one. This ends the current task.
            """,
            inputSchemaJSON: """
            {"type":"object","properties":{\
            "primary_item_id":{"type":"string","description":"The theory item holding the result you are claiming"},\
            "supporting_item_ids":{"type":"array","items":{"type":"string"},"description":"Other items the claim rests on that are not reachable through the primary item's dependencies"},\
            \(completionField)\
            "argument":{"type":"string","description":"Why this completely answers the user's question, in ordinary mathematical language: what was established, under which hypotheses, and why nothing is left open. ≤1500 chars."}\
            },"required":["primary_item_id","argument"]}
            """
        )
    }

    func execute(inputJSON: String) async throws -> String {
        let input = jsonObject(inputJSON)
        guard let primary = (input["primary_item_id"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !primary.isEmpty else {
            throw ProgramError(message: "missing 'primary_item_id' — name the item holding the result")
        }
        guard let argument = (input["argument"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !argument.isEmpty else {
            throw ProgramError(message: """
            missing 'argument' — say why this answers the user's question. The adjudicator \
            reads this, not your transcript, and cannot infer the claim from the item alone.
            """)
        }

        let supporting = (input["supporting_item_ids"] as? [Any] ?? []).compactMap { $0 as? String }
        var completionIDs = (input["claimed_completion_ids"] as? [Any] ?? [])
            .compactMap { $0 as? String }
        // An unknown id is a slip, not grounds for refusal: the ids are a convenience for the
        // adjudicator, which forms its own view of what was satisfied either way.
        if let contract {
            completionIDs = completionIDs.filter { contract.answer(id: $0) != nil }
        }

        let candidateID = try await claim(primary, supporting,
                                          completionIDs.isEmpty ? nil : completionIDs, argument)
        signals.setSolutionClaim(candidateID)
        signals.setOutcome(TaskOutcome(
            kind: .completed,
            summary: "Filed solution candidate on \(primary): \(argument)"))

        return """
        Candidate filed on '\(primary)'. It settles nothing yet — contract adjudication runs \
        next in fresh context, and review after it if that passes. End your turn now; you will \
        be told the outcome either way.
        """
    }
}

/// Renders what crosses between branches, and derives findings the harness can assert
/// mechanically instead of asking a model to claim them.
public enum ProgramContext {

    /// The "Shared facts" section injected into a branch's task context.
    ///
    /// Only project-memory FACTS cross — the goal, and strategies already eliminated.
    /// Beliefs (Key Insights, Current Status, Active Strategies) are deliberately
    /// withheld: a shared set of beliefs is exactly what collapses a portfolio of
    /// contradictory approaches back into one line of thought. Returns nil when there
    /// is nothing to share, so the section is omitted rather than rendered empty.
    ///
    /// `routedFindings` are the ones the director decided this branch should have — already
    /// filtered by the caller through `ResearchProgram.findings(routedTo:)`. Everything else
    /// in the pool stays out of this branch's context, including findings that are perfectly
    /// true: a proof branch's promising lemma injected into a refutation branch does not help
    /// it refute, it pulls it toward the proof.
    public static func sharedFactsSection(
        projectMemory: String,
        routedFindings: [ProgramFinding],
        routes: [ResearchRoute] = []
    ) -> String? {
        let memory = MemoryDocument.parse(markdown: projectMemory)
        var factLines: [String] = []
        if let goal = memory.sections[.goal]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !goal.isEmpty {
            factLines.append("Program goal:\n\(goal)")
        }
        if let eliminated = memory.sections[.eliminatedStrategies]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !eliminated.isEmpty {
            factLines.append("Already eliminated (do not repeat without a genuinely new twist):\n\(eliminated)")
        }
        // The registry outlives the branches, so this is what stops generation 3 from
        // re-running what generation 1 already killed. Memory is capped and the journal is
        // truncated; nothing else in a branch's context carries this.
        if let closed = routes.closedRouteDigest {
            factLines.append(closed)
        }

        guard !factLines.isEmpty || !routedFindings.isEmpty else { return nil }

        let findingLines = routedFindings.map { finding -> String in
            var line = "- [\(finding.kind.rawValue)] \(finding.statement)"
            if !finding.itemIDs.isEmpty { line += " — items: \(finding.itemIDs.joined(separator: ", "))" }
            if let path = finding.artifactPath { line += " — evidence: \(path)" }
            if finding.isConfirmed {
                // The note says who confirmed it — the mathematician, or the fresh-context
                // adjudication on an unattended run.
                line += " — CONFIRMED"
                if let note = finding.verdictNote, !note.isEmpty { line += ": \(note)" }
            } else if finding.isProvisional {
                // The default trust state, said out loud rather than left to be inferred from
                // the absence of CONFIRMED: a sibling reading this is building on a branch's
                // claim, not a checked fact, and building on it wrong is what corrupts siblings.
                line += " — UNVERIFIED, the publishing branch's own claim"
            }
            return line
        }

        return PromptLibrary.text("program_shared_facts", [
            "FACTS": factLines.isEmpty ? "(none recorded yet)" : factLines.joined(separator: "\n\n"),
            "FINDINGS": findingLines.isEmpty
                ? "(nothing has been routed to this branch)"
                : findingLines.joined(separator: "\n")
        ])
    }

    /// A prove task's finding, derived from the proof outcome rather than claimed by a
    /// model: a clean review with no outstanding issues is the only case worth telling
    /// siblings about. Everything weaker stays inside the branch.
    public static func finding(
        fromProveOutcome outcome: ProofWorkbench.Outcome,
        targetID: String,
        branchPlanID: String
    ) -> ProgramFinding? {
        guard outcome.finalStatus == .reviewedNoErrors, outcome.outstandingIssues.isEmpty else {
            return nil
        }
        return ProgramFinding(
            branchPlanID: branchPlanID,
            kind: .proofOutcome,
            statement: "\(targetID): proof drafted and reviewed with no errors found "
                + "(\(outcome.roundsUsed) round(s)). Treat as evidence, not certainty.",
            itemIDs: [targetID])
    }
}
