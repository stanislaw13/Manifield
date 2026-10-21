import XCTest
@testable import ManifieldDiagnostics

final class DiagnosticsSnapshotTests: XCTestCase {

    private func sample(isTranslocated: Bool = false,
                        planType: String? = "ChatGPT Plus",
                        providers: [String] = ["anthropic", "openai"]) -> DiagnosticsSnapshot {
        DiagnosticsSnapshot(appVersion: "0.1.0",
                            buildNumber: "1",
                            macOSVersion: "Version 26.3.0 (Build 25D60)",
                            architecture: "arm64",
                            isTranslocated: isTranslocated,
                            codexBinaryFound: true,
                            codexPlanType: planType,
                            pythonEnvironmentReady: false,
                            configuredProviders: providers,
                            capturedAt: Date(timeIntervalSince1970: 1_789_732_800))
    }

    func testEncodesAsReadableSortedJSON() throws {
        let json = try sample().jsonString()
        XCTAssertTrue(json.contains("\n"), "the disclosure shows this text; it has to be readable")
        XCTAssertTrue(json.contains("\"appVersion\" : \"0.1.0\""), json)
        XCTAssertTrue(json.contains("\"capturedAt\" : \"2026-09-18T12:00:00Z\""), json)
        // Sorted keys, so the same machine always produces the same text and a tester who
        // reads the preview twice sees the same thing twice.
        let appVersion = try XCTUnwrap(json.range(of: "appVersion"))
        let buildNumber = try XCTUnwrap(json.range(of: "buildNumber"))
        XCTAssertTrue(appVersion.lowerBound < buildNumber.lowerBound)
    }

    func testRoundTrips() throws {
        let original = sample(isTranslocated: true)
        let decoded = try DiagnosticsSnapshot.decoder()
            .decode(DiagnosticsSnapshot.self, from: original.jsonData())
        XCTAssertEqual(decoded, original)
    }

    // MARK: - Translocation

    func testTranslocationFlagIsEncoded() throws {
        XCTAssertTrue(try sample(isTranslocated: true).jsonString().contains("\"isTranslocated\" : true"))
        XCTAssertTrue(try sample(isTranslocated: false).jsonString().contains("\"isTranslocated\" : false"))
    }

    /// The path macOS actually runs a quarantined app from — randomised directory and all.
    func testTranslocatedBundlePathIsRecognised() {
        let translocated = "/private/var/folders/9k/xn2p4c1n0_3b/T/AppTranslocation/"
            + "4E1B2C3D-0000-4A5B-8C9D-AABBCCDDEEFF/d/Manifield.app"
        XCTAssertTrue(DiagnosticsSnapshot.isTranslocated(bundlePath: translocated))
    }

    func testOrdinaryBundlePathsAreNotTranslocated() {
        XCTAssertFalse(DiagnosticsSnapshot.isTranslocated(bundlePath: "/Applications/Manifield.app"))
        XCTAssertFalse(DiagnosticsSnapshot.isTranslocated(bundlePath: "/Users/ada/Downloads/Manifield.app"))
        XCTAssertFalse(DiagnosticsSnapshot.isTranslocated(
            bundlePath: "/Users/ada/Library/Developer/Xcode/DerivedData/Manifield-abc/Build/Products/Debug/Manifield.app"))
    }

    func testCurrentReadsTheBundleAndTheMachine() {
        let bundle = Bundle(for: DiagnosticsSnapshotTests.self)
        let snapshot = DiagnosticsSnapshot.current(
            .init(codexBinaryFound: false, codexPlanType: nil,
                  pythonEnvironmentReady: true, configuredProviders: ["gemini"]),
            bundle: bundle)
        XCTAssertFalse(snapshot.macOSVersion.isEmpty)
        XCTAssertTrue(["arm64", "x86_64", "arm64 (Rosetta)", "x86_64 (Rosetta)"].contains(snapshot.architecture),
                      snapshot.architecture)
        XCTAssertEqual(snapshot.configuredProviders, ["gemini"])
        XCTAssertTrue(snapshot.pythonEnvironmentReady)
    }

    // MARK: - What must never be in it

    func testPlanTypeSurvivesButIsNormalised() {
        XCTAssertEqual(sample(planType: "ChatGPT Plus").codexPlanType, "ChatGPT-Plus")
        XCTAssertEqual(sample(planType: nil).codexPlanType, nil)
    }

    /// Provider *names*, never keys. A key smuggled into the list is not identifier-shaped
    /// under its length limit, so it comes out as an opaque handle rather than a key.
    func testProviderListCannotCarryAKey() throws {
        let snapshot = sample(providers: ["anthropic", "sk-ant-api03-AAAABBBBCCCCDDDDEEEEFFFFGGGGHHHH"])
        let json = try snapshot.jsonString()
        XCTAssertTrue(json.contains("anthropic"))
        XCTAssertFalse(json.contains("sk-ant-api03"), json)
        XCTAssertTrue(json.contains("<opaque:"), json)
    }

    func testSnapshotCarriesNoAddressOrPath() throws {
        let json = try sample().jsonString()
        XCTAssertFalse(json.contains("@"))
        XCTAssertFalse(json.contains(NSHomeDirectory()))
    }
}
