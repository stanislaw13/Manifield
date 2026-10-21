import Foundation

public enum CoreError: LocalizedError {
    case invalidFrontmatter(String)
    case notAProject(URL)
    case itemNotFound(String)
    case io(String)
    case sqlite(String)

    public var errorDescription: String? {
        switch self {
        case .invalidFrontmatter(let m): return "Invalid frontmatter: \(m)"
        case .notAProject(let url): return "Not a Manifield project: \(url.path)"
        case .itemNotFound(let id): return "No theory item with id '\(id)'"
        case .io(let m): return m
        case .sqlite(let m): return "Database error: \(m)"
        }
    }
}

public enum ItemType: String, Codable, CaseIterable, Identifiable, Sendable {
    case definition
    case axiom
    case postulate
    case theorem
    case mainTheorem = "main-theorem"
    case lemma
    case proposition
    case corollary
    case claim
    case fact
    case observation
    case conjecture
    case hypothesis
    case problem
    case openProblem = "open-problem"
    case question
    case principle
    case law
    case identity
    case inequality
    case formula
    case algorithm
    case remark
    case example
    case exercise
    /// A standalone illustration. Its image lives in `figures/`, never inside the
    /// markdown — see `TheoryItem.image`. Appended last on purpose: `sortRank` is a
    /// position in `allCases`, so inserting anywhere else renumbers existing types.
    case figure

    public var id: String { rawValue }

    public var displayName: String {
        rawValue.split(separator: "-").map(\.capitalized).joined(separator: " ")
    }

    public var pluralName: String {
        switch self {
        case .corollary: return "Corollaries"
        case .identity: return "Identities"
        case .inequality: return "Inequalities"
        case .hypothesis: return "Hypotheses"
        default: return displayName + "s"
        }
    }

    /// Conventional id prefix, e.g. `lem-degree-bound`.
    public var idPrefix: String {
        switch self {
        case .definition: return "def"
        case .axiom: return "ax"
        case .postulate: return "post"
        case .theorem: return "thm"
        case .mainTheorem: return "mthm"
        case .lemma: return "lem"
        case .proposition: return "prop"
        case .corollary: return "cor"
        case .claim: return "clm"
        case .fact: return "fact"
        case .observation: return "obs"
        case .conjecture: return "conj"
        case .hypothesis: return "hyp"
        case .problem: return "prob"
        case .openProblem: return "oprob"
        case .question: return "qst"
        case .principle: return "prin"
        case .law: return "law"
        case .identity: return "idn"
        case .inequality: return "ineq"
        case .formula: return "form"
        case .algorithm: return "alg"
        case .remark: return "rem"
        case .example: return "ex"
        case .exercise: return "exr"
        case .figure: return "fig"
        }
    }

    /// One-line meaning, shown to import models and in pickers.
    public var summary: String {
        switch self {
        case .definition: return "Introduces a mathematical term, object, property, or notation."
        case .axiom: return "A foundational statement accepted without proof."
        case .postulate: return "Like an axiom, especially in geometry or applied settings."
        case .theorem: return "An important proved result."
        case .mainTheorem: return "The central result of the work."
        case .lemma: return "A supporting result, usually used to prove a theorem."
        case .proposition: return "A proved result, less central than a theorem but independently interesting."
        case .corollary: return "A result that follows relatively directly from another result."
        case .claim: return "A small intermediate assertion, often proved inside a longer proof."
        case .fact: return "A standard, elementary, or immediately verifiable result."
        case .observation: return "A useful consequence or point that requires little argument."
        case .conjecture: return "A statement believed to be true but not yet proved."
        case .hypothesis: return "An assumption, or an unproved proposed statement."
        case .problem: return "A mathematical question presented for solution."
        case .openProblem: return "A problem whose answer is not currently known."
        case .question: return "A question raised by the authors, more tentative than a formal problem."
        case .principle: return "A general rule or broad mathematical phenomenon."
        case .law: return "A fundamental relation, especially in applied mathematics or physics."
        case .identity: return "An equality valid for all admissible values of its variables."
        case .inequality: return "A formally stated bound or comparison."
        case .formula: return "A mathematical relation singled out for later use."
        case .algorithm: return "A finite procedure for a computation or construction."
        case .remark: return "A comment or aside that states mathematical content informally."
        case .example: return "A concrete instance illustrating a definition or result."
        case .exercise: return "A problem posed to the reader, possibly stating a usable result."
        case .figure: return "A standalone illustration — a plot, diagram or drawing — that other items refer to."
        }
    }

    /// Visual/behavioral grouping: 26 types collapse into 6 families so graph shapes,
    /// legends, and status defaults stay comprehensible.
    public enum ShapeFamily: String, CaseIterable, Identifiable, Sendable {
        case definitionLike = "definition-like"
        case mainResult = "main-result"
        case supporting
        case open
        case meta
        case figure

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .definitionLike: return "Definitions & axioms"
            case .mainResult: return "Main results"
            case .supporting: return "Supporting results"
            case .open: return "Open questions"
            case .meta: return "Remarks & examples"
            case .figure: return "Figures"
            }
        }
    }

    public var shapeFamily: ShapeFamily {
        switch self {
        case .definition, .axiom, .postulate:
            return .definitionLike
        case .theorem, .mainTheorem, .corollary:
            return .mainResult
        case .lemma, .proposition, .claim, .fact, .observation,
             .identity, .inequality, .formula, .law, .principle, .algorithm:
            return .supporting
        case .conjecture, .hypothesis, .problem, .openProblem, .question:
            return .open
        case .remark, .example, .exercise:
            return .meta
        case .figure:
            return .figure
        }
    }

    /// Types whose statement is inherently unestablished — they default to
    /// `.conjecture` status instead of `.proofDrafted`/`.source`.
    public var isOpenLike: Bool { shapeFamily == .open }

    /// Position in `allCases`, used as the type tiebreak in display sorting.
    public var sortRank: Int { ItemType.allCases.firstIndex(of: self) ?? 0 }

    /// Types it makes sense to run the prover on.
    public var isProvable: Bool {
        switch shapeFamily {
        case .mainResult, .supporting, .open: return true
        case .definitionLike, .meta, .figure: return false
        }
    }

    /// Types the Organizer may propose when breaking a document into items. A figure
    /// needs image bytes the import pipeline cannot produce yet, so offering the type to
    /// the import model would only yield figures with nothing to show.
    public var isImportable: Bool { self != .figure }

    /// Types whose content is an asset rather than prose — they carry `image` instead of
    /// a `## Statement`, and the trust ladder does not apply to them.
    public var isAsset: Bool { self == .figure }

    /// Common spellings that are not raw values, mapped to their best type.
    private static let aliases: [String: ItemType] = [
        "open-question": .openProblem,
        "notation": .definition,
        "convention": .definition,
        "assumption": .hypothesis,
        "criterion": .theorem,
        "property": .proposition,
        "note": .remark,
        "comment": .remark,
        "def": .definition, "thm": .theorem, "lem": .lemma, "prop": .proposition,
        "cor": .corollary, "conj": .conjecture, "obs": .observation, "alg": .algorithm,
        "rem": .remark, "ex": .example
    ]

    /// Lenient type lookup for import parsing: exact raw value (possibly differently
    /// formatted) → alias table → longest-raw-value substring. `exact` is false when
    /// the match involved interpretation the user should be told about.
    public static func bestMatch(_ raw: String) -> (type: ItemType, exact: Bool)? {
        let normalized = raw.lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: " ", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if let type = ItemType(rawValue: normalized) { return (type, true) }
        if let type = aliases[normalized] { return (type, false) }
        let byLength = allCases.sorted { $0.rawValue.count > $1.rawValue.count }
        if let type = byLength.first(where: { normalized.contains($0.rawValue) }) {
            return (type, false)
        }
        return nil
    }
}

/// Trust level of a statement. The app never claims "correct" — only what evidence exists.
public enum ItemStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case conjecture
    case tested
    case proofDrafted = "proof-drafted"
    case reviewedNoErrors = "reviewed-no-errors"
    case humanApproved = "human-approved"
    /// Established result from imported, cited literature — trusted without re-proving.
    case source
    case formallyVerified = "formally-verified"
    /// Not on the ladder at all: a figure asserts nothing that could be proved, so it
    /// carries no evidence claim. Ranked lowest so breakage propagation never touches it.
    case illustration

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .conjecture: return "Conjecture"
        case .tested: return "Tested"
        case .proofDrafted: return "Proof drafted"
        case .reviewedNoErrors: return "Review found no errors"
        case .humanApproved: return "Human approved"
        case .source: return "Cited literature"
        case .formallyVerified: return "Formally verified"
        case .illustration: return "Illustration"
        }
    }

    /// Single source of truth for status colors, shared by SwiftUI badges and the graph web view.
    public var colorHex: String {
        switch self {
        case .conjecture: return "#9E9E9E"
        case .tested: return "#42A5F5"
        case .proofDrafted: return "#FFB300"
        case .reviewedNoErrors: return "#7CB342"
        case .humanApproved: return "#2E7D32"
        case .source: return "#00838F"
        case .formallyVerified: return "#6A1B9A"
        case .illustration: return "#7C8F78"
        }
    }

    /// Ordering used for downgrades (breakage propagation) and display.
    public var rank: Int {
        switch self {
        case .illustration: return 0
        case .conjecture: return 0
        case .tested: return 1
        case .proofDrafted: return 2
        case .reviewedNoErrors: return 3
        case .humanApproved: return 4
        case .source: return 5
        case .formallyVerified: return 6
        }
    }

    /// Statuses a user may set by hand. `illustration` is not one of them: it belongs to
    /// figures and only to figures, and the type decides it.
    public static var ladder: [ItemStatus] { allCases.filter { $0 != .illustration } }
}

public struct TheoryItem: Identifiable, Equatable, Sendable, Codable {
    public var id: String
    public var type: ItemType
    public var name: String
    public var status: ItemStatus
    public var dependsOn: [String]
    /// Goal items this item claims to resolve. This is intentionally distinct from
    /// `dependsOn`: a proof/result may rely on several lemmas while answering exactly one
    /// research goal, and reversing that relationship loses the meaning of the result once
    /// it is read outside the run that produced it.
    public var resolves: [String]
    public var tags: [String]
    public var source: String?
    /// Section slug this item belongs to; `/` separates subsections,
    /// e.g. `preliminaries` or `weierstrass-theory/division`.
    public var section: String?
    /// Position in the original document, stamped by import (chunkIndex·1000 + position
    /// within the chunk). Nil for hand-created items — they sort after ordered ones.
    public var order: Int?
    /// Project-relative path of a figure's image, e.g. `figures/fig-hat-tile.png`.
    /// Only figures carry one. The markdown body never holds the image itself: the app
    /// synthesizes the `<img>` at render time, so item files stay plain text and no
    /// agent-written markdown can point a page at an arbitrary URL.
    public var image: String?
    /// Project-relative path of the script that produced a figure's image, when it was
    /// generated rather than dropped in — the audit trail, and what a later re-render
    /// would run.
    public var generator: String?
    /// Markdown + LaTeX after the frontmatter (typically `## Statement` and `## Proof`
    /// sections; `## Caption` for figures).
    public var body: String

    public init(
        id: String,
        type: ItemType,
        name: String,
        status: ItemStatus = .conjecture,
        dependsOn: [String] = [],
        resolves: [String] = [],
        tags: [String] = [],
        source: String? = nil,
        section: String? = nil,
        order: Int? = nil,
        image: String? = nil,
        generator: String? = nil,
        body: String = ""
    ) {
        self.id = id
        self.type = type
        self.name = name
        self.status = status
        self.dependsOn = dependsOn
        self.resolves = resolves
        self.tags = tags
        self.source = source
        self.section = section
        self.order = order
        self.image = image
        self.generator = generator
        self.body = body
    }

    private enum CodingKeys: String, CodingKey {
        case id, type, name, status, dependsOn, resolves, tags, source, section, order, body
    }

    /// Lenient because theory items also live inside persisted agent proposals. Older
    /// proposals predate `resolves` and must remain reviewable after this field is added.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        type = try c.decode(ItemType.self, forKey: .type)
        name = try c.decode(String.self, forKey: .name)
        status = try c.decodeIfPresent(ItemStatus.self, forKey: .status)
            ?? (type.isOpenLike ? .conjecture : .proofDrafted)
        dependsOn = try c.decodeIfPresent([String].self, forKey: .dependsOn) ?? []
        resolves = try c.decodeIfPresent([String].self, forKey: .resolves) ?? []
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        source = try c.decodeIfPresent(String.self, forKey: .source)
        section = try c.decodeIfPresent(String.self, forKey: .section)
        order = try c.decodeIfPresent(Int.self, forKey: .order)
        body = try c.decodeIfPresent(String.self, forKey: .body) ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(type, forKey: .type)
        try c.encode(name, forKey: .name)
        try c.encode(status, forKey: .status)
        try c.encode(dependsOn, forKey: .dependsOn)
        try c.encode(resolves, forKey: .resolves)
        try c.encode(tags, forKey: .tags)
        try c.encodeIfPresent(source, forKey: .source)
        try c.encodeIfPresent(section, forKey: .section)
        try c.encodeIfPresent(order, forKey: .order)
        try c.encode(body, forKey: .body)
    }

    public var statement: String? { section(named: "Statement") }
    public var proof: String? { section(named: "Proof") }
    /// A figure's prose: what the picture shows and how to read it.
    public var caption: String? { section(named: "Caption") }

    public var isFigure: Bool { type == .figure }

    /// The default status for a type when a file does not state one.
    public static func defaultStatus(for type: ItemType) -> ItemStatus {
        if type.isAsset { return .illustration }
        return type.isOpenLike ? .conjecture : .proofDrafted
    }

    /// Extracts the content of a `## <name>` section from the body.
    public func section(named name: String) -> String? {
        let lines = body.components(separatedBy: "\n")
        var collected: [String] = []
        var inSection = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("## ") {
                if inSection { break }
                inSection = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                    .caseInsensitiveCompare(name) == .orderedSame
                continue
            }
            if inSection { collected.append(line) }
        }
        let text = collected.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Sanitizes a section path: each `/`-separated segment becomes a kebab-case slug.
    /// Returns nil for effectively empty input.
    public static func sanitizeSection(_ raw: String?) -> String? {
        guard let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let segments = raw.split(separator: "/").map { sanitizeID(String($0)) }
        let joined = segments.prefix(2).joined(separator: "/")  // section/subsection max
        return joined.isEmpty ? nil : joined
    }

    /// Human-readable form of a section slug: "weierstrass-theory/division" → "Weierstrass Theory ▸ Division".
    public static func sectionDisplayName(_ slug: String?) -> String {
        guard let slug, !slug.isEmpty else { return "Unsorted" }
        return slug.split(separator: "/").map { segment in
            segment.split(separator: "-").map { $0.capitalized }.joined(separator: " ")
        }.joined(separator: " ▸ ")
    }

    /// Canonical display order: document position first (unordered items last),
    /// then type declaration order, then id.
    public static func documentOrder(_ a: TheoryItem, _ b: TheoryItem) -> Bool {
        let ao = a.order ?? Int.max
        let bo = b.order ?? Int.max
        if ao != bo { return ao < bo }
        if a.type.sortRank != b.type.sortRank { return a.type.sortRank < b.type.sortRank }
        return a.id < b.id
    }

    /// Natural slug comparison, so "part-2" < "part-10".
    public static func sectionSlugOrder(_ a: String, _ b: String) -> Bool {
        a.compare(b, options: [.numeric, .caseInsensitive]) == .orderedAscending
    }

    /// Groups items by section for display. Item order within each group is preserved
    /// from the input (callers pass store order or search-rank order); sections are
    /// ordered by their smallest item `order`, then natural slug, unsectioned last.
    public static func groupedBySection(
        _ items: [TheoryItem]
    ) -> [(section: String?, items: [TheoryItem])] {
        guard items.contains(where: { $0.section != nil }) else { return [(nil, items)] }
        var groups: [(section: String?, items: [TheoryItem])] = []
        var indexBySection: [String: Int] = [:]
        var unsectioned: [TheoryItem] = []
        for item in items {
            guard let section = item.section else {
                unsectioned.append(item)
                continue
            }
            if let idx = indexBySection[section] {
                groups[idx].items.append(item)
            } else {
                indexBySection[section] = groups.count
                groups.append((section, [item]))
            }
        }
        groups.sort { lhs, rhs in
            let lo = lhs.items.map { $0.order ?? Int.max }.min() ?? Int.max
            let ro = rhs.items.map { $0.order ?? Int.max }.min() ?? Int.max
            if lo != ro { return lo < ro }
            return sectionSlugOrder(lhs.section ?? "", rhs.section ?? "")
        }
        if !unsectioned.isEmpty { groups.append((nil, unsectioned)) }
        return groups
    }

    /// Sanitizes an arbitrary string into a valid item id (lowercase, dashes).
    ///
    /// Capped well under any filesystem's per-component limit (255 bytes on APFS/HFS+) —
    /// counted in UTF-8 bytes, not characters, because this can pass through multi-byte
    /// Unicode letters ("kühn" survives whole) and a character cap alone would not actually
    /// bound the byte length a filesystem enforces. Every call site turns the result into
    /// part of a filename — a plan id, a program id, a theory item id — and every one of them
    /// was written assuming its input was already a short, human-authored title. Nothing
    /// enforced that until a caller fed it a raw, unbounded problem statement instead and the
    /// OS refused to create the file: "the file name ... is invalid", from deep inside a save
    /// call, nowhere near where the actual mistake was. Capping here protects every caller at
    /// once rather than trusting each new one to remember to truncate its own input first.
    public static let sanitizedIDMaxLength = 60

    public static func sanitizeID(_ raw: String) -> String {
        let lowered = raw.lowercased()
        var out = ""
        var outByteCount = 0
        var lastWasDash = true
        for scalar in lowered.unicodeScalars {
            let isAlphanumeric = CharacterSet.alphanumerics.contains(scalar)
            guard isAlphanumeric || !lastWasDash else { continue }
            let addedBytes = isAlphanumeric ? String(scalar).utf8.count : 1
            guard outByteCount + addedBytes <= sanitizedIDMaxLength else { break }
            if isAlphanumeric {
                out.unicodeScalars.append(scalar)
                lastWasDash = false
            } else {
                out.append("-")
                lastWasDash = true
            }
            outByteCount += addedBytes
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "item" : out
    }
}
