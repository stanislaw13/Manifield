import Foundation

/// The last line of defence before anything is written to disk or sent anywhere.
///
/// The log API's *shape* is what actually keeps research out of the log — event names and
/// field keys are `StaticString`, so they cannot be built from runtime data, and values go
/// through `DiagnosticsValue`, which has no free-text case. But two of those cases do carry
/// runtime strings (`.errorDescription`, `.id`), and an error description is exactly the
/// kind of thing that quietly contains a URL with a key in it, a home path, or the address
/// the user signed in with. Everything string-shaped is scrubbed here on the way out,
/// whatever route it took to get here.
public enum Redactor {

    /// Stands in for whatever was removed. Deliberately conspicuous: a report that reads
    /// `<redacted:key>` tells the maintainer the redaction fired, which a silently emptied
    /// field would not.
    public static func placeholder(_ what: String) -> String { "<redacted:\(what)>" }

    /// Replaces the user's home directory with `~`.
    ///
    /// Home paths are not just noise: `/Users/<name>/` is the tester's real name, and the
    /// folders under it are their project titles. Takes the home directory as a parameter
    /// so tests do not depend on whose machine they run on.
    ///
    /// This only ever swaps the home directory prefix for `~` — it says nothing about what
    /// follows, and what follows is where the actual leak lives. `~/Documents/Manifield/<a
    /// theorem's working title>` survives this step exactly as intact as `~/.codex/bin/codex`
    /// does. `redactingUserPaths`, always run after this in `scrub`/`scrubMultiline`, is what
    /// tells those two apart.
    public static func abbreviatingHome(_ text: String, home: String = NSHomeDirectory()) -> String {
        guard !home.isEmpty, home != "/" else { return text }
        let trimmed = home.hasSuffix("/") ? String(home.dropLast()) : home
        // The realpath form too: NSHomeDirectory() reports /Users/x while a URL that has
        // been through the file system may carry /System/Volumes/Data/Users/x.
        // Longest first: replacing the bare path before the firmlinked one would leave
        // `/System/Volumes/Data~` behind.
        let variants = ["/System/Volumes/Data" + trimmed, trimmed]
        var result = text
        for variant in variants where !variant.isEmpty {
            result = result.replacingOccurrences(of: variant, with: "~")
        }
        return result
    }

    /// Fixed, app-owned directories under `~`. Never a project, a source, or an item — only
    /// places this app itself created and named, which is exactly what makes them safe to
    /// keep and useful to keep: `codex-home` and `pyenv` under Application Support explain
    /// environment failures, and a maintainer reading the log has no other way to tell a
    /// Codex install problem from a Python one.
    private static let safeHomeDirectoryPrefixes = [
        "~/Library/Application Support/Manifield",
        "~/Library/Logs/Manifield",
        "~/Library/Caches",
    ]

    /// The fixed candidate paths `CodexBinaryLocator` tries under `~`. Not a prefix list —
    /// each is one specific binary — because the ones from `$PATH` are not on this list:
    /// an arbitrary `PATH` entry under `~` is not a location the app chose, so it gets no
    /// special treatment and is redacted like any other path the user controls.
    private static let safeHomeExactPaths: Set<String> = [
        "~/.codex/bin/codex",
        "~/Applications/ChatGPT.app/Contents/Resources/codex",
        "~/.npm-global/bin/codex",
        "~/.volta/bin/codex",
    ]

    /// A `~`-rooted path candidate: `~` then everything up to whichever comes first — the
    /// start of *another* `~`-rooted path, a quote character, a newline, or the end of the
    /// string. A path here can contain spaces — a project folder is the tester's own title
    /// for their work — so a space cannot be the boundary; these four can, because they are
    /// how the paths this app actually produces are bounded: Cocoa's own file-not-found text
    /// wraps a path in quotes, `CoreError.notAProject` leaves it as the plain remainder of
    /// the string, and a message that lists more than one candidate (`"tried ~/a, ~/b"`)
    /// separates them with nothing more reliable than a comma — which is why this cannot
    /// stop at the first path's own trailing punctuation and must instead look ahead for
    /// where the *next* one starts. Without that lookahead, one safe path followed by one
    /// unsafe path in the same unquoted sentence would fuse into a single candidate, and a
    /// safe *prefix* match on the first half would wave the unsafe second half through too.
    private static let homeRelativePathPattern = try! NSRegularExpression(
        pattern: #"~/[^"\n]*?(?=~/|"|\n|$)"#)

    /// Characters that continue a path or a filename, for telling "this fixed candidate,
    /// exactly" from "this fixed candidate's name, followed by more of the same word".
    /// Deliberately excludes `.`: none of `safeHomeExactPaths` ends in an extension, so a
    /// period straight after one is sentence punctuation ("...tried ~/.codex/bin/codex.")
    /// rather than a continuation into some other, differently-named file.
    private static func continuesAPathComponent(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_" || character == "-" || character == "/"
    }

    /// How many of a `~`-rooted candidate's leading characters belong to one of the app's
    /// own fixed locations — `nil` when none of them do.
    ///
    /// A directory (Application Support/Manifield, Logs/Manifield, Caches) is safe for its
    /// whole length, whatever is under it: `codex-home` and `pyenv` live there, and a
    /// maintainer needs both to tell a Codex install problem from a Python one. A specific
    /// binary (one of `CodexBinaryLocator`'s candidates) is safe only up to its own length,
    /// and only when `continuesAPathComponent` says nothing longer is being named —
    /// `~/.codex/bin/codex-helper` is a different program, not the one this app looks for.
    /// Either way, once the safe portion is found, whatever trails after it in the same
    /// candidate (a comma, a closing sentence, another already-safe path) is of no interest
    /// here and is left exactly as it was.
    private static func safePrefixLength(of candidate: String) -> Int? {
        for prefix in safeHomeDirectoryPrefixes where candidate == prefix || candidate.hasPrefix(prefix + "/") {
            return candidate.count
        }
        for exact in safeHomeExactPaths where candidate.hasPrefix(exact) {
            if candidate.count == exact.count { return exact.count }
            let next = candidate[candidate.index(candidate.startIndex, offsetBy: exact.count)]
            if !continuesAPathComponent(next) { return exact.count }
        }
        return nil
    }

    /// Redacts every `~`-rooted path that is not one of the app's own fixed locations.
    ///
    /// This is the actual privacy boundary for filesystem paths, not `abbreviatingHome`.
    /// Nothing outside `~` is touched here — nothing outside the user's home directory is
    /// user-named, so a bundled-app path or a Homebrew prefix carries no risk — but almost
    /// everything under `~` is the tester's own naming: a project folder is named after
    /// what it studies, and an item file is a slug of an item's name (`theory/conj-gamma2-
    /// doubling.md` says exactly as much about the mathematics as the folder around it
    /// does). A short allowlist of fixed, app-owned exceptions survives because a
    /// maintainer needs them to diagnose the app's most common failure; everything else
    /// becomes `Redactor.placeholder("path")`, wholesale — same reasoning as
    /// `scrubIdentifier`: a redaction that keeps the shape of what it removed is not a
    /// redaction.
    static func redactingUserPaths(_ text: String) -> String {
        let matches = homeRelativePathPattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard !matches.isEmpty else { return text }
        var result = ""
        var cursor = text.startIndex
        for match in matches {
            guard let range = Range(match.range, in: text) else { continue }
            result += text[cursor..<range.lowerBound]
            let candidate = String(text[range])
            // Safe means the *whole* candidate is kept, trailing prose and all: it was
            // never redaction-worthy to begin with, so there is nothing to cut out of it.
            result += safePrefixLength(of: candidate) != nil ? candidate : placeholder("path")
            cursor = range.upperBound
        }
        result += text[cursor...]
        return result
    }

    /// Email addresses. The tester's own address is the one identifier the log is most
    /// likely to pick up by accident — the Codex account is signed in with it, so it turns
    /// up in sign-in errors — and it is named explicitly in the redaction rule.
    private static let emailPattern = try! NSRegularExpression(
        pattern: #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#)

    /// Credential-shaped runs. Covers the published key formats (`sk-…`, `sk-ant-…`,
    /// `AIza…`, `xai-…`, `ghp_…`, `nvapi-…`) plus a generic long opaque token, and the
    /// `Authorization: Bearer …` header an HTTP error is apt to echo back.
    private static let secretPatterns: [NSRegularExpression] = [
        #"(?i)bearer\s+[A-Za-z0-9._\-]{8,}"#,
        #"\b(?:sk|pk|rk)-[A-Za-z0-9._\-]{12,}"#,
        #"\bAIza[A-Za-z0-9._\-]{20,}"#,
        #"\b(?:xai|nvapi|gsk|glm)-[A-Za-z0-9._\-]{12,}"#,
        #"\b(?:ghp|gho|ghs|github_pat)_[A-Za-z0-9_]{16,}"#,
        // A bare high-entropy token: 32+ characters of key alphabet with no word breaks.
        // Long enough not to swallow ordinary identifiers, which are the other thing the
        // log legitimately carries — with UUIDs excluded outright, because every id in this
        // app is one and they are the whole reason the log is worth reading.
        #"\b(?!\#(uuidShape)\b)[A-Za-z0-9_\-]{32,}\b"#
    ].map { try! NSRegularExpression(pattern: $0) }

    private static let uuidShape = #"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"#

    public static func redactingEmails(_ text: String) -> String {
        replacing(emailPattern, in: text, with: placeholder("email"))
    }

    public static func redactingSecrets(_ text: String) -> String {
        secretPatterns.reduce(text) { replacing($1, in: $0, with: placeholder("key")) }
    }

    private static func replacing(_ regex: NSRegularExpression, in text: String, with replacement: String) -> String {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: range,
                                              withTemplate: NSRegularExpression.escapedTemplate(for: replacement))
    }

    /// Flattens newlines, tabs and other control characters to single spaces.
    ///
    /// Not cosmetic. The log is one record per line, and a value containing a newline would
    /// forge a second record — which is both a parsing problem and the shape a multi-line
    /// proof would arrive in if one ever reached a value by mistake.
    public static func singleLine(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        var lastWasSpace = false
        for scalar in text.unicodeScalars {
            let isBreak = CharacterSet.whitespacesAndNewlines.contains(scalar)
                || CharacterSet.controlCharacters.contains(scalar)
            if isBreak {
                if !lastWasSpace { out.append(" ") }
                lastWasSpace = true
            } else {
                out.unicodeScalars.append(scalar)
                lastWasSpace = false
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// Hard length cap, marked when it bites.
    ///
    /// The cap is the safety net under every judgement call above it: even if some future
    /// call site hands an error description that turns out to be a whole model response,
    /// what lands in the log is a sentence of it, not the response.
    public static func capped(_ text: String, at limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "…"
    }

    /// The full pass applied to every runtime string the log or a report carries.
    public static func scrub(_ text: String, limit: Int, home: String = NSHomeDirectory()) -> String {
        var result = singleLine(text)
        result = abbreviatingHome(result, home: home)
        result = redactingUserPaths(result)
        result = redactingEmails(result)
        result = redactingSecrets(result)
        return capped(result, at: limit)
    }

    /// The same pass for text that is allowed to keep its line breaks — the log tail and a
    /// crash report, which are only readable as many lines.
    public static func scrubMultiline(_ text: String, limit: Int, home: String = NSHomeDirectory()) -> String {
        var result = abbreviatingHome(text, home: home)
        result = redactingUserPaths(result)
        result = redactingEmails(result)
        result = redactingSecrets(result)
        return capped(result, at: limit)
    }

    /// What an identifier may be made of. A value containing anything else is not one.
    private static let identifierCharacters = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:-")

    /// The pass for `DiagnosticsValue.id` and `.symbol`.
    ///
    /// All-or-nothing, and deliberately so. An earlier version replaced the offending
    /// characters and kept the rest — which turned a theorem statement into the same
    /// statement with underscores for spaces, every word still legible. Scrubbing that
    /// preserves vocabulary is not redaction.
    ///
    /// So: a value that is actually identifier-shaped (a UUID, a slug, a provider name)
    /// passes through untouched, and anything else is replaced wholesale by an opaque
    /// handle. Two lines about the same wrong-but-consistent value still tie together, and
    /// nothing readable survives.
    public static func scrubIdentifier(_ text: String, limit: Int = 64) -> String {
        guard !text.isEmpty else { return "" }
        let wellFormed = text.count <= limit
            && text.unicodeScalars.allSatisfy { identifierCharacters.contains($0) }
        return wellFormed ? text : "<opaque:\(handle(text))>"
    }

    /// Reduces a string to a short stable handle that cannot be read back.
    ///
    /// For values that are useful only as "the same one as last time" — above all a project
    /// folder path, whose every component is the tester's own naming of unpublished work.
    /// FNV-1a rather than a crypto hash: this is a correlation handle, not a commitment, and
    /// it keeps the package free of any import beyond Foundation.
    public static func handle(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in Array(text.utf8) {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return String(format: "%08x", UInt32(truncatingIfNeeded: hash >> 32))
    }
}

extension Date {
    /// Dropped to whole seconds.
    ///
    /// Both JSON shapes here carry ISO 8601 to the second, so a value that remembers more
    /// than that is a value that stops being equal to itself the moment it is written and
    /// read back. Truncating at the point of capture keeps a report and its file identical.
    var truncatedToSecond: Date {
        Date(timeIntervalSince1970: timeIntervalSince1970.rounded(.down))
    }
}
