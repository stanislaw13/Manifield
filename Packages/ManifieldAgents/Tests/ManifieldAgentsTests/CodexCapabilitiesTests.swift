import XCTest
@testable import ManifieldAgents

final class CodexCapabilitiesTests: XCTestCase {

    // MARK: - Method inventory parsing

    /// The exact shape recent `codex app-server` builds return for an unrecognized method —
    /// captured live, not invented, so this test pins the real format rather than an assumption
    /// about it.
    private static let capturedUnknownMethodError = """
    Invalid request: unknown variant `bogus/method`, expected one of `initialize`, `thread/start`, \
    `turn/start`, `turn/interrupt`, `thread/inject_items`, `model/list`, `account/read`, \
    `account/rateLimits/read`, `account/login/start`, `account/login/cancel`, `account/logout`
    """

    func testParsesEveryBacktickQuotedMethodFromTheErrorMessage() {
        let methods = CodexCapabilities.parseSupportedMethods(
            fromUnknownMethodError: Self.capturedUnknownMethodError)
        XCTAssertEqual(methods, [
            "initialize", "thread/start", "turn/start", "turn/interrupt", "thread/inject_items",
            "model/list", "account/read", "account/rateLimits/read", "account/login/start",
            "account/login/cancel", "account/logout"
        ])
    }

    func testMessageWithNoExpectedOneOfClauseParsesToEmpty() {
        XCTAssertEqual(CodexCapabilities.parseSupportedMethods(fromUnknownMethodError: "some other error"), [])
    }

    func testMissingMethodsReportsExactlyWhatsAbsent() {
        let supported: Set<String> = [
            "initialize", "thread/start", "turn/start", "model/list", "account/read"
        ]
        let missing = CodexCapabilities.missingMethods(in: supported)
        XCTAssertEqual(missing, [
            "turn/interrupt", "account/rateLimits/read", "account/login/start",
            "account/login/cancel", "account/logout"
        ])
    }

    func testAllRequiredMethodsPresentLeavesNothingMissing() {
        XCTAssertTrue(CodexCapabilities.missingMethods(in: CodexCapabilities.requiredMethods).isEmpty)
        XCTAssertFalse(CodexCapabilities.requiredMethods.contains("thread/inject_items"),
                       "Phase 1 must not require the still-unused history injection method")
    }

    // MARK: - Schema field checks

    private func schemaData(properties: [String]) -> Data {
        let props = Dictionary(uniqueKeysWithValues: properties.map { ($0, ["type": "string"]) })
        return try! JSONSerialization.data(withJSONObject: ["type": "object", "properties": props])
    }

    func testDetectsDynamicToolsFieldWhenPresent() {
        XCTAssertTrue(CodexCapabilities.hasDynamicToolsField(
            inThreadStartParamsSchema: schemaData(properties: ["model", "cwd", "dynamicTools"])))
    }

    func testMissingDynamicToolsFieldFailsClosed() {
        XCTAssertFalse(CodexCapabilities.hasDynamicToolsField(
            inThreadStartParamsSchema: schemaData(properties: ["model", "cwd"])))
    }

    func testDetectsEffortFieldWhenPresent() {
        XCTAssertTrue(CodexCapabilities.hasEffortField(
            inTurnStartParamsSchema: schemaData(properties: ["threadId", "input", "effort"])))
    }

    func testMissingEffortFieldFailsClosed() {
        XCTAssertFalse(CodexCapabilities.hasEffortField(
            inTurnStartParamsSchema: schemaData(properties: ["threadId", "input"])))
    }

    func testMalformedSchemaDataFailsClosedRatherThanCrashing() {
        XCTAssertFalse(CodexCapabilities.hasDynamicToolsField(inThreadStartParamsSchema: Data("not json".utf8)))
        XCTAssertFalse(CodexCapabilities.hasEffortField(inTurnStartParamsSchema: Data()))
    }

    // MARK: - isSufficient

    func testIsSufficientRequiresAllThreeSignals() {
        XCTAssertTrue(CodexCapabilities(supportsDynamicTools: true, supportsEffort: true, missingMethods: []).isSufficient)
        XCTAssertFalse(CodexCapabilities(supportsDynamicTools: false, supportsEffort: true, missingMethods: []).isSufficient)
        XCTAssertFalse(CodexCapabilities(supportsDynamicTools: true, supportsEffort: false, missingMethods: []).isSufficient)
        XCTAssertFalse(CodexCapabilities(supportsDynamicTools: true, supportsEffort: true, missingMethods: ["turn/start"]).isSufficient)
    }

    func testCompatibilityDescriptionNamesMissingFieldsAndMethods() {
        let capabilities = CodexCapabilities(
            supportsDynamicTools: false, supportsEffort: false,
            missingMethods: ["turn/start", "model/list"])
        XCTAssertEqual(
            capabilities.incompatibilityDescription,
            "thread/start is missing the dynamicTools field; turn/start is missing the effort field; missing methods: model/list, turn/start")
    }

    func testRunnerRejectsIncompatibleBinaryBeforeStartingAThread() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-incompatible-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let binary = directory.appendingPathComponent("codex")
        let threadMarker = directory.appendingPathComponent("thread-started").path
        let source = """
        #!/usr/bin/python3
        import json, os, sys
        if "generate-json-schema" in sys.argv:
            out = sys.argv[sys.argv.index("--out") + 1]
            os.makedirs(os.path.join(out, "v2"), exist_ok=True)
            open(os.path.join(out, "v2", "ThreadStartParams.json"), "w").write('{"type":"object","properties":{}}')
            open(os.path.join(out, "v2", "TurnStartParams.json"), "w").write('{"type":"object","properties":{}}')
            sys.exit(0)
        for line in sys.stdin:
            request = json.loads(line)
            method = request.get("method")
            if method == "thread/start":
                open(\(String(reflecting: threadMarker)), "w").write("started")
            if request.get("id") == 0:
                print(json.dumps({"id":0,"result":{}}), flush=True)
            elif request.get("id") == 1:
                message = "Invalid request: unknown variant `probe`, expected one of `initialize`, `thread/start`"
                print(json.dumps({"id":1,"error":{"message":message}}), flush=True)
        """
        try source.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)

        do {
            _ = try await CodexRunner(model: "m", binaryOverride: binary.path).run(
                config: AgentConfig(systemPrompt: "sys", tools: []),
                history: [.user("q")], onActivity: { _ in })
            XCTFail("expected incompatibility rejection")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("incompatible codex binary"))
            XCTAssertTrue(error.localizedDescription.contains("dynamicTools"))
            XCTAssertTrue(error.localizedDescription.contains("missing methods"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: threadMarker),
                       "compatibility must be enforced before thread/start")
    }

    func testExecutableFingerprintChangesWhenBinaryIsReplacedInPlace() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-fingerprint-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("one".utf8).write(to: file)
        let first = CodexEnvironment.executableFingerprint(file.path)
        try Data("a different executable payload".utf8).write(to: file)
        let second = CodexEnvironment.executableFingerprint(file.path)
        XCTAssertNotEqual(first, second)
    }
}
