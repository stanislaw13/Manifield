import Foundation

/// What the maintainer needs to know about the machine a report came from — and nothing
/// else. Every field here is about the *installation*: versions, architecture, whether the
/// pieces the app depends on were found. No project, no path, no key, no address.
public struct DiagnosticsSnapshot: Codable, Equatable, Sendable {

    /// The bits only the app can answer, handed in rather than reached for.
    ///
    /// This package deliberately depends on none of the others, so it cannot ask
    /// `CodexBinaryLocator` where the binary is or `PythonRuntime` whether the venv is
    /// built. The app knows; it passes the answers in. That is also what keeps the snapshot
    /// testable without a Codex install on the machine running the tests.
    public struct AppSupplied: Sendable, Equatable {
        public var codexBinaryFound: Bool
        /// The plan name if the Codex session is signed in and reported one. Never the
        /// account's email address.
        public var codexPlanType: String?
        public var pythonEnvironmentReady: Bool
        /// Provider *names* — "anthropic", "openai" — for providers that have a key
        /// configured. Never the keys, and never a prefix of one.
        public var configuredProviders: [String]

        public init(codexBinaryFound: Bool = false,
                    codexPlanType: String? = nil,
                    pythonEnvironmentReady: Bool = false,
                    configuredProviders: [String] = []) {
            self.codexBinaryFound = codexBinaryFound
            self.codexPlanType = codexPlanType
            self.pythonEnvironmentReady = pythonEnvironmentReady
            self.configuredProviders = configuredProviders
        }
    }

    public var appVersion: String
    public var buildNumber: String
    public var macOSVersion: String
    public var architecture: String

    /// True when macOS is running the app from a randomised read-only path under
    /// `/private/var/folders/.../AppTranslocation/`.
    ///
    /// Gatekeeper does this to a quarantined app the user launched straight out of a DMG
    /// or Downloads folder without moving it to /Applications first. The app still opens,
    /// which is what makes it so confusing: bundle-relative resource loading and
    /// subprocess spawning break, and this app does both — its KaTeX web assets live
    /// inside the bundle and it spawns Python. Every report says so up front, because
    /// "move it to /Applications and reopen" is the whole fix and no amount of reading a
    /// stack trace gets you there.
    public var isTranslocated: Bool

    public var codexBinaryFound: Bool
    public var codexPlanType: String?
    public var pythonEnvironmentReady: Bool
    public var configuredProviders: [String]
    public var capturedAt: Date

    public init(appVersion: String,
                buildNumber: String,
                macOSVersion: String,
                architecture: String,
                isTranslocated: Bool,
                codexBinaryFound: Bool,
                codexPlanType: String?,
                pythonEnvironmentReady: Bool,
                configuredProviders: [String],
                capturedAt: Date) {
        self.appVersion = appVersion
        self.buildNumber = buildNumber
        self.macOSVersion = macOSVersion
        self.architecture = architecture
        self.isTranslocated = isTranslocated
        self.codexBinaryFound = codexBinaryFound
        // Plan names ("ChatGPT Plus") have a space in them, and an identifier does not —
        // hyphenate before scrubbing so a legitimate plan name survives as itself rather
        // than collapsing to an opaque handle.
        self.codexPlanType = codexPlanType.map {
            Redactor.scrubIdentifier($0.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: " ", with: "-"), limit: 48)
        }
        self.pythonEnvironmentReady = pythonEnvironmentReady
        self.configuredProviders = configuredProviders.map { Redactor.scrubIdentifier($0, limit: 32) }
        self.capturedAt = capturedAt.truncatedToSecond
    }

    /// Reads this machine, then folds in what the app supplied.
    public static func current(_ supplied: AppSupplied,
                               bundle: Bundle = .main,
                               processInfo: ProcessInfo = .processInfo,
                               now: Date = Date()) -> DiagnosticsSnapshot {
        let info = bundle.infoDictionary ?? [:]
        return DiagnosticsSnapshot(
            appVersion: info["CFBundleShortVersionString"] as? String ?? "unknown",
            buildNumber: info["CFBundleVersion"] as? String ?? "unknown",
            macOSVersion: processInfo.operatingSystemVersionString,
            architecture: machineArchitecture(),
            isTranslocated: isTranslocated(bundlePath: bundle.bundlePath),
            codexBinaryFound: supplied.codexBinaryFound,
            codexPlanType: supplied.codexPlanType,
            pythonEnvironmentReady: supplied.pythonEnvironmentReady,
            configuredProviders: supplied.configuredProviders,
            capturedAt: now)
    }

    /// Takes the path rather than reading `Bundle.main`, so the condition this flag exists
    /// to catch can actually be tested.
    public static func isTranslocated(bundlePath: String) -> Bool {
        bundlePath.contains("/AppTranslocation/")
    }

    /// `arm64` or `x86_64` as the kernel reports it, with Rosetta called out — an Intel
    /// slice running under translation on Apple silicon behaves like neither.
    public static func machineArchitecture() -> String {
        var sysinfo = utsname()
        guard uname(&sysinfo) == 0 else { return "unknown" }
        let machine = withUnsafePointer(to: &sysinfo.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) { String(cString: $0) }
        }
        var translated: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("sysctl.proc_translated", &translated, &size, nil, 0) == 0, translated == 1 {
            return "\(machine) (Rosetta)"
        }
        return machine
    }

    // MARK: - JSON

    /// Pretty, key-sorted, ISO 8601 dates, slashes left alone.
    ///
    /// Readable is a requirement, not a nicety: this exact text is what the consent
    /// disclosure shows the tester before anything is sent, and an unreadable blob is not
    /// something anyone can meaningfully agree to.
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public func jsonData() throws -> Data { try Self.encoder().encode(self) }

    public func jsonString() throws -> String {
        String(data: try jsonData(), encoding: .utf8) ?? ""
    }
}
