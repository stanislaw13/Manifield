import XCTest
@testable import ManifieldCore

final class ResearchProgramTests: XCTestCase {

    private func makeStore() throws -> (ProjectStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("program-store-tests-\(UUID().uuidString)")
        return (try ProjectStore.create(at: dir, name: "P"), dir)
    }

    private func sampleProgram() -> ResearchProgram {
        ResearchProgram(
            id: "2026-07-24-gamma2-portfolio",
            goal: "Settle conj-gamma2-doubling",
            status: .active,
            maxConcurrentBranches: 2,
            programTokenBudget: 6_000_000,
            branches: [
                .init(planID: "2026-07-24-gamma2-portfolio-refuter", title: "Hunt counterexamples",
                      challengesLeadingAnswer: true, costClass: .cheap),
                .init(planID: "2026-07-24-gamma2-portfolio-discharging", title: "Discharging",
                      costClass: .expensive,
                      providerKind: "anthropic", model: "claude-opus-5")
            ],
            findings: [
                ProgramFinding(id: "f1", branchPlanID: "2026-07-24-gamma2-portfolio-refuter",
                               kind: .obstruction, statement: "Local charge arguments fail at δ=2.",
                               itemIDs: ["lem-min-degree-two"], artifactPath: "artifacts/run-1/stdout.txt")
            ],
            skippedCells: [.init(cell: "probabilistic", why: "The graphs are too sparse for concentration.")])
    }

    func testProgramManifestRoundTripThroughStore() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let program = sampleProgram()
        try store.saveProgram(program)

        let loaded = try XCTUnwrap(store.program(id: program.id))
        XCTAssertEqual(loaded.goal, program.goal)
        XCTAssertEqual(loaded.status, .active)
        XCTAssertEqual(loaded.maxConcurrentBranches, 2)
        XCTAssertEqual(loaded.programTokenBudget, 6_000_000)
        XCTAssertEqual(loaded.branches, program.branches, "model overrides survive the round-trip")
        XCTAssertEqual(loaded.skippedCells, program.skippedCells)

        // Dates are stored ISO8601 (human-inspectable, like plan frontmatter), so they
        // round-trip to the second — compare the finding field-wise around that.
        let loadedFinding = try XCTUnwrap(loaded.findings.first)
        let original = try XCTUnwrap(program.findings.first)
        XCTAssertEqual(loadedFinding.id, original.id)
        XCTAssertEqual(loadedFinding.branchPlanID, original.branchPlanID)
        XCTAssertEqual(loadedFinding.kind, original.kind)
        XCTAssertEqual(loadedFinding.statement, original.statement)
        XCTAssertEqual(loadedFinding.itemIDs, original.itemIDs)
        XCTAssertEqual(loadedFinding.artifactPath, original.artifactPath)
        XCTAssertEqual(loadedFinding.createdAt.timeIntervalSince1970,
                       original.createdAt.timeIntervalSince1970, accuracy: 1.0)

        let (all, warnings) = store.loadPrograms()
        XCTAssertEqual(all.count, 1)
        XCTAssertTrue(warnings.isEmpty)
    }

    func testPilotChoiceRoundTripsAndOlderManifestsDefaultToEnabled() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let disabled = ResearchProgram(id: "p", goal: "g", pilotsEnabled: false)

        let encoded = try encoder.encode(disabled)
        XCTAssertFalse(try decoder.decode(ResearchProgram.self, from: encoded).pilotsEnabled)

        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "pilotsEnabled")
        let legacyData = try JSONSerialization.data(withJSONObject: legacy)
        XCTAssertTrue(try decoder.decode(ResearchProgram.self, from: legacyData).pilotsEnabled)
    }

    func testUnparseableProgramIsAWarningNotAFailure() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try store.saveProgram(sampleProgram())
        try FileManager.default.createDirectory(at: store.programsURL, withIntermediateDirectories: true)
        try "{ not json".write(to: store.programsURL.appendingPathComponent("broken.json"),
                               atomically: true, encoding: .utf8)

        let (programs, warnings) = store.loadPrograms()
        XCTAssertEqual(programs.count, 1)
        XCTAssertEqual(warnings.count, 1)
    }

    /// The raw values are the on-disk persistence contract — renaming a case silently
    /// orphans every finding already written.
    func testFindingKindRawValuesStable() {
        XCTAssertEqual(ProgramFinding.Kind.counterexample.rawValue, "counterexample")
        XCTAssertEqual(ProgramFinding.Kind.candidateAnswer.rawValue, "candidate_answer")
        XCTAssertEqual(ProgramFinding.Kind.proofOutcome.rawValue, "proof_outcome")
        XCTAssertEqual(ProgramFinding.Kind.obstruction.rawValue, "obstruction")
        XCTAssertEqual(ProgramFinding.Kind.reduction.rawValue, "reduction")
        XCTAssertEqual(ProgramFinding.Kind.evidence.rawValue, "evidence")
        XCTAssertEqual(ProgramFinding.Kind.lensAbandoned.rawValue, "lens_abandoned")
        XCTAssertEqual(ProgramFinding.Kind.allCases.count, 7)
    }




    // MARK: - Deleting

    /// A branch memory is invisible to `loadPlans()`, so deleting only the plan file
    /// leaves an orphan that would resurface under any later plan reusing the id.
    func testDeletingAPlanTakesItsBranchMemory() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.savePlan(PlanDocument(id: "b1", goal: "g"))
        try store.saveBranchMemory(planID: "b1", text: "## Goal\nbranch state")
        XCTAssertFalse(store.loadBranchMemory(planID: "b1").isEmpty)

        try store.deletePlan(id: "b1")

        XCTAssertNil(store.plan(id: "b1"))
        XCTAssertEqual(store.loadBranchMemory(planID: "b1"), "")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: store.branchMemoryURL(planID: "b1").path))
    }

    func testDeletingAMissingPlanIsNotAnError() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertNoThrow(try store.deletePlan(id: "never-existed"))
    }

    func testDeletingAProgramRemovesManifestBranchesMemoriesAndReport() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        var program = sampleProgram()
        for branch in program.branches {
            try store.savePlan(PlanDocument(id: branch.planID, goal: "g", program: program.id))
            try store.saveBranchMemory(planID: branch.planID, text: "state for \(branch.planID)")
        }
        let reportPath = "programs/\(program.id)-report.md"
        try FileManager.default.createDirectory(at: store.programsURL,
                                                withIntermediateDirectories: true)
        try "# report".write(to: dir.appendingPathComponent(reportPath),
                             atomically: true, encoding: .utf8)
        program.reportPath = reportPath
        try store.saveProgram(program)

        try store.deleteProgram(program)

        XCTAssertNil(store.program(id: program.id))
        for branch in program.branches {
            XCTAssertNil(store.plan(id: branch.planID))
            XCTAssertEqual(store.loadBranchMemory(planID: branch.planID), "")
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent(reportPath).path))
    }

    /// Only the plans the manifest lists may go. A plan belonging to another program is
    /// not collateral, and neither is an unrelated standalone plan.
    func testDeletingAProgramLeavesUnrelatedPlansAlone() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let program = sampleProgram()
        for branch in program.branches {
            try store.savePlan(PlanDocument(id: branch.planID, goal: "g", program: program.id))
        }
        try store.savePlan(PlanDocument(id: "bystander", goal: "other work"))
        try store.saveBranchMemory(planID: "bystander", text: "keep me")
        try store.saveProgram(program)

        try store.deleteProgram(program)

        XCTAssertNotNil(store.plan(id: "bystander"))
        XCTAssertEqual(store.loadBranchMemory(planID: "bystander"), "keep me")
    }

    /// Virtual programs wrap a standalone plan and have no manifest on disk; deleting one
    /// must still remove the plan it wraps rather than throwing on the missing file.
    func testDeletingAVirtualProgramRemovesTheWrappedPlan() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let plan = PlanDocument(id: "solo", goal: "standalone")
        try store.savePlan(plan)
        try store.saveBranchMemory(planID: "solo", text: "notes")

        try store.deleteProgram(ResearchProgram.virtual(plan: plan))

        XCTAssertNil(store.plan(id: "solo"))
        XCTAssertEqual(store.loadBranchMemory(planID: "solo"), "")
    }

    // MARK: - Status vocabulary

    /// `failed` is a verdict and `abandoned` is a shrug; the archive is read to learn what
    /// has been ruled out, so collapsing them would lose the distinction that matters.
    func testFailedAndAbandonedAreDistinctAndBothArchive() {
        XCTAssertNotEqual(ResearchProgram.Status.failed, .abandoned)
        for status in ResearchProgram.Status.allCases {
            XCTAssertEqual(status.isArchived, [.done, .abandoned, .failed].contains(status))
        }
        for status in PlanStatus.allCases {
            XCTAssertEqual(status.isArchived, [.done, .abandoned, .failed].contains(status))
        }
        XCTAssertFalse(PlanStatus.userSettable.contains(.active),
                       "run machinery owns active; offering it would desynchronize state")
        XCTAssertFalse(PlanStatus.userSettable.contains(.draft))
    }

    /// Closing a branch out has to be reversible. Without a runnable status in the menu, a
    /// branch marked discarded could never be picked up again.
    func testEveryCloseOutStatusCanBeReversed() {
        XCTAssertTrue(PlanStatus.userSettable.contains(.approved),
                      "there must be a way back to a runnable state")
        XCTAssertEqual(PlanStatus.approved.userActionLabel, "Reopen (runnable)")
        for status in PlanStatus.userSettable where status.isArchived {
            XCTAssertTrue(PlanStatus.userSettable.contains { !$0.isArchived },
                          "\(status.rawValue) must be escapable from the same menu")
        }
    }

    /// The list label must name the problem. Older manifests have no title and must keep
    /// falling back to the goal rather than showing a raw id.
    func testDisplayNamePrefersTitleThenGoalThenID() {
        var program = ResearchProgram(id: "p1", goal: "Determine the exact supremum and hence compute c.")
        XCTAssertEqual(program.displayName, "Determine the exact supremum and hence compute c.")
        program.title = "Constrained supremum problem"
        XCTAssertEqual(program.displayName, "Constrained supremum problem")
        program.title = "   "
        XCTAssertEqual(program.displayName, "Determine the exact supremum and hence compute c.")
        program.title = nil
        program.goal = ""
        XCTAssertEqual(program.displayName, "p1")
    }

    func testTitleSurvivesTheManifestRoundTrip() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.saveProgram(ResearchProgram(
            id: "p2", goal: "g", title: "Short name"))
        let loaded = try XCTUnwrap(store.program(id: "p2"))
        XCTAssertEqual(loaded.title, "Short name")
        XCTAssertEqual(loaded.displayName, "Short name")
    }

    func testPlanStatusFailedRoundTripsThroughTheFile() throws {
        var plan = PlanDocument(id: "b1", goal: "g")
        plan.status = .failed
        let reparsed = try PlanDocument.parse(markdown: plan.serialized())
        XCTAssertEqual(reparsed.status, .failed)
    }


    func testFindingStatementIsClampedAtInit() {
        let finding = ProgramFinding(branchPlanID: "b", kind: .evidence,
                                     statement: String(repeating: "x", count: 900))
        XCTAssertEqual(finding.statement.count, ProgramFinding.maxStatementLength)
    }

    func testBranchMemoryRoundTripAndAbsentReadsEmpty() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertEqual(store.loadBranchMemory(planID: "nope"), "")

        let text = "## Goal\nRefute it.\n\n## Key Insights\nδ=2 is the hard case.\n"
        try store.saveBranchMemory(planID: "branch-a", text: text)
        XCTAssertEqual(store.loadBranchMemory(planID: "branch-a"), text)
        XCTAssertEqual(store.loadBranchMemory(planID: "branch-b"), "",
                       "branch memories are isolated from each other")
        XCTAssertTrue(store.branchMemoryURL(planID: "branch-a").lastPathComponent
            .hasSuffix(ProjectStore.branchMemorySuffix))
    }

    func testVirtualProgramWrapsPlanAndIsNeverPersisted() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let plan = PlanDocument(id: "2026-07-24-solo", goal: "One line of attack",
                                tokenBudget: 2_000_000)
        let program = ResearchProgram.virtual(plan: plan)

        XCTAssertTrue(program.isVirtual)
        XCTAssertEqual(program.branches.count, 1)
        XCTAssertEqual(program.branches[0].planID, plan.id)
        XCTAssertFalse(program.branches[0].challengesLeadingAnswer)
        XCTAssertEqual(program.maxConcurrentBranches, 1)
        XCTAssertEqual(program.programTokenBudget, plan.tokenBudget)
        XCTAssertThrowsError(try store.saveProgram(program))
    }


    // MARK: - Verdicts

    func testRejectedFindingsStopCirculating() {
        var program = sampleProgram()
        program.findings.append(ProgramFinding(id: "f2", branchPlanID: "b", kind: .evidence,
                                               statement: "Holds to n=40"))
        program.setVerdict(.rejected, note: "The scan had an off-by-one.", forFinding: "f2")

        XCTAssertEqual(program.circulatingFindings.map(\.id), ["f1"])
        XCTAssertTrue(program.findings.first { $0.id == "f2" }?.isRejected ?? false)
    }

    func testConfirmedFindingKeepsCirculatingWithItsNote() {
        var program = sampleProgram()
        program.setVerdict(.confirmed, note: "Checked by hand.", forFinding: "f1")
        let finding = program.circulatingFindings.first
        XCTAssertEqual(finding?.verdict, .confirmed)
        XCTAssertEqual(finding?.verdictNote, "Checked by hand.")
    }

    func testVerdictSurvivesTheManifestRoundTrip() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        var program = sampleProgram()
        program.setVerdict(.rejected, note: "wrong", forFinding: "f1")
        try store.saveProgram(program)

        let loaded = try XCTUnwrap(store.program(id: program.id))
        XCTAssertEqual(loaded.findings.first?.verdict, .rejected)
        XCTAssertTrue(loaded.circulatingFindings.isEmpty)
    }

    /// Manifests written before verdicts existed must still decode.
    func testFindingWithoutAVerdictDecodesAsUnreviewed() throws {
        let json = """
        {"id":"f9","branchPlanID":"b","kind":"evidence","statement":"s",
         "itemIDs":[],"createdAt":"2026-07-24T10:00:00Z"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let finding = try decoder.decode(ProgramFinding.self, from: Data(json.utf8))
        XCTAssertNil(finding.verdict)
        XCTAssertFalse(finding.isRejected)
        XCTAssertFalse(finding.isConfirmed)
    }

    func testSchedulingOrders() {
        XCTAssertLessThan(CostClass.cheap.order, CostClass.standard.order)
        XCTAssertLessThan(CostClass.standard.order, CostClass.expensive.order)
    }

    func testMaxConcurrentBranchesIsFloored() {
        XCTAssertEqual(ResearchProgram(id: "p", goal: "g", maxConcurrentBranches: 0)
            .maxConcurrentBranches, 1)
    }
}
