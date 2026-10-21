import Foundation
import ManifieldCore

/// Adapts the pilot briefs to the problem, between freezing the contract and running the pilots.
///
/// Cheap and narrow by design. It decides what the first attempts should *be* for this problem —
/// a computation, an equality-case analysis, a constructive search — rather than accepting four
/// permanent angles that happen to suit most problems. It is not portfolio planning: it sees no
/// memory, no route vocabulary and no library beliefs, produces no mechanisms, priors or kill
/// criteria, and cannot activate anything. It may select no pilots when recognition already
/// exposed the decisive gap and another blind sample would not change the portfolio.
public enum PilotSelector {

    public static func systemPrompt() -> String {
        var parts = [PromptLibrary.text("pilot_selector", [
            "ROLES": Pilots.Role.allCases.map { "- `\($0.rawValue)` — \($0.charter)" }
                .joined(separator: "\n"),
            "REQUIRED": "No role is mandatory. Choose only attempts with positive information value."
        ])]
        parts.append(ContextAssembly.honestyRules)
        parts.append(ContextAssembly.computeEnvironment)
        parts.append(ContextAssembly.latexRules)
        return parts.joined(separator: "\n\n")
    }

    public static func userMessage(goal: String) -> String {
        """
        The problem:

        \(goal)

        Choose this problem's pilots and call select_pilots once.
        """
    }

    /// Runs one selection turn. An explicit empty selection is respected; the defaults are a
    /// compatibility fallback only when the selector failed to make any decision at all.
    public static func select(
        runner: AgentRunner,
        goal: String,
        contract: SuccessContract?,
        recognitionDigest: String = "",
        thinking: ThinkingLevel = .off,
        programID: String = "",
        record: RecordTurn? = nil,
        onActivity: @escaping @Sendable (AgentActivity) -> Void = { _ in }
    ) async throws -> [Pilots.Brief] {
        let signals = PilotSelectionSignals()
        var system = systemPrompt()
        system += "\n\n" + ContextAssembly.researchTargetSection(
            originalRequest: goal, contract: contract)
        if !recognitionDigest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            system += "\n\n" + """
            A bounded recognition attempt ran before you. Select pilots specifically to verify,
            challenge, or advance what it left unresolved:

            \(recognitionDigest)
            """
        }
        let config = AgentConfig(
            systemPrompt: SystemPrompt(system),
            tools: [SelectPilotsTool(signals: signals)],
            maxIterations: 4,
            thinking: thinking)
        do {
            _ = try await runRecordedTurn(
                runner: runner, config: config,
                history: [.user(userMessage(goal: goal))],
                programID: programID, role: .pilotSelect,
                title: "Which first attempts this problem rewards",
                record: record,
                outcome: { _ in
                    let briefs = signals.briefs
                    return briefs == nil
                        ? "no briefs selected — falling back to the defaults"
                        : briefs!.isEmpty ? "no pilots needed"
                        : briefs!.map(\.title).joined(separator: " · ")
                },
                onActivity: onActivity)
        } catch let error as ProgramUsageError {
            // Reaching the one program ceiling is not a failed selector whose work should be
            // replaced with defaults. Let the planning session stop here so adding tokens can
            // resume it without buying pilots or a portfolio beyond the user's limit.
            throw error
        } catch {
            return Pilots.defaultBriefs
        }
        return signals.briefs ?? Pilots.defaultBriefs
    }
}

final class PilotSelectionSignals: @unchecked Sendable {
    private let lock = NSLock()
    private var _briefs: [Pilots.Brief]?
    var briefs: [Pilots.Brief]? { lock.lock(); defer { lock.unlock() }; return _briefs }
    func set(_ briefs: [Pilots.Brief]) { lock.lock(); _briefs = briefs; lock.unlock() }
}

struct SelectPilotsTool: AgentTool {
    let signals: PilotSelectionSignals

    var spec: ToolSpec {
        ToolSpec(
            name: "select_pilots",
            description: """
            Record exactly the independent first attempts worth buying for this problem. An \
            empty array is a real decision when recognition already supplied the information \
            planning needs. Every selected pilot runs blind to the others.
            """,
            inputSchemaJSON: #"""
            {"type":"object","properties":{
            "pilots":{"type":"array","items":{"type":"object","properties":{
            "role":{"type":"string","enum":["direct_answer","challenge","reformulation","open"]},
            "title":{"type":"string","description":"Three or four words naming the angle"},
            "directive":{"type":"string","description":"The angle, addressed to the pilot in the second person: what to do, and what to report either way"}},
            "required":["role","title","directive"]}}},
            "required":["pilots"]}
            """#
        )
    }

    func execute(inputJSON: String) async throws -> String {
        let input = jsonObject(inputJSON)
        let raw = input["pilots"] as? [[String: Any]] ?? []

        var briefs: [Pilots.Brief] = []
        for (index, entry) in raw.enumerated() {
            guard let roleRaw = entry["role"] as? String,
                  let role = Pilots.Role(rawValue: roleRaw) else {
                throw ResearchError(message: """
                pilot \(index + 1): 'role' must be one of \
                \(Pilots.Role.allCases.map(\.rawValue).joined(separator: ", "))
                """)
            }
            guard let directive = (entry["directive"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !directive.isEmpty else {
                throw ResearchError(message: "pilot \(index + 1): needs a 'directive'")
            }
            let title = (entry["title"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? role.displayName
            briefs.append(Pilots.Brief(
                id: "p\(index + 1)-\(role.rawValue)",
                role: role,
                title: title.isEmpty ? role.displayName : title,
                directive: directive))
        }

        signals.set(briefs)
        return "Selected \(briefs.count) pilots. End your turn."
    }
}
