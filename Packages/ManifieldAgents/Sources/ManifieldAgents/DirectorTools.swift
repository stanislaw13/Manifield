import Foundation
import ManifieldCore

/// Collects the director's decision across its two tool calls.
final class DirectorSignals: @unchecked Sendable {
    private let lock = NSLock()
    private var _verdict: Director.Decision.Verdict?
    private var _rationale = ""
    private var _status = ""
    private var _routes: [ResearchRoute] = []
    private var _workerAssignments: [WorkerAssignment] = []
    private var _challengeGovernance: ProblemChallenge.Governance?

    var decision: Director.Decision? {
        lock.lock(); defer { lock.unlock() }
        guard let _verdict else { return nil }
        return Director.Decision(verdict: _verdict, rationale: _rationale,
                                 status: _status, routes: _routes,
                                 workerAssignments: _workerAssignments,
                                 challengeGovernance: _challengeGovernance)
    }

    func setVerdict(_ verdict: Director.Decision.Verdict, rationale: String, status: String) {
        lock.lock(); _verdict = verdict; _rationale = rationale; _status = status; lock.unlock()
    }
    func setRoutes(_ routes: [ResearchRoute]) {
        lock.lock(); _routes = routes; lock.unlock()
    }
    /// Appends rather than replaces: unlike `propose_routes` (one call, the whole slate),
    /// `dispatch_worker` is meant to be called once per assignment, in whatever order the
    /// director wants them attacked.
    func addWorkerAssignment(_ assignment: WorkerAssignment) {
        lock.lock(); _workerAssignments.append(assignment); lock.unlock()
    }
    func setChallengeGovernance(_ governance: ProblemChallenge.Governance) {
        lock.lock(); _challengeGovernance = governance; lock.unlock()
    }
}

enum DirectorTools {

    static func tools(
        signals: DirectorSignals,
        existingRoutes: [ResearchRoute],
        generation: Int,
        canSettle: Bool,
        activeTargetRevisionID: String,
        defaultWorkerTokenBudget: Int = 300_000,
        challenge: ProblemChallenge? = nil,
        branchIDs: [String] = []
    ) -> [AgentTool] {
        var tools: [AgentTool] = [
            SetProgramVerdictTool(signals: signals, canSettle: canSettle),
            ProposeRoutesTool(signals: signals, existingRoutes: existingRoutes,
                              generation: generation),
            DispatchWorkerTool(signals: signals,
                               activeTargetRevisionID: activeTargetRevisionID,
                               defaultTokenBudget: defaultWorkerTokenBudget)
        ]
        if let challenge {
            tools.append(GovernProblemChallengeTool(
                signals: signals, challenge: challenge, branchIDs: branchIDs))
        }
        return tools
    }

    /// The routing turn's only tool. A separate turn from the verdict on purpose: routing
    /// happens while branches are running and a verdict happens when they have stopped, and
    /// giving the routing turn a verdict tool would invite it to rule on a generation it has
    /// only half seen.
    static func routingTools(signals: RoutingSignals,
                             findingIDs: [String],
                             branchIDs: [String]) -> [AgentTool] {
        [RouteFindingsTool(signals: signals, findingIDs: findingIDs, branchIDs: branchIDs)]
    }
}

struct GovernProblemChallengeTool: AgentTool {
    let signals: DirectorSignals
    let challenge: ProblemChallenge
    let branchIDs: [String]

    var spec: ToolSpec {
        let ids = branchIDs.map { "\"\($0)\"" }.joined(separator: ",")
        return ToolSpec(
            name: "govern_problem_challenge",
            description: """
            Govern the accepted challenge `\(challenge.id)`. This is not another review. Decide
            whether the accepted defect requires a new immutable target revision, and classify
            the effect on actual branches: stop work made invalid, replan work whose objective
            changed, and preserve unaffected work that remains relevant. An accepted challenge
            may invalidate only one part of a composite request. `replacement_request` must be
            the minimal correction supported by the accepted rulings, never a more convenient
            research problem. Apply a revision only when the challenge also pinned a separate
            corrected library goal item; `replacement_request` must exactly equal that item's
            `## Statement`. Otherwise govern the established defect without silently
            inventing its repair. Set `open_new_portfolio` when unresolved work needs routes under
            the governed target; then choose the program verdict `continue` and propose them.
            If the target stays unchanged and named unaffected branches can simply resume, put
            them in `continue_branch_plan_ids`, leave `open_new_portfolio` false, and do not
            manufacture duplicate routes.
            """,
            inputSchemaJSON: """
            {"type":"object","properties":{
              "apply_revision":{"type":"boolean","description":"Adopt a new immutable target revision"},
              "replacement_request":{"type":"string","description":"The minimal corrected request; required when applying a revision"},
              "stop_branch_plan_ids":{"type":"array","items":{"type":"string","enum":[\(ids)]}},
              "replan_branch_plan_ids":{"type":"array","items":{"type":"string","enum":[\(ids)]}},
              "continue_branch_plan_ids":{"type":"array","items":{"type":"string","enum":[\(ids)]}},
              "open_new_portfolio":{"type":"boolean"},
              "rationale":{"type":"string","description":"Why each disposition follows from the accepted defect and which user-requested parts remain unresolved"}
            },"required":["apply_revision","stop_branch_plan_ids","replan_branch_plan_ids","continue_branch_plan_ids","open_new_portfolio","rationale"]}
            """)
    }

    func execute(inputJSON: String) async throws -> String {
        let input = jsonObject(inputJSON)
        guard let applyRevision = input["apply_revision"] as? Bool,
              let openNewPortfolio = input["open_new_portfolio"] as? Bool else {
            throw ResearchError(message: "missing apply_revision or open_new_portfolio")
        }
        let replacement = (input["replacement_request"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if applyRevision && replacement?.isEmpty != false {
            throw ResearchError(message: "applying a revision requires its complete minimal replacement_request")
        }
        if applyRevision && (challenge.proposedTargetItemID == nil
                             || challenge.proposedTargetItemData == nil) {
            throw ResearchError(message: "applying a revision requires the challenge to cite a separate corrected library target whose raw bytes were pinned at filing; govern without revision if the repair is not established")
        }
        if applyRevision, let data = challenge.proposedTargetItemData,
           let markdown = String(data: data, encoding: .utf8),
           let item = try? TheoryItem.parse(markdown: markdown) {
            guard let statement = item.statement?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  statement == replacement else {
                throw ResearchError(message: "replacement_request must exactly match the proposed goal item's ## Statement")
            }
        }
        guard let rationale = (input["rationale"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !rationale.isEmpty else {
            throw ResearchError(message: "missing rationale")
        }

        let valid = Set(branchIDs)
        func ids(_ key: String) -> [String] {
            (input[key] as? [Any] ?? []).compactMap { $0 as? String }
                .filter { valid.contains($0) }
        }
        let stopped = ids("stop_branch_plan_ids")
        let replanned = ids("replan_branch_plan_ids")
        let continued = ids("continue_branch_plan_ids")
        if applyRevision && !continued.isEmpty {
            throw ResearchError(message: "a branch cannot continue unchanged across a new target revision; put still-relevant work in replan_branch_plan_ids and carry its mechanism into the new routes")
        }
        let overlaps = Set(stopped).intersection(replanned)
            .union(Set(stopped).intersection(continued))
            .union(Set(replanned).intersection(continued))
        guard overlaps.isEmpty else {
            throw ResearchError(message: "a branch cannot be stopped, replanned and continued at once: \(overlaps.sorted().joined(separator: ", "))")
        }
        if !replanned.isEmpty && !openNewPortfolio {
            throw ResearchError(message: "replanned branches require open_new_portfolio so their corrected work returns as governed routes")
        }

        signals.setChallengeGovernance(.init(
            applyRevision: applyRevision,
            replacementRequest: applyRevision ? replacement : nil,
            stopBranchPlanIDs: stopped,
            replanBranchPlanIDs: replanned,
            continueBranchPlanIDs: continued,
            openNewPortfolio: openNewPortfolio,
            rationale: String(rationale.prefix(2_000))))
        return "Challenge governance recorded. Now set the program verdict and, if continuing, propose the unresolved routes."
    }
}

struct SetProgramVerdictTool: AgentTool {
    let signals: DirectorSignals
    /// False until a solution candidate has passed both contract adjudication and review.
    /// `settled` is then not in the schema at all — a verdict the evidence cannot support
    /// should not be a choice the model can make and then justify.
    let canSettle: Bool

    var spec: ToolSpec {
        var cases = canSettle ? [#""settled""#] : []
        cases.append(#""futile""#)
        cases.append(#""continue""#)
        let verdicts = cases.joined(separator: ",")
        return ToolSpec(
            name: "set_program_verdict",
            description: """
            Record the program's verdict and the status line for the mathematician. \
            \(canSettle
                ? "'settled' is available because a solution candidate passed contract adjudication and review. Take it only if what was accepted answers the whole question."
                : "'settled' is NOT available: no solution candidate has passed both independent checks, so nothing has been established to have answered the question. A branch believing it is close is not evidence.") \
            'futile' is a real result: say what would have to change for the problem to become \
            tractable — proposing more work by reflex is not a substitute for actually judging \
            whether it would pay for itself. \
            'continue' requires a specific named gap and what would close it: propose_routes \
            for a genuinely broad portfolio, dispatch_worker for one small, decisive question.
            """,
            inputSchemaJSON: """
            {"type":"object","properties":{"verdict":{"type":"string","enum":[\(verdicts)]},\
            "rationale":{"type":"string","description":"Why this verdict, citing the evidence"},\
            "status":{"type":"string","description":"2-3 sentences for the research page: where the program stands, what was ruled out, what happens next"}},\
            "required":["verdict","rationale","status"]}
            """
        )
    }

    func execute(inputJSON: String) async throws -> String {
        let input = jsonObject(inputJSON)
        guard let raw = input["verdict"] as? String,
              let verdict = Director.Decision.Verdict(rawValue: raw) else {
            throw ResearchError(message: "verdict must be settled, futile or continue")
        }
        guard canSettle || verdict != .settled else {
            throw ResearchError(message: """
            REJECTED — 'settled' requires a solution candidate that passed BOTH contract \
            adjudication and review, and this program has none. Whatever the branches \
            reported, nothing has been independently established to answer the user's \
            question. Choose 'futile' if the problem is out of reach, or 'continue' with the \
            routes that would close the gap.
            """)
        }
        guard let rationale = input["rationale"] as? String, !rationale.isEmpty else {
            throw ResearchError(message: "missing 'rationale'")
        }
        guard let status = input["status"] as? String, !status.isEmpty else {
            throw ResearchError(message: "missing 'status' — the research page needs it")
        }
        signals.setVerdict(verdict, rationale: String(rationale.prefix(1500)),
                           status: String(status.prefix(800)))
        return verdict == .continue
            ? "Verdict recorded. Now call propose_routes with the next generation."
            : "Verdict recorded. End your turn."
    }
}

struct ProposeRoutesTool: AgentTool {
    let signals: DirectorSignals
    let existingRoutes: [ResearchRoute]
    let generation: Int

    var spec: ToolSpec {
        ToolSpec(
            name: "propose_routes",
            description: """
            Propose exactly the genuinely different mechanisms worth buying for the next \
            generation. Choose the count by expected information value, not a quota. Each \
            needs the mathematical idea (not a restatement of the goal), any extra assumptions \
            it introduces, and a decisive next test — the one cheap action that would advance \
            or kill it. Do not list the conclusion or presupposition this route must establish \
            as one of its assumptions; make the decisive test resolve that uncertainty. A \
            mechanism already in the registry is refused, including one that has \
            been falsified: the program does not re-run what it has already ruled out. \
            List routes in the order they should be attacked — the first listed runs first. \
            Name in 'descends_from' the ids of the routes this one comes out of — the \
            obstruction it is designed to get around, the partial result it builds on — or \
            leave it empty for a genuinely fresh start. \
            Set model_tier 'strong' on a route whose decisive work needs deep novel reasoning \
            (a hard proof, a subtle construction); leave it default for routes that are mostly \
            computation, enumeration, or literature work.
            """,
            inputSchemaJSON: #"{"type":"object","properties":{"routes":{"type":"array","items":{"type":"object","properties":{"mechanism":{"type":"string","description":"The core mathematical idea"},"assumptions":{"type":"array","items":{"type":"string"}},"next_test":{"type":"string","description":"The decisive cheap action that would advance or kill this"},"descends_from":{"type":"array","items":{"type":"string"},"description":"Ids of existing routes this one comes out of; empty for a fresh start"},"model_tier":{"type":"string","enum":["strong","default"],"description":"'strong' runs this branch on the strongest configured model — for decisive novel reasoning, not routine labour"}},"required":["mechanism","next_test"]}}},"required":["routes"]}"#
        )
    }

    func execute(inputJSON: String) async throws -> String {
        let raw = jsonObject(inputJSON)["routes"] as? [[String: Any]] ?? []
        guard !raw.isEmpty else {
            throw ResearchError(message: "continuing requires at least one concrete new route")
        }

        var routes: [ResearchRoute] = []
        for entry in raw {
            guard let mechanism = (entry["mechanism"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !mechanism.isEmpty else {
                throw ResearchError(message: "every route needs a 'mechanism'")
            }
            guard let nextTest = (entry["next_test"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !nextTest.isEmpty else {
                throw ResearchError(message: """
                route '\(mechanism)': missing 'next_test'. A route whose decisive test you \
                cannot state is not ready to be a route.
                """)
            }
            // The code-level half of the anti-repetition guard. Prompt wording alone does not
            // hold: the model is being asked to be original at the moment it is out of ideas.
            if let clash = existingRoutes.first(where: { Self.isSameMechanism($0.mechanism, mechanism) }) {
                throw ResearchError(message: """
                REJECTED — '\(mechanism)' is the mechanism of an existing route \
                (\(clash.status.rawValue)\(clash.obstruction.map { ", died on: \($0)" } ?? "")). \
                The program does not re-run a route it has already ruled out. Propose a \
                different mechanism, or say explicitly in the mechanism what is different \
                this time and why that changes the outcome.
                """)
            }
            if let clash = routes.first(where: { Self.isSameMechanism($0.mechanism, mechanism) }) {
                throw ResearchError(message: """
                REJECTED — two of your proposed routes share a mechanism ('\(clash.mechanism)' \
                and '\(mechanism)'). Routes that would fail for the same reason are one route.
                """)
            }
            let tier = (entry["model_tier"] as? String).flatMap { $0 == "strong" ? $0 : nil }
            // Unknown ids are dropped rather than refused: a wrong parent is a cosmetic gap in
            // the lineage, and rejecting the whole proposal over one would cost a generation.
            let known = Set(existingRoutes.map(\.id))
            let parents = (entry["descends_from"] as? [Any] ?? [])
                .compactMap { $0 as? String }
                .filter { known.contains($0) }
            routes.append(ResearchRoute(
                mechanism: mechanism,
                assumptions: (entry["assumptions"] as? [Any] ?? []).compactMap { $0 as? String },
                status: .proposed,
                nextTest: nextTest,
                parentRouteIDs: parents,
                generation: generation,
                modelTier: tier))
        }
        signals.setRoutes(routes)
        return "Recorded \(routes.count) route(s) for generation \(generation). End your turn."
    }
}

extension ProposeRoutesTool {
    /// Cheap mechanism identity: normalised text, then a token-overlap test. Deliberately
    /// generous — a false clash costs one re-proposal with an explanation attached, while a
    /// missed one costs a whole generation re-running a dead route.
    static func isSameMechanism(_ lhs: String, _ rhs: String) -> Bool {
        let a = tokens(lhs), b = tokens(rhs)
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a == b { return true }
        let overlap = a.intersection(b).count
        return Double(overlap) / Double(Swift.min(a.count, b.count)) >= 0.75
    }

    private static func tokens(_ text: String) -> Set<String> {
        let stop: Set<String> = ["the", "a", "an", "of", "for", "to", "and", "or", "in", "on",
                                 "with", "by", "via", "using", "use", "that", "this", "is",
                                 "as", "at", "from", "into", "over", "under", "its", "it"]
        return Set(text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 && !stop.contains($0) })
    }
}

/// Dispatches one freeform assignment directly — the whole of what used to require a route,
/// a pass-2 planner turn, and (for a "pilot") a whole separate selection stage. Call it once
/// per assignment; unlike `propose_routes`, which takes a slate, this is meant to be called
/// repeatedly in the order the director wants each one attacked.
struct DispatchWorkerTool: AgentTool {
    let signals: DirectorSignals
    let activeTargetRevisionID: String
    let defaultTokenBudget: Int

    var spec: ToolSpec {
        ToolSpec(
            name: "dispatch_worker",
            description: """
            Dispatch one branch with a freeform objective, no fixed role. Use this instead of \
            propose_routes when a single small, decisive question is worth answering before \
            committing to a broader portfolio — what a "pilot" used to mean — or whenever the \
            work genuinely does not need a mechanism-shaped route around it. The branch plans \
            its own tasks from your objective; you are not asked for a task list. Give it a \
            tight token_budget and a stop_condition that names the observable fact that ends \
            it — a decisive stop is what makes a small dispatch different from an open-ended \
            one, not a role label. Call this once per assignment, as many times as you want \
            independent branches; concurrency is a ceiling from the program's settings, not a \
            quota you need to fill.
            """,
            inputSchemaJSON: """
            {"type":"object","properties":{
              "objective":{"type":"string","description":"What this branch should establish — freeform, not a route mechanism"},
              "constraints":{"type":"array","items":{"type":"string"},"description":"Extra hypotheses or restrictions this dispatch introduces beyond the fixed goal Statement"},
              "stop_condition":{"type":"string","description":"The observable fact that ends this assignment — required for anything meant to be small and decisive"},
              "relevant_item_ids":{"type":"array","items":{"type":"string"},"description":"Theory items you already know are relevant; the branch still searches on its own"},
              "token_budget":{"type":"integer","description":"Defaults to a modest budget if omitted; set it explicitly for a small, decisive dispatch"},
              "model_tier":{"type":"string","enum":["strong","default"],"description":"'strong' runs this branch on the strongest configured model — for decisive novel reasoning, not routine labour"},
              "priority":{"type":"integer","description":"Lower runs first, relative to other branches and dispatches in this generation"}
            },"required":["objective","stop_condition"]}
            """
        )
    }

    func execute(inputJSON: String) async throws -> String {
        let entry = jsonObject(inputJSON)
        guard let objective = (entry["objective"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !objective.isEmpty else {
            throw ResearchError(message: "dispatch_worker needs an 'objective'")
        }
        guard let stopCondition = (entry["stop_condition"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !stopCondition.isEmpty else {
            throw ResearchError(message: """
            dispatch_worker needs a 'stop_condition' — the observable fact that ends this \
            assignment. A dispatch whose stop you cannot state is not ready to be dispatched.
            """)
        }
        let constraints = (entry["constraints"] as? [Any] ?? []).compactMap { $0 as? String }
        // Not filtered against the live library: a wrong id just fails to resolve when the
        // branch looks it up, same as any other item the director might misremember. The
        // branch searches on its own regardless — see the tool description.
        let items = (entry["relevant_item_ids"] as? [Any] ?? []).compactMap { $0 as? String }
        let budget = (entry["token_budget"] as? Int).map { max(1, $0) } ?? defaultTokenBudget
        let tier = (entry["model_tier"] as? String).flatMap { $0 == "strong" ? $0 : nil }
        let priority = entry["priority"] as? Int

        signals.addWorkerAssignment(WorkerAssignment(
            objective: objective,
            constraints: constraints,
            targetRevisionID: activeTargetRevisionID,
            relevantItemIDs: items,
            tokenBudget: budget,
            modelTier: tier,
            priority: priority,
            stopCondition: stopCondition))
        return "Dispatched: \(objective.prefix(140)). End your turn when you have dispatched everything you intend to."
    }
}

// MARK: - Routing

/// Collects the routing turn's decisions.
final class RoutingSignals: @unchecked Sendable {
    private let lock = NSLock()
    private var _routings: [FindingRouting] = []
    var routings: [FindingRouting] { lock.lock(); defer { lock.unlock() }; return _routings }
    func set(_ routings: [FindingRouting]) { lock.lock(); _routings = routings; lock.unlock() }
}

struct RouteFindingsTool: AgentTool {
    let signals: RoutingSignals
    let findingIDs: [String]
    let branchIDs: [String]

    var spec: ToolSpec {
        let findings = findingIDs.map { "\"\($0)\"" }.joined(separator: ",")
        let branches = branchIDs.map { "\"\($0)\"" }.joined(separator: ",")
        let decisions = FindingRouting.Decision.allCases
            .map { "\"\($0.rawValue)\"" }.joined(separator: ",")
        return ToolSpec(
            name: "route_findings",
            description: """
            Decide who receives each submitted finding. Every finding listed must get exactly \
            one decision, and a finding you do not route reaches nobody. Sending is not the \
            safe default: a finding injected into a branch whose route it does not bear on \
            pulls that branch toward someone else's approach, which is how a portfolio of \
            deliberately different attacks collapses into one.
            """,
            inputSchemaJSON: """
            {"type":"object","properties":{\
            "routings":{"type":"array","items":{"type":"object","properties":{\
            "finding_id":{"type":"string","enum":[\(findings)]},\
            "decision":{"type":"string","enum":[\(decisions)],\
            "description":"send_now = a named branch should act on this at its next task; hold = real but immature or independence-sensitive, decide again later; do_not_send = branch-local or distracting, stays searchable but is never injected; global = every branch must have it (a statement correction, a fatal shared obstruction, a settled target)"},\
            "recipients":{"type":"array","items":{"type":"string"\(branchIDs.isEmpty ? "" : ",\"enum\":[\(branches)]")},\
            "description":"For send_now: the branches that need it. Ignored otherwise — global reaches everyone but the originator."},\
            "rationale":{"type":"string","description":"Why, in one sentence: which assumption it invalidates, which dependency it satisfies, what duplication it prevents — or why sending it would collapse a branch's independence"}\
            },"required":["finding_id","decision","rationale"]}}\
            },"required":["routings"]}
            """
        )
    }

    func execute(inputJSON: String) async throws -> String {
        let input = jsonObject(inputJSON)
        let raw = input["routings"] as? [[String: Any]] ?? []
        guard !raw.isEmpty else {
            throw ResearchError(message: "'routings' must decide each of the listed findings")
        }

        let known = Set(findingIDs)
        var seen = Set<String>()
        var routings: [FindingRouting] = []
        for entry in raw {
            guard let findingID = entry["finding_id"] as? String, known.contains(findingID) else {
                throw ResearchError(message: """
                unknown finding id '\(entry["finding_id"] as? String ?? "")' — route only the \
                findings listed: \(findingIDs.joined(separator: ", "))
                """)
            }
            guard let decisionRaw = entry["decision"] as? String,
                  let decision = FindingRouting.Decision(rawValue: decisionRaw) else {
                throw ResearchError(message: """
                finding '\(findingID)': 'decision' must be one of \
                \(FindingRouting.Decision.allCases.map(\.rawValue).joined(separator: ", "))
                """)
            }
            guard let rationale = (entry["rationale"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !rationale.isEmpty else {
                throw ResearchError(message: """
                finding '\(findingID)': missing 'rationale'. Withholding needs a reason as \
                much as sending does — this is the record of why a branch did or did not know.
                """)
            }
            let recipients = (entry["recipients"] as? [Any] ?? []).compactMap { $0 as? String }
                .filter { branchIDs.contains($0) }
            // send_now with nobody to send to is a hold that reads as a send. Naming it
            // correctly is what keeps the routing history worth reading later.
            guard decision != .sendNow || !recipients.isEmpty else {
                throw ResearchError(message: """
                finding '\(findingID)': 'send_now' needs at least one recipient from \
                \(branchIDs.joined(separator: ", ")). If no branch should act on it now, use \
                'hold' or 'do_not_send' and say why.
                """)
            }
            seen.insert(findingID)
            routings.append(FindingRouting(
                findingID: findingID, decision: decision,
                recipientPlanIDs: decision == .sendNow ? recipients : [],
                rationale: String(rationale.prefix(600))))
        }

        let missing = findingIDs.filter { !seen.contains($0) }
        guard missing.isEmpty else {
            throw ResearchError(message: """
            REJECTED — these findings were left undecided: \(missing.joined(separator: ", ")). \
            An unrouted finding reaches nobody, so silence here is a decision made by accident. \
            Route every one, using 'do_not_send' where that is the right answer.
            """)
        }

        signals.set(routings)
        let sent = routings.filter { $0.decision.circulates }.count
        return "Routed \(routings.count) finding(s); \(sent) will reach a branch. End your turn."
    }
}
