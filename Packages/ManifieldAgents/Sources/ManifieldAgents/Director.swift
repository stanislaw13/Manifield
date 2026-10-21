import Foundation
import ManifieldCore

/// The research director: decides what a program does when every branch has stopped.
///
/// Deliberately **not** a long-lived agent. It is invoked with fresh context each time and
/// reads durable state — contract, registry, findings, budget — never the transcripts that
/// produced them. A director carrying the whole investigation in context would defend the
/// portfolio it chose and rationalise the routes it commissioned, which is exactly the
/// capability we need it not to have.
public struct Director {

    /// Why the director is being convened. The decision surface is the same either way;
    /// what changes is the question it is answering.
    public enum Trigger: Equatable, Sendable {
        /// Every branch of the generation has stopped — the ordinary boundary.
        case generationEnded
        /// A solution candidate passed contract adjudication and review mid-generation.
        /// Only the director may act on it: the branch that filed it is parked, and the
        /// siblings are still running.
        case solutionAccepted(itemID: String)
        /// A freeform challenge to the fixed goal Statement passed separate mathematical and
        /// scope/necessity review. It may invalidate only part of the ongoing research.
        case problemChallengeAccepted(challengeID: String)
    }

    /// What the director decided.
    public struct Decision: Equatable, Sendable {
        public enum Verdict: String, Sendable, CaseIterable {
            /// The question was answered, on a candidate that passed both independent
            /// checks. Refused in code when no candidate has been accepted.
            case settled
            /// Not reachable with the means available. A result, not a shrug.
            case futile
            /// A named gap is worth another generation.
            case `continue` = "continue"
        }

        public var verdict: Verdict
        /// Why, in the director's own words.
        public var rationale: String
        /// Two or three sentences for the research page. The status line is a by-product of a
        /// turn that was happening anyway — never a separate "write a summary" call.
        public var status: String
        /// New routes, when the verdict is `continue`.
        public var routes: [ResearchRoute]
        /// Freeform work dispatched directly, when the verdict is `continue`. The director may
        /// use this instead of or alongside `routes` — a single small, decisive dispatch (what
        /// used to be a "pilot") needs no portfolio built around it.
        public var workerAssignments: [WorkerAssignment]
        public var challengeGovernance: ProblemChallenge.Governance?

        public init(verdict: Verdict, rationale: String, status: String,
                    routes: [ResearchRoute] = [],
                    workerAssignments: [WorkerAssignment] = [],
                    challengeGovernance: ProblemChallenge.Governance? = nil) {
            self.verdict = verdict
            self.rationale = rationale
            self.status = status
            self.routes = routes
            self.workerAssignments = workerAssignments
            self.challengeGovernance = challengeGovernance
        }
    }

    /// Mechanical evidence of whether the program is still learning. Computed, never asked:
    /// a model asked whether it is making progress says yes.
    public struct ProgressSignal: Equatable, Sendable {
        /// Findings submitted this generation that carry new information.
        public var newFindings: Int
        /// Solution candidates filed so far, by outcome. An accepted one is the only thing
        /// that licenses `settled`, and the code enforces that rather than the prose.
        public var candidatesFiled: Int
        public var candidatesRejected: Int
        public var hasAcceptedSolution: Bool
        public var generation: Int
        public var tokensSpent: Int
        public var tokensRemaining: Int
        public var isInitialPlanning: Bool = false

        /// The futility signal: a generation that produced nothing is the clearest evidence
        /// available that the current line of attack is exhausted.
        public var isStalled: Bool { !isInitialPlanning && newFindings == 0 }

        public var promptLine: String {
            if isInitialPlanning {
                return "Initial planning: no work has been commissioned yet. This is not evidence of futility. "
                    + "Budget: \(tokensSpent) tokens spent, \(tokensRemaining) remaining."
            }
            var line = "Generation \(generation) produced \(newFindings) new finding(s) since the previous decision"
            line += " of the kinds that carry information (evidence, reduction, obstruction, counterexample)."
            if isStalled {
                line += " NOTHING NEW WAS LEARNED this generation — the strongest available"
                line += " evidence that another generation of the same shape will also produce nothing."
            }
            if hasAcceptedSolution {
                line += " A solution candidate has PASSED contract adjudication and review."
            } else if candidatesFiled > 0 {
                line += " \(candidatesFiled) solution candidate(s) were filed"
                line += candidatesRejected > 0 ? ", \(candidatesRejected) rejected" : ""
                line += "; none has been accepted."
            } else {
                line += " No solution candidate has been filed."
            }
            line += " Budget: \(tokensSpent) tokens spent, \(tokensRemaining) remaining."
            return line
        }
    }

    /// Finding kinds that count as having learned something. A `candidate_answer` or a
    /// `lens_abandoned` restates the branch's own position; it is not new information about
    /// the problem.
    static let informativeKinds: Set<ProgramFinding.Kind> = [
        .evidence, .reduction, .obstruction, .counterexample, .proofOutcome
    ]

    public static func progressSignal(
        program: ResearchProgram,
        records: [String: RunRecord],
        generation: Int,
        findingsBefore: Int,
        tokensSpent authoritativeTokensSpent: Int? = nil
    ) -> ProgressSignal {
        let informative = program.findings
            .dropFirst(findingsBefore)
            .filter { informativeKinds.contains($0.kind) && !$0.isRejected }
        let spent = authoritativeTokensSpent ?? (program.planningTokensUsed
            + records.values.reduce(0) { $0 + $1.tokensUsed })
        return ProgressSignal(
            newFindings: informative.count,
            candidatesFiled: program.solutions.count,
            candidatesRejected: program.solutions.filter { $0.status.isRejected }.count,
            hasAcceptedSolution: program.acceptedSolution != nil,
            generation: generation,
            tokensSpent: spent,
            tokensRemaining: max(0, program.programTokenBudget - spent),
            isInitialPlanning: generation == 1 && program.branches.isEmpty
                && program.workerAssignments.isEmpty && program.findings.isEmpty
                && (program.routes ?? []).isEmpty)
    }

    // MARK: - Prompt

    public static func systemPrompt(
        program: ResearchProgram,
        records: [String: RunRecord],
        signal: ProgressSignal,
        branchMemories: [String: String],
        projectMemory: String
    ) -> String {
        var parts = [PromptLibrary.text("director_system")]
        parts.append(ContextAssembly.honestyRules)
        parts.append(ContextAssembly.researchTargetSection(
            originalRequest: program.researchRequest, contract: program.contract))
        parts.append(ContextAssembly.researchGoalItemSection(program.activeTargetRevision))
        parts.append("Progress signal (computed, not reported by any agent):\n\(signal.promptLine)")

        let routes = program.routes ?? []
        if !routes.isEmpty {
            parts.append("""
            Route registry — every line of attack this program has tried. You may not \
            re-propose a mechanism that is already here. The bracketed id is what \
            `descends_from` refers to:

            \(routes.map { "- [\($0.id)] \($0.line)" }.joined(separator: "\n"))
            """)
        }
        if !program.workerAssignments.isEmpty {
            parts.append("""
            Worker dispatches this program has made directly, outside a route. Do not \
            re-dispatch an objective already covered by one still running:

            \(program.workerAssignments.map { assignment -> String in
                var line = "- [\(assignment.id)] \(assignment.objective)"
                if let stop = assignment.stopCondition, !stop.isEmpty {
                    line += " — stop: \(stop)"
                }
                if let planID = assignment.planID {
                    line += " (branch `\(planID)`)"
                }
                return line
            }.joined(separator: "\n"))
            """)
        }
        if !program.skippedCells.isEmpty {
            parts.append("Approaches deliberately not taken:\n" + program.skippedCells
                .map { "- \($0.cell): \($0.why)" }.joined(separator: "\n"))
        }

        let branchLines = program.branches.map { branch -> String in
            let record = records[branch.planID]
            let outcome: String
            switch record?.state {
            case .finished(let summary): outcome = "finished — \(summary.prefix(300))"
            case .failed(let reason): outcome = "failed — \(reason.prefix(200))"
            default: outcome = "stopped (\(record.map { String(describing: $0.state) } ?? "no record"))"
            }
            var line = "- \(branch.title)"
                + (branch.challengesLeadingAnswer ? " [challenges the leading answer]" : "")
                + ": \(outcome)"
            line += " — \(record?.tokensUsed ?? 0) tokens"
            if let memory = branchMemories[branch.planID], !memory.isEmpty {
                let eliminated = MemoryDocument.parse(markdown: memory)
                    .sections[.eliminatedStrategies]?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !eliminated.isEmpty { line += "\n  eliminated: \(eliminated.prefix(400))" }
            }
            return line
        }
        parts.append("Branches this generation:\n\(branchLines.joined(separator: "\n"))")

        let findings = program.findings.filter { !$0.isRejected }
        if !findings.isEmpty {
            parts.append("Findings submitted, and where each was routed:\n"
                + findings.map { finding -> String in
                    var line = "- [\(finding.kind.rawValue)] (from \(finding.branchPlanID)) "
                        + finding.statement
                    if finding.isConfirmed {
                        line += " — CONFIRMED"
                        if let note = finding.verdictNote, !note.isEmpty { line += " (\(note))" }
                    } else if finding.isProvisional {
                        line += " — PROVISIONAL, not independently reviewed"
                    }
                    switch program.routing(forFinding: finding.id) {
                    case .none:
                        line += "\n  routing: NOT YET ROUTED — no branch has seen this"
                    case .some(let routing) where routing.decision == .sendNow:
                        line += "\n  routing: sent to \(routing.recipientPlanIDs.joined(separator: ", "))"
                    case .some(let routing):
                        line += "\n  routing: \(routing.decision.rawValue)"
                            + (routing.rationale.isEmpty ? "" : " — \(routing.rationale)")
                    }
                    return line
                }.joined(separator: "\n"))
        }

        if !program.solutions.isEmpty {
            parts.append("Solution candidates:\n" + program.solutions.map { candidate in
                var line = "- \(candidate.primaryItemID) (from \(candidate.branchPlanID)) "
                    + "— \(candidate.status.rawValue)"
                if let ruling = candidate.contractRuling {
                    line += "\n  contract: \(ruling.accepted ? "accepted" : "rejected") — \(ruling.note.prefix(300))"
                }
                if let ruling = candidate.reviewRuling {
                    line += "\n  review: \(ruling.accepted ? "accepted" : "rejected") — \(ruling.note.prefix(300))"
                }
                return line
            }.joined(separator: "\n"))
        }
        if !program.challenges.isEmpty {
            parts.append("Problem challenges:\n" + program.challenges.map { challenge in
                var line = "- `\(challenge.id)` from `\(challenge.branchPlanID)` — \(challenge.status.rawValue)\n  \(challenge.description.prefix(600))"
                if let ruling = challenge.mathematicalRuling {
                    line += "\n  mathematical review: \(ruling.accepted ? "accepted" : "rejected") — \(ruling.note.prefix(300))"
                }
                if let ruling = challenge.scopeRuling {
                    line += "\n  scope review: \(ruling.accepted ? "accepted" : "rejected") — \(ruling.note.prefix(300))"
                }
                if let replacement = challenge.proposedReplacementRequest {
                    line += "\n  proposed minimal correction: \(replacement.prefix(500))"
                }
                return line
            }.joined(separator: "\n"))
        }
        parts.append(ContextAssembly.memorySection(projectMemory))
        return parts.joined(separator: "\n\n")
    }

    /// Runs one director turn and returns its decision. Nil when the turn produced no verdict —
    /// the caller then leaves the program where it is rather than inventing one.
    public static func decide(
        runner: AgentRunner,
        program: ResearchProgram,
        records: [String: RunRecord],
        signal: ProgressSignal,
        branchMemories: [String: String] = [:],
        projectMemory: String = "",
        generation: Int,
        trigger: Trigger = .generationEnded,
        thinking: ThinkingLevel = .off,
        record: RecordTurn? = nil,
        onActivity: @escaping @Sendable (AgentActivity) -> Void = { _ in }
    ) async throws -> Decision? {
        let signals = DirectorSignals()
        let acceptedChallengeID: String?
        if case .problemChallengeAccepted(let challengeID) = trigger {
            acceptedChallengeID = challengeID
        } else {
            acceptedChallengeID = nil
        }
        let config = AgentConfig(
            systemPrompt: SystemPrompt(systemPrompt(
                program: program, records: records, signal: signal,
                branchMemories: branchMemories, projectMemory: projectMemory)),
            tools: DirectorTools.tools(
                signals: signals,
                existingRoutes: program.routes ?? [],
                generation: generation + 1,
                canSettle: program.acceptedSolution != nil && acceptedChallengeID == nil,
                activeTargetRevisionID: program.activeTargetRevisionID,
                challenge: acceptedChallengeID.flatMap { id in
                    program.challenges.first { $0.id == id && $0.status == .accepted }
                },
                branchIDs: program.branches.map(\.planID)),
            maxIterations: 6,
            thinking: thinking)

        _ = try await runRecordedTurn(
            runner: runner, config: config,
            history: [.user(userMessage(generation: generation, trigger: trigger,
                                        isInitialPlanning: signal.isInitialPlanning))],
            programID: program.id, role: .directorVerdict,
            title: "Director — generation \(generation)",
            record: record,
            outcome: { _ in
                guard let decision = signals.decision else { return "no verdict" }
                return "\(decision.verdict.rawValue) — \(decision.rationale.prefix(180))"
            },
            onActivity: onActivity)

        guard var decision = signals.decision else { return nil }
        if acceptedChallengeID != nil, decision.challengeGovernance == nil {
            return nil
        }
        // Ordinarily, a `continue` with no routes is not a continuation. The challenge path
        // has one deliberate exception: the director may preserve named, unaffected branches
        // under the unchanged target without inventing duplicate replacement routes for them.
        let resumesGovernedBranches = acceptedChallengeID != nil
            && decision.challengeGovernance?.applyRevision == false
            && !(decision.challengeGovernance?.continueBranchPlanIDs.isEmpty ?? true)
            && decision.challengeGovernance?.openNewPortfolio == false
        if decision.verdict == .continue, decision.routes.isEmpty,
           decision.workerAssignments.isEmpty, !resumesGovernedBranches {
            decision = Decision(
                verdict: .futile,
                rationale: decision.rationale
                    + " [downgraded: the director chose to continue but dispatched nothing]",
                status: decision.status,
                challengeGovernance: decision.challengeGovernance)
        }
        return decision
    }

    public static func userMessage(generation: Int,
                                   trigger: Trigger = .generationEnded,
                                   isInitialPlanning: Bool = false) -> String {
        let opening: String
        switch trigger {
        case .generationEnded:
            opening = isInitialPlanning
                ? "This is the first planning decision. No branches have run; commission the initial work."
                : "Every branch of generation \(generation) has stopped."
        case .solutionAccepted(let itemID):
            opening = """
            A branch filed a solution candidate on `\(itemID)`, and it passed BOTH \
            independent checks: contract adjudication found that it answers the user's \
            question as the contract defines it, and review found the mathematics and the \
            assembled argument sound.

            Sibling branches are still running — nothing was stopped on the claim alone. \
            Only you may act on it. `settled` is now available and is usually right; before \
            taking it, read the rulings below and check that what was accepted answers the \
            whole question rather than one part of it. If a live branch is still working a \
            part the candidate does not cover, say so and `continue`.
            """
        case .problemChallengeAccepted(let challengeID):
            opening = """
            Problem challenge `\(challengeID)` passed BOTH independent gates: the alleged
            defect is mathematically sound, and the scope reviewer found that it genuinely
            makes the fixed goal Statement impossible as written rather than merely inconvenient.

            The challenge does not answer every remaining part of the user's request. First
            call govern_problem_challenge: decide whether to adopt a new immutable revision,
            which existing branches stop, which require replanning, and which unaffected work
            remains relevant. If research remains, choose `continue` and propose the routes
            that carry it forward under the governed target. Do not settle on a challenge.
            """
        }
        let continuationInstruction: String
        if case .problemChallengeAccepted = trigger {
            continuationInstruction = """
            If you choose `continue`, call propose_routes or dispatch_worker only when \
            governance opens a new portfolio or replans affected work. You may instead \
            continue named unaffected branches under an unchanged target without \
            manufacturing duplicate routes or assignments.
            """
        } else {
            continuationInstruction = """
            If you choose `continue`, also call propose_routes and/or dispatch_worker. A \
            genuinely broad portfolio needs routes; one small, decisive question — what a \
            pilot used to be — needs only a single dispatch_worker call with a tight budget \
            and stop condition, not a route built around it.
            """
        }
        return """
        \(opening) Decide the program's verdict now with set_program_verdict.

        \(continuationInstruction)
        """
    }
}


// MARK: - Routing

public extension Director {

    /// Decides who receives each newly submitted finding.
    ///
    /// A separate, much cheaper turn than the verdict, run while branches are still working.
    /// It reads the branch registry — each branch's prior, mechanism, assumptions and kill
    /// criterion — and the findings themselves, never a transcript. That is the whole reason
    /// this is the director's job rather than the publishing branch's: the branch knows its
    /// result and nothing about its siblings' routes, and the director knows the routes and
    /// nothing about anyone's reasoning.
    static func routingSystemPrompt(
        program: ResearchProgram,
        plans: [String: PlanDocument]
    ) -> String {
        var parts = [PromptLibrary.text("finding_routing")]
        parts.append(ContextAssembly.honestyRules)
        parts.append(ContextAssembly.researchTargetSection(
            originalRequest: program.researchRequest, contract: program.contract))
        parts.append(ContextAssembly.researchGoalItemSection(program.activeTargetRevision))

        let branchLines = program.branches.map { branch -> String in
            var line = "- `\(branch.planID)` — \(branch.title)"
            if branch.challengesLeadingAnswer { line += " [attacks the leading answer]" }
            if let plan = plans[branch.planID] {
                if !plan.lens.isEmpty {
                    line += "\n  prior: \(plan.lens.prefix(400))"
                }
                if let kill = plan.kill, !kill.isEmpty {
                    line += "\n  kill criterion: \(kill)"
                }
                let pending = plan.tasks.filter { $0.status == .pending || $0.status == .inProgress }
                if !pending.isEmpty {
                    line += "\n  still to do: " + pending.map(\.title).joined(separator: "; ")
                }
            }
            if let route = (program.routes ?? []).first(where: { $0.planID == branch.planID }) {
                line += "\n  mechanism: \(route.mechanism)"
                if !route.assumptions.isEmpty {
                    line += "\n  assumes: \(route.assumptions.joined(separator: "; "))"
                }
            }
            return line
        }
        parts.append("The branches, and what each is working under:\n"
            + branchLines.joined(separator: "\n"))

        let history = program.routings.compactMap { routing -> String? in
            guard let finding = program.findings.first(where: { $0.id == routing.findingID })
            else { return nil }
            return "- [\(finding.kind.rawValue)] \(finding.statement.prefix(160)) → "
                + "\(routing.decision.rawValue)"
                + (routing.recipientPlanIDs.isEmpty ? "" : " (\(routing.recipientPlanIDs.joined(separator: ", ")))")
        }
        if !history.isEmpty {
            parts.append("Already routed, so you can stay consistent:\n"
                + history.joined(separator: "\n"))
        }
        return parts.joined(separator: "\n\n")
    }

    static func routingUserMessage(_ findings: [ProgramFinding]) -> String {
        let blocks = findings.map { finding -> String in
            var block = "### `\(finding.id)` [\(finding.kind.rawValue)] from `\(finding.branchPlanID)`\n"
                + finding.statement
            if !finding.itemIDs.isEmpty {
                block += "\nItems: \(finding.itemIDs.joined(separator: ", "))"
            }
            if let path = finding.artifactPath { block += "\nEvidence: \(path)" }
            if finding.isConfirmed {
                block += "\nINDEPENDENTLY CONFIRMED"
                if let note = finding.verdictNote, !note.isEmpty { block += ": \(note)" }
            } else if finding.isProvisional {
                block += "\nPROVISIONAL — not independently reviewed. Route it as a hypothesis " +
                    "from the branch, and say so to whoever receives it, not as an established fact."
            }
            return block
        }
        return """
        These findings were submitted and have not been routed. Decide who receives each one, \
        then call route_findings once.

        \(blocks.joined(separator: "\n\n"))
        """
    }

    /// Runs one routing turn. Returns an empty array when the turn produced nothing, which
    /// leaves the findings unrouted and therefore unseen — the safe direction.
    static func route(
        runner: AgentRunner,
        program: ResearchProgram,
        plans: [String: PlanDocument],
        findings: [ProgramFinding],
        thinking: ThinkingLevel = .off,
        record: RecordTurn? = nil,
        onActivity: @escaping @Sendable (AgentActivity) -> Void = { _ in }
    ) async throws -> [FindingRouting] {
        guard !findings.isEmpty else { return [] }
        let signals = RoutingSignals()
        let config = AgentConfig(
            systemPrompt: SystemPrompt(routingSystemPrompt(program: program, plans: plans)),
            tools: DirectorTools.routingTools(
                signals: signals,
                findingIDs: findings.map(\.id),
                branchIDs: program.branches.map(\.planID)),
            maxIterations: 4,
            thinking: thinking)
        _ = try await runRecordedTurn(
            runner: runner, config: config,
            history: [.user(routingUserMessage(findings))],
            programID: program.id, role: .routing,
            title: "Who gets told about \(findings.count) finding(s)",
            record: record,
            outcome: { _ in
                let routings = signals.routings
                guard !routings.isEmpty else { return "nothing was routed" }
                let counts = Dictionary(grouping: routings, by: \.decision)
                    .map { "\($0.value.count) \($0.key.rawValue)" }
                    .sorted()
                return counts.joined(separator: ", ")
            },
            onActivity: onActivity)
        return signals.routings
    }
}
