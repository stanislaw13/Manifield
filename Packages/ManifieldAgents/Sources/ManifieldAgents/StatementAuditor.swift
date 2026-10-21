import Foundation
import ManifieldCore

/// Reads the user's problem as a sceptical referee, before anything else sees it.
///
/// It exists because the expensive ambiguity is the one nobody notices: a conjoined goal, a
/// quantifier that reads two ways, a convention the project uses differently from the
/// literature. Caught here it costs one cheap turn; caught after the contract is frozen and
/// three branches are planned against the wrong reading it costs the program.
///
/// Deliberately narrow. It normalizes, exposes and recommends — it does not decide a
/// substantive ambiguity silently, and it does not search external literature. Reaching for a
/// nearby paper here biases the reading toward that paper's terminology and invites swapping
/// the user's formulation for a known related theorem; prior-work and novelty questions belong
/// to a pilot or a later route, after the contract is frozen. Project-local sources are fair
/// game, because resolving the project's own notation is the job.
public enum StatementAuditor {

    /// A reading the statement genuinely admits, and what follows from taking it.
    public struct Ambiguity: Codable, Equatable, Sendable {
        public var reading: String
        public var consequence: String

        public init(reading: String, consequence: String) {
            self.reading = reading
            self.consequence = consequence
        }

        /// One line, for the contract's `ambiguities` and the review sheet.
        public var line: String { "\(reading) — \(consequence)" }
    }

    public struct Audit: Codable, Equatable, Sendable {
        /// The statement with quantifiers, conventions and scope made explicit.
        public var normalizedStatement: String
        /// Which reading the auditor recommends, and why.
        public var recommendedReading: String
        public var ambiguities: [Ambiguity]
        /// Conventions in play that a reader could get wrong (indexing, degeneracy, empty cases).
        public var conventions: [String]

        public init(normalizedStatement: String, recommendedReading: String = "",
                    ambiguities: [Ambiguity] = [], conventions: [String] = []) {
            self.normalizedStatement = normalizedStatement
            self.recommendedReading = recommendedReading
            self.ambiguities = ambiguities
            self.conventions = conventions
        }

        /// What the contract carries forward, so a later disagreement about what was asked has
        /// something to point at.
        public var contractAmbiguities: [String] {
            ambiguities.map(\.line)
        }
    }

    public static func systemPrompt(notation: String, outline: String) -> String {
        var parts = [PromptLibrary.text("statement_auditor")]
        parts.append(ContextAssembly.honestyRules)
        parts.append(ContextAssembly.latexRules)
        if !notation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("Project notation registry:\n\(notation)")
        }
        if !outline.isEmpty { parts.append("Library outline:\n\(outline)") }
        return parts.joined(separator: "\n\n")
    }

    public static func userMessage(problem: String) -> String {
        """
        The problem, exactly as the user wrote it:

        \(problem)

        Audit it now, then call report_statement_reading once.
        """
    }

    /// Runs one audit turn. Nil when the turn produced nothing usable — the caller then drafts
    /// the contract from the user's raw wording rather than from an invented normalization.
    public static func audit(
        runner: AgentRunner,
        problem: String,
        tools: [AgentTool] = [],
        notation: String = "",
        outline: String = "",
        thinking: ThinkingLevel = .off,
        programID: String = "",
        record: RecordTurn? = nil,
        onActivity: @escaping @Sendable (AgentActivity) -> Void = { _ in }
    ) async throws -> Audit? {
        let signals = StatementAuditSignals()
        let config = AgentConfig(
            systemPrompt: SystemPrompt(systemPrompt(notation: notation, outline: outline)),
            tools: tools + [ReportStatementReadingTool(signals: signals)],
            maxIterations: 8,
            thinking: thinking)
        _ = try await runRecordedTurn(
            runner: runner, config: config,
            history: [.user(userMessage(problem: problem))],
            programID: programID, role: .statementAudit,
            title: "How the statement is to be read",
            record: record,
            outcome: { _ in
                guard let audit = signals.audit else { return "no reading was reported" }
                return audit.ambiguities.isEmpty
                    ? "read as: \(audit.recommendedReading.prefix(160))"
                    : "\(audit.ambiguities.count) ambiguity(ies); read as: \(audit.recommendedReading.prefix(120))"
            },
            onActivity: onActivity)
        return signals.audit
    }
}

final class StatementAuditSignals: @unchecked Sendable {
    private let lock = NSLock()
    private var _audit: StatementAuditor.Audit?
    var audit: StatementAuditor.Audit? { lock.lock(); defer { lock.unlock() }; return _audit }
    func set(_ audit: StatementAuditor.Audit) { lock.lock(); _audit = audit; lock.unlock() }
}

struct ReportStatementReadingTool: AgentTool {
    let signals: StatementAuditSignals

    var spec: ToolSpec {
        ToolSpec(
            name: "report_statement_reading",
            description: """
            Record how this problem should be read: the statement with its quantifiers and \
            conventions made explicit, the reading you recommend, every materially different \
            reading you found with what each would change, and the conventions a reader could \
            get wrong. A material ambiguity is one whose readings can produce different
            mathematical answers. Do not resolve one silently. Wording-only or equivalent
            readings are conventions: adopt and record them without pausing the run.
            """,
            inputSchemaJSON: #"""
            {"type":"object","properties":{
            "normalized_statement":{"type":"string","description":"The statement with quantifiers, scope and conventions explicit. Same question, said unambiguously — not a different or easier one."},
            "recommended_reading":{"type":"string","description":"Which reading you recommend and why. Required when you list any ambiguity."},
            "ambiguities":{"type":"array","items":{"type":"object","properties":{
            "reading":{"type":"string","description":"A reading the statement genuinely admits"},
            "consequence":{"type":"string","description":"What taking this reading would change about what counts as an answer"}},
            "required":["reading","consequence"]}},
            "conventions":{"type":"array","items":{"type":"string"},"description":"Conventions in play a reader could get wrong: indexing, degeneracy, empty cases, strictness"}},
            "required":["normalized_statement"]}
            """#
        )
    }

    func execute(inputJSON: String) async throws -> String {
        let input = jsonObject(inputJSON)
        guard let statement = (input["normalized_statement"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !statement.isEmpty else {
            throw ResearchError(message: "missing 'normalized_statement'")
        }

        let ambiguities = (input["ambiguities"] as? [[String: Any]] ?? []).compactMap {
            entry -> StatementAuditor.Ambiguity? in
            guard let reading = (entry["reading"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !reading.isEmpty else {
                return nil
            }
            return StatementAuditor.Ambiguity(
                reading: reading,
                consequence: (entry["consequence"] as? String) ?? "")
        }

        let recommended = (input["recommended_reading"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // An ambiguity reported with no recommendation hands the drafter a fork it cannot
        // resolve either, so the contract would end up picking one silently — which is the
        // failure this whole stage exists to prevent.
        guard ambiguities.isEmpty || !recommended.isEmpty else {
            throw ResearchError(message: """
            REJECTED — you listed \(ambiguities.count) reading(s) the statement admits but did \
            not say which one to use. Whoever drafts the contract will otherwise choose one \
            silently. Call report_statement_reading again with 'recommended_reading' filled in.
            """)
        }

        signals.set(StatementAuditor.Audit(
            normalizedStatement: statement,
            recommendedReading: recommended,
            ambiguities: ambiguities,
            conventions: (input["conventions"] as? [Any] ?? []).compactMap { $0 as? String }))

        return ambiguities.isEmpty
            ? "Reading recorded; no material ambiguity found. End your turn."
            : "Reading recorded with \(ambiguities.count) ambiguity(ies) flagged. End your turn."
    }
}
