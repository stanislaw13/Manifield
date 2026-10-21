import SwiftUI
import ManifieldCore

struct ResearchLimitsEditor: View {
    @Binding var limits: ResearchLimits

    var body: some View {
        Toggle("Unlimited research execution", isOn: Binding(
            get: { limits == .unlimited }, set: { limits = $0 ? .unlimited : .init() }))
        Text("Usage is still recorded. Concurrency and context compaction remain separate settings.")
            .font(.caption).foregroundStyle(.secondary)
        row("Tool calls per turn", value: $limits.toolCalls, fallback: 24)
        row("Program tokens (input + output)", value: $limits.programTokens, fallback: 6_000_000)
        row("Tokens per assignment", value: $limits.assignmentTokens, fallback: 500_000)
        row("Program elapsed seconds", value: $limits.elapsedSeconds, fallback: 86_400)
        row("Plan revisions", value: $limits.planRevisions, fallback: 3, minimum: 0)
        row("Proof repair rounds", value: $limits.reviewRounds, fallback: 3)
    }

    private func row(_ title: String, value: Binding<ResearchLimit>, fallback: Int, minimum: Int = 1) -> some View {
        HStack {
            Text(title)
            Spacer()
            if let current = value.wrappedValue.value {
                TextField("Limit", value: Binding(get: { value.wrappedValue.value ?? current },
                    set: { value.wrappedValue = .bounded(max(minimum, $0)) }), format: .number)
                    .textFieldStyle(.roundedBorder).frame(width: 125)
            }
            Toggle("Unlimited", isOn: Binding(get: { value.wrappedValue == .unlimited },
                set: { value.wrappedValue = $0 ? .unlimited : .bounded(fallback) }))
                .toggleStyle(.checkbox).frame(width: 100, alignment: .leading)
        }
    }
}
