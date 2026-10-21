import Foundation

/// Dependency structure over theory items. Edges point from an item to what it depends on
/// (`depends_on` in frontmatter). Reverse edges answer "what breaks if this is wrong?"
public struct DependencyGraph: Sendable {

    public struct Edge: Equatable, Sendable {
        public let from: String  // the dependent item
        public let to: String    // the dependency it uses
    }

    public private(set) var itemsByID: [String: TheoryItem]
    public private(set) var edges: [Edge]
    private var forward: [String: [String]]   // id -> dependencies
    private var reverse: [String: [String]]   // id -> dependents

    /// References in depends_on that point at ids not present in the project.
    public private(set) var missingReferences: [Edge]
    /// References into attached literature sources (`slug:item-id`) — external by design,
    /// not "missing".
    public private(set) var externalReferences: [Edge]

    public init(items: [TheoryItem]) {
        var byID: [String: TheoryItem] = [:]
        for item in items { byID[item.id] = item }
        var edges: [Edge] = []
        var missing: [Edge] = []
        var external: [Edge] = []
        var fwd: [String: [String]] = [:]
        var rev: [String: [String]] = [:]

        for item in items {
            for dep in item.dependsOn {
                let edge = Edge(from: item.id, to: dep)
                if byID[dep] != nil {
                    edges.append(edge)
                    fwd[item.id, default: []].append(dep)
                    rev[dep, default: []].append(item.id)
                } else if dep.contains(":") {
                    external.append(edge)
                } else {
                    missing.append(edge)
                }
            }
        }
        self.itemsByID = byID
        self.edges = edges
        self.forward = fwd
        self.reverse = rev
        self.missingReferences = missing
        self.externalReferences = external
    }

    public var nodeIDs: [String] { itemsByID.keys.sorted() }

    public func dependencies(of id: String) -> [String] { forward[id] ?? [] }
    public func dependents(of id: String) -> [String] { reverse[id] ?? [] }

    /// Everything that (transitively) uses `id` — the blast radius when `id` is invalidated.
    public func transitiveDependents(of id: String) -> Set<String> {
        var seen: Set<String> = []
        var stack = dependents(of: id)
        while let next = stack.popLast() {
            if seen.insert(next).inserted {
                stack.append(contentsOf: dependents(of: next))
            }
        }
        return seen
    }

    /// Returns one dependency cycle if any exists (a proof depending on itself, possibly indirectly).
    public func findCycle() -> [String]? {
        var state: [String: Int] = [:]  // 0 unvisited (absent), 1 in-stack, 2 done
        var path: [String] = []
        var cycle: [String]? = nil

        func dfs(_ node: String) -> Bool {
            state[node] = 1
            path.append(node)
            for dep in forward[node] ?? [] {
                if state[dep] == 1 {
                    let start = path.firstIndex(of: dep) ?? 0
                    cycle = Array(path[start...]) + [dep]
                    return true
                }
                if state[dep] == nil, dfs(dep) { return true }
            }
            state[node] = 2
            path.removeLast()
            return false
        }

        for node in nodeIDs where state[node] == nil {
            if dfs(node) { return cycle }
        }
        return nil
    }

    /// JSON for the graph web view: `{nodes: [{id, name, type, family, status, statusRank, tags, color, statement, …}], edges: [{source, target}]}`.
    /// Edge direction is dependency → dependent, i.e. the direction of derivation.
    /// `resolveExternal` looks up `slug:item-id` references in attached sources; resolved
    /// or not, external references become distinct literature nodes.
    public func webJSON(resolveExternal: (String) -> TheoryItem? = { _ in nil }) throws -> String {
        var nodes: [[String: Any]] = []
        for id in nodeIDs {
            guard let item = itemsByID[id] else { continue }
            nodes.append([
                "id": item.id,
                "name": item.name,
                "type": item.type.rawValue,
                "family": item.type.shapeFamily.rawValue,
                "typeLabel": item.type.displayName,
                "status": item.status.rawValue,
                "statusLabel": item.status.displayName,
                // Solidity is drawn from this rank, and `illustration` ranks 0 so that
                // breakage propagation ignores figures. Drawn at 0 they would fade out
                // like unproved conjectures, which says something false about a picture
                // — so they are reported at the "settled" tier instead.
                "statusRank": item.isFigure ? ItemStatus.reviewedNoErrors.rank : item.status.rank,
                "color": item.status.colorHex,
                "section": item.section ?? "",
                "statement": (item.isFigure ? item.caption : item.statement) ?? "",
                "tags": item.tags
            ])
        }
        for ref in Set(externalReferences.map(\.to)).sorted() {
            let resolved = resolveExternal(ref)
            nodes.append([
                "id": ref,
                "name": resolved.map { "\($0.name)\n(\(ref.split(separator: ":").first ?? ""))" } ?? ref,
                "type": "source-ref",
                "family": "source-ref",
                "typeLabel": "Literature",
                "status": ItemStatus.source.rawValue,
                "statusLabel": resolved == nil ? "Source not attached" : ItemStatus.source.displayName,
                // Fill solidity is computed client-side from statusRank; an unresolved
                // reference renders as a ghost — "attach the source" reads as unsettled.
                "statusRank": resolved == nil ? 0 : ItemStatus.source.rank,
                "color": resolved == nil ? "#9E9E9E" : ItemStatus.source.colorHex,
                "section": "",
                "statement": resolved?.statement ?? "*Attach the source to see this statement.*",
                "tags": [String]()
            ])
        }
        var edgeDicts: [[String: Any]] = edges.map { ["source": $0.to, "target": $0.from] }
        edgeDicts += externalReferences.map { ["source": $0.to, "target": $0.from] }
        let obj: [String: Any] = ["nodes": nodes, "edges": edgeDicts]
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// Compact JSON persisted as `graph.json` in the project folder.
    public func fileJSON() throws -> Data {
        let obj: [String: Any] = [
            "edges": edges.map { ["from": $0.from, "to": $0.to] },
            "missing": missingReferences.map { ["from": $0.from, "to": $0.to] }
        ]
        return try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
    }
}
