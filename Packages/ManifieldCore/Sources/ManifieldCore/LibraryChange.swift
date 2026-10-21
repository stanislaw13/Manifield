import Foundation

/// One thing an agent run did to the theory library.
///
/// Runs propose and write through several paths — direct writes in auto mode, proposals
/// the user accepts mid-run, evidence attached to existing items. Rather than instrument
/// each path, a run compares a snapshot taken before it started with the library
/// afterwards: whatever route a change took, it shows up here.
public struct LibraryChange: Codable, Equatable, Sendable, Identifiable {

    public enum Kind: String, Codable, CaseIterable, Sendable {
        case created
        case statusChanged
        case removed
        /// Rewritten without its trust level moving. Invisible to a status diff, which is why
        /// it only appears on changes attributed at a task boundary — there the run knows the
        /// item was written, whether or not the write moved anything a snapshot compares.
        case revised

        public var displayName: String {
            switch self {
            case .created: return "New"
            case .statusChanged: return "Status changed"
            case .removed: return "Removed"
            case .revised: return "Revised"
            }
        }
    }

    public var itemID: String
    public var name: String
    public var kind: Kind
    /// Status before the run; nil for a newly created item.
    public var fromStatus: ItemStatus?
    /// Status after the run; nil if the item was removed.
    public var toStatus: ItemStatus?
    /// Which branch made the change, and when. Nil for a change caught by the whole-run diff
    /// rather than attributed at a task boundary — the run genuinely does not know who made
    /// those, and claiming a branch for them would be worse than admitting it.
    public var branchPlanID: String?
    public var taskIndex: Int?
    public var at: Date?

    /// The id has to distinguish two changes to the same item, since a branch can revise an
    /// item across several tasks and a program can touch one from two branches. Attributed
    /// changes key on when and where; the run diff has exactly one entry per item.
    public var id: String {
        guard let at else { return itemID }
        return "\(itemID)@\(at.timeIntervalSince1970)-\(branchPlanID ?? "run")"
    }

    /// True when this change can be placed on a branch and a moment.
    public var isAttributed: Bool { branchPlanID != nil && at != nil }

    public init(itemID: String, name: String, kind: Kind,
                fromStatus: ItemStatus? = nil, toStatus: ItemStatus? = nil,
                branchPlanID: String? = nil, taskIndex: Int? = nil, at: Date? = nil) {
        self.itemID = itemID
        self.name = name
        self.kind = kind
        self.fromStatus = fromStatus
        self.toStatus = toStatus
        self.branchPlanID = branchPlanID
        self.taskIndex = taskIndex
        self.at = at
    }

    /// True when the item's trust level went *down* — the case worth reading first, since
    /// it usually means a counterexample or a failed review landed on something.
    public var isDowngrade: Bool {
        guard let fromStatus, let toStatus else { return false }
        return toStatus.rank < fromStatus.rank
    }
}

/// The library's id → (name, status) state at a moment in time. Cheap to take, so a run
/// takes one at the start and diffs against the end.
public struct LibrarySnapshot: Equatable, Sendable {

    private var statuses: [String: ItemStatus]
    private var names: [String: String]

    public init(items: [TheoryItem]) {
        statuses = Dictionary(items.map { ($0.id, $0.status) }, uniquingKeysWith: { _, last in last })
        names = Dictionary(items.map { ($0.id, $0.name) }, uniquingKeysWith: { _, last in last })
    }

    public var isEmpty: Bool { statuses.isEmpty }

    /// What changed between this snapshot and a later one, newest-relevant first:
    /// downgrades, then new items, then the rest — sorted by id within each group so the
    /// list is stable across renders.
    /// `attribution` tags every change with who made it and when. Supplied at a task boundary,
    /// where the run knows both; omitted for the whole-run diff, where it does not.
    public func changes(
        to later: LibrarySnapshot,
        attribution: (branchPlanID: String, taskIndex: Int, at: Date)? = nil
    ) -> [LibraryChange] {
        var changes: [LibraryChange] = []

        func change(_ id: String, _ name: String, _ kind: LibraryChange.Kind,
                    from: ItemStatus? = nil, to: ItemStatus? = nil) -> LibraryChange {
            LibraryChange(itemID: id, name: name, kind: kind, fromStatus: from, toStatus: to,
                          branchPlanID: attribution?.branchPlanID,
                          taskIndex: attribution?.taskIndex,
                          at: attribution?.at)
        }

        for (id, status) in later.statuses {
            let name = later.names[id] ?? id
            guard let before = statuses[id] else {
                changes.append(change(id, name, .created, to: status))
                continue
            }
            if before != status {
                changes.append(change(id, name, .statusChanged, from: before, to: status))
            }
        }
        for (id, status) in statuses where later.statuses[id] == nil {
            changes.append(change(id, names[id] ?? id, .removed, from: status))
        }

        return changes.sorted { lhs, rhs in
            if lhs.isDowngrade != rhs.isDowngrade { return lhs.isDowngrade }
            if (lhs.kind == .created) != (rhs.kind == .created) { return lhs.kind == .created }
            return lhs.itemID < rhs.itemID
        }
    }
}
