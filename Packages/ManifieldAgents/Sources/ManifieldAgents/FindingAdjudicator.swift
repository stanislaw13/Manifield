import Foundation
import ManifieldCore

/// Fresh-context verification of a claimed counterexample, run before the claim is allowed
/// to circulate. The report's verification hierarchy in one turn: the adjudicator sees the
/// exact goal, the claim, and the branch's artifact — never the branch's reasoning — and
/// recomputes rather than re-reads. Its verdict is what replaces the human counterexample
/// gate on unattended runs.
public enum FindingAdjudicator {

    public struct Ruling: Equatable, Sendable {
        public var confirmed: Bool
        /// What was recomputed (confirmed) or precisely what failed (rejected). The branch
        /// reads this on rejection, so it is written to be actionable.
        public var note: String

        public init(confirmed: Bool, note: String) {
            self.confirmed = confirmed
            self.note = note
        }
    }

    public static func systemPrompt(
        goal: String,
        contract: SuccessContract?,
        claim: ProgramFinding,
        artifactText: String?
    ) -> String {
        var parts = [PromptLibrary.text("finding_adjudicator")]
        parts.append(ContextAssembly.honestyRules)
        parts.append(ContextAssembly.researchTargetSection(
            originalRequest: goal, contract: contract))
        var claimLines = ["The claim under adjudication:", "Statement: \(claim.statement)"]
        if !claim.itemIDs.isEmpty {
            claimLines.append("Theory items cited: \(claim.itemIDs.joined(separator: ", "))")
        }
        if let path = claim.artifactPath {
            claimLines.append("Evidence artifact: \(path)")
        }
        parts.append(claimLines.joined(separator: "\n"))
        if let artifactText, !artifactText.isEmpty {
            parts.append("""
            Contents of the cited artifact (the branch's own run — evidence to check, not \
            verification):

            \(artifactText)
            """)
        } else if claim.artifactPath != nil {
            parts.append("The cited artifact could not be read. Treat the claim as having no "
                + "computational evidence and verify from scratch.")
        }
        return parts.joined(separator: "\n\n")
    }

    /// Runs one adjudication turn. `tools` should be read-only theory plus compute — the
    /// adjudicator verifies, it never writes. Returns nil when the turn ended without a
    /// ruling; the caller treats that as "not confirmed" and keeps the human gate.
    public static func adjudicate(
        runner: AgentRunner,
        goal: String,
        contract: SuccessContract?,
        claim: ProgramFinding,
        artifactText: String?,
        tools: [AgentTool],
        thinking: ThinkingLevel = .off,
        programID: String = "",
        record: RecordTurn? = nil,
        onActivity: @escaping @Sendable (AgentActivity) -> Void = { _ in }
    ) async throws -> Ruling? {
        let signals = AdjudicationSignals()
        let config = AgentConfig(
            systemPrompt: SystemPrompt(systemPrompt(
                goal: goal, contract: contract,
                claim: claim, artifactText: artifactText)),
            tools: tools + [ReportAdjudicationTool(signals: signals)],
            maxIterations: 16,
            thinking: thinking)
        _ = try await runRecordedTurn(
            runner: runner, config: config,
            history: [.user("""
            Adjudicate the counterexample claim above: verify it independently, then call \
            report_adjudication with your ruling.
            """)],
            programID: programID, role: .findingAdjudication, subjectID: claim.id,
            title: "Is this finding sound? — \(claim.kind.displayName)",
            record: record,
            outcome: { _ in
                guard let ruling = signals.ruling else { return "no ruling" }
                return (ruling.confirmed ? "confirmed" : "rejected")
                    + " — \(ruling.note.prefix(180))"
            },
            onActivity: onActivity)
        return signals.ruling
    }
}

final class AdjudicationSignals: @unchecked Sendable {
    private let lock = NSLock()
    private var _ruling: FindingAdjudicator.Ruling?
    var ruling: FindingAdjudicator.Ruling? { lock.lock(); defer { lock.unlock() }; return _ruling }
    func set(_ ruling: FindingAdjudicator.Ruling) { lock.lock(); _ruling = ruling; lock.unlock() }
}

struct ReportAdjudicationTool: AgentTool {
    let signals: AdjudicationSignals

    var spec: ToolSpec {
        ToolSpec(
            name: "report_adjudication",
            description: """
            Record your ruling on the counterexample claim and end your turn. 'confirmed' \
            only when you independently verified the object and its contradiction of the \
            goal statement — say what you recomputed. 'rejected' for everything else, \
            including "plausible but unverifiable" — say precisely what failed, because the \
            claiming branch reads your note and gets one chance to repair the claim.
            """,
            inputSchemaJSON: #"{"type":"object","properties":{"verdict":{"type":"string","enum":["confirmed","rejected"]},"note":{"type":"string","description":"Confirmed: what you recomputed and how. Rejected: precisely what failed or could not be verified."}},"required":["verdict","note"]}"#
        )
    }

    func execute(inputJSON: String) async throws -> String {
        let input = jsonObject(inputJSON)
        guard let verdict = input["verdict"] as? String,
              ["confirmed", "rejected"].contains(verdict) else {
            throw ResearchError(message: "verdict must be 'confirmed' or 'rejected'")
        }
        guard let note = (input["note"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty else {
            throw ResearchError(message: "missing 'note' — the ruling is unusable without its reason")
        }
        signals.set(FindingAdjudicator.Ruling(
            confirmed: verdict == "confirmed", note: String(note.prefix(1200))))
        return "Ruling recorded. End your turn."
    }
}
