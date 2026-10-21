import Foundation
import ManifieldCore

/// Application history is authoritative. Provider sessions are disposable caches of this record.
public struct ResearchConversationRecord: Codable, Equatable, Sendable {
    public var messages: [LLMMessage] = []
    public var epoch: Int = 0
    public var eventCursor: Int = 0
    public var archives: [String] = []
    public var report: AssignmentReport?
    public var strategy: String?
    public var updatedAt: Date = Date()
    public init() {}
}

public actor ResearchConversation {
    public let key: String
    public let providerKey: String
    private let directory: URL
    private var record: ResearchConversationRecord

    public init(key: String, directory: URL) throws {
        // Keys may come from persisted IDs, never allow them to escape the session directory.
        guard !key.isEmpty, key.allSatisfy({ $0.isLetter || $0.isNumber || "-_".contains($0) }) else {
            throw ResearchError(message: "Invalid research session identifier.")
        }
        self.key = key; self.directory = directory
        self.providerKey = key + "-" + ResearchTargetRevision.sha256(Data(directory.standardizedFileURL.path.utf8)).prefix(16)
        let url = directory.appendingPathComponent(key + ".json")
        if FileManager.default.fileExists(atPath: url.path) {
            record = try JSONDecoder().decode(ResearchConversationRecord.self, from: Data(contentsOf: url))
        } else { record = .init() }
    }

    public func snapshot() -> ResearchConversationRecord { record }
    public func checkpoint(_ messages: [LLMMessage]) throws {
        record.messages = messages; try save()
    }
    public func append(_ text: String, cursor: Int? = nil) throws {
        record.messages.append(.user(text))
        if let cursor { record.eventCursor = cursor }
        try save()
    }
    public func report(_ report: AssignmentReport?) throws { record.report = report; try save() }
    public func setStrategy(_ text: String) throws { record.strategy = text; try save() }
    /// Committed together with the next tool-result checkpoint, never ahead of its acknowledgement.
    public func advanceCursor(_ cursor: Int) { record.eventCursor = max(record.eventCursor, cursor) }

    /// A checkpoint can end between intent and acknowledgement. Only replay director operations
    /// whose durable operation identity makes retries safe; arbitrary library writes are inspected.
    public func recover(tools: [AgentTool], replayable: Set<String> = []) async throws {
        let acknowledged = Set(record.messages.flatMap(\.blocks).compactMap { block -> String? in
            if case .toolResult(let id, _, _) = block { return id }; return nil
        })
        let pending = record.messages.flatMap(\.blocks).compactMap { block -> (String, String, String)? in
            if case .toolUse(let id, let name, let input) = block, !acknowledged.contains(id) {
                return (id, name, input)
            }; return nil
        }
        for (id, name, input) in pending {
            var text = "Execution was interrupted before acknowledgement. Inspect saved artifacts before repeating this operation."
            var isError = true
            if replayable.contains(name), let tool = tools.first(where: { $0.spec.name == name }) {
                do { text = try await tool.execute(callID: id, inputJSON: input); isError = false }
                catch { text = error.localizedDescription }
            }
            record.messages.append(.init(role: .user, blocks: [.toolResult(toolUseID: id, content: text, isError: isError)]))
            try save()
        }
    }

    public func compact(runner: AgentRunner, strategicState: String,
                        thinking: ThinkingLevel, onActivity: @escaping @Sendable (AgentActivity) -> Void) async throws {
        let archive = "\(key)-archive-\(record.epoch)"
        try write(record, named: archive) // Save all rejected approaches before discarding context.
        let config = AgentConfig(systemPrompt: """
            Summarize this research conversation for its continuation. Preserve the current strategy,
            exact unresolved gaps, rejected approaches and reasons, useful evidence IDs and trust,
            pending operations/questions, and intended next actions. Do not do new mathematics.
            The supplied durable state is authoritative; transcript claims are observations.
            Keep the handoff under 2500 words. An archive retains the complete conversation.
            """, maxTokens: 6000, thinking: thinking)
        let result = try await runner.run(config: config,
            history: record.messages + [.user("Prepare the continuation handoff.\n\n" + strategicState)],
            onActivity: onActivity)
        guard !result.finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ResearchError(message: "Compaction returned no handoff; the original history is preserved.")
        }
        record.archives.append(archive)
        record.epoch += 1
        record.messages = [.user("Conversation handoff (a summary, not independent evidence):\n\(result.finalText)\n\nDirector strategy:\n\(record.strategy ?? "Not recorded")\n\nDurable state:\n\(strategicState)\n\nFull history archive: \(archive)")]
        try save()
    }

    public func readArchive(name: String, offset: Int, limit: Int) throws -> String {
        guard record.archives.contains(name) else { throw ResearchError(message: "Unknown conversation archive.") }
        let data = try Data(contentsOf: directory.appendingPathComponent(name + ".json"))
        let text = String(decoding: data, as: UTF8.self)
        return String(text.dropFirst(max(0, offset)).prefix(min(max(1, limit), 20_000)))
    }

    private func save() throws { record.updatedAt = Date(); try write(record, named: key) }
    private func write(_ value: ResearchConversationRecord, named: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: directory.appendingPathComponent(named + ".json"), options: .atomic)
    }
}

func researchJSON<T: Encodable>(_ value: T) throws -> String {
    String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
}

func requiredResearchString(_ input: [String: Any], _ key: String) throws -> String {
    guard let text = input[key] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw ResearchError(message: "Missing '\(key)'.")
    }
    return text
}

func researchToolCalls(_ messages: [LLMMessage]) -> Int {
    messages.flatMap(\.blocks).filter { if case .toolUse = $0 { return true }; return false }.count
}
