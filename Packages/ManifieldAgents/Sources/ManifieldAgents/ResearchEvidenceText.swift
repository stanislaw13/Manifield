import Foundation
import ManifieldCore

public enum ResearchEvidenceText {
    public static func assignmentTool(id assignmentID: String, scheduler: PersistentResearchScheduler) -> AgentTool {
        FunctionAgentTool(name: "read_assignment_evidence", description: "Read evidence explicitly supplied by the director, including its current trust and review status. Character pagination permits reading the full evidence.", schema: #"{"type":"object","properties":{"id":{"type":"string"},"offset":{"type":"integer"},"limit":{"type":"integer"}},"required":["id"]}"#) { _, json in
            let input = jsonObject(json), id = try requiredResearchString(input, "id"), p = await scheduler.snapshot()
            guard let a = p.execution?.assignments.first(where: { $0.id == assignmentID }),
                  (a.evidenceIDs + a.messages.flatMap(\.evidenceIDs)).contains(id) else {
                throw ResearchError(message: "Evidence has not been supplied to this assignment.")
            }
            let text: String
            if let f = p.findings.first(where: { $0.id == id }) { text = try researchJSON(f) }
            else if let c = p.solutions.first(where: { $0.id == id }) { text = try researchJSON(c) }
            else if let c = p.challenges.first(where: { $0.id == id }) { text = challenge(c) }
            else { throw ResearchError(message: "Unknown evidence ID.") }
            let offset = max(0, input["offset"] as? Int ?? 0), limit = min(20_000, max(1, input["limit"] as? Int ?? 12_000))
            return "Characters \(offset)..<\(min(text.count, offset + limit)) of \(text.count):\n" + String(text.dropFirst(offset).prefix(limit))
        }
    }
    public static func challenge(_ c: ProblemChallenge) -> String {
        var sections = ["Challenge \(c.id) · status \(c.status.rawValue) · target \(c.targetRevisionID)", c.description]
        if let r = c.mathematicalRuling { sections.append("Mathematical review: \(r.accepted ? "accepted" : "rejected")\n\(r.note)") }
        if let r = c.scopeRuling { sections.append("Scope review: \(r.accepted ? "accepted" : "rejected") · \(r.targetDisposition?.rawValue ?? "coverage unspecified")\n\(r.note)") }
        if let g = c.governance { sections.append("Director governance:\n\(g.rationale)") }
        if let replacement = c.proposedReplacementRequest { sections.append("Proposed correction:\n" + replacement) }
        sections.append("Evidence IDs: " + c.evidenceItemIDs.joined(separator: ", "))
        for id in c.evidenceItemIDs {
            if let data = c.evidenceItemData?[id] {
                sections.append("Filed evidence \(id):\n" + String(decoding: data, as: UTF8.self))
            }
        }
        return sections.joined(separator: "\n\n")
    }
}
