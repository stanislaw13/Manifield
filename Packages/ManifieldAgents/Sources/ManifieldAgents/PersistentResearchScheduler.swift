import Foundation
import ManifieldCore

/// Owns program writes and scheduling. It never makes a model call to choose the next work.
public actor PersistentResearchScheduler {
    public typealias Executor = @Sendable (ResearchAssignment, ResearchProgram, PersistentResearchScheduler) async throws -> AssignmentReport
    public typealias AssignmentUsage = @Sendable (_ assignmentID: String) -> Int
    private var program: ResearchProgram
    private var committed: ResearchProgram
    private var persistenceFailure: String?
    private let save: @Sendable (ResearchProgram) throws -> Void
    private let onChange: @Sendable (ResearchProgram) -> Void
    private let usageForAssignment: AssignmentUsage
    private let execute: Executor
    private var running: [String: Task<Void, Never>] = [:]
    private var stopped = false
    private var started = false
    private var timer: Task<Void, Never>?
    private struct Waiter {
        let after: Int
        let ids: Set<String>
        let continuation: CheckedContinuation<[ResearchProgramEvent], Error>
    }
    private var waiters: [UUID: Waiter] = [:]

    public init(program: ResearchProgram,
                save: @escaping @Sendable (ResearchProgram) throws -> Void,
                onChange: @escaping @Sendable (ResearchProgram) -> Void = { _ in },
                usageForAssignment: @escaping AssignmentUsage = { _ in 0 },
                execute: @escaping Executor) throws {
        guard program.execution?.version == 1 else {
            throw ResearchError(message: "This program has no persistent director execution state.")
        }
        self.program = program; self.committed = program
        self.save = save; self.onChange = onChange
        self.usageForAssignment = usageForAssignment; self.execute = execute
    }

    public func snapshot() -> ResearchProgram { program }
    public func checkHealth() throws {
        if let persistenceFailure { throw ResearchError(message: persistenceFailure) }
    }
    public func checkAssignmentBoundary(_ id: String) throws {
        try checkHealth()
        if hasAcceptedChallenge, let i = index(id),
           program.execution!.assignments[i].targetRevisionID == program.activeTargetRevisionID {
            throw AssignmentReviewPause()
        }
    }
    public func events(after: Int) -> [ResearchProgramEvent] { relevantEvents(after: after, ids: []) }
    public func guideDirector(_ message: String) throws {
        append(.guidance, summary: "User guidance: " + message)
        try persist(); notify()
    }
    public func acknowledgeGuidance(assignmentID: String, messageIDs: [String]) throws {
        guard let i = index(assignmentID) else { throw ResearchError(message: "Unknown guidance recipient.") }
        let known = Set(program.execution!.assignments[i].messages.map(\.id))
        guard Set(messageIDs).isSubset(of: known) else { throw ResearchError(message: "Unknown guidance message.") }
        let old = Set(program.execution!.assignments[i].deliveredMessageIDs ?? [])
        let updated = old.union(messageIDs)
        guard updated != old else { return }
        program.execution!.assignments[i].deliveredMessageIDs = updated.sorted()
        try persist()
    }

    public func start() throws {
        guard !started else { throw ResearchError(message: "This scheduler has already started.") }
        guard program.execution!.resolution == nil else { throw ResearchError(message: "This program is already resolved.") }
        started = true
        // A previous process cannot still own these local executions. Preserve their partial
        // artifacts and let the director explicitly continue; never silently duplicate them.
        for index in program.execution!.assignments.indices {
            if program.execution!.assignments[index].status == .running {
                program.execution!.assignments[index].status = .paused
                program.execution!.assignments[index].reports.append(.init(
                    summary: "Execution was interrupted. Saved work is available for continuation.",
                    stopReason: .interrupted))
                append(.reported, assignmentID: program.execution!.assignments[index].id,
                       summary: "Interrupted assignment has saved partial work.")
            }
        }
        stopped = false
        if program.execution!.startedAt == nil { program.execution!.startedAt = Date() }
        program.status = .active
        try persist()
        if let seconds = program.execution!.limits.elapsedSeconds.value {
            let remaining = max(0, Double(seconds) - Date().timeIntervalSince(program.execution!.startedAt!))
            timer = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: UInt64(min(remaining, 1e9) * 1e9)) }
                catch { return }
                try? await self?.pause("Program elapsed-time limit reached.")
            }
        }
        admit()
    }

    public func dispatch(_ assignment: ResearchAssignment) throws -> ResearchAssignment {
        if let existing = program.execution!.assignments.first(where: { $0.operationID == assignment.operationID }) {
            return existing
        }
        guard !stopped, program.execution!.resolution == nil else {
            throw ResearchError(message: "The program is paused or resolved.")
        }
        guard index(assignment.id) == nil else { throw ResearchError(message: "Assignment ID already exists.") }
        guard assignment.programID == program.id,
              assignment.targetRevisionID == program.activeTargetRevisionID else {
            throw ResearchError(message: "Dispatch must use this program's active target revision.")
        }
        guard !hasAcceptedChallenge else {
            throw ResearchError(message: "Govern the accepted problem challenge before admitting more work.")
        }
        program.execution!.assignments.append(assignment)
        append(.dispatched, assignmentID: assignment.id, summary: assignment.objective,
               operationID: assignment.operationID)
        try persist() // Commit ownership and operation identity before starting the executor.
        admit()
        return assignment
    }

    public func continueAssignment(id: String, message: String, evidenceIDs: [String], operationID: String) throws {
        if program.execution!.events.contains(where: { $0.operationID == operationID }) { return }
        guard !stopped, program.execution!.resolution == nil, !hasAcceptedChallenge else {
            throw ResearchError(message: "Resume the program and govern accepted challenges before continuing work.")
        }
        guard let index = index(id) else { throw ResearchError(message: "Unknown assignment \(id).") }
        guard program.execution!.assignments[index].targetRevisionID == program.activeTargetRevisionID else {
            throw ResearchError(message: "This assignment has an older target. Dispatch work explicitly under the revised target.")
        }
        program.execution!.assignments[index].messages.append(.init(text: message, evidenceIDs: evidenceIDs))
        if running[id] == nil {
            program.execution!.assignments[index].revision += 1
            program.execution!.assignments[index].status = .queued
        }
        append(.guidance, assignmentID: id, summary: message, references: evidenceIDs, operationID: operationID)
        try persist()
        notify(); admit()
    }

    public func stopAssignment(id: String, reason: String, operationID: String) throws {
        if program.execution!.events.contains(where: { $0.operationID == operationID }) { return }
        guard let index = index(id) else { throw ResearchError(message: "Unknown assignment \(id).") }
        program.execution!.assignments[index].status = .stopped
        append(.stopped, assignmentID: id, summary: reason, operationID: operationID)
        try persist()
        running[id]?.cancel()
        notify()
    }

    public func pause(_ reason: String) throws {
        stopped = true; timer?.cancel()
        if program.execution!.resolution != nil {
            for task in running.values { task.cancel() }
            notify(); return // A late usage/cancellation report cannot undo a committed resolution.
        }
        program.status = .paused
        append(.directorPaused, summary: reason)
        try persist()
        for task in running.values { task.cancel() }
        notify()
    }

    public func wait(after: Int, assignmentIDs: [String] = []) async throws -> [ResearchProgramEvent] {
        try checkHealth()
        guard assignmentIDs.allSatisfy({ index($0) != nil }) else { throw ResearchError(message: "Unknown assignment in wait request.") }
        let ids = Set(assignmentIDs)
        let available = relevantEvents(after: after, ids: ids)
        if !available.isEmpty || stopped { return available }
        // An accepted challenge is a director decision point. `admit()` deliberately prevents
        // queued work from starting until it is governed, so waiting here could otherwise sleep
        // forever (especially when a filtered wait hides the challenge's assignment event).
        if let challenge = acceptedChallengeAwaitingGovernance {
            throw governanceRequiredError(challenge)
        }
        if !hasWork(ids) { return available }
        let key = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                waiters[key] = Waiter(after: after, ids: ids, continuation: continuation)
            }
        } onCancel: {
            Task { await self.cancelWait(key) }
        }
    }

    public func publish(_ finding: ProgramFinding) throws {
        if program.findings.contains(where: { $0.id == finding.id }) { return }
        program.findings.append(finding)
        append(.evidence, assignmentID: finding.branchPlanID, summary: finding.statement, references: [finding.id])
        try persist(); notify()
    }

    public func file(_ candidate: SolutionCandidate) throws {
        program.upsertSolution(candidate)
        append(.evidence, assignmentID: candidate.branchPlanID,
               summary: "Solution candidate filed for independent review.", references: [candidate.id])
        try persist(); notify()
    }

    public func file(_ challenge: ProblemChallenge) throws {
        program.upsertChallenge(challenge)
        append(.evidence, assignmentID: challenge.branchPlanID,
               summary: "Problem challenge filed for independent review.", references: [challenge.id])
        try persist(); notify()
    }

    public func reviewed(_ candidate: SolutionCandidate) throws {
        program.upsertSolution(candidate)
        guard [.accepted, .contractRejected, .reviewRejected].contains(candidate.status) else {
            try persist(); return // Recovery checkpoints are not director decision points.
        }
        informRecipients(evidenceID: candidate.id, status: candidate.status.rawValue)
        append(.reviewed, assignmentID: candidate.branchPlanID,
               summary: "Solution candidate: \(candidate.status.rawValue).", references: [candidate.id])
        try persist(); notify()
    }

    public func reviewed(_ challenge: ProblemChallenge) throws {
        program.upsertChallenge(challenge)
        guard [.accepted, .mathematicalRejected, .scopeRejected, .governed].contains(challenge.status) else {
            try persist(); return
        }
        informRecipients(evidenceID: challenge.id, status: challenge.status.rawValue)
        append(.reviewed, assignmentID: challenge.branchPlanID,
               summary: "Problem challenge: \(challenge.status.rawValue).", references: [challenge.id])
        try persist(); notify()
    }

    public func resolve(_ resolution: ProgramResolution) throws {
        guard resolution.targetRevisionID == program.activeTargetRevisionID else {
            throw ResearchError(message: "Resolution does not match the active target.")
        }
        switch resolution.kind {
        case .answered:
            guard resolution.evidenceIDs.contains(where: { id in
                program.solutions.contains { $0.id == id && $0.status == .accepted && $0.targetRevisionID == resolution.targetRevisionID }
            }) else { throw ResearchError(message: "An answer requires an accepted solution for this target revision.") }
        case .invalidTarget:
            guard resolution.evidenceIDs.contains(where: { id in
                program.challenges.contains { $0.id == id && $0.targetRevisionID == resolution.targetRevisionID
                    && $0.mathematicalRuling?.accepted == true && $0.scopeRuling?.accepted == true
                    && $0.scopeRuling?.targetDisposition == .fullInvalidity }
            }) else { throw ResearchError(message: "Invalid-target resolution requires accepted mathematical and scope reviews confirming full invalidity. Partial scope or unresolved conventions must remain open.") }
        case .unresolved: break
        }
        program.execution!.resolution = resolution
        program.status = resolution.kind == .unresolved ? .failed : .done
        stopped = true; timer?.cancel()
        try persist()
        for task in running.values { task.cancel() }
        notify()
    }

    public func govern(challengeID: String, revision: ResearchTargetRevision?,
                       stopIDs: [String], continueIDs: [String], explanation: String) throws {
        guard let position = program.challenges.firstIndex(where: { $0.id == challengeID }),
              program.challenges[position].mathematicalRuling?.accepted == true,
              program.challenges[position].scopeRuling?.accepted == true,
              program.challenges[position].targetRevisionID == program.activeTargetRevisionID else {
            throw ResearchError(message: "Both challenge reviews must accept before governance.")
        }
        guard Set(stopIDs).isDisjoint(with: Set(continueIDs)),
              (stopIDs + continueIDs).allSatisfy({ index($0) != nil }) else {
            throw ResearchError(message: "Use known, disjoint stopped and continuing assignments.")
        }
        let activeIDs = Set(program.execution!.assignments.filter { $0.status == .running || $0.status == .queued }.map(\.id))
        guard activeIDs.isSubset(of: Set(stopIDs + continueIDs)) else {
            throw ResearchError(message: "State an explicit disposition for every active assignment.")
        }
        if let revision {
            guard revision.parentRevisionID == program.activeTargetRevisionID,
                  revision.proposedByChallengeID == challengeID, continueIDs.isEmpty,
                  !program.targetRevisions.contains(where: { $0.id == revision.id }) else {
                throw ResearchError(message: "A revision must belong to this challenge and parent target. Stop old assignments and dispatch new work under the new target.")
            }
            program.targetRevisions.append(revision)
            program.activeTargetRevisionID = revision.id
            append(.targetChanged, summary: explanation, references: [challengeID, revision.id])
        }
        program.challenges[position].status = .governed
        program.challenges[position].governance = .init(applyRevision: revision != nil,
            replacementRequest: revision?.statement, stopBranchPlanIDs: stopIDs,
            replanBranchPlanIDs: [], continueBranchPlanIDs: continueIDs, openNewPortfolio: false,
            rationale: explanation, newTargetRevisionID: revision?.id)
        for id in stopIDs {
            if let i = index(id) { program.execution!.assignments[i].status = .stopped; running[id]?.cancel() }
        }
        for id in continueIDs {
            guard let i = index(id) else { continue }
            program.execution!.assignments[i].messages.append(.init(text: "Challenge governance: " + explanation, evidenceIDs: [challengeID]))
            if running[id] == nil {
                program.execution!.assignments[i].status = .queued
                program.execution!.assignments[i].revision += 1
            }
        }
        try persist(); notify(); admit()
    }

    public func drain() async {
        while let task = running.values.first { await task.value }
    }

    private var acceptedChallengeAwaitingGovernance: ProblemChallenge? {
        program.challenges.first {
            $0.status == .accepted && $0.governance == nil
                && $0.targetRevisionID == program.activeTargetRevisionID
        }
    }
    private var hasAcceptedChallenge: Bool { acceptedChallengeAwaitingGovernance != nil }
    private func governanceRequiredError(_ challenge: ProblemChallenge) -> ResearchError {
        let disposition = challenge.scopeRuling?.targetDisposition?.rawValue ?? "unspecified scope"
        return ResearchError(message: "Problem challenge \(challenge.id) is accepted: both independent reviews are complete (\(disposition)). Govern or resolve it before waiting; queued assignments cannot start while it awaits governance.")
    }
    private func index(_ id: String) -> Int? { program.execution!.assignments.firstIndex { $0.id == id } }
    private func append(_ kind: ResearchProgramEvent.Kind, assignmentID: String? = nil,
                        summary: String, references: [String] = [], operationID: String? = nil) {
        program.execution!.append(kind, target: program.activeTargetRevisionID, assignmentID: assignmentID,
                                  summary: summary, references: references, operationID: operationID)
    }
    private func informRecipients(evidenceID: String, status: String) {
        for i in program.execution!.assignments.indices {
            let a = program.execution!.assignments[i]
            guard (a.evidenceIDs + a.messages.flatMap(\.evidenceIDs)).contains(evidenceID) else { continue }
            let message = "Evidence \(evidenceID) review status changed to \(status). Read its current ruling before relying on it."
            guard !a.messages.contains(where: { $0.text == message }) else { continue }
            program.execution!.assignments[i].messages.append(.init(text: message, evidenceIDs: [evidenceID]))
        }
    }
    private func persist() throws {
        try checkHealth()
        program.updated = Date()
        do { try save(program); committed = program; onChange(program) }
        catch {
            persistenceFailure = "Research stopped because its state could not be saved: " + error.localizedDescription
            program = committed; program.status = .paused; stopped = true; timer?.cancel()
            for task in running.values { task.cancel() }
            notify()
            throw ResearchError(message: persistenceFailure!)
        }
    }

    private func admit() {
        guard !stopped, !hasAcceptedChallenge, program.execution!.resolution == nil else { return }
        while running.count < program.maxConcurrentBranches,
              let assignment = program.execution!.assignments.first(where: { $0.status == .queued && $0.targetRevisionID == program.activeTargetRevisionID }) {
            guard let index = index(assignment.id) else { return }
            program.execution!.assignments[index].status = .running
            append(.started, assignmentID: assignment.id, summary: assignment.objective)
            do { try persist() } catch { stopped = true; notify(); return }
            let snapshot = program
            running[assignment.id] = Task { [execute] in
                do {
                    let report = try await execute(assignment, snapshot, self)
                    self.finished(assignment.id, report: report)
                } catch {
                    let reason: AssignmentReport.StopReason
                    if case ProgramUsageError.usageUnavailable = error { reason = .error }
                    else if error is ProgramUsageError || error is AssignmentUsageError { reason = .tokenLimit }
                    else if error is AssignmentReviewPause { reason = .review }
                    else if error is CancellationError { reason = .interrupted }
                    else { reason = .error }
                    if error is ProgramUsageError { try? self.pause(error.localizedDescription) }
                    self.finished(assignment.id, report: .init(summary: error.localizedDescription, stopReason: reason,
                        tokensUsed: (error as? AssignmentUsageError)?.used ?? 0))
                }
            }
        }
    }

    private func finished(_ id: String, report: AssignmentReport) {
        running.removeValue(forKey: id)
        // A failed save rolls `program` back to the last committed value and cancels all
        // executors. Their cancellation callbacks must not mutate that recovered snapshot.
        guard persistenceFailure == nil else { return }
        guard let index = index(id) else { return }
        var report = report
        // The executor can be cancelled or throw after its budgeted runner has already
        // persisted usage, before its normal return path has a chance to populate the report.
        // The append-only ledger is authoritative for cumulative assignment spend.
        report.tokensUsed = max(report.tokensUsed, usageForAssignment(id))
        report.findingIDs = program.findings.filter { $0.branchPlanID == id }.map(\.id)
        report.solutionIDs = program.solutions.filter { $0.branchPlanID == id }.map(\.id)
        report.challengeIDs = program.challenges.filter { $0.branchPlanID == id }.map(\.id)
        program.execution!.assignments[index].reports.append(report)
        if program.execution!.assignments[index].status != .stopped {
            program.execution!.assignments[index].status = report.stopReason == .completed ? .finished : .paused
            let delivered = Set(program.execution!.assignments[index].deliveredMessageIDs ?? [])
            if !stopped, program.execution!.assignments[index].messages.contains(where: { !delivered.contains($0.id) }) {
                program.execution!.assignments[index].status = .queued
                program.execution!.assignments[index].revision += 1
            }
        }
        append(.reported, assignmentID: id, summary: report.summary,
               references: report.itemIDs + report.findingIDs + report.solutionIDs + report.challengeIDs)
        do { try persist() } catch { stopped = true }
        notify(); admit()
    }

    private func hasWork(_ ids: Set<String>) -> Bool {
        program.execution!.assignments.contains {
            (ids.isEmpty || ids.contains($0.id)) && ($0.status == .running || $0.status == .queued)
        }
    }
    private func relevantEvents(after: Int, ids: Set<String>) -> [ResearchProgramEvent] {
        Array(program.execution!.events.lazy.filter {
            $0.sequence > after && $0.kind != .started && $0.kind != .dispatched
                && (ids.isEmpty || $0.assignmentID == nil || ids.contains($0.assignmentID!))
        }.prefix(50)).map { event in
            var compact = event
            compact.summary = String(event.summary.prefix(1500))
            compact.references = Array(event.references.prefix(50))
            return compact
        }
    }
    private func notify() {
        // Copy the keys before removing entries. Mutating a Dictionary while iterating it is
        // not a supported collection operation and can otherwise make simultaneous wakeups
        // intermittent.
        for id in Array(waiters.keys) {
            guard let waiter = waiters[id] else { continue }
            if let persistenceFailure {
                waiters.removeValue(forKey: id)
                waiter.continuation.resume(throwing: ResearchError(message: persistenceFailure))
                continue
            }
            let events = relevantEvents(after: waiter.after, ids: waiter.ids)
            if !events.isEmpty || stopped {
                waiters.removeValue(forKey: id); waiter.continuation.resume(returning: events)
            } else if let challenge = acceptedChallengeAwaitingGovernance {
                waiters.removeValue(forKey: id)
                waiter.continuation.resume(throwing: governanceRequiredError(challenge))
            } else if !hasWork(waiter.ids) {
                waiters.removeValue(forKey: id); waiter.continuation.resume(returning: events)
            }
        }
    }
    private func cancelWait(_ id: UUID) { waiters.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError()) }
}

public struct AssignmentReviewPause: LocalizedError, Sendable {
    public init() {}
    public var errorDescription: String? { "An accepted problem challenge awaits director governance. Work paused at a safe boundary." }
}
