import XCTest
@testable import ManifieldSandbox

final class PythonSandboxTests: XCTestCase {

    private var artifactsDir: URL!
    private var sandbox: PythonSandbox!

    override func setUpWithError() throws {
        artifactsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("manifieldsandbox-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: artifactsDir, withIntermediateDirectories: true)
        // useSeatbelt=false: the test process may itself be sandboxed (nested seatbelt is
        // not permitted). The seatbelt path is still exercised via the retry logic test.
        sandbox = PythonSandbox(
            runtime: PythonRuntime(venvURL: artifactsDir.appendingPathComponent("no-venv")),
            artifactsURL: artifactsDir,
            useSeatbelt: false
        )
        guard sandbox.runtime.findSystemPython() != nil else {
            throw XCTSkip("no python3 available on this machine")
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: artifactsDir)
    }

    func testBasicRunProducesOutputAndArtifacts() async throws {
        let result = try await sandbox.run(
            script: "print('hello', 6 * 7)\n",
            label: "Basic Check!"
        )
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertFalse(result.timedOut)
        XCTAssertTrue(result.stdout.contains("hello 42"))
        XCTAssertTrue(result.artifactName.contains("basic-check"))

        let files = try FileManager.default.contentsOfDirectory(atPath: result.artifactURL.path)
        XCTAssertTrue(files.contains("script.py"))
        XCTAssertTrue(files.contains("stdout.txt"))
        XCTAssertTrue(files.contains("stderr.txt"))
        XCTAssertTrue(files.contains("meta.json"))

        let savedStdout = try String(contentsOf: result.artifactURL.appendingPathComponent("stdout.txt"), encoding: .utf8)
        XCTAssertTrue(savedStdout.contains("hello 42"))
    }

    func testTimeoutKillsProcess() async throws {
        let started = Date()
        let result = try await sandbox.run(
            script: "import time\nprint('starting')\ntime.sleep(60)\nprint('never')\n",
            label: "timeout",
            timeout: 2
        )
        XCTAssertTrue(result.timedOut)
        XCTAssertTrue(result.stdout.contains("starting"))
        XCTAssertFalse(result.stdout.contains("never"))
        XCTAssertLessThan(Date().timeIntervalSince(started), 15)
    }

    func testNonzeroExitAndStderr() async throws {
        let result = try await sandbox.run(
            script: "import sys\nsys.stderr.write('boom\\n')\nsys.exit(3)\n",
            label: "exitcode"
        )
        XCTAssertEqual(result.exitCode, 3)
        XCTAssertTrue(result.stderr.contains("boom"))
    }

    func testStdoutCap() async throws {
        let result = try await sandbox.run(
            script: "print('x' * 500000)\n",
            label: "bigout"
        )
        XCTAssertTrue(result.stdoutTruncated)
        XCTAssertLessThanOrEqual(result.stdout.count, PythonSandbox.stdoutLimit + 1024)
    }

    func testLabelSanitization() {
        // Unicode letters/digits are valid in folder names and are preserved.
        XCTAssertEqual(PythonSandbox.sanitize("Check γ₂ ≤ 2γ (v1)"), "check-γ₂-2γ-v1")
        XCTAssertEqual(PythonSandbox.sanitize("///"), "run")
    }

    func testRuntimeDiscovery() {
        let runtime = PythonRuntime(venvURL: artifactsDir.appendingPathComponent("missing"))
        XCTAssertNotNil(runtime.findSystemPython())
        XCTAssertFalse(runtime.isReady)
        let interpreter = runtime.runInterpreter()
        XCTAssertEqual(interpreter?.hasPackages, false)
    }
}

/// Run-folder allocation needs no interpreter, so it lives outside the class whose
/// setUp skips when python3 is missing.
final class RunDirectoryTests: XCTestCase {

    private var artifactsDir: URL!

    override func setUpWithError() throws {
        artifactsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("manifield-rundir-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: artifactsDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: artifactsDir)
    }

    private func makeSandbox(namespace: String?) -> PythonSandbox {
        PythonSandbox(
            runtime: PythonRuntime(venvURL: artifactsDir.appendingPathComponent("no-venv")),
            artifactsURL: artifactsDir,
            useSeatbelt: false,
            runNamespace: namespace)
    }

    func testRunNamespaceAppearsInFolderName() throws {
        let dir = try makeSandbox(namespace: "Branch Refuter!").makeRunDirectory(label: "Scan n=8")
        XCTAssertTrue(dir.lastPathComponent.contains("branch-refuter"))
        XCTAssertTrue(dir.lastPathComponent.contains("scan-n-8"))
    }

    func testNoNamespaceKeepsTimestampLabelShape() throws {
        let dir = try makeSandbox(namespace: nil).makeRunDirectory(label: "Scan")
        XCTAssertFalse(dir.lastPathComponent.isEmpty)
        XCTAssertTrue(dir.lastPathComponent.hasSuffix("-scan"))
    }

    /// The timestamp only resolves to the second: several runs of the same label in one
    /// second must still land in distinct folders.
    func testSameSecondSameLabelDirectoriesAreDistinct() throws {
        let sandbox = makeSandbox(namespace: "b1")
        var urls: Set<URL> = []
        for _ in 0..<5 {
            let dir = try sandbox.makeRunDirectory(label: "collide")
            XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path))
            urls.insert(dir)
        }
        XCTAssertEqual(urls.count, 5)
    }

    func testConcurrentBranchesDoNotShareAFolder() throws {
        let a = makeSandbox(namespace: "branch-a")
        let b = makeSandbox(namespace: "branch-b")
        let first = try a.makeRunDirectory(label: "same")
        let second = try b.makeRunDirectory(label: "same")
        XCTAssertNotEqual(first, second)
    }
}
