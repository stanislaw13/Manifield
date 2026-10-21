import XCTest
@testable import ManifieldCore

final class ResearchTargetTests: XCTestCase {

    private func makeStore() throws -> (ProjectStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("research-target-tests-\(UUID().uuidString)")
        return (try ProjectStore.create(at: dir, name: "Targets"), dir)
    }

    func testTargetPinsExactRawBytesAndNaturalItemType() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let item = TheoryItem(
            id: "qst-classify-groups", type: .question, name: "Classify the groups",
            body: "## Statement\nClassify all groups satisfying C.")
        try store.save(item)

        // Deliberately change byte-level formatting without changing the parsed item. The
        // revision must hash the file that was actually pinned, not a normalized reserialization.
        let url = store.theoryURL.appendingPathComponent("\(item.id).md")
        var raw = try Data(contentsOf: url)
        raw.append(Data("\n<!-- byte-level sentinel -->\n".utf8))
        try raw.write(to: url)

        let revision = try store.makeResearchTargetRevision(
            requestText: "Classify all groups satisfying C.", libraryItemID: item.id)

        XCTAssertEqual(revision.libraryItemID, item.id)
        XCTAssertEqual(revision.libraryItemType, .question,
                       "the recognizer's natural type must not be coerced to Problem")
        XCTAssertEqual(revision.libraryItemData, raw)
        XCTAssertEqual(revision.libraryItemSHA256, ResearchTargetRevision.sha256(raw))
        XCTAssertTrue(revision.matchesLiveItemData(raw))
        XCTAssertFalse(revision.matchesLiveItemData(Data(item.serialized().utf8)))
    }

    func testTargetFreezesRecursiveDependenciesNotationAndMacros() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let base = TheoryItem(
            id: "def-base", type: .definition, name: "Base object",
            body: "## Statement\nA base object is fixed.")
        let local = TheoryItem(
            id: "lem-local", type: .lemma, name: "Local lemma",
            dependsOn: [base.id], body: "## Statement\nEvery base object is local.")
        let goal = TheoryItem(
            id: "prob-goal", type: .problem, name: "Classify local objects",
            dependsOn: [local.id, "source-book::def-external"],
            body: "## Statement\nClassify every local object.")
        try store.save(base)
        try store.save(local)
        try store.save(goal)
        try store.saveNotation("Let $B$ denote the base object.\n")
        try store.saveMacros("\\newcommand{\\Base}{B}\n")

        let revision = try store.makeResearchTargetRevision(
            requestText: try XCTUnwrap(goal.statement), libraryItemID: goal.id)

        XCTAssertEqual(revision.libraryItemName, goal.name)
        XCTAssertEqual(Set(revision.dependencyItemData.keys), [base.id, local.id])
        XCTAssertEqual(
            revision.dependencyItemSHA256[base.id],
            revision.dependencyItemData[base.id].map(ResearchTargetRevision.sha256))
        XCTAssertEqual(revision.notationSnapshot, "Let $B$ denote the base object.\n")
        XCTAssertEqual(revision.macrosSnapshot, "\\newcommand{\\Base}{B}\n")

        // Later live-library edits cannot change what this research revision meant.
        var changedBase = base
        changedBase.body = "## Statement\nA different definition."
        try store.save(changedBase)
        XCTAssertNotEqual(try store.rawTheoryItemData(id: base.id), revision.dependencyItemData[base.id])
    }

    func testProtectedGoalAllowsResearchSectionsButRejectsRedefinition() {
        let frozen = TheoryItem(
            id: "prob-goal", type: .problem, name: "Classify objects",
            status: .conjecture, dependsOn: ["def-object"],
            body: "## Statement\nClassify all objects satisfying C.")
        let revision = ResearchTargetRevision(
            requestText: "Classify all objects satisfying C.",
            libraryItemID: frozen.id, libraryItemType: frozen.type,
            libraryItemName: frozen.name, libraryItemData: Data(frozen.serialized().utf8))

        var researchUpdate = frozen
        researchUpdate.status = .proofDrafted
        researchUpdate.tags = ["active"]
        researchUpdate.dependsOn.append("lem-classification")
        researchUpdate.body += "\n\n## Evidence\nChecked all objects of size at most 10.\n\n## Proof\nDraft."
        XCTAssertNil(revision.protectedGoalChange(in: researchUpdate))

        var changedStatement = researchUpdate
        changedStatement.body = "## Statement\nClassify only finite objects satisfying C."
        XCTAssertEqual(revision.protectedGoalChange(in: changedStatement), "Statement")

        var changedName = researchUpdate
        changedName.name = "A narrower classification"
        XCTAssertEqual(revision.protectedGoalChange(in: changedName), "name")

        var changedType = researchUpdate
        changedType.type = .question
        XCTAssertEqual(revision.protectedGoalChange(in: changedType), "type")
    }

    func testLegacyManifestSynthesizesDeterministicTargetRevision() throws {
        let encoded = try JSONEncoder().encode(ResearchProgram(id: "legacy-p", goal: "Compute Ω."))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        json.removeValue(forKey: "targetRevisions")
        json.removeValue(forKey: "activeTargetRevisionID")
        json.removeValue(forKey: "challenges")
        let legacy = try JSONSerialization.data(withJSONObject: json)

        let first = try JSONDecoder().decode(ResearchProgram.self, from: legacy)
        let second = try JSONDecoder().decode(ResearchProgram.self, from: legacy)

        XCTAssertEqual(first.researchRequest, "Compute Ω.")
        XCTAssertEqual(first.targetRevisions.count, 1)
        XCTAssertEqual(first.activeTargetRevisionID, second.activeTargetRevisionID)
        XCTAssertTrue(first.activeTargetRevisionID.hasPrefix("legacy-"))
        XCTAssertTrue(first.challenges.isEmpty)
    }

    func testAppendingRevisionPreservesHistoryAndAdvancesOnlyCurrentRequest() {
        let initial = ResearchTargetRevision(
            id: "r1", requestText: "Classify all G satisfying C.",
            libraryItemID: "qst-c", libraryItemType: .question,
            libraryItemData: Data("original bytes".utf8))
        var program = ResearchProgram(
            id: "p", goal: "Classify all G satisfying C.",
            targetRevisions: [initial], activeTargetRevisionID: initial.id)
        let revised = ResearchTargetRevision(
            id: "r2", parentRevisionID: initial.id,
            requestText: "Classify all finite G satisfying C.",
            proposedByChallengeID: "challenge-1")

        program.appendTargetRevision(revised)

        XCTAssertEqual(program.goal, "Classify all G satisfying C.",
                       "the original user request remains compatibility/history data")
        XCTAssertEqual(program.researchRequest, revised.requestText)
        XCTAssertEqual(program.targetRevisions.map(\.id), ["r1", "r2"])
        XCTAssertEqual(program.targetRevisions.first?.libraryItemData,
                       Data("original bytes".utf8))
        XCTAssertEqual(program.activeTargetRevision.parentRevisionID, "r1")
    }

    func testAcceptedChallengeCanLeaveOtherResearchUnresolved() {
        var challenge = ProblemChallenge(
            id: "c1", branchPlanID: "classification-branch", targetRevisionID: "r1",
            description: "The requested class includes an undefined parameter n.",
            proposedReplacementRequest: "Classify all groups for each specified n.")
        challenge.mathematicalRuling = .init(accepted: true, note: "n has no quantifier")
        challenge.scopeRuling = .init(accepted: true, note: "adding the quantifier is necessary")
        challenge.status = .accepted
        challenge.governance = .init(
            applyRevision: true,
            replacementRequest: challenge.proposedReplacementRequest,
            stopBranchPlanIDs: ["invalid-object-branch"],
            replanBranchPlanIDs: ["classification-branch"],
            continueBranchPlanIDs: [], openNewPortfolio: true,
            rationale: "The corrected classification request is still unresolved.")

        XCTAssertEqual(challenge.status, .accepted)
        XCTAssertTrue(challenge.governance?.openNewPortfolio == true)
        XCTAssertEqual(challenge.governance?.replanBranchPlanIDs, ["classification-branch"])
    }
}
