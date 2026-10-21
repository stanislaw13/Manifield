import XCTest
import ManifieldCore
@testable import Manifield

/// The recovery affordance hangs entirely on this one judgement: a denial is offered the
/// open panel, and every other failure keeps its own message. TCC cannot be revoked from a
/// test, so the errors here are built by hand — which is the reason the classifier is a
/// pure function over `Error` rather than something that looks at the disk.
final class ProjectAccessTests: XCTestCase {

    func testCocoaNoPermissionIsADenial() {
        // Exactly what `Data(contentsOf:)` throws for a TCC-guarded project.json.
        let error = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError,
                            userInfo: [NSFilePathErrorKey: "/Users/tester/Documents/Theory/project.json"])
        XCTAssertEqual(error.code, 257, "the Cocoa code this classifier is written against")
        XCTAssertTrue(ProjectAccess.isPermissionDenied(error))
    }

    func testPosixDenialsAreDenials() {
        XCTAssertTrue(ProjectAccess.isPermissionDenied(
            NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES), userInfo: nil)))
        XCTAssertTrue(ProjectAccess.isPermissionDenied(
            NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM), userInfo: nil)))
    }

    func testDenialWrappedInAnotherErrorIsStillADenial() {
        // Foundation routinely hands the errno up under NSUnderlyingErrorKey rather than
        // restating it as a Cocoa code.
        let underlying = NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM), userInfo: nil)
        let wrapper = NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError,
                              userInfo: [NSUnderlyingErrorKey: underlying])
        XCTAssertTrue(ProjectAccess.isPermissionDenied(wrapper))
    }

    func testMissingFileIsNotADenial() {
        // A folder that was moved or deleted must keep its own message: no amount of
        // re-granting access brings it back.
        let error = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError, userInfo: nil)
        XCTAssertFalse(ProjectAccess.isPermissionDenied(error))
    }

    func testCorruptProjectFileIsNotADenial() throws {
        // The real thing: what JSONDecoder throws on a project.json that is not JSON.
        let corrupt = Data("{ not json".utf8)
        do {
            _ = try JSONDecoder().decode([String: String].self, from: corrupt)
            XCTFail("the fixture is supposed to be undecodable")
        } catch {
            XCTAssertFalse(ProjectAccess.isPermissionDenied(error))
        }
    }

    func testUnrelatedErrorsAreNotDenials() {
        XCTAssertFalse(ProjectAccess.isPermissionDenied(
            CoreError.notAProject(URL(fileURLWithPath: "/Users/tester/Documents/Theory"))))
        // The number alone means nothing — 257 in some other domain is some other error.
        XCTAssertFalse(ProjectAccess.isPermissionDenied(
            NSError(domain: "com.manifield.test", code: NSFileReadNoPermissionError, userInfo: nil)))
        XCTAssertFalse(ProjectAccess.isPermissionDenied(
            NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT), userInfo: nil)))
    }

    /// The catch path itself, walked with a genuinely unreadable file rather than a
    /// constructed error. POSIX permissions are not TCC, but they surface as the same
    /// Cocoa 257 the release-testing log recorded, so this checks the wiring from
    /// `openProject` through to the button the user is offered.
    @MainActor
    func testOpeningAnUnreadableProjectOffersTheFolderBack() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let meta = folder.appendingPathComponent("project.json")
        try Data(#"{"name":"Walled off"}"#.utf8).write(to: meta)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: meta.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: meta.path)
            try? FileManager.default.removeItem(at: folder)
        }
        if (try? Data(contentsOf: meta)) != nil {
            throw XCTSkip("this process reads files regardless of their permissions")
        }

        let state = AppState()
        state.openProject(at: folder)

        XCTAssertNil(state.store, "the open has to have failed for the rest to mean anything")
        XCTAssertEqual(state.openAccessDenial, folder,
                       "a denial must hand the alert the folder to re-choose")
        XCTAssertEqual(state.openError, ProjectAccess.permissionMessage(for: folder))
    }

    /// The other half of the rule: a folder that is simply not a project keeps its own
    /// message and is offered nothing, because re-choosing it would fix nothing.
    @MainActor
    func testOpeningAFolderThatIsNotAProjectOffersNothing() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let state = AppState()
        state.openProject(at: folder)

        XCTAssertNil(state.store)
        XCTAssertNotNil(state.openError)
        XCTAssertNil(state.openAccessDenial,
                     "granting access cannot conjure a project.json that was never there")
    }

    @MainActor
    func testANewErrorTakesAwayAStaleRecoveryOffer() {
        let state = AppState()
        state.openError = "denied"
        state.openAccessDenial = URL(fileURLWithPath: "/Users/tester/Documents/Theory")
        state.openError = "a corrupt file, which re-choosing the folder will not fix"
        XCTAssertNil(state.openAccessDenial)
    }

    func testPermissionMessageNamesTheFolderAndTheWayOut() {
        let message = ProjectAccess.permissionMessage(for:
            URL(fileURLWithPath: "/Users/tester/Documents/Sheaf Cohomology"))
        XCTAssertTrue(message.contains("Sheaf Cohomology"),
                      "the user has to know which folder is being refused")
        XCTAssertTrue(message.contains("Choose this folder"),
                      "the message has to say what the button will do")
        XCTAssertFalse(message.contains("project.json"),
                       "the raw Cocoa sentence names a file the user never chose")
    }
}
