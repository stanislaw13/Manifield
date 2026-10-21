import Foundation
import ManifieldCore

/// One agent turn, kept verbatim.
///
/// Before this existed the system threw away almost everything it thought. A branch's
/// conversation lived in its run record and was **set to nil** at every compaction, so a long
/// branch permanently lost its reasoning several times over. The pilots and the statement audit
/// lived in a planning controller and died with `reset()`. The director, the planners, the
/// reviewers and the adjudicators wrote nothing at all — only the ruling they returned. The
/// live log was one 24 000-character string, every branch interleaved, gone at quit.
///
/// The judging agents run on deliberately thin context, so what they were looking at when they
/// ruled is not reconstructible from anything else; the same holds for a pilot, which is defined
/// by having seen none of the others. Keeping the turn is the only way those stay answerable.
///
/// Turns are immutable once written and are never read back into a prompt — this is a record for
/// people, not context for models.
public struct AgentTurnRecord: Codable, Equatable, Sendable, Identifiable {

    /// Which agent produced the turn. Drives grouping and the reader's framing, and is stored
    /// as a string so an unknown role from a newer build reads as `.other` rather than
    /// failing the whole file.
    public enum Role: String, Codable, Sendable, CaseIterable {
        case goalFormalization = "goal_formalization"
        case statementAudit = "statement_audit"
        case contractDraft = "contract_draft"
        case recognition
        case pilotSelect = "pilot_select"
        case pilot
        case portfolio
        case portfolioAudit = "portfolio_audit"
        case branchPlan = "branch_plan"
        /// One stretch of a branch's conversation, ended by a compaction or by the leg stopping.
        case branchLeg = "branch_leg"
        case replan
        case review
        case assemblyReview = "assembly_review"
        case findingAdjudication = "finding_adjudication"
        case contractAdjudication = "contract_adjudication"
        case challengeMathReview = "challenge_math_review"
        case challengeScopeReview = "challenge_scope_review"
        case routing
        case directorVerdict = "director_verdict"
        case synthesis
        case other

        public var displayName: String {
            switch self {
            case .goalFormalization: return "Research goal formalization"
            case .statementAudit: return "Statement audit"
            case .contractDraft: return "Contract drafting"
            case .recognition: return "Recognition"
            case .pilotSelect: return "Pilot selection"
            case .pilot: return "Pilot"
            case .portfolio: return "Portfolio design"
            case .portfolioAudit: return "Portfolio coverage audit"
            case .branchPlan: return "Branch planning"
            case .branchLeg: return "Branch work"
            case .replan: return "Replan"
            case .review: return "Proof review"
            case .assemblyReview: return "Assembly review"
            case .findingAdjudication: return "Finding adjudication"
            case .contractAdjudication: return "Contract adjudication"
            case .challengeMathReview: return "Challenge mathematical review"
            case .challengeScopeReview: return "Challenge scope review"
            case .routing: return "Finding routing"
            case .directorVerdict: return "Director"
            case .synthesis: return "Synthesis"
            case .other: return "Agent turn"
            }
        }

        /// True for the roles that judge rather than generate. Worth marking in the reader:
        /// their thin context is a design decision, and a reader who does not know that will
        /// read the absence of memory and taste as a bug.
        public var judges: Bool {
            switch self {
            case .review, .assemblyReview, .findingAdjudication, .contractAdjudication,
                 .challengeMathReview, .challengeScopeReview,
                 .directorVerdict, .routing, .goalFormalization, .statementAudit,
                 .contractDraft, .pilotSelect,
                 .portfolioAudit:
                return true
            default:
                return false
            }
        }

        /// Budget class for the call that produced this record. Control work gets access to
        /// the protected reserve; generative work cannot consume the tokens needed to check
        /// and report what it found.
        var usageWorkClass: ProgramUsageEntry.WorkClass {
            switch self {
            case .review, .assemblyReview, .findingAdjudication, .contractAdjudication,
                 .challengeMathReview, .challengeScopeReview,
                 .routing, .directorVerdict, .synthesis, .portfolioAudit:
                return .control
            default:
                return .research
            }
        }
    }

    /// Tool results are already on disk as artifacts; a 12 MB stdout in a transcript buys
    /// nothing and makes the file unopenable. Anything longer keeps a head and a tail with the
    /// elided length named, so the reader can see that something was cut and how much.
    public static let maxToolResultLength = 16_000

    public var id: String
    public var programID: String
    public var role: Role
    /// What the turn was about: a plan id for a branch, an item id for a review, a candidate id
    /// for an adjudication, a pilot brief id for a pilot. Nil for program-wide turns.
    public var subjectID: String?
    /// One line naming the turn, for the list. The branch title, the item name, the pilot's
    /// brief title.
    public var title: String
    /// The system prompt the turn ran under. Kept because for a judging agent it is most of
    /// what determined the answer, and because it is the only record of which fragments were
    /// assembled for this role.
    public var systemPrompt: String
    public var messages: [LLMMessage]
    /// What the turn produced, in one line — the verdict, the ruling, the outcome. Lets the
    /// list say what happened without opening anything.
    public var outcome: String
    public var providerKind: String?
    public var model: String?
    public var tokensIn: Int
    public var tokensOut: Int
    public var startedAt: Date
    public var endedAt: Date
    /// Set when the turn ended by a compaction rather than by finishing, so a reader knows the
    /// branch continued in the next leg rather than stopping here.
    public var endedByCompaction: Bool

    public var tokensUsed: Int { tokensIn + tokensOut }
    public var duration: TimeInterval { endedAt.timeIntervalSince(startedAt) }

    public init(id: String = UUID().uuidString,
                programID: String,
                role: Role,
                subjectID: String? = nil,
                title: String,
                systemPrompt: String = "",
                messages: [LLMMessage] = [],
                outcome: String = "",
                providerKind: String? = nil,
                model: String? = nil,
                tokensIn: Int = 0,
                tokensOut: Int = 0,
                startedAt: Date = Date(),
                endedAt: Date = Date(),
                endedByCompaction: Bool = false) {
        self.id = id
        self.programID = programID
        self.role = role
        self.subjectID = subjectID
        self.title = title
        self.systemPrompt = systemPrompt
        self.messages = messages.map(Self.trimmed)
        self.outcome = outcome
        self.providerKind = providerKind
        self.model = model
        self.tokensIn = tokensIn
        self.tokensOut = tokensOut
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.endedByCompaction = endedByCompaction
    }

    /// Lenient decode: a role this build does not know reads as `.other` rather than throwing
    /// away the turn, and every optional field is genuinely optional.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        programID = try c.decode(String.self, forKey: .programID)
        role = Role(rawValue: try c.decodeIfPresent(String.self, forKey: .role) ?? "") ?? .other
        subjectID = try c.decodeIfPresent(String.self, forKey: .subjectID)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        systemPrompt = try c.decodeIfPresent(String.self, forKey: .systemPrompt) ?? ""
        messages = try c.decodeIfPresent([LLMMessage].self, forKey: .messages) ?? []
        outcome = try c.decodeIfPresent(String.self, forKey: .outcome) ?? ""
        providerKind = try c.decodeIfPresent(String.self, forKey: .providerKind)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        tokensIn = try c.decodeIfPresent(Int.self, forKey: .tokensIn) ?? 0
        tokensOut = try c.decodeIfPresent(Int.self, forKey: .tokensOut) ?? 0
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt) ?? Date()
        endedAt = try c.decodeIfPresent(Date.self, forKey: .endedAt) ?? startedAt
        endedByCompaction = try c.decodeIfPresent(Bool.self, forKey: .endedByCompaction) ?? false
    }

    /// Caps oversized tool results in place. Applied on the way in, so nothing downstream has
    /// to remember to do it and a turn can never be written at its full unbounded size.
    static func trimmed(_ message: LLMMessage) -> LLMMessage {
        var message = message
        message.blocks = message.blocks.map { block in
            guard case .toolResult(let id, let content, let isError) = block,
                  content.count > maxToolResultLength else { return block }
            let keep = maxToolResultLength / 2
            let elided = content.count - 2 * keep
            return .toolResult(
                toolUseID: id,
                content: String(content.prefix(keep))
                    + "\n\n… \(elided) characters elided — the full output is in this run's artifacts …\n\n"
                    + String(content.suffix(keep)),
                isError: isError)
        }
        return message
    }
}

/// Writes a finished turn to the transcript store. Nil wherever there is no program to write
/// under — a standalone plan, a package test — which is what keeps recording optional rather
/// than something every call site has to arrange.
public typealias RecordTurn = @Sendable (AgentTurnRecord) -> Void

/// Runs one agent turn and writes it down.
///
/// Every role agent is `AgentLoop` with a different prompt and toolset, so this is the one place
/// that has to know how to record. The loop itself deliberately does not: it has no idea which
/// role it is serving, what the turn was about, or what counts as its outcome — all of which are
/// the caller's knowledge and all of which are what make the record readable afterwards.
///
/// Usage is accumulated by wrapping the activity callback rather than asking the caller to
/// report it, because a caller that forgets leaves a turn claiming it cost nothing.
public func runRecordedTurn(
    runner: AgentRunner,
    config: AgentConfig,
    history: [LLMMessage],
    programID: String,
    role: AgentTurnRecord.Role,
    subjectID: String? = nil,
    title: String,
    model: String? = nil,
    record: RecordTurn?,
    outcome: @escaping @Sendable (AgentTurnResult) -> String = { _ in "" },
    onActivity: @escaping @Sendable (AgentActivity) -> Void = { _ in }
) async throws -> AgentTurnResult {
    let effectiveRunner: AgentRunner
    if runner is ProgramBudgetedRunner {
        effectiveRunner = runner
    } else {
        effectiveRunner = ProgramBudgetedRunner(
            base: runner, programID: programID, stage: role.rawValue,
            subjectID: subjectID, workClass: role.usageWorkClass)
    }

    guard let record, !programID.isEmpty else {
        return try await effectiveRunner.run(
            config: config, history: history, onActivity: onActivity)
    }

    let usage = UsageBox()
    let startedAt = Date()
    let write: @Sendable ([LLMMessage], String) -> Void = { messages, outcomeText in
        record(AgentTurnRecord(
            programID: programID, role: role, subjectID: subjectID, title: title,
            systemPrompt: config.systemPrompt.text, messages: messages, outcome: outcomeText,
            model: model, tokensIn: usage.input, tokensOut: usage.output,
            startedAt: startedAt, endedAt: Date()))
    }

    do {
        let result = try await effectiveRunner.run(
            config: config, history: history
        ) { activity in
            usage.add(activity)
            onActivity(activity)
        }
        write(result.transcript, outcome(result))
        return result
    } catch {
        // A turn that failed part-way is the one most worth reading. The history is what the
        // turn was asked, which is the part that survives an error; the error itself becomes
        // the outcome so the list says why there is nothing more.
        if !(error is CancellationError) {
            write(history, "failed — \(error.localizedDescription)")
        }
        throw error
    }
}

/// One turn as the list shows it: everything except the messages, which are the expensive part
/// to load and are wanted only for the one turn actually being read.
public struct AgentTurnSummary: Equatable, Sendable, Identifiable {
    public var id: String
    public var fileName: String
    public var programID: String
    public var role: AgentTurnRecord.Role
    public var subjectID: String?
    public var title: String
    public var outcome: String
    public var model: String?
    public var tokensIn: Int
    public var tokensOut: Int
    public var startedAt: Date
    public var endedAt: Date
    public var endedByCompaction: Bool
    /// Bytes on disk, so a program's transcript weight is visible where it can be acted on.
    public var byteSize: Int

    public var tokensUsed: Int { tokensIn + tokensOut }

    public init(record: AgentTurnRecord, fileName: String, byteSize: Int) {
        self.id = record.id
        self.fileName = fileName
        self.programID = record.programID
        self.role = record.role
        self.subjectID = record.subjectID
        self.title = record.title
        self.outcome = record.outcome
        self.model = record.model
        self.tokensIn = record.tokensIn
        self.tokensOut = record.tokensOut
        self.startedAt = record.startedAt
        self.endedAt = record.endedAt
        self.endedByCompaction = record.endedByCompaction
        self.byteSize = byteSize
    }
}

// MARK: - Store

extension ProjectStore {

    /// Fractional seconds, unlike the manifest's plain `.iso8601`. Turn timestamps drive the
    /// map's time axis and adjacent judging turns routinely land inside the same second, so
    /// truncating to whole seconds would reorder them against their sequence numbers.
    private static func turnCoder() -> (JSONEncoder, JSONDecoder) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(formatter.string(from: date))
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            // Fall back to whole seconds so a file written by any other coder still loads.
            if let date = formatter.date(from: text) { return date }
            return ISO8601DateFormatter().date(from: text) ?? Date()
        }
        return (encoder, decoder)
    }

    /// `programs/<program-id>/turns/`. A directory per program rather than one flat pile:
    /// deleting a program then takes its transcripts with it, and listing one program's turns
    /// does not have to read every other program's.
    public func turnsURL(programID: String) -> URL {
        programsURL
            .appendingPathComponent(programID, isDirectory: true)
            .appendingPathComponent("turns", isDirectory: true)
    }

    /// Appends a turn. Sequence-prefixed so the directory listing is chronological without
    /// opening anything, and so two turns finishing in the same millisecond cannot collide.
    ///
    /// Failures are swallowed by design at the call sites: losing a transcript must never take
    /// down the run that produced it.
    @discardableResult
    public func saveTurn(_ record: AgentTurnRecord) throws -> String {
        let directory = turnsURL(programID: record.programID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sequence = nextTurnSequence(in: directory)
        let name = String(format: "%04d-%@-%@.json", sequence, record.role.rawValue,
                          String(record.id.prefix(8)))
        let (encoder, _) = Self.turnCoder()
        try encoder.encode(record).write(to: directory.appendingPathComponent(name))
        return name
    }

    /// Every turn of a program, oldest first, without their messages.
    ///
    /// Unreadable files are skipped rather than fatal — a half-written turn from a crash must
    /// not make the whole history unopenable, which is the failure mode this store exists to
    /// prevent in the first place.
    public func turnSummaries(programID: String) -> [AgentTurnSummary] {
        let directory = turnsURL(programID: programID)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return [] }
        let (_, decoder) = Self.turnCoder()
        return files
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url),
                      let record = try? decoder.decode(AgentTurnRecord.self, from: data)
                else { return nil }
                return AgentTurnSummary(record: record,
                                        fileName: url.lastPathComponent,
                                        byteSize: data.count)
            }
    }

    public func loadTurn(programID: String, fileName: String) -> AgentTurnRecord? {
        let url = turnsURL(programID: programID).appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let (_, decoder) = Self.turnCoder()
        return try? decoder.decode(AgentTurnRecord.self, from: data)
    }

    /// Total bytes of a program's transcripts, for the readout in Setup. A research program is
    /// worth a lot of disk, but it should never grow without the user being able to see it.
    public func turnsByteSize(programID: String) -> Int {
        let directory = turnsURL(programID: programID)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return files.reduce(0) { total, url in
            total + ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    /// Moves a planning session's turns under the program it became.
    ///
    /// The front half — the statement audit, the contract, the pilots, the portfolio — runs
    /// before any program exists, and a program's id is derived from a title the portfolio pass
    /// has not produced yet. So those turns are written under a provisional session id and
    /// adopted here, at approval. A session the user abandons keeps its directory until it is
    /// swept, which is the right way round: the alternative loses the pilots of every portfolio
    /// somebody looked at and declined.
    public func adoptTurns(fromSession sessionID: String, toProgram programID: String) throws {
        let source = turnsURL(programID: sessionID)
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        let destination = turnsURL(programID: programID)

        guard FileManager.default.fileExists(atPath: destination.path) else {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: source, to: destination)
            try? FileManager.default.removeItem(at: source.deletingLastPathComponent())
            return
        }
        // A program that already has turns is being re-approved; merge rather than clobber.
        for file in (try? FileManager.default.contentsOfDirectory(at: source,
                                                                  includingPropertiesForKeys: nil)) ?? [] {
            let target = destination.appendingPathComponent(file.lastPathComponent)
            if !FileManager.default.fileExists(atPath: target.path) {
                try? FileManager.default.moveItem(at: file, to: target)
            }
        }
        try? FileManager.default.removeItem(at: source.deletingLastPathComponent())
    }

    /// Deletes every transcript of a program. The manifest, the plans and the findings are
    /// untouched — this throws away the reasoning, never the results.
    public func purgeTurns(programID: String) throws {
        let directory = turnsURL(programID: programID)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    /// One past the highest sequence already present, so numbering survives a relaunch. Reading
    /// the directory rather than keeping a counter in memory is what makes that true.
    private func nextTurnSequence(in directory: URL) -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        let highest = files.compactMap { url -> Int? in
            Int(url.lastPathComponent.prefix(4))
        }.max() ?? 0
        return highest + 1
    }
}
