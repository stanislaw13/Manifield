import Foundation

/// How a research run executes an approved plan.
public enum RunMode: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Fully autonomous: writes theory items directly (within the trust ladder),
    /// updates memory/plan automatically, runs until done or blocked.
    case auto
    /// Pauses after each task for the user to review and redirect.
    case checkpoint

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .auto: return "Auto (run until blocked)"
        case .checkpoint: return "Checkpoint (pause after each task)"
        }
    }
}

public enum PlanStatus: String, Codable, CaseIterable, Sendable {
    case draft, approved, active, paused, done, abandoned
    /// The approach was tried and did not work. Distinct from `abandoned` (dropped without
    /// a verdict) and from `done` (ran to completion): a failed branch is a real result,
    /// and the difference is what the next program needs to read off the archive.
    case failed

    public var displayName: String {
        switch self {
        case .draft: return "Draft"
        case .approved: return "Approved"
        case .active: return "Active"
        case .paused: return "Paused"
        case .done: return "Done"
        case .abandoned: return "Discarded"
        case .failed: return "Failed"
        }
    }

    /// Statuses the user has closed out — they collapse into the archive rather than
    /// cluttering the working list.
    public var isArchived: Bool {
        switch self {
        case .done, .abandoned, .failed: return true
        case .draft, .approved, .active, .paused: return false
        }
    }

    /// Statuses a user may set by hand. `approved` is included as the way *back*: closing
    /// a branch out has to be reversible, and without it a branch marked discarded could
    /// never be picked up again. `draft` and `active` stay owned by the approval and run
    /// machinery — setting those by hand would only desynchronize them from a run.
    public static var userSettable: [PlanStatus] { [.approved, .paused, .done, .failed, .abandoned] }

    /// How the status reads as a menu action rather than as a label.
    public var userActionLabel: String {
        self == .approved ? "Reopen (runnable)" : displayName
    }
}

/// One step of a research plan.
public struct PlanTask: Codable, Equatable, Sendable {
    public enum Status: String, Codable, CaseIterable, Sendable {
        case pending, inProgress = "in_progress", completed, blocked, failed
        /// The branch revised its plan and this task is no longer worth doing. Distinct from
        /// `failed`, which was attempted and did not work: a dropped task was never tried, and
        /// conflating the two would misreport the branch's history. Kept in the plan rather
        /// than deleted so the record shows what was abandoned and why (`needs` carries the
        /// reason) — and so renumbering never invalidates a plan-log reference.
        case dropped

        /// No further execution will pick this task up.
        public var isTerminal: Bool { self == .completed || self == .failed || self == .dropped }

        /// True while the task has never been executed, so a revision may still discard it.
        public var isUnstarted: Bool { self == .pending || self == .blocked }
    }

    public enum Kind: Equatable, Sendable, Codable {
        /// Open-ended research step (experiments, drafting, literature).
        case research
        /// Prove one specific theory item — delegated to the ProofWorkbench.
        case prove(targetID: String)

        var serialized: String {
            switch self {
            case .research: return "research"
            case .prove(let targetID): return "prove: \(targetID)"
            }
        }

        public static func parse(_ text: String) -> Kind? {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if trimmed == "research" { return .research }
            if trimmed.hasPrefix("prove:") {
                let id = trimmed.dropFirst(6).trimmingCharacters(in: .whitespaces)
                return id.isEmpty ? nil : .prove(targetID: id)
            }
            return nil
        }
    }

    /// 1-based position; also the number used in depends-on references.
    public var index: Int
    public var title: String
    public var status: Status
    public var kind: Kind
    public var dependsOn: [Int]
    /// What the task is waiting for (set when blocked, e.g. a question to the user).
    public var needs: String?
    /// Run the reviewer over this task's outcome before it counts as completed.
    public var reviewGate: Bool

    public init(index: Int, title: String, status: Status = .pending, kind: Kind = .research,
                dependsOn: [Int] = [], needs: String? = nil, reviewGate: Bool = false) {
        self.index = index
        self.title = title
        self.status = status
        self.kind = kind
        self.dependsOn = dependsOn
        self.needs = needs
        self.reviewGate = reviewGate
    }

    /// `3. [pending] (prove: lem-x) Strengthen the bound — depends: 1, 2 — review`
    /// The canonical one-line form: the on-disk representation, and what agents and
    /// exported digests show.
    public var line: String {
        var parts = ["\(index). [\(status.rawValue)] (\(kind.serialized)) \(title)"]
        if !dependsOn.isEmpty {
            parts.append("depends: \(dependsOn.map(String.init).joined(separator: ", "))")
        }
        if reviewGate { parts.append("review") }
        if let needs, !needs.isEmpty { parts.append("needs: \(needs)") }
        return parts.joined(separator: " — ")
    }

    /// Lenient inverse of `line`; returns nil for lines that aren't tasks.
    static func parse(line: String) -> PlanTask? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        // "<n>. [<status>] (<kind>) rest"
        guard let dot = trimmed.firstIndex(of: "."),
              let index = Int(trimmed[..<dot]) else { return nil }
        var rest = String(trimmed[trimmed.index(after: dot)...]).trimmingCharacters(in: .whitespaces)

        guard rest.hasPrefix("["), let closeBracket = rest.firstIndex(of: "]") else { return nil }
        let statusRaw = String(rest[rest.index(after: rest.startIndex)..<closeBracket])
        guard let status = Status(rawValue: statusRaw.trimmingCharacters(in: .whitespaces)) else { return nil }
        rest = String(rest[rest.index(after: closeBracket)...]).trimmingCharacters(in: .whitespaces)

        guard rest.hasPrefix("("), let closeParen = rest.firstIndex(of: ")") else { return nil }
        let kindRaw = String(rest[rest.index(after: rest.startIndex)..<closeParen])
        guard let kind = Kind.parse(kindRaw) else { return nil }
        rest = String(rest[rest.index(after: closeParen)...]).trimmingCharacters(in: .whitespaces)

        var components = rest.components(separatedBy: " — ")
        let title = components.removeFirst().trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return nil }

        var dependsOn: [Int] = []
        var needs: String?
        var reviewGate = false
        for component in components {
            let part = component.trimmingCharacters(in: .whitespaces)
            if part.hasPrefix("depends:") {
                dependsOn = part.dropFirst(8).split(separator: ",")
                    .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            } else if part == "review" {
                reviewGate = true
            } else if part.hasPrefix("needs:") {
                needs = part.dropFirst(6).trimmingCharacters(in: .whitespaces)
            }
        }
        return PlanTask(index: index, title: title, status: status, kind: kind,
                        dependsOn: dependsOn, needs: needs, reviewGate: reviewGate)
    }
}

/// A research plan: one file per goal under `plans/`, the single source of truth for
/// the task list and statuses. Agents mutate it only through typed tools (parse →
/// mutate → serialize); humans may edit it, and the parser re-validates before runs.
public struct PlanDocument: Equatable, Sendable {

    public var id: String
    public var goal: String
    public var status: PlanStatus
    public var runMode: RunMode
    public var tokenBudget: Int
    public var created: Date
    public var updated: Date
    /// Full prose of `## Goal` (the frontmatter `goal` is the one-line form).
    public var goalText: String
    /// The chosen strategy and why — from the approved proposal.
    public var approach: String
    public var tasks: [PlanTask]
    /// Append-only run journal (one line per entry, newest last).
    public var log: [String]
    /// Id of the ResearchProgram this plan is a branch of; nil for a standalone plan,
    /// which the app presents as a virtual one-branch program (no disk migration).
    public var program: String?
    /// True when this branch's job is to attack the leading or most obvious answer rather than
    /// to build it. Duplicated from the program manifest so a branch carries its own framing —
    /// its run context is assembled from the plan file alone.
    public var challengesLeadingAnswer: Bool
    /// One-line falsifiable criterion that ends this branch when it fires.
    public var kill: String?
    /// Full prose of `## Lens` — the branch's standing bias, injected as its own system
    /// section (never into `promptDigest`, which would double it).
    public var lens: String
    /// Standing guidance from the user (`## Guidance`), read fresh at every task start so
    /// a course correction lands at the next task instead of requiring a restart.
    public var guidance: String

    public init(id: String, goal: String, status: PlanStatus = .draft,
                runMode: RunMode = .checkpoint, tokenBudget: Int = 2_000_000,
                created: Date = Date(), updated: Date = Date(),
                goalText: String = "", approach: String = "",
                tasks: [PlanTask] = [], log: [String] = [],
                program: String? = nil, challengesLeadingAnswer: Bool = false,
                kill: String? = nil, lens: String = "", guidance: String = "") {
        self.id = id
        self.goal = goal
        self.status = status
        self.runMode = runMode
        self.tokenBudget = tokenBudget
        self.created = created
        self.updated = updated
        self.goalText = goalText
        self.approach = approach
        self.tasks = tasks
        self.log = log
        self.program = program
        self.challengesLeadingAnswer = challengesLeadingAnswer
        self.kill = kill.flatMap { $0.isEmpty ? nil : $0 }
        self.lens = lens
        self.guidance = guidance
    }

    /// Removes a task the run hasn't started, renumbering the rest and remapping every
    /// `dependsOn` reference. Completed and in-progress tasks are refused: the journal and
    /// the plan log already refer to their numbers.
    @discardableResult
    public mutating func removeTask(index: Int) -> Bool {
        guard let position = tasks.firstIndex(where: { $0.index == index }),
              tasks[position].status == .pending else { return false }
        tasks.remove(at: position)
        renumberTasks(removing: index)
        return true
    }

    /// Marks an unstarted task as dropped, with the reason on `needs`. Refuses anything that
    /// has run: the record of what the branch actually did is not rewritable by the branch.
    /// Returns false when the task does not exist or has started.
    @discardableResult
    public mutating func dropTask(index: Int, reason: String) -> Bool {
        guard let position = tasks.firstIndex(where: { $0.index == index }),
              tasks[position].status.isUnstarted else { return false }
        tasks[position].status = .dropped
        tasks[position].needs = reason
        return true
    }

    /// How many times this plan's remaining work has been rewritten, counted off the log so it
    /// survives a restart without a new field. The cap it feeds is what keeps a branch from
    /// replanning instead of concluding.
    public var revisionCount: Int {
        log.filter { $0.contains(Self.revisionLogMarker) }.count
    }

    public static let revisionLogMarker = "plan revised"

    /// Appends a task at the end; returns its 1-based index.
    @discardableResult
    public mutating func appendTask(title: String, kind: PlanTask.Kind = .research,
                                    reviewGate: Bool = false) -> Int {
        let index = (tasks.map(\.index).max() ?? 0) + 1
        tasks.append(PlanTask(index: index, title: title, kind: kind, reviewGate: reviewGate))
        return index
    }

    private mutating func renumberTasks(removing removed: Int) {
        for position in tasks.indices {
            let old = tasks[position].index
            if old > removed { tasks[position].index = old - 1 }
            tasks[position].dependsOn = tasks[position].dependsOn
                .compactMap { dependency in
                    if dependency == removed { return nil }          // the dependency is gone
                    return dependency > removed ? dependency - 1 : dependency
                }
                .filter { $0 < tasks[position].index }                // never point forward
        }
    }

    public func task(index: Int) -> PlanTask? {
        tasks.first { $0.index == index }
    }

    /// A task is runnable when pending and every dependency has completed.
    public func runnableTasks() -> [PlanTask] {
        tasks.filter { task in
            task.status == .pending && task.dependsOn.allSatisfy { dep in
                self.task(index: dep)?.status == .completed
            }
        }
    }

    /// True when no task can make further progress (all terminal, or the rest blocked).
    public var isFinished: Bool {
        tasks.allSatisfy { $0.status.isTerminal }
    }

    /// Still-pending tasks that can never run because `index` failed: a dependency is only
    /// satisfied by `completed`, so everything downstream of a failure is unreachable.
    ///
    /// Left unmarked they sit `pending` forever and the run simply ends — the plan then reads
    /// as if the work were merely unfinished rather than cut off, which is what made branch 1
    /// of the first automode run lose a tractable task behind an impossible one.
    public func strandedTasks(after index: Int) -> [PlanTask] {
        var killed: Set<Int> = [index]
        // Tasks are index-ordered and dependencies only ever point backwards, so one forward
        // pass reaches the whole transitive closure.
        for task in tasks.sorted(by: { $0.index < $1.index })
        where task.status == .pending && task.dependsOn.contains(where: { killed.contains($0) }) {
            killed.insert(task.index)
        }
        killed.remove(index)
        return tasks.filter { killed.contains($0.index) }
    }

    /// Non-terminal tasks that can never become runnable, because some task they transitively
    /// depend on has failed. They are not questions for the user — no answer makes a failed
    /// dependency complete — so the run loop must not mistake them for a task awaiting input.
    public func unreachableTasks() -> [PlanTask] {
        let failed = Set(tasks.filter { $0.status == .failed }.map(\.index))
        var blocked: Set<Int> = []
        for task in tasks.sorted(by: { $0.index < $1.index })
        where !task.status.isTerminal
            && task.dependsOn.contains(where: { failed.contains($0) || blocked.contains($0) }) {
            blocked.insert(task.index)
        }
        return tasks.filter { blocked.contains($0.index) }
    }

    // MARK: - Parse / serialize

    public static func parse(markdown: String, fallbackID: String? = nil) throws -> PlanDocument {
        let (fm, body) = Frontmatter.split(document: markdown)
        guard let fm else { throw CoreError.invalidFrontmatter("plan is missing '---' frontmatter") }
        let fields = Frontmatter.parseFields(fm)
        guard let id = fields["id"]?.first ?? fallbackID, !id.isEmpty else {
            throw CoreError.invalidFrontmatter("plan is missing 'id'")
        }
        let formatter = ISO8601DateFormatter()

        var sections: [String: [String]] = [:]
        var currentSection: String?
        for line in body.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("## ") {
                currentSection = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces).lowercased()
                sections[currentSection!] = []
                continue
            }
            if let section = currentSection {
                sections[section, default: []].append(line)
            }
        }
        func sectionText(_ name: String) -> String {
            (sections[name] ?? []).joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var tasks: [PlanTask] = []
        var badLines: [String] = []
        for line in sections["tasks"] ?? [] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if let task = PlanTask.parse(line: trimmed) {
                tasks.append(task)
            } else {
                badLines.append(trimmed)
            }
        }
        guard badLines.isEmpty else {
            throw CoreError.invalidFrontmatter(
                "plan '\(id)' has unparseable task line(s): \(badLines.joined(separator: " | "))")
        }

        let log = (sections["log"] ?? [])
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("- ") }
            .map { String($0.dropFirst(2)) }

        return PlanDocument(
            id: id,
            goal: fields["goal"]?.first ?? "",
            status: fields["status"]?.first.flatMap { PlanStatus(rawValue: $0) } ?? .draft,
            runMode: fields["run_mode"]?.first.flatMap { RunMode(rawValue: $0) } ?? .checkpoint,
            tokenBudget: fields["token_budget"]?.first.flatMap { Int($0) } ?? 2_000_000,
            created: fields["created"]?.first.flatMap { formatter.date(from: $0) } ?? Date(),
            updated: fields["updated"]?.first.flatMap { formatter.date(from: $0) } ?? Date(),
            goalText: sectionText("goal"),
            approach: sectionText("approach"),
            tasks: tasks,
            log: log,
            program: fields["program"]?.first,
            // `challenges_leading_answer` is the current field; a plan written under the
            // stance vocabulary keeps its job description via the three breaker stances.
            challengesLeadingAnswer: fields["challenges_leading_answer"]?.first
                .flatMap { Bool($0) }
                ?? ["refute", "adversary", "impossible"]
                    .contains(fields["stance"]?.first ?? ""),
            kill: fields["kill"]?.first,
            lens: sectionText("lens"),
            guidance: sectionText("guidance")
        )
    }

    public func serialized() -> String {
        let formatter = ISO8601DateFormatter()
        var lines: [String] = ["---"]
        lines.append("kind: plan")
        lines.append("id: \(Frontmatter.quoteIfNeeded(id))")
        lines.append("goal: \(Frontmatter.quoteIfNeeded(goal))")
        lines.append("status: \(status.rawValue)")
        lines.append("run_mode: \(runMode.rawValue)")
        lines.append("token_budget: \(tokenBudget)")
        lines.append("created: \(formatter.string(from: created))")
        lines.append("updated: \(formatter.string(from: updated))")
        // Program fields are emitted only when set, so standalone plans round-trip
        // byte-identically to files written before Research Programs existed.
        if let program, !program.isEmpty {
            lines.append("program: \(Frontmatter.quoteIfNeeded(program))")
        }
        if challengesLeadingAnswer { lines.append("challenges_leading_answer: true") }
        if let kill, !kill.isEmpty { lines.append("kill: \(Frontmatter.quoteIfNeeded(kill))") }
        lines.append("---")
        lines.append("")
        lines.append("## Goal")
        lines.append(goalText.isEmpty ? goal : goalText)
        lines.append("")
        lines.append("## Approach")
        lines.append(approach)
        lines.append("")
        if !lens.isEmpty {
            lines.append("## Lens")
            lines.append(lens)
            lines.append("")
        }
        if !guidance.isEmpty {
            lines.append("## Guidance")
            lines.append(guidance)
            lines.append("")
        }
        lines.append("## Tasks")
        for task in tasks { lines.append(task.line) }
        lines.append("")
        lines.append("## Log")
        for entry in log { lines.append("- \(entry)") }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Compact form for agent prompts: goal, approach, one line per task.
    public var promptDigest: String {
        var parts = ["Plan '\(id)' [\(status.rawValue)]", "Goal: \(goalText.isEmpty ? goal : goalText)"]
        if !approach.isEmpty { parts.append("Approach: \(approach)") }
        if challengesLeadingAnswer {
            parts.append("This branch attacks the leading answer rather than building it."
                + (kill.map { " Kill criterion: \($0)" } ?? ""))
        } else if let kill {
            parts.append("Kill criterion: \(kill)")
        }
        parts.append("Tasks:")
        parts.append(contentsOf: tasks.map(\.line))
        return parts.joined(separator: "\n")
    }
}

// MARK: - PlanTask.Kind Codable

extension PlanTask.Kind {
    private enum CodingKeys: String, CodingKey { case kind, targetID }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "research": self = .research
        case "prove": self = .prove(targetID: try c.decode(String.self, forKey: .targetID))
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: c, debugDescription: "unknown task kind '\(other)'")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .research:
            try c.encode("research", forKey: .kind)
        case .prove(let targetID):
            try c.encode("prove", forKey: .kind)
            try c.encode(targetID, forKey: .targetID)
        }
    }
}

// MARK: - ProjectStore plans

extension ProjectStore {

    public var plansURL: URL { rootURL.appendingPathComponent("plans", isDirectory: true) }

    /// All parseable plans, newest first; unparseable files are reported, not fatal.
    public func loadPlans() -> (plans: [PlanDocument], warnings: [String]) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: plansURL, includingPropertiesForKeys: nil) else {
            return ([], [])
        }
        var plans: [PlanDocument] = []
        var warnings: [String] = []
        // `<planID>.memory.md` files are branch research memories, not plans.
        for file in files where file.pathExtension == "md"
            && !file.lastPathComponent.hasSuffix(ProjectStore.branchMemorySuffix) {
            do {
                let text = try String(contentsOf: file, encoding: .utf8)
                let fallbackID = file.deletingPathExtension().lastPathComponent
                plans.append(try PlanDocument.parse(markdown: text, fallbackID: fallbackID))
            } catch {
                warnings.append("\(file.lastPathComponent): \(error.localizedDescription)")
            }
        }
        plans.sort { $0.created > $1.created }
        return (plans, warnings)
    }

    public func plan(id: String) -> PlanDocument? {
        let url = plansURL.appendingPathComponent("\(id).md")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return try? PlanDocument.parse(markdown: text, fallbackID: id)
    }

    public func savePlan(_ plan: PlanDocument) throws {
        var plan = plan
        plan.updated = Date()
        try FileManager.default.createDirectory(at: plansURL, withIntermediateDirectories: true)
        try plan.serialized().write(
            to: plansURL.appendingPathComponent("\(plan.id).md"),
            atomically: true, encoding: .utf8)
    }

    /// Deletes a plan and the branch memory that belongs to it. The memory file is the
    /// easy one to forget: it is invisible to `loadPlans()`, so an orphan would linger
    /// unreferenced and reappear under a later plan that happened to reuse the id.
    public func deletePlan(id: String) throws {
        let fm = FileManager.default
        for url in [plansURL.appendingPathComponent("\(id).md"), branchMemoryURL(planID: id)]
        where fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
    }
}
