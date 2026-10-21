import SwiftUI
import ManifieldAgents

/// Roles: which model does which job, and how hard it thinks.
struct SettingsRolesPage: View {
    var body: some View {
        Form {
            Section {
                Text("Spend where the reasoning is: the researcher and the prover do the mathematics, the reviewer has to be strong enough to judge them, and the director only allocates. Anything left on “Default” runs on the provider and model set in AI Providers.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                ForEach(AgentTask.allCases) { task in
                    RoleRow(task: task)
                }
            } header: {
                SettingsSectionHeader("Roles", systemImage: "person.2.badge.gearshape")
            }
        }
        .formStyle(.grouped)
    }
}

/// One role in the Settings roles table: which model runs it, and how hard it thinks.
///
/// Both controls show "Default" when unset, and the row says what the default resolves to —
/// otherwise "Default" is an answer that hides the thing the user came here to find out.
struct RoleRow: View {
    let task: AgentTask

    @State private var revision = 0
    @ObservedObject private var modelCache = ModelListCache.shared

    private var thinkingBinding: Binding<String> {
        Binding(
            get: { AppSettings.thinkingLevel(for: task)?.rawValue ?? "" },
            set: { raw in
                AppSettings.setThinkingLevel(ThinkingLevel(rawValue: raw), for: task)
                revision += 1
            })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(task.displayName).font(.callout)
                Spacer()
                ModelTaskPicker(task: task)
                Picker("", selection: thinkingBinding) {
                    Text("Thinking: default").tag("")
                    ForEach(ThinkingLevel.allCases) { level in
                        Text(level.displayName).tag(level.rawValue)
                            .disabled(!modelCache.supportsThinking(level, for: AppSettings.effectiveChoice(for: task)))
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            Text(task.roleSummary)
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Runs on \(AppSettings.effectiveChoice(for: task).model) · thinking \(AppSettings.effectiveThinking(for: task).displayName.lowercased())")
                .font(.caption2.monospaced()).foregroundStyle(.tertiary)
                .id(revision)
        }
        .padding(.vertical, 3)
    }
}
