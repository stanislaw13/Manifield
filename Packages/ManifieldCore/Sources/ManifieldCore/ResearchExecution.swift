import Foundation

/// A resource ceiling, independent of context compaction or concurrency.
public enum ResearchLimit: Codable, Equatable, Sendable {
    case bounded(Int)
    case unlimited

    public var value: Int? {
        if case .bounded(let value) = self { return max(0, value) }
        return nil
    }
    public var runnerValue: Int { value ?? Int.max }
    public func reached(_ used: Int) -> Bool { value.map { used >= $0 } ?? false }
    public var displayName: String { value.map(String.init) ?? "Unlimited" }
}

public struct ResearchLimits: Codable, Equatable, Sendable {
    public var toolCalls: ResearchLimit
    public var programTokens: ResearchLimit
    public var assignmentTokens: ResearchLimit
    public var elapsedSeconds: ResearchLimit
    public var planRevisions: ResearchLimit
    public var reviewRounds: ResearchLimit

    public init(toolCalls: ResearchLimit = .bounded(24),
                programTokens: ResearchLimit = .bounded(6_000_000),
                assignmentTokens: ResearchLimit = .unlimited,
                elapsedSeconds: ResearchLimit = .bounded(86_400),
                planRevisions: ResearchLimit = .bounded(3),
                reviewRounds: ResearchLimit = .bounded(3)) {
        self.toolCalls = toolCalls
        self.programTokens = programTokens
        self.assignmentTokens = assignmentTokens
        self.elapsedSeconds = elapsedSeconds
        self.planRevisions = planRevisions
        self.reviewRounds = reviewRounds
    }

    public static let unlimited = ResearchLimits(
        toolCalls: .unlimited, programTokens: .unlimited, assignmentTokens: .unlimited,
        elapsedSeconds: .unlimited, planRevisions: .unlimited, reviewRounds: .unlimited)
}

public struct AssignmentReport: Codable, Equatable, Sendable {
    /// The worker's report of achievement; independent evidence review is recorded separately.
    public enum Outcome: String, Codable, Sendable { case achieved, partial, unresolved }
    public enum StopReason: String, Codable, Sendable {
        case completed, review, question, tokenLimit, toolLimit, timeLimit, stopped, interrupted, error
    }
    public var outcome: Outcome
    public var summary: String
    public var unresolved: String
    public var stopReason: StopReason
    public var itemIDs: [String]
    public var findingIDs: [String]
    public var solutionIDs: [String]
    public var challengeIDs: [String]
    public var tokensUsed: Int
    public var createdAt: Date
    /// The worker's one-line statement of the result, written for the interface. Optional:
    /// planned branches and reports saved before it existed fall back to `displayHeadline`.
    public var headline: String?

    public init(outcome: Outcome = .unresolved, summary: String, unresolved: String = "",
                stopReason: StopReason = .completed, itemIDs: [String] = [],
                findingIDs: [String] = [], solutionIDs: [String] = [], challengeIDs: [String] = [],
                tokensUsed: Int = 0, createdAt: Date = Date(), headline: String? = nil) {
        self.outcome = outcome; self.summary = summary; self.unresolved = unresolved
        self.stopReason = stopReason; self.itemIDs = itemIDs; self.findingIDs = findingIDs
        self.solutionIDs = solutionIDs; self.challengeIDs = challengeIDs
        self.tokensUsed = tokensUsed; self.createdAt = createdAt
        self.headline = headline.map { ResearchText.clamp($0, maxLength: ResearchText.headlineLength) }
    }

    public var displayHeadline: String {
        if let headline, !headline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return headline }
        return ResearchText.headline(summary)
    }

    /// Every ID the report cites, in the order a reader checks them.
    public var references: [String] { itemIDs + findingIDs + solutionIDs + challengeIDs }
}

public struct AssignmentMessage: Codable, Equatable, Identifiable, Sendable {
    public var id: String = UUID().uuidString
    public var text: String
    public var evidenceIDs: [String]
    public var createdAt: Date = Date()
    public init(text: String, evidenceIDs: [String] = []) {
        self.text = text; self.evidenceIDs = evidenceIDs
    }
}

public struct ResearchAssignment: Codable, Equatable, Identifiable, Sendable {
    public enum Mode: String, Codable, CaseIterable, Sendable { case direct, planned }
    public enum Status: String, Codable, Sendable {
        case queued, running, paused, finished, stopped, errored
    }
    public var id: String
    public var operationID: String
    public var programID: String
    public var targetRevisionID: String
    public var mode: Mode
    public var objective: String
    public var constraints: [String]
    public var itemIDs: [String]
    public var evidenceIDs: [String]
    public var parentAssignmentID: String?
    public var planID: String?
    public var modelTier: String?
    public var tokenLimit: ResearchLimit
    public var status: Status
    public var revision: Int
    public var messages: [AssignmentMessage]
    public var deliveredMessageIDs: [String]?
    public var reports: [AssignmentReport]
    public var createdAt: Date
    /// A few words naming the work, supplied by the director at dispatch purely for the
    /// interface. The objective stays the authoritative instruction the worker receives.
    public var title: String?

    public init(id: String = UUID().uuidString, operationID: String, programID: String,
                targetRevisionID: String, mode: Mode, objective: String, title: String? = nil,
                constraints: [String] = [], itemIDs: [String] = [], evidenceIDs: [String] = [],
                parentAssignmentID: String? = nil, modelTier: String? = nil,
                tokenLimit: ResearchLimit = .unlimited) {
        self.id = id; self.operationID = operationID; self.programID = programID
        self.targetRevisionID = targetRevisionID; self.mode = mode; self.objective = objective
        self.title = title.map { ResearchText.clamp($0, maxLength: ResearchText.titleLength) }
            .flatMap { $0.isEmpty ? nil : $0 }
        self.constraints = constraints; self.itemIDs = itemIDs; self.evidenceIDs = evidenceIDs
        self.parentAssignmentID = parentAssignmentID; self.modelTier = modelTier
        self.tokenLimit = tokenLimit; self.status = .queued; self.revision = 1
        self.messages = []; self.reports = []; self.createdAt = Date()
        self.deliveredMessageIDs = []
        self.planID = mode == .planned ? "\(programID)-assignment-\(id.lowercased())" : nil
    }
    public var latestReport: AssignmentReport? { reports.last }

    /// What to call this assignment wherever it is listed. Assignments dispatched before
    /// titles existed get the objective's first sentence rather than the whole instruction.
    public var displayTitle: String {
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return title }
        return ResearchText.headline(objective, maxLength: ResearchText.titleLength)
    }
}

/// Short, list-sized projections of generated research text. Reports, objectives and
/// challenges are written as paragraphs for the next agent; a list row needs one line.
public enum ResearchText {
    public static let titleLength = 80
    public static let headlineLength = 140

    /// The first sentence of `text`, clamped to `maxLength`. Never splits inside `$…$`
    /// math, and skips the periods of common abbreviations ("e.g.", "Thm.").
    public static func headline(_ text: String, maxLength: Int = headlineLength) -> String {
        let firstLine = text.split(whereSeparator: \.isNewline)
            .map { stripMarkdownPrefix(String($0)) }
            .first { !$0.isEmpty } ?? ""
        return clamp(firstSentence(of: firstLine), maxLength: maxLength)
    }

    /// Trims and shortens at a word boundary outside math, marking the cut with an ellipsis.
    public static func clamp(_ text: String, maxLength: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        guard trimmed.count > maxLength else { return trimmed }
        let characters = Array(trimmed)
        var inMath = false
        var lastSafeBreak = 0
        for index in 0..<maxLength {
            let character = characters[index]
            if character == "$", index == 0 || characters[index - 1] != "\\" { inMath.toggle() }
            if character == " ", !inMath { lastSafeBreak = index }
        }
        let cut = lastSafeBreak > maxLength / 2 ? lastSafeBreak : unmathedPrefixLength(characters, limit: maxLength)
        return String(characters[0..<cut]).trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: ",;:")) + "…"
    }

    private static let abbreviations: Set<String> = [
        "e.g", "i.e", "cf", "vs", "resp", "etc", "al", "approx", "thm", "lem", "prop", "def",
        "cor", "eq", "fig", "sec", "ch",
    ]

    private static func firstSentence(of line: String) -> String {
        let characters = Array(line)
        var inMath = false
        var wordStart = 0
        for index in characters.indices {
            let character = characters[index]
            if character == "$", index == 0 || characters[index - 1] != "\\" { inMath.toggle() }
            if character == " " { wordStart = index + 1 }
            guard !inMath, ".!?".contains(character) else { continue }
            let atBoundary = index + 1 == characters.count || characters[index + 1] == " "
            guard atBoundary, index >= 12 else { continue }
            let word = String(characters[wordStart..<index]).lowercased()
            // Single letters are not skipped: mathematics ends sentences on variables ("in U.").
            if character == ".", abbreviations.contains(word) { continue }
            return String(characters[0...index])
        }
        return line
    }

    /// A hard cut that backs out of an open `$…$` span, so the result never leaves math unbalanced.
    private static func unmathedPrefixLength(_ characters: [Character], limit: Int) -> Int {
        var inMath = false
        var mathStart = 0
        for index in 0..<limit where characters[index] == "$" && (index == 0 || characters[index - 1] != "\\") {
            inMath.toggle()
            if inMath { mathStart = index }
        }
        return inMath ? mathStart : limit
    }

    private static func stripMarkdownPrefix(_ line: String) -> String {
        var result = line.trimmingCharacters(in: .whitespaces)
        while let first = result.first, "#>*-".contains(first) {
            result.removeFirst()
            result = result.trimmingCharacters(in: .whitespaces)
        }
        return result.replacingOccurrences(of: "**", with: "")
    }
}

extension ResearchProgram {
    /// The assignment a research record belongs to. Planned work files under its plan ID.
    public func assignment(id: String) -> ResearchAssignment? {
        execution?.assignments.first { $0.id == id || $0.planID == id }
    }
}

public struct ResearchProgramEvent: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case dispatched, started, reported, evidence, reviewed, guidance, stopped, targetChanged, directorPaused
    }
    public var id: Int { sequence }
    public var sequence: Int
    public var kind: Kind
    public var assignmentID: String?
    public var targetRevisionID: String
    public var summary: String
    public var references: [String]
    public var operationID: String?
    public var createdAt: Date
    public init(sequence: Int, kind: Kind, assignmentID: String? = nil,
                targetRevisionID: String, summary: String, references: [String] = [],
                operationID: String? = nil) {
        self.sequence = sequence; self.kind = kind; self.assignmentID = assignmentID
        self.targetRevisionID = targetRevisionID; self.summary = summary
        self.references = references; self.operationID = operationID; self.createdAt = Date()
    }
}

public struct ProgramResolution: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case answered, invalidTarget, unresolved }
    public var kind: Kind
    public var targetRevisionID: String
    public var evidenceIDs: [String]
    public var explanation: String
    public var createdAt: Date = Date()
    public init(kind: Kind, targetRevisionID: String, evidenceIDs: [String], explanation: String) {
        self.kind = kind; self.targetRevisionID = targetRevisionID
        self.evidenceIDs = evidenceIDs; self.explanation = explanation
    }
}

/// New programs use this state. Old manifests remain readable without inventing assignments.
public struct ResearchExecution: Codable, Equatable, Sendable {
    public var version: Int = 1
    public var limits: ResearchLimits
    public var assignments: [ResearchAssignment] = []
    public var events: [ResearchProgramEvent] = []
    public var resolution: ProgramResolution?
    public var startedAt: Date?
    public init(limits: ResearchLimits = .init()) { self.limits = limits }

    public mutating func append(_ kind: ResearchProgramEvent.Kind, target: String,
                                assignmentID: String? = nil, summary: String,
                                references: [String] = [], operationID: String? = nil) {
        events.append(.init(sequence: (events.last?.sequence ?? 0) + 1, kind: kind,
                            assignmentID: assignmentID, targetRevisionID: target,
                            summary: summary, references: references, operationID: operationID))
    }
}
