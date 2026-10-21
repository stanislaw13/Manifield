import Foundation

/// One line of attack, tracked independently of whichever branch is currently working it.
///
/// The registry is the program's durable negative knowledge. Nothing else holds it: the task
/// journal is truncated to the last dozen entries, and research memory is capped, so without
/// this a later generation re-attempts what an earlier one already killed.
public struct ResearchRoute: Codable, Equatable, Sendable, Identifiable {

    public enum Status: String, Codable, CaseIterable, Sendable {
        /// Considered, not yet given a branch.
        case proposed
        case active
        /// Waiting on something — a lemma, a decision, a computation out of reach.
        case blocked
        /// Ruled out, with the reason in `obstruction`. The most valuable state in the registry.
        case falsified
        /// Folded into another route; `mergedInto` says which.
        case merged
        case proved

        public var isClosed: Bool { self == .falsified || self == .merged || self == .proved }

        public var displayName: String {
            switch self {
            case .proposed: return "Proposed"
            case .active: return "Active"
            case .blocked: return "Blocked"
            case .falsified: return "Falsified"
            case .merged: return "Merged"
            case .proved: return "Proved"
            }
        }
    }

    public var id: String
    /// Branch currently working it, when one is. Nil for a proposed or closed route — the
    /// route outlives the branch, which is the point of keying on it rather than on the plan.
    public var planID: String?
    /// The core mathematical idea, not a prose title. What makes two routes the same route.
    public var mechanism: String
    /// Extra hypotheses this route introduces beyond the problem's own.
    public var assumptions: [String]
    public var status: Status
    /// Theory item ids the route depends on or produced.
    public var keyClaims: [String]
    /// The smallest precisely identified gap or counterexample. Set when the route closes.
    public var obstruction: String?
    /// Artifact paths and finding ids supporting it.
    public var evidence: [String]
    /// The decisive action that would advance or kill this route. The scheduler's input, and
    /// the fastest thing for a human to read when asking what is happening.
    public var nextTest: String?
    public var mergedInto: String?
    /// Routes this one descends from — the obstruction it was proposed to get around, the
    /// partial result it builds on. Empty for a first-generation route, and for any route
    /// proposed before lineage was recorded.
    ///
    /// Without it a later generation is a stack of unrelated columns: `generation` says *when* a
    /// route was proposed and `mergedInto` covers only merges, so nothing connects a route to
    /// what produced it. The director knows the answer at the moment it proposes; it simply was
    /// not being asked.
    public var parentRouteIDs: [String]
    /// Which wave of branches proposed it, so a reader can see how the attack evolved.
    public var generation: Int
    /// "strong" to run the branch on the strongest configured model, nil for the default.
    /// Set by whoever proposed the route — the director tiers by how hard the decisive work
    /// is, not by role.
    public var modelTier: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: String = UUID().uuidString, planID: String? = nil, mechanism: String,
                assumptions: [String] = [], status: Status = .proposed,
                keyClaims: [String] = [], obstruction: String? = nil, evidence: [String] = [],
                nextTest: String? = nil, mergedInto: String? = nil,
                parentRouteIDs: [String] = [], generation: Int = 1,
                modelTier: String? = nil,
                createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.planID = planID
        self.mechanism = mechanism
        self.assumptions = assumptions
        self.status = status
        self.keyClaims = keyClaims
        self.obstruction = obstruction
        self.evidence = evidence
        self.nextTest = nextTest
        self.mergedInto = mergedInto
        self.parentRouteIDs = parentRouteIDs
        self.generation = generation
        self.modelTier = modelTier
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// One line for a prompt or a table row.
    public var line: String {
        var parts = ["[\(status.rawValue)] \(mechanism)"]
        if !assumptions.isEmpty { parts.append("assumes: \(assumptions.joined(separator: "; "))") }
        if let obstruction, !obstruction.isEmpty { parts.append("died on: \(obstruction)") }
        if let nextTest, !nextTest.isEmpty, !status.isClosed { parts.append("next: \(nextTest)") }
        if !keyClaims.isEmpty { parts.append("items: \(keyClaims.joined(separator: ", "))") }
        return parts.joined(separator: " — ")
    }
}

public extension Array where Element == ResearchRoute {

    /// What a new branch must be told so it does not re-run a dead route. Deliberately every
    /// falsified route rather than only same-mechanism ones: at this scale the whole list is a
    /// few lines, and a mechanism classifier that mis-files one entry silently loses exactly
    /// the knowledge the registry exists to keep.
    var closedRouteDigest: String? {
        let closed = filter { $0.status == .falsified }
        guard !closed.isEmpty else { return nil }
        return """
        Routes already ruled out in this program. Do not re-attempt these; if your task \
        requires one, say so in your summary rather than repeating the work:

        \(closed.map { "- \($0.mechanism)\($0.obstruction.map { o in " — died on: \(o)" } ?? "")" }
            .joined(separator: "\n"))
        """
    }

    /// The open routes and their decisive next tests — the scheduler's view.
    var liveRoutes: [ResearchRoute] { filter { !$0.status.isClosed } }

    func route(planID: String) -> ResearchRoute? {
        first { $0.planID == planID }
    }
}

/// A claim that is being leaned on but has not itself been established.
///
/// Derived rather than maintained: gaps disappear under increasingly polished exposition, and
/// a ledger somebody has to remember to update is a ledger that drifts. This one is recomputed
/// from the library every time it is read.
public struct ProofObligation: Equatable, Sendable, Identifiable {
    /// The item whose standing depends on something unproved.
    public var itemID: String
    /// Ids it (transitively) rests on that are not established.
    public var unprovedDependencies: [String]

    public var id: String { itemID }

    public init(itemID: String, unprovedDependencies: [String]) {
        self.itemID = itemID
        self.unprovedDependencies = unprovedDependencies
    }
}

public extension ItemStatus {
    /// True when the item is being presented as established rather than as an open question.
    /// `tested` is deliberately *not* established — evidence on small cases is the exact thing
    /// the success contract's exclusion list rules out as a substitute for proof.
    var isEstablished: Bool {
        switch self {
        case .conjecture, .tested, .illustration: return false
        case .proofDrafted, .reviewedNoErrors, .humanApproved, .source, .formallyVerified:
            return true
        }
    }
}

public enum ProofObligations {

    /// Every item that claims to be established while resting on something that is not.
    /// Cycles are tolerated: an id is expanded at most once per root.
    public static func open(items: [TheoryItem]) -> [ProofObligation] {
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        func unprovedUnder(_ root: TheoryItem) -> [String] {
            var seen: Set<String> = [root.id]
            var stack = root.dependsOn
            var found: Set<String> = []
            while let next = stack.popLast() {
                guard seen.insert(next).inserted else { continue }
                guard let item = byID[next] else {
                    // A dangling reference is its own kind of unproved dependency.
                    found.insert(next)
                    continue
                }
                if !item.status.isEstablished {
                    found.insert(next)
                } else {
                    stack.append(contentsOf: item.dependsOn)
                }
            }
            return found.sorted()
        }

        return items
            .filter { $0.status.isEstablished }
            .compactMap { item in
                let unproved = unprovedUnder(item)
                return unproved.isEmpty ? nil : ProofObligation(
                    itemID: item.id, unprovedDependencies: unproved)
            }
            .sorted { $0.itemID < $1.itemID }
    }
}
