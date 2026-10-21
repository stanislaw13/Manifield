import XCTest
import ManifieldCore
import ManifieldSandbox
@testable import ManifieldAgents

final class AnthropicParserTests: XCTestCase {

    func testTextAndToolUseStream() throws {
        let parser = AnthropicStreamParser()
        var events: [LLMEvent] = []

        let lines = [
            #"{"type":"message_start","message":{"usage":{"input_tokens":42}}}"#,
            #"{"type":"content_block_start","index":0,"content_block":{"type":"text"}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Let me "}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"search."}}"#,
            #"{"type":"content_block_stop","index":0}"#,
            #"{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"tu_1","name":"search_theory"}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"query\":"}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"\"domination\"}"}}"#,
            #"{"type":"content_block_stop","index":1}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":17}}"#,
            #"{"type":"message_stop"}"#
        ]
        for line in lines {
            events.append(contentsOf: try parser.handle(dataLine: line))
        }

        XCTAssertTrue(events.contains(.textDelta("Let me ")))
        XCTAssertTrue(events.contains(.toolUseStarted(id: "tu_1", name: "search_theory")))
        XCTAssertTrue(events.contains(.toolUseFinished(
            id: "tu_1", name: "search_theory", inputJSON: #"{"query":"domination"}"#)))
        XCTAssertTrue(events.contains(.usage(input: 42, output: 17)))
        XCTAssertTrue(events.contains(.finished(.toolUse)))
    }

    func testErrorEventThrows() {
        let parser = AnthropicStreamParser()
        XCTAssertThrowsError(try parser.handle(
            dataLine: #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#))
    }
}

final class OpenAIParserTests: XCTestCase {

    func testToolCallAccumulation() {
        let parser = OpenAIStreamParser()
        var events: [LLMEvent] = []

        let lines = [
            #"{"choices":[{"delta":{"content":"Checking"}}]}"#,
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"search_theory","arguments":""}}]}}]}"#,
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"que"}}]}}]}"#,
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"ry\":\"ore\"}"}}]}}]}"#,
            #"{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#,
            #"{"choices":[],"usage":{"prompt_tokens":10,"completion_tokens":5}}"#
        ]
        for line in lines {
            events.append(contentsOf: parser.handle(dataLine: line))
        }
        events.append(contentsOf: parser.flush())

        XCTAssertTrue(events.contains(.textDelta("Checking")))
        XCTAssertTrue(events.contains(.toolUseStarted(id: "call_1", name: "search_theory")))
        XCTAssertTrue(events.contains(.toolUseFinished(
            id: "call_1", name: "search_theory", inputJSON: #"{"query":"ore"}"#)))
        XCTAssertTrue(events.contains(.usage(input: 10, output: 5)))
        XCTAssertTrue(events.contains(.finished(.toolUse)))
    }

    func testPlainStop() {
        let parser = OpenAIStreamParser()
        var events = parser.handle(dataLine: #"{"choices":[{"delta":{"content":"Done."},"finish_reason":"stop"}]}"#)
        events.append(contentsOf: parser.flush())
        XCTAssertTrue(events.contains(.finished(.endTurn)))
    }
}

// MARK: - Agent loop with a scripted provider

private final class MockProvider: LLMProvider {
    var description: String { "mock" }
    var scripts: [[LLMEvent]]
    private(set) var requests: [LLMRequest] = []

    init(scripts: [[LLMEvent]]) {
        self.scripts = scripts
    }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        requests.append(request)
        let events = scripts.isEmpty ? [LLMEvent.finished(.endTurn)] : scripts.removeFirst()
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
}

private struct EchoTool: AgentTool {
    var spec: ToolSpec {
        ToolSpec(name: "echo", description: "echoes",
                 inputSchemaJSON: #"{"type":"object","properties":{"query":{"type":"string"}}}"#)
    }
    func execute(inputJSON: String) async throws -> String {
        "echo:" + ((jsonObject(inputJSON)["query"] as? String) ?? "?")
    }
}

final class AgentLoopTests: XCTestCase {

    func testToolRoundTrip() async throws {
        let provider = MockProvider(scripts: [
            [
                .textDelta("Let me check. "),
                .toolUseFinished(id: "t1", name: "echo", inputJSON: #"{"query":"hi"}"#),
                .finished(.toolUse)
            ],
            [
                .textDelta("The answer is 42."),
                .finished(.endTurn)
            ]
        ])
        let loop = AgentLoop(provider: provider)
        let result = try await loop.run(
            config: AgentConfig(systemPrompt: "sys", tools: [EchoTool()]),
            history: [.user("question")]
        )

        XCTAssertEqual(result.finalText, "The answer is 42.")
        // user q, assistant(text+tool_use), user(tool_result), assistant(final)
        XCTAssertEqual(result.transcript.count, 4)
        if case .toolResult(let id, let content, let isError) = result.transcript[2].blocks[0] {
            XCTAssertEqual(id, "t1")
            XCTAssertEqual(content, "echo:hi")
            XCTAssertFalse(isError)
        } else {
            XCTFail("expected tool result block")
        }
        XCTAssertEqual(provider.requests.count, 2)
        XCTAssertEqual(provider.requests[0].system, "sys")
    }

    func testSummarizeShowsLabelAndRuntimeEstimate() {
        let summary = AgentLoop.summarize(
            inputJSON: #"{"script":"print(1)","label":"check-doubling","estimated_runtime_seconds":45}"#)
        XCTAssertEqual(summary, "label: check-doubling · est ~45s")
        XCTAssertEqual(AgentLoop.summarize(inputJSON: #"{"query":"hi"}"#), "query: hi")
    }

    func testUnknownToolReportsErrorResult() async throws {
        let provider = MockProvider(scripts: [
            [.toolUseFinished(id: "t1", name: "nope", inputJSON: "{}"), .finished(.toolUse)],
            [.textDelta("ok"), .finished(.endTurn)]
        ])
        let loop = AgentLoop(provider: provider)
        let result = try await loop.run(
            config: AgentConfig(systemPrompt: "s", tools: [EchoTool()]),
            history: [.user("q")]
        )
        if case .toolResult(_, let content, let isError) = result.transcript[2].blocks[0] {
            XCTAssertTrue(isError)
            XCTAssertTrue(content.contains("Unknown tool"))
        } else {
            XCTFail("expected tool result block")
        }
        XCTAssertEqual(result.finalText, "ok")
    }

    func testIterationCap() async throws {
        // Provider always asks for another tool call; the loop must stop at maxIterations.
        let endless = Array(repeating: [
            LLMEvent.toolUseFinished(id: "t", name: "echo", inputJSON: "{}"),
            LLMEvent.finished(.toolUse)
        ], count: 10)
        let provider = MockProvider(scripts: endless)
        let loop = AgentLoop(provider: provider)
        let result = try await loop.run(
            config: AgentConfig(systemPrompt: "s", tools: [EchoTool()], maxIterations: 3),
            history: [.user("q")]
        )
        XCTAssertEqual(provider.requests.count, 3)
        XCTAssertTrue(result.finalText.contains("iteration limit"))
    }
}

final class OrganizerTests: XCTestCase {

    func testParseProposalsFromProseWrappedJSON() throws {
        let response = """
        Here is the structured breakdown:

        ```json
        [
          {"id": "def-dominating-set", "type": "definition", "name": "Dominating set",
           "section": "Basics!",
           "statement": "A set $D \\\\subseteq V$ with $N[D] = V$.", "depends_on": [], "tags": ["basics"]},
          {"id": "thm-ore", "type": "theorem", "name": "Ore bound", "status": "human-approved",
           "statement": "If $\\\\delta(G) \\\\ge 1$ then $\\\\gamma(G) \\\\le n/2$.",
           "proof": "Take a spanning forest [...]", "depends_on": ["def-dominating-set"]},
          {"type": "porism", "name": "Bogus", "statement": "x"}
        ]
        ```
        """
        let (items, warnings) = try Organizer.parseProposals(from: response)
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items[0].id, "def-dominating-set")
        XCTAssertEqual(items[0].section, "basics")
        XCTAssertEqual(items[0].status, .proofDrafted)
        XCTAssertEqual(items[1].status, .humanApproved)
        XCTAssertTrue(items[1].body.contains("## Proof"))
        XCTAssertEqual(items[1].dependsOn, ["def-dominating-set"])
        // Unknown types are preserved as remarks (with a warning), not dropped.
        XCTAssertEqual(items[2].type, .remark)
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings[0].contains("porism"))
    }

    func testParseProposalsMapsNearMissTypesWithWarning() throws {
        let response = """
        [{"id": "prop-x", "type": "Proposition", "name": "X", "statement": "s"},
         {"type": "open question", "name": "Y", "statement": "t"}]
        """
        let (items, warnings) = try Organizer.parseProposals(from: response)
        XCTAssertEqual(items.map(\.type), [.proposition, .openProblem])
        XCTAssertEqual(items[1].status, .conjecture)  // open-like default
        XCTAssertEqual(warnings.count, 1)  // "open question" is an alias, "Proposition" is exact
        XCTAssertTrue(warnings[0].contains("open question"))
    }

    func testExtractJSONArrayRespectsStrings() {
        let text = #"noise ["a]b", "c"] trailing"#
        XCTAssertEqual(Organizer.extractJSONArray(from: text), #"["a]b", "c"]"#)
        XCTAssertNil(Organizer.extractJSONArray(from: "no array here"))
    }

    func testMissingArrayThrows() {
        XCTAssertThrowsError(try Organizer.parseProposals(from: "I could not process this."))
    }

    func testSectionOutlineFromSectionsAndSubsections() {
        let source = """
        \\section{Preliminaries}
        Some text.
        \\subsection{Basic Notation}
        \\section{The ring $\\mathcal{O}_K$}
        \\subsection*{Division Results}
        """
        let outline = Organizer.sectionOutline(from: source)
        // Math noise in headings is stripped before slugging: $\mathcal{O}_K$ → OK.
        XCTAssertEqual(outline, """
        - preliminaries — “Preliminaries”
        - preliminaries/basic-notation — “Basic Notation”
        - the-ring-ok — “The ring OK”
        - the-ring-ok/division-results — “Division Results”
        """)
    }

    func testSectionOutlineChaptersBecomeTopLevel() {
        let source = """
        \\chapter{Weierstrass Theory}
        \\section{Division}
        \\subsection{Too Deep}
        \\chapter{Applications}
        """
        let outline = Organizer.sectionOutline(from: source)
        XCTAssertEqual(outline, """
        - weierstrass-theory — “Weierstrass Theory”
        - weierstrass-theory/division — “Division”
        - weierstrass-theory/too-deep — “Too Deep”
        - applications — “Applications”
        """)
    }

    func testSectionOutlineAbsentWithoutHeadings() {
        XCTAssertNil(Organizer.sectionOutline(from: "Just a theorem: $x^2 \\ge 0$."))
        XCTAssertNil(Organizer.sectionOutline(from: "We discuss \\sectioning conventions."))
    }

    func testUserMessageIncludesOutlineWhenPresent() {
        let withSections = Organizer.userMessage(source: "\\section{Basics}\nText")
        XCTAssertTrue(withSections.contains("- basics — “Basics”"))
        let without = Organizer.userMessage(source: "Plain text")
        XCTAssertFalse(without.contains("Document outline"))
    }
}

final class SandboxToolsTests: XCTestCase {

    private var tempDir: URL!
    private var store: ProjectStore!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("manifieldagents-sandbox-tests-\(UUID().uuidString)")
        store = try ProjectStore.create(at: tempDir, name: "T")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testOEISFormatBothShapes() {
        let wrapped = #"{"results":[{"number":45,"name":"Fibonacci numbers","data":"0,1,1,2,3,5,8,13,21,34,55,89,144,233"}]}"#
        let out = OEISLookupTool.format(data: Data(wrapped.utf8), query: "0,1,1,2")
        XCTAssertTrue(out.contains("A000045"))
        XCTAssertTrue(out.contains("Fibonacci"))

        let bare = #"[{"number":7,"name":"The zero sequence","data":"0,0,0"}]"#
        XCTAssertTrue(OEISLookupTool.format(data: Data(bare.utf8), query: "q").contains("A000007"))

        XCTAssertTrue(OEISLookupTool.format(data: Data("null".utf8), query: "xyz").contains("No OEIS matches"))
    }

    func testRecordTestEvidenceCreatesProposal() async throws {
        try store.save(TheoryItem(
            id: "conj-x", type: .conjecture, name: "X", status: .conjecture,
            body: "## Statement\n$P$ holds."))

        let captured = CapturedProposal()
        let tool = RecordTestEvidenceTool(store: store) { captured.set($0) }
        let reply = try await tool.execute(inputJSON: """
            {"id": "conj-x", "verdict": "no-counterexample-found",
             "summary": "all 853 connected graphs on ≤7 vertices with δ≥2",
             "artifact": "20260707-101500-check-x"}
            """)

        XCTAssertTrue(reply.contains("Do not assume it was accepted"))
        let proposal = captured.value
        XCTAssertNotNil(proposal)
        XCTAssertEqual(proposal?.action, .update)
        XCTAssertEqual(proposal?.item.status, .tested)
        XCTAssertTrue(proposal?.item.body.contains("## Evidence") ?? false)
        XCTAssertTrue(proposal?.item.body.contains("artifacts/20260707-101500-check-x") ?? false)
        // The store itself must be untouched until the user confirms.
        XCTAssertEqual(store.item(id: "conj-x")?.status, .conjecture)
    }

    func testRecordCounterexampleResetsStatus() async throws {
        try store.save(TheoryItem(
            id: "thm-y", type: .theorem, name: "Y", status: .proofDrafted,
            body: "## Statement\n$Q$ holds."))
        let captured = CapturedProposal()
        let tool = RecordTestEvidenceTool(store: store) { captured.set($0) }
        _ = try await tool.execute(inputJSON: """
            {"id": "thm-y", "verdict": "counterexample-found",
             "summary": "found on C5", "artifact": "a1",
             "counterexample": "C5 edge list: (1,2),(2,3),(3,4),(4,5),(5,1)"}
            """)
        XCTAssertEqual(captured.value?.item.status, .conjecture)
        XCTAssertTrue(captured.value?.item.body.contains("Counterexample: C5") ?? false)
    }

    func testRunPythonToolEndToEnd() async throws {
        let runtime = PythonRuntime(venvURL: tempDir.appendingPathComponent("no-venv"))
        guard runtime.findSystemPython() != nil else { throw XCTSkip("no python3") }
        let sandbox = PythonSandbox(runtime: runtime, artifactsURL: store.artifactsURL, useSeatbelt: false)
        let tool = RunPythonTool(sandbox: sandbox)
        let reply = try await tool.execute(inputJSON: """
            {"script": "print('counterexamples found:', 0)", "label": "toolcheck"}
            """)
        XCTAssertTrue(reply.contains("exit code: 0"))
        XCTAssertTrue(reply.contains("counterexamples found: 0"))
        XCTAssertTrue(reply.contains("artifact: artifacts/"))
        XCTAssertTrue(reply.contains("math packages NOT installed"))
    }

    private final class CapturedProposal: @unchecked Sendable {
        private let lock = NSLock()
        private var proposal: TheoryProposal?
        func set(_ p: TheoryProposal) { lock.lock(); proposal = p; lock.unlock() }
        var value: TheoryProposal? { lock.lock(); defer { lock.unlock() }; return proposal }
    }
}

final class SourceImportTests: XCTestCase {

    func testSplitLaTeXByChaptersAndSections() {
        let tex = """
        \\documentclass{book}
        \\newcommand{\\A}{\\mathcal{A}}
        \\begin{document}
        \\chapter{Preliminaries}
        Basic notions of rings and ideals, with enough text to pass the length filter. \
        We recall standard definitions used throughout this work and fix conventions.
        \\section{Power Series}
        The ring of formal power series and its basic properties, again with sufficient \
        prose to constitute a meaningful chunk of mathematical content for import.
        \\chapter{Weierstrass Theory}
        \\section{Division}
        The Weierstrass division theorem states that for $F$ regular of order $m$ there \
        exist unique $Q$ and $R$ with the required degree bound on the remainder term.
        \\end{document}
        """
        let chunks = SourceImport.splitLaTeX(tex)
        let sections = chunks.map(\.section)
        XCTAssertEqual(sections, ["preliminaries", "preliminaries/power-series", "weierstrass-theory/division"],
                       "empty chapter body (Weierstrass) is skipped; nesting follows chapters")
        XCTAssertTrue(chunks[1].text.contains("formal power series"))
        XCTAssertEqual(chunks[2].title, "Division")
    }

    func testSplitLaTeXWithoutHeadingsAndSizeSplit() {
        let flat = SourceImport.splitLaTeX("Just a theorem: $x=x$. No headings here.")
        XCTAssertEqual(flat.count, 1)
        XCTAssertEqual(flat[0].section, "imported")

        let paragraph = String(repeating: "word ", count: 400)  // ~2000 chars
        let big = Array(repeating: paragraph, count: 20).joined(separator: "\n\n")
        let split = SourceImport.splitLaTeX("\\section{Huge}\n" + big, maxChunkSize: 10_000)
        XCTAssertGreaterThan(split.count, 2)
        XCTAssertTrue(split.allSatisfy { $0.section == "huge" })
        XCTAssertTrue(split.allSatisfy { $0.text.count <= 12_000 })
        XCTAssertTrue(split[1].title.contains("part 2"))
    }

    /// The import that motivated the structured splitter: a book whose body held no
    /// blank line came back as one 960k-character "paragraph", was sent whole, and was
    /// rejected by the provider at ~250k tokens. The surrounding scraps produced no
    /// items, so the run reported success with an empty source.
    func testNoChunkExceedsTheBudgetEvenWithoutParagraphBreaks() {
        let preamble = Array(repeating: String(repeating: "x", count: 500), count: 10)
            .joined(separator: "\n\n")
        let unbrokenBody = String(repeating: "a body line with no blank lines\n", count: 30_000)
        let chunks = SourceImport.splitLaTeX(
            preamble + "\n\n" + unbrokenBody, maxChunkSize: 24_000)

        XCTAssertGreaterThan(chunks.count, 30, "a ~1 MB document must not stay in 3 chunks")
        XCTAssertTrue(chunks.allSatisfy { $0.text.count <= 24_000 },
                      "largest chunk was \(chunks.map(\.text.count).max() ?? 0) characters")
    }

    /// Same guarantee when there are no line breaks at all to cut on.
    func testSingleEnormousLineIsHardSplitAndFlagged() {
        let line = String(repeating: "word ", count: 20_000)  // 100k chars, one line
        let chunks = SourceImport.splitLaTeX(line, maxChunkSize: 10_000)
        XCTAssertTrue(chunks.allSatisfy { $0.text.count <= 10_000 })
        XCTAssertTrue(chunks.dropFirst().allSatisfy(\.startsMidStructure))
        XCTAssertTrue(chunks.dropLast().allSatisfy(\.endsMidStructure))
    }

    /// Titles carrying math — `\chapter{The spaces $L^p(\mathbb{R})$}` — used to be
    /// invisible to the heading regex, which could not see past a nested brace, so a
    /// structured book was chunked as if it had no structure at all.
    func testHeadingsWithBracesInTitlesAreFound() {
        let tex = """
        \\chapter{The spaces $L^p(\\mathbb{R})$}
        Completeness of these spaces is the content of the Riesz–Fischer theorem, stated \
        and proved below with the usual measure-theoretic apparatus assumed known.
        \\section[Duality]{Duality and the space $L^q$}
        The dual of $L^p$ is $L^q$ for conjugate exponents, established by the standard \
        Radon–Nikodym argument that occupies the rest of this section of the chapter.
        """
        let chunks = SourceImport.splitLaTeX(tex)
        XCTAssertEqual(chunks.map(\.section), ["the-spaces-lp-r", "the-spaces-lp-r/duality-and-the-space-lq"])
    }

    /// The user-visible worry: a cut inside `\begin{theorem}` hands the model half a
    /// statement, and half a statement is what a model completes out of thin air.
    /// Paragraph breaks inside environments are common, so the splitter must skip them.
    func testSplitNeverCutsInsideATheoremOrProof() {
        let unit = """
        \\begin{theorem}[Riesz representation]
        Let $H$ be a Hilbert space and $f$ a bounded linear functional on it.

        Then $f = \\langle\\cdot, y\\rangle$ for a unique $y \\in H$ with $\\|f\\| = \\|y\\|$.
        \\end{theorem}

        \\begin{proof}
        Consider $\\ker f$, a closed subspace of $H$ by continuity of the functional.

        If $\\ker f = H$ take $y = 0$; otherwise pick a unit vector orthogonal to it.
        \\end{proof}
        """
        let body = Array(repeating: unit, count: 40).joined(separator: "\n\n")
        let chunks = SourceImport.splitLaTeX("\\section{Hilbert Spaces}\n" + body, maxChunkSize: 3_000)

        XCTAssertGreaterThan(chunks.count, 5, "the fixture must actually need splitting")
        for chunk in chunks {
            let begins = chunk.text.components(separatedBy: "\\begin{").count - 1
            let ends = chunk.text.components(separatedBy: "\\end{").count - 1
            XCTAssertEqual(begins, ends, "chunk '\(chunk.title)' straddles an environment")
            XCTAssertFalse(chunk.startsMidStructure)
            XCTAssertFalse(chunk.endsMidStructure)
        }
    }

    /// A single environment larger than the whole budget cannot be kept intact — but
    /// then both sides must be flagged, so the Organizer is told not to invent the rest.
    func testEnvironmentLargerThanTheBudgetIsFlaggedOnBothSides() {
        let proof = "\\begin{proof}\n"
            + Array(repeating: "A step of the argument, spelled out at length.", count: 300)
                .joined(separator: "\n\n")
            + "\n\\end{proof}"
        let chunks = SourceImport.splitLaTeX("\\section{Long}\n" + proof, maxChunkSize: 2_000)

        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(chunks.allSatisfy { $0.text.count <= 2_000 })
        XCTAssertTrue(chunks[0].endsMidStructure, "the first piece stops inside the proof")
        XCTAssertTrue(chunks[1].startsMidStructure, "the second piece opens inside it")
        XCTAssertFalse(chunks.last!.endsMidStructure, "the last piece closes the proof")
    }

    /// Text after `\end{document}` is not part of the document — LaTeX stops reading
    /// there. A real import spent 25 rate-limited model calls reading a megabyte of
    /// base64 that sat past that line.
    func testTextAfterEndDocumentIsNotImported() {
        let tex = """
        \\documentclass{article}
        \\begin{document}
        \\section{Real Content}
        A theorem worth importing, stated with enough surrounding prose to survive the \
        minimum-length filter that drops empty sectioning stubs from the chunk list.
        \\end{document}

        \\begin{document}
        \\section{Trailing Junk}
        \(String(repeating: "Material that LaTeX never reads because it is past the end.\n", count: 500))
        """
        let chunks = SourceImport.splitLaTeX(tex)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].section, "real-content")
        XCTAssertFalse(chunks[0].text.contains("Trailing Junk"))
    }

    func testWholeLineCommentsAreNotImported() {
        let tex = """
        \\section{Kept}
        % a note to self that is not content
        Real prose that belongs to the section and must survive the comment stripping \
        along with everything else stated here in the body of this particular section.
        """
        let chunks = SourceImport.splitLaTeX(tex)
        XCTAssertFalse(chunks[0].text.contains("note to self"))
        XCTAssertTrue(chunks[0].text.contains("Real prose"))
    }

    /// The file that produced 25 empty chunks: a PDF smuggled into a `.tex` shell whose
    /// document body is empty. Nothing here is worth a model call, and the user needs to
    /// be told where the mathematics actually is.
    func testBase64PDFWrapperIsRejectedWithAUsefulReason() {
        let payload = Array(repeating: "JVBERi0xLjUKJdDUxdgKMTEwIDAgb2JqCjw8Ci9MZW5ndGggMzE0NQovRmlsdGVy",
                            count: 400).joined(separator: "\n")
        let tex = """
        \\documentclass{article}
        \\directlua{ decode the payload below at compile time }
        \\begin{document}
        \\end{document}

        %%<FA-PDF-BASE64>
        \(payload)
        """
        let reason = SourceImport.rejectionReason(forLaTeX: tex, fileName: "wrapper.tex")
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason!.contains("PDF encoded as base64"))
        XCTAssertTrue(reason!.contains("Import that PDF itself"))
    }

    func testMasterFileOfIncludesIsRejectedWithAUsefulReason() {
        let tex = """
        \\documentclass{book}
        \\begin{document}
        \\input{chapter1}
        \\include{appendix}
        \\end{document}
        """
        let reason = SourceImport.rejectionReason(forLaTeX: tex, fileName: "book.tex")
        XCTAssertTrue(reason?.contains("master file") == true)
        XCTAssertTrue(reason?.contains("2 other file(s)") == true)
    }

    /// The screening must never stand between the user and a real document — including a
    /// short one, and including a chapter fragment with no preamble at all.
    func testOrdinaryDocumentsAndFragmentsAreNeverRejected() {
        let short = """
        \\documentclass{article}
        \\begin{document}
        \\begin{theorem}
        Every bounded functional on a subspace extends to the whole space with equal norm.
        \\end{theorem}
        \\end{document}
        """
        XCTAssertNil(SourceImport.rejectionReason(forLaTeX: short, fileName: "short.tex"))

        let fragment = "\\chapter{Included}\n\\begin{theorem}A statement.\\end{theorem}"
        XCTAssertNil(SourceImport.rejectionReason(forLaTeX: fragment, fileName: "ch1.tex"),
                     "a file meant to be \\input has no \\begin{document} and is still importable")

        // A chunk of ordinary mathematics is not an encoded payload, however dense.
        XCTAssertFalse(SourceImport.isEncodedPayload("""
        \\begin{align}\\int_0^\\infty\\frac{\\sin x}{x}\\,dx = \\frac{\\pi}{2}\\end{align}
        The Dirichlet integral, evaluated by contour integration over a semicircular arc.
        """))
    }

    func testSplitPagesBatches() {
        let pages = (1...20).map { "Page \($0) content" }
        let chunks = SourceImport.splitPages(pages, pagesPerChunk: 8)
        XCTAssertEqual(chunks.count, 3)
        XCTAssertEqual(chunks[0].section, "part-1")
        XCTAssertEqual(chunks[2].title, "Part 3 (pages 17–20)")
    }

    func testSplitPagesWithOutlineFollowsSections() throws {
        // 20 pages, two chapters with one subsection each; chapter 2 starts on page 11.
        let pages = (1...20).map { "Page \($0) " + String(repeating: "content ", count: 20) }
        let outline = [
            SourceImport.OutlineEntry(title: "Foundations", pageIndex: 0, depth: 0),
            SourceImport.OutlineEntry(title: "Rings", pageIndex: 4, depth: 1),
            SourceImport.OutlineEntry(title: "Modules", pageIndex: 10, depth: 0),
            SourceImport.OutlineEntry(title: "Free Modules", pageIndex: 14, depth: 1),
        ]
        let chunks = try XCTUnwrap(SourceImport.splitPages(pages, outline: outline, pagesPerChunk: 8))

        XCTAssertEqual(chunks.map(\.section),
                       ["foundations", "foundations/rings", "modules", "modules/free-modules"])
        XCTAssertEqual(chunks[0].title, "Foundations (pages 1–4)")
        XCTAssertEqual(chunks[1].title, "Rings (pages 5–10)")
        XCTAssertEqual(chunks[3].title, "Free Modules (pages 15–20)")
        // No chunk straddles a section boundary even under the 8-page batch size.
        XCTAssertTrue(chunks.allSatisfy { !$0.text.isEmpty })
    }

    func testSplitPagesWithOutlineBatchesLongSections() throws {
        let pages = (1...30).map { "Page \($0) " + String(repeating: "words ", count: 20) }
        let outline = [
            SourceImport.OutlineEntry(title: "One", pageIndex: 0, depth: 0),
            SourceImport.OutlineEntry(title: "Two", pageIndex: 20, depth: 0),
        ]
        let chunks = try XCTUnwrap(SourceImport.splitPages(pages, outline: outline, pagesPerChunk: 8))
        // "One" spans 20 pages → three batches, all in the same section.
        XCTAssertEqual(chunks.map(\.section), ["one", "one", "one", "two", "two"])
        XCTAssertEqual(chunks[0].title, "One (pages 1–8)")
        XCTAssertEqual(chunks[2].title, "One (pages 17–20)")
    }

    func testSplitPagesWithDegenerateOutlineFallsBack() {
        let pages = (1...10).map { "Page \($0) " + String(repeating: "text ", count: 20) }
        // A single bookmark tells us nothing about structure.
        XCTAssertNil(SourceImport.splitPages(
            pages, outline: [SourceImport.OutlineEntry(title: "All", pageIndex: 0, depth: 0)]))
        // Out-of-range bookmarks are dropped, leaving too few to be useful.
        XCTAssertNil(SourceImport.splitPages(
            pages, outline: [
                SourceImport.OutlineEntry(title: "A", pageIndex: 50, depth: 0),
                SourceImport.OutlineEntry(title: "B", pageIndex: 60, depth: 0),
            ]))
    }

    func testSplitPagesWithOutlineKeepsFrontMatterAndDedupesSlugs() throws {
        let filler = String(repeating: "front matter text ", count: 30)
        let pages = [filler, filler] + (3...12).map { "Page \($0) " + String(repeating: "body ", count: 20) }
        let outline = [
            SourceImport.OutlineEntry(title: "Results", pageIndex: 2, depth: 0),
            SourceImport.OutlineEntry(title: "Results", pageIndex: 7, depth: 0),
        ]
        let chunks = try XCTUnwrap(SourceImport.splitPages(pages, outline: outline, pagesPerChunk: 8))
        XCTAssertEqual(chunks[0].section, "front-matter")
        XCTAssertEqual(chunks.map(\.section).filter { $0.hasPrefix("results") },
                       ["results", "results-2"])
    }

    func testNormalizeForcesSourceInvariants() {
        let items = [
            TheoryItem(id: "thm-a", type: .theorem, name: "A", status: .humanApproved),
            TheoryItem(id: "conj-b", type: .conjecture, name: "B", status: .tested,
                       section: "weierstrass-theory/open-problems")
        ]
        let normalized = SourceImport.normalize(items, chunkSection: "weierstrass-theory", citation: "Book (1991)")
        XCTAssertEqual(normalized[0].status, .source)
        XCTAssertEqual(normalized[0].section, "weierstrass-theory")
        XCTAssertEqual(normalized[0].source, "Book (1991)")
        XCTAssertEqual(normalized[1].status, .conjecture, "open problems stay conjectures")
        XCTAssertEqual(normalized[1].section, "weierstrass-theory/open-problems", "organizer's refinement kept")
        XCTAssertNil(normalized[0].order, "no chunk index, no order stamp")

        let stamped = SourceImport.normalize(items, chunkSection: "s", citation: nil, chunkIndex: 3)
        XCTAssertEqual(stamped.map(\.order), [3000, 3001])
    }
}

final class SourceToolsTests: XCTestCase {

    private var tempDir: URL!
    private var attached: [(slug: String, store: ProjectStore)] = []

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("source-tools-tests-\(UUID().uuidString)")
        let book = try ProjectStore.create(at: tempDir.appendingPathComponent("book"), name: "Analytic Geometry")
        try book.updateMeta { $0.kind = .source; $0.citation = "Łojasiewicz (1991)" }
        try book.save(TheoryItem(
            id: "thm-division", type: .theorem, name: "Weierstrass division",
            status: .source, section: "weierstrass-theory",
            body: "## Statement\nFor $F$ regular of order $m$ ..."))
        attached = [("analytic-geometry", book)]
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testSearchReturnsNamespacedIDs() async throws {
        let tools = SourceTools.tools(attached: attached)
        let search = tools.first { $0.spec.name == "search_sources" }!
        let result = try await search.execute(inputJSON: #"{"query": "division"}"#)
        XCTAssertTrue(result.contains("analytic-geometry:thm-division"))
        let empty = try await search.execute(inputJSON: #"{"query": "cohomology"}"#)
        XCTAssertTrue(empty.contains("No matches"))
    }

    func testReadSourceItem() async throws {
        let tools = SourceTools.tools(attached: attached)
        let read = tools.first { $0.spec.name == "read_source_item" }!
        let result = try await read.execute(inputJSON: #"{"ref": "analytic-geometry:thm-division"}"#)
        XCTAssertTrue(result.contains("Łojasiewicz (1991)"))
        XCTAssertTrue(result.contains("Cite as: analytic-geometry:thm-division"))
        XCTAssertTrue(result.contains("regular of order"))

        await XCTAssertThrowsErrorAsync(try await read.execute(inputJSON: #"{"ref": "nope:thm-x"}"#))
        await XCTAssertThrowsErrorAsync(try await read.execute(inputJSON: #"{"ref": "no-colon"}"#))
    }

    func testNoToolsWithoutAttachedSources() {
        XCTAssertTrue(SourceTools.tools(attached: []).isEmpty)
    }

    /// The bug this guards: chatting in English about a Polish paper, the agent searched
    /// in English, got nothing, and reported that the source does not cover the theorem.
    /// Both the tool description and the empty result now name the source's language.
    func testSearchNamesTheSourceLanguage() async throws {
        let paper = try ProjectStore.create(
            at: tempDir.appendingPathComponent("topologia"), name: "Topologia ogólna")
        try paper.updateMeta { $0.kind = .source }
        try paper.save(TheoryItem(
            id: "tw-zwartosc", type: .theorem, name: "Twierdzenie o zwartości",
            status: .source,
            body: """
            ## Statement
            Niech $X$ będzie przestrzenią topologiczną zwartą i spójną. Wówczas każde
            odwzorowanie ciągłe $f \\colon X \\to \\mathbb{R}$ osiąga swoje kresy, a obraz
            jest przedziałem domkniętym.
            """))
        let tools = SourceTools.tools(attached: [("topologia", paper)])
        let search = try XCTUnwrap(tools.first { $0.spec.name == "search_sources" })

        XCTAssertTrue(search.spec.description.contains("topologia [Polish]"),
                      "the language is stated before the query is written")
        XCTAssertTrue(search.spec.description.contains("Polish here"))

        let empty = try await search.execute(inputJSON: #"{"query": "compact connected"}"#)
        XCTAssertTrue(empty.contains("No matches"))
        XCTAssertTrue(empty.contains("topologia is written in Polish"),
                      "and again where the mistake shows — an empty result")

        let found = try await search.execute(inputJSON: #"{"query": "zwartą spójną"}"#)
        XCTAssertTrue(found.contains("topologia:tw-zwartosc"))

        let prompt = ContextAssembly.sourcesSection(attached: [("topologia", paper)])
        XCTAssertTrue(prompt.contains("1 items in Polish"))
    }

    /// A library the user works in is not always in the language of the conversation either.
    func testTheorySearchNamesTheLibraryLanguage() async throws {
        let store = try ProjectStore.create(
            at: tempDir.appendingPathComponent("praca"), name: "Praca")
        try store.save(TheoryItem(
            id: "lem-ciaglosc", type: .lemma, name: "Lemat o ciągłości",
            body: """
            ## Statement
            Każda funkcja ciągła na zbiorze domkniętym i ograniczonym jest jednostajnie
            ciągła, a jej obraz jest zbiorem zwartym w przestrzeni euklidesowej.
            """))
        let search = try XCTUnwrap(
            TheoryTools.readOnlyTools(store: store).first { $0.spec.name == "search_theory" })

        XCTAssertTrue(search.spec.description.contains("Polish here"))
        let empty = try await search.execute(inputJSON: #"{"query": "uniformly continuous"}"#)
        XCTAssertTrue(empty.contains("the library is written in Polish"))
        XCTAssertTrue(empty.contains("list_theory"), "the existing fallback survives")
    }

    func testChatPromptListsSources() {
        let prompt = ContextAssembly.chatSystemPrompt(
            projectName: "Work", notation: "", items: [], userProfile: "",
            attachedSources: attached
        ).text
        XCTAssertTrue(prompt.contains("analytic-geometry — Analytic Geometry (Łojasiewicz (1991))"))
        XCTAssertTrue(prompt.contains("sections: weierstrass-theory"))
        XCTAssertTrue(prompt.contains("never cite literature from memory"))
    }
}

func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("expected error", file: file, line: line)
    } catch {}
}

final class ContextAssemblyTests: XCTestCase {

    func testOutlineGroupsBySection() {
        let items = [
            TheoryItem(id: "def-a", type: .definition, name: "A", section: "basics"),
            TheoryItem(id: "thm-b", type: .theorem, name: "B", section: "main-results"),
            TheoryItem(id: "rem-c", type: .remark, name: "C")
        ]
        let outline = ContextAssembly.outline(items: items)
        let basicsPos = outline.range(of: "§ Basics")?.lowerBound
        let mainPos = outline.range(of: "§ Main Results")?.lowerBound
        let unsortedPos = outline.range(of: "§ Unsorted")?.lowerBound
        XCTAssertNotNil(basicsPos)
        XCTAssertNotNil(mainPos)
        XCTAssertNotNil(unsortedPos)
        XCTAssertTrue(basicsPos! < mainPos! && mainPos! < unsortedPos!, "unsectioned items go last")

        // Flat projects get no section headers at all.
        let flat = ContextAssembly.outline(items: [TheoryItem(id: "lem-x", type: .lemma, name: "X")])
        XCTAssertFalse(flat.contains("§"))
    }

    func testChatPromptContainsAllSections() {
        let items = [TheoryItem(id: "lem-a", type: .lemma, name: "A")]
        let prompt = ContextAssembly.chatSystemPrompt(
            projectName: "k-Domination",
            notation: "$\\gamma(G)$ is the domination number.",
            items: items,
            userProfile: "PhD student in graph theory."
        ).text
        XCTAssertTrue(prompt.contains("k-Domination"))
        XCTAssertTrue(prompt.contains("lem-a"))
        XCTAssertTrue(prompt.contains("PhD student"))
        XCTAssertTrue(prompt.contains("domination number"))
        XCTAssertTrue(prompt.contains("Never call a statement"))
    }
}
