import Foundation
import ManifieldCore

/// Pass-1 output: a set of broad research routes awaiting the user's multi-select. Mirrors
/// the PlanProposal flow — the tool hands it to the app, the user picks and edits in a native
/// sheet, and each selected route gets its own task plan in pass 2.
public struct ApproachProposal: Identifiable, Equatable, Sendable {

    public struct Approach: Equatable, Sendable, Identifiable {
        public var title: String
        /// The core mathematical idea: what would make this route work. Deliberately not a
        /// task list — pass 2 derives those, separately per branch, so one route's detailed
        /// plan cannot shape how the portfolio was designed.
        public var mechanism: String
        /// The standing prior, written in the second person — injected verbatim into
        /// every task of the branch as its research lens.
        public var prior: String
        /// What this route would establish, and why that would matter to the user's question.
        /// The planning-quality test is an expected-payoff test, not an output quota: a branch
        /// may still end honestly with nothing publishable.
        public var expectedPayoff: String
        /// True when this route's job is to attack the leading or most obvious answer. This is
        /// descriptive metadata; fresh-context coverage review judges the actual mechanisms.
        public var challengesLeadingAnswer: Bool
        /// Ontology cells this approach occupies (tactic families and/or lens archetypes).
        public var ontologyCells: [String]
        /// The observable fact that ends this branch.
        public var killCriterion: String
        public var costClass: CostClass
        /// The planner's own pick: would it run this branch? The full-auto flow activates
        /// exactly these; the selection pane pre-selects them for the user to override.
        public var activate: Bool
        /// "strong" to run the branch on the strongest configured model; nil for the default.
        public var modelTier: String?

        public var id: String { title }

        public init(title: String, mechanism: String, prior: String,
                    expectedPayoff: String = "",
                    challengesLeadingAnswer: Bool = false,
                    ontologyCells: [String] = [], killCriterion: String,
                    costClass: CostClass = .standard,
                    activate: Bool = true, modelTier: String? = nil) {
            self.title = title
            self.mechanism = mechanism
            self.prior = prior
            self.expectedPayoff = expectedPayoff
            self.challengesLeadingAnswer = challengesLeadingAnswer
            self.ontologyCells = ontologyCells
            self.killCriterion = killCriterion
            self.costClass = costClass
            self.activate = activate
            self.modelTier = modelTier
        }
    }

    public let id: UUID
    /// Short name for the whole program — the problem, not any one approach.
    public let title: String
    public let goal: String
    public let approaches: [Approach]
    /// High-value parts of the ontology the planner deliberately left out, with why —
    /// the coverage map the user needs to judge the portfolio.
    public let skippedCells: [ResearchProgram.SkippedCell]

    public init(goal: String, title: String = "",
                approaches: [Approach], skippedCells: [ResearchProgram.SkippedCell]) {
        self.id = UUID()
        self.title = title
        self.goal = goal
        self.approaches = approaches
        self.skippedCells = skippedCells
    }
}

/// The two-pass planner behind Research Programs: pass 1 designs broad routes, pass 2 turns
/// each selected one into a task plan under its own lens.
///
/// The split is the point. Pass 1 sees the whole portfolio and stays high-level — mechanism,
/// prior, payoff, kill criterion — because deciding one route's lemmas while designing the
/// others makes the others imitate the first, and the portfolio collapses to variations on a
/// theme. Pass 2 is already inside a branch and may be as specific as it likes.
public enum ProgramPlanner {

    // MARK: - Pass 1: routes

    /// Pass 1 deliberately sees the FULL research memory, beliefs included. It is the one
    /// place where knowing the project's current consensus helps — you cannot design a route
    /// that contradicts the consensus without knowing what it is.
    public static func pass1SystemPrompt(
        notation: String,
        items: [TheoryItem],
        userProfile: String,
        memory: String,
        contract: SuccessContract? = nil,
        projectOntology: String? = nil,
        pilotDigest: String? = nil,
        goal: String = ""
    ) -> String {
        var parts: [String] = []
        parts.append(PromptLibrary.text("program_planner_system"))
        parts.append(ContextAssembly.honestyRules)
        parts.append(ContextAssembly.mathematicalTaste)
        // What would actually settle the problem, before anything about how to attack it: a
        // route's payoff is only judgeable against the answer the program is trying to reach.
        let target = goal.isEmpty ? (contract?.statement ?? "") : goal
        if !target.isEmpty {
            parts.append(ContextAssembly.researchTargetSection(
                originalRequest: target, contract: contract))
        }
        parts.append(PromptLibrary.text("approach_ontology"))
        if let projectOntology,
           !projectOntology.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("Project-specific ontology additions (ontology.md — the user's own "
                + "families and lenses; prefer these where they apply):\n\(projectOntology)")
        }
        // What the independent first attempts actually reached — the portfolio should be
        // designed around observed mechanisms and obstructions, not priors alone.
        if let pilotDigest, !pilotDigest.isEmpty {
            parts.append(pilotDigest)
        }
        parts.append(ContextAssembly.memorySection(memory))
        parts.append(ContextAssembly.computeEnvironment)
        parts.append(ContextAssembly.latexRules)
        if !userProfile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("About the user (plan at their level, toward their interests): \(userProfile)")
        }
        if !notation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("Project notation registry:\n\(notation)")
        }
        parts.append("Library outline:\n\(ContextAssembly.outline(items: items))")
        return parts.joined(separator: "\n\n")
    }

    public static func pass1UserMessage(problem: String) -> String {
        """
        Design a portfolio of attacks on the following problem. Analyze the theory, then \
        call propose_approaches with exactly the broad routes whose expected information value
        justifies running them. Route count is a consequence of the problem, not a quota.

        \(ContextAssembly.researchTargetSection(originalRequest: problem, contract: nil))
        """
    }

    public static func proposeApproachesTool(
        onProposal: @escaping @Sendable (ApproachProposal) -> Void
    ) -> AgentTool {
        ProposeApproachesTool(onProposal: onProposal)
    }

    // MARK: - Pass 2: one branch plan

    /// Pass 2 is already inside a branch: it sees facts only (goal + eliminated strategies)
    /// plus its own lens, never the project's beliefs — the same isolation the branch's tasks
    /// will run under. It does see the frozen contract: a task list planned blind to what
    /// would actually answer the question is how a branch ends up proving something true and
    /// unsurprising.
    public static func pass2SystemPrompt(
        approach: ApproachProposal.Approach,
        goal: String,
        notation: String,
        items: [TheoryItem],
        userProfile: String,
        projectMemory: String,
        contract: SuccessContract? = nil
    ) -> String {
        var parts: [String] = []
        parts.append(PromptLibrary.text("branch_planner_system"))
        parts.append(ContextAssembly.honestyRules)
        parts.append(ContextAssembly.mathematicalTaste)
        parts.append(ContextAssembly.researchTargetSection(
            originalRequest: goal, contract: contract))
        parts.append(lensSection(prior: approach.prior,
                                 challengesLeadingAnswer: approach.challengesLeadingAnswer,
                                 kill: approach.killCriterion))
        var routeBlock = """
        Program goal: \(goal)

        This branch's mechanism: \(approach.mechanism)
        """
        if !approach.expectedPayoff.isEmpty {
            routeBlock += "\n\nWhat this route is expected to be worth: \(approach.expectedPayoff)"
                + "\n\nPreserve that payoff. The tasks may change as the mathematics develops, "
                + "but a task list that no longer aims at it is planning a different branch."
        }
        parts.append(routeBlock)
        if let shared = ProgramContext.sharedFactsSection(
            projectMemory: projectMemory, routedFindings: []) {
            parts.append(shared)
        }
        // Pass 2 writes the task list, so this is the pass that can plan an unrunnable method.
        parts.append(ContextAssembly.computeEnvironment)
        parts.append(ContextAssembly.latexRules)
        if !userProfile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("About the user (plan at their level, toward their interests): \(userProfile)")
        }
        if !notation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("Project notation registry:\n\(notation)")
        }
        parts.append("Library outline:\n\(ContextAssembly.outline(items: items))")
        return parts.joined(separator: "\n\n")
    }

    public static func pass2UserMessage(approach: ApproachProposal.Approach, goal: String) -> String {
        """
        Plan the branch '\(approach.title)' of the program attacking: \(goal)

        Work under the research lens above and call propose_branch_plan with the task list.
        """
    }

    public static func proposeBranchPlanTool(
        onProposal: @escaping @Sendable (PlanProposal.Option) -> Void
    ) -> AgentTool {
        ProposeBranchPlanTool(onProposal: onProposal)
    }

    public static func declineBranchTool(
        onDecline: @escaping @Sendable (String) -> Void
    ) -> AgentTool {
        DeclineBranchTool(onDecline: onDecline)
    }

    /// The rendered lens, shared by pass-2 planning and the branch's own task turns so
    /// the plan and its execution hold the same prior.
    public static func lensSection(
        prior: String, challengesLeadingAnswer: Bool, kill: String
    ) -> String {
        PromptLibrary.text("branch_lens", [
            "LENS": prior,
            "ROLE": challengesLeadingAnswer
                ? "This branch attacks the leading answer. Your job is to break it, not to "
                    + "extend it: hunt the counterexample, the obstruction, the case the "
                    + "obvious argument forgets. If it survives everything you throw at it, "
                    + "that is your result — say so plainly rather than manufacturing a doubt."
                : "This branch builds toward an answer. Commit to the mechanism above and "
                    + "push it as far as the mathematics allows. A sibling branch is trying "
                    + "to break whatever you produce; that is its job, not yours.",
            "KILL": kill.isEmpty ? "(none set — use your judgement about when the approach is dead)" : kill
        ])
    }
}

// MARK: - Synthesis

/// The program-level closing turn: the first context that sees every branch at once.
public enum ProgramSynthesis {

    /// One finished branch, flattened for the report. The app assembles these from the
    /// plan, the run record and the branch's memory file.
    public struct BranchInput: Sendable {
        public var planID: String
        public var title: String
        public var challengesLeadingAnswer: Bool
        public var approach: String
        public var kill: String?
        public var taskLines: [String]
        public var tokensUsed: Int
        public var journal: [String]
        public var memory: String

        public init(planID: String, title: String, challengesLeadingAnswer: Bool = false,
                    approach: String, kill: String? = nil, taskLines: [String] = [],
                    tokensUsed: Int = 0, journal: [String] = [], memory: String = "") {
            self.planID = planID
            self.title = title
            self.challengesLeadingAnswer = challengesLeadingAnswer
            self.approach = approach
            self.kill = kill
            self.taskLines = taskLines
            self.tokensUsed = tokensUsed
            self.journal = journal
            self.memory = memory
        }
    }

    public static func systemPrompt(
        goal: String,
        contract: SuccessContract?,
        solution: SolutionCandidate?,
        branches: [BranchInput],
        findings: [ProgramFinding],
        skippedCells: [ResearchProgram.SkippedCell]
    ) -> String {
        var parts = [PromptLibrary.text("program_synthesis")]
        parts.append(ContextAssembly.honestyRules)
        parts.append(ContextAssembly.mathematicalTaste)
        parts.append(ContextAssembly.researchTargetSection(
            originalRequest: goal, contract: contract))

        // The one thing the report must not get wrong is whether the question was answered.
        // It is a fact on the manifest, decided by two passes that are not this one.
        if let solution {
            let forms = solution.effectiveCompletionIDs
            parts.append("""
            **A solution candidate was accepted.** Item `\(solution.primaryItemID)`\
            \(solution.supportingItemIDs.isEmpty ? "" : ", supported by \(solution.supportingItemIDs.joined(separator: ", "))")\
            \(forms.isEmpty ? "" : ", satisfying \(forms.joined(separator: ", "))"). \
            It passed contract adjudication\
            \(solution.contractRuling.map { ": \($0.note)" } ?? "")\
            \(solution.reviewRuling.map { " and review: \($0.note)" } ?? ""). \
            Lead the report with the answer itself, in the problem's own terms. Report the \
            review level actually achieved — reviewed with no errors found is not the same as \
            human-approved or formally verified, and the reader needs to know which they have.
            """)
        } else {
            parts.append("""
            **No solution candidate was accepted.** The program did not answer the user's \
            question. Report what it did establish — partial results, ranges settled, routes \
            ruled out and why — as itself, in its own terms. Do not present the strongest \
            partial result as though it were the answer, and do not describe a portfolio that \
            ran out of ideas as though it had concluded something. Honest futility is a real \
            outcome and the archive is read for it.
            """)
        }

        for branch in branches {
            var section = "### Branch '\(branch.title)' (\(branch.planID))"
            if branch.challengesLeadingAnswer {
                section += " — attacked the leading answer"
            }
            if !branch.approach.isEmpty { section += "\nMechanism: \(branch.approach)" }
            if let kill = branch.kill, !kill.isEmpty { section += "\nKill criterion: \(kill)" }
            if !branch.taskLines.isEmpty {
                section += "\nTasks: " + branch.taskLines.joined(separator: "; ")
            }
            section += "\nTokens: \(branch.tokensUsed)"
            if !branch.journal.isEmpty {
                section += "\nJournal:\n" + branch.journal.map { "- \($0)" }.joined(separator: "\n")
            }
            let memory = MemoryDocument.parse(markdown: branch.memory)
            if !memory.isEmpty {
                section += "\nBranch memory:\n\(memory.promptRendering)"
            }
            parts.append(section)
        }

        if findings.isEmpty {
            parts.append("No findings were submitted during this program.")
        } else {
            parts.append("Findings submitted during the program:\n" + findings
                .map { "- [\($0.kind.rawValue)] (branch \($0.branchPlanID)) \($0.statement)" }
                .joined(separator: "\n"))
        }
        if !skippedCells.isEmpty {
            parts.append("Approaches deliberately not run:\n" + skippedCells
                .map { "- \($0.cell): \($0.why)" }
                .joined(separator: "\n"))
        }
        return parts.joined(separator: "\n\n")
    }
}

// MARK: - Tools

/// The portfolio hard gate: presenting routes to the user ends the planner's work.
struct ProposeApproachesTool: AgentTool {
    let onProposal: @Sendable (ApproachProposal) -> Void

    var spec: ToolSpec {
        let costs = CostClass.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ",")
        return ToolSpec(
            name: "propose_approaches",
            description: "Present the broad research routes worth running for a hard problem, spanning genuinely different mechanisms. Choose the count by expected information value, not a quota. Call this ONCE, after your analysis is complete. Describe routes, NOT task lists: no lemmas to prove, no ordered steps, no decision about the detailed argument — those are derived per branch in a second pass, and deciding them here makes every later route imitate the first. After calling this, STOP.",
            inputSchemaJSON: """
            {"type":"object","properties":{\
            "goal":{"type":"string","description":"One-line statement of the problem being attacked"},\
            "title":{"type":"string","description":"Short name for the program, 3-7 words, naming the PROBLEM rather than any route to it (e.g. 'Constrained supremum of a cubic functional'). It labels the whole portfolio, so it must not describe one approach — the branches carry those names."},\
            "approaches":{"type":"array","items":{"type":"object","properties":{\
            "title":{"type":"string","description":"Short route name"},\
            "mechanism":{"type":"string","description":"The core mathematical idea and why it could work, 2-4 sentences. The mechanism, not a restatement of the goal and not a plan of steps."},\
            "prior":{"type":"string","description":"The research lens: one paragraph, second person, written as a standing prior the branch works under"},\
            "expected_payoff":{"type":"string","description":"What this route would establish if it works, and why that would matter to the user's question — a complete answer, or a precise result that would materially improve the next research decision. This is an expected-value judgement, not a promise: a branch may still end honestly with nothing publishable."},\
            "challenges_leading_answer":{"type":"boolean","description":"True when this route's job is explicitly to attack the leading or most obvious answer rather than build toward it. This label is descriptive; an independent auditor judges whether the activated portfolio has a credible falsification path."},\
            "ontology_cells":{"type":"array","minItems":1,"items":{"type":"string"},"description":"Tactic families and/or lens archetypes this route occupies"},\
            "kill_criterion":{"type":"string","description":"The observable fact that would end this branch. A fact someone could check, not a feeling."},\
            "cost_class":{"type":"string","enum":[\(costs)],"description":"Rough execution cost, for the user's budget read"},\
            "activate":{"type":"boolean","description":"Your own pick: is this branch worth running now? Activate every and only route with positive expected information value. List approaches in attack order; on a fully automatic run the activated ones run in exactly that order with no further selection."},\
            "model_tier":{"type":"string","enum":["strong","default"],"description":"'strong' runs this branch on the strongest configured model — for branches whose decisive work is deep novel reasoning (a hard proof, a subtle construction), not for computation or literature work"}\
            },"required":["title","mechanism","prior","expected_payoff","challenges_leading_answer","ontology_cells","kill_criterion","cost_class"]}},\
            "skipped_cells":{"type":"array","items":{"type":"object","properties":{\
            "cell":{"type":"string"},"why":{"type":"string"}},"required":["cell","why"]},\
            "description":"High-value ontology cells you deliberately did NOT propose, each with why. Required (may be an empty array only if you genuinely covered everything)."}\
            },"required":["goal","approaches","skipped_cells"]}
            """
        )
    }

    func execute(inputJSON: String) async throws -> String {
        let input = jsonObject(inputJSON)
        guard let goal = input["goal"] as? String, !goal.isEmpty else {
            throw PlannerError(message: "missing 'goal'")
        }
        guard let title = (input["title"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            throw PlannerError(message: """
            missing 'title' — give the program a short name for the problem itself. The \
            goal statement is a directive sentence; used as a label it reads like one \
            branch's task rather than the portfolio's subject.
            """)
        }
        guard let rawApproaches = input["approaches"] as? [[String: Any]],
              !rawApproaches.isEmpty else {
            throw PlannerError(message: "provide at least one route with positive expected information value")
        }
        guard let rawSkipped = input["skipped_cells"] as? [Any] else {
            throw PlannerError(message: """
            missing 'skipped_cells' — list the high-value ontology cells you did not \
            propose, each with why (use an empty array only if you truly covered everything)
            """)
        }

        var approaches: [ApproachProposal.Approach] = []
        for (offset, raw) in rawApproaches.enumerated() {
            let position = offset + 1
            guard let title = raw["title"] as? String, !title.isEmpty else {
                throw PlannerError(message: "route \(position): missing 'title'")
            }
            guard let mechanism = raw["mechanism"] as? String, !mechanism.isEmpty else {
                throw PlannerError(message: """
                route \(position) ('\(title)'): missing 'mechanism' — name the mathematical \
                idea that would make this route work
                """)
            }
            guard let prior = raw["prior"] as? String, !prior.isEmpty else {
                throw PlannerError(message: """
                route \(position) ('\(title)'): missing 'prior' — every branch needs a \
                standing prior; without one it just reproduces the default approach
                """)
            }
            guard let payoff = raw["expected_payoff"] as? String, !payoff.isEmpty else {
                throw PlannerError(message: """
                route \(position) ('\(title)'): missing 'expected_payoff' — say what this \
                route would establish and why that would matter to the user's question. A \
                route with no statable payoff is a route nobody can decide to run.
                """)
            }
            guard let kill = raw["kill_criterion"] as? String, !kill.isEmpty else {
                throw PlannerError(message: """
                route \(position) ('\(title)'): missing 'kill_criterion' — state the \
                observable fact that would end this branch
                """)
            }
            let cells = (raw["ontology_cells"] as? [Any] ?? []).compactMap { $0 as? String }
            guard !cells.isEmpty else {
                throw PlannerError(message: """
                route \(position) ('\(title)'): 'ontology_cells' must name at least one \
                cell, so the portfolio's coverage is legible
                """)
            }
            let cost = (raw["cost_class"] as? String).flatMap { CostClass(rawValue: $0) }
            guard let cost else {
                throw PlannerError(message: "route \(position) ('\(title)'): 'cost_class' must be "
                    + CostClass.allCases.map(\.rawValue).joined(separator: ", "))
            }
            approaches.append(ApproachProposal.Approach(
                title: title, mechanism: mechanism, prior: prior, expectedPayoff: payoff,
                challengesLeadingAnswer: raw["challenges_leading_answer"] as? Bool ?? false,
                ontologyCells: cells, killCriterion: kill, costClass: cost,
                activate: raw["activate"] as? Bool ?? true,
                modelTier: (raw["model_tier"] as? String).flatMap { $0 == "strong" ? $0 : nil }))
        }

        let skipped = rawSkipped.compactMap { entry -> ResearchProgram.SkippedCell? in
            guard let dict = entry as? [String: Any],
                  let cell = dict["cell"] as? String, !cell.isEmpty,
                  let why = dict["why"] as? String, !why.isEmpty else { return nil }
            return ResearchProgram.SkippedCell(cell: cell, why: why)
        }

        onProposal(ApproachProposal(goal: goal, title: title,
                                    approaches: approaches, skippedCells: skipped))
        return """
        Presented \(approaches.count) routes to the user. STOP now — do not analyze \
        further and do not write task lists. The user selects which routes to run; \
        each selected one is planned in a separate pass.
        """
    }
}

/// Pass-2 gate: one branch's task list.
struct ProposeBranchPlanTool: AgentTool {
    let onProposal: @Sendable (PlanProposal.Option) -> Void

    var spec: ToolSpec {
        ToolSpec(
            name: "propose_branch_plan",
            description: "Deliver the task list for THIS branch. Call once, after your analysis; order tasks so the kill criterion is tested as early and cheaply as possible. After calling this, STOP.",
            inputSchemaJSON: """
            {"type":"object","properties":{\
            "summary":{"type":"string","description":"How this task list executes the branch's thesis, 2-4 sentences"},\
            "tasks":{"type":"array","minItems":1,"maxItems":12,"items":{"type":"object","properties":{\
            "title":{"type":"string"},\
            "kind":{"type":"string","description":"'research' or 'prove: <item-id>' for proving one specific item"},\
            "depends_on":{"type":"array","items":{"type":"integer"},"description":"1-based indices of EARLIER tasks that must complete first"},\
            "review":{"type":"boolean","description":"true if the result should pass the reviewer before counting as done"}\
            },"required":["title","kind"]}}\
            },"required":["summary","tasks"]}
            """
        )
    }

    func execute(inputJSON: String) async throws -> String {
        let input = jsonObject(inputJSON)
        guard let summary = input["summary"] as? String, !summary.isEmpty else {
            throw PlannerError(message: "missing 'summary'")
        }
        guard let rawTasks = input["tasks"] as? [[String: Any]], !rawTasks.isEmpty else {
            throw PlannerError(message: "a runnable branch needs at least one concrete task")
        }
        let tasks = try PlannerValidation.parseTasks(rawTasks, context: "")

        onProposal(PlanProposal.Option(
            title: "", summary: summary, pros: "", cons: "", tasks: tasks))
        return """
        Branch plan delivered. STOP now — do not begin executing it. The user reviews the \
        whole program before anything runs.
        """
    }
}

/// A route can become obsolete between portfolio design and pass 2, once its planner reads the
/// actual theory and sources. Refusing it is cheaper and more honest than manufacturing tasks.
struct DeclineBranchTool: AgentTool {
    let onDecline: @Sendable (String) -> Void

    var spec: ToolSpec {
        ToolSpec(
            name: "decline_branch",
            description: "Decline this route only when concrete evidence shows that it is already resolved, duplicates an existing mechanism, or cannot pursue its stated payoff under the authoritative target. Difficulty, budget, or preference for an easier route are not valid reasons. Call instead of propose_branch_plan, then stop.",
            inputSchemaJSON: #"{"type":"object","properties":{"reason":{"type":"string","description":"Concrete evidence that makes this route unnecessary or invalid; name the item, finding, or target mismatch"}},"required":["reason"]}"#)
    }

    func execute(inputJSON: String) async throws -> String {
        let reason = (jsonObject(inputJSON)["reason"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !reason.isEmpty else {
            throw PlannerError(message: "declining a branch requires a concrete reason")
        }
        onDecline(String(reason.prefix(1500)))
        return "Branch declined with a recorded reason. STOP now."
    }
}
