import Foundation
import ManifieldCore
import ManifieldAgents
import ManifieldSandbox

extension AppState {
    func persistentRunner(program: ResearchProgram, assignment: ResearchAssignment? = nil,
                          task: AgentTask, stage: String) throws -> AgentRunner {
        guard let store else { throw CoreError.io("No project open") }
        let binding = try assignment.map { try ProgramAccountingBinding(program: program,
            subjectID: $0.id, ledger: store.loadUsageLedger(programID: program.id)) }
        return ProgramBudgetedRunner(base: try researchRunnerOverride?(task) ?? makeRunner(config: try providerConfig(for: task, program: program)),
            programID: program.id, stage: stage, subjectID: assignment?.id,
            workClass: task == .researcher || task == .prover ? .research : .control,
            assignmentBudget: binding?.assignmentBudget, requiresAccounting: true)
    }

    func makePersistentSolutionFiler(assignment: ResearchAssignment,
                                     scheduler: PersistentResearchScheduler) -> DirectResearchWorkbench.FileSolution {
        { [weak self] primary, supporting, completionIDs, argument in
            let candidate = try await MainActor.run {
                guard let store = self?.store, store.item(id: primary) != nil else { throw CoreError.io("The claimed result does not exist.") }
                var candidate = SolutionCandidate(branchPlanID: assignment.id,
                    targetRevisionID: assignment.targetRevisionID, primaryItemID: primary,
                    supportingItemIDs: supporting, claimedCompletionIDs: completionIDs, argument: argument)
                let items = Dictionary(store.items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                candidate.itemSnapshots = Dictionary(SolutionReviewGate.closure(of: candidate, items: items)
                    .map { ($0.id, SolutionReviewGate.contentHash($0)) }, uniquingKeysWith: { a, _ in a })
                return candidate
            }
            try await scheduler.file(candidate)
            return candidate.id
        }
    }

    func makePersistentChallengeFiler(assignment: ResearchAssignment,
                                      scheduler: PersistentResearchScheduler) -> DirectResearchWorkbench.FileChallenge {
        { [weak self] description, replacement, targetID, evidenceIDs in
            let challenge = try await MainActor.run {
                guard let store = self?.store else { throw CoreError.io("No project open") }
                var evidence: [String: Data] = [:]
                for id in evidenceIDs { evidence[id] = try store.rawTheoryItemData(id: id) }
                let target = targetID.flatMap { store.item(id: $0) }
                if let targetID {
                    guard target != nil, !(target?.statement ?? "").isEmpty else { throw CoreError.io("Corrected goal \(targetID) needs a complete Statement.") }
                    guard store.program(id: assignment.programID)?.targetRevisions.first(where: { $0.id == assignment.targetRevisionID })?.libraryItemID != targetID else {
                        throw CoreError.io("The corrected target must be a separate item.")
                    }
                }
                return ProblemChallenge(branchPlanID: assignment.id, targetRevisionID: assignment.targetRevisionID,
                    description: description, proposedReplacementRequest: replacement,
                    proposedTargetItemID: targetID, proposedTargetItemType: target?.type,
                    proposedTargetItemData: try targetID.map { try store.rawTheoryItemData(id: $0) },
                    evidenceItemIDs: evidenceIDs, evidenceItemData: evidence,
                    evidenceItemSnapshots: evidence.mapValues(ResearchTargetRevision.sha256))
            }
            try await scheduler.file(challenge)
            return challenge.id
        }
    }

    func executePersistentAssignment(_ assignment: ResearchAssignment, program: ResearchProgram,
                                     scheduler: PersistentResearchScheduler,
                                     onEvent: @escaping @Sendable (ResearchWorkbench.Event) -> Void) async throws -> AssignmentReport {
        guard let store else { throw CoreError.io("No project open") }
        // A previous interruption may have happened after filing but before review completed.
        // Retry that evidence before commissioning another attempt in the same assignment.
        if assignment.revision > 1 {
            try await reviewPersistentEvidence(assignment: assignment, scheduler: scheduler,
                onActivity: { onEvent(.agentActivity($0)) })
            try await scheduler.checkAssignmentBoundary(assignment.id)
        }
        let runner = try persistentRunner(program: program, assignment: assignment, task: .researcher, stage: assignment.mode.rawValue)
        let activity: @Sendable (AgentActivity) -> Void = { onEvent(.agentActivity($0)) }
        var report: AssignmentReport
        if assignment.mode == .direct {
            let sandbox = makePythonSandbox(artifactsURL: store.artifactsURL, runNamespace: assignment.id)
            let apply: @Sendable (TheoryProposal) async throws -> String = { @MainActor [weak self] proposal in
                guard let self else { throw CoreError.io("Project closed") }
                try self.validateProtectedGoalUpdate(proposal)
                guard TheoryWritePolicy.agentSettableStatuses.contains(proposal.item.status) else {
                    throw CoreError.io("This status requires independent review.")
                }
                try store.save(proposal.item)
                self.reloadFromDisk()
                return "Saved \(proposal.item.id)."
            }
            let tools = TheoryTools.readOnlyTools(store: store)
                + SandboxTools.tools(sandbox: sandbox, store: store, onProposal: { _ in }, applyDirect: apply)
                + SourceTools.tools(attached: attachedSources.map { (slug: $0.ref.slug, store: $0.store) })
                + DocumentTools.tools(store: store, access: makeStandingDocumentAccess())
                + [ProgramTools.publishFindingTool(branchPlanID: assignment.id,
                    targetRevisionID: assignment.targetRevisionID, publish: { try await scheduler.publish($0) })]
            let worker = DirectResearchWorkbench(runner: runner, store: store, contextTools: tools,
                writePolicy: .direct(apply), fileSolution: makePersistentSolutionFiler(assignment: assignment, scheduler: scheduler),
                fileChallenge: makePersistentChallengeFiler(assignment: assignment, scheduler: scheduler),
                thinking: AppSettings.effectiveThinking(for: .researcher),
                compactAt: max(8_000, AppSettings.Limit.researchConversationTokens.value), onActivity: activity)
            let conversation = try ResearchConversation(key: "assignment-\(assignment.id)", directory: store.sessionsURL)
            report = try await worker.run(assignment: assignment, program: program, scheduler: scheduler, conversation: conversation)
        } else {
            guard let planID = assignment.planID else { throw CoreError.io("Planned assignment has no plan identity.") }
            var plan: PlanDocument
            if let saved = store.plan(id: planID) { plan = saved }
            else {
                plan = try await PlannedAssignmentPlanner.plan(assignment: assignment, program: program,
                    runner: persistentRunner(program: program, assignment: assignment, task: .planner, stage: "assignment_planning"),
                    tools: TheoryTools.readOnlyTools(store: store), thinking: AppSettings.effectiveThinking(for: .planner),
                    save: { @MainActor plan in try store.savePlan(plan) }, onActivity: activity)
            }
            let savedRecord = store.loadSession(named: "research-run-\(planID)")
                .flatMap { try? JSONDecoder().decode(RunRecord.self, from: $0) }
            var record = savedRecord ?? RunRecord(plan: plan)
            if assignment.revision > 1 {
                if plan.isFinished, let message = assignment.messages.last {
                    plan.tasks.append(.init(index: (plan.tasks.map(\.index).max() ?? 0) + 1,
                        title: message.text, reviewGate: true))
                }
                for i in plan.tasks.indices where plan.tasks[i].status == .blocked || plan.tasks[i].status == .inProgress {
                    plan.tasks[i].status = .pending
                }
                plan.status = .approved; record.state = .ready; record.lastStopReason = nil
                try store.savePlan(plan)
            }
            let branch = program.branch(planID: planID) ?? ResearchProgram.Branch(planID: planID, title: assignment.displayTitle)
            let workbench = try makeBranchWorkbench(program: program, branch: branch, runtime: nil, mode: .auto,
                persistentScheduler: scheduler, assignment: assignment, onEvent: onEvent)
            record = try await workbench.run(plan: plan, record: record,
                userInput: assignment.messages.last?.text)
            try store.saveSession(named: "research-run-\(planID)", json: JSONEncoder().encode(record))
            let summary = record.journal.suffix(4).map(\.summary).joined(separator: "\n")
            switch record.state {
            case .finished(let text): report = .init(outcome: .partial, summary: text)
            case .failed(let reason): report = .init(summary: reason, unresolved: reason)
            case .waitingForUser(let question): report = .init(summary: question.question, unresolved: question.context, stopReason: .question)
            case .solutionUnderReview, .problemChallengeUnderReview: report = .init(outcome: .partial, summary: summary, stopReason: .review)
            case .budgetPause: report = .init(summary: summary, stopReason: .tokenLimit)
            default: report = .init(summary: summary, stopReason: record.lastStopReason ?? .stopped)
            }
            report.itemIDs = Array(Set(record.libraryChanges.map(\.itemID))).sorted()
        }
        // Each review starts with fresh history and the assignment's exact frozen target.
        try await reviewPersistentEvidence(assignment: assignment, scheduler: scheduler, onActivity: activity)
        report.tokensUsed = store.loadUsageLedger(programID: program.id).filter { $0.subjectID == assignment.id }.reduce(0) { $0 + $1.actualTokens }
        return report
    }

    func reviewPersistentEvidence(assignment: ResearchAssignment, scheduler: PersistentResearchScheduler,
                                  onActivity: @escaping @Sendable (AgentActivity) -> Void) async throws {
        guard let store else { throw CoreError.io("No project open") }
        let p = await scheduler.snapshot()
        guard let target = p.targetRevisions.first(where: { $0.id == assignment.targetRevisionID }) else { throw CoreError.io("Assigned target revision is missing.") }
        let runner = try persistentRunner(program: p, assignment: assignment, task: .reviewer, stage: "assignment_evidence_review")
        let tools = TheoryTools.readOnlyTools(store: store) + SandboxTools.computeTools(sandbox:
            makePythonSandbox(artifactsURL: store.artifactsURL, runNamespace: "review-\(assignment.id)"))
        let thinking = AppSettings.effectiveThinking(for: .reviewer)
        for challenge in p.challenges where challenge.branchPlanID == assignment.id &&
            [.filed, .mathematicalReview, .scopeReview].contains(challenge.status) {
            _ = try await ProblemChallengeReviewer.review(challenge: challenge, target: target,
                items: store.items, tools: tools, runner: runner, thinking: thinking,
                programID: p.id, record: makeTurnRecorder(),
                onProgress: { try await scheduler.reviewed($0) }, onActivity: onActivity)
        }
        for var candidate in p.solutions where candidate.branchPlanID == assignment.id &&
            [.filed, .contractChecking, .underReview].contains(candidate.status) {
            let items = store.items
            guard let ruling = try await SolutionAdjudicator.adjudicate(runner: runner,
                goal: target.statement.isEmpty ? target.requestText : target.statement, contract: nil,
                targetRevision: target, candidate: candidate, items: items, tools: tools,
                thinking: thinking, programID: p.id, record: makeTurnRecorder(), onActivity: onActivity) else {
                throw CoreError.io("Solution adjudication returned no ruling; the candidate remains pending.")
            }
            candidate.contractRuling = .init(accepted: ruling.accepted, note: ruling.note,
                satisfiedCompletionIDs: ruling.satisfiedCompletionIDs)
            candidate.status = ruling.accepted ? .underReview : .contractRejected
            try await scheduler.reviewed(candidate)
            if !ruling.accepted { continue }
            let verifier = LLMReviewer(runner: runner, tools: tools, notation: target.notationSnapshot,
                outline: ContextAssembly.outline(items: items), thinking: thinking, exclusions: [])
            let recorder = makeTurnRecorder(), frozenCandidate = candidate
            let goal = target.statement.isEmpty ? target.requestText : target.statement
            let result = try await SolutionReviewGate.review(candidate: candidate,
                goal: goal, contract: nil, items: items, cache: [:], verifier: verifier,
                reviewAssembly: { chain, _ in
                    try await SolutionReviewGate.reviewAssembly(runner: runner, goal: goal,
                        contract: nil, chain: chain, candidate: frozenCandidate, tools: tools,
                        thinking: thinking, programID: p.id, record: recorder, onActivity: onActivity)
                }, onActivity: onActivity)
            candidate.reviewRuling = result.ruling
            candidate.status = result.ruling.accepted ? .accepted : .reviewRejected
            try await scheduler.reviewed(candidate)
        }
    }

    func revisePersistentTarget(program: ResearchProgram, challenge: ProblemChallenge,
                                 itemID: String?, scheduler: PersistentResearchScheduler) async throws -> ResearchTargetRevision {
        guard let store, challenge.mathematicalRuling?.accepted == true,
              challenge.scopeRuling?.accepted == true, challenge.scopeRuling?.targetDisposition != .needsClarification,
              let request = challenge.proposedReplacementRequest, !request.isEmpty else {
            throw CoreError.io("A revision needs an independently accepted minimal correction; clarify the intended statement when no repair is established.")
        }
        let targetID: String
        var formalizedContract: SuccessContract?
        if let pinnedID = challenge.proposedTargetItemID {
            guard itemID == nil || itemID == pinnedID,
                  let raw = challenge.proposedTargetItemData,
                  try store.rawTheoryItemData(id: pinnedID) == raw else {
                throw CoreError.io("The proposed target changed after review. File and review the corrected evidence again.")
            }
            targetID = pinnedID
        } else {
            // Formalize only the already reviewed correction, then check the resulting item
            // through a new scope review before allowing it to become authoritative.
            let context = try makeResearchGoalEditorContext()
            let formalizationRunner = try persistentRunner(program: program, task: .planner,
                stage: "target_revision_formalization")
            guard let formalized = try await ResearchGoalEditor.run(runner: formalizationRunner, request: request,
                store: store, tools: context.tools, notation: context.notation, macros: context.macros,
                outline: context.outline, thinking: context.thinking, programID: program.id,
                record: makeTurnRecorder(), applyCreate: context.applyCreate) else { throw CoreError.io("Could not formalize the accepted correction.") }
            targetID = formalized.item.id
            formalizedContract = formalized.draft.contract
            var check = challenge
            check.proposedTargetItemID = targetID; check.proposedTargetItemData = try store.rawTheoryItemData(id: targetID)
            check.proposedTargetItemType = formalized.item.type
            check.proposedTargetItemSHA256 = check.proposedTargetItemData.map(ResearchTargetRevision.sha256)
            check.mathematicalRuling = nil; check.scopeRuling = nil; check.status = .filed
            let reviewRunner = try persistentRunner(program: program, task: .reviewer,
                stage: "target_revision_challenge_review")
            let reviewTools = TheoryTools.readOnlyTools(store: store) + SandboxTools.computeTools(sandbox:
                makePythonSandbox(artifactsURL: store.artifactsURL,
                    runNamespace: "target-revision-review-\(challenge.id)"))
            let ruling = try await ProblemChallengeReviewer.review(challenge: check, target: program.activeTargetRevision,
                items: store.items, tools: reviewTools, runner: reviewRunner,
                thinking: AppSettings.effectiveThinking(for: .reviewer),
                programID: program.id, record: makeTurnRecorder())
            guard ruling.status == .accepted else { throw CoreError.io("The formalized correction did not pass independent review.") }
            // Keep the original accepted defect authoritative (and admission frozen) while
            // checking the proposed correction. Commit new bytes/rulings together on success.
            try await scheduler.reviewed(ruling)
        }
        var revision = try store.makeResearchTargetRevision(requestText: request, libraryItemID: targetID,
            parentRevisionID: program.activeTargetRevisionID, proposedByChallengeID: challenge.id,
            changeNote: "Minimal correction after accepted challenge and director governance.")
        revision.statement = store.item(id: targetID)?.statement ?? request
        revision.recommendedReading = formalizedContract?.recommendedReading ?? ""
        revision.ambiguities = formalizedContract?.ambiguities ?? []
        return revision
    }
}
