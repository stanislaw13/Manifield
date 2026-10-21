import SwiftUI
import ManifieldAgents

/// AI providers: the keys and sign-ins that let agents run at all, plus the provider and
/// model everything falls back to when a role has no override of its own.
struct SettingsProvidersPage: View {
    @ObservedObject private var modelCache = ModelListCache.shared
    @ObservedObject private var codexStatus = CodexAccountStatus.shared

    @State private var providerKind = AppSettings.providerKind
    @State private var models: [ProviderKind: String] = [:]
    @State private var keys: [ProviderKind: String] = [:]

    private func isConfigured(_ kind: ProviderKind) -> Bool {
        kind.usesAPIKey ? !(keys[kind] ?? "").isEmpty : codexStatus.isSignedIn
    }

    var body: some View {
        Form {
            Section {
                Picker("Provider", selection: $providerKind) {
                    ForEach(ProviderKind.allCases) { kind in
                        Text(isConfigured(kind) ? kind.displayName
                             : "\(kind.displayName) — \(kind.usesAPIKey ? "no API key" : "not signed in")")
                            .tag(kind)
                    }
                }
                .onChange(of: providerKind) { _, newValue in
                    AppSettings.providerKind = newValue
                }
                if !isConfigured(providerKind) {
                    Label(providerKind.usesAPIKey
                          ? "This provider has no API key yet — add one below or agents can't run on it."
                          : "Not signed in to Codex yet — sign in below or agents can't run on it.",
                          systemImage: "key.slash")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                HStack {
                    Picker(
                        "Model",
                        selection: binding(for: providerKind, in: $models,
                                           default: AppSettings.model(for: providerKind))
                    ) {
                        ForEach(modelOptions(for: providerKind)) { option in
                            Text(option.displayName).tag(option.id)
                        }
                    }
                    if modelCache.loading.contains(providerKind) {
                        ProgressView().controlSize(.small)
                    } else {
                        Button {
                            modelCache.refresh(kind: providerKind, apiKey: keys[providerKind] ?? "")
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                        .help("Refresh the model list from \(providerKind.displayName)")
                        .disabled(!isConfigured(providerKind))
                    }
                }
                .onChange(of: models) { _, newValue in
                    if let model = newValue[providerKind] {
                        AppSettings.setModel(model, for: providerKind)
                    }
                }
                if let error = modelCache.errors[providerKind] {
                    Text("Couldn't refresh model list: \(error)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("This is the fallback: any role left on “Default” in Roles runs here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                SettingsSectionHeader("Default provider and model", systemImage: "cpu")
            }

            Section {
                ForEach(ProviderKind.allCases.filter(\.usesAPIKey)) { kind in
                    SecureField(kind.displayName, text: binding(for: kind, in: $keys, default: ""))
                        .onSubmit {
                            Keychain.set(keys[kind] ?? "", account: kind.keychainAccount)
                            modelCache.refresh(kind: kind, apiKey: keys[kind] ?? "")
                        }
                }
                Text("Keys are saved when you press ⏎ in a field, and again when you leave this page. Manifield calls providers directly — your keys never leave this Mac except toward the provider itself.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                SettingsSectionHeader("API keys (stored in the macOS Keychain)",
                                      systemImage: "key.fill")
            }

            Section {
                CodexAccountSection()
            } header: {
                SettingsSectionHeader("Codex (ChatGPT account)",
                                      systemImage: "person.badge.key")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            for kind in ProviderKind.allCases {
                models[kind] = AppSettings.model(for: kind)
                guard kind.usesAPIKey else { continue }
                let key = Keychain.apiKey(for: kind) ?? ""
                keys[kind] = key
                modelCache.refresh(kind: kind, apiKey: key)
            }
            codexStatus.refresh()
            modelCache.refresh(kind: .codex, apiKey: "")
        }
        .onDisappear {
            // Also persist keys on close (and on leaving this page for another section) in
            // case the user didn't press ⏎.
            for kind in ProviderKind.allCases.filter(\.usesAPIKey) {
                Keychain.set(keys[kind] ?? "", account: kind.keychainAccount)
            }
        }
    }

    /// The catalog/live options for `kind`, plus the currently stored model id if it isn't
    /// among them — otherwise a Picker bound to that id would render as unselected (e.g. a
    /// live fetch can return dated snapshot ids instead of the alias already saved).
    private func modelOptions(for kind: ProviderKind) -> [ModelOption] {
        var options = modelCache.options(for: kind)
        let current = models[kind] ?? AppSettings.model(for: kind)
        if !options.contains(where: { $0.id == current }) {
            options.insert(ModelOption(id: current, displayName: current), at: 0)
        }
        return options
    }

    private func binding(
        for kind: ProviderKind,
        in dict: Binding<[ProviderKind: String]>,
        default defaultValue: String
    ) -> Binding<String> {
        Binding(
            get: { dict.wrappedValue[kind] ?? defaultValue },
            set: { dict.wrappedValue[kind] = $0 }
        )
    }
}
