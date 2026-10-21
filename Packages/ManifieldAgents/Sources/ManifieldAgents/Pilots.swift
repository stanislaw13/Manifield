import Foundation
import ManifieldCore

/// Independent first attempts, run before any portfolio is designed.
///
/// The evidence is that a single model thinking hard from a precise statement discovers a great
/// deal, and that run-to-run variance is high enough that one sample tells you little. On a
/// cheap model both effects are stronger, not weaker. So: a few short capped attempts from
/// deliberately different angles, none of which sees the others, before paying orchestration
/// cost.
///
/// The angles are an adaptable vocabulary, not a fixed decomposition. Four permanent semantic
/// cases would be the same mistake as a fixed goal-kind taxonomy: depending
/// on the problem the most valuable first attempt may be a computation, a candidate generation,
/// an equality-case analysis, a literature transfer, a variational reformulation, a
/// classification-completeness check or a constructive search. The selector buys only attempts
/// that would change the next decision, and they run blind to each other.
public enum Pilots {

    /// What a pilot is *for*. These labels help describe selected attempts; none is a quota.
    public enum Role: String, CaseIterable, Codable, Sendable, Identifiable {
        /// Go at the answer itself.
        case directAnswer = "direct_answer"
        /// Attack the leading or most obvious answer.
        case challenge
        /// Change the shape of the problem: reformulate, reduce, simplify decisively.
        case reformulation
        /// Whatever this problem rewards that the other three do not reach.
        case open

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .directAnswer: return "Direct answer"
            case .challenge: return "Challenge"
            case .reformulation: return "Reformulation"
            case .open: return "Open"
            }
        }

        /// What a brief in this role has to do, for the selector's schema and its refusals.
        public var charter: String {
            switch self {
            case .directAnswer:
                return "seeks a complete answer to the question as asked"
            case .challenge:
                return "seriously attacks the leading or most obvious answer"
            case .reformulation:
                return "seeks a structural reformulation, decisive simplification, or alternative mechanism"
            case .open:
                return "whatever this problem rewards that the other roles do not reach"
            }
        }
    }

    /// One pilot's assignment: a role, and a directive adapted to this problem.
    public struct Brief: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var role: Role
        public var title: String
        /// Second person, addressed to the pilot. Carries the whole angle.
        public var directive: String

        public init(id: String, role: Role, title: String, directive: String) {
            self.id = id
            self.role = role
            self.title = title
            self.directive = directive
        }
    }

    /// Kept as an empty compatibility surface for callers compiled against the earlier API.
    /// Roles are no longer mandatory; portfolio coverage is judged after the proposal exists.
    public static let requiredRoles: [Role] = []

    /// Coverage failures, as instructive lines. Empty means the set is runnable.
    public static func coverageProblems(_ briefs: [Brief]) -> [String] {
        []
    }

    /// The template a selector adapts, and the fallback when no selection ran. These are the
    /// angles that pay off on most problems; they are a starting point, not the taxonomy.
    public static var defaultBriefs: [Brief] {
        [
            Brief(id: "direct", role: .directAnswer, title: "Direct attempt", directive: """
                Your angle: attack the problem directly. Take the most natural line you can see \
                and push it as far as this budget allows. Say exactly where it stops and what \
                would be needed to get past that point.
                """),
            Brief(id: "negative", role: .challenge, title: "Negative resolution", directive: """
                Your angle: assume the expected answer is WRONG. Pursue whichever way of \
                establishing that would answer the request — a concrete counterexample, a \
                proof that the requested object cannot exist, an obstruction that rules the \
                approach out. Search small cases exhaustively rather than sampling. If the \
                expected answer survives everything you can throw at it, say what the search \
                covered and where it stopped: a bound on where a counterexample cannot be is a \
                real result, and so is a failed impossibility argument that names its own gap.
                """),
            Brief(id: "reduce", role: .reformulation, title: "Reduction and reformulation",
                  directive: """
                Your angle: change the question. Look for an equivalent formulation, a reduction \
                to a better-understood problem, or a generalisation that is easier than the \
                special case. For every equivalence you propose, say whether you proved it, \
                sourced it, or are guessing — an unproved equivalence that gets treated as \
                established is how a program ends up solving a different problem.
                """),
            Brief(id: "adversarial", role: .challenge, title: "Adversarial audit", directive: """
                Your angle: do not try to solve it. Assume someone has already produced the \
                obvious answer, and referee it. Where would that argument be weakest? Which \
                degenerate or boundary cases would it forget? What hidden assumption is it \
                likely resting on, and does the statement actually license it? Name the \
                specific near-miss that someone attacking this problem would produce and \
                mistake for a solution — that is the most useful thing you can hand the \
                planner, because it names the plausible near-miss later checks must attack.
                """)
        ]
    }

    public struct Result: Equatable, Sendable, Identifiable {
        public var brief: Brief
        public var text: String
        public var tokensIn: Int
        public var tokensOut: Int
        public var failure: String?

        public var id: String { brief.id }
        public var succeeded: Bool { failure == nil && !text.isEmpty }

        public init(brief: Brief, text: String, tokensIn: Int = 0, tokensOut: Int = 0,
                    failure: String? = nil) {
            self.brief = brief
            self.text = text
            self.tokensIn = tokensIn
            self.tokensOut = tokensOut
            self.failure = failure
        }
    }

    public static func systemPrompt(
        brief: Brief, contract: SuccessContract?, notation: String, outline: String, memory: String,
        goal: String = ""
    ) -> String {
        var parts = [PromptLibrary.text("pilot_system", ["DIRECTIVE": brief.directive])]
        parts.append(ContextAssembly.honestyRules)
        parts.append(ContextAssembly.mathematicalTaste)
        // The contract comes before the taste and checker framing for the same reason it does
        // in a branch task: what would settle the problem outranks how to work on it.
        let target = goal.isEmpty ? (contract?.statement ?? "") : goal
        if !target.isEmpty {
            parts.append(ContextAssembly.researchTargetSection(
                originalRequest: target, contract: contract))
        }
        parts.append(ContextAssembly.checkerRules)
        parts.append(ContextAssembly.computeEnvironment)
        parts.append(ContextAssembly.latexRules)
        if !memory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(ContextAssembly.memorySection(memory))
        }
        if !notation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("Project notation registry:\n\(notation)")
        }
        if !outline.isEmpty { parts.append("Library outline:\n\(outline)") }
        return parts.joined(separator: "\n\n")
    }

    public static func userMessage(goal: String) -> String {
        """
        The problem:

        \(goal)

        Work it from your assigned angle now, then report what you found.
        """
    }

    /// Runs one pilot. Failures are captured rather than thrown: one angle erroring out must
    /// not cost the others, which are independent by construction.
    public static func run(
        runner: AgentRunner,
        brief: Brief,
        goal: String,
        tools: [AgentTool],
        contract: SuccessContract? = nil,
        notation: String = "",
        outline: String = "",
        memory: String = "",
        maxIterations: Int = 12,
        thinking: ThinkingLevel = .off,
        programID: String = "",
        record: RecordTurn? = nil,
        onActivity: @escaping @Sendable (AgentActivity) -> Void = { _ in }
    ) async throws -> Result {
        let usage = UsageBox()
        let config = AgentConfig(
            systemPrompt: SystemPrompt(systemPrompt(
                brief: brief, contract: contract,
                notation: notation, outline: outline, memory: memory, goal: goal)),
            tools: tools,
            maxIterations: maxIterations,
            thinking: thinking)
        do {
            let result = try await runRecordedTurn(
                runner: runner, config: config,
                history: [.user(userMessage(goal: goal))],
                programID: programID, role: .pilot, subjectID: brief.id,
                title: brief.title, record: record,
                outcome: { result in
                    let text = result.finalText.trimmingCharacters(in: .whitespacesAndNewlines)
                    return text.isEmpty ? "produced nothing" : String(text.prefix(200))
                }
            ) { activity in
                usage.add(activity)
                onActivity(activity)
            }
            return Result(brief: brief,
                          text: result.finalText.trimmingCharacters(in: .whitespacesAndNewlines),
                          tokensIn: usage.input, tokensOut: usage.output)
        } catch is CancellationError {
            return Result(brief: brief, text: "", tokensIn: usage.input, tokensOut: usage.output,
                          failure: "cancelled")
        } catch let error as ProgramUsageError {
            // A shared-ceiling pause governs the session, not just this pilot. Propagate it so
            // the caller stops the pipeline instead of recording an ordinary failed sample and
            // spending more tokens on the remaining pilots.
            throw error
        } catch {
            return Result(brief: brief, text: "", tokensIn: usage.input, tokensOut: usage.output,
                          failure: error.localizedDescription)
        }
    }

    /// Runs the pilots one after another. Sequential on purpose: the providers have no
    /// rate-limit backoff, and a burst of parallel first attempts is the easiest way to trip one.
    public static func runAll(
        runner: AgentRunner,
        briefs: [Brief]? = nil,
        goal: String,
        tools: [AgentTool],
        contract: SuccessContract? = nil,
        notation: String = "",
        outline: String = "",
        memory: String = "",
        maxIterations: Int = 12,
        thinking: ThinkingLevel = .off,
        programID: String = "",
        record: RecordTurn? = nil,
        onPilotStarted: @escaping @Sendable (Brief) -> Void = { _ in },
        onActivity: @escaping @Sendable (AgentActivity) -> Void = { _ in }
    ) async throws -> [Result] {
        var results: [Result] = []
        for brief in briefs ?? defaultBriefs {
            if Task.isCancelled { break }
            onPilotStarted(brief)
            results.append(try await run(
                runner: runner, brief: brief, goal: goal, tools: tools, contract: contract,
                notation: notation, outline: outline, memory: memory,
                maxIterations: maxIterations, thinking: thinking,
                programID: programID, record: record, onActivity: onActivity))
        }
        return results
    }

    /// Pilot output as the planner sees it. Failed pilots are named rather than dropped:
    /// "this angle produced nothing" is itself information about the problem, and silently
    /// omitting it would overstate the coverage.
    public static func digest(_ results: [Result]) -> String {
        guard !results.isEmpty else { return "" }
        let blocks = results.map { result -> String in
            guard result.succeeded else {
                return "### \(result.brief.title)\n(produced nothing — \(result.failure ?? "empty reply"))"
            }
            return "### \(result.brief.title)\n\(result.text)"
        }
        return """
        Independent first attempts at this problem. Each was run in isolation and saw none of \
        the others, so agreement between them is weak evidence and disagreement is worth \
        looking at. Nothing here has been reviewed.

        \(blocks.joined(separator: "\n\n"))
        """
    }
}

/// Thread-safe usage accumulator for a pilot turn.
final class UsageBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _input = 0
    private var _output = 0
    var input: Int { lock.lock(); defer { lock.unlock() }; return _input }
    var output: Int { lock.lock(); defer { lock.unlock() }; return _output }

    func add(_ activity: AgentActivity) {
        guard case .usage(let input, let output) = activity else { return }
        lock.lock(); _input += input; _output += output; lock.unlock()
    }
}
