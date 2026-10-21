import Foundation
import ManifieldCore
import ManifieldSandbox

/// Phase-2 conjecture-checker tools: sandboxed Python execution with artifacts,
/// OEIS lookup, and evidence recording. Evidence funnels through the proposal flow
/// (the user confirms) unless `applyDirect` is supplied — the auto-mode research path,
/// where a pending proposal is a human gate the run was told not to have.
public enum SandboxTools {

    public static func tools(
        sandbox: PythonSandbox,
        store: ProjectStore,
        onProposal: @escaping @Sendable (TheoryProposal) -> Void,
        applyDirect: (@Sendable (TheoryProposal) async throws -> String)? = nil
    ) -> [AgentTool] {
        computeTools(sandbox: sandbox)
            + [RecordTestEvidenceTool(store: store, onProposal: onProposal, applyDirect: applyDirect)]
    }

    /// Pure computation tools (no proposal side-effects) — given to the prover/reviewer.
    public static func computeTools(sandbox: PythonSandbox) -> [AgentTool] {
        [RunPythonTool(sandbox: sandbox), OEISLookupTool()]
    }
}

struct RunPythonTool: AgentTool {
    let sandbox: PythonSandbox

    /// Both numbers come from the user's Limits settings, so the prompt has to quote them
    /// rather than the old hard-coded 120/600 — a model told the wrong ceiling asks for
    /// timeouts that get silently clamped, and then misreads the kill as its script hanging.
    private var defaultSeconds: Int { Int(sandbox.limits.defaultTimeout) }
    private var maxSeconds: Int { Int(sandbox.limits.maxTimeout) }

    var spec: ToolSpec {
        ToolSpec(
            name: "run_python",
            description: """
            Execute a Python 3 script in a local sandbox: NO network access, file writes \
            confined to the run folder, hard timeout. networkx, sympy, numpy and matplotlib are \
            available once the user has set up the environment in Settings. Print your \
            findings to stdout. The script and its full output are automatically saved as \
            an artifact in the project — cite the artifact name when reporting results. \
            Use for counterexample searches, verifying computations, and testing claims on \
            exhaustive small cases (prefer exhaustive enumeration over random sampling). \
            Estimate the wall-clock runtime honestly — the user sees it before the run; \
            when it exceeds the \(defaultSeconds)s default timeout, also set timeout_seconds.
            """,
            inputSchemaJSON: #"{"type":"object","properties":{"script":{"type":"string","description":"Complete Python 3 script"},"label":{"type":"string","description":"Short kebab-case label for the artifact folder, e.g. check-doubling-conjecture"},"estimated_runtime_seconds":{"type":"integer","description":"Your honest estimate of the script's wall-clock runtime in seconds (shown to the user before the run)"},"timeout_seconds":{"type":"integer","description":"Max runtime in seconds (default \#(defaultSeconds), max \#(maxSeconds))"}},"required":["script","label","estimated_runtime_seconds"]}"#
        )
    }

    func execute(inputJSON: String) async throws -> String {
        let input = jsonObject(inputJSON)
        guard let script = input["script"] as? String, !script.isEmpty else {
            throw AgentError.badResponse("missing 'script'")
        }
        let label = input["label"] as? String ?? "run"
        // Without an explicit timeout, leave headroom above the model's own estimate
        // so honestly-estimated long runs aren't killed at the configured default.
        let estimate = input["estimated_runtime_seconds"] as? Double
        let defaultTimeout = max(sandbox.limits.defaultTimeout, (estimate ?? 0) * 2)
        let timeout = min(sandbox.limits.maxTimeout,
                          max(1.0, (input["timeout_seconds"] as? Double) ?? defaultTimeout))

        let result = try await sandbox.run(script: script, label: label, timeout: timeout)

        var flags: [String] = []
        flags.append(result.sandboxed ? "sandboxed (no network)" : "NOT sandboxed")
        flags.append(result.packagesAvailable
            ? "math packages available"
            : "WARNING: math packages NOT installed — standard library only. Ask the user to run Set Up Python Environment in Settings.")
        if result.timedOut { flags.append("TIMED OUT after \(Int(timeout))s") }
        if result.stdoutTruncated { flags.append("stdout truncated") }

        var text = """
        exit code: \(result.exitCode) in \(String(format: "%.1f", result.duration))s [\(flags.joined(separator: "; "))]
        artifact: artifacts/\(result.artifactName)/
        """
        text += "\n--- stdout ---\n" + (result.stdout.isEmpty ? "(empty)" : String(result.stdout.suffix(12_000)))
        if !result.stderr.isEmpty {
            text += "\n--- stderr ---\n" + String(result.stderr.suffix(3_000))
        }
        return text
    }
}

struct OEISLookupTool: AgentTool {

    /// OEIS asks clients to identify themselves; same shape as the feedback sender's
    /// `Manifield-Feedback/1`, with the site so a maintainer is reachable from a server log.
    static let userAgent = "Manifield/1 (+https://manifield.net)"

    var spec: ToolSpec {
        ToolSpec(
            name: "oeis_lookup",
            description: "Search the On-Line Encyclopedia of Integer Sequences. Query with comma-separated terms (e.g. \"1, 2, 4, 8, 16\") or keywords. Returns the top matching sequences with their A-numbers.",
            inputSchemaJSON: #"{"type":"object","properties":{"query":{"type":"string","description":"Sequence terms or keywords"}},"required":["query"]}"#
        )
    }

    func execute(inputJSON: String) async throws -> String {
        guard let query = jsonObject(inputJSON)["query"] as? String, !query.isEmpty else {
            throw AgentError.badResponse("missing 'query'")
        }
        var components = URLComponents(string: "https://oeis.org/search")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "fmt", value: "json")
        ]
        var request = URLRequest(url: components.url!)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw AgentError.http((response as? HTTPURLResponse)?.statusCode ?? 0, "OEIS request failed")
        }
        return Self.format(data: data, query: query)
    }

    /// Parses the OEIS JSON response (either `{"results": [...]}` or a bare array).
    static func format(data: Data, query: String) -> String {
        let json = try? JSONSerialization.jsonObject(with: data)
        let results: [[String: Any]]
        if let object = json as? [String: Any] {
            results = object["results"] as? [[String: Any]] ?? []
        } else {
            results = json as? [[String: Any]] ?? []
        }
        guard !results.isEmpty else { return "No OEIS matches for '\(query)'." }
        // OEIS names and terms are CC BY-SA 4.0 and its EULA asks for credit plus a URL. The
        // credit belongs in the tool's own output, not in a notices file: this content is fetched
        // at runtime, so the only place the attribution can reach it is the model's context,
        // alongside the data it credits and in front of whatever gets written from it.
        return results.prefix(5).compactMap { entry in
            guard let number = entry["number"] as? Int else { return nil }
            let name = entry["name"] as? String ?? ""
            let terms = (entry["data"] as? String ?? "").split(separator: ",").prefix(12).joined(separator: ", ")
            return String(
                format: "A%06d — %@\n  %@…\n  Source: The On-Line Encyclopedia of Integer Sequences, https://oeis.org/A%06d (CC BY-SA 4.0).",
                number, name, terms, number)
        }.joined(separator: "\n")
    }
}

struct RecordTestEvidenceTool: AgentTool {
    let store: ProjectStore
    let onProposal: @Sendable (TheoryProposal) -> Void
    /// Auto-mode path: the update lands immediately (evidence and the tested/conjecture
    /// statuses sit inside the agent-settable slice of the trust ladder). Nil keeps the
    /// confirm-every-write proposal flow.
    let applyDirect: (@Sendable (TheoryProposal) async throws -> String)?

    init(store: ProjectStore,
         onProposal: @escaping @Sendable (TheoryProposal) -> Void,
         applyDirect: (@Sendable (TheoryProposal) async throws -> String)? = nil) {
        self.store = store
        self.onProposal = onProposal
        self.applyDirect = applyDirect
    }

    var spec: ToolSpec {
        ToolSpec(
            name: "record_test_evidence",
            description: """
            Attach the outcome of a computational check to a theory item. \
            \(applyDirect == nil
                ? "Creates an update proposal (the user confirms it): an"
                : "The update is applied immediately (this run is in auto mode): an") \
            entry is appended to the item's \
            '## Evidence' section with the artifact reference, and the trust status is \
            adjusted (conjecture → tested on a clean no-counterexample run; a found \
            counterexample resets status to conjecture). Describe EXACTLY what was tested — \
            object class, generation method, count.
            """,
            inputSchemaJSON: #"{"type":"object","properties":{"id":{"type":"string","description":"Theory item id"},"verdict":{"type":"string","enum":["no-counterexample-found","counterexample-found"],"description":"Outcome of the check"},"summary":{"type":"string","description":"Precise description: what class of objects, how generated, how many, what was checked"},"artifact":{"type":"string","description":"Artifact folder name from run_python, e.g. 20260707-101500-check-doubling"},"counterexample":{"type":"string","description":"Full description of the counterexample (edge list etc.), when found"}},"required":["id","verdict","summary","artifact"]}"#
        )
    }

    func execute(inputJSON: String) async throws -> String {
        let input = jsonObject(inputJSON)
        guard let id = input["id"] as? String, var item = store.item(id: id) else {
            throw CoreError.itemNotFound(input["id"] as? String ?? "?")
        }
        guard let verdict = input["verdict"] as? String,
              ["no-counterexample-found", "counterexample-found"].contains(verdict) else {
            throw AgentError.badResponse("verdict must be no-counterexample-found or counterexample-found")
        }
        guard let summary = input["summary"] as? String, !summary.isEmpty,
              let artifact = input["artifact"] as? String, !artifact.isEmpty else {
            throw AgentError.badResponse("missing 'summary' or 'artifact'")
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        var entry = "- \(dateFormatter.string(from: Date())) — **\(verdict)**: \(summary) (artifact: `artifacts/\(artifact)`)"
        if let counterexample = input["counterexample"] as? String, !counterexample.isEmpty {
            entry += "\n  - Counterexample: \(counterexample)"
        }

        if item.body.contains("## Evidence") {
            item.body += "\n" + entry
        } else {
            item.body += "\n\n## Evidence\n" + entry
        }

        if verdict == "counterexample-found" {
            item.status = .conjecture
        } else if item.status == .conjecture {
            item.status = .tested
        }

        if let applyDirect {
            _ = try await applyDirect(TheoryProposal(action: .update, item: item))
            return "Evidence recorded on '\(id)' — status is now '\(item.status.rawValue)'."
        }
        onProposal(TheoryProposal(action: .update, item: item))
        return "Evidence proposal for '\(id)' recorded and shown to the user for confirmation (status would become '\(item.status.rawValue)'). Do not assume it was accepted."
    }
}
