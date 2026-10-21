import Foundation
import ManifieldAgents

/// In-memory cache of live model lists fetched from each provider's API, shared between
/// Settings (which triggers the fetches) and the per-task model pickers (which just read
/// whatever's cached). Falls back to `ModelCatalog`'s curated list until a fetch succeeds.
@MainActor
final class ModelListCache: ObservableObject {
    static let shared = ModelListCache()

    @Published private(set) var models: [ProviderKind: [ModelOption]] = [:]
    @Published private(set) var loading: Set<ProviderKind> = []
    @Published private(set) var errors: [ProviderKind: String] = [:]

    private init() {}

    func options(for kind: ProviderKind) -> [ModelOption] {
        models[kind] ?? ModelCatalog.suggested(for: kind)
    }

    func displayName(for model: String, kind: ProviderKind) -> String {
        options(for: kind).first { $0.id == model }?.displayName ?? model
    }

    /// Metadata is authoritative only after a live listing succeeds. Curated fallbacks predate
    /// modality/effort advertisement and must not cause attachments to be rejected.
    func advertisedOption(for model: String, kind: ProviderKind) -> ModelOption? {
        models[kind]?.first { $0.id == model }
    }

    func supportsThinking(_ level: ThinkingLevel, for choice: ModelChoice) -> Bool {
        guard choice.kind == .codex,
              let option = advertisedOption(for: choice.model, kind: choice.kind),
              !option.supportedReasoningEfforts.isEmpty
        else { return true }
        if level == .off { return true } // CodexRunner maps this to the cheapest advertised effort.
        return option.supportedReasoningEfforts.map { $0.lowercased() }.contains(level.rawValue)
    }

    /// Fetches the live model list for `kind`. No-ops for an empty key (except `.codex`, which
    /// has none — it authenticates by ChatGPT sign-in, not a key, so gating on `apiKey` would
    /// freeze its picker on the curated fallback list forever) or a fetch already in flight;
    /// failures are recorded but leave the previous (or curated) list in place.
    func refresh(kind: ProviderKind, apiKey: String) {
        guard kind.usesAPIKey ? !apiKey.isEmpty : true, !loading.contains(kind) else { return }
        loading.insert(kind)
        errors[kind] = nil
        Task {
            do {
                let config = kind == .codex
                    ? ProviderConfig(kind: kind, apiKey: "",
                                     codexBinaryPath: AppSettings.codexPath.isEmpty ? nil : AppSettings.codexPath)
                    : ProviderConfig(kind: kind, apiKey: apiKey)
                let fetched = try await fetchAvailableModels(config: config)
                models[kind] = fetched
            } catch {
                errors[kind] = error.localizedDescription
            }
            loading.remove(kind)
        }
    }
}
