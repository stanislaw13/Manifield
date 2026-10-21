import Foundation
import ManifieldCore

// MARK: - Knowledge policy

/// What knowledge the Prover may draw on beyond the project and its attached sources.
public enum KnowledgePolicy: String, CaseIterable, Identifiable, Sendable {
    /// Project items + attached sources only; anything else must be left as an explicit gap.
    case restricted
    /// May use well-known established results without waiting for approval; every one is
    /// recorded and proposed afterwards (add to library + cite), for the user to accept.
    case autoExternal = "auto-external"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .restricted: return "Restricted (project + sources only)"
        case .autoExternal: return "Auto (may use well-known results)"
        }
    }
}

/// A well-known result the Prover declared and used (auto mode).
public struct ExternalResult: Equatable, Sendable {
    public let name: String
    public let statement: String
    public let citation: String

    public init(name: String, statement: String, citation: String) {
        self.name = name
        self.statement = statement
        self.citation = citation
    }
}

final class ExternalCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [ExternalResult] = []

    func record(_ result: ExternalResult) {
        lock.lock()
        defer { lock.unlock() }
        if !results.contains(where: { $0.name.caseInsensitiveCompare(result.name) == .orderedSame }) {
            results.append(result)
        }
    }

    var all: [ExternalResult] {
        lock.lock()
        defer { lock.unlock() }
        return results
    }
}

struct UseExternalResultTool: AgentTool {
    let policy: KnowledgePolicy
    let collector: ExternalCollector

    var spec: ToolSpec {
        ToolSpec(
            name: "use_external_result",
            description: "Declare a well-known established theorem (not in the project or attached sources) that you want to use in the proof. Provide its standard name, a precise statement, and the standard citation. Whether use is permitted depends on the run's knowledge policy — obey the tool's response.",
            inputSchemaJSON: #"{"type":"object","properties":{"name":{"type":"string","description":"Standard name, e.g. Hall's marriage theorem"},"statement":{"type":"string","description":"Precise statement in LaTeX/markdown"},"citation":{"type":"string","description":"Standard citation, e.g. Hall (1935)"}},"required":["name","statement","citation"]}"#
        )
    }

    func execute(inputJSON: String) async throws -> String {
        let input = jsonObject(inputJSON)
        guard let name = input["name"] as? String, !name.isEmpty,
              let statement = input["statement"] as? String, !statement.isEmpty else {
            throw AgentError.badResponse("missing 'name' or 'statement'")
        }
        let citation = input["citation"] as? String ?? "unknown"

        switch policy {
        case .restricted:
            return """
            DENIED — this proof runs in restricted mode (project items and attached sources \
            only). Do not use '\(name)'. Either derive what you need from available items, \
            or mark the step as an explicit gap: "(gap: requires \(name))" and continue as \
            far as possible.
            """
        case .autoExternal:
            collector.record(ExternalResult(name: name, statement: statement, citation: citation))
            return """
            Recorded. You may use it now — cite it in the proof text as "(by external: \
            \(name))". It will be reported to the user afterwards and proposed for the \
            library; do not declare it again.
            """
        }
    }
}

// MARK: - Review

public struct ReviewIssue: Equatable, Sendable {
    public let location: String
    public let severity: String   // fatal | gap | minor
    public let description: String

    public init(location: String, severity: String, description: String) {
        self.location = location
        self.severity = severity
        self.description = description
    }
}

public struct ReviewResult: Sendable {
    public enum Verdict: Equatable, Sendable {
        case noErrorsFound
        case issues
    }
    public let verdict: Verdict
    public let issues: [ReviewIssue]

    public init(verdict: Verdict, issues: [ReviewIssue]) {
        self.verdict = verdict
        self.issues = issues
    }
}

/// Pluggable proof checking: the LLM reviewer is implementation #1; a Lean 4 kernel
/// checker slots in behind the same interface later.
public protocol ProofVerifier {
    func review(
        target: TheoryItem,
        proofMarkdown: String,
        onActivity: @escaping @Sendable (AgentActivity) -> Void
    ) async throws -> ReviewResult
}

public struct LLMReviewer: ProofVerifier {
    let runner: AgentRunner
    let tools: [AgentTool]
    let notation: String
    let outline: String
    let thinking: ThinkingLevel
    /// The success contract's not-counted list, when the run has one.
    let exclusions: [String]

    public init(runner: AgentRunner, tools: [AgentTool], notation: String, outline: String,
                thinking: ThinkingLevel = .off, exclusions: [String] = []) {
        self.runner = runner
        self.tools = tools
        self.notation = notation
        self.outline = outline
        self.thinking = thinking
        self.exclusions = exclusions
    }

    public func review(
        target: TheoryItem,
        proofMarkdown: String,
        onActivity: @escaping @Sendable (AgentActivity) -> Void
    ) async throws -> ReviewResult {
        let config = AgentConfig(
            systemPrompt: SystemPrompt(
                ProverPrompts.reviewerSystem(notation: notation, outline: outline,
                                             exclusions: exclusions)),
            tools: tools,
            maxIterations: 10,
            thinking: thinking
        )
        let result = try await runner.run(
            config: config,
            history: [.user(ProverPrompts.reviewRequest(target: target, proof: proofMarkdown))],
            onActivity: onActivity
        )
        return Self.parseVerdict(result.finalText)
    }

    /// Lenient verdict parsing: JSON object anywhere in the reply; unparseable output
    /// becomes an issue (never a silent approval).
    static func parseVerdict(_ text: String) -> ReviewResult {
        guard let json = extractJSONObject(from: text),
              let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let verdict = object["verdict"] as? String else {
            return ReviewResult(verdict: .issues, issues: [ReviewIssue(
                location: "review",
                severity: "gap",
                description: "Reviewer output was not parseable as a verdict. Raw reply begins: \(String(text.prefix(300)))"
            )])
        }
        if verdict == "no-errors-found" {
            return ReviewResult(verdict: .noErrorsFound, issues: [])
        }
        let issues = (object["issues"] as? [[String: Any]] ?? []).map { entry in
            ReviewIssue(
                location: entry["location"] as? String ?? "unspecified",
                severity: entry["severity"] as? String ?? "gap",
                description: entry["description"] as? String ?? "\(entry)"
            )
        }
        return ReviewResult(
            verdict: .issues,
            issues: issues.isEmpty
                ? [ReviewIssue(location: "review", severity: "gap",
                               description: "Reviewer reported issues but listed none.")]
                : issues
        )
    }

    /// First balanced top-level JSON object in the text (respecting strings/escapes).
    static func extractJSONObject(from text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < text.endIndex {
            let char = text[index]
            if escaped {
                escaped = false
            } else if inString {
                if char == "\\" { escaped = true }
                else if char == "\"" { inString = false }
            } else {
                switch char {
                case "\"": inString = true
                case "{": depth += 1
                case "}":
                    depth -= 1
                    if depth == 0 { return String(text[start...index]) }
                default: break
                }
            }
            index = text.index(after: index)
        }
        return nil
    }
}

// MARK: - Prompts

enum ProverPrompts {

    static func proverSystem(
        policy: KnowledgePolicy,
        notation: String,
        outline: String,
        userProfile: String,
        memory: String = "",
        extraSections: [String] = []
    ) -> String {
        let policyText: String
        switch policy {
        case .restricted:
            policyText = PromptLibrary.text("prover_policy_restricted")
        case .autoExternal:
            policyText = PromptLibrary.text("prover_policy_auto")
        }

        var parts = [
            PromptLibrary.text("prover_system"),
            policyText,
            ContextAssembly.mathematicalTaste,
            PromptLibrary.text("prover_output")
        ]
        // A branch's lens applies to its proving too. The reviewer deliberately never
        // receives it — a reviewer sharing the prover's prior defeats the review gate.
        parts.append(contentsOf: extraSections)
        if !MemoryDocument.parse(markdown: memory).isEmpty {
            parts.append(ContextAssembly.memorySection(memory))
        }
        if !userProfile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("About the user (match their style and level): \(userProfile)")
        }
        if !notation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("Project notation registry:\n\(notation)")
        }
        parts.append("Library outline:\n\(outline)")
        return parts.joined(separator: "\n\n")
    }

    static func draftRequest(target: TheoryItem, store: ProjectStore) -> String {
        var text = """
        Prove the following \(target.type.displayName.lowercased()) (id: \(target.id)):

        \(target.statement ?? target.body)
        """
        let deps = target.dependsOn.compactMap { id -> String? in
            guard let dep = store.item(id: id) else { return nil }
            return "- \(dep.id) [\(dep.type.rawValue)]: \(dep.statement ?? dep.name)"
        }
        if !deps.isEmpty {
            text += "\n\nDeclared dependencies (verify and use as needed):\n" + deps.joined(separator: "\n")
        }
        if let existing = target.proof, !existing.isEmpty {
            text += "\n\nA previous draft exists — reuse what is sound, discard what is not:\n\(existing)"
        }
        return text
    }

    static func reviseRequest(target: TheoryItem, proof: String, issues: [ReviewIssue]) -> String {
        """
        Your proof of \(target.id) was reviewed and issues were found. Revise it to address \
        every issue (or, where an issue cannot be fixed, mark the step as an explicit gap). \
        Output the complete revised proof.

        Statement:
        \(target.statement ?? target.body)

        Current proof:
        \(proof)

        Review issues:
        \(issues.map { "- [\($0.severity)] \($0.location): \($0.description)" }.joined(separator: "\n"))
        """
    }

    static func reviewerSystem(notation: String, outline: String,
                               exclusions: [String] = []) -> String {
        var parts = [PromptLibrary.text("reviewer_system")]
        // The contract's not-counted list doubles as the reviewer's checklist of known failure
        // modes — the reviewer is the one context where checking against them costs nothing,
        // because it is already reading the argument line by line.
        if !exclusions.isEmpty {
            parts.append("""
            This run's success contract rules the following out. Each is a specific way an \
            argument can look complete and not be — check the proof against every one, and \
            raise an issue where it matches:

            \(exclusions.map { "- \($0)" }.joined(separator: "\n"))
            """)
        }
        if !notation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("Project notation registry:\n\(notation)")
        }
        parts.append("Library outline:\n\(outline)")
        return parts.joined(separator: "\n\n")
    }

    static func reviewRequest(target: TheoryItem, proof: String) -> String {
        """
        Review this proof of \(target.id) (\(target.type.displayName): \(target.name)).

        Statement:
        \(target.statement ?? target.body)

        Proof under review:
        \(proof)
        """
    }
}

// MARK: - Workbench (prove → review → fix)

/// Orchestrates the autonomous prove→review→fix loop for one target item. Nothing is
/// written to the library — the outcome is delivered as proposals the user confirms.
public final class ProofWorkbench {

    public struct Configuration: Sendable {
        public var policy: KnowledgePolicy
        public var maxRounds: Int
        public var proverThinking: ThinkingLevel
        public var reviewerThinking: ThinkingLevel

        public init(policy: KnowledgePolicy = .autoExternal, maxRounds: Int = 3,
                    proverThinking: ThinkingLevel = .off, reviewerThinking: ThinkingLevel = .off) {
            self.policy = policy
            self.maxRounds = max(1, maxRounds)
            self.proverThinking = proverThinking
            self.reviewerThinking = reviewerThinking
        }
    }

    public enum Event: Sendable {
        case roundStarted(round: Int, of: Int)
        case proverActivity(AgentActivity)
        case reviewStarted
        case reviewerActivity(AgentActivity)
        case verdict(ReviewResult)
    }

    public struct Outcome: Sendable {
        public let finalStatus: ItemStatus
        public let roundsUsed: Int
        public let proposalCount: Int
        public let externalsUsed: [ExternalResult]
        public let outstandingIssues: [ReviewIssue]
    }

    private let runner: AgentRunner
    /// Optionally a different runner for the reviewer (a distinct model reviews less
    /// agreeably than the one that wrote the proof). Defaults to the prover's runner.
    private let reviewerRunner: AgentRunner
    private let store: ProjectStore
    private let attachedSources: [(slug: String, store: ProjectStore)]
    private let extraTools: [AgentTool]
    private let userProfile: String
    private let configuration: Configuration
    /// Research memory for the prover; defaults to the project's. A research branch
    /// points it at its own isolated memory file.
    private let memoryText: @Sendable () -> String
    /// Extra prover system sections (a branch's lens). Never given to the reviewer.
    private let extraSystemSections: [String]
    private let onProposal: @Sendable (TheoryProposal) -> Void
    private let onEvent: @Sendable (Event) -> Void

    public init(
        runner: AgentRunner,
        reviewerRunner: AgentRunner? = nil,
        store: ProjectStore,
        attachedSources: [(slug: String, store: ProjectStore)],
        extraTools: [AgentTool],
        userProfile: String,
        configuration: Configuration,
        memoryText: (@Sendable () -> String)? = nil,
        extraSystemSections: [String] = [],
        onProposal: @escaping @Sendable (TheoryProposal) -> Void,
        onEvent: @escaping @Sendable (Event) -> Void
    ) {
        self.runner = runner
        self.reviewerRunner = reviewerRunner ?? runner
        self.store = store
        self.attachedSources = attachedSources
        self.extraTools = extraTools
        self.userProfile = userProfile
        self.configuration = configuration
        self.memoryText = memoryText ?? { [store] in store.memory }
        self.extraSystemSections = extraSystemSections
        self.onProposal = onProposal
        self.onEvent = onEvent
    }

    public func run(targetID: String) async throws -> Outcome {
        guard let target = store.item(id: targetID) else { throw CoreError.itemNotFound(targetID) }

        let collector = ExternalCollector()
        let readTools = TheoryTools.readOnlyTools(store: store)
            + SourceTools.tools(attached: attachedSources)
            + extraTools
        let proverTools = readTools + [UseExternalResultTool(policy: configuration.policy, collector: collector)]
        let outline = ContextAssembly.outline(items: store.items)

        let reviewer = LLMReviewer(
            runner: reviewerRunner, tools: readTools,
            notation: store.notation, outline: outline,
            thinking: configuration.reviewerThinking
        )

        var proof = ""
        var issues: [ReviewIssue] = []
        var roundsUsed = 0
        let onEvent = self.onEvent

        for round in 1...configuration.maxRounds {
            try Task.checkCancellation()
            roundsUsed = round
            onEvent(.roundStarted(round: round, of: configuration.maxRounds))

            let proverConfig = AgentConfig(
                systemPrompt: SystemPrompt(ProverPrompts.proverSystem(
                    policy: configuration.policy, notation: store.notation,
                    outline: outline, userProfile: userProfile, memory: memoryText(),
                    extraSections: extraSystemSections)),
                tools: proverTools,
                maxIterations: 16,
                thinking: configuration.proverThinking
            )
            let request = round == 1
                ? ProverPrompts.draftRequest(target: target, store: store)
                : ProverPrompts.reviseRequest(target: target, proof: proof, issues: issues)
            let result = try await runner.run(
                config: proverConfig,
                history: [.user(request)]
            ) { activity in onEvent(.proverActivity(activity)) }

            proof = Self.cleanProof(result.finalText)
            guard !proof.isEmpty else { throw AgentError.badResponse("the prover returned an empty proof") }

            onEvent(.reviewStarted)
            let review = try await reviewer.review(target: target, proofMarkdown: proof) { activity in
                onEvent(.reviewerActivity(activity))
            }
            onEvent(.verdict(review))
            if review.verdict == .noErrorsFound {
                issues = []
                break
            }
            issues = review.issues
        }

        // Deliver everything as user-confirmed proposals.
        let externals = collector.all
        var externalIDs: [String] = []
        var proposals: [TheoryProposal] = []
        for external in externals {
            var id = "thm-" + TheoryItem.sanitizeID(external.name)
            if store.item(id: id) != nil { id = store.availableID(for: .theorem, name: external.name) }
            externalIDs.append(id)
            proposals.append(TheoryProposal(action: .create, item: TheoryItem(
                id: id,
                type: .theorem,
                name: external.name,
                status: .source,
                tags: ["external"],
                source: "well-known (model-cited, unverified): \(external.citation)",
                section: "external-results",
                body: "## Statement\n\(external.statement)"
            )))
        }

        var updated = target
        var finalProof = proof
        if !issues.isEmpty {
            finalProof += "\n\n**Outstanding review issues:**\n"
                + issues.map { "- [\($0.severity)] \($0.location): \($0.description)" }.joined(separator: "\n")
        }
        updated.body = Self.replacingProofSection(in: target.body, with: finalProof)
        updated.status = issues.isEmpty ? .reviewedNoErrors : .proofDrafted
        updated.dependsOn = Self.mergedDependencies(
            existing: target.dependsOn, targetID: target.id, proof: proof,
            store: store, attachedSources: attachedSources, externalIDs: externalIDs
        )
        proposals.insert(TheoryProposal(action: .update, item: updated), at: 0)

        for proposal in proposals { onProposal(proposal) }

        return Outcome(
            finalStatus: updated.status,
            roundsUsed: roundsUsed,
            proposalCount: proposals.count,
            externalsUsed: externals,
            outstandingIssues: issues
        )
    }

    // MARK: - Text assembly helpers (unit-tested)

    /// Strips wrappers the model may add despite instructions (code fence, Proof heading).
    static func cleanProof(_ text: String) -> String {
        var proof = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if proof.hasPrefix("```") {
            proof = proof.components(separatedBy: "\n").dropFirst().joined(separator: "\n")
            if let fence = proof.range(of: "\n```", options: .backwards) {
                proof = String(proof[..<fence.lowerBound])
            }
        }
        for heading in ["## Proof", "# Proof", "**Proof.**", "Proof."] where proof.hasPrefix(heading) {
            proof = String(proof.dropFirst(heading.count))
            break
        }
        return proof.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Replaces the `## Proof` section content in a body (or appends one).
    static func replacingProofSection(in body: String, with proof: String) -> String {
        let lines = body.components(separatedBy: "\n")
        var out: [String] = []
        var inProof = false
        var replaced = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("## ") {
                let isProofHeading = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                    .caseInsensitiveCompare("Proof") == .orderedSame
                if isProofHeading {
                    inProof = true
                    replaced = true
                    out.append("## Proof")
                    out.append(proof)
                    continue
                }
                inProof = false
            }
            if !inProof { out.append(line) }
        }
        if !replaced {
            out.append("")
            out.append("## Proof")
            out.append(proof)
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Union of declared deps with ids actually cited in the proof — project ids that
    /// exist, source refs that resolve, and the newly proposed external ids.
    static func mergedDependencies(
        existing: [String],
        targetID: String,
        proof: String,
        store: ProjectStore,
        attachedSources: [(slug: String, store: ProjectStore)],
        externalIDs: [String]
    ) -> [String] {
        var deps = existing
        func add(_ id: String) {
            if id != targetID, !deps.contains(id) { deps.append(id) }
        }

        let pattern = #"(?:([a-z0-9][a-z0-9-]*):)?((?:def|lem|thm|conj|rem)-[a-z0-9][a-z0-9-]*)"#
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let ns = proof as NSString
            for match in regex.matches(in: proof, range: NSRange(location: 0, length: ns.length)) {
                let itemID = ns.substring(with: match.range(at: 2))
                if match.range(at: 1).location != NSNotFound {
                    let slug = ns.substring(with: match.range(at: 1))
                    if let source = attachedSources.first(where: { $0.slug == slug }),
                       source.store.item(id: itemID) != nil {
                        add("\(slug):\(itemID)")
                    }
                } else if store.item(id: itemID) != nil {
                    add(itemID)
                }
            }
        }
        for id in externalIDs { add(id) }
        return deps
    }
}
