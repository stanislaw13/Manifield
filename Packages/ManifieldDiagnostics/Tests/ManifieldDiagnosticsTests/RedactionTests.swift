import XCTest
@testable import ManifieldDiagnostics

/// The redaction rule is the product's premise, not a nicety: these testers' projects hold
/// unpublished mathematics, and a log that leaks a statement is worse than no log at all.
final class RedactionTests: XCTestCase {

    func testHomeDirectoryBecomesTilde() {
        let text = "could not open /Users/ada/Documents/Riemann/project.json"
        XCTAssertEqual(Redactor.abbreviatingHome(text, home: "/Users/ada"),
                       "could not open ~/Documents/Riemann/project.json")
    }

    func testFirmlinkedHomePathIsAbbreviatedToo() {
        let text = "/System/Volumes/Data/Users/ada/Library/Logs"
        XCTAssertEqual(Redactor.abbreviatingHome(text, home: "/Users/ada"), "~/Library/Logs")
    }

    func testEmailAddressesAreRemoved() {
        let scrubbed = Redactor.redactingEmails("sign-in failed for ada.lovelace+chat@example.co.uk")
        XCTAssertFalse(scrubbed.contains("@example"))
        XCTAssertFalse(scrubbed.contains("ada.lovelace"))
        XCTAssertTrue(scrubbed.contains("<redacted:email>"))
    }

    func testApiKeyShapesAreRemoved() {
        let samples = [
            "401 for key sk-ant-api03-AbCdEfGhIjKlMnOpQrStUvWxYz0123456789",
            "Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.payload.signature",
            "x-goog key AIzaSyA1B2C3D4E5F6G7H8I9J0K1L2M3N4O5P6Q",
            "xai-abcdefghijklmnopqrstuvwxyz012345",
            "token ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        ]
        for sample in samples {
            let scrubbed = Redactor.redactingSecrets(sample)
            XCTAssertTrue(scrubbed.contains("<redacted:key>"), "not redacted: \(sample)")
            XCTAssertFalse(scrubbed.contains("ABCDEFGHIJKLMNOPQRSTUVWXYZ"), "leaked: \(scrubbed)")
        }
    }

    /// The generic "long opaque token" rule must not eat the one string the log exists to
    /// carry. Every id in this app is a UUID.
    func testUUIDsSurviveSecretRedaction() {
        let uuid = "9F86D081-884C-7D65-9A25-8A1C2E4F3B77"
        XCTAssertEqual(Redactor.redactingSecrets("plan \(uuid) started"), "plan \(uuid) started")
        XCTAssertEqual(Redactor.scrubIdentifier(uuid), uuid)
    }

    func testControlCharactersCollapseToSpaces() {
        let text = "line one\nline two\ttabbed\r\nthird"
        XCTAssertEqual(Redactor.singleLine(text), "line one line two tabbed third")
    }

    func testLengthCapBites() {
        let long = String(repeating: "x", count: 500)
        let capped = Redactor.capped(long, at: 100)
        XCTAssertEqual(capped.count, 101)
        XCTAssertTrue(capped.hasSuffix("…"))
    }

    /// `.id` and `.symbol` keep identifier characters and destroy everything else, so a
    /// statement handed to the wrong case arrives as punctuation rather than as prose.
    func testIdentifierScrubDestroysProse() {
        let statement = "Let f be holomorphic on the unit disc with f(0) = 0; then |f(z)| ≤ |z|."
        let scrubbed = Redactor.scrubIdentifier(statement)
        XCTAssertFalse(scrubbed.contains(" "))
        XCTAssertFalse(scrubbed.contains("holomorphic on"))
        XCTAssertLessThanOrEqual(scrubbed.count, 65)
    }

    func testHandleIsStableAndOpaque() {
        let path = "/Users/ada/Documents/Proof of the Riemann Hypothesis"
        let handle = Redactor.handle(path)
        XCTAssertEqual(handle, Redactor.handle(path))
        XCTAssertEqual(handle.count, 8)
        XCTAssertNotEqual(handle, Redactor.handle(path + "2"))
        XCTAssertFalse(handle.lowercased().contains("riemann"))
    }

    /// The full pass, on the nastiest realistic input: an error description that has picked
    /// up a home path, the account address and a key on its way up the stack. The project
    /// path is the one thing here that must not survive even abbreviated — see
    /// `testProjectPathsUnderHomeAreRedacted` below for the bug this used to codify.
    func testFullScrubHandlesEverythingAtOnce() {
        let raw = """
        POST https://api.example.com failed for ada@example.com
        using sk-ant-api03-ZZZZYYYYXXXXWWWWVVVVUUUUTTTTSSSS
        while reading /Users/ada/Documents/Secret Theory/item.md
        """
        let scrubbed = Redactor.scrub(raw, limit: 400, home: "/Users/ada")
        XCTAssertFalse(scrubbed.contains("ada@example.com"))
        XCTAssertFalse(scrubbed.contains("sk-ant-api03"))
        XCTAssertFalse(scrubbed.contains("/Users/ada"))
        XCTAssertFalse(scrubbed.contains("\n"))
        XCTAssertFalse(scrubbed.contains("Secret Theory"))
        XCTAssertTrue(scrubbed.contains("<redacted:path>"), scrubbed)
    }

    // MARK: - Paths under the home directory

    /// The leak this whole fix exists for: `CoreError.notAProject` embeds `url.path`
    /// verbatim, so opening the wrong folder writes the folder's name — the tester's own
    /// project title — straight into `error=`. `abbreviatingHome` alone does not catch
    /// this, because it only ever swaps the home prefix for `~` and has no opinion about
    /// what comes after. This must be caught by the time `scrub` is done.
    func testProjectPathsUnderHomeAreRedacted() {
        let raw = "Not a Manifield project: /Users/ada/Documents/Manifield/Counterexamples to the Doubling Conjecture"
        let scrubbed = Redactor.scrub(raw, limit: 400, home: "/Users/ada")
        XCTAssertFalse(scrubbed.contains("Doubling Conjecture"))
        XCTAssertFalse(scrubbed.contains("Counterexamples"))
        XCTAssertTrue(scrubbed.contains("<redacted:path>"), scrubbed)
    }

    /// An item's filename is a slug of its name — `conj-gamma2-doubling` is short for
    /// "the gamma-2 doubling conjecture" — so it leaks exactly what the folder around it
    /// does, and must be redacted the same way.
    func testTheoryItemFilenamesUnderHomeAreRedacted() {
        let raw = "The file \"/Users/ada/Documents/Manifield/Proj/theory/conj-gamma2-doubling.md\" couldn't be opened."
        let scrubbed = Redactor.scrub(raw, limit: 400, home: "/Users/ada")
        XCTAssertFalse(scrubbed.contains("gamma2-doubling"))
        XCTAssertTrue(scrubbed.contains("<redacted:path>"), scrubbed)
        // The quotes and the rest of the sentence are not part of the leak and should stay.
        XCTAssertTrue(scrubbed.contains("\"<redacted:path>\" couldn't be opened."), scrubbed)
    }

    /// Every fixed candidate `CodexBinaryLocator` tries under `~`, plus the app's own
    /// Application Support / Logs / Caches locations. These are the maintainer's only tool
    /// for diagnosing "codex binary not found" and the app's Python setup, so they must come
    /// through `scrub` byte-for-byte.
    func testAppOwnedAndCodexCandidatePathsSurviveIntact() {
        let survivors = [
            "~/Library/Application Support/Manifield/codex-home/config.toml",
            "~/Library/Application Support/Manifield/pyenv/bin/python3",
            "~/Library/Logs/Manifield/manifield-2026-09-18.log",
            "~/Library/Caches/com.manifield.app/tmp",
            "~/.codex/bin/codex",
            "~/Applications/ChatGPT.app/Contents/Resources/codex",
            "~/.npm-global/bin/codex",
            "~/.volta/bin/codex",
        ]
        for path in survivors {
            let raw = "checked \(path.replacingOccurrences(of: "~", with: "/Users/ada")) — not executable"
            let scrubbed = Redactor.scrub(raw, limit: 400, home: "/Users/ada")
            XCTAssertTrue(scrubbed.contains(path), "did not survive: \(path) -> \(scrubbed)")
            XCTAssertFalse(scrubbed.contains("<redacted:path>"), "over-redacted: \(path) -> \(scrubbed)")
        }
    }

    /// Paths entirely outside the home directory are never user-named — a bundled app, a
    /// Homebrew prefix, a global npm install — so they need no redaction at all and are
    /// untouched by `abbreviatingHome`, `redactingUserPaths`, or anything else in `scrub`.
    func testPathsOutsideHomeAreNeverRedacted() {
        let survivors = [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "/usr/local/lib/node_modules/@openai/codex/bin/codex",
        ]
        for path in survivors {
            let scrubbed = Redactor.scrub("codex candidate: \(path)", limit: 400, home: "/Users/ada")
            XCTAssertTrue(scrubbed.contains(path), "did not survive: \(path) -> \(scrubbed)")
        }
    }
}
