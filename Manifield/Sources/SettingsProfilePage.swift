import SwiftUI

/// Profile: what Manifield knows about the person it is writing for.
///
/// It gets a page of its own because these are the only settings that change what the agents
/// *say* rather than what they are allowed to do, and because the fields that join them later
/// (notation habits, areas, what to assume known) belong beside them rather than scattered
/// through General.
struct SettingsProfilePage: View {
    @State private var name = AppSettings.userName
    @State private var profile = AppSettings.userProfile

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name, prompt: Text("What Prismo should call you"))
                    .onChange(of: name) { _, newValue in
                        AppSettings.userName = newValue
                    }
                Text("Used in chat only, and sparingly — a colleague who says your name in every sentence is not being friendly. Research branches, imports and the other background agents never see it: they have nobody to address, so a name in those prompts is context spent on nothing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                SettingsSectionHeader("Name", systemImage: "person.crop.circle")
            }

            Section {
                TextEditor(text: $profile)
                    .font(.body)
                    .frame(minHeight: 260)
                    .onChange(of: profile) { _, newValue in
                        AppSettings.userProfile = newValue
                    }
                Text("Example: “PhD student in extremal graph theory; comfortable with the probabilistic method; prefer combinatorial over algebraic arguments.” Prismo adapts its explanations to this — chat, the prover's write-ups, and the explorer's suggestions all read it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Saved as you type. Say what you already know as readily as what you don't: the most useful line here is usually the one that stops an agent re-deriving something you teach.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                SettingsSectionHeader("Your mathematical profile",
                                      systemImage: "person.text.rectangle")
            }
        }
        .formStyle(.grouped)
    }
}
