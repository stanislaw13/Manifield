import SwiftUI
import ManifieldCore
import ManifieldAgents
import ManifieldSandbox
import ManifieldDiagnostics

/// The Research tab's planning flow: brainstorm approaches → pick them → review the
/// generated branch plans → approve. Takes over the whole tab while it is not `.idle`,
/// which is why it is an axis of its own rather than a `ResearchPage` case.
enum PlanningPhase: Equatable {
    case idle
    case brainstorming
    case selecting
    case reviewing
}

/// Which page the Research tab is showing. Full pages rather than a permanent split view:
/// a portfolio, a program's dashboard and one branch's plan each want the whole window,
/// and sharing it between a list and a detail column is what made the tab unreadable.
///
/// Lives on `AppState`, not in the view: the tab's views are destroyed and rebuilt on every
/// tab switch, so a route held in `@State` would send the user back to the list every time
/// they looked at their library.
enum ResearchPage: Equatable {
    case list
    case program(id: String)
    case branch(programID: String, planID: String)

    var programID: String? {
        switch self {
        case .list: return nil
        case .program(let id): return id
        case .branch(let programID, _): return programID
        }
    }
}

/// Which document the Memory tab is editing. Branches keep their own research memory —
/// that isolation is what stops a portfolio collapsing into one line of thought — so the
/// tab has to address more than the project's single `memory.md`. A literature source
/// opened as its own project adds its `overview.md`, which is otherwise only reachable
/// from a *different* project's Sources browser.
enum MemoryScope: Hashable {
    case project
    case branch(planID: String)
    /// A source's `overview.md` — the briefing every project citing it carries.
    case sourceOverview
}

/// Pre-fills the planner pane and starts it immediately. Set when the user corrects a
/// A problem the planner pane should pick up and start on when it next appears — the user
/// stated it once already, and retyping it to re-plan would be busywork.
struct PlannerSeed: Equatable {
    var problem: String
}

enum SidebarSelection: Hashable {
    case chat
    case graph
    case library
    case sources
    case importer
    case notation
    case memory
    case research
    /// One of the files kept with the project (`documents/<slug>/`), shown in its viewer.
    case document(slug: String)
}

/// What the Graph tab visualizes: the open project, or one attached source's own DAG.
enum GraphScope: Hashable {
    case project
    case source(String)  // slug of an attached source
}

/// Settings live in UserDefaults (keys in Keychain). Small enough to read directly.
enum AppSettings {
    static var providerKind: ProviderKind {
        get {
            ProviderKind(rawValue: UserDefaults.standard.string(forKey: "providerKind") ?? "")
                ?? .anthropic
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "providerKind") }
    }

    static func model(for kind: ProviderKind) -> String {
        let stored = UserDefaults.standard.string(forKey: "model.\(kind.rawValue)") ?? ""
        return stored.isEmpty ? kind.defaultModel : stored
    }

    static func setModel(_ model: String, for kind: ProviderKind) {
        UserDefaults.standard.set(model, forKey: "model.\(kind.rawValue)")
    }

    static var userProfile: String {
        get { UserDefaults.standard.string(forKey: "userProfile") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "userProfile") }
    }

    /// What Prismo calls the user in conversation. Chat only — a research branch or an
    /// import run has nobody to address, and a name in those prompts is context spent on
    /// nothing.
    static var userName: String {
        get { UserDefaults.standard.string(forKey: "userName") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "userName") }
    }

    /// One-time explanation shown the first time a chat is switched to Auto — direct
    /// library writes with no version control behind them warrant saying so once.
    static var hasSeenAutoModeNotice: Bool {
        get { UserDefaults.standard.bool(forKey: "hasSeenAutoModeNotice") }
        set { UserDefaults.standard.set(newValue, forKey: "hasSeenAutoModeNotice") }
    }

    static var pythonPath: String {
        get { UserDefaults.standard.string(forKey: "pythonPath") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "pythonPath") }
    }

    /// The address the user last typed into the feedback form, remembered so a second
    /// report does not mean typing it again. Never read by anything but that field — no
    /// report carries it unless the field is filled in at the time it is sent.
    static var feedbackEmail: String {
        get { UserDefaults.standard.string(forKey: "feedbackEmail") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "feedbackEmail") }
    }

    /// User override for the `codex` binary location. Empty (the default) means
    /// `CodexBinaryLocator`'s standard search order — the bundled ChatGPT.app copy first.
    static var codexPath: String {
        get { UserDefaults.standard.string(forKey: "codexPath") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "codexPath") }
    }

    /// Whether `kind` has what it needs to be worth offering in a picker: a non-empty Keychain
    /// key for the API-key providers, or a locatable `codex` binary for Codex. Sign-in isn't
    /// checked here — that's verified lazily when a turn actually runs, matching how another
    /// provider's key isn't verified to actually *work* before it's offered either.
    static func isProviderConfigured(_ kind: ProviderKind) -> Bool {
        guard kind.usesAPIKey else {
            return CodexBinaryLocator().locate(override: codexPath.isEmpty ? nil : codexPath) != nil
        }
        return !(Keychain.apiKey(for: kind) ?? "").isEmpty
    }

    /// How many source-import chunks run against the provider at once. Kept as a named
    /// property because a dozen call sites read it; the storage and clamping live with the
    /// other user-adjustable limits (see `AppSettings.Limit`).
    static var importConcurrency: Int {
        get { Limit.importConcurrency.value }
        set { Limit.importConcurrency.value = newValue }
    }

    /// "Don't show again" on the large-import cost warning.
    static var suppressLargeImportWarning: Bool {
        get { UserDefaults.standard.bool(forKey: "suppressLargeImportWarning") }
        set { UserDefaults.standard.set(newValue, forKey: "suppressLargeImportWarning") }
    }

    // MARK: Per-task model overrides (nil = use the global default above)

    static func modelChoice(for task: AgentTask) -> ModelChoice? {
        guard let data = UserDefaults.standard.data(forKey: "modelChoice.\(task.rawValue)") else { return nil }
        return try? JSONDecoder().decode(ModelChoice.self, from: data)
    }

    static func setModelChoice(_ choice: ModelChoice?, for task: AgentTask) {
        let key = "modelChoice.\(task.rawValue)"
        if let choice, let data = try? JSONEncoder().encode(choice) {
            UserDefaults.standard.set(data, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    /// The (provider, model) actually used for a task: its override, or the global default.
    static func effectiveChoice(for task: AgentTask) -> ModelChoice {
        if let override = modelChoice(for: task) { return override }
        if task == .director {
            // The director ran on the planner's model before it was separately
            // configurable, so an unconfigured one still does — the new setting adds a
            // knob without moving anybody's existing runs onto a different model.
            return effectiveChoice(for: .planner)
        }
        if task == .chatNaming {
            // Ride whatever provider is already proven-configured for chat, but pick its
            // cheapest cataloged model — titling should be light by default, not just
            // "whatever the user's main chat model happens to be."
            let chatKind = effectiveChoice(for: .chat).kind
            if let light = ModelCatalog.suggested(for: chatKind).last {
                return ModelChoice(kind: chatKind, model: light.id)
            }
        }
        return ModelChoice(kind: providerKind, model: model(for: providerKind))
    }

    // MARK: Per-task thinking overrides (nil = the task's built-in default)

    static func thinkingLevel(for task: AgentTask) -> ThinkingLevel? {
        guard let raw = UserDefaults.standard.string(forKey: "thinking.\(task.rawValue)") else { return nil }
        return ThinkingLevel(rawValue: raw)
    }

    static func setThinkingLevel(_ level: ThinkingLevel?, for task: AgentTask) {
        let key = "thinking.\(task.rawValue)"
        if let level {
            UserDefaults.standard.set(level.rawValue, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    static func effectiveThinking(for task: AgentTask) -> ThinkingLevel {
        if let own = thinkingLevel(for: task) { return own }
        // Same inheritance as the model: a director nobody has configured thinks exactly
        // as hard as the planner it used to be.
        if task == .director, let planner = thinkingLevel(for: .planner) { return planner }
        return task.defaultThinkingLevel
    }
}

@MainActor
final class AppState: ObservableObject {
    /// Injectable provider boundary for deterministic end-to-end research validation.
    var researchRunnerOverride: ((AgentTask) throws -> AgentRunner)?

    @Published var store: ProjectStore?
    @Published var selection: SidebarSelection = .library
    @Published var selectedItemID: String?
    @Published var libraryFilter: ItemType?
    /// Bumped whenever items change so web views (graph, detail) refresh.
    @Published var itemsVersion = 0
    /// Bumped whenever the project's kept files change (the store holds them, so the
    /// sidebar and viewer need the nudge).
    @Published var documentsVersion = 0
    /// File names currently being copied/extracted, for the "adding…" row.
    @Published var documentsInFlight: [String] = []
    /// Soft, inline feedback about a file (e.g. "no extractable text"); hard failures go
    /// to `openError`.
    @Published var documentNotice: String?
    /// Set when something hands the Import tab a file to work on (e.g. "Import items from
    /// this file" on a kept document); consumed by the tab on appear.
    @Published var importSeed: URL?
    /// Agent-proposed edits awaiting user confirmation (human-in-the-loop writes).
    /// Persisted per project so closing the sheet or the app never loses them.
    @Published var pendingProposals: [TheoryProposal] = [] {
        didSet {
            persistProposals()
            syncPendingFigureImages()
        }
    }
    @Published var showProposalsSheet = false
    @Published var openError: String? {
        // Everything that fails anywhere in the app raises this one alert, so a denial
        // left over from an earlier failure must never lend its "Choose Folder…" button to
        // an unrelated message. Clearing here makes that structural: the URL survives only
        // when it is set immediately after the message it belongs to, as `openProject` does.
        didSet { openAccessDenial = nil }
    }
    /// The folder to offer the open panel for, set alongside `openError` when an open
    /// failed because macOS refused access. See `ProjectAccess`: re-choosing the folder is
    /// what re-establishes the grant, and it is the only failure that route can fix — for
    /// a missing folder or a corrupt project.json this stays nil and the alert keeps its
    /// single OK button.
    @Published var openAccessDenial: URL?
    /// Set when a status downgrade breaks dependents — MainView shows the cascade dialog.
    @Published var pendingBreakage: BreakageInfo?

    struct BreakageInfo: Identifiable {
        let id = UUID()
        let sourceID: String
        let affectedIDs: [String]
    }
    /// Approach theses from planning pass 1, awaiting the user's multi-select.
    @Published var pendingApproachProposal: ApproachProposal?
    /// Consumed by the planner pane on appear; see `PlannerSeed`.
    @Published var plannerSeed: PlannerSeed?
    /// See `storeSolutionReviewCache`.
    private var solutionReviewCaches: [String: SolutionReviewGate.ReviewCache] = [:]
    /// Which page the Research tab is showing. See `ResearchPage`.
    @Published var researchPage: ResearchPage = .list
    /// Which memory the Memory tab shows. Set by the Research tab's per-branch link, so
    /// jumping from a branch to its memory lands on the right document.
    @Published var selectedMemory: MemoryScope = .project
    /// Which step of planning the Research tab is showing. Planning renders inline as a
    /// section rather than a modal, so a long plan gets the full window and the sidebar
    /// stays usable.
    @Published var planningPhase: PlanningPhase = .idle
    /// Research plans in the open project (plans/*.md), newest first.
    @Published var plans: [PlanDocument] = []
    /// Research programs in the open project (programs/*.json), newest first.
    @Published var programs: [ResearchProgram] = []
    /// Literature sources attached to the open project, with their loaded stores.
    @Published var attachedSources: [(ref: SourceRef, store: ProjectStore)] = []
    /// Attached refs whose folders could not be opened (moved/deleted).
    @Published var brokenSourceRefs: [SourceRef] = []
    /// Which source the Sources tab shows; nil = the all-sources list page.
    @Published var selectedSourceSlug: String?
    /// Selected item within the shown source (also set by graph click-through).
    @Published var selectedSourceItemID: String?
    /// What the Graph tab shows; falls back to .project when its source detaches.
    @Published var graphScope: GraphScope = .project

    let chat = ChatController()
    /// Owns planning pass 2 so a half-generated program survives tab switches.
    let planning = ProgramPlanningController()
    let research = ResearchController()
    let sourceLibrary = SourceLibrary()
    /// Machine-local library import — keeps running across sheet dismissal, tab
    /// switches, and even project switches.
    let sourceImport = SourceImportController()
    /// Project import (Import tab) — survives navigating away from the tab.
    let theoryImport = TheoryImportController()

    private var reloadDebounce: DispatchWorkItem?
    private var sourceReloadDebounces: [String: DispatchWorkItem] = [:]

    // MARK: - Recent projects

    var recentProjects: [URL] {
        (UserDefaults.standard.stringArray(forKey: "recentProjects") ?? [])
            .map { URL(fileURLWithPath: $0) }
            // Forget a project only when it is actually gone. A folder the app is merely
            // not allowed to look into is still recoverable through the open panel, and
            // dropping its row would hide the one way back — see `ProjectAccess.isMissing`.
            .filter { !ProjectAccess.isMissing($0) }
    }

    private func rememberRecent(_ url: URL) {
        var paths = UserDefaults.standard.stringArray(forKey: "recentProjects") ?? []
        paths.removeAll { $0 == url.path }
        paths.insert(url.path, at: 0)
        UserDefaults.standard.set(Array(paths.prefix(8)), forKey: "recentProjects")
    }

    // MARK: - Project lifecycle

    func openProject(at url: URL) {
        do {
            let store = try ProjectStore(opening: url)
            attach(store)
            rememberRecent(url)
            // `.handle`, never `.path`: a project folder is named by the user after what
            // they are working on, and an unpublished theorem's name is exactly the kind
            // of thing that must not reach a log. The handle is stable, so two lines about
            // the same project still line up.
            Diagnostics.log.info("project.opened", category: .project, [
                ("project", .handle(url.path)),
                ("items", .count(store.items.count)),
                ("kind", .symbol(store.meta.kind?.rawValue ?? "workspace"))
            ])
        } catch {
            // A denial is recoverable and nothing else is, so the two get different words
            // and different buttons. `denied` is a `.flag`, never the reason text — the
            // privacy rule above covers everything this line carries.
            let denied = ProjectAccess.isPermissionDenied(error)
            openError = denied ? ProjectAccess.permissionMessage(for: url) : error.localizedDescription
            openAccessDenial = denied ? url : nil
            Diagnostics.log.failure("project.open.failed", category: .project, error: error,
                                    [("project", .handle(url.path)), ("denied", .flag(denied))])
        }
    }

    func createProject(at url: URL) {
        do {
            let store = try ProjectStore.create(at: url, name: url.lastPathComponent)
            attach(store)
            rememberRecent(url)
            Diagnostics.log.info("project.created", category: .project, [
                ("project", .handle(url.path))
            ])
        } catch {
            openError = error.localizedDescription
            Diagnostics.log.failure("project.create.failed", category: .project, error: error,
                                    [("project", .handle(url.path))])
        }
    }

    private func attach(_ store: ProjectStore) {
        self.store = store
        // The figure scheme handler resolves ids against whatever is open here.
        FigureResolver.shared.store = store
        selection = store.items.isEmpty ? .importer : .library
        selectedItemID = store.items.first?.id
        selectedSourceSlug = nil
        selectedSourceItemID = nil
        graphScope = .project
        // Also clears a branch scope left over from the previous project, whose plan id
        // means nothing here. A source opens on its overview: that is the document about
        // the work, and its research memory is usually empty.
        selectedMemory = store.meta.kind == .source ? .sourceOverview : .project
        restoreProposals(from: store)
        restoreJournal(from: store)
        loadAttachedSources()
        reloadPlans()
        itemsVersion += 1
        chat.attach(appState: self)
        research.attach(appState: self)
        planning.attach(appState: self)
        // A theory import (and its review) targets one project; a source import
        // targets the machine-local library and keeps running.
        theoryImport.reset()

        store.startWatching { [weak self] in
            guard let self else { return }
            self.reloadDebounce?.cancel()
            let work = DispatchWorkItem { self.reloadFromDisk() }
            self.reloadDebounce = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        }
    }

    func closeProject() {
        if let store { Diagnostics.log.info("project.closed", category: .project,
                                           [("project", .handle(store.rootURL.path))]) }
        store?.stopWatching()
        for source in attachedSources { source.store.stopWatching() }
        store = nil
        FigureResolver.shared.store = nil
        selectedItemID = nil
        pendingProposals = []
        pendingApproachProposal = nil
        plans = []
        programs = []
        attachedSources = []
        brokenSourceRefs = []
        selectedSourceSlug = nil
        selectedSourceItemID = nil
        graphScope = .project
    }

    // MARK: - Research plans

    func reloadPlans() {
        plans = store?.loadPlans().plans ?? []
        programs = store?.loadPrograms().programs ?? []
    }

    /// Every plan belongs to a program: real ones come from `programs/`, and a standalone
    /// plan is wrapped in a virtual program so the UI and runner have one shape to handle.
    /// Nothing on disk changes — legacy plans keep working untouched.
    var allPrograms: [ResearchProgram] {
        let standalone = plans.filter { $0.program == nil }.map(ResearchProgram.virtual(plan:))
        return (programs + standalone).sorted { $0.created > $1.created }
    }

    func program(id: String) -> ResearchProgram? {
        allPrograms.first { $0.id == id }
    }

    /// The plans backing a program's branches, in manifest order.
    func branchPlans(of program: ResearchProgram) -> [PlanDocument] {
        let ids = program.execution?.assignments.compactMap(\.planID) ?? program.branches.map(\.planID)
        return ids.compactMap { id in
            plans.first { $0.id == id }
        }
    }

    /// Reads the document a scope addresses. Absent files read as empty, which is the same
    /// thing a branch that has not written anything yet should show.
    func memory(for scope: MemoryScope) -> String {
        guard let store else { return "" }
        switch scope {
        case .project: return store.memory
        case .branch(let planID): return store.loadBranchMemory(planID: planID)
        case .sourceOverview: return store.overview
        }
    }

    func saveMemory(_ text: String, for scope: MemoryScope) throws {
        guard let store else { throw CoreError.io("No project open") }
        switch scope {
        case .project: try store.saveMemory(text)
        case .branch(let planID): try store.saveBranchMemory(planID: planID, text: text)
        case .sourceOverview: try store.saveOverview(text)
        }
    }

    /// Human label for a memory scope — the branch's title from its manifest where there
    /// is one, falling back to the plan id.
    func memoryTitle(for scope: MemoryScope) -> String {
        switch scope {
        case .project:
            return "Project memory"
        case .sourceOverview:
            return "Source overview"
        case .branch(let planID):
            for program in allPrograms {
                if let branch = program.branch(planID: planID), !branch.title.isEmpty {
                    return branch.title
                }
            }
            return planID
        }
    }

    /// Whether the Memory tab offers the source overview: always for a source, and for
    /// anything else only if an `overview.md` is actually there — a file that exists
    /// should never be invisible just because the project's kind says it shouldn't be.
    var showsSourceOverview: Bool {
        guard let store else { return false }
        return store.meta.kind == .source
            || !store.overview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Opens a branch's memory in the Memory tab.
    func showMemory(forBranch planID: String) {
        selectedMemory = .branch(planID: planID)
        selection = .memory
    }

    /// One selected approach with its generated task list and per-branch settings.
    struct ApprovedBranch {
        var approach: ApproachProposal.Approach
        var option: PlanProposal.Option
        var tokenBudget: Int
        var providerKind: String?
        var model: String?
    }

    /// Writes a research program: one plan file per branch (carrying its lens, stance and
    /// kill criterion) plus the manifest that groups and schedules them.
    func approveProgram(
        goal: String,
        title: String,
        branches: [ApprovedBranch],
        skippedCells: [ResearchProgram.SkippedCell],
        programTokenBudget: Int,
        maxConcurrentBranches: Int,
        runMode: RunMode,
        contract: SuccessContract? = nil,
        continuation: ContinuationPolicy? = nil,
        pilotsEnabled: Bool = true,
        targetItemID: String,
        initialFindings: [ProgramFinding] = [],
        initialSolutions: [SolutionCandidate] = [],
        roleModelOverrides: [String: ResearchProgram.ModelOverride] = [:],
        adoptTurnsFromSession: String? = nil,
        // A program with no branches and no accepted answer is normally pointless — nothing
        // would ever run it. That stopped being true once the runner could convene the
        // director on an empty roster and have it dispatch the first work itself (a zero-
        // branch program is vacuously "every branch terminal", so the director's first
        // convening happens on the program's very first `run()`). Explicit opt-in: every
        // existing caller keeps the exact guard it always had.
        allowEmptyForDirector: Bool = false
    ) throws -> ResearchProgram {
        guard let store else { throw CoreError.io("No project open") }
        guard let targetItem = store.item(id: targetItemID),
              let targetStatement = targetItem.statement?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !targetStatement.isEmpty else {
            throw CoreError.io("A program needs a formal research-goal theory item with a Statement")
        }
        if let contract,
           contract.statement.trimmingCharacters(in: .whitespacesAndNewlines) != targetStatement {
            throw CoreError.io("The success contract must be the frozen Statement of goal item '\(targetItemID)'")
        }
        let formalGoal = targetStatement
        guard !branches.isEmpty || allowEmptyForDirector
            || initialSolutions.contains(where: { $0.status == .accepted }) else {
            throw CoreError.io("A program needs a branch or an independently accepted answer")
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        // The short title makes a far better id slug than the directive goal sentence.
        var programID = "\(dateFormatter.string(from: Date()))-\(TheoryItem.sanitizeID(title.isEmpty ? goal : title))"
        if store.program(id: programID) != nil {
            programID += "-\(Int(Date().timeIntervalSince1970) % 10_000)"
        }

        let approvedAt = ISO8601DateFormatter().string(from: Date())
        var manifestBranches: [ResearchProgram.Branch] = []
        for (position, branch) in branches.enumerated() {
            var planID = "\(programID)-\(TheoryItem.sanitizeID(branch.approach.title))"
            if store.plan(id: planID) != nil {
                planID += "-\(manifestBranches.count + 1)"
            }
            let plan = PlanDocument(
                id: planID,
                goal: formalGoal,
                status: .approved,
                runMode: runMode,
                tokenBudget: branch.tokenBudget,
                goalText: formalGoal,
                approach: "\(branch.approach.title): \(branch.approach.mechanism)",
                tasks: branch.option.tasks,
                log: ["\(approvedAt) branch approved as part of program \(programID)"],
                program: programID,
                challengesLeadingAnswer: branch.approach.challengesLeadingAnswer,
                kill: branch.approach.killCriterion,
                lens: branch.approach.prior
            )
            try store.savePlan(plan)
            // The user's explicit model pick wins; failing that, the planner's tier choice.
            let tierOverride = branch.providerKind == nil && branch.model == nil
                ? strongTierOverride(for: branch.approach.modelTier) : nil
            manifestBranches.append(ResearchProgram.Branch(
                planID: planID,
                title: branch.approach.title,
                challengesLeadingAnswer: branch.approach.challengesLeadingAnswer,
                costClass: branch.approach.costClass,
                providerKind: branch.providerKind ?? tierOverride?.providerKind,
                model: branch.model ?? tierOverride?.model,
                // The list order IS the attack order — pass 1 was told to rank by judgment.
                priority: position))
        }

        // Generation 1's routes: one per branch, so the registry knows what has been tried
        // from the first run rather than only from the director's first turn.
        let routes = zip(branches, manifestBranches).map { approved, manifest in
            ResearchRoute(planID: manifest.planID,
                          mechanism: approved.approach.mechanism,
                          status: .active,
                          nextTest: approved.option.tasks.first?.title,
                          generation: 1)
        }

        let targetRevision = try store.makeResearchTargetRevision(
            requestText: formalGoal, libraryItemID: targetItemID,
            changeNote: contract?.reviewedAt == nil
                ? "Automatically formalized from the retained user request; interpretation not user-confirmed."
                : "Formalized from the retained user request and confirmed during program review.")
        let stampedFindings = initialFindings.map { finding -> ProgramFinding in
            var finding = finding
            finding.targetRevisionID = targetRevision.id
            return finding
        }
        let stampedSolutions = initialSolutions.map { candidate -> SolutionCandidate in
            var candidate = candidate
            candidate.targetRevisionID = targetRevision.id
            return candidate
        }
        var program = ResearchProgram(
            id: programID,
            // Historical input only. Research agents receive the formal target revision.
            goal: goal,
            title: title,
            targetRevisions: [targetRevision],
            activeTargetRevisionID: targetRevision.id,
            // Empty and *not* explained by an already-accepted answer means the director is
            // expected to pick this up — active, not done, so `startProgram` actually runs it.
            status: branches.isEmpty && !allowEmptyForDirector ? .done : .active,
            contract: contract,
            continuation: continuation,
            pilotsEnabled: pilotsEnabled,
            maxConcurrentBranches: maxConcurrentBranches,
            programTokenBudget: programTokenBudget,
            branches: manifestBranches,
            routes: routes,
            findings: stampedFindings,
            solutions: stampedSolutions,
            roleModelOverrides: roleModelOverrides,
            skippedCells: skippedCells)
        var executionLimits = AppSettings.researchLimits
        executionLimits.programTokens = programTokenBudget == .max ? .unlimited : .bounded(programTokenBudget)
        var execution = ResearchExecution(limits: executionLimits)
        execution.assignments = manifestBranches.map { branch in
            var assignment = ResearchAssignment(id: branch.planID, operationID: "approved-" + branch.planID,
                programID: programID, targetRevisionID: targetRevision.id, mode: .planned,
                objective: branch.title, tokenLimit: executionLimits.assignmentTokens)
            assignment.planID = branch.planID
            return assignment
        }
        if program.status == .done, let solution = stampedSolutions.first(where: { $0.status == .accepted }) {
            execution.resolution = .init(kind: .answered, targetRevisionID: targetRevision.id,
                evidenceIDs: [solution.id], explanation: solution.argument)
        }
        program.execution = execution
        try store.saveProgram(program)
        // The front half ran before this program had an id, under the planning session's. Move
        // its turns in now, so the audit, the contract, the pilots and the portfolio are part of
        // the program's history rather than orphaned under an id nothing looks up.
        if let adoptTurnsFromSession {
            try? store.adoptTurns(fromSession: adoptTurnsFromSession, toProgram: programID)
            try? store.adoptUsageLedger(fromSession: adoptTurnsFromSession, toProgram: programID)
        }
        let ledgerTokens = store.usageTokens(programID: programID)
        program.planningTokensUsed = ledgerTokens > 0
            ? ledgerTokens
            : store.turnSummaries(programID: programID).reduce(0) { $0 + $1.tokensUsed }
        try store.saveProgram(program)
        reloadPlans()
        return program
    }

    /// The (provider, model) pair for a "strong"-tier branch: the prover task's configuration,
    /// which is where the user already points their strongest model. Nil when the tier is
    /// default or the prover task is unconfigured — the branch then runs on the researcher
    /// default rather than failing.
    func strongTierOverride(
        for modelTier: String?
    ) -> (providerKind: String, model: String)? {
        guard modelTier == "strong", let config = try? providerConfig(for: .prover) else {
            return nil
        }
        return (config.kind.rawValue, config.model)
    }

    /// Turns the director's routes into runnable branches and appends them to a live program.
    ///
    /// This is the step that closes the research loop: without it the director can decide to
    /// continue and the program still stops, because routes are not plans. Each route goes
    /// through the ordinary pass-2 branch planner, so a generation-2 branch is built exactly
    /// like a generation-1 one and every existing mechanism applies to it unchanged.
    @discardableResult
    func appendGeneration(
        to program: ResearchProgram,
        routes: [ResearchRoute],
        tokenBudget: Int,
        onProgress: @MainActor (ResearchRoute) -> Void = { _ in }
    ) async throws -> (program: ResearchProgram, plans: [String: PlanDocument]) {
        guard let store else { throw CoreError.io("No project open") }
        guard !program.isVirtual else {
            throw CoreError.io("A standalone plan has no program to extend")
        }

        // Governance may have advanced the target after the caller captured `program`.
        // Re-read it, then run the same goal editor used at program creation. The director's
        // replacement prose is not handed straight to branches: it first becomes a complete
        // selected/created theory item and a new frozen revision.
        var working = store.program(id: program.id) ?? program
        if working.contract == nil, working.targetRevisions.count > 1 {
            let provisional = working.activeTargetRevision
            let context = try makeResearchGoalEditorContext()
            guard let formalized = try await ResearchGoalEditor.run(
                runner: context.runner, request: provisional.requestText,
                store: context.store, tools: context.tools,
                notation: context.notation, macros: context.macros,
                outline: context.outline, thinking: context.thinking,
                programID: working.id, record: makeTurnRecorder(),
                applyCreate: context.applyCreate) else {
                throw CoreError.io("The governed replacement could not be turned into a formal goal item; no branches were opened.")
            }
            var revision = try store.makeResearchTargetRevision(
                requestText: formalized.draft.contract.statement,
                libraryItemID: formalized.item.id,
                parentRevisionID: provisional.id,
                proposedByChallengeID: provisional.proposedByChallengeID,
                changeNote: "Formal goal item adopted after two accepted challenge reviews and director governance; automatic interpretation not user-confirmed.")
            revision.statement = formalized.draft.contract.statement
            revision.recommendedReading = formalized.draft.contract.recommendedReading
            revision.ambiguities = formalized.draft.contract.ambiguities
            working.appendTargetRevision(revision)
            working.contract = formalized.draft.contract
            if let challengeIndex = working.challenges.firstIndex(where: {
                $0.governance?.newTargetRevisionID == provisional.id
            }) {
                working.challenges[challengeIndex].governance?.newTargetRevisionID = revision.id
            }
            try store.saveProgram(working)
        }

        guard !routes.isEmpty else { return (working, [:]) }
        let generationProposal = ApproachProposal(
            goal: working.researchRequest,
            title: working.displayName,
            approaches: routes.map(Self.approach(from:)),
            skippedCells: [])
        let durableEvidence = working.findings.filter { !$0.isRejected }.map {
            "- [\($0.kind.rawValue)] \($0.statement)"
        }.joined(separator: "\n")
        let (coverageRunner, coverageThinking) = try makePortfolioAuditorContext()
        let coverage = try await PortfolioAuditor.audit(
            runner: coverageRunner, goal: working.researchRequest, contract: working.contract,
            proposal: generationProposal,
            evidenceDigest: durableEvidence.isEmpty
                ? "No finding predates this proposal. That is expected before the first "
                    + "director-opened branches run and is context, not a coverage defect."
                : "Durable findings from earlier generations:\n\(durableEvidence)",
            thinking: coverageThinking, programID: working.id,
            record: makeTurnRecorder())

        let generation = (working.routes?.map(\.generation).max() ?? 1) + 1
        let approvedAt = ISO8601DateFormatter().string(from: Date())

        // Rejected coverage used to throw here, discarding the routes entirely — the director's
        // very next convening would see the identical empty registry and could propose the same
        // inadequate portfolio again. There is also no live conversation left to repair from:
        // these routes are a finished decision from a director turn that already ended, not an
        // in-progress planner reply the way a first portfolio's repair-and-reaudit pass has.
        // Recording them as blocked, with the auditor's own gaps as the obstruction, reuses the
        // registry mechanism the director already reads and already respects ("you may not
        // re-propose a mechanism that is already here") — its next turn sees exactly what was
        // wrong and can revise, dispatch something narrower instead, or call it futile, rather
        // than a hand-authored repair stage second-guessing it on its behalf.
        guard coverage.accepted else {
            var updated = working
            let blocked = routes.map { route -> ResearchRoute in
                var blocked = route
                blocked.status = .blocked
                blocked.obstruction = coverage.feedback
                blocked.generation = generation
                return blocked
            }
            let blockedIDs = Set(blocked.map(\.id))
            updated.routes = (updated.routes ?? []).filter { !blockedIDs.contains($0.id) } + blocked
            updated.updated = Date()
            try store.saveProgram(updated)
            return (updated, [:])
        }
        var updated = working
        var placed: [ResearchRoute] = []
        var newPlans: [String: PlanDocument] = [:]
        // New branches run after whatever the previous generation left, in the director's
        // proposal order — it was told the listed order is the attack order.
        var nextPriority = (updated.branches.compactMap(\.priority).max() ?? -1) + 1

        for route in routes {
            onProgress(route)
            // The route is a mechanism and a decisive test; pass 2 turns that into a task list.
            let approach = Self.approach(from: route)
            let captured = OptionBox()
            let (runner, config) = try makeBranchPlannerConfig(
                approach: approach, goal: working.researchRequest, contract: working.contract,
                onProposal: { captured.set($0) },
                onDecline: { captured.decline($0) })
            _ = try await runRecordedTurn(
                runner: runner, config: config,
                history: [.user(ProgramPlanner.pass2UserMessage(
                    approach: approach, goal: working.researchRequest))],
                programID: working.id, role: .branchPlan,
                title: "Task list — \(approach.title)",
                record: makeTurnRecorder(),
                outcome: { _ in
                    captured.value.map { "\($0.tasks.count) task(s)" }
                        ?? "no task list proposed"
                })
            guard let option = captured.value else {
                // One route failing to plan must not cost the rest of the generation.
                var failed = route
                failed.status = .blocked
                failed.obstruction = captured.declineReason
                    ?? "the planner produced no task list for this route"
                failed.generation = generation
                placed.append(failed)
                continue
            }

            var planID = "\(working.id)-g\(generation)-\(TheoryItem.sanitizeID(approach.title))"
            if store.plan(id: planID) != nil { planID += "-\(placed.count + 1)" }
            let plan = PlanDocument(
                id: planID,
                goal: working.researchRequest,
                status: .approved,
                runMode: .auto,
                tokenBudget: tokenBudget,
                goalText: working.researchRequest,
                approach: "\(approach.title): \(approach.mechanism)",
                tasks: option.tasks,
                log: ["\(approvedAt) branch opened by the director as generation \(generation)"],
                program: working.id,
                challengesLeadingAnswer: approach.challengesLeadingAnswer,
                kill: approach.killCriterion,
                lens: approach.prior)
            try store.savePlan(plan)
            newPlans[planID] = plan

            let tierOverride = strongTierOverride(for: route.modelTier)
            updated.branches.append(ResearchProgram.Branch(
                planID: planID, title: approach.title,
                challengesLeadingAnswer: approach.challengesLeadingAnswer,
                costClass: approach.costClass,
                providerKind: tierOverride?.providerKind,
                model: tierOverride?.model,
                priority: nextPriority))
            nextPriority += 1
            var live = route
            live.planID = planID
            live.status = .active
            live.generation = generation
            placed.append(live)
        }

        // Replace the proposed entries with their placed versions, keeping earlier generations.
        let placedIDs = Set(placed.map(\.id))
        updated.routes = (updated.routes ?? []).filter { !placedIDs.contains($0.id) } + placed
        updated.status = .active
        updated.updated = Date()
        try store.saveProgram(updated)
        reloadPlans()
        return (updated, newPlans)
    }

    /// A route as the branch planner expects an approach.
    private static func approach(from route: ResearchRoute) -> ApproachProposal.Approach {
        ApproachProposal.Approach(
            title: String(route.mechanism.prefix(80)),
            mechanism: route.mechanism,
            prior: """
            You are working this route: \(route.mechanism). \
            \(route.assumptions.isEmpty ? "" : "It assumes: \(route.assumptions.joined(separator: "; ")). ")\
            The director opened this branch because that mechanism has not been tried in this \
            program. Work it on its own terms rather than drifting back toward what earlier \
            branches did.
            """,
            expectedPayoff: route.nextTest.map {
                "The decisive test is \($0); running it either advances this mechanism or rules it out."
            } ?? "",
            ontologyCells: [route.mechanism],
            killCriterion: route.nextTest.map {
                "The decisive test — \($0) — has been run and its result rules this mechanism out."
            } ?? "The mechanism is shown not to reach the target.")
    }

    // MARK: - Closing out and deleting

    /// True while this program (or the plan behind a virtual one) is the live run.
    private func isRunningNow(programID: String) -> Bool {
        research.isRunning && research.isActive(programID: programID)
    }

    /// Edits a saved program's settings in place — autonomy, budgets, concurrency, per-branch
    /// models. Everything here was previously frozen at approval with no way even to see it
    /// afterwards, which is why an overnight run could not be retuned without rebuilding it.
    ///
    /// A running program is refused: the runner captured its manifest at launch, so an edit
    /// mid-run would show as saved while changing nothing until the next start.
    func updateProgram(_ program: ResearchProgram,
                       _ mutate: (inout ResearchProgram) -> Void) throws {
        guard let store else { throw CoreError.io("No project open") }
        guard !program.isVirtual else {
            throw CoreError.io("A standalone plan has no program settings to edit.")
        }
        guard !isRunningNow(programID: program.id) else {
            throw CoreError.io("Stop the run before changing this program's settings — the running program is using the values it started with.")
        }
        var updated = store.program(id: program.id) ?? program
        mutate(&updated)
        try store.saveProgram(updated)
        reloadPlans()
    }

    /// Sets a program's status by hand — marking a portfolio done, failed, or discarded.
    /// A virtual program has no manifest, so the status lands on its single plan instead.
    func setProgramStatus(_ status: ResearchProgram.Status, for program: ResearchProgram) throws {
        guard let store else { throw CoreError.io("No project open") }
        guard !isRunningNow(programID: program.id) else {
            throw CoreError.io("Stop the run before changing this program's status.")
        }
        if program.isVirtual {
            guard let planID = program.branches.first?.planID else { return }
            try setPlanStatus(PlanStatus(rawValue: status.rawValue) ?? .abandoned, forPlan: planID)
            return
        }
        var updated = program
        updated.status = status
        try store.saveProgram(updated)
        reloadPlans()
    }

    /// Sets one branch's status — the common case being "this approach failed", which is
    /// a result worth recording rather than a plan left half-run.
    func setPlanStatus(_ status: PlanStatus, forPlan planID: String) throws {
        guard let store else { throw CoreError.io("No project open") }
        guard var plan = store.plan(id: planID) else { throw CoreError.io("Plan not found") }
        guard !(research.isRunning && research.record(of: planID) != nil) else {
            throw CoreError.io("Stop the run before changing this branch's status.")
        }
        guard plan.status != status else { return }
        plan.status = status
        plan.log.append("\(ISO8601DateFormatter().string(from: Date())) "
            + "status set to \(status.rawValue) by user")
        try store.savePlan(plan)
        reloadPlans()
    }

    /// Closes a branch out with a recorded reason. Shared by the user's branch menu and
    /// chat's `close_branch`, so both land the same log line.
    func closeBranch(planID: String, status: PlanStatus, reason: String) throws {
        guard let store else { throw CoreError.io("No project open") }
        guard var plan = store.plan(id: planID) else { throw CoreError.io("Plan not found") }
        guard !(research.isRunning && research.record(of: planID) != nil) else {
            throw CoreError.io("This branch is running — stop the run before closing it out.")
        }
        plan.status = status
        plan.log.append("\(ISO8601DateFormatter().string(from: Date())) "
            + "\(status.rawValue): \(reason)")
        try store.savePlan(plan)
        reloadPlans()
    }

    /// Deletes a program and everything it owns. Irreversible, and the caller is expected
    /// to have confirmed — this only refuses while the program is the live run.
    func deleteProgram(_ program: ResearchProgram) throws {
        guard let store else { throw CoreError.io("No project open") }
        guard !isRunningNow(programID: program.id) else {
            throw CoreError.io("Stop the run before deleting this program.")
        }
        try store.deleteProgram(program)
        reloadPlans()
    }

    /// Deletes one branch plan, leaving the rest of its program intact. The manifest entry
    /// goes too, or the program would list a branch whose file no longer exists.
    func deleteBranch(planID: String, from program: ResearchProgram) throws {
        guard let store else { throw CoreError.io("No project open") }
        guard !isRunningNow(programID: program.id) else {
            throw CoreError.io("Stop the run before deleting a branch.")
        }
        try store.deletePlan(id: planID)
        if !program.isVirtual {
            var updated = program
            updated.branches.removeAll { $0.planID == planID }
            // Findings published by a branch that no longer exists would cite a dead id.
            updated.findings.removeAll { $0.branchPlanID == planID }
            try store.saveProgram(updated)
        }
        reloadPlans()
    }

    /// Saves user edits to an approved plan (tasks, lens, kill criterion, budget).
    /// Refused while that plan is running — the workbench re-reads and rewrites the file
    /// between tasks, so a concurrent edit would be silently overwritten.
    func saveEditedPlan(_ plan: PlanDocument) throws {
        guard let store else { throw CoreError.io("No project open") }
        guard !(research.isRunning && research.record(of: plan.id) != nil) else {
            throw CoreError.io("Stop the run before editing this plan.")
        }
        var edited = plan
        edited.log.append("\(ISO8601DateFormatter().string(from: Date())) plan edited by user")
        try store.savePlan(edited)
        reloadPlans()
    }

    /// Sets (or clears) a branch's standing guidance. Safe while running: the workbench
    /// re-reads it from disk at the next task boundary.
    func setGuidance(_ text: String, forPlan planID: String) throws {
        guard let store else { throw CoreError.io("No project open") }
        guard var plan = store.plan(id: planID) else { throw CoreError.io("Plan not found") }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard plan.guidance != trimmed else { return }
        plan.guidance = trimmed
        plan.log.append("\(ISO8601DateFormatter().string(from: Date())) "
            + (trimmed.isEmpty ? "guidance cleared" : "guidance set by user"))
        try store.savePlan(plan)
        reloadPlans()
    }

    /// The live state of a research branch, for a chat that is working on it: its plan and
    /// task statuses, the lens it runs under, the user's guidance, what each task reported,
    /// its own research memory, and the findings it published.
    func branchContextDigest(planID: String) -> String? {
        guard let store, let plan = store.plan(id: planID) else { return nil }
        let program = allPrograms.first { $0.branches.contains { $0.planID == planID } }
        let branch = program?.branch(planID: planID)

        var parts: [String] = []
        if let program, !program.isVirtual {
            parts.append("Program: \(program.researchRequest) — branch '\(branch?.title ?? planID)'"
                + (branch.map { $0.challengesLeadingAnswer ? " (challenges the leading answer)" : "" } ?? ""))
        } else {
            parts.append("Plan: \(plan.goal.isEmpty ? plan.id : plan.goal)")
        }
        parts.append("Status: \(plan.status.rawValue)")
        if !plan.approach.isEmpty { parts.append("Thesis: \(plan.approach)") }
        if !plan.lens.isEmpty { parts.append("Research lens:\n\(plan.lens)") }
        if let kill = plan.kill, !kill.isEmpty { parts.append("Kill criterion: \(kill)") }
        if !plan.guidance.isEmpty { parts.append("The user's standing guidance:\n\(plan.guidance)") }
        parts.append("Tasks:\n" + plan.tasks.map(\.line).joined(separator: "\n"))

        if let record = research.record(of: planID), !record.journal.isEmpty {
            parts.append("What each task reported:\n" + record.journal
                .map { "- task \($0.taskIndex) [\($0.outcome)]: \($0.summary)" }
                .joined(separator: "\n"))
        }
        let branchMemory = store.loadBranchMemory(planID: planID)
        if !branchMemory.isEmpty {
            parts.append("This branch's research memory:\n"
                + MemoryDocument.parse(markdown: branchMemory).promptRendering)
        }
        if let program {
            let live = research.isActive(programID: program.id) ? research.findings : program.findings
            let own = live.filter { $0.branchPlanID == planID && !$0.isRejected }
            if !own.isEmpty {
                parts.append("Findings this branch published:\n" + own
                    .map { "- [\($0.kind.rawValue)] \($0.statement)" }
                    .joined(separator: "\n"))
            }
        }
        return parts.joined(separator: "\n\n")
    }

    /// Rules on a branch's claim. A rejected finding stops circulating immediately — the
    /// next task of every sibling reads the manifest fresh, so nothing further is built
    /// on it. Passing nil returns it to unreviewed.
    func setFindingVerdict(_ verdict: ProgramFinding.Verdict?, note: String?,
                           findingID: String, programID: String) throws {
        guard let store else { throw CoreError.io("No project open") }
        guard var program = store.program(id: programID) else {
            throw CoreError.io("Program not found")
        }
        program.setVerdict(verdict, note: note, forFinding: findingID)
        try store.saveProgram(program)
        research.applyVerdict(verdict, note: note, findingID: findingID)
        reloadPlans()
    }

    /// Opens a branch's work in a fresh chat: the plan, what each task reported, the
    /// branch's own research memory and its findings, attached as a document so the whole
    /// thing can be discussed without re-reading files by hand.
    func openInChat(program: ResearchProgram, planID: String) {
        guard let store, let plan = store.plan(id: planID) else { return }
        let branch = program.branch(planID: planID)
        let record = research.record(of: planID)

        var parts: [String] = ["# Branch: \(branch?.title ?? plan.id)"]
        parts.append("Program goal: \(program.researchRequest)")
        if let branch, branch.challengesLeadingAnswer {
            parts.append("This branch attacks the leading answer.")
        }
        if !plan.lens.isEmpty { parts.append("## Research lens\n\(plan.lens)") }
        if let kill = plan.kill, !kill.isEmpty { parts.append("## Kill criterion\n\(kill)") }
        if !plan.guidance.isEmpty { parts.append("## Standing guidance\n\(plan.guidance)") }
        parts.append("## Tasks\n" + plan.tasks.map(\.line).joined(separator: "\n"))
        if let record, !record.journal.isEmpty {
            parts.append("## What each task reported\n" + record.journal
                .map { "- task \($0.taskIndex) [\($0.outcome)]: \($0.summary)" }
                .joined(separator: "\n"))
        }
        let branchMemory = store.loadBranchMemory(planID: planID)
        if !branchMemory.isEmpty { parts.append("## Branch research memory\n\(branchMemory)") }
        let ownFindings = (research.isActive(programID: program.id)
                           ? research.findings : program.findings)
            .filter { $0.branchPlanID == planID }
        if !ownFindings.isEmpty {
            parts.append("## Findings this branch published\n" + ownFindings
                .map { "- [\($0.kind.rawValue)] \($0.statement)" }
                .joined(separator: "\n"))
        }
        if !plan.log.isEmpty {
            parts.append("## Plan log\n" + plan.log.map { "- \($0)" }.joined(separator: "\n"))
        }

        chat.newChat()
        // A live link (the system prompt re-reads the branch every turn) plus a snapshot
        // of the full log as an attachment, since the digest deliberately omits detail.
        chat.branchPlanID = planID
        chat.pendingAttachments.append(ChatController.ComposerAttachment(
            name: "branch-\(plan.id).md",
            kind: .document(text: parts.joined(separator: "\n\n"))))
        chat.draft = "This is where branch '\(branch?.title ?? plan.id)' got to. "
        selection = .chat
    }

    /// Pushes the project's LaTeX macro dictionary (macros.tex) into a web view so KaTeX
    /// can expand user-defined commands like \A. Call before rendering into any box.
    func syncMacros(_ box: WebViewBox) {
        box.call("setMathMacros", store?.macroDictionary ?? [:])
    }

    func macrosChanged() {
        itemsVersion += 1
        syncMacros(chat.box)
    }

    func reloadFromDisk() {
        guard let store else { return }
        try? store.reload()
        if let id = selectedItemID, store.item(id: id) == nil {
            selectedItemID = store.items.first?.id
        }
        itemsVersion += 1
    }

    // MARK: - Item mutations (all user-confirmed paths funnel through here)

    /// Active programs protect only the fields that define their goal. Proof/Evidence and
    /// trust status remain ordinary theory edits. Redefinition is represented by a reviewed
    /// problem challenge and a new target revision, never by an unjournalled in-place change.
    private func protectedGoalError(for item: TheoryItem) -> String? {
        guard let store else { return nil }
        for program in store.loadPrograms().programs
        where program.status == .active || program.status == .paused {
            let revision = program.activeTargetRevision
            if let field = revision.protectedGoalChange(in: item) {
                return "Cannot change goal item '\(item.id)' field '\(field)' while program "
                    + "'\(program.displayName)' uses revision '\(revision.id)'. File a problem "
                    + "challenge; after both reviews accept it, the director can adopt a new "
                    + "formal goal revision. Proof, Evidence and status remain editable."
            }
        }
        return nil
    }

    func validateProtectedGoalUpdate(_ proposal: TheoryProposal) throws {
        guard proposal.action == .update,
              let message = protectedGoalError(for: proposal.item) else { return }
        throw CoreError.io(message)
    }

    func save(_ item: TheoryItem) {
        guard let store else { return }
        if let message = protectedGoalError(for: item) {
            openError = message
            return
        }
        let previousStatus = store.item(id: item.id)?.status
        do {
            try store.save(item)
            itemsVersion += 1
        } catch {
            openError = error.localizedDescription
            return
        }
        // Breakage propagation: a downgrade invalidates the reviews of everything built on it.
        if let previousStatus, item.status.rank < previousStatus.rank {
            let affected = store.breakageAffected(of: item.id)
            if !affected.isEmpty {
                pendingBreakage = BreakageInfo(sourceID: item.id, affectedIDs: affected.map(\.id))
            }
        }
    }

    /// Applies the cascade: every affected dependent drops back to "proof drafted".
    func applyBreakage(_ info: BreakageInfo) {
        guard let store else { return }
        for id in info.affectedIDs {
            if var item = store.item(id: id),
               item.status.rank >= ItemStatus.reviewedNoErrors.rank, item.status != .source {
                item.status = .proofDrafted
                try? store.save(item)
            }
        }
        itemsVersion += 1
        pendingBreakage = nil
    }

    func deleteItem(id: String) {
        guard let store else { return }
        if store.loadPrograms().programs.contains(where: {
            ($0.status == .active || $0.status == .paused)
                && $0.activeTargetRevision.libraryItemID == id
        }) {
            openError = "Cannot delete '\(id)' while an active or paused program uses it as its research goal."
            return
        }
        try? store.delete(id: id)
        if selectedItemID == id { selectedItemID = store.items.first?.id }
        itemsVersion += 1
    }

    /// Copies an image into `figures/` and points the item at it, in one step — the file
    /// and the `image:` field must never be able to disagree.
    func setFigureImage(from url: URL, on item: TheoryItem) {
        guard let store else { return }
        do {
            var updated = item
            updated.image = try store.addFigureImage(from: url, for: item.id)
            save(updated)
        } catch {
            openError = error.localizedDescription
        }
    }

    func accept(_ proposal: TheoryProposal) {
        do { try validateProtectedGoalUpdate(proposal) }
        catch { openError = error.localizedDescription; return }
        var item = proposal.item
        do {
            try adoptFigureSource(of: proposal, into: &item)
        } catch {
            openError = error.localizedDescription
            return  // never write a figure item whose image failed to land
        }
        journalWrite(proposal, item: item)
        save(item)
        pendingProposals.removeAll { $0.id == proposal.id }
    }

    func reject(_ proposal: TheoryProposal) {
        // Nothing to clean up: a figure proposal's image is still in its artifacts run
        // folder, which is where a render lives until someone decides to keep it.
        pendingProposals.removeAll { $0.id == proposal.id }
    }

    /// Points the figure scheme handler at the renders behind any pending figure
    /// proposals, so the review sheet shows the picture instead of a missing-image note.
    private func syncPendingFigureImages() {
        guard let store else {
            FigureResolver.shared.pendingImages = [:]
            return
        }
        var images: [String: URL] = [:]
        for proposal in pendingProposals where proposal.item.isFigure {
            guard let source = proposal.figureSource,
                  let render = FigureAsset.resolveArtifactRender(source, in: store.rootURL)
            else { continue }
            images[proposal.item.id] = render.imageURL
        }
        FigureResolver.shared.pendingImages = images
    }

    /// Copies a proposed figure's rendered image (and the script behind it) out of the
    /// sandbox run folder and into `figures/`. Deferred to this moment on purpose:
    /// proposing must not write to the project, so acceptance is what makes it real.
    private func adoptFigureSource(of proposal: TheoryProposal, into item: inout TheoryItem) throws {
        guard let source = proposal.figureSource, let store else { return }
        guard let render = FigureAsset.resolveArtifactRender(source, in: store.rootURL) else {
            throw CoreError.io("""
            The rendered image for '\(item.id)' is no longer in artifacts/\(source) — \
            ask Prismo to render it again.
            """)
        }
        let paths = try store.adoptArtifactRender(render, for: item.id)
        item.image = paths.image
        item.generator = paths.generator
    }

    // MARK: - Agent write journal

    /// Every agent write, grouped by the turn that made it — the source for the chat's
    /// change summary and the only way back from an Auto-mode turn that went wrong.
    @Published private(set) var writeJournal = WriteJournal() {
        didSet { persistJournal() }
    }
    /// The turn writes are currently attributed to. ChatController opens a new one per
    /// message so a turn's writes group together.
    private(set) var currentWriteTurn = UUID()

    private static let journalSessionName = "write-journal"

    func beginWriteTurn() -> UUID {
        currentWriteTurn = UUID()
        return currentWriteTurn
    }

    /// Captures the pre-write state. Must be called BEFORE the item is saved, and with
    /// the item that will actually be written — a figure's asset paths are filled in on
    /// the way through, and a revert has to restore what landed, not what was proposed.
    private func journalWrite(_ proposal: TheoryProposal, item: TheoryItem) {
        guard let store else { return }
        let existing = store.item(id: item.id)
        writeJournal.record(TheoryWrite(
            turnID: currentWriteTurn,
            itemID: item.id,
            itemName: item.name,
            itemType: item.type,
            action: proposal.action == .create ? .create : .update,
            before: existing?.serialized(),
            after: item.serialized()))
    }

    /// Applies an agent write immediately (Auto mode), journaling it first so the turn
    /// stays revertible. Returns the confirmation the agent sees.
    func applyDirectWrite(_ proposal: TheoryProposal) throws -> String {
        guard let store else { throw CoreError.io("No project open") }
        try validateProtectedGoalUpdate(proposal)
        var item = proposal.item
        try adoptFigureSource(of: proposal, into: &item)
        journalWrite(proposal, item: item)
        try store.save(item)
        itemsVersion += 1
        let verb = proposal.action == .create ? "Created" : "Updated"
        // Breakage propagation still applies — a downgrade invalidates dependants' reviews.
        if proposal.action == .update,
           let previous = writeJournal.writes.last?.before,
           let previousItem = try? TheoryItem.parse(markdown: previous),
           item.status.rank < previousItem.status.rank {
            let affected = store.breakageAffected(of: item.id)
            if !affected.isEmpty {
                pendingBreakage = BreakageInfo(
                    sourceID: item.id, affectedIDs: affected.map(\.id))
            }
        }
        if item.isFigure {
            return "Saved figure '\(item.id)' to the library. It is live and citable."
        }
        return "\(verb) '\(item.id)'. The change is live in the library."
    }

    /// Undoes every write made in one turn: newest first, restoring prior content and
    /// deleting items the turn created.
    func revertWriteTurn(_ turnID: UUID) {
        guard let store else { return }
        for step in writeJournal.revertPlan(turnID: turnID) {
            switch step {
            case .restore(_, let markdown):
                if let item = try? TheoryItem.parse(markdown: markdown) {
                    try? store.save(item)
                }
            case .delete(let itemID):
                try? store.delete(id: itemID)
                if selectedItemID == itemID { selectedItemID = store.items.first?.id }
            }
        }
        writeJournal.forget(turnID: turnID)
        itemsVersion += 1
    }

    private func persistJournal() {
        guard let store else { return }
        if let data = try? JSONEncoder().encode(writeJournal) {
            try? store.saveSession(named: Self.journalSessionName, json: data)
        }
    }

    private func restoreJournal(from store: ProjectStore) {
        if let data = store.loadSession(named: Self.journalSessionName),
           let saved = try? JSONDecoder().decode(WriteJournal.self, from: data) {
            writeJournal = saved
        } else {
            writeJournal = WriteJournal()
        }
    }

    private static let proposalsSessionName = "pending-proposals"

    private func persistProposals() {
        guard let store else { return }
        if let data = try? JSONEncoder().encode(pendingProposals) {
            try? store.saveSession(named: Self.proposalsSessionName, json: data)
        }
    }

    private func restoreProposals(from store: ProjectStore) {
        if let data = store.loadSession(named: Self.proposalsSessionName),
           let saved = try? JSONDecoder().decode([TheoryProposal].self, from: data) {
            pendingProposals = saved
        } else {
            pendingProposals = []
        }
    }

    // MARK: - Kept files (documents/)

    var documents: [ProjectDocument] { store?.documents ?? [] }

    func document(slug: String) -> ProjectDocument? { store?.document(slug: slug) }

    /// Copies files into the project and extracts their text so agents can search them.
    /// Extraction of a long PDF takes seconds, so it runs off the main thread; the copy and
    /// the store write stay here (ProjectStore is not thread-safe).
    @discardableResult
    func addDocuments(at urls: [URL]) async -> [ProjectDocument] {
        guard let store else { return [] }
        var added: [ProjectDocument] = []
        var notices: [String] = []
        for url in urls {
            documentsInFlight.append(url.lastPathComponent)
            do {
                let extracted = try await Task.detached(priority: .userInitiated) {
                    try PDFExtraction.read(url: url)
                }.value
                let document = try store.addDocument(
                    from: url,
                    fulltext: extracted.fulltext,
                    pageCount: extracted.pageCount)
                added.append(document)
                notices.append(contentsOf: extracted.warnings.map {
                    "\(document.meta.title): \($0)"
                })
            } catch {
                notices.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
            documentsInFlight.removeAll { $0 == url.lastPathComponent }
        }
        documentNotice = notices.isEmpty ? nil : notices.joined(separator: "\n")
        if !added.isEmpty { documentsVersion += 1 }
        return added
    }

    func removeDocument(slug: String) {
        guard let store else { return }
        do {
            try store.removeDocument(slug: slug)
            if selection == .document(slug: slug) { selection = .library }
            documentsVersion += 1
        } catch {
            openError = error.localizedDescription
        }
    }

    func renameDocument(slug: String, title: String) {
        guard let store else { return }
        do {
            try store.renameDocument(slug: slug, title: title)
            documentsVersion += 1
        } catch {
            openError = error.localizedDescription
        }
    }

    /// Extracts (or re-extracts) a kept file's text — the recovery path after OCRing a
    /// scanned PDF in place, and the way an older project's files become searchable.
    func extractDocumentText(slug: String) async {
        guard let store, let document = store.document(slug: slug), let fileURL = document.fileURL else {
            return
        }
        documentsInFlight.append(document.meta.title)
        do {
            let extracted = try await Task.detached(priority: .userInitiated) {
                try PDFExtraction.read(url: fileURL)
            }.value
            if let fulltext = extracted.fulltext {
                try store.saveDocumentFulltext(slug: slug, fulltext)
                documentNotice = "\(document.meta.title): extracted \(fulltext.info.unitLabel)."
                documentsVersion += 1
            } else {
                documentNotice = "\(document.meta.title): "
                    + (extracted.warnings.first ?? "no text could be extracted.")
            }
        } catch {
            documentNotice = "\(document.meta.title): \(error.localizedDescription)"
        }
        documentsInFlight.removeAll { $0 == document.meta.title }
    }

    /// Hands a kept file to the Import tab so its content can be organized into items.
    func importItems(fromDocument slug: String) {
        guard let document = document(slug: slug), let fileURL = document.fileURL else { return }
        importSeed = fileURL
        selection = .importer
    }

    // MARK: - Attached sources

    func loadAttachedSources() {
        for source in attachedSources { source.store.stopWatching() }
        var loaded: [(SourceRef, ProjectStore)] = []
        var broken: [SourceRef] = []
        for ref in store?.meta.sources ?? [] {
            if let sourceStore = try? ProjectStore(opening: URL(fileURLWithPath: ref.path)) {
                loaded.append((ref, sourceStore))
            } else {
                broken.append(ref)
            }
        }
        attachedSources = loaded
        brokenSourceRefs = broken
        if let slug = selectedSourceSlug, !loaded.contains(where: { $0.0.slug == slug }) {
            selectedSourceSlug = nil
        }
        if case .source(let slug) = graphScope, !loaded.contains(where: { $0.0.slug == slug }) {
            graphScope = .project
        }
        // Watch each source folder so edits from another window (a source opened as
        // its own project) or an external tool show up here without a manual reload.
        for (ref, sourceStore) in loaded {
            sourceStore.startWatching { [weak self, weak sourceStore] in
                guard let self else { return }
                self.sourceReloadDebounces[ref.slug]?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    try? sourceStore?.reload()
                    self?.itemsVersion += 1
                }
                self.sourceReloadDebounces[ref.slug] = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
            }
        }
    }

    func attachSource(at url: URL) {
        guard let store else { return }
        do {
            _ = try ProjectStore(opening: url)  // validate before recording
            let slug = TheoryItem.sanitizeID(url.lastPathComponent)
            try store.attachSource(SourceRef(slug: slug, path: url.path))
            loadAttachedSources()
            itemsVersion += 1
        } catch {
            openError = error.localizedDescription
        }
    }

    func detachSource(slug: String) {
        try? store?.detachSource(slug: slug)
        loadAttachedSources()
        itemsVersion += 1
    }

    /// Resolves a namespaced reference `slug:item-id` against the attached sources.
    func sourceItem(ref: String) -> TheoryItem? {
        guard let colon = ref.firstIndex(of: ":") else { return nil }
        let slug = String(ref[..<colon])
        let itemID = String(ref[ref.index(after: colon)...])
        return attachedSources.first { $0.ref.slug == slug }?.store.item(id: itemID)
    }

    // MARK: - Agents

    /// A program's own override for `task` beats the global default when it decodes to a
    /// usable provider — a stale or malformed override (e.g. a key that got removed) must
    /// not strand the run, so it silently falls through to the global default instead.
    func providerConfig(for task: AgentTask, program: ResearchProgram? = nil) throws -> ProviderConfig {
        if let override = program?.roleModelOverrides[task.rawValue],
           let kind = ProviderKind(rawValue: override.providerKind) {
            if !kind.usesAPIKey {
                return ProviderConfig(kind: kind, apiKey: "", model: override.model,
                    codexBinaryPath: AppSettings.codexPath.isEmpty ? nil : AppSettings.codexPath)
            }
            if let key = Keychain.apiKey(for: kind), !key.isEmpty {
                return ProviderConfig(kind: kind, apiKey: key, model: override.model)
            }
        }
        let choice = AppSettings.effectiveChoice(for: task)
        guard choice.kind.usesAPIKey else {
            return ProviderConfig(
                kind: choice.kind, apiKey: "", model: choice.model,
                codexBinaryPath: AppSettings.codexPath.isEmpty ? nil : AppSettings.codexPath)
        }
        guard let key = Keychain.apiKey(for: choice.kind), !key.isEmpty else {
            throw AgentError.noAPIKey(choice.kind)
        }
        return ProviderConfig(kind: choice.kind, apiKey: key, model: choice.model)
    }

    func makePythonRuntime() -> PythonRuntime {
        PythonRuntime(interpreterOverride: AppSettings.pythonPath.isEmpty ? nil : AppSettings.pythonPath)
    }

    /// Every sandbox the app hands an agent, built in one place so the user's timeout
    /// limits reach all of them. Constructing `PythonSandbox` directly skips those limits,
    /// which is why nothing outside this method does.
    func makePythonSandbox(artifactsURL: URL, runNamespace: String? = nil) -> PythonSandbox {
        PythonSandbox(runtime: makePythonRuntime(), artifactsURL: artifactsURL,
                      runNamespace: runNamespace, limits: AppSettings.pythonSandboxLimits)
    }

    func makeChatConfig(mode: ChatMode = .propose) throws -> (runner: AgentRunner, config: AgentConfig) {
        guard let store else { throw CoreError.io("No project open") }
        let runner = makeRunner(config: try providerConfig(for: .chat))
        let onProposal: @Sendable (TheoryProposal) -> Void = { [weak self] proposal in
            DispatchQueue.main.async { self?.pendingProposals.append(proposal) }
        }
        // The same enqueue, shaped like the direct-write path so one tool serves both
        // modes: save_figure differs only in where its proposal lands.
        let recordProposal: @Sendable (TheoryProposal) async throws -> String = {
            [weak self] proposal in
            await MainActor.run { self?.pendingProposals.append(proposal) }
            return """
            Figure '\(proposal.item.id)' proposed and shown to the user for confirmation — \
            the image is copied into the project only if they accept. Do not assume they did.
            """
        }
        let sandbox = makePythonSandbox(artifactsURL: store.artifactsURL)
        let sources = attachedSources.map { (slug: $0.ref.slug, store: $0.store) }

        // Mode decides the tool surface: Ask reads, Plan gathers only enough context to
        // draft a target for the persistent research director, and Propose/Auto are the
        // full agent. Writes stay behind the proposal gate except in Auto, which applies
        // them directly.
        var tools: [AgentTool]
        switch mode {
        case .auto:
            // Direct writes: the tool applies through AppState so every one is journaled
            // and the turn stays revertible.
            let applyWrite: @Sendable (TheoryProposal) async throws -> String = {
                [weak self] proposal in
                try await MainActor.run {
                    guard let self else { throw CoreError.io("No project open") }
                    return try self.applyDirectWrite(proposal)
                }
            }
            tools = TheoryTools.autoChatTools(store: store, apply: applyWrite)
            tools += SandboxTools.tools(sandbox: sandbox, store: store, onProposal: onProposal)
            tools.append(makeVisualizationTool(sandbox: sandbox))
            tools += FigureTools.writeTools(store: store, apply: applyWrite)
        case .plan:
            tools = TheoryTools.readOnlyTools(store: store)
        case .propose:
            tools = TheoryTools.chatTools(store: store, onProposal: onProposal)
            tools += SandboxTools.tools(sandbox: sandbox, store: store, onProposal: onProposal)
            tools.append(makeVisualizationTool(sandbox: sandbox))
            tools += FigureTools.writeTools(store: store, apply: recordProposal)
        case .ask:
            tools = TheoryTools.readOnlyTools(store: store)
        }
        // Reading a figure is reading a caption — allowed everywhere, including Ask.
        tools += FigureTools.readTools(store: store)
        tools += SourceTools.tools(attached: sources)
        // Full texts are user-gated: reads check the grant at call time, and the
        // request tool suspends on the chat's Allow/Deny banner.
        let fulltextAccess = FulltextTools.Access(
            isGranted: { @MainActor [weak self] slug in
                self?.chat.isFulltextGranted(slug: slug) ?? false
            },
            requestGrant: { @MainActor [weak self] slug, reason in
                guard let self else { return false }
                return await self.chat.requestFulltextAccess(slug: slug, reason: reason)
            }
        )
        let fulltextTools = FulltextTools.tools(attached: sources, access: fulltextAccess)
        tools += fulltextTools
        // The project's own kept files are gated the same way — per-chat grants through
        // request_document_access, or the standing "read full documents" choice.
        let documentTools = DocumentTools.tools(store: store, access: makeDocumentAccess())
        tools += documentTools
        if mode != .plan {
            tools.append(makeMemoryTool())
        }
        if mode != .ask {
            // Chat hands one confirmed target to the persistent director. Portfolio design
            // belongs to that continuing research conversation, not to the old two-pass
            // approach selector that Plan mode used to open.
            tools.append(makeStartResearchTool())
        }
        // review_proof needs the reviewer model; chat still works without its key.
        if mode.canWriteTheory, let reviewerConfig = try? providerConfig(for: .reviewer) {
            let verifier = LLMReviewer(
                runner: makeRunner(config: reviewerConfig),
                tools: TheoryTools.readOnlyTools(store: store) + SandboxTools.computeTools(sandbox: sandbox),
                notation: store.notation,
                outline: ContextAssembly.outline(items: store.items),
                thinking: AppSettings.effectiveThinking(for: .reviewer))
            tools.append(ReviewTools.reviewProofTool(store: store, verifier: verifier))
        }
        // Only when the conversation is attached to a branch, and never in Ask or Plan —
        // closing an approach is a write, while Plan now does nothing beyond target hand-off.
        if mode != .ask && mode != .plan,
           let planID = chat.branchPlanID, let plan = store.plan(id: planID) {
            let title = allPrograms.compactMap { $0.branch(planID: planID)?.title }.first
                ?? (plan.goal.isEmpty ? planID : plan.goal)
            tools.append(ProgramTools.closeBranchTool(
                branchPlanID: planID,
                branchTitle: title,
                close: { @MainActor [weak self] status, reason in
                    guard let self else { return }
                    try self.closeBranch(planID: planID, status: status, reason: reason)
                }))
        }
        let focusedItems = chat.attachedItems.compactMap { store.item(id: $0.id) }
        let grantedSlugs = Set(sources.map(\.slug).filter { chat.isFulltextGranted(slug: $0) })
        let modeDirective: String?
        switch mode {
        case .propose: modeDirective = nil
        case .auto: modeDirective = ContextAssembly.autoModeDirective
        case .plan: modeDirective = ContextAssembly.planModeDirective
        case .ask: modeDirective = ContextAssembly.askModeDirective
        }
        let system = ContextAssembly.chatSystemPrompt(
            projectName: store.meta.name,
            notation: store.notation,
            items: store.items,
            userName: AppSettings.userName,
            userProfile: AppSettings.userProfile,
            checkerAvailable: mode == .auto || mode == .propose,
            figureToolsAvailable: mode == .auto || mode == .propose,
            attachedSources: sources,
            fulltextGranted: grantedSlugs,
            fulltextToolsAvailable: !fulltextTools.isEmpty,
            documents: store.documents,
            documentsGranted: grantedDocumentSlugs(),
            documentToolsAvailable: !documentTools.isEmpty,
            documentIndex: store.index,
            focusedItems: focusedItems,
            memory: store.memory,
            modeDirective: modeDirective,
            branchContext: chat.branchPlanID.flatMap { branchContextDigest(planID: $0) }
        )
        return (runner, AgentConfig(
            systemPrompt: system, tools: tools, maxIterations: AppSettings.chatMaxIterations,
            maxTokens: AppSettings.Limit.chatResponseTokens.value,
            thinking: AppSettings.effectiveThinking(for: .chat)))
    }

    /// Chat's gate on the project's kept files: the grant is checked per call (so an
    /// approval mid-turn takes effect at once) and the request suspends on the chat banner.
    private func makeDocumentAccess() -> DocumentTools.Access {
        DocumentTools.Access(
            isGranted: { @MainActor [weak self] slug in
                self?.chat.isDocumentGranted(slug: slug) ?? false
            },
            requestGrant: { @MainActor [weak self] slug, reason in
                guard let self else { return false }
                let title = self.document(slug: slug)?.meta.title ?? slug
                return await self.chat.requestDocumentAccess(slug: slug, title: title, reason: reason)
            }
        )
    }

    /// Kept files this chat may read right now.
    private func grantedDocumentSlugs() -> Set<String> {
        Set(documents.map(\.slug).filter { chat.isDocumentGranted(slug: $0) })
    }

    /// The gate for agent surfaces with no approval UI (research branches, the prover):
    /// they may read the project's files only under the standing "read full documents"
    /// choice, and can never ask for more mid-run.
    func makeStandingDocumentAccess() -> DocumentTools.Access {
        DocumentTools.Access(
            isGranted: { @MainActor [weak self] _ in
                self?.chat.fulltextAccess.allowAll ?? false
            }
        )
    }

    /// The kept-files briefing for those same surfaces, so an agent knows what exists (and
    /// whether it can read it) instead of guessing.
    private func documentsSectionForRuns() -> [String] {
        guard let store, !store.documents.isEmpty else { return [] }
        let allowed = chat.fulltextAccess.allowAll
        return [ContextAssembly.documentsSection(
            documents: store.documents,
            granted: allowed ? Set(store.documents.map(\.slug)) : [],
            toolsAvailable: allowed,
            index: store.index)]
    }

    /// create_visualization renders in the sandbox and hands the PNG to the chat for
    /// inline display.
    private func makeVisualizationTool(sandbox: PythonSandbox) -> AgentTool {
        VisualizationTools.tool(sandbox: sandbox) { [weak self] pngURL, title, caption in
            DispatchQueue.main.async {
                self?.chat.showVisualization(pngURL: pngURL, title: title, caption: caption)
            }
        }
    }

    /// update_memory writes directly (the memory is the agent's notebook, not part of
    /// the trust ladder), but always through the main actor — ProjectStore isn't
    /// thread-safe and tools execute off-main.
    private func makeMemoryTool() -> AgentTool {
        MemoryTools.updateTool(
            currentMemory: { @MainActor [weak self] in
                self?.store?.memory ?? ""
            },
            saveMemory: { @MainActor [weak self] text in
                guard let store = self?.store else { throw CoreError.io("No project open") }
                try store.saveMemory(text)
            }
        )
    }

    /// The same tool pointed at one branch's isolated memory file. Branches never write
    /// the project memory during a run — that is what keeps their beliefs apart.
    private func makeBranchMemoryTool(planID: String) -> AgentTool {
        MemoryTools.updateTool(
            currentMemory: { @MainActor [weak self] in
                self?.store?.loadBranchMemory(planID: planID) ?? ""
            },
            saveMemory: { @MainActor [weak self] text in
                guard let store = self?.store else { throw CoreError.io("No project open") }
                try store.saveBranchMemory(planID: planID, text: text)
            }
        )
    }

    private func makeApproachesTool() -> AgentTool {
        ProgramPlanner.proposeApproachesTool { [weak self] proposal in
            DispatchQueue.main.async { self?.presentApproachProposal(proposal) }
        }
    }

    /// Chat's hand-off into the persistent research wiring. The model must first show the
    /// exact target and receive explicit confirmation in a later user turn; that conversational
    /// gate is spelled out in both the chat prompt and this tool's description. Once called,
    /// this follows the same formalize-goal -> persistent-director path as Start research.
    private func makeStartResearchTool() -> AgentTool {
        FunctionAgentTool(
            name: "start_research",
            description: """
            Start the persistent research workflow with the exact target previously shown to the \
            user. Use only after the user explicitly confirms that target in a later message. \
            Never call in the same turn that first proposes or revises the target. The workflow \
            formalizes the target as a protected research-goal item, freezes its interpretation, \
            and gives it to a continuing director that chooses and manages research assignments.
            """,
            schema: #"{"type":"object","properties":{"target":{"type":"string","description":"The exact research target the user confirmed, unchanged from the latest proposal."}},"required":["target"]}"#,
            effect: .finish
        ) { @MainActor [weak self] _, json in
            guard let self else { throw CoreError.io("No project open") }
            guard let data = json.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rawTarget = object["target"] as? String else {
                throw CoreError.io("start_research requires the confirmed target")
            }
            guard !rawTarget.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CoreError.io("The confirmed research target is empty")
            }
            guard !self.research.isRunning else {
                throw CoreError.io("Another research program is already running")
            }
            guard !self.planning.isGenerating else {
                throw CoreError.io("Another research program is already being prepared")
            }
            guard !self.planning.hasSession else {
                throw CoreError.io("A research setup is already awaiting review; finish or discard it first")
            }
            guard self.pendingApproachProposal == nil else {
                throw CoreError.io("A research proposal is already awaiting review; finish or discard it first")
            }

            let runLimits = RunLimits()
            self.planning.proposedLimits = runLimits
            self.researchPage = .list
            self.planningPhase = .brainstorming
            self.selection = .research
            self.planning.runDirectorFirst(
                problem: rawTarget,
                maxConcurrentBranches: runLimits.maxConcurrentBranches,
                limits: runLimits.execution
            ) { [weak self] program in
                guard let self else { return }
                self.researchPage = .program(id: program.id)
                self.research.startProgram(program, mode: .auto)
                self.planningPhase = .idle
            }
            return "Research started with the confirmed target. The Research tab now shows goal formalization and will open the persistent director when it is ready."
        }
    }

    /// Raises the legacy supervised planner's pass-1 output into the Research tab. Planning
    /// renders inline there rather than as a sheet, so the phase has to be driven from here;
    /// a new proposal must replace an older pending one instead of sitting behind it unseen.
    func presentApproachProposal(_ proposal: ApproachProposal) {
        // Clears the *branch* side of any previous session but keeps the pilots and the
        // drafted contract: those now run BEFORE this proposal exists and belong to it.
        // A full `reset()` here would throw away the four pilot turns that produced it.
        planning.prepareForProposal()
        pendingApproachProposal = proposal
        planningPhase = .selecting
        selection = .research
    }

    /// Planning pass 1: propose contradictory approaches. Sees the full research memory —
    /// designing an approach that argues against the project's beliefs requires knowing them.
    /// `onProposal` reroutes the result away from the selection pane (the full-auto pipeline
    /// captures it instead); `fullAuto` tells the planner its activation picks are final.
    func makeProgramPlannerConfig(
        goal: String,
        contract: SuccessContract? = nil,
        pilotDigest: String? = nil,
        fullAuto: Bool = false,
        onProposal: (@Sendable (ApproachProposal) -> Void)? = nil
    ) throws -> (runner: AgentRunner, config: AgentConfig) {
        guard let store else { throw CoreError.io("No project open") }
        let runner = makeRunner(config: try providerConfig(for: .planner))
        let sandbox = makePythonSandbox(artifactsURL: store.artifactsURL)
        var tools: [AgentTool] = TheoryTools.readOnlyTools(store: store)
        tools += SandboxTools.computeTools(sandbox: sandbox)
        tools += SourceTools.tools(attached: attachedSources.map { (slug: $0.ref.slug, store: $0.store) })
        tools.append(onProposal.map { ProgramPlanner.proposeApproachesTool(onProposal: $0) }
            ?? makeApproachesTool())
        var system = ProgramPlanner.pass1SystemPrompt(
            notation: store.notation,
            items: store.items,
            userProfile: AppSettings.userProfile,
            memory: store.memory,
            contract: contract,
            projectOntology: projectOntology(),
            pilotDigest: pilotDigest,
            goal: goal
        )
        if fullAuto {
            system += "\n\n" + """
            This is a FULLY AUTOMATIC run: the approaches you mark `activate: true` will be \
            planned and executed immediately, in your listed order, with no human review \
            between here and the result. Choose the activated set and its order as the \
            researcher responsible for the outcome, not as a menu for someone else to prune.
            """
        }
        return (runner, AgentConfig(
            systemPrompt: SystemPrompt(system), tools: tools, maxIterations: 24,
            thinking: AppSettings.effectiveThinking(for: .planner)))
    }

    /// Planning pass 2: one branch's task list, planned under its own lens and facts only.
    func makeBranchPlannerConfig(
        approach: ApproachProposal.Approach,
        goal: String,
        contract: SuccessContract? = nil,
        onProposal: @escaping @Sendable (PlanProposal.Option) -> Void,
        onDecline: @escaping @Sendable (String) -> Void = { _ in }
    ) throws -> (runner: AgentRunner, config: AgentConfig) {
        guard let store else { throw CoreError.io("No project open") }
        let runner = makeRunner(config: try providerConfig(for: .planner))
        let sandbox = makePythonSandbox(artifactsURL: store.artifactsURL)
        var tools: [AgentTool] = TheoryTools.readOnlyTools(store: store)
        tools += SandboxTools.computeTools(sandbox: sandbox)
        tools += SourceTools.tools(attached: attachedSources.map { (slug: $0.ref.slug, store: $0.store) })
        tools.append(ProgramPlanner.proposeBranchPlanTool(onProposal: onProposal))
        tools.append(ProgramPlanner.declineBranchTool(onDecline: onDecline))
        let system = ProgramPlanner.pass2SystemPrompt(
            approach: approach,
            goal: goal,
            notation: store.notation,
            items: store.items,
            userProfile: AppSettings.userProfile,
            projectMemory: store.memory,
            contract: contract
        )
        return (runner, AgentConfig(
            systemPrompt: SystemPrompt(system), tools: tools, maxIterations: 20,
            thinking: AppSettings.effectiveThinking(for: .planner)))
    }

    /// Optional per-project `ontology.md`: the user's own tactic families and lenses,
    /// appended to the built-in ontology in pass 1.
    private func projectOntology() -> String? {
        guard let store else { return nil }
        return try? String(contentsOf: store.rootURL.appendingPathComponent("ontology.md"),
                           encoding: .utf8)
    }

    /// The program-level synthesis turn: the comparison report across finished branches.
    /// Whether this branch has published a `lens_abandoned` finding. Read from disk at the end
    /// of the run rather than tracked in memory, so a finding published by an earlier leg of
    /// the same branch still counts.
    private func makeLensAbandonedCheck(
        planID: String?, programID: String?
    ) -> (@Sendable () -> Bool)? {
        guard let planID, let programID, let store else { return nil }
        return { @Sendable in
            store.program(id: programID)?.findings.contains {
                $0.branchPlanID == planID && $0.kind == .lensAbandoned && !$0.isRejected
            } ?? false
        }
    }


    /// The fresh-context adjudication a counterexample claim must survive before it
    /// publishes on an unattended run. Runs on the reviewer's provider — the adjudicator IS
    /// a reviewer, and the design rule that the reviewer is never weaker than the generator
    /// it judges applies with full force here. Nil (manual programs) keeps the human gate.
    private func makeCounterexampleAdjudicator(
        program: ResearchProgram?
    ) -> (@Sendable (ProgramFinding) async throws -> FindingAdjudicator.Ruling?)? {
        guard let program, !program.isVirtual,
              program.continuation?.autoAdjudicateCounterexamples == true,
              let store else { return nil }
        let goal = program.researchRequest
        let contract = program.contract
        let programID = program.id
        let reviewerThinking = AppSettings.effectiveThinking(for: .reviewer)
        let rootURL = store.rootURL
        let artifactsURL = store.artifactsURL

        return { @Sendable finding in
            // Tools are built per adjudication on the main actor (they touch the store);
            // the turn itself runs off it.
            let (runner, tools, recorder) = try await MainActor.run {
                [weak self] () -> (AgentRunner, [AgentTool], RecordTurn?) in
                guard let self, let store = self.store else { throw CoreError.io("No project open") }
                let sandbox = makePythonSandbox(artifactsURL: artifactsURL,
                                                runNamespace: "adjudication")
                return (makeRunner(config: try self.providerConfig(for: .reviewer)),
                        TheoryTools.readOnlyTools(store: store)
                            + SandboxTools.computeTools(sandbox: sandbox),
                        self.makeTurnRecorder())
            }
            return try await FindingAdjudicator.adjudicate(
                runner: runner,
                goal: goal,
                contract: contract,
                claim: finding,
                artifactText: Self.artifactExcerpt(for: finding, rootURL: rootURL),
                tools: tools,
                thinking: reviewerThinking,
                programID: programID, record: recorder)
        }
    }

    /// Files a solution candidate on the program, snapshotting the cited items so a review
    /// done now can be reused later only if none of them has moved since.
    ///
    /// Nil outside a program branch, which also removes `claim_solution` from the toolset:
    /// a standalone plan has no contract to adjudicate against and no director to settle.
    private func makeSolutionFiler(
        planID: String?, programID: String?
    ) -> (@Sendable (String, [String], [String]?, String) async throws -> String)? {
        guard let planID, let programID else { return nil }
        return { @Sendable primaryItemID, supporting, completionIDs, argument in
            try await MainActor.run { [weak self] () throws -> String in
                guard let self, let store = self.store,
                      var program = store.program(id: programID) else {
                    throw CoreError.io("this branch's program is missing")
                }
                guard store.item(id: primaryItemID) != nil else {
                    throw CoreError.io("""
                    no theory item '\(primaryItemID)' — claim a result that exists in the \
                    library, not one you intend to write
                    """)
                }
                var candidate = SolutionCandidate(
                    branchPlanID: planID,
                    targetRevisionID: program.activeTargetRevisionID,
                    primaryItemID: primaryItemID,
                    supportingItemIDs: supporting,
                    claimedCompletionIDs: completionIDs,
                    argument: argument)
                let byID = Dictionary(store.items.map { ($0.id, $0) },
                                      uniquingKeysWith: { first, _ in first })
                candidate.itemSnapshots = Dictionary(
                    SolutionReviewGate.closure(of: candidate, items: byID)
                        .map { ($0.id, SolutionReviewGate.contentHash($0)) },
                    uniquingKeysWith: { first, _ in first })
                program.upsertSolution(candidate)
                program.updated = Date()
                try store.saveProgram(program)
                return candidate.id
            }
        }
    }

    /// Files a challenge against exactly the revision this branch is working under. Evidence
    /// and an optional replacement target are snapshotted from raw disk bytes at filing time;
    /// later edits cannot improve a weak challenge retroactively.
    private func makeProblemChallengeFiler(
        planID: String?, programID: String?
    ) -> (@Sendable (String, String?, String?, [String]) async throws -> String)? {
        guard let planID, let programID else { return nil }
        return { @Sendable description, replacement, proposedTargetItemID, evidenceIDs in
            try await MainActor.run { [weak self] () throws -> String in
                guard let self, let store = self.store,
                      var program = store.program(id: programID) else {
                    throw CoreError.io("this branch's program is missing")
                }

                var evidenceData: [String: Data] = [:]
                var evidenceSnapshots: [String: String] = [:]
                for id in evidenceIDs {
                    guard store.item(id: id) != nil else {
                        throw CoreError.io("challenge evidence item '\(id)' does not exist")
                    }
                    let raw = try store.rawTheoryItemData(id: id)
                    evidenceData[id] = raw
                    evidenceSnapshots[id] = ResearchTargetRevision.sha256(raw)
                }

                var proposedType: ItemType?
                var proposedData: Data?
                if let proposedTargetItemID {
                    if proposedTargetItemID == program.activeTargetRevision.libraryItemID {
                        throw CoreError.io("the corrected goal must be a separate item; the active goal item cannot be repurposed before governance")
                    }
                    guard let item = store.item(id: proposedTargetItemID) else {
                        throw CoreError.io("proposed target item '\(proposedTargetItemID)' does not exist")
                    }
                    guard let statement = item.statement?
                        .trimmingCharacters(in: .whitespacesAndNewlines), !statement.isEmpty else {
                        throw CoreError.io("proposed goal item '\(proposedTargetItemID)' needs a complete ## Statement")
                    }
                    proposedType = item.type
                    proposedData = try store.rawTheoryItemData(id: proposedTargetItemID)
                }

                let challenge = ProblemChallenge(
                    branchPlanID: planID,
                    targetRevisionID: program.activeTargetRevisionID,
                    description: description,
                    proposedReplacementRequest: replacement,
                    proposedTargetItemID: proposedTargetItemID,
                    proposedTargetItemType: proposedType,
                    proposedTargetItemData: proposedData,
                    evidenceItemIDs: evidenceIDs,
                    evidenceItemData: evidenceData,
                    evidenceItemSnapshots: evidenceSnapshots)
                program.upsertChallenge(challenge)
                try store.saveProgram(program)
                return challenge.id
            }
        }
    }

    /// Contract adjudication for a filed candidate: does this answer the question that was
    /// asked, assuming the mathematics holds? Runs on the reviewer tier for the same reason
    /// the finding adjudicator does — it is a judging role, and judging is never cheaper than
    /// what it judges. The ruling is written to the manifest either way, so a rejection is
    /// part of the record rather than a turn nobody can see.
    private func makeSolutionAdjudicator(
        programID: String?
    ) -> (@Sendable (String) async throws -> (accepted: Bool, note: String))? {
        guard let programID else { return nil }
        let reviewerThinking = AppSettings.effectiveThinking(for: .reviewer)
        return { @Sendable candidateID in
            let prepared = try await MainActor.run {
                [weak self] () throws -> (AgentRunner, [AgentTool], String,
                                          SuccessContract?, ResearchTargetRevision,
                                          SolutionCandidate, [TheoryItem],
                                          RecordTurn?) in
                guard let self, let store = self.store,
                      let program = store.program(id: programID),
                      let candidate = program.solutions.first(where: { $0.id == candidateID })
                else { throw CoreError.io("solution candidate \(candidateID) is missing") }
                return (makeRunner(config: try self.providerConfig(for: .reviewer)),
                        TheoryTools.readOnlyTools(store: store),
                        program.researchRequest, program.contract,
                        program.activeTargetRevision, candidate, store.items,
                        self.makeTurnRecorder())
            }
            let (runner, tools, goal, contract, revision, candidate, items, recorder) = prepared

            let ruling = try await SolutionAdjudicator.adjudicate(
                runner: runner, goal: goal, contract: contract,
                targetRevision: revision,
                candidate: candidate, items: items, tools: tools,
                thinking: reviewerThinking,
                programID: programID, record: recorder)

            return try await MainActor.run { [weak self] () -> (accepted: Bool, note: String) in
                guard let self, let store = self.store,
                      var program = store.program(id: programID),
                      var stored = program.solutions.first(where: { $0.id == candidateID })
                else { return (false, "the candidate could not be recorded") }
                // No ruling is not an acceptance: a candidate nobody managed to check stays
                // filed, and the director sees it as unadjudicated.
                guard let ruling else {
                    stored.status = .filed
                    program.upsertSolution(stored)
                    try? store.saveProgram(program)
                    return (false, "the adjudication turn produced no ruling")
                }
                stored.contractRuling = SolutionCandidate.ContractRuling(
                    accepted: ruling.accepted, note: ruling.note,
                    satisfiedCompletionIDs: ruling.satisfiedCompletionIDs)
                stored.status = ruling.accepted ? .underReview : .contractRejected
                program.upsertSolution(stored)
                program.updated = Date()
                try? store.saveProgram(program)
                return (ruling.accepted, ruling.note)
            }
        }
    }

    /// The cited artifact's script and output, capped — what the adjudicator gets instead of
    /// the branch's word for what the run showed. Reading is best-effort: a missing artifact
    /// is reported as such rather than failing the adjudication.
    private static func artifactExcerpt(for finding: ProgramFinding, rootURL: URL) -> String? {
        guard let path = finding.artifactPath, !path.isEmpty else { return nil }
        // The path may cite the folder or a file inside it; read the folder either way.
        let cited = rootURL.appendingPathComponent(path)
        let folder = cited.pathExtension.isEmpty ? cited : cited.deletingLastPathComponent()
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        else { return nil }
        var sections: [String] = []
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where ["py", "txt", "json", "md"].contains(file.pathExtension) {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            sections.append("--- \(file.lastPathComponent) ---\n\(String(text.prefix(12_000)))")
        }
        return sections.isEmpty ? nil : sections.joined(separator: "\n\n")
    }

    /// Writes finished agent turns to a program's transcript store.
    ///
    /// One closure per program (or per planning session), handed to every agent that runs under
    /// it. Recording is fire-and-forget and failures are swallowed inside the store: a run must
    /// never fall over because its own history could not be written.
    ///
    /// Nil when there is no project open, which is also the only state where there is nowhere to
    /// write — every other caller gets a working recorder and does not have to check.
    func makeTurnRecorder() -> RecordTurn? {
        guard let store else { return nil }
        return { turn in
            try? store.saveTurn(turn)
        }
    }

    /// What a pilot needs: read-only theory, the sandbox, and arXiv. Pilots deliberately get
    /// no write tools — they run before the success contract exists, and nothing should reach
    /// the library before there is a definition of what counts.
    func makePilotContext() throws -> (runner: AgentRunner, tools: [AgentTool],
                                       notation: String, outline: String,
                                       memory: String, thinking: ThinkingLevel) {
        guard let store else { throw CoreError.io("No project open") }
        let runner = makeRunner(config: try providerConfig(for: .planner))
        let sandbox = makePythonSandbox(artifactsURL: store.artifactsURL)
        let tools = TheoryTools.readOnlyTools(store: store)
            + SandboxTools.computeTools(sandbox: sandbox)
            + ArxivTools.tools()
        return (runner, tools, store.notation,
                ContextAssembly.outline(items: store.items), store.memory,
                AppSettings.effectiveThinking(for: .planner))
    }

    /// Recognition gets read/search/compute plus one deliberately create-only library tool.
    /// Existing theory is immutable while the system is deciding whether research is needed.
    func makeRecognitionContext() throws -> (runner: AgentRunner, tools: [AgentTool],
                                             notation: String, outline: String,
                                             thinking: ThinkingLevel) {
        guard let store else { throw CoreError.io("No project open") }
        let sandbox = makePythonSandbox(artifactsURL: store.artifactsURL,
                                        runNamespace: "planning-recognition")
        let create = Recognition.createItemTool(store: store) { @MainActor [weak self] proposal in
            guard let self else { throw CoreError.io("No project open") }
            return try self.applyDirectWrite(proposal)
        }
        let tools = TheoryTools.readOnlyTools(store: store)
            + SandboxTools.computeTools(sandbox: sandbox)
            + SourceTools.tools(attached: attachedSources.map { (slug: $0.ref.slug, store: $0.store) })
            + ArxivTools.tools()
            + [create]
        return (makeRunner(config: try providerConfig(for: .planner)), tools, store.notation,
                ContextAssembly.outline(items: store.items),
                AppSettings.effectiveThinking(for: .planner))
    }

    /// Applies the same two independent gates as a branch claim, before any pilots or routes
    /// see the recognition result. Rejection notes become explicit planning input.
    func reviewRecognitionClaim(
        _ claim: Recognition.Claim,
        goal: String,
        contract: SuccessContract?,
        targetItemID: String,
        sessionID: String
    ) async throws -> SolutionCandidate {
        guard let store else { throw CoreError.io("No project open") }
        var candidate = SolutionCandidate(
            branchPlanID: "planning-recognition",
            primaryItemID: claim.primaryItemID,
            supportingItemIDs: claim.supportingItemIDs,
            argument: claim.argument)
        guard store.item(id: claim.primaryItemID) != nil else {
            candidate.contractRuling = .init(
                accepted: false,
                note: "The claimed primary item '\(claim.primaryItemID)' does not exist.")
            candidate.status = .contractRejected
            return candidate
        }
        let byID = Dictionary(store.items.map { ($0.id, $0) },
                              uniquingKeysWith: { first, _ in first })
        candidate.itemSnapshots = Dictionary(
            SolutionReviewGate.closure(of: candidate, items: byID)
                .map { ($0.id, SolutionReviewGate.contentHash($0)) },
            uniquingKeysWith: { first, _ in first })

        let adjudicator = makeRunner(config: try providerConfig(for: .reviewer))
        var targetRevision = try store.makeResearchTargetRevision(
            requestText: contract?.statement ?? goal, libraryItemID: targetItemID,
            changeNote: "Provisional frozen goal for recognition review.")
        if let contract {
            targetRevision.statement = contract.statement
            targetRevision.ambiguities = contract.ambiguities
            targetRevision.reviewedAt = contract.reviewedAt
        }
        let ruling = try await SolutionAdjudicator.adjudicate(
            runner: adjudicator, goal: goal, contract: contract,
            targetRevision: targetRevision, candidate: candidate,
            items: store.items, tools: TheoryTools.readOnlyTools(store: store),
            thinking: AppSettings.effectiveThinking(for: .reviewer),
            programID: sessionID, record: makeTurnRecorder())
        guard let ruling else { return candidate }
        candidate.contractRuling = .init(
            accepted: ruling.accepted, note: ruling.note,
            satisfiedCompletionIDs: ruling.satisfiedCompletionIDs)
        guard ruling.accepted else {
            candidate.status = .contractRejected
            return candidate
        }

        candidate.status = .underReview
        let provisional = ResearchProgram(
            id: sessionID, goal: goal, targetRevisions: [targetRevision],
            activeTargetRevisionID: targetRevision.id,
            contract: contract, solutions: [candidate])
        let context = try makeSolutionReviewContext(program: provisional, store: store)
        let reviewed = try await SolutionReviewGate.review(
            candidate: candidate, goal: goal, contract: contract, items: context.items,
            cache: context.cache, verifier: context.verifier,
            reviewAssembly: { chain, candidate in
                try await SolutionReviewGate.reviewAssembly(
                    runner: context.runner, goal: goal, contract: contract,
                    chain: chain, candidate: candidate, tools: context.tools,
                    thinking: context.thinking, programID: sessionID,
                    record: self.makeTurnRecorder())
            })
        candidate.reviewRuling = reviewed.ruling
        candidate.status = reviewed.ruling.accepted ? .accepted : .reviewRejected
        storeSolutionReviewCache(reviewed.cache, programID: sessionID)
        return candidate
    }

    /// The goal editor replaces the former audit-then-contract pair. It may read project-local
    /// context and create one missing goal item, but it cannot edit existing theory.
    func makeResearchGoalEditorContext() throws -> (
        runner: AgentRunner, tools: [AgentTool], notation: String, macros: String,
        outline: String, thinking: ThinkingLevel, store: ProjectStore,
        applyCreate: @Sendable (TheoryProposal) async throws -> String
    ) {
        guard let store else { throw CoreError.io("No project open") }
        let tools = TheoryTools.readOnlyTools(store: store)
            + SourceTools.tools(attached: attachedSources.map { (slug: $0.ref.slug, store: $0.store) })
        let apply: @Sendable (TheoryProposal) async throws -> String = {
            @MainActor [weak self] proposal in
            guard let self else { throw CoreError.io("The project was closed") }
            guard proposal.action == .create else {
                throw CoreError.io("The research-goal editor cannot update existing theory")
            }
            return try self.applyDirectWrite(proposal)
        }
        return (makeRunner(config: try providerConfig(for: .planner)), tools,
                store.notation, store.macros, ContextAssembly.outline(items: store.items),
                AppSettings.effectiveThinking(for: .planner), store, apply)
    }

    /// Legacy contexts remain for opening older planning histories and focused tests. New
    /// programs use `makeResearchGoalEditorContext` and one model turn.
    /// The contract drafter runs on the planner's model: it is deciding what the whole run
    /// will be measured against, which is the last place to economise.
    func makeContractDrafterContext() throws -> (runner: AgentRunner, thinking: ThinkingLevel) {
        (makeRunner(config: try providerConfig(for: .planner)),
         AppSettings.effectiveThinking(for: .planner))
    }

    /// The statement auditor: project-local reading tools only.
    ///
    /// No `search_arxiv` here, deliberately. Reaching for a nearby paper while deciding how to
    /// read the user's question biases the reading toward that paper's terminology and invites
    /// swapping the question for a known related theorem — before the contract is even frozen.
    /// The project's own theory and sources are fair game, because resolving the project's
    /// notation is the job; prior-work and novelty questions belong to a pilot, afterwards.
    func makeStatementAuditorContext() throws -> (runner: AgentRunner, tools: [AgentTool],
                                                  notation: String, outline: String,
                                                  thinking: ThinkingLevel) {
        guard let store else { throw CoreError.io("No project open") }
        let tools = TheoryTools.readOnlyTools(store: store)
            + SourceTools.tools(attached: attachedSources.map { (slug: $0.ref.slug, store: $0.store) })
        return (makeRunner(config: try providerConfig(for: .planner)),
                tools, store.notation, ContextAssembly.outline(items: store.items),
                AppSettings.effectiveThinking(for: .planner))
    }

    /// The pilot selector: one cheap turn with no tools at all. It adapts the first attempts
    /// to the problem from the statement and the contract, and giving it read access would
    /// invite it to start doing the research it is supposed to be scoping.
    func makePilotSelectorContext() throws -> (runner: AgentRunner, thinking: ThinkingLevel) {
        (makeRunner(config: try providerConfig(for: .planner)), .off)
    }

    /// Independent of the portfolio planner and deliberately tool-free: it judges the routes
    /// from their submitted mechanisms, not from the reasoning that made them sound plausible.
    func makePortfolioAuditorContext() throws -> (runner: AgentRunner, thinking: ThinkingLevel) {
        (makeRunner(config: try providerConfig(for: .reviewer)),
         AppSettings.effectiveThinking(for: .reviewer))
    }

    /// What the solution review gate needs. The reviewer tier throughout: this is the last
    /// check before a program records that it answered the question, and "never weaker than
    /// what it judges" applies with full force.
    func makeSolutionReviewContext(
        program: ResearchProgram, store: ProjectStore
    ) throws -> (runner: AgentRunner, tools: [AgentTool], verifier: ProofVerifier,
                 items: [TheoryItem], cache: SolutionReviewGate.ReviewCache,
        thinking: ThinkingLevel) {
        let reviewerConfig = try providerConfig(for: .reviewer)
        let runner: AgentRunner = ProgramBudgetedRunner(
            base: makeRunner(config: reviewerConfig),
            programID: program.id,
            stage: AgentTurnRecord.Role.review.rawValue,
            workClass: .control)
        let sandbox = makePythonSandbox(artifactsURL: store.artifactsURL,
                                        runNamespace: "solution-review")
        let tools = TheoryTools.readOnlyTools(store: store)
            + SandboxTools.computeTools(sandbox: sandbox)
        let verifier = LLMReviewer(
            runner: runner, tools: tools,
            notation: store.notation,
            outline: ContextAssembly.outline(items: store.items),
            thinking: AppSettings.effectiveThinking(for: .reviewer),
            exclusions: [])
        return (runner, tools, verifier, store.items,
                solutionReviewCaches[program.id] ?? [:],
                AppSettings.effectiveThinking(for: .reviewer))
    }

    /// Separate reviewer-tier context for a request challenge. Both gates use the same
    /// capability level but start with fresh histories and different mandates.
    func makeProblemChallengeReviewContext(
        program: ResearchProgram
    ) throws -> (runner: AgentRunner, tools: [AgentTool], thinking: ThinkingLevel) {
        guard let store else { throw CoreError.io("No project open") }
        let runner: AgentRunner = ProgramBudgetedRunner(
            base: makeRunner(config: try providerConfig(for: .reviewer)),
            programID: program.id,
            stage: "problem_challenge_review",
            workClass: .control)
        let sandbox = makePythonSandbox(artifactsURL: store.artifactsURL,
                                        runNamespace: "problem-challenge-review")
        let tools = TheoryTools.readOnlyTools(store: store)
            + SandboxTools.computeTools(sandbox: sandbox)
        return (runner, tools, AppSettings.effectiveThinking(for: .reviewer))
    }

    /// Item reviews already known good, per program, so re-claiming unchanged work does not
    /// re-review it. Deliberately in memory only: a cache that survived a restart would have
    /// to be invalidated against files the user may have edited in between, and getting that
    /// wrong means accepting a solution on a review of something else.
    func storeSolutionReviewCache(_ cache: SolutionReviewGate.ReviewCache, programID: String) {
        solutionReviewCaches[programID] = cache
    }

    /// What a director turn needs from the app. The director allocates rather than discovers,
    /// but it is deciding whether to spend another generation — so it runs on its own
    /// configured model, which falls back to the planner's until the user sets one.
    func makeDirectorContext(
        program: ResearchProgram
    ) throws -> (runner: AgentRunner, branchMemories: [String: String],
                 projectMemory: String, thinking: ThinkingLevel) {
        guard let store else { throw CoreError.io("No project open") }
        let runner = makeRunner(config: try providerConfig(for: .director))
        var memories: [String: String] = [:]
        for branch in program.branches {
            memories[branch.planID] = store.loadBranchMemory(planID: branch.planID)
        }
        return (runner, memories, store.memory, AppSettings.effectiveThinking(for: .director))
    }

    func makeSynthesisConfig(
        program: ResearchProgram,
        records: [String: RunRecord]
    ) throws -> (runner: AgentRunner, config: AgentConfig) {
        guard let store else { throw CoreError.io("No project open") }
        let runner = makeRunner(config: try providerConfig(for: .planner))
        let inputs = program.branches.map { branch -> ProgramSynthesis.BranchInput in
            let plan = plans.first { $0.id == branch.planID }
            let record = records[branch.planID]
            return ProgramSynthesis.BranchInput(
                planID: branch.planID,
                title: branch.title,
                challengesLeadingAnswer: branch.challengesLeadingAnswer,
                approach: plan?.approach ?? "",
                kill: plan?.kill,
                taskLines: plan?.tasks.map { "\($0.index) [\($0.status.rawValue)] \($0.title)" } ?? [],
                tokensUsed: record?.tokensUsed ?? 0,
                journal: record?.journal.map { "task \($0.taskIndex) [\($0.outcome)]: \($0.summary)" } ?? [],
                memory: store.loadBranchMemory(planID: branch.planID))
        }
        let synthesisPrompt = ProgramSynthesis.systemPrompt(
            goal: program.researchRequest, contract: program.contract,
            solution: program.acceptedSolution, branches: inputs,
            findings: program.findings, skippedCells: program.skippedCells)
            + "\n\n" + ContextAssembly.researchGoalItemSection(program.activeTargetRevision)
        return (runner, AgentConfig(
            systemPrompt: SystemPrompt(synthesisPrompt),
            // The synthesis turn is the one place a program writes the project memory.
            tools: [makeMemoryTool()],
            maxIterations: 8,
            thinking: AppSettings.effectiveThinking(for: .planner)))
    }

    /// Builds the research-run engine for one run. Auto mode writes agent-settable
    /// items directly through `save` (breakage/FTS stay correct) and queues anything
    /// above the agent's slice of the trust ladder as a proposal; checkpoint mode
    /// keeps the full proposal flow.
    func makeResearchWorkbench(
        mode: RunMode,
        onEvent: @escaping @Sendable (ResearchWorkbench.Event) -> Void
    ) throws -> ResearchWorkbench {
        try makeBranchWorkbench(program: nil, branch: nil, runtime: nil,
                                mode: mode, onEvent: onEvent)
    }

    /// Builds the workbench for one research branch. With `program`/`branch` nil this is
    /// an ordinary single-plan run (identical behavior to before Research Programs); with
    /// them set, the branch additionally gets its own isolated memory file, its lens, the
    /// cross-branch findings section, a namespaced artifact folder, and publish_finding.
    func makeBranchWorkbench(
        program: ResearchProgram?,
        branch: ResearchProgram.Branch?,
        runtime: ProgramRunner.BranchRuntime?,
        mode: RunMode,
        persistentScheduler: PersistentResearchScheduler? = nil,
        assignment: ResearchAssignment? = nil,
        onEvent: @escaping @Sendable (ResearchWorkbench.Event) -> Void
    ) throws -> ResearchWorkbench {
        guard let store else { throw CoreError.io("No project open") }
        let program = runtime?.program ?? program
        let binding: ProgramAccountingBinding?
        if let program, !program.isVirtual, let branch {
            binding = try ProgramAccountingBinding(program: program, subjectID: assignment?.id ?? branch.planID,
                ledger: store.loadUsageLedger(programID: program.id))
        } else { binding = nil }
        let assignmentBudget = binding?.assignmentBudget
        // A branch may override the researcher model; anything unconfigured falls back to
        // the program's own override, then the task default — never failing the run.
        let researcherRunner = try researchRunnerOverride?(.researcher)
            ?? makeRunner(config: branchProviderConfig(for: branch, program: program))
        let usageProgramID = (program?.isVirtual == false) ? (program?.id ?? "") : ""
        let usageSubjectID = assignment?.id ?? branch?.planID
        let runner: AgentRunner = ProgramBudgetedRunner(
            base: researcherRunner,
            programID: usageProgramID,
            stage: "branch_research",
            subjectID: usageSubjectID,
            workClass: .research, assignmentBudget: assignmentBudget, requiresAccounting: binding != nil)
        let reviewerRunner: AgentRunner = ProgramBudgetedRunner(
            base: try researchRunnerOverride?(.reviewer) ?? makeRunner(config: try providerConfig(for: .reviewer, program: program)),
            programID: usageProgramID,
            stage: AgentTurnRecord.Role.review.rawValue,
            subjectID: usageSubjectID,
            workClass: .control, assignmentBudget: assignmentBudget, requiresAccounting: binding != nil)
        let proverRunner: AgentRunner = ProgramBudgetedRunner(
            base: try researchRunnerOverride?(.prover) ?? makeRunner(config: try providerConfig(for: .prover, program: program)),
            programID: usageProgramID,
            stage: "branch_prover",
            subjectID: usageSubjectID,
            workClass: .research, assignmentBudget: assignmentBudget, requiresAccounting: binding != nil)
        // Only program branches namespace their artifacts; a single plan keeps the
        // familiar `<timestamp>-<label>` folders.
        let sandbox = makePythonSandbox(artifactsURL: store.artifactsURL,
                                        runNamespace: runtime == nil ? nil : branch?.planID)

        let enqueueProposal: @Sendable (TheoryProposal) -> Void = { [weak self] proposal in
            DispatchQueue.main.async {
                guard let self else { return }
                do {
                    try self.validateProtectedGoalUpdate(proposal)
                    self.pendingProposals.append(proposal)
                } catch {
                    self.openError = error.localizedDescription
                }
            }
        }
        let applyDirect: @Sendable (TheoryProposal) async throws -> String = { @MainActor [weak self] proposal in
            guard let self, self.store != nil else { throw CoreError.io("No project open") }
            try self.validateProtectedGoalUpdate(proposal)
            guard TheoryWritePolicy.agentSettableStatuses.contains(proposal.item.status) else {
                self.pendingProposals.append(proposal)
                return "Status '\(proposal.item.status.rawValue)' needs the user — queued as a proposal instead."
            }
            self.save(proposal.item)
            return "Wrote '\(proposal.item.id)' [\(proposal.item.status.rawValue)]."
        }
        // ProofWorkbench's proposal callback is synchronous; in auto mode each proposal
        // is applied on its own main-actor hop (independent items, order not critical).
        let proofProposalSink: @Sendable (TheoryProposal) -> Void
        if mode == .auto {
            proofProposalSink = { proposal in
                Task<Void, Never> { _ = try? await applyDirect(proposal) }
            }
        } else {
            proofProposalSink = enqueueProposal
        }

        var contextTools: [AgentTool] = TheoryTools.readOnlyTools(store: store)
        // Evidence recording follows the run's write policy: auto mode applies it directly
        // (tested/conjecture sit inside the agent-settable trust slice), checkpoint mode
        // keeps the confirm-every-write proposal flow; run_python/oeis are read-only.
        contextTools += SandboxTools.tools(sandbox: sandbox, store: store,
                                           onProposal: enqueueProposal,
                                           applyDirect: mode == .auto ? applyDirect : nil)
        contextTools += SourceTools.tools(attached: attachedSources.map { (slug: $0.ref.slug, store: $0.store) })
        // A run has nobody to ask, so the project's files are readable here only under the
        // standing permission; the briefing below says which of the two it is.
        let documentTools = DocumentTools.tools(store: store, access: makeStandingDocumentAccess())
        contextTools += documentTools
        if let branch, let runtime {
            contextTools.append(ProgramTools.publishFindingTool(
                branchPlanID: branch.planID,
                targetRevisionID: program?.activeTargetRevisionID,
                adjudicate: makeCounterexampleAdjudicator(program: program),
                publish: runtime.publish))
        }
        if let assignment, let persistentScheduler {
            contextTools.append(ResearchEvidenceText.assignmentTool(id: assignment.id, scheduler: persistentScheduler))
            contextTools.append(ProgramTools.publishFindingTool(branchPlanID: assignment.id,
                targetRevisionID: assignment.targetRevisionID,
                publish: { try await persistentScheduler.publish($0) }))
        }

        // `branch` identifies which plan is running (a standalone plan is a one-branch
        // virtual program); `runtime` is what makes it a *program* branch — isolated
        // memory, shared facts, findings. Steering applies to both.
        let branchPlanID = branch?.planID
        let isProgramBranch = runtime != nil || persistentScheduler != nil
        let plan = runtime?.plan ?? branchPlanID.flatMap { store.plan(id: $0) }
        var memoryText: (@Sendable () -> String)?
        if isProgramBranch, let planID = branchPlanID {
            memoryText = { [store] in store.loadBranchMemory(planID: planID) }
        }
        // Snapshot on the main actor here; the program never writes the project memory
        // mid-run, so a snapshot cannot go stale under the branch.
        let projectMemorySnapshot = store.memory
        var sharedFactsText: (@Sendable () -> String?)?
        if let runtime, let planID = branchPlanID, let programID = program?.id {
            sharedFactsText = { [store] in
                // Verdicts live on the manifest and can change mid-run, so they are read
                // from disk (a pure read) rather than trusted from the in-memory pool.
                let rulings = Dictionary(
                    (store.program(id: programID)?.findings ?? [])
                        .map { ($0.id, ($0.verdict, $0.verdictNote)) },
                    uniquingKeysWith: { _, last in last })
                let findings = runtime.findings().map { finding -> ProgramFinding in
                    guard let ruling = rulings[finding.id] else { return finding }
                    var ruled = finding
                    ruled.verdict = ruling.0
                    ruled.verdictNote = ruling.1
                    return ruled
                }
                // Routings live on the manifest and are written by the director's routing
                // turn while this branch runs, so they are read from disk with the verdicts.
                let onDisk = store.program(id: programID)
                let routings = onDisk?.routings ?? []
                let routed = findings.filter { finding in
                    guard finding.branchPlanID != planID, !finding.isRejected else { return false }
                    return routings.first { $0.findingID == finding.id }?.reaches(planID) == true
                }
                return ProgramContext.sharedFactsSection(
                    projectMemory: projectMemorySnapshot,
                    routedFindings: routed,
                    // A route the director closed mid-run must reach the next task, not the
                    // next program.
                    routes: onDisk?.routes ?? [])
            }
        }
        var lensSections: [String] = []
        if let assignment {
            lensSections.append("Assignment constraints: " + assignment.constraints.joined(separator: "\n")
                + "\nRelevant item IDs: " + assignment.itemIDs.joined(separator: ", ")
                + "\nSupplied evidence IDs: " + assignment.evidenceIDs.joined(separator: ", "))
        }
        if let program, !program.isVirtual {
            lensSections.append(ContextAssembly.researchGoalItemSection(program.activeTargetRevision))
        }
        if let plan, !plan.lens.isEmpty {
            lensSections.append(ProgramPlanner.lensSection(
                prior: plan.lens,
                challengesLeadingAnswer: plan.challengesLeadingAnswer,
                kill: plan.kill ?? ""))
        }
        lensSections.append(contentsOf: documentsSectionForRuns())
        // Re-read from disk per task, so guidance typed mid-run lands at the next task.
        var guidanceText: (@Sendable () -> String?)?
        if let planID = branchPlanID {
            guidanceText = { [store] in
                let text = store.plan(id: planID)?.guidance ?? ""
                return text.isEmpty ? nil : text
            }
        }
        if let assignment, let program {
            guidanceText = { [store] in
                guard let current = store.program(id: program.id)?.execution?.assignments.first(where: { $0.id == assignment.id }) else { return nil }
                return current.messages.map { $0.text + "\nEvidence IDs: " + $0.evidenceIDs.joined(separator: ", ") }.joined(separator: "\n")
            }
            sharedFactsText = { [store] in
                guard let current = store.program(id: program.id),
                      let a = current.execution?.assignments.first(where: { $0.id == assignment.id }) else { return nil }
                let ids = Set(a.evidenceIDs + a.messages.flatMap(\.evidenceIDs))
                return current.findings.filter { ids.contains($0.id) }.map {
                    "Finding \($0.id) (\($0.verdict?.rawValue ?? "unverified")): \($0.statement)\n\($0.verdictNote ?? "")"
                }.joined(separator: "\n")
            }
        }

        let outline = ContextAssembly.outline(items: store.items)
        // The contract is the program's, fixed for the run. Its not-counted list reaches the
        // reviewer as well as the tasks: the reviewer is where checking against those costs
        // nothing, because it is already reading the argument line by line.
        let contract = program?.contract
        let verifier = LLMReviewer(
            runner: reviewerRunner,
            tools: TheoryTools.readOnlyTools(store: store) + SandboxTools.computeTools(sandbox: sandbox),
            notation: store.notation,
            outline: outline,
            thinking: AppSettings.effectiveThinking(for: .reviewer),
            exclusions: [])

        let attachedForProver = attachedSources.map { (slug: $0.ref.slug, store: $0.store) }
        let userProfile = AppSettings.userProfile
        let proverThinking = AppSettings.effectiveThinking(for: .prover)
        let reviewerThinking = AppSettings.effectiveThinking(for: .reviewer)
        // Built inside the runner (tools aren't Sendable); the gate itself is.
        let documentAccess = makeStandingDocumentAccess()
        let proveRunner: @Sendable (String, @escaping @Sendable (AgentActivity) -> Void) async throws -> ProofWorkbench.Outcome = { targetID, onActivity in
            let workbench = ProofWorkbench(
                runner: proverRunner,
                reviewerRunner: reviewerRunner,
                store: store,
                attachedSources: attachedForProver,
                extraTools: SandboxTools.computeTools(sandbox: sandbox)
                    + DocumentTools.tools(store: store, access: documentAccess),
                userProfile: userProfile,
                configuration: ProofWorkbench.Configuration(
                    policy: .autoExternal, maxRounds: program?.execution?.limits.reviewRounds.runnerValue ?? 3,
                    proverThinking: proverThinking, reviewerThinking: reviewerThinking),
                memoryText: memoryText,
                extraSystemSections: lensSections,
                onProposal: proofProposalSink,
                onEvent: { event in
                    switch event {
                    case .proverActivity(let activity), .reviewerActivity(let activity):
                        onActivity(activity)
                    default:
                        break
                    }
                })
            let outcome = try await workbench.run(targetID: targetID)
            // A clean review is a fact siblings need; derived from the outcome, never
            // claimed by the model.
            if let runtime, let branchPlanID,
               let finding = ProgramContext.finding(fromProveOutcome: outcome,
                                                    targetID: targetID,
                                                    branchPlanID: branchPlanID) {
                try? await runtime.publish(finding)
            }
            return outcome
        }

        return ResearchWorkbench(
            runner: runner,
            store: store,
            contextTools: contextTools,
            memoryTool: persistentScheduler == nil ? ((isProgramBranch ? branchPlanID.map { makeBranchMemoryTool(planID: $0) } : nil)
                ?? makeMemoryTool()) : nil,
            writePolicy: mode == .auto ? .direct(applyDirect) : .propose(enqueueProposal),
            proveRunner: proveRunner,
            verifier: verifier,
            savePlan: { @MainActor [weak self] plan in
                guard let store = self?.store else { throw CoreError.io("No project open") }
                try store.savePlan(plan)
            },
            memoryText: memoryText,
            sharedFactsText: sharedFactsText,
            guidanceText: guidanceText,
            lensWasAbandoned: makeLensAbandonedCheck(planID: branchPlanID,
                                                    programID: program?.id),
            adjudicateSolution: persistentScheduler == nil ? makeSolutionAdjudicator(programID: program?.id) : nil,
            fileSolutionClaim: assignment.flatMap { a in persistentScheduler.map { makePersistentSolutionFiler(assignment: a, scheduler: $0) } }
                ?? makeSolutionFiler(planID: branchPlanID, programID: program?.id),
            fileProblemChallenge: assignment.flatMap { a in persistentScheduler.map { makePersistentChallengeFiler(assignment: a, scheduler: $0) } }
                ?? makeProblemChallengeFiler(planID: branchPlanID, programID: program?.id),
            configuration: ResearchWorkbench.Configuration(
                thinking: AppSettings.effectiveThinking(for: .researcher),
                maxTaskIterations: program?.execution?.limits.toolCalls.runnerValue ?? AppSettings.Limit.researchTaskIterations.value,
                extraSystemSections: lensSections,
                successContract: contract,
                maxPlanRevisions: program?.execution?.limits.planRevisions.runnerValue ?? AppSettings.Limit.researchPlanRevisions.value,
                continuation: persistentScheduler == nil ? (program?.continuation ?? .manual) : .manual,
                maxConversationTokens: AppSettings.Limit.researchConversationTokens.value,
                // A virtual program wraps a standalone plan and is never persisted, so there is
                // nowhere to archive under; an empty id turns archiving off rather than leaving
                // a directory nothing reads.
                programID: (program?.isVirtual ?? true) ? "" : (program?.id ?? ""),
                explicitOutcomes: persistentScheduler != nil,
                reviewRounds: program?.execution?.limits.reviewRounds ?? .bounded(3),
                guidanceDelivery: assignment.flatMap { a in persistentScheduler.map { ResearchGuidanceDelivery(assignment: a, scheduler: $0) } }),
            onEvent: onEvent
        )
    }

    /// The researcher provider for a branch: its own override when set and usable, otherwise
    /// the program's role override, otherwise the researcher task default (a stale override
    /// must not strand the program).
    private func branchProviderConfig(for branch: ResearchProgram.Branch?,
                                      program: ResearchProgram? = nil) throws -> ProviderConfig {
        guard let branch, let rawKind = branch.providerKind, let model = branch.model,
              let kind = ProviderKind(rawValue: rawKind) else {
            return try providerConfig(for: .researcher, program: program)
        }
        guard kind.usesAPIKey else {
            return ProviderConfig(
                kind: kind, apiKey: "", model: model,
                codexBinaryPath: AppSettings.codexPath.isEmpty ? nil : AppSettings.codexPath)
        }
        guard let key = Keychain.apiKey(for: kind), !key.isEmpty else {
            return try providerConfig(for: .researcher, program: program)
        }
        return ProviderConfig(kind: kind, apiKey: key, model: model)
    }

    /// Titling round-trip: system prompt + the opening message, no tools, no project
    /// context — kept separate from makeChatConfig so it never touches the (possibly large)
    /// theory/notation/sources context the real chat turn assembles.
    func makeChatNamingConfig() throws -> (runner: AgentRunner, config: AgentConfig) {
        let runner = makeRunner(config: try providerConfig(for: .chatNaming))
        return (runner, AgentConfig(
            systemPrompt: SystemPrompt(ChatNaming.systemPrompt), maxIterations: 1, maxTokens: 32, thinking: .off))
    }

    func makeOrganizerConfig(instructions: String = "") throws -> (runner: AgentRunner, config: AgentConfig) {
        guard let store else { throw CoreError.io("No project open") }
        let runner = makeRunner(config: try providerConfig(for: .importer))
        let system = Organizer.systemPrompt(
            existingItems: store.items, notation: store.notation,
            instructions: instructions.isEmpty ? nil : instructions)
        return (runner, AgentConfig(systemPrompt: SystemPrompt(system), tools: [], maxTokens: 16384))
    }

    func makeExplorerConfig(candidateCount: Int) throws -> (runner: AgentRunner, config: AgentConfig) {
        guard let store else { throw CoreError.io("No project open") }
        let runner = makeRunner(config: try providerConfig(for: .explorer))
        let onProposal: @Sendable (TheoryProposal) -> Void = { [weak self] proposal in
            DispatchQueue.main.async { self?.pendingProposals.append(proposal) }
        }
        let sandbox = makePythonSandbox(artifactsURL: store.artifactsURL)
        let tools = TheoryTools.chatTools(store: store, onProposal: onProposal)
            + SandboxTools.computeTools(sandbox: sandbox)
            + SourceTools.tools(attached: attachedSources.map { (slug: $0.ref.slug, store: $0.store) })
        let system = Explorer.systemPrompt(
            notation: store.notation,
            items: store.items,
            userProfile: AppSettings.userProfile,
            candidateCount: candidateCount,
            memory: store.memory
        )
        return (runner, AgentConfig(
            systemPrompt: SystemPrompt(system), tools: tools, maxIterations: 24,
            thinking: AppSettings.effectiveThinking(for: .explorer)))
    }
}
