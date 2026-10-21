import CryptoKit
import Foundation
import ManifieldCore

/// One admitted model call. Entries are append-only and intentionally finer-grained than
/// `AgentTurnRecord`: an agent turn may contain a retry or a branch may make several calls
/// before its conversation is archived, but each admission and overrun still needs a durable
/// explanation.
public struct ProgramUsageEntry: Codable, Equatable, Sendable, Identifiable {
    public enum WorkClass: String, Codable, Sendable {
        /// Work that advances an approach: recognition, pilots, planning and branch research.
        /// Classification is diagnostic only; every class spends from the same ceiling.
        case research
        /// Work that protects or closes the run: adjudication, review, routing and synthesis.
        /// Classification is diagnostic only; it owns no reserved slice of the budget.
        case control
    }

    public enum Termination: String, Codable, Sendable {
        case completed
        case toolCompleted = "tool_completed"
        case suspended
        case contextBoundary = "context_boundary"
        case iterationLimit = "iteration_limit"
        case failed
        case cancelled
        case budgetPaused = "budget_paused"
        case assignmentBudgetPaused = "assignment_budget_paused"
        /// Retained so usage ledgers written by the former per-call guard still decode.
        case runawayInterrupted = "runaway_interrupted"
    }

    public var id: String
    public var programID: String
    public var stage: String
    public var subjectID: String?
    public var workClass: WorkClass
    public var provider: String
    public var promptSHA256: String
    public var estimatedInputTokens: Int
    public var inputTokens: Int
    public var outputTokens: Int
    public var cachedInputTokens: Int
    public var cacheWriteInputTokens: Int
    public var reasoningOutputTokens: Int
    public var toolCalls: Int
    public var termination: Termination
    public var error: String?
    public struct Diagnostics: Codable, Equatable, Sendable {
        public var accountingVersion: Int = 2
        public var programLimit: Int
        public var assignmentLimit: Int?
        public var programSpentBefore: Int
        public var assignmentSpentBefore: Int?
        public var systemCharacters: Int
        public var historyCharacters: Int
        public var toolCharacters: Int
        public var invocationID: String
        /// Identifies the application runtime and build without recording environment values,
        /// command-line arguments, paths, provider credentials, or provider-native session IDs.
        public var runtimeIdentity: String?
        public var buildIdentity: String?
        /// Hash of execution knobs and tool contracts. Prompt contents have their own hash on
        /// the entry and are never copied into diagnostics.
        public var configurationSHA256: String?
        /// Application conversation continuity only. This is not a provider request/thread ID.
        public var applicationSessionKey: String?
        public var applicationSessionEpoch: Int?
        /// Estimates are explanatory signals only. They never reject a request because provider
        /// tokenization and the final wire payload may differ from this character-based estimate.
        public var estimatedInputExceedsAssignmentRemainingBy: Int?
        /// Actual provider usage beyond the allocation remaining when this invocation began.
        public var observedAssignmentOvershootTokens: Int?
        public var observedProgramOvershootTokens: Int?

        public init(
            programLimit: Int, assignmentLimit: Int?, programSpentBefore: Int,
            assignmentSpentBefore: Int?, systemCharacters: Int, historyCharacters: Int,
            toolCharacters: Int, invocationID: String, runtimeIdentity: String? = nil,
            buildIdentity: String? = nil, configurationSHA256: String? = nil,
            applicationSessionKey: String? = nil, applicationSessionEpoch: Int? = nil,
            estimatedInputExceedsAssignmentRemainingBy: Int? = nil,
            observedAssignmentOvershootTokens: Int? = nil,
            observedProgramOvershootTokens: Int? = nil
        ) {
            self.programLimit = programLimit
            self.assignmentLimit = assignmentLimit
            self.programSpentBefore = programSpentBefore
            self.assignmentSpentBefore = assignmentSpentBefore
            self.systemCharacters = systemCharacters
            self.historyCharacters = historyCharacters
            self.toolCharacters = toolCharacters
            self.invocationID = invocationID
            self.runtimeIdentity = runtimeIdentity
            self.buildIdentity = buildIdentity
            self.configurationSHA256 = configurationSHA256
            self.applicationSessionKey = applicationSessionKey
            self.applicationSessionEpoch = applicationSessionEpoch
            self.estimatedInputExceedsAssignmentRemainingBy = estimatedInputExceedsAssignmentRemainingBy
            self.observedAssignmentOvershootTokens = observedAssignmentOvershootTokens
            self.observedProgramOvershootTokens = observedProgramOvershootTokens
        }
    }
    public var diagnostics: Diagnostics?
    public var startedAt: Date
    public var endedAt: Date

    public var actualTokens: Int { inputTokens + outputTokens }
    public init(
        id: String = UUID().uuidString,
        programID: String,
        stage: String,
        subjectID: String? = nil,
        workClass: WorkClass,
        provider: String,
        promptSHA256: String,
        estimatedInputTokens: Int,
        inputTokens: Int,
        outputTokens: Int,
        cachedInputTokens: Int = 0,
        cacheWriteInputTokens: Int = 0,
        reasoningOutputTokens: Int = 0,
        toolCalls: Int = 0,
        termination: Termination,
        error: String? = nil, diagnostics: Diagnostics? = nil,
        startedAt: Date,
        endedAt: Date = Date()
    ) {
        self.id = id
        self.programID = programID
        self.stage = stage
        self.subjectID = subjectID
        self.workClass = workClass
        self.provider = provider
        self.promptSHA256 = promptSHA256
        self.estimatedInputTokens = max(0, estimatedInputTokens)
        self.inputTokens = max(0, inputTokens)
        self.outputTokens = max(0, outputTokens)
        self.cachedInputTokens = max(0, cachedInputTokens)
        self.cacheWriteInputTokens = max(0, cacheWriteInputTokens)
        self.reasoningOutputTokens = max(0, reasoningOutputTokens)
        self.toolCalls = max(0, toolCalls)
        self.termination = termination
        self.error = error
        self.diagnostics = diagnostics
        self.startedAt = startedAt
        self.endedAt = endedAt
    }
}

/// Totals shown for a persistent program. Older/front-half planning calls may survive only in
/// `planningTokensUsed`; keep that spend visible without pretending an input/output split that
/// the missing per-call ledger can no longer establish.
public struct ProgramUsageSummary: Equatable, Sendable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var cachedInputTokens: Int
    public var earlierPlanningTokens: Int

    public var ledgerTokens: Int { inputTokens + outputTokens }
    public var totalTokens: Int { ledgerTokens + earlierPlanningTokens }

    public init(inputTokens: Int = 0, outputTokens: Int = 0,
                cachedInputTokens: Int = 0, earlierPlanningTokens: Int = 0) {
        self.inputTokens = max(0, inputTokens)
        self.outputTokens = max(0, outputTokens)
        self.cachedInputTokens = max(0, cachedInputTokens)
        self.earlierPlanningTokens = max(0, earlierPlanningTokens)
    }
}

public enum ProgramUsageError: LocalizedError, Equatable, Sendable {
    case budgetReached(used: Int, limit: Int)
    case usageUnavailable(provider: String)

    public var errorDescription: String? {
        switch self {
        case .usageUnavailable(let provider):
            return "\(provider) completed tool work without reporting its token usage. The work is saved, but accounting is incomplete. Research paused rather than treating missing usage as zero."
        case .budgetReached(let used, let limit):
            return "The program reached its \(limit)-token ceiling at \(used) tokens. "
                + "Add tokens to continue."
        }
    }
}

/// A direct worker exhausted its allocation; the shared program may still buy other work.
public struct AssignmentUsageError: LocalizedError, Equatable, Sendable {
    public let used: Int
    public let limit: Int
    public var errorDescription: String? {
        "The assignment reached its \(limit)-token allocation at \(used) tokens. "
            + "Preserve the partial work; the director must decide whether to allocate more work."
    }
}

/// The one shared meter for every model call in a planning session or running program.
///
/// Completed spend and live usage from every active call count toward the same ceiling. Work
/// classes remain on ledger entries for diagnostics, but no stage owns a percentage and no
/// estimate can stop a call before actual usage reaches the user's limit. When concurrent
/// calls collectively reach the ceiling they are all interrupted and surface the same
/// resumable `budgetReached` pause.
public actor ProgramUsageBudget {
    public struct Call: Sendable, Equatable {
        public let id: String
    }

    public let totalBudget: Int
    private var spentTokens: Int
    private struct ActiveCall: Sendable {
        var actualTokens: Int
        let pause: @Sendable (_ used: Int, _ limit: Int) -> Void
    }
    private var activeCalls: [String: ActiveCall] = [:]

    public init(totalBudget: Int, initialSpent: Int = 0) {
        self.totalBudget = max(0, totalBudget)
        self.spentTokens = max(0, initialSpent)
    }

    public init(limit: ResearchLimit, initialSpent: Int = 0) {
        self.totalBudget = limit.runnerValue
        self.spentTokens = max(0, initialSpent)
    }

    public func beginCall(
        pause: @escaping @Sendable (_ used: Int, _ limit: Int) -> Void
    ) throws -> Call {
        let used = totalUsed
        guard used < totalBudget else {
            throw ProgramUsageError.budgetReached(used: used, limit: totalBudget)
        }
        let call = Call(id: UUID().uuidString)
        activeCalls[call.id] = ActiveCall(actualTokens: 0, pause: pause)
        return call
    }

    /// Replaces this call's last live count with its new cumulative count. Provider usage
    /// events are normalized to deltas before they reach `ProgramUsageMeter`; the runner sends
    /// their cumulative sum here so delayed reports can never double-charge a call.
    public func report(_ call: Call, actualTokens: Int) {
        guard var active = activeCalls[call.id] else { return }
        active.actualTokens = max(active.actualTokens, max(0, actualTokens))
        activeCalls[call.id] = active
        pauseAllIfNeeded()
    }

    /// Moves a call's live count into completed spend. Idempotent so a late provider event or
    /// a cancellation race cannot charge the same call twice.
    public func finishCall(_ call: Call, actualTokens: Int) -> Snapshot {
        if let active = activeCalls.removeValue(forKey: call.id) {
            spentTokens += max(active.actualTokens, max(0, actualTokens))
        }
        pauseAllIfNeeded()
        return snapshotValue
    }

    public struct Snapshot: Sendable, Equatable {
        public let spent: Int
        public let active: Int
        public let total: Int
        public var used: Int { spent + active }
        public var reached: Bool { used >= total }
    }

    public func snapshot() -> Snapshot { snapshotValue }

    private var activeTokens: Int {
        activeCalls.values.reduce(0) { $0 + $1.actualTokens }
    }

    private var totalUsed: Int { spentTokens + activeTokens }

    private var snapshotValue: Snapshot {
        Snapshot(spent: spentTokens, active: activeTokens, total: totalBudget)
    }

    private func pauseAllIfNeeded() {
        let used = totalUsed
        guard used >= totalBudget else { return }
        let callbacks = activeCalls.values.map(\.pause)
        for pause in callbacks { pause(used, totalBudget) }
    }
}

public typealias AppendProgramUsage = @Sendable (ProgramUsageEntry) -> Void

/// The app registers one context for the lifetime of a planning/run task. Recorded roles are
/// instrumented automatically by `runRecordedTurn`; branch/prover calls use
/// `ProgramBudgetedRunner` directly because their transcript boundaries are coarser than calls.
public actor ProgramUsageRegistry {
    public static let shared = ProgramUsageRegistry()

    public struct Context: Sendable {
        public let budget: ProgramUsageBudget
        public let append: AppendProgramUsage
        public let limits: ResearchLimits?
    }

    private var contexts: [String: Context] = [:]

    public func register(
        programID: String,
        totalBudget: Int,
        initialSpent: Int = 0,
        limits: ResearchLimits? = nil,
        append: @escaping AppendProgramUsage
    ) {
        guard !programID.isEmpty else { return }
        contexts[programID] = Context(
            budget: ProgramUsageBudget(totalBudget: totalBudget, initialSpent: initialSpent),
            append: append, limits: limits)
    }

    public func context(programID: String) -> Context? { contexts[programID] }

    public func unregister(programID: String) { contexts.removeValue(forKey: programID) }
}

/// Adds one-program accounting and durable diagnostics to an arbitrary runner. Every usage
/// delta is charged to the shared live meter. Reaching the program ceiling interrupts all
/// active calls, but reports a resumable program-budget pause rather than a failed agent turn.
public struct ProgramBudgetedRunner: AgentRunner {
    public let base: AgentRunner
    public let programID: String
    public let stage: String
    public let subjectID: String?
    public let workClass: ProgramUsageEntry.WorkClass
    public let assignmentBudget: ProgramUsageBudget?
    public let requiresAccounting: Bool

    public init(
        base: AgentRunner,
        programID: String,
        stage: String,
        subjectID: String? = nil,
        workClass: ProgramUsageEntry.WorkClass,
        assignmentBudget: ProgramUsageBudget? = nil, requiresAccounting: Bool = false
    ) {
        self.assignmentBudget = assignmentBudget
        self.requiresAccounting = requiresAccounting
        self.base = base
        self.programID = programID
        self.stage = stage
        self.subjectID = subjectID
        self.workClass = workClass
    }

    public var description: String { base.description }

    public func run(
        config: AgentConfig,
        history: [LLMMessage],
        onActivity: @escaping @Sendable (AgentActivity) -> Void
    ) async throws -> AgentTurnResult {
        guard let context = await ProgramUsageRegistry.shared.context(programID: programID) else {
            guard !requiresAccounting else {
                throw ResearchError(message: "Accounting is not registered for program \(programID), assignment \(subjectID ?? "director"), stage \(stage). No provider call was started.")
            }
            return try await base.run(config: config, history: history, onActivity: onActivity)
        }
        var config = config
        if let limits = context.limits {
            // Persistent workbenches already pass their remaining per-run allowance. Other
            // stages inherit the same explicit user setting instead of hidden 8/12/16-call caps.
            if config.sessionKey == nil { config.maxIterations = limits.toolCalls.runnerValue }
            config.stopOnToolEffect = true
        }
        let programBefore = await context.budget.snapshot()
        let assignmentBefore = await assignmentBudget?.snapshot()
        let estimate = Self.estimatedInputTokens(config: config, history: history)
        let assignmentRemaining = assignmentBefore.map { max(0, $0.total - $0.used) }
        let estimatedAssignmentExcess = assignmentRemaining.flatMap { remaining in
            estimate > remaining ? estimate - remaining : nil
        }
        let diagnostics = ProgramUsageEntry.Diagnostics(
            programLimit: programBefore.total, assignmentLimit: assignmentBefore?.total,
            programSpentBefore: programBefore.used, assignmentSpentBefore: assignmentBefore?.used,
            systemCharacters: config.systemPrompt.text.count,
            historyCharacters: history.reduce(0) { $0 + $1.blocks.reduce(0) { $0 + $1.approximateLength } },
            toolCharacters: config.tools.reduce(0) { $0 + $1.spec.name.count + $1.spec.description.count + $1.spec.inputSchemaJSON.count },
            invocationID: UUID().uuidString,
            runtimeIdentity: Self.runtimeIdentity,
            buildIdentity: Self.buildIdentity,
            configurationSHA256: Self.configurationHash(config: config),
            applicationSessionKey: config.sessionKey,
            applicationSessionEpoch: config.sessionKey == nil ? nil : config.sessionEpoch,
            estimatedInputExceedsAssignmentRemainingBy: estimatedAssignmentExcess)

        let cancellation = UsageCancellationBox()
        let call = try await context.budget.beginCall { used, limit in
            cancellation.pauseForBudget(used: used, limit: limit)
        }
        let assignmentCancellation = UsageCancellationBox()
        let assignmentCall: ProgramUsageBudget.Call?
        do {
            assignmentCall = try await assignmentBudget?.beginCall { used, limit in
                assignmentCancellation.pauseForBudget(used: used, limit: limit)
            }
        } catch let ProgramUsageError.budgetReached(used, limit) {
            _ = await context.budget.finishCall(call, actualTokens: 0)
            throw AssignmentUsageError(used: used, limit: limit)
        } catch {
            _ = await context.budget.finishCall(call, actualTokens: 0)
            throw error
        }
        let meter = ProgramUsageMeter()
        let startedAt = Date()
        let priorAdmission = config.beforeProviderCall
        let priorCheckpoint = config.checkpoint
        let synchronize: @Sendable () async throws -> Void = {
            let actual = meter.actualTokens
            await context.budget.report(call, actualTokens: actual)
            if let assignmentCall { await assignmentBudget?.report(assignmentCall, actualTokens: actual) }
            let program = await context.budget.snapshot()
            if program.reached { throw ProgramUsageError.budgetReached(used: program.used, limit: program.total) }
            if let assignment = await assignmentBudget?.snapshot(), assignment.reached {
                throw AssignmentUsageError(used: assignment.used, limit: assignment.total)
            }
        }
        config.beforeProviderCall = { try await priorAdmission?(); try await synchronize() }
        config.checkpoint = { messages in
            // Preserve a completed tool effect before reporting a ceiling.
            try await priorCheckpoint?(messages)
            try await synchronize()
        }
        let effectiveConfig = config

        let operation = Task {
            try await base.run(config: effectiveConfig, history: history) { activity in
                meter.add(activity)
                onActivity(activity)
                if case .usage = activity {
                    let actual = meter.actualTokens
                    Task {
                        await context.budget.report(call, actualTokens: actual)
                        if let assignmentCall {
                            await assignmentBudget?.report(assignmentCall, actualTokens: actual)
                        }
                    }
                }
            }
        }
        cancellation.attach(operation)
        assignmentCancellation.attach(operation)

        let result: AgentTurnResult
        do {
            result = try await withTaskCancellationHandler {
                try await operation.value
            } onCancel: {
                operation.cancel()
            }
        } catch {
            let totals = meter.snapshot()
            let budget = await context.budget.finishCall(
                call, actualTokens: totals.input + totals.output)
            let assignment = if let assignmentCall {
                await assignmentBudget?.finishCall(assignmentCall, actualTokens: totals.input + totals.output)
            } else { nil as ProgramUsageBudget.Snapshot? }
            let termination: ProgramUsageEntry.Termination
            let reportedError: Error
            if let paused = cancellation.budgetPause
                ?? Self.budgetPause(from: error)
                ?? (budget.reached ? (used: budget.used, limit: budget.total) : nil) {
                termination = .budgetPaused
                reportedError = ProgramUsageError.budgetReached(
                    used: paused.used, limit: paused.limit)
            } else if let assignment, assignment.reached {
                termination = .assignmentBudgetPaused
                reportedError = AssignmentUsageError(used: assignment.used, limit: assignment.total)
            } else if error is CancellationError {
                termination = .cancelled
                reportedError = error
            } else {
                termination = .failed
                reportedError = error
            }
            context.append(Self.entry(
                programID: programID, stage: stage, subjectID: subjectID,
                workClass: workClass, provider: base.description, config: config, history: history,
                estimate: estimate, totals: totals,
                termination: termination, error: reportedError.localizedDescription,
                startedAt: startedAt, diagnostics: diagnostics))
            throw reportedError
        }

        let totals = meter.snapshot()
        let budget = await context.budget.finishCall(
            call, actualTokens: totals.input + totals.output)
        let assignment = if let assignmentCall {
            await assignmentBudget?.finishCall(assignmentCall, actualTokens: totals.input + totals.output)
        } else { nil as ProgramUsageBudget.Snapshot? }
        if budget.reached {
            let error = ProgramUsageError.budgetReached(used: budget.used, limit: budget.total)
            context.append(Self.entry(
                programID: programID, stage: stage, subjectID: subjectID,
                workClass: workClass, provider: base.description, config: config, history: history,
                estimate: estimate, totals: totals, termination: .budgetPaused,
                error: error.localizedDescription, startedAt: startedAt, diagnostics: diagnostics))
            throw error
        }
        if let assignment, assignment.reached {
            let error = AssignmentUsageError(used: assignment.used, limit: assignment.total)
            context.append(Self.entry(
                programID: programID, stage: stage, subjectID: subjectID,
                workClass: workClass, provider: base.description, config: config, history: history,
                estimate: estimate, totals: totals, termination: .assignmentBudgetPaused,
                error: error.localizedDescription, startedAt: startedAt, diagnostics: diagnostics))
            throw error
        }
        context.append(Self.entry(
            programID: programID, stage: stage, subjectID: subjectID,
            workClass: workClass, provider: base.description, config: config, history: history,
            estimate: estimate, totals: totals,
            termination: totals.hitIterationLimit ? .iterationLimit : result.stop == .toolCompleted ? .toolCompleted
                : result.stop == .suspended ? .suspended : result.stop == .contextBoundary ? .contextBoundary : .completed,
            error: nil, startedAt: startedAt, diagnostics: diagnostics))
        return result
    }

    private static func budgetPause(from error: Error) -> (used: Int, limit: Int)? {
        guard let usageError = error as? ProgramUsageError,
              case .budgetReached(let used, let limit) = usageError else {
            return nil
        }
        return (used, limit)
    }

    private static func entry(
        programID: String,
        stage: String,
        subjectID: String?,
        workClass: ProgramUsageEntry.WorkClass,
        provider: String,
        config: AgentConfig,
        history: [LLMMessage],
        estimate: Int,
        totals: ProgramUsageMeter.Snapshot,
        termination: ProgramUsageEntry.Termination,
        error: String?,
        startedAt: Date, diagnostics: ProgramUsageEntry.Diagnostics? = nil
    ) -> ProgramUsageEntry {
        var diagnostics = diagnostics
        if var detail = diagnostics {
            let actual = totals.input + totals.output
            let programRemaining = max(0, detail.programLimit - detail.programSpentBefore)
            let programOvershoot = actual - programRemaining
            detail.observedProgramOvershootTokens = programOvershoot > 0 ? programOvershoot : nil
            if let limit = detail.assignmentLimit,
               let spent = detail.assignmentSpentBefore {
                let assignmentOvershoot = actual - max(0, limit - spent)
                detail.observedAssignmentOvershootTokens = assignmentOvershoot > 0
                    ? assignmentOvershoot : nil
            }
            diagnostics = detail
        }
        return ProgramUsageEntry(
            programID: programID, stage: stage, subjectID: subjectID,
            workClass: workClass, provider: provider,
            promptSHA256: promptHash(config: config, history: history),
            estimatedInputTokens: estimate,
            inputTokens: totals.input, outputTokens: totals.output,
            cachedInputTokens: totals.cachedInput,
            cacheWriteInputTokens: totals.cacheWriteInput,
            reasoningOutputTokens: totals.reasoningOutput,
            toolCalls: totals.toolCalls, termination: termination, error: error, diagnostics: diagnostics,
            startedAt: startedAt)
    }

    static func estimatedInputTokens(config: AgentConfig, history: [LLMMessage]) -> Int {
        let historyCharacters = history.reduce(0) { total, message in
            total + message.blocks.reduce(0) { $0 + $1.approximateLength }
        }
        let toolCharacters = config.tools.reduce(0) { total, tool in
            total + tool.spec.name.count + tool.spec.description.count + tool.spec.inputSchemaJSON.count
        }
        return max(1, (config.systemPrompt.text.count + historyCharacters + toolCharacters + 3) / 4)
    }

    static func promptHash(config: AgentConfig, history: [LLMMessage]) -> String {
        var data = Data(config.systemPrompt.text.utf8)
        if let encoded = try? JSONEncoder().encode(history) { data.append(encoded) }
        for tool in config.tools {
            data.append(Data(tool.spec.name.utf8))
            data.append(Data(tool.spec.description.utf8))
            data.append(Data(tool.spec.inputSchemaJSON.utf8))
        }
        data.append(Data("\(config.maxIterations)|\(config.maxTokens)|\(config.thinking.rawValue)".utf8))
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func configurationHash(config: AgentConfig) -> String {
        var data = Data("iterations=\(config.maxIterations)|tokens=\(config.maxTokens)|thinking=\(config.thinking.rawValue)|stopEffect=\(config.stopOnToolEffect)|context=\(config.contextTokenThreshold.map(String.init) ?? "none")|sessionEpoch=\(config.sessionEpoch)".utf8)
        for tool in config.tools {
            data.append(Data("|\(tool.spec.name)|\(tool.spec.description)|\(tool.spec.inputSchemaJSON)".utf8))
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static var runtimeIdentity: String {
        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        let architecture = "unknown"
        #endif
        return "\(ProcessInfo.processInfo.operatingSystemVersionString);arch=\(architecture)"
    }

    private static var buildIdentity: String {
        let bundle = Bundle.main
        let identifier = bundle.bundleIdentifier ?? "unbundled"
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return "\(identifier);version=\(version ?? "unknown");build=\(build ?? "unknown");executableSHA256=\(executableDigest)"
    }
    private static let executableDigest: String = {
        guard let url = Bundle.main.executableURL, let bytes = try? Data(contentsOf: url, options: .mappedIfSafe) else { return "unavailable" }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }()
}

private final class ProgramUsageMeter: @unchecked Sendable {
    struct Snapshot: Sendable {
        let input: Int
        let output: Int
        let cachedInput: Int
        let cacheWriteInput: Int
        let reasoningOutput: Int
        let toolCalls: Int
        let hitIterationLimit: Bool
    }

    private let lock = NSLock()
    private var input = 0
    private var output = 0
    private var cachedInput = 0
    private var cacheWriteInput = 0
    private var reasoningOutput = 0
    private var toolCalls = 0
    private var hitIterationLimit = false

    func add(_ activity: AgentActivity) {
        lock.lock()
        switch activity {
        case .usage(let newInput, let newOutput):
            input += max(0, newInput)
            output += max(0, newOutput)
        case .usageDetails(let details):
            cachedInput += max(0, details.cachedInputTokens)
            cacheWriteInput += max(0, details.cacheWriteInputTokens)
            reasoningOutput += max(0, details.reasoningOutputTokens)
        case .toolStarted:
            toolCalls += 1
        case .iterationLimitReached:
            hitIterationLimit = true
        default:
            break
        }
        lock.unlock()
    }

    var actualTokens: Int {
        lock.lock(); defer { lock.unlock() }
        return input + output
    }

    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(
            input: input, output: output, cachedInput: cachedInput,
            cacheWriteInput: cacheWriteInput, reasoningOutput: reasoningOutput,
            toolCalls: toolCalls, hitIterationLimit: hitIterationLimit)
    }
}

private final class UsageCancellationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var operation: Task<AgentTurnResult, Error>?
    private var cancellationRequested = false
    private var _budgetPause: (used: Int, limit: Int)?

    func attach(_ operation: Task<AgentTurnResult, Error>) {
        lock.lock()
        self.operation = operation
        let shouldCancel = cancellationRequested
        lock.unlock()
        if shouldCancel { operation.cancel() }
    }

    func pauseForBudget(used: Int, limit: Int) {
        lock.lock()
        if _budgetPause == nil { _budgetPause = (used, limit) }
        cancellationRequested = true
        let operation = operation
        lock.unlock()
        operation?.cancel()
    }

    var budgetPause: (used: Int, limit: Int)? {
        lock.lock(); defer { lock.unlock() }
        return _budgetPause
    }
}

// MARK: - Persistence and diagnostics

extension ProjectStore {
    public func usageLedgerURL(programID: String) -> URL {
        programsURL
            .appendingPathComponent(programID, isDirectory: true)
            .appendingPathComponent("usage", isDirectory: true)
    }

    /// UUID filenames make concurrent branch appends independent; unlike a JSON array, a crash
    /// can lose at most the entry being written and can never corrupt earlier accounting.
    public func saveUsageEntry(_ entry: ProgramUsageEntry) throws {
        let directory = usageLedgerURL(programID: entry.programID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let stamp = Int(entry.startedAt.timeIntervalSince1970 * 1_000)
        let name = "\(stamp)-\(entry.id).json"
        try encoder.encode(entry).write(to: directory.appendingPathComponent(name), options: .atomic)
    }

    public func loadUsageLedger(programID: String) -> [ProgramUsageEntry] {
        let directory = usageLedgerURL(programID: programID)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return files.filter { $0.pathExtension == "json" }.compactMap { file in
            guard let data = try? Data(contentsOf: file) else { return nil }
            return try? decoder.decode(ProgramUsageEntry.self, from: data)
        }.sorted { $0.startedAt < $1.startedAt }
    }

    public func usageTokens(programID: String) -> Int {
        loadUsageLedger(programID: programID).reduce(0) { $0 + $1.actualTokens }
    }

    /// One durable total for a program, including every completed/failed/control call. Older
    /// programs may have recorded their planning front half only in `planningTokensUsed`; add
    /// only the portion not already represented by adopted planning-session ledger entries.
    public func usageTokens(program: ResearchProgram) -> Int {
        usageSummary(program: program).totalTokens
    }

    public func usageSummary(program: ResearchProgram) -> ProgramUsageSummary {
        let entries = loadUsageLedger(programID: program.id)
        // Adopted entries retain the provisional planning session as their embedded program id
        // even after their files move into the final program's usage directory. Identity is
        // deliberate here: timestamps are encoded to whole seconds, so a program and its first
        // director call can compare equal and must not be mistaken for planning usage.
        let planningInLedger = entries
            .filter { $0.programID != program.id }
            .reduce(0) { $0 + $1.actualTokens }
        return ProgramUsageSummary(
            inputTokens: entries.reduce(0) { $0 + $1.inputTokens },
            outputTokens: entries.reduce(0) { $0 + $1.outputTokens },
            cachedInputTokens: entries.reduce(0) { $0 + $1.cachedInputTokens },
            earlierPlanningTokens: max(0, program.planningTokensUsed - planningInLedger))
    }

    public func adoptUsageLedger(fromSession sessionID: String, toProgram programID: String) throws {
        let source = usageLedgerURL(programID: sessionID)
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        let destination = usageLedgerURL(programID: programID)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for file in (try? FileManager.default.contentsOfDirectory(
            at: source, includingPropertiesForKeys: nil)) ?? [] {
            let target = destination.appendingPathComponent(file.lastPathComponent)
            if !FileManager.default.fileExists(atPath: target.path) {
                try? FileManager.default.moveItem(at: file, to: target)
            }
        }
        try? FileManager.default.removeItem(at: source.deletingLastPathComponent())
    }
}
