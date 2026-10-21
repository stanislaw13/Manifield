import XCTest
import ManifieldCore
@testable import ManifieldAgents

final class PersistentResearchTests: XCTestCase {
    func testReviewProgressIsSavedWithoutWakingDirectorAndLatePauseCannotUndoResolution() async throws {
        let p = ResearchProgram(id: "review-events", goal: "g", execution: .init(limits: .unlimited))
        let scheduler = try PersistentResearchScheduler(program: p, save: { _ in }) { _, _, _ in .init(summary: "") }
        try await scheduler.start()
        var challenge = ProblemChallenge(branchPlanID: "a", targetRevisionID: p.activeTargetRevisionID, description: "Counterexample")
        challenge.status = .mathematicalReview
        try await scheduler.reviewed(challenge)
        let progress = await scheduler.snapshot()
        XCTAssertEqual(progress.challenges.first?.status, .mathematicalReview)
        XCTAssertFalse(progress.execution!.events.contains { $0.kind == .reviewed })
        challenge.status = .accepted
        challenge.mathematicalRuling = .init(accepted: true, note: "Verified")
        challenge.scopeRuling = .init(accepted: true, note: "Full scope", targetDisposition: .fullInvalidity)
        try await scheduler.reviewed(challenge)
        let events = await scheduler.events(after: 0)
        XCTAssertEqual(events.filter { $0.kind == .reviewed }.count, 1)
        try await scheduler.resolve(.init(kind: .invalidTarget, targetRevisionID: p.activeTargetRevisionID,
            evidenceIDs: [challenge.id], explanation: "Invalid"))
        try await scheduler.pause("Late usage report")
        let final = await scheduler.snapshot()
        XCTAssertEqual(final.status, .done)
        XCTAssertEqual(final.execution?.resolution?.kind, .invalidTarget)
    }
    func testConcurrencyCeilingReleasesSlotForNextAssignment() async throws {
        let p = ResearchProgram(id: "p", goal: "g", maxConcurrentBranches: 2,
            execution: .init(limits: .unlimited))
        let executions = ControlledExecutions()
        let scheduler = try PersistentResearchScheduler(program: p, save: { _ in }) { assignment, _, _ in
            await executions.run(assignment.id)
            return .init(summary: "Finished \(assignment.id)")
        }
        try await scheduler.start()
        for id in ["one", "two", "three"] {
            _ = try await scheduler.dispatch(.init(id: id, operationID: "op-\(id)", programID: p.id,
                targetRevisionID: p.activeTargetRevisionID, mode: .direct, objective: id))
        }

        await executions.waitForStarts(2)
        var snapshot = await scheduler.snapshot()
        XCTAssertEqual(Set(snapshot.execution!.assignments.filter { $0.status == .running }.map(\.id)), ["one", "two"])
        XCTAssertEqual(snapshot.execution!.assignments.first(where: { $0.id == "three" })?.status, .queued)
        await executions.release("one")
        await executions.waitForStarts(3)
        let highWaterMark = await executions.highWaterMark()
        XCTAssertEqual(highWaterMark, 2)

        await executions.release("two")
        await executions.release("three")
        await scheduler.drain()
        snapshot = await scheduler.snapshot()
        XCTAssertTrue(snapshot.execution!.assignments.allSatisfy { $0.status == .finished })
        try await scheduler.pause("test finished")
    }

    func testCancelledAssignmentReportReconcilesUsageFromDurableLedger() async throws {
        let p = ResearchProgram(id: "p", goal: "g", execution: .init(limits: .unlimited))
        let scheduler = try PersistentResearchScheduler(
            program: p,
            save: { _ in },
            usageForAssignment: { id in id == "cancelled" ? 1_300 : 0 }
        ) { _, _, _ in
            throw CancellationError()
        }
        try await scheduler.start()
        _ = try await scheduler.dispatch(.init(
            id: "cancelled", operationID: "op-cancelled", programID: p.id,
            targetRevisionID: p.activeTargetRevisionID, mode: .direct,
            objective: "Record partial work before cancellation"))
        await scheduler.drain()

        let snapshot = await scheduler.snapshot()
        let report = try XCTUnwrap(snapshot.execution?.assignments.first?.latestReport)
        XCTAssertEqual(report.stopReason, .interrupted)
        XCTAssertEqual(report.tokensUsed, 1_300,
                       "the report and durable usage ledger must agree after cancellation")
        try await scheduler.pause("test finished")
    }

    func testWaitWakesForGuidanceAndPropagatesCancellation() async throws {
        let p = ResearchProgram(id: "p", goal: "g", execution: .init(limits: .unlimited))
        let executions = ControlledExecutions()
        let scheduler = try PersistentResearchScheduler(program: p, save: { _ in }) { assignment, _, _ in
            await executions.run(assignment.id)
            return .init(summary: "finished")
        }
        try await scheduler.start()
        let assignment = ResearchAssignment(id: "one", operationID: "op-one", programID: p.id,
            targetRevisionID: p.activeTargetRevisionID, mode: .direct, objective: "Inspect")
        _ = try await scheduler.dispatch(assignment)
        await executions.waitForStarts(1)
        let cursor = await scheduler.snapshot().execution!.events.last!.sequence

        let guidanceWait = Task { try await scheduler.wait(after: cursor, assignmentIDs: [assignment.id]) }
        let secondGuidanceWait = Task { try await scheduler.wait(after: cursor) }
        try await scheduler.guideDirector("Prioritize the boundary case.")
        let guidance = try await guidanceWait.value
        let secondGuidance = try await secondGuidanceWait.value
        XCTAssertEqual(guidance.map(\.kind), [.guidance])
        XCTAssertEqual(secondGuidance.map(\.kind), [.guidance])

        let cancellationWait = Task {
            try await scheduler.wait(after: guidance.last!.sequence, assignmentIDs: [assignment.id])
        }
        cancellationWait.cancel()
        do {
            _ = try await cancellationWait.value
            XCTFail("cancelled wait should throw")
        } catch is CancellationError {}

        await executions.release("one")
        await scheduler.drain()
        try await scheduler.pause("test finished")
    }

    func testWaitRejectsQueuedAssignmentBlockedByAcceptedChallenge() async throws {
        var p = ResearchProgram(id: "challenge-wait", goal: "g", maxConcurrentBranches: 1,
            execution: .init(limits: .unlimited))
        var finished = ResearchAssignment(id: "first", operationID: "op-first", programID: p.id,
            targetRevisionID: p.activeTargetRevisionID, mode: .direct, objective: "Find a counterexample")
        finished.status = .paused
        var queued = ResearchAssignment(id: "second", operationID: "op-second", programID: p.id,
            targetRevisionID: p.activeTargetRevisionID, mode: .direct, objective: "Repeat the check")
        queued.status = .queued
        p.execution!.assignments = [finished, queued]
        var challenge = ProblemChallenge(id: "accepted", branchPlanID: finished.id,
            targetRevisionID: p.activeTargetRevisionID, description: "The whole target is false.")
        challenge.status = .accepted
        challenge.mathematicalRuling = .init(accepted: true, note: "Counterexample verified.")
        challenge.scopeRuling = .init(accepted: true, note: "The entire target fails.",
            targetDisposition: .fullInvalidity)
        p.challenges = [challenge]
        let calls = ExecutionCounter()
        let scheduler = try PersistentResearchScheduler(program: p, save: { _ in }) { _, _, _ in
            await calls.add(); return .init(summary: "must not run")
        }
        try await scheduler.start()

        do {
            _ = try await scheduler.wait(after: 0, assignmentIDs: [queued.id])
            XCTFail("waiting for scheduler-blocked queued work must fail instead of hanging")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("both independent reviews are complete"))
            XCTAssertTrue(error.localizedDescription.contains("queued assignments cannot start"))
        }
        let callCount = await calls.count
        let snapshot = await scheduler.snapshot()
        XCTAssertEqual(callCount, 0)
        XCTAssertEqual(snapshot.execution?.assignments[1].status, .queued)
        try await scheduler.pause("test finished")
    }

    func testFailedAdmissionSaveSurfacesAndDoesNotStartExecutor() async throws {
        let p = ResearchProgram(id: "p", goal: "g", execution: .init(limits: .unlimited))
        let store = FailingProgramSave(failOnCall: 3)
        let calls = ExecutionCounter()
        let scheduler = try PersistentResearchScheduler(program: p, save: { program in
            try store.save(program)
        }) { _, _, _ in
            await calls.add()
            return .init(summary: "must not run")
        }
        try await scheduler.start() // save 1
        let assignment = ResearchAssignment(id: "one", operationID: "op-one", programID: p.id,
            targetRevisionID: p.activeTargetRevisionID, mode: .direct, objective: "Inspect")
        _ = try await scheduler.dispatch(assignment) // queued save 2, running save 3 fails

        do {
            try await scheduler.checkHealth()
            XCTFail("persistence failure should remain visible")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("could not be saved"))
        }
        let snapshot = await scheduler.snapshot()
        XCTAssertEqual(snapshot.status, .paused)
        XCTAssertEqual(snapshot.execution?.assignments.first?.status, .queued)
        XCTAssertFalse(snapshot.execution!.events.contains { $0.kind == .started })
        let callCount = await calls.count
        XCTAssertEqual(callCount, 0)
    }

    func testGuidanceArrivingAsRunFinishesIsDeliveredOnceOnContinuation() async throws {
        let p = ResearchProgram(id: "p", goal: "g", execution: .init(limits: .unlimited))
        let executions = ControlledExecutions()
        let calls = ExecutionCounter()
        let scheduler = try PersistentResearchScheduler(program: p, save: { _ in }) { assignment, _, scheduler in
            await calls.add()
            if assignment.revision == 1 {
                await executions.run(assignment.id)
            } else {
                try await scheduler.acknowledgeGuidance(
                    assignmentID: assignment.id, messageIDs: assignment.messages.map(\.id))
            }
            return .init(summary: "run \(assignment.revision) finished")
        }
        try await scheduler.start()
        let assignment = ResearchAssignment(id: "one", operationID: "op-one", programID: p.id,
            targetRevisionID: p.activeTargetRevisionID, mode: .direct, objective: "Inspect")
        _ = try await scheduler.dispatch(assignment)
        await executions.waitForStarts(1)
        try await scheduler.continueAssignment(id: assignment.id, message: "Check the final edge case.",
            evidenceIDs: [], operationID: "late-guidance")
        await executions.release("one")
        await scheduler.drain()

        let snapshot = await scheduler.snapshot()
        let final = snapshot.execution!.assignments[0]
        let callCount = await calls.count
        XCTAssertEqual(callCount, 2)
        XCTAssertEqual(final.revision, 2)
        XCTAssertEqual(final.reports.count, 2)
        XCTAssertEqual(final.messages.count, 1)
        XCTAssertEqual(Set(final.deliveredMessageIDs ?? []), Set(final.messages.map(\.id)))
        XCTAssertEqual(final.status, .finished)
        try await scheduler.pause("test finished")
    }

    func testReviewUpdateOnlyReachesAssignmentsSuppliedTheEvidence() async throws {
        var p = ResearchProgram(id: "p", goal: "g", execution: .init(limits: .unlimited))
        var selectedDirectly = ResearchAssignment(id: "selected", operationID: "op-selected", programID: p.id,
            targetRevisionID: p.activeTargetRevisionID, mode: .direct, objective: "Use evidence",
            evidenceIDs: ["candidate"])
        selectedDirectly.status = .paused
        var selectedByGuidance = ResearchAssignment(id: "guided", operationID: "op-guided", programID: p.id,
            targetRevisionID: p.activeTargetRevisionID, mode: .direct, objective: "Use later evidence")
        selectedByGuidance.status = .paused
        selectedByGuidance.messages = [.init(text: "Read candidate", evidenceIDs: ["candidate"])]
        var unrelated = ResearchAssignment(id: "unrelated", operationID: "op-unrelated", programID: p.id,
            targetRevisionID: p.activeTargetRevisionID, mode: .direct, objective: "Independent work")
        unrelated.status = .paused
        p.execution!.assignments = [selectedDirectly, selectedByGuidance, unrelated]
        let scheduler = try PersistentResearchScheduler(program: p, save: { _ in }) { _, _, _ in
            .init(summary: "unused")
        }
        try await scheduler.start()
        let candidate = SolutionCandidate(id: "candidate", branchPlanID: "author",
            targetRevisionID: p.activeTargetRevisionID, primaryItemID: "answer", argument: "complete",
            status: .accepted)
        try await scheduler.reviewed(candidate)

        let assignments = await scheduler.snapshot().execution!.assignments
        let selectedMessage = assignments.first(where: { $0.id == "selected" })!.messages
        let guidedMessages = assignments.first(where: { $0.id == "guided" })!.messages
        let unrelatedMessages = assignments.first(where: { $0.id == "unrelated" })!.messages
        XCTAssertEqual(selectedMessage.count, 1)
        XCTAssertEqual(guidedMessages.count, 2)
        XCTAssertTrue(unrelatedMessages.isEmpty)
        XCTAssertEqual(selectedMessage[0].evidenceIDs, ["candidate"])
        try await scheduler.pause("test finished")
    }

    func testAcceptedChallengePausesOldWorkAndRevisionRequiresFreshAssignment() async throws {
        let p = ResearchProgram(id: "p", goal: "g", execution: .init(limits: .unlimited))
        let executions = ControlledExecutions()
        let scheduler = try PersistentResearchScheduler(program: p, save: { _ in }) { assignment, _, scheduler in
            await executions.run(assignment.id)
            try await scheduler.checkAssignmentBoundary(assignment.id)
            return .init(outcome: .partial, summary: "boundary reached")
        }
        try await scheduler.start()
        let old = ResearchAssignment(id: "old", operationID: "op-old", programID: p.id,
            targetRevisionID: p.activeTargetRevisionID, mode: .direct, objective: "Old target")
        _ = try await scheduler.dispatch(old)
        await executions.waitForStarts(1)

        var challenge = ProblemChallenge(id: "challenge", branchPlanID: old.id,
            targetRevisionID: p.activeTargetRevisionID, description: "The target needs a quantifier.")
        challenge.status = .accepted
        challenge.mathematicalRuling = .init(accepted: true, note: "Verified.")
        challenge.scopeRuling = .init(accepted: true, note: "A precise revision is available.",
            targetDisposition: .needsClarification)
        try await scheduler.reviewed(challenge)
        await executions.release(old.id)
        await scheduler.drain()
        var snapshot = await scheduler.snapshot()
        XCTAssertEqual(snapshot.execution!.assignments[0].latestReport?.stopReason, .review)

        var revision = ResearchTargetRevision(id: "revised", parentRevisionID: p.activeTargetRevisionID,
            requestText: "For every n, prove the claim.", proposedByChallengeID: challenge.id)
        revision.statement = "For every n, prove the claim."
        try await scheduler.govern(challengeID: challenge.id, revision: revision,
            stopIDs: [old.id], continueIDs: [], explanation: "Adopt the quantified target.")
        snapshot = await scheduler.snapshot()
        XCTAssertEqual(snapshot.activeTargetRevisionID, revision.id)
        XCTAssertEqual(snapshot.execution!.assignments[0].status, .stopped)

        await executions.release("new")
        let fresh = ResearchAssignment(id: "new", operationID: "op-new", programID: p.id,
            targetRevisionID: revision.id, mode: .direct, objective: "Recheck revised target")
        _ = try await scheduler.dispatch(fresh)
        await scheduler.drain()
        snapshot = await scheduler.snapshot()
        XCTAssertEqual(snapshot.execution!.assignments.last?.status, .finished)
        XCTAssertEqual(snapshot.execution!.assignments.last?.targetRevisionID, revision.id)
        try await scheduler.pause("test finished")
    }

    func testChallengeGovernanceCanContinueUnaffectedPausedWork() async throws {
        var p = ResearchProgram(id: "p", goal: "two independent parts", execution: .init(limits: .unlimited))
        var assignment = ResearchAssignment(id: "unaffected", operationID: "op-unaffected", programID: p.id,
            targetRevisionID: p.activeTargetRevisionID, mode: .direct, objective: "Second part")
        assignment.status = .paused
        p.execution!.assignments = [assignment]
        var challenge = ProblemChallenge(id: "challenge", branchPlanID: "other",
            targetRevisionID: p.activeTargetRevisionID, description: "Only the first part is malformed.")
        challenge.status = .accepted
        challenge.mathematicalRuling = .init(accepted: true, note: "Verified.")
        challenge.scopeRuling = .init(accepted: true, note: "Second part is unaffected.",
            targetDisposition: .partialInvalidity)
        p.challenges = [challenge]
        let calls = ExecutionCounter()
        let scheduler = try PersistentResearchScheduler(program: p, save: { _ in }) { assignment, _, scheduler in
            try await scheduler.acknowledgeGuidance(
                assignmentID: assignment.id, messageIDs: assignment.messages.map(\.id))
            await calls.add()
            return .init(outcome: .partial, summary: "Continued unaffected scope.")
        }
        try await scheduler.start()
        try await scheduler.govern(challengeID: challenge.id, revision: nil,
            stopIDs: [], continueIDs: [assignment.id], explanation: "Continue the independent second part.")
        await scheduler.drain()

        let snapshot = await scheduler.snapshot()
        let callCount = await calls.count
        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(snapshot.execution!.assignments[0].revision, 2)
        XCTAssertEqual(snapshot.execution!.assignments[0].status, .finished)
        XCTAssertEqual(snapshot.challenges[0].status, .governed)
        XCTAssertEqual(snapshot.activeTargetRevisionID, p.activeTargetRevisionID)
        try await scheduler.pause("test finished")
    }

    func testDispatchRetryRunsOnceAndWaitReturnsReportUnderSameProgram() async throws {
        let p = ResearchProgram(id: "p", goal: "g", execution: .init(limits: .unlimited))
        let calls = ExecutionCounter()
        let scheduler = try PersistentResearchScheduler(program: p, save: { _ in }) { assignment, program, _ in
            await calls.add()
            XCTAssertEqual(assignment.programID, program.id)
            XCTAssertNil(assignment.planID)
            return .init(summary: "No useful result; this is valid.")
        }
        try await scheduler.start()
        let a = ResearchAssignment(id: "one", operationID: "call1", programID: p.id,
            targetRevisionID: p.activeTargetRevisionID, mode: .direct, objective: "Inspect")
        _ = try await scheduler.dispatch(a)
        var retry = a; retry.id = "different-generated-id"
        let original = try await scheduler.dispatch(retry)
        XCTAssertEqual(original.id, "one")
        let events = try await scheduler.wait(after: 0, assignmentIDs: [a.id])
        XCTAssertEqual(events.last?.kind, .reported)
        await scheduler.drain()
        let result = await scheduler.snapshot(), count = await calls.count
        XCTAssertEqual(count, 1)
        XCTAssertEqual(result.execution?.assignments.count, 1)
        XCTAssertEqual(result.execution?.assignments.first?.latestReport?.outcome, .unresolved)
        XCTAssertTrue(result.branches.isEmpty)
        try await scheduler.pause("test finished")
    }

    func testRestartPreservesInterruptedAssignmentWithoutImplicitReplay() async throws {
        var p = ResearchProgram(id: "p", goal: "g", execution: .init(limits: .unlimited))
        var a = ResearchAssignment(id: "one", operationID: "call1", programID: p.id,
            targetRevisionID: p.activeTargetRevisionID, mode: .planned, objective: "Inspect")
        a.status = .running; p.execution!.assignments = [a]
        let calls = ExecutionCounter()
        let scheduler = try PersistentResearchScheduler(program: p, save: { _ in }) { assignment, _, scheduler in
            try await scheduler.acknowledgeGuidance(assignmentID: assignment.id, messageIDs: assignment.messages.map(\.id))
            await calls.add(); return .init(outcome: .partial, summary: "A precise gap remains.")
        }
        try await scheduler.start()
        let restored = await scheduler.snapshot()
        XCTAssertEqual(restored.execution?.assignments[0].status, .paused)
        XCTAssertEqual(restored.execution?.assignments[0].latestReport?.stopReason, .interrupted)
        try await scheduler.continueAssignment(id: a.id, message: "Try the missing step", evidenceIDs: [], operationID: "resume1")
        try await scheduler.continueAssignment(id: a.id, message: "Try the missing step", evidenceIDs: [], operationID: "resume1")
        await scheduler.drain()
        let final = await scheduler.snapshot(), count = await calls.count
        XCTAssertEqual(count, 1)
        XCTAssertEqual(final.execution?.assignments[0].revision, 2)
        XCTAssertEqual(final.execution?.assignments[0].reports.count, 2)
        try await scheduler.pause("test finished")
    }

    func testAcceptedPartialChallengeCannotResolveWholeTarget() async throws {
        var p = ResearchProgram(id: "p", goal: "two obligations", execution: .init(limits: .unlimited))
        var challenge = ProblemChallenge(branchPlanID: "a", targetRevisionID: p.activeTargetRevisionID,
            description: "First obligation is impossible.")
        challenge.status = .accepted
        challenge.mathematicalRuling = .init(accepted: true, note: "Verified counterexample.")
        challenge.scopeRuling = .init(accepted: true, note: "Second obligation remains.", targetDisposition: .partialInvalidity)
        p.challenges = [challenge]
        let scheduler = try PersistentResearchScheduler(program: p, save: { _ in }) { _, _, _ in .init(summary: "") }
        try await scheduler.start()
        do {
            try await scheduler.resolve(.init(kind: .invalidTarget, targetRevisionID: p.activeTargetRevisionID,
                evidenceIDs: [challenge.id], explanation: "Invalid"))
            XCTFail("partial challenge must not close whole target")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Partial scope")) }
        challenge.scopeRuling?.targetDisposition = .fullInvalidity
        try await scheduler.reviewed(challenge)
        try await scheduler.resolve(.init(kind: .invalidTarget, targetRevisionID: p.activeTargetRevisionID,
            evidenceIDs: [challenge.id], explanation: "Entire target invalid."))
        let final = await scheduler.snapshot()
        XCTAssertEqual(final.status, .done)
        XCTAssertTrue(final.solutions.isEmpty)
    }

    func testTerminalToolWinsOnLastAllowedCallAndSkipsRemainingBatch() async throws {
        let count = ExecutionCounter()
        let provider = ResearchScriptProvider { _ in [
            .toolUseFinished(id: "finish", name: "finish", inputJSON: "{}"),
            .toolUseFinished(id: "bad", name: "mutate", inputJSON: "{}"), .finished(.toolUse)] }
        let finish = FunctionAgentTool(name: "finish", description: "", schema: "{}", effect: .finish) { _, _ in "Saved" }
        let mutate = FunctionAgentTool(name: "mutate", description: "", schema: "{}") { _, _ in await count.add(); return "Bad" }
        var config = AgentConfig(systemPrompt: "", tools: [finish, mutate], maxIterations: 1)
        config.stopOnToolEffect = true
        let result = try await AgentLoop(provider: provider).run(config: config, history: [.user("work")])
        XCTAssertEqual(result.stop, .toolCompleted)
        let executed = await count.count
        XCTAssertEqual(executed, 0)
        XCTAssertEqual(provider.requests.count, 1)
    }

    func testConversationRecoversIdempotentDispatchAndCompactionArchivesRejectedApproach() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = try ResearchConversation(key: "director-p", directory: dir)
        try await session.checkpoint([.user("Approach A failed at the midpoint identity."),
            .init(role: .assistant, blocks: [.toolUse(id: "stable-op", name: "dispatch_work", inputJSON: "{}")])])
        let count = ExecutionCounter()
        let tool = FunctionAgentTool(name: "dispatch_work", description: "", schema: "{}") { id, _ in
            XCTAssertEqual(id, "stable-op"); await count.add(); return "assignment-1"
        }
        try await session.recover(tools: [tool], replayable: ["dispatch_work"])
        try await session.recover(tools: [tool], replayable: ["dispatch_work"])
        let countValue = await count.count
        XCTAssertEqual(countValue, 1)
        let provider = ResearchScriptProvider { _ in [.textDelta("Approach A failed at midpoint. Wait for assignment-1."), .finished(.endTurn)] }
        try await session.compact(runner: AgentLoop(provider: provider), strategicState: "assignment-1 running", thinking: .off, onActivity: { _ in })
        let compacted = await session.snapshot()
        XCTAssertEqual(compacted.epoch, 1)
        XCTAssertEqual(compacted.messages.count, 1)
        let archived = try await session.readArchive(name: compacted.archives[0], offset: 0, limit: 20_000)
        XCTAssertTrue(archived.contains("midpoint identity"))
        let reloaded = try ResearchConversation(key: "director-p", directory: dir)
        let snapshot = await reloaded.snapshot()
        XCTAssertEqual(snapshot, compacted)
    }

    func testDirectWorkerReturnsEmptyHandedWithoutCreatingPlan() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try ProjectStore.create(at: dir, name: "Test")
        let p = ResearchProgram(id: "p", goal: "g", execution: .init(limits: .unlimited))
        let assignment = ResearchAssignment(id: "a", operationID: "op", programID: p.id,
            targetRevisionID: p.activeTargetRevisionID, mode: .direct, objective: "Check the missing lemma")
        let provider = ResearchScriptProvider { request in
            XCTAssertFalse(request.tools.contains { $0.name == "add_task" || $0.name == "revise_plan" })
            return [.toolUseFinished(id: "report", name: "report_assignment",
                inputJSON: #"{"outcome":"unresolved","summary":"The proposed midpoint identity does not follow.","unresolved":"Need a valid local reflection argument."}"#), .finished(.toolUse)]
        }
        let worker = DirectResearchWorkbench(runner: AgentLoop(provider: provider), store: store,
            contextTools: [], writePolicy: .direct { _ in "" }, fileSolution: { _, _, _, _ in "" }, fileChallenge: { _, _, _, _ in "" })
        let scheduler = try PersistentResearchScheduler(program: p, save: { _ in }) { a, p, scheduler in
            let session = try ResearchConversation(key: "worker-a", directory: dir)
            return try await worker.run(assignment: a, program: p, scheduler: scheduler, conversation: session)
        }
        try await scheduler.start()
        _ = try await scheduler.dispatch(assignment)
        await scheduler.drain()
        let final = await scheduler.snapshot()
        XCTAssertEqual(final.execution?.assignments[0].latestReport?.outcome, .unresolved)
        XCTAssertNil(final.execution?.assignments[0].planID)
        XCTAssertEqual(provider.requests.count, 1)
        try await scheduler.pause("test finished")
    }
}

private actor ExecutionCounter {
    var count = 0
    func add() { count += 1 }
}

private actor ControlledExecutions {
    private var started: [String] = []
    private var active = 0
    private var maximumActive = 0
    private var released: Set<String> = []
    private var releaseWaiters: [String: CheckedContinuation<Void, Never>] = [:]
    private var startWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func run(_ id: String) async {
        started.append(id)
        active += 1
        maximumActive = max(maximumActive, active)
        let ready = startWaiters.filter { started.count >= $0.0 }
        startWaiters.removeAll { started.count >= $0.0 }
        ready.forEach { $0.1.resume() }
        if !released.contains(id) {
            await withCheckedContinuation { releaseWaiters[id] = $0 }
        }
        active -= 1
    }

    func waitForStarts(_ count: Int) async {
        guard started.count < count else { return }
        await withCheckedContinuation { startWaiters.append((count, $0)) }
    }

    func release(_ id: String) {
        released.insert(id)
        releaseWaiters.removeValue(forKey: id)?.resume()
    }

    func highWaterMark() -> Int { maximumActive }
}

private final class FailingProgramSave: @unchecked Sendable {
    private let lock = NSLock()
    private let failOnCall: Int
    private var calls = 0

    init(failOnCall: Int) { self.failOnCall = failOnCall }

    func save(_ program: ResearchProgram) throws {
        lock.lock()
        defer { lock.unlock() }
        calls += 1
        if calls == failOnCall { throw SaveFailure() }
    }

    private struct SaveFailure: LocalizedError {
        var errorDescription: String? { "simulated disk failure" }
    }
}

private final class ResearchScriptProvider: LLMProvider, @unchecked Sendable {
    var description: String { "scripted research" }
    private let script: @Sendable (LLMRequest) -> [LLMEvent]
    private let lock = NSLock()
    private var saved: [LLMRequest] = []
    var requests: [LLMRequest] { lock.lock(); defer { lock.unlock() }; return saved }
    init(script: @escaping @Sendable (LLMRequest) -> [LLMEvent]) { self.script = script }
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        lock.lock(); saved.append(request); lock.unlock()
        let events = script(request)
        return AsyncThrowingStream { stream in events.forEach { stream.yield($0) }; stream.finish() }
    }
}
