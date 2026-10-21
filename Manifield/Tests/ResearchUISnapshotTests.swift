import XCTest
import AppKit
import WebKit
import SwiftUI
import ManifieldCore
import ManifieldAgents
@testable import Manifield

/// Renders the persistent program page's tabs offscreen to PNG files, so the layout can be
/// looked at without screen-recording permission. Opt-in: set MANIFIELD_SNAPSHOT_DIR
/// (via `TEST_RUNNER_MANIFIELD_SNAPSHOT_DIR=… xcodebuild test`) or the test skips.
final class ResearchUISnapshotTests: XCTestCase {
    private var outputDirectory: URL!
    private var projectDirectory: URL!

    override func setUpWithError() throws {
        guard let path = ProcessInfo.processInfo.environment["MANIFIELD_SNAPSHOT_DIR"], !path.isEmpty else {
            throw XCTSkip("Set MANIFIELD_SNAPSHOT_DIR to render research UI snapshots.")
        }
        outputDirectory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        projectDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDown() {
        if let projectDirectory { try? FileManager.default.removeItem(at: projectDirectory) }
    }

    @MainActor
    func testRenderPersistentProgramTabs() async throws {
        let store = try ProjectStore.create(at: projectDirectory, name: "Snapshots")
        let state = AppState(); state.store = store; state.research.attach(appState: state)
        let resolved = Self.resolvedProgram()
        let paused = Self.pausedProgram()
        try store.saveProgram(resolved)
        try store.saveProgram(paused)
        state.reloadPlans()
        let navigation = ResearchNavigation()

        try await render("1-overview-resolved", state: state,
            PersistentProgramPage(program: resolved, research: state.research))
        try await render("2-overview-waiting", state: state,
            PersistentProgramPage(program: paused, research: state.research))
        try await render("2b-overview-waiting-wide", state: state,
            PersistentProgramPage(program: paused, research: state.research),
            size: NSSize(width: 1_800, height: 900))
        try await render("2c-overview-waiting-compact", state: state,
            PersistentProgramPage(program: paused, research: state.research),
            size: NSSize(width: 760, height: 900))
        try await render("3-assignments", state: state,
            PersistentAssignmentsTab(program: resolved, research: state.research, live: false,
                assignmentTokens: [:], navigation: navigation, selection: .constant(nil)).padding())
        try await render("4-evidence", state: state,
            EvidenceSegment(program: resolved, findings: resolved.findings, changes: []).padding())
        try await render("5-log", state: state,
            PersistentLogTab(program: resolved, research: state.research, live: false, navigation: navigation).padding())
        try await render("6-program-list", state: state, ProgramListPage())
    }

    @MainActor
    func testMathPageSizesToContentAndClipsWithoutInnerScroll() async throws {
        let state = AppState()
        let box = WebViewBox(page: "math")
        var reported: [Double] = []
        box.onMessage = { message in
            if message["type"] as? String == "contentHeight", let height = message["height"] as? Double {
                reported.append(height)
            }
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 420), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        box.webView.frame = NSRect(x: 0, y: 0, width: 520, height: 420)
        window.contentView = box.webView
        state.syncMacros(box)
        box.call("setDocument", Self.resolutionText + "\n\nA second paragraph: $\\|f(s)-f(t)\\|_2=|s-t|$ for all $s,t\\in U$.")
        try await Task.sleep(nanoseconds: 1_500_000_000)

        let fullHeight = try XCTUnwrap(reported.last)
        XCTAssertGreaterThan(fullHeight, 60, "multi-line content must report its real height")
        let errors = try await box.webView.evaluateJavaScript("document.querySelectorAll('.math-error').length") as? Int
        XCTAssertEqual(errors, 0)
        try write(try await box.webView.takeSnapshot(configuration: nil), name: "7-math-full")

        box.call("setClip", 60)
        try await Task.sleep(nanoseconds: 300_000_000)
        let clipped = try await box.webView.evaluateJavaScript(
            "[document.getElementById('content').className, document.documentElement.style.overflow, document.getElementById('content').getBoundingClientRect().height].join('|')") as? String
        XCTAssertEqual(clipped, "clipped|hidden|60")
        box.webView.frame = NSRect(x: 0, y: 0, width: 520, height: 60)
        try write(try await box.webView.takeSnapshot(configuration: nil), name: "8-math-clipped")

        // Reflow at a narrower width must re-report a taller height.
        box.call("setClip", 0)
        box.webView.frame = NSRect(x: 0, y: 0, width: 300, height: 420)
        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertGreaterThan(try XCTUnwrap(reported.last), fullHeight)
        window.contentView = nil
    }

    // MARK: Rendering

    @MainActor
    private func render<V: View>(_ name: String, state: AppState, _ view: V,
                                 size: NSSize = NSSize(width: 1320, height: 900)) async throws {
        let root = view
            .environmentObject(state)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 900_000_000)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: outputDirectory.appendingPathComponent("\(name).png"))
        window.contentView = nil
    }

    private func write(_ image: NSImage, name: String) throws {
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let png = try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try png.write(to: outputDirectory.appendingPathComponent("\(name).png"))
    }

    // MARK: Fixtures — shaped like the "local distance-preserving map" run

    static let resolutionText = "The accepted challenge gives a complete counterexample: $E=\\mathbb{R}$, $F=\\mathbb{R}^2$ with Euclidean norms, $U=(0,1)$, $V=\\mathbb{R}^2$, $f(t)=(t,0)$. All hypotheses hold, yet no affine map $\\mathbb{R}\\to\\mathbb{R}^2$ is bijective, so the asserted conclusion fails. The challenge has full-invalidity scope, so the program resolves as an invalid target."

    static func baseProgram(id: String) -> (ResearchProgram, ResearchAssignment, ResearchAssignment, ProblemChallenge) {
        var program = ResearchProgram(id: id, goal: "Extension of a local distance-preserving map",
                                      execution: .init(limits: .init(programTokens: .bounded(6_000_000))))
        program.title = "Extension of a local distance-preserving map"
        program.execution!.startedAt = Date().addingTimeInterval(-30 * 3600)
        let target = program.activeTargetRevisionID

        var first = ResearchAssignment(operationID: "op-1", programID: id, targetRevisionID: target, mode: .direct,
            objective: "Independently test the exact frozen problem for a counterexample, focusing on whether an isometric embedding on open connected $U$ into an open connected $V$ can have $E$ and $F$ of different dimensions. If false, submit a rigorous problem challenge with an explicit example; report evidence ID.",
            title: "Counterexample with dim E ≠ dim F")
        let challenge: ProblemChallenge = {
            var c = ProblemChallenge(branchPlanID: first.id, targetRevisionID: target,
                description: "The frozen statement is false. Let $E=\\mathbb{R}$ and $F=\\mathbb{R}^2$ with Euclidean norms, $U=(0,1)$, $V=\\mathbb{R}^2$, and $f(t)=(t,0)$. Both $U$ and $V$ are nonempty open connected subsets, and $\\|f(s)-f(t)\\|_2=|s-t|$ for all $s,t\\in U$. But any affine map $T:\\mathbb{R}\\to\\mathbb{R}^2$ has the form $T(t)=tv+b$, whose image is an affine line, so it cannot be bijective onto $\\mathbb{R}^2$.")
            c.status = .accepted
            c.mathematicalRuling = .init(accepted: true, note: "Accepted: the counterexample satisfies every frozen hypothesis, and every affine map $\\mathbb{R}\\to\\mathbb{R}^2$ has image in an affine line.")
            c.scopeRuling = .init(accepted: true, note: "Accepted. The example conclusively falsifies the universal conclusion. The smallest defensible repair is to require $f(U)=V$.", targetDisposition: .fullInvalidity)
            c.proposedReplacementRequest = "Add the hypothesis $f(U)=V$ to the extension theorem."
            c.evidenceItemIDs = ["cex-dimension-mismatch-open-local-isometry"]
            return c
        }()
        first.status = .paused
        first.reports = [AssignmentReport(outcome: .unresolved,
            summary: "Filed problem challenge \(challenge.id): The frozen statement is false. Let $E=\\mathbb{R}$ and $F=\\mathbb{R}^2$, $U=(0,1)$, $V=\\mathbb{R}^2$, $f(t)=(t,0)$. Any affine map $T:\\mathbb{R}\\to\\mathbb{R}^2$ has image an affine line, so it cannot be bijective onto $\\mathbb{R}^2$. The missing dimension compatibility cannot be inferred from openness of $V$ because the problem does not require $f(U)=V$ or surjectivity.",
            stopReason: .review, itemIDs: ["cex-dimension-mismatch-open-local-isometry"], challengeIDs: [challenge.id],
            tokensUsed: 87_098, headline: "Counterexample filed: $f(t)=(t,0)$ embeds $(0,1)$ isometrically in $\\mathbb{R}^2$")]
        let second = ResearchAssignment(operationID: "op-2", programID: id, targetRevisionID: target, mode: .direct,
            objective: "Analyze whether the hypotheses force $f(U)=V$ or force surjectivity/dimensional equality. Seek a concise explicit counterexample if not; submit a problem challenge if found, and report evidence ID.")
        program.execution!.assignments = [first, second]
        program.challenges = [challenge]
        let e = { (kind: ResearchProgramEvent.Kind, assignment: String?, summary: String) in
            program.execution!.append(kind, target: target, assignmentID: assignment, summary: summary)
        }
        e(.dispatched, first.id, first.objective)
        e(.started, first.id, first.objective)
        e(.dispatched, second.id, second.objective)
        e(.evidence, first.id, "Problem challenge filed for independent review.")
        e(.reviewed, first.id, "Problem challenge: accepted.")
        e(.reported, first.id, first.reports[0].summary)
        return (program, first, second, challenge)
    }

    static func resolvedProgram() -> ResearchProgram {
        var (program, _, _, challenge) = baseProgram(id: "snapshot-resolved")
        program.status = .done
        program.execution!.resolution = ProgramResolution(kind: .invalidTarget,
            targetRevisionID: program.activeTargetRevisionID, evidenceIDs: [challenge.id], explanation: resolutionText)
        return program
    }

    static func pausedProgram() -> ResearchProgram {
        var (program, _, _, _) = baseProgram(id: "snapshot-paused")
        program.title = "Paused copy waiting on the user"
        program.challenges[0].status = .scopeReview
        program.challenges[0].scopeRuling = nil
        program.status = .paused
        program.execution!.append(.directorPaused, target: program.activeTargetRevisionID,
            summary: "Should the target be read with $f(U)=V$ implicit? The literature version assumes it; the frozen statement does not. Answer before I dispatch the repaired-target assignment.")
        return program
    }
}
