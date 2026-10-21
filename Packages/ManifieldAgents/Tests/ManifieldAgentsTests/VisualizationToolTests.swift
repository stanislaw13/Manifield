import XCTest
@testable import ManifieldAgents

final class VisualizationToolTests: XCTestCase {

    func testScriptWrapsSnippetBetweenThemeAndSave() {
        let script = VisualizationTools.script(for: "ax.plot([1, 2], [3, 4])")
        XCTAssertTrue(script.contains("matplotlib.use(\"Agg\")"))
        XCTAssertTrue(script.contains("MANIFIELD_COLORS"))
        XCTAssertTrue(script.contains("ax.plot([1, 2], [3, 4])"))
        XCTAssertTrue(script.contains("MANIFIELD_VIZ_SAVED"))
        // Theme precedes the snippet; saving follows it.
        let theme = script.range(of: "MANIFIELD_COLORS")!.lowerBound
        let snippet = script.range(of: "ax.plot")!.lowerBound
        let save = script.range(of: "savefig(\"viz.png\")")!.lowerBound
        XCTAssertTrue(theme < snippet && snippet < save)
        // The python inside the swift literal must not carry Swift indentation.
        XCTAssertTrue(script.contains("\ntry:\n    import networkx as nx\n"))
    }

    func testMissingInputsRejected() async {
        let sandbox = ManifieldSandbox.PythonSandbox(
            runtime: .init(), artifactsURL: FileManager.default.temporaryDirectory)
        let tool = VisualizationTools.tool(sandbox: sandbox)
        await XCTAssertThrowsErrorAsync(try await tool.execute(inputJSON: #"{"title": "no code"}"#))
        await XCTAssertThrowsErrorAsync(try await tool.execute(inputJSON: #"{"code": "ax.plot([1],[1])"}"#))
    }
}

import ManifieldSandbox

final class AttachmentBlockCodableTests: XCTestCase {

    func testImageAndDocumentBlocksRoundTrip() throws {
        let message = LLMMessage(role: .user, blocks: [
            .image(mediaType: "image/png", base64: "aGVsbG8="),
            .document(name: "notes.tex", text: "\\gamma(G) \\le n/2"),
            .text("What does this say?")
        ])
        let data = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(LLMMessage.self, from: data)
        XCTAssertEqual(decoded, message)
    }

    func testAnthropicEncodesImageAndDocumentBlocks() throws {
        let provider = AnthropicProvider(config: .init(kind: .anthropic, apiKey: "k"))
        let request = LLMRequest(system: "s", messages: [
            LLMMessage(role: .user, blocks: [
                .image(mediaType: "image/jpeg", base64: "QUJD"),
                .document(name: "a.md", text: "hello"),
                .text("hi")
            ])
        ])
        let urlRequest = try provider.makeURLRequest(request)
        let body = try XCTUnwrap(urlRequest.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        let blocks = try XCTUnwrap(messages[0]["content"] as? [[String: Any]])
        XCTAssertEqual(blocks.count, 3)
        XCTAssertEqual(blocks[0]["type"] as? String, "image")
        let source = try XCTUnwrap(blocks[0]["source"] as? [String: Any])
        XCTAssertEqual(source["media_type"] as? String, "image/jpeg")
        XCTAssertEqual(source["data"] as? String, "QUJD")
        XCTAssertEqual(blocks[1]["type"] as? String, "text")
        XCTAssertTrue((blocks[1]["text"] as? String ?? "").contains("[Attached file: a.md]"))
        XCTAssertEqual(blocks[2]["text"] as? String, "hi")
    }

    func testOpenAICompatUsesArrayContentOnlyWithImages() throws {
        let provider = OpenAICompatProvider(
            config: .init(kind: .openai, apiKey: "k"),
            baseURL: URL(string: "https://api.openai.com/v1")!)

        // Document + text merge into one plain-string user message.
        let textual = LLMRequest(system: "s", messages: [
            LLMMessage(role: .user, blocks: [
                .document(name: "a.py", text: "print(1)"), .text("run it?")
            ])
        ])
        var body = try JSONSerialization.jsonObject(
            with: XCTUnwrap(provider.makeURLRequest(textual).httpBody)) as? [String: Any]
        var messages = try XCTUnwrap(body?["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 2)  // system + user
        let merged = try XCTUnwrap(messages[1]["content"] as? String)
        XCTAssertTrue(merged.contains("[Attached file: a.py]") && merged.contains("run it?"))

        // An image forces the content-parts array form.
        let withImage = LLMRequest(system: "s", messages: [
            LLMMessage(role: .user, blocks: [
                .image(mediaType: "image/png", base64: "QUJD"), .text("see this")
            ])
        ])
        body = try JSONSerialization.jsonObject(
            with: XCTUnwrap(provider.makeURLRequest(withImage).httpBody)) as? [String: Any]
        messages = try XCTUnwrap(body?["messages"] as? [[String: Any]])
        let parts = try XCTUnwrap(messages[1]["content"] as? [[String: Any]])
        XCTAssertEqual(parts[0]["type"] as? String, "image_url")
        let imageURL = try XCTUnwrap(parts[0]["image_url"] as? [String: Any])
        XCTAssertEqual(imageURL["url"] as? String, "data:image/png;base64,QUJD")
        XCTAssertEqual(parts[1]["type"] as? String, "text")
    }
}

/// Runs the real tool through the real sandbox — skipped unless the shared Manifield
/// Python environment (with matplotlib) is set up on this machine.
final class VisualizationToolIntegrationTests: XCTestCase {

    func testRendersRealPNGWithThemedHarness() async throws {
        let runtime = PythonRuntime()
        try XCTSkipUnless(runtime.isReady, "Manifield venv not set up")

        let artifacts = FileManager.default.temporaryDirectory
            .appendingPathComponent("manifield-viz-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: artifacts) }

        let sandbox = PythonSandbox(runtime: runtime, artifactsURL: artifacts)
        let delivered = expectation(description: "onImage fired")
        nonisolated(unsafe) var deliveredURL: URL?
        let tool = VisualizationTools.tool(sandbox: sandbox) { url, title, caption in
            deliveredURL = url
            XCTAssertEqual(title, "Primes")
            XCTAssertEqual(caption, "First primes")
            delivered.fulfill()
        }

        let input: [String: Any] = [
            "title": "Primes",
            "caption": "First primes",
            "code": """
            import sympy
            ns = list(range(2, 60))
            pi = [sympy.primepi(n) for n in ns]
            ax.step(ns, pi, where="post")
            ax.set_xlabel(r"$n$"); ax.set_ylabel(r"$\\pi(n)$")
            ax.set_title("Prime counting function")
            print("last value:", pi[-1])
            """
        ]
        let result = try await tool.execute(
            inputJSON: String(data: JSONSerialization.data(withJSONObject: input), encoding: .utf8)!)

        await fulfillment(of: [delivered], timeout: 5)
        let url = try XCTUnwrap(deliveredURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let size = (try? Data(contentsOf: url).count) ?? 0
        XCTAssertGreaterThan(size, 10_000, "PNG suspiciously small")
        XCTAssertTrue(result.hasPrefix("png: artifacts/"), "machine-parseable first line, got: \(result.prefix(60))")
        XCTAssertTrue(result.contains("last value:"), "snippet stdout should be passed back to the model")

        // The failure path returns actionable stderr.
        do {
            _ = try await tool.execute(inputJSON: #"{"title": "Broken", "code": "ax.plot(undefined_name)"}"#)
            XCTFail("expected error")
        } catch {
            XCTAssertTrue("\(error.localizedDescription)".contains("undefined_name"))
        }
    }
}
