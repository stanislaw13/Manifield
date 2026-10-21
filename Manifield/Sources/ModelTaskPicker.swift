import SwiftUI
import ManifieldAgents

/// Menu for choosing which model runs a given agent task — the global default or any
/// suggested model of any provider. Used in Settings and inline next to each task
/// (chat toolbar, import, prover, explorer), so e.g. imports of easy files can run on a
/// cheaper model without touching the rest.
struct ModelTaskPicker: View {
    let task: AgentTask
    /// Compact = icon + short model name (toolbars); otherwise full label.
    var compact = false

    @ObservedObject private var modelCache = ModelListCache.shared
    @State private var revision = 0

    private var current: ModelChoice? { AppSettings.modelChoice(for: task) }
    private var effective: ModelChoice { AppSettings.effectiveChoice(for: task) }

    /// Providers worth listing: those configured (API key, or a locatable Codex binary), plus
    /// whatever is already selected (so an existing choice never becomes invisible). Nothing
    /// configured → show everything, otherwise a fresh install would render an empty menu.
    private var listedKinds: [ProviderKind] {
        let configured = ProviderKind.allCases.filter(AppSettings.isProviderConfigured)
        guard !configured.isEmpty else { return ProviderKind.allCases }
        var kinds = configured
        for extra in [effective.kind, AppSettings.providerKind] where !kinds.contains(extra) {
            kinds.append(extra)
        }
        return ProviderKind.allCases.filter { kinds.contains($0) }
    }

    var body: some View {
        Menu {
            Button {
                AppSettings.setModelChoice(nil, for: task)
                revision += 1
            } label: {
                if current == nil { Image(systemName: "checkmark") }
                let defaultKind = AppSettings.providerKind
                Text("Default (\(modelCache.displayName(for: AppSettings.model(for: defaultKind), kind: defaultKind)))")
            }
            let kinds = listedKinds
            ForEach(kinds) { kind in
                Section(kind.displayName) {
                    ForEach(modelCache.options(for: kind)) { option in
                        Button {
                            AppSettings.setModelChoice(ModelChoice(kind: kind, model: option.id), for: task)
                            revision += 1
                        } label: {
                            if current == ModelChoice(kind: kind, model: option.id) {
                                Image(systemName: "checkmark")
                            }
                            Text(option.displayName)
                        }
                    }
                }
            }
            if kinds.count < ProviderKind.allCases.count {
                Text("Other providers appear here once their API key is set in Settings.")
            }
            Divider()
            Menu("Thinking — \(AppSettings.effectiveThinking(for: task).displayName)") {
                Button {
                    AppSettings.setThinkingLevel(nil, for: task)
                    revision += 1
                } label: {
                    if AppSettings.thinkingLevel(for: task) == nil { Image(systemName: "checkmark") }
                    Text("Default (\(task.defaultThinkingLevel.displayName))")
                }
                ForEach(ThinkingLevel.allCases) { level in
                    Button {
                        AppSettings.setThinkingLevel(level, for: task)
                        revision += 1
                    } label: {
                        if AppSettings.thinkingLevel(for: task) == level { Image(systemName: "checkmark") }
                        Text(level.displayName)
                    }
                    .disabled(!modelCache.supportsThinking(level, for: effective))
                }
                if effective.kind == .codex {
                    Text("Off uses the model's cheapest advertised reasoning effort when true off is unavailable.")
                }
            }
        } label: {
            let name = modelCache.displayName(for: effective.model, kind: effective.kind)
            if compact {
                Label(name, systemImage: "cpu")
            } else {
                Text(current == nil ? "Default — \(name)" : name)
            }
        }
        .id(revision)
        .help("Model used for \(task.displayName). Unlisted model ids can be set as the global default in Settings.")
    }
}
