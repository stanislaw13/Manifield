import Foundation
import ManifieldCore

/// The program as a lineage graph: routes as lanes, time running down, and the lateral traffic
/// between them.
///
/// A commit graph is the right instinct — generations, branching, merges — but the interesting
/// edges here go *sideways*. A branch works from its own reasoning plus whatever crossed to it,
/// so "which branch knew what, and when" is the question the portfolio model exists to make
/// answerable, and it is invisible in every list view: a list can show that a finding exists,
/// never that the director decided three branches should not hear about it.
///
/// A **pure projection**, like `ProgramStatus`: everything here is derived from the manifest and
/// the run records, in domain coordinates (a lane index and a `Date`). No pixels, no view — the
/// renderer maps to geometry, and the layout is testable without one.
public struct ProgramGraph: Equatable, Sendable {

    /// One route, held for as long as the route exists rather than for one branch's run. Lanes
    /// are the graph's x axis.
    public struct Lane: Equatable, Sendable, Identifiable {
        public var id: String
        public var routeID: String
        public var planID: String?
        public var title: String
        public var mechanism: String
        public var status: ResearchRoute.Status
        public var challengesLeadingAnswer: Bool
        public var generation: Int
        /// Lanes this one descends from, as lane indices. Drawn as a curve from the parent's
        /// position at the generation boundary.
        public var parentLaneIndices: [Int]
        /// When the lane's branch started and last did anything. Nil start for a route that was
        /// proposed and never given a branch.
        public var startedAt: Date?
        public var endedAt: Date?
        public var tokensSpent: Int
        /// Task boundaries along the lane. Texture rather than nodes: a branch has nine to
        /// twelve of these and they carry no relational information, so drawing them as
        /// clickable marks would add fifty hit targets that say nothing a lane does not.
        public var taskTicks: [Tick]

        public var isClosed: Bool { status.isClosed }
    }

    public struct Tick: Equatable, Sendable {
        public var taskIndex: Int
        public var at: Date
        public var outcome: String
        public var completed: Bool
    }

    /// Something that happened on a lane at a moment. Nodes are clickable; ticks are not.
    public struct Node: Equatable, Sendable, Identifiable {
        public enum Kind: Equatable, Sendable {
            /// A finding, with the routing decision that governs it. Nil routing means it has
            /// been submitted and reaches nobody.
            case finding(kind: ProgramFinding.Kind, decision: FindingRouting.Decision?)
            case libraryChange(kind: LibraryChange.Kind, downgrade: Bool)
            case claim(status: SolutionCandidate.Status)
            /// The route ended here.
            case routeClosed(status: ResearchRoute.Status)
        }

        public var id: String
        public var kind: Kind
        public var laneIndex: Int
        public var at: Date
        public var label: String
        /// The object this node stands for, so a click can open its detail pane.
        public var subjectID: String
    }

    /// A finding travelling from the lane that published it to a lane that was told about it.
    ///
    /// A `hold` or `do_not_send` produces **no** edge, which is the point: an edge that goes
    /// nowhere is what "the director decided not to tell anyone" looks like.
    public struct Edge: Equatable, Sendable, Identifiable {
        public var id: String
        public var fromNodeID: String
        public var fromLane: Int
        public var toLane: Int
        public var at: Date
        public var decision: FindingRouting.Decision
        public var rationale: String
    }

    /// A generation boundary — a director turn, drawn across every lane.
    public struct Boundary: Equatable, Sendable, Identifiable {
        public var id: String
        public var generation: Int
        public var at: Date
        public var label: String
    }

    /// An approach the planner considered and deliberately did not take. Drawn as a stub that
    /// starts and stops: negative space is part of what a portfolio decided.
    public struct Ghost: Equatable, Sendable, Identifiable {
        public var id: String
        public var cell: String
        public var why: String
    }

    public var lanes: [Lane]
    public var nodes: [Node]
    public var edges: [Edge]
    public var boundaries: [Boundary]
    public var ghosts: [Ghost]
    /// The window every time coordinate is measured against. Equal bounds for a program where
    /// nothing has a timestamp yet — the renderer then spaces lanes evenly rather than dividing
    /// by zero.
    public var start: Date
    public var end: Date

    public var isEmpty: Bool { lanes.isEmpty && nodes.isEmpty }

    /// Where a moment sits in the window, 0...1. Clamped, so a record whose clock is off cannot
    /// push a node off the canvas.
    public func fraction(of date: Date) -> Double {
        let span = end.timeIntervalSince(start)
        guard span > 0 else { return 0 }
        return min(1, max(0, date.timeIntervalSince(start) / span))
    }

    // MARK: - Build

    public static func build(
        program: ResearchProgram,
        records: [String: RunRecord],
        plans: [String: PlanDocument] = [:],
        programRecord: ProgramRunRecord? = nil
    ) -> ProgramGraph {
        let routes = program.routes ?? []

        // A branch with no route still needs a lane — a standalone plan has no registry, and a
        // program whose routes were never recorded would otherwise draw as nothing at all.
        var lanes: [Lane] = []
        var laneIndexByRoute: [String: Int] = [:]
        var laneIndexByPlan: [String: Int] = [:]

        let ordered = routes.sorted { lhs, rhs in
            if lhs.generation != rhs.generation { return lhs.generation < rhs.generation }
            return lhs.createdAt < rhs.createdAt
        }

        for route in ordered {
            let record = route.planID.flatMap { records[$0] }
            let branch = route.planID.flatMap { program.branch(planID: $0) }
            let ticks = record.map(Self.ticks) ?? []
            let lane = Lane(
                id: route.id,
                routeID: route.id,
                planID: route.planID,
                title: branch?.title ?? route.mechanism,
                mechanism: route.mechanism,
                status: route.status,
                challengesLeadingAnswer: branch?.challengesLeadingAnswer ?? false,
                generation: route.generation,
                parentLaneIndices: [],
                startedAt: record?.startedAt ?? ticks.first?.at,
                endedAt: ticks.last?.at ?? record?.updatedAt,
                tokensSpent: record?.tokensUsed ?? 0,
                taskTicks: ticks)
            laneIndexByRoute[route.id] = lanes.count
            if let planID = route.planID { laneIndexByPlan[planID] = lanes.count }
            lanes.append(lane)
        }

        // Branches the registry does not cover. Kept so the graph never silently omits work.
        for branch in program.branches where laneIndexByPlan[branch.planID] == nil {
            let record = records[branch.planID]
            let ticks = record.map(Self.ticks) ?? []
            laneIndexByPlan[branch.planID] = lanes.count
            lanes.append(Lane(
                id: "branch-\(branch.planID)",
                routeID: "",
                planID: branch.planID,
                title: branch.title,
                mechanism: plans[branch.planID]?.approach ?? branch.title,
                status: .active,
                challengesLeadingAnswer: branch.challengesLeadingAnswer,
                generation: 1,
                parentLaneIndices: [],
                startedAt: record?.startedAt ?? ticks.first?.at,
                endedAt: ticks.last?.at ?? record?.updatedAt,
                tokensSpent: record?.tokensUsed ?? 0,
                taskTicks: ticks))
        }

        // Lineage, once every lane has an index.
        for (index, route) in ordered.enumerated() where !route.parentRouteIDs.isEmpty {
            lanes[index].parentLaneIndices = route.parentRouteIDs.compactMap { laneIndexByRoute[$0] }
        }

        var nodes: [Node] = []
        var edges: [Edge] = []

        for finding in program.findings {
            guard let lane = laneIndexByPlan[finding.branchPlanID] else { continue }
            let routing = program.routing(forFinding: finding.id)
            let nodeID = "finding-\(finding.id)"
            nodes.append(Node(
                id: nodeID,
                kind: .finding(kind: finding.kind, decision: routing?.decision),
                laneIndex: lane,
                at: finding.createdAt,
                label: finding.statement,
                subjectID: finding.id))

            guard let routing, routing.decision.circulates else { continue }
            // `global` reaches every lane but the originator's; `send_now` reaches the named
            // recipients. Hold and do-not-send produce nothing, which is the whole point.
            let targets: [Int] = routing.decision == .global
                ? lanes.indices.filter { $0 != lane }
                : routing.recipientPlanIDs.compactMap { laneIndexByPlan[$0] }.filter { $0 != lane }
            for target in Set(targets).sorted() {
                edges.append(Edge(
                    id: "\(nodeID)->\(target)",
                    fromNodeID: nodeID,
                    fromLane: lane,
                    toLane: target,
                    at: routing.decidedAt,
                    decision: routing.decision,
                    rationale: routing.rationale))
            }
        }

        // Attributed changes only. A whole-run diff entry has no branch and no moment, so it
        // has nowhere to go on a graph whose axes are exactly those two things.
        for record in records.values {
            for change in record.libraryChanges {
                guard let planID = change.branchPlanID,
                      let lane = laneIndexByPlan[planID],
                      let at = change.at else { continue }
                nodes.append(Node(
                    id: "change-\(change.id)",
                    kind: .libraryChange(kind: change.kind, downgrade: change.isDowngrade),
                    laneIndex: lane,
                    at: at,
                    label: "\(change.kind.displayName): \(change.name)",
                    subjectID: change.itemID))
            }
        }

        for candidate in program.solutions {
            guard let lane = laneIndexByPlan[candidate.branchPlanID] else { continue }
            nodes.append(Node(
                id: "claim-\(candidate.id)",
                kind: .claim(status: candidate.status),
                laneIndex: lane,
                at: candidate.createdAt,
                label: "Claim on \(candidate.primaryItemID)",
                subjectID: candidate.id))
        }

        for (index, route) in ordered.enumerated() where route.status.isClosed {
            nodes.append(Node(
                id: "closed-\(route.id)",
                kind: .routeClosed(status: route.status),
                laneIndex: index,
                at: route.updatedAt,
                label: route.obstruction ?? route.status.displayName,
                subjectID: route.id))
        }

        // A boundary per generation after the first, placed at the earliest lane of that
        // generation — which is when the director's turn must have happened.
        var boundaries: [Boundary] = []
        let byGeneration = Dictionary(grouping: ordered, by: \.generation)
        for generation in byGeneration.keys.sorted() where generation > 1 {
            let group = byGeneration[generation] ?? []
            guard let at = group.map(\.createdAt).min() else { continue }
            boundaries.append(Boundary(
                id: "gen-\(generation)",
                generation: generation,
                at: at,
                label: "Director opened generation \(generation) — \(group.count) route(s)"))
        }

        let ghosts = program.skippedCells.map {
            Ghost(id: $0.cell, cell: $0.cell, why: $0.why)
        }

        let moments = lanes.compactMap(\.startedAt) + lanes.compactMap(\.endedAt)
            + nodes.map(\.at) + edges.map(\.at) + boundaries.map(\.at)
        let start = moments.min() ?? program.created
        let end = moments.max() ?? program.updated

        return ProgramGraph(lanes: lanes, nodes: nodes, edges: edges,
                            boundaries: boundaries, ghosts: ghosts,
                            start: start, end: max(end, start))
    }

    private static func ticks(_ record: RunRecord) -> [Tick] {
        record.journal.map {
            Tick(taskIndex: $0.taskIndex, at: $0.endedAt, outcome: $0.outcome,
                 completed: $0.outcome == "completed")
        }
    }
}
