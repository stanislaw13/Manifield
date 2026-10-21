import SwiftUI
import ManifieldCore
import ManifieldAgents

/// The program's event log as a timeline: kind, the assignment it concerns as a link, when,
/// and a summary that stays short until opened. The raw live stream sits underneath while
/// the program runs.
struct PersistentLogTab: View {
    enum Filter: String, CaseIterable, Identifiable {
        case all, work, evidence, director
        var id: String { rawValue }

        var label: String {
            switch self {
            case .all: return "All"
            case .work: return "Work"
            case .evidence: return "Evidence & review"
            case .director: return "Director"
            }
        }

        func includes(_ kind: ResearchProgramEvent.Kind) -> Bool {
            switch self {
            case .all: return true
            case .work: return [.dispatched, .started, .reported, .stopped].contains(kind)
            case .evidence: return [.evidence, .reviewed].contains(kind)
            case .director: return [.guidance, .targetChanged, .directorPaused].contains(kind)
            }
        }
    }

    let program: ResearchProgram
    @ObservedObject var research: ResearchController
    let live: Bool
    let navigation: ResearchNavigation

    @State private var filter: Filter = .all
    @State private var query = ""
    @State private var newestFirst = true
    @State private var showConsole = true

    private var events: [ResearchProgramEvent] {
        let matching = (program.execution?.events ?? []).filter { event in
            guard filter.includes(event.kind) else { return false }
            guard !query.isEmpty else { return true }
            if event.summary.localizedCaseInsensitiveContains(query) { return true }
            return event.assignmentID.flatMap { program.assignment(id: $0) }?
                .displayTitle.localizedCaseInsensitiveContains(query) ?? false
        }
        return newestFirst ? matching.reversed() : matching
    }

    var body: some View {
        let shown = events
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Picker("Show", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                TextField("Search the log", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                Spacer()
                Button { newestFirst.toggle() } label: {
                    Label(newestFirst ? "Newest first" : "Oldest first", systemImage: "arrow.up.arrow.down")
                }
                if live {
                    Toggle(isOn: $showConsole) { Label("Live output", systemImage: "terminal") }
                        .toggleStyle(.button)
                }
            }
            if shown.isEmpty {
                ContentUnavailableView(query.isEmpty ? "No activity yet" : "No matching activity",
                                       systemImage: "list.bullet.rectangle")
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(shown.enumerated()), id: \.element.id) { index, event in
                            ProgramEventRow(event: event, program: program, navigation: navigation,
                                            lineLimit: 3, connectsBelow: index < shown.count - 1)
                        }
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .researchScrollGutter()
            }
            if live && showConsole {
                LiveConsole(text: research.log).frame(height: 200)
            }
        }
    }
}
