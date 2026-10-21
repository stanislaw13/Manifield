import Foundation
import ManifieldCore

/// A brainstormed set of attack strategies awaiting the user's decision. Mirrors the
/// TheoryProposal flow: the tool hands it to the app, the user picks/edits/rejects in
/// a native sheet, and approval writes a PlanDocument.
public struct PlanProposal: Identifiable, Equatable, Sendable {
    public struct Option: Equatable, Sendable {
        public var title: String
        public var summary: String
        public var pros: String
        public var cons: String
        public var tasks: [PlanTask]

        public init(title: String, summary: String, pros: String, cons: String, tasks: [PlanTask]) {
            self.title = title
            self.summary = summary
            self.pros = pros
            self.cons = cons
            self.tasks = tasks
        }
    }

    public let id: UUID
    public let goal: String
    public let options: [Option]
    /// 0-based index of the model's recommended option.
    public let recommendedIndex: Int

    public init(goal: String, options: [Option], recommendedIndex: Int) {
        self.id = UUID()
        self.goal = goal
        self.options = options
        self.recommendedIndex = recommendedIndex
    }
}

struct PlannerError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Task-list rules shared by every plan-proposing tool, so a strategy proposed in one
/// pass and a branch planned in another are validated identically.
enum PlannerValidation {

    /// Parses a tool's `tasks` array into `PlanTask`s, or throws an instructive error.
    /// `context` prefixes messages so the model knows which option failed.
    static func parseTasks(_ rawTasks: [[String: Any]], context: String) throws -> [PlanTask] {
        var tasks: [PlanTask] = []
        for (offset, rawTask) in rawTasks.enumerated() {
            let index = offset + 1
            guard let taskTitle = rawTask["title"] as? String, !taskTitle.isEmpty else {
                throw PlannerError(message: "\(context)task \(index): missing 'title'")
            }
            guard let kind = PlanTask.Kind.parse(rawTask["kind"] as? String ?? "") else {
                throw PlannerError(message: """
                \(context)task \(index): 'kind' must be 'research' or 'prove: <item-id>'
                """)
            }
            let dependsOn = (rawTask["depends_on"] as? [Any] ?? []).compactMap { $0 as? Int }
            if let bad = dependsOn.first(where: { $0 < 1 || $0 >= index }) {
                throw PlannerError(message: """
                \(context)task \(index): depends_on \(bad) must reference an EARLIER task \
                (1..\(index - 1))
                """)
            }
            tasks.append(PlanTask(
                index: index,
                title: taskTitle,
                kind: kind,
                dependsOn: dependsOn,
                reviewGate: rawTask["review"] as? Bool ?? false
            ))
        }
        return tasks
    }
}
