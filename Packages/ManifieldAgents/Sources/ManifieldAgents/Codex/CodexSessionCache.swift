import Foundation

/// Native threads cache authoritative application history. Compaction and restart discard them.
actor CodexSessionCache {
    static let shared = CodexSessionCache()
    struct Entry {
        let threadID: String
        let server: any CodexServing
        let fingerprint: String
        let epoch: Int
        let history: [LLMMessage]
    }
    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    private var busy: Set<String> = []
    func acquire(_ key: String) throws -> Entry? {
        guard busy.insert(key).inserted else { throw AgentError.api("A provider turn is already running for this research conversation.") }
        order.removeAll { $0 == key }
        return entries.removeValue(forKey: key)
    }
    func release(_ key: String, entry: Entry?) async {
        busy.remove(key)
        if let entry { entries[key] = entry; order.append(key) }
        while order.count > 32 {
            let old = order.removeFirst()
            if let discarded = entries.removeValue(forKey: old) { await discarded.server.closeThread(discarded.threadID) }
        }
    }
    func remove(_ key: String) async {
        order.removeAll { $0 == key }
        if let entry = entries.removeValue(forKey: key) { await entry.server.closeThread(entry.threadID) }
    }
}
