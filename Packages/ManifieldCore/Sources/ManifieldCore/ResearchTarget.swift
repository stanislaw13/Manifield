import CryptoKit
import Foundation

/// The exact formalized goal a research program is answering.
///
/// The original user prompt lives on `ResearchProgram.goal`. A revision instead preserves the
/// selected goal item, its dependency closure, and the notation/macros needed to read it as they
/// existed when the revision was adopted. Agents work against this snapshot. Editing the live
/// library later cannot silently change what an earlier claim, finding, or review meant.
public struct ResearchTargetRevision: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var parentRevisionID: String?
    public var requestText: String
    public var requestSHA256: String
    /// A target may be any natural theory item type: conjecture, question, algorithm, etc.
    public var libraryItemID: String?
    public var libraryItemType: ItemType?
    public var libraryItemName: String?
    /// Verbatim UTF-8 file bytes, not a reserialization of the parsed item.
    public var libraryItemData: Data?
    public var libraryItemSHA256: String?
    /// Raw snapshots of the local items the goal depends on, recursively. Source-qualified
    /// dependencies remain named in the goal item but cannot be snapshotted by this store.
    public var dependencyItemData: [String: Data]
    public var dependencyItemSHA256: [String: String]
    public var notationSnapshot: String
    public var macrosSnapshot: String
    public var proposedByChallengeID: String?
    public var changeNote: String?
    public var createdAt: Date

    // MARK: - The audited reading

    /// Exact statement, quantifiers and conventions, as normalized before the run. Empty until
    /// a drafter has read this revision — `ResearchProgram.contract` treats an empty statement
    /// as "not yet drafted", exactly as `SuccessContract.validationProblems` always has.
    public var statement: String = ""
    /// Legacy: every form a complete answer could take, kept only for programs that predate
    /// statement-only targets. New drafting leaves this empty.
    public var completeAnswers: [SuccessContract.CompleteAnswer] = []
    /// Legacy rationale for `completeAnswers`. New targets leave this empty.
    public var completenessRationale: String = ""
    /// Legacy problem-specific exclusions. New targets leave this empty.
    public var notCounted: [String] = []
    /// Reading adopted during formalization when the request admitted materially different readings.
    public var recommendedReading: String = ""
    /// Readings the statement audit found materially different.
    public var ambiguities: [String] = []
    /// When a human approved this revision's reading. Nil means research proceeding against
    /// it is unreviewed, which a verdict must say out loud rather than silently inherit.
    public var reviewedAt: Date?

    public init(
        id: String = UUID().uuidString,
        parentRevisionID: String? = nil,
        requestText: String,
        libraryItemID: String? = nil,
        libraryItemType: ItemType? = nil,
        libraryItemName: String? = nil,
        libraryItemData: Data? = nil,
        dependencyItemData: [String: Data] = [:],
        notationSnapshot: String = "",
        macrosSnapshot: String = "",
        proposedByChallengeID: String? = nil,
        changeNote: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.parentRevisionID = parentRevisionID
        self.requestText = requestText
        self.requestSHA256 = Self.sha256(Data(requestText.utf8))
        self.libraryItemID = libraryItemID
        self.libraryItemType = libraryItemType
        self.libraryItemName = libraryItemName
        self.libraryItemData = libraryItemData
        self.libraryItemSHA256 = libraryItemData.map(Self.sha256)
        self.dependencyItemData = dependencyItemData
        self.dependencyItemSHA256 = dependencyItemData.mapValues(Self.sha256)
        self.notationSnapshot = notationSnapshot
        self.macrosSnapshot = macrosSnapshot
        self.proposedByChallengeID = proposedByChallengeID
        self.changeNote = changeNote
        self.createdAt = createdAt
    }

    /// Lenient decode: every field below `createdAt` was added after revisions already existed
    /// on disk, so each is read with a default rather than failing manifests that predate it.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        parentRevisionID = try c.decodeIfPresent(String.self, forKey: .parentRevisionID)
        requestText = try c.decode(String.self, forKey: .requestText)
        requestSHA256 = try c.decodeIfPresent(String.self, forKey: .requestSHA256)
            ?? Self.sha256(Data(requestText.utf8))
        libraryItemID = try c.decodeIfPresent(String.self, forKey: .libraryItemID)
        libraryItemType = try c.decodeIfPresent(ItemType.self, forKey: .libraryItemType)
        libraryItemName = try c.decodeIfPresent(String.self, forKey: .libraryItemName)
        libraryItemData = try c.decodeIfPresent(Data.self, forKey: .libraryItemData)
        libraryItemSHA256 = try c.decodeIfPresent(String.self, forKey: .libraryItemSHA256)
            ?? libraryItemData.map(Self.sha256)
        dependencyItemData = try c.decodeIfPresent(
            [String: Data].self, forKey: .dependencyItemData) ?? [:]
        dependencyItemSHA256 = try c.decodeIfPresent(
            [String: String].self, forKey: .dependencyItemSHA256)
            ?? dependencyItemData.mapValues(Self.sha256)
        notationSnapshot = try c.decodeIfPresent(String.self, forKey: .notationSnapshot) ?? ""
        macrosSnapshot = try c.decodeIfPresent(String.self, forKey: .macrosSnapshot) ?? ""
        proposedByChallengeID = try c.decodeIfPresent(String.self, forKey: .proposedByChallengeID)
        changeNote = try c.decodeIfPresent(String.self, forKey: .changeNote)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        statement = try c.decodeIfPresent(String.self, forKey: .statement) ?? ""
        completeAnswers = try c.decodeIfPresent(
            [SuccessContract.CompleteAnswer].self, forKey: .completeAnswers) ?? []
        completenessRationale =
            try c.decodeIfPresent(String.self, forKey: .completenessRationale) ?? ""
        notCounted = try c.decodeIfPresent([String].self, forKey: .notCounted) ?? []
        recommendedReading = try c.decodeIfPresent(String.self, forKey: .recommendedReading) ?? ""
        ambiguities = try c.decodeIfPresent([String].self, forKey: .ambiguities) ?? []
        reviewedAt = try c.decodeIfPresent(Date.self, forKey: .reviewedAt)
    }

    public var isReviewed: Bool { reviewedAt != nil }

    /// Compatibility target for manifests created before explicit revisions existed.
    public static func legacy(requestText: String) -> Self {
        let digest = sha256(Data(requestText.utf8))
        return Self(id: "legacy-\(digest.prefix(20))", requestText: requestText,
                    changeNote: "Synthesized from a pre-revision program manifest.",
                    createdAt: Date(timeIntervalSince1970: 0))
    }

    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public func matchesLiveItemData(_ data: Data) -> Bool {
        guard let libraryItemSHA256 else { return libraryItemData == nil }
        return Self.sha256(data) == libraryItemSHA256
    }

    public var frozenLibraryItem: TheoryItem? {
        guard let libraryItemData,
              let markdown = String(data: libraryItemData, encoding: .utf8) else { return nil }
        return try? TheoryItem.parse(markdown: markdown)
    }

    /// Returns the protected field an ordinary edit tried to change. Proof, Evidence, status,
    /// tags, source, section and `resolves` remain editable; the definition of the goal does
    /// not. A governed problem challenge advances the program to a new revision instead.
    public func protectedGoalChange(in proposed: TheoryItem) -> String? {
        guard proposed.id == libraryItemID, let frozen = frozenLibraryItem else { return nil }
        if proposed.type != frozen.type { return "type" }
        if proposed.name != frozen.name { return "name" }
        if proposed.statement != frozen.statement { return "Statement" }
        return nil
    }
}

/// A branch's freeform claim that the fixed research-goal Statement contains a real defect.
///
/// This deliberately has no outcome taxonomy. The mathematical description is the claim.
/// The only machine-level distinction is procedural: which independent checks have run and
/// whether the director has governed an accepted change.
public struct ProblemChallenge: Codable, Equatable, Sendable, Identifiable {
    public enum Status: String, Codable, CaseIterable, Sendable {
        case filed
        case mathematicalReview = "mathematical_review"
        case mathematicalRejected = "mathematical_rejected"
        case scopeReview = "scope_review"
        case scopeRejected = "scope_rejected"
        case accepted
        case governed

        public var isRejected: Bool {
            self == .mathematicalRejected || self == .scopeRejected
        }
    }

    public struct ReviewRuling: Codable, Equatable, Sendable {
        public enum TargetDisposition: String, Codable, Sendable {
            case fullInvalidity, partialInvalidity, needsClarification
        }
        public var accepted: Bool
        public var note: String
        /// Scope review's explicit coverage. Older rulings have no authority to close a new execution.
        public var targetDisposition: TargetDisposition?

        public init(accepted: Bool, note: String, targetDisposition: TargetDisposition? = nil) {
            self.accepted = accepted
            self.note = note
            self.targetDisposition = targetDisposition
        }
    }

    /// The director's response after both independent checks accept the challenge.
    /// Arrays are explicit because an accepted challenge may invalidate one branch while
    /// leaving another part of a composite request unresolved and worth continuing.
    public struct Governance: Codable, Equatable, Sendable {
        public var applyRevision: Bool
        public var replacementRequest: String?
        public var stopBranchPlanIDs: [String]
        public var replanBranchPlanIDs: [String]
        public var continueBranchPlanIDs: [String]
        public var openNewPortfolio: Bool
        public var rationale: String
        public var newTargetRevisionID: String?
        public var decidedAt: Date

        public init(
            applyRevision: Bool,
            replacementRequest: String? = nil,
            stopBranchPlanIDs: [String] = [],
            replanBranchPlanIDs: [String] = [],
            continueBranchPlanIDs: [String] = [],
            openNewPortfolio: Bool = false,
            rationale: String,
            newTargetRevisionID: String? = nil,
            decidedAt: Date = Date()
        ) {
            self.applyRevision = applyRevision
            self.replacementRequest = replacementRequest
            self.stopBranchPlanIDs = stopBranchPlanIDs
            self.replanBranchPlanIDs = replanBranchPlanIDs
            self.continueBranchPlanIDs = continueBranchPlanIDs
            self.openNewPortfolio = openNewPortfolio
            self.rationale = rationale
            self.newTargetRevisionID = newTargetRevisionID
            self.decidedAt = decidedAt
        }
    }

    public static let maxDescriptionLength = 4_000
    public static let maxReplacementLength = 4_000

    public var id: String
    public var branchPlanID: String
    public var targetRevisionID: String
    /// What is wrong, the evidence, and why it makes the request impossible as written.
    public var description: String
    /// Optional minimal corrected request. Omission is valid when the defect is established
    /// but the right repair is not yet known.
    public var proposedReplacementRequest: String?
    /// Optional newly-created item to use as the target if a revision is adopted.
    public var proposedTargetItemID: String?
    public var proposedTargetItemType: ItemType?
    public var proposedTargetItemData: Data?
    public var proposedTargetItemSHA256: String?
    public var evidenceItemIDs: [String]
    /// Exact raw bytes cited when the challenge was filed. Reviewers use these rather than
    /// the mutable live library; the digest map makes their identity human-inspectable.
    public var evidenceItemData: [String: Data]?
    public var evidenceItemSnapshots: [String: String]
    public var mathematicalRuling: ReviewRuling?
    public var scopeRuling: ReviewRuling?
    public var governance: Governance?
    public var status: Status
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        branchPlanID: String,
        targetRevisionID: String,
        description: String,
        proposedReplacementRequest: String? = nil,
        proposedTargetItemID: String? = nil,
        proposedTargetItemType: ItemType? = nil,
        proposedTargetItemData: Data? = nil,
        evidenceItemIDs: [String] = [],
        evidenceItemData: [String: Data] = [:],
        evidenceItemSnapshots: [String: String] = [:],
        mathematicalRuling: ReviewRuling? = nil,
        scopeRuling: ReviewRuling? = nil,
        governance: Governance? = nil,
        status: Status = .filed,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.branchPlanID = branchPlanID
        self.targetRevisionID = targetRevisionID
        self.description = String(description.prefix(Self.maxDescriptionLength))
        self.proposedReplacementRequest = proposedReplacementRequest.map {
            String($0.prefix(Self.maxReplacementLength))
        }
        self.proposedTargetItemID = proposedTargetItemID
        self.proposedTargetItemType = proposedTargetItemType
        self.proposedTargetItemData = proposedTargetItemData
        self.proposedTargetItemSHA256 = proposedTargetItemData.map(ResearchTargetRevision.sha256)
        self.evidenceItemIDs = evidenceItemIDs
        self.evidenceItemData = evidenceItemData.isEmpty ? nil : evidenceItemData
        self.evidenceItemSnapshots = evidenceItemSnapshots
        self.mathematicalRuling = mathematicalRuling
        self.scopeRuling = scopeRuling
        self.governance = governance
        self.status = status
        self.createdAt = createdAt
    }
}

public extension ProjectStore {
    /// The actual bytes on disk. Hashing `TheoryItem.serialized()` would miss external edits in
    /// formatting/frontmatter and would not be a hash of the version the agent really saw.
    func rawTheoryItemData(id: String) throws -> Data {
        guard item(id: id) != nil else { throw CoreError.itemNotFound(id) }
        return try Data(contentsOf: theoryURL.appendingPathComponent("\(id).md"))
    }

    func makeResearchTargetRevision(
        requestText: String,
        libraryItemID: String? = nil,
        parentRevisionID: String? = nil,
        proposedByChallengeID: String? = nil,
        changeNote: String? = nil
    ) throws -> ResearchTargetRevision {
        guard let libraryItemID else {
            return ResearchTargetRevision(
                parentRevisionID: parentRevisionID, requestText: requestText,
                proposedByChallengeID: proposedByChallengeID, changeNote: changeNote)
        }
        guard let item = item(id: libraryItemID) else { throw CoreError.itemNotFound(libraryItemID) }
        var dependencyData: [String: Data] = [:]
        var visited: Set<String> = [item.id]
        var queue = item.dependsOn
        while let id = queue.first {
            queue.removeFirst()
            guard !visited.contains(id) else { continue }
            visited.insert(id)
            // A source-qualified id belongs to a different store. It remains explicit in the
            // snapshotted frontmatter and attached-source access can resolve it later.
            guard let dependency = self.item(id: id) else { continue }
            dependencyData[id] = try rawTheoryItemData(id: id)
            queue.append(contentsOf: dependency.dependsOn)
        }
        return ResearchTargetRevision(
            parentRevisionID: parentRevisionID,
            requestText: requestText,
            libraryItemID: libraryItemID,
            libraryItemType: item.type,
            libraryItemName: item.name,
            libraryItemData: try rawTheoryItemData(id: libraryItemID),
            dependencyItemData: dependencyData,
            notationSnapshot: notation,
            macrosSnapshot: macros,
            proposedByChallengeID: proposedByChallengeID,
            changeNote: changeNote)
    }
}
