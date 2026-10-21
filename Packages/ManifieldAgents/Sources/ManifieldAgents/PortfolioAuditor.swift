import Foundation
import ManifieldCore

/// Fresh-context check of a proposed portfolio. The planner does not get to certify its own
/// diversity or adversarial coverage: this pass sees the target, observed recognition/pilot
/// evidence and the proposed mechanisms, but none of the planner's reasoning transcript.
public enum PortfolioAuditor {
    public struct Audit: Equatable, Sendable {
        public var accepted: Bool
        public var falsificationPath: String
        public var gaps: [String]
        public var note: String

        public init(accepted: Bool, falsificationPath: String,
                    gaps: [String] = [], note: String = "") {
            self.accepted = accepted
            self.falsificationPath = falsificationPath
            self.gaps = gaps
            self.note = note
        }

        public var feedback: String {
            var lines = [note, "Falsification path: \(falsificationPath)"]
            if !gaps.isEmpty { lines.append("Gaps:\n" + gaps.map { "- \($0)" }.joined(separator: "\n")) }
            return lines.filter { !$0.isEmpty }.joined(separator: "\n\n")
        }
    }

    public static func systemPrompt(goal: String, contract: SuccessContract?) -> String {
        [
            """
            You are the Portfolio Auditor in Manifield. A separate planner proposed research
            routes. Judge the activated portfolio in fresh context; do not redesign it and do
            not reward it for sounding comprehensive.

            There is no preferred route count and no mandatory role. One excellent route can
            pass. Many routes can fail if they duplicate one mechanism or have no actionable
            payoff. Judge what the routes actually do, not their labels.

            This is a prospective planning gate, not a review of completed research. The
            proposed branches have not run yet. Judge whether their mechanisms, decisive tests
            and expected payoffs would cover the request if carried out. Do not require a
            certificate, proof, exact value, citation or other completed finding to exist before
            accepting the plan; those are outputs the routes are being opened to produce. Reject
            a missing or circular planned step, but never reject merely because the planned
            step's result is not already in the evidence digest.

            Accept only when:
            - every activated route has a distinct mechanism and a result that would change a
              research decision;
            - the combined portfolio addresses the user's actual request;
            - it contains a credible way to falsify its leading assumptions or detect that its
              proposed answer is incomplete.

            Adapt falsification to the request. A classification problem need not have a thesis
            to refute: boundary cases, completeness checks and attempts to construct an omitted
            family are adversarial paths. A construction request can test impossibility or hidden
            constraints. A computation can use independent derivation and error bounds. Do not
            demand a dedicated "challenge" branch when an activated route already performs the
            necessary test.

            Report concrete gaps. Never invent extra routes merely to reach a count.
            """,
            ContextAssembly.honestyRules,
            ContextAssembly.researchTargetSection(originalRequest: goal, contract: contract)
        ].joined(separator: "\n\n")
    }

    public static func proposalSection(_ proposal: ApproachProposal) -> String {
        let explicitlyActivated = proposal.approaches.filter(\.activate)
        let active = explicitlyActivated.isEmpty ? proposal.approaches : explicitlyActivated
        let routes = active.enumerated().map { index, route -> String in
            """
            ### \(index + 1). \(route.title)
            Mechanism: \(route.mechanism)
            Prior: \(route.prior)
            Expected payoff: \(route.expectedPayoff)
            Kill criterion: \(route.killCriterion)
            Marked adversarial: \(route.challengesLeadingAnswer ? "yes" : "no")
            """
        }.joined(separator: "\n\n")
        let skipped = proposal.skippedCells.isEmpty ? "none recorded" : proposal.skippedCells
            .map { "- \($0.cell): \($0.why)" }.joined(separator: "\n")
        return """
        Audit boundary: these are proposed routes, not completed findings. No activated branch
        has run yet; assess the coverage of the work they commit to doing.

        Proposed activated portfolio (\(active.count) route(s)):

        \(routes.isEmpty ? "(none)" : routes)

        Deliberately skipped:
        \(skipped)
        """
    }

    public static func audit(
        runner: AgentRunner,
        goal: String,
        contract: SuccessContract?,
        proposal: ApproachProposal,
        evidenceDigest: String = "",
        thinking: ThinkingLevel = .off,
        programID: String = "",
        record: RecordTurn? = nil,
        onActivity: @escaping @Sendable (AgentActivity) -> Void = { _ in }
    ) async throws -> Audit {
        let signals = PortfolioAuditSignals()
        var message = proposalSection(proposal)
        if !evidenceDigest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            message += "\n\nObserved before portfolio design:\n\n\(evidenceDigest)"
        }
        let config = AgentConfig(
            systemPrompt: SystemPrompt(systemPrompt(goal: goal, contract: contract)),
            tools: [ReportPortfolioAuditTool(signals: signals)],
            maxIterations: 3,
            thinking: thinking)
        _ = try await runRecordedTurn(
            runner: runner, config: config, history: [.user(message)],
            programID: programID, role: .portfolioAudit,
            title: "Independent portfolio coverage audit", record: record,
            outcome: { _ in
                guard let audit = signals.audit else { return "no audit reported" }
                return audit.accepted ? "accepted — \(audit.falsificationPath.prefix(160))"
                    : "rejected — \(audit.gaps.joined(separator: "; ").prefix(180))"
            },
            onActivity: onActivity)
        return signals.audit ?? Audit(
            accepted: false, falsificationPath: "",
            gaps: ["The auditor ended without reporting a coverage decision."],
            note: "No portfolio audit was produced.")
    }
}

private final class PortfolioAuditSignals: @unchecked Sendable {
    private let lock = NSLock()
    private var _audit: PortfolioAuditor.Audit?
    var audit: PortfolioAuditor.Audit? { lock.lock(); defer { lock.unlock() }; return _audit }
    func set(_ audit: PortfolioAuditor.Audit) { lock.lock(); _audit = audit; lock.unlock() }
}

private struct ReportPortfolioAuditTool: AgentTool {
    let signals: PortfolioAuditSignals

    var spec: ToolSpec {
        ToolSpec(
            name: "report_portfolio_audit",
            description: "Accept or reject the activated portfolio on actual coverage, with its concrete falsification/completeness path and any gaps. Route count and role labels are not criteria.",
            inputSchemaJSON: #"{"type":"object","properties":{"accepted":{"type":"boolean"},"falsification_path":{"type":"string","description":"The concrete route/test that could disprove the leading assumptions or expose incompleteness"},"gaps":{"type":"array","items":{"type":"string"},"description":"Concrete coverage defects; empty only on acceptance"},"note":{"type":"string","description":"Concise overall ruling"}},"required":["accepted","falsification_path","gaps","note"]}"#)
    }

    func execute(inputJSON: String) async throws -> String {
        let input = jsonObject(inputJSON)
        guard let accepted = input["accepted"] as? Bool else {
            throw ResearchError(message: "missing 'accepted'")
        }
        let path = (input["falsification_path"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let gaps = (input["gaps"] as? [Any] ?? []).compactMap { value -> String? in
            guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return nil }
            return text
        }
        let note = (input["note"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if accepted && path.isEmpty {
            throw ResearchError(message: "an accepted portfolio must name its concrete falsification or completeness path")
        }
        if !accepted && gaps.isEmpty {
            throw ResearchError(message: "a rejected portfolio must name at least one concrete gap")
        }
        signals.set(.init(accepted: accepted, falsificationPath: path, gaps: gaps, note: note))
        return accepted ? "Portfolio coverage accepted. End your turn."
            : "Portfolio coverage rejected with \(gaps.count) gap(s). End your turn."
    }
}
