# Contributing to Manifield

Thanks for looking. Bug reports, mathematics that breaks the app, and code are all welcome.

## Reporting problems

Open an issue. The most useful reports show the app doing the wrong thing with real mathematics:

- LaTeX that renders wrongly or not at all (include the snippet and your macros)
- an import that gets the structure wrong: missing items, wrong dependencies, statuses that claim too much
- a graph that misleads
- an agent that overstates what it did

If the problem involves unpublished work, a minimal made-up example that shows the same behaviour is enough. Nobody should have to share their research to report a bug. *Help → Report a Bug…* in the app sends a report with an optional redacted log, and it never includes project content.

## Building

You need Xcode 26 and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`). `project.yml` is the source of truth. Regenerate the Xcode project after pulling or after changing it:

```bash
xcodegen generate
open Manifield.xcodeproj
```

**Signing.** `project.yml` carries the maintainer's team id. To run the app from Xcode, select the Manifield target, then under *Signing & Capabilities* pick your own team or *Sign to Run Locally*. If Xcode refuses the bundle identifier, change `PRODUCT_BUNDLE_IDENTIFIER` locally and don't commit it. Note that a build with the default identifier `com.manifield.app` shares its settings with an installed release.

A headless build needs no signing identity. This is what CI runs:

```bash
xcodebuild -project Manifield.xcodeproj -scheme Manifield -configuration Debug \
  CODE_SIGNING_ALLOWED=NO build
```

## Tests

Four Swift packages have their own test suites, and the app target has a fifth (`ManifieldTests`) for anything that needs app state:

```bash
(cd Packages/ManifieldCore && swift test)
(cd Packages/ManifieldAgents && swift test)
(cd Packages/ManifieldSandbox && swift test)
(cd Packages/ManifieldDiagnostics && swift test)
xcodebuild -project Manifield.xcodeproj -scheme Manifield \
  -destination 'platform=macOS' test
```

The app tests load into the app, so they need the same signing setup as running it. Tests that call real model APIs and spend tokens are opt-in: they skip unless their `MANIFIELD_LIVE_*` environment variables are set (with a `TEST_RUNNER_` prefix when you run them through `xcodebuild`). CI runs the package tests and a headless build on every pull request.

## Code layout

```
Manifield/                     the SwiftUI app: views, controllers, web-view bridges
  Sources/
  Resources/web/               math.html, chat.html, graph.html, render.js, and vendored
                               KaTeX, marked, DOMPurify and d3-force
  Tests/
Packages/ManifieldCore/        models, frontmatter parser, project store, FTS5 search index,
                               dependency graph, sources and documents
Packages/ManifieldAgents/      LLM providers (Anthropic, OpenAI-compatible, Codex app-server),
                               the agent loop, tools, prompts, Organizer, Prover/Reviewer,
                               research programs, Keychain
Packages/ManifieldSandbox/     the seatbelt profile and the shared Python virtualenv
Packages/ManifieldDiagnostics/ logging, redaction, the diagnostics snapshot, feedback transport.
                               Depends on none of the others, on purpose
Scripts/                       web-asset fetching, Sparkle helper signing, the feedback Worker
examples/                      example projects
```

Prompts for the agents live in `Packages/ManifieldAgents/Sources/ManifieldAgents/Prompts/` as Markdown.

The web assets are pinned copies. To refresh them, run `bash Scripts/fetch_web_assets.sh`, then update `THIRD_PARTY_NOTICES.md` if a version changed.

## Rules the code relies on

These are deliberate. A change that breaks one needs a good reason in the pull request.

1. **Plain files are the source of truth.** Anything that matters to the mathematics lives in the project folder as Markdown, YAML or JSON. The index and the graph are derived and rebuildable.
2. **Agents propose, the human decides.** Library writes go through the proposal gate, except in Auto mode, which the user switches on explicitly. Agents can set `conjecture`, `tested`, `proof-drafted` and `reviewed-no-errors` (`TheoryWritePolicy.agentSettableStatuses`). The rest of the ladder belongs to the user in every mode.
3. **Never claim more than the evidence.** UI text, prompts and docs say *Review found no errors*, never "correct" or "verified", unless a proof assistant was involved.
4. **No project content in logs or diagnostics.** Log through `DiagnosticsValue`. It has no case for free text on purpose: don't add one, and don't log item text, prompts, model output or project paths (use `.handle`).
5. **Useful without AI.** Core organizing features must keep working with no model configured.

## Licence

Manifield is GPLv3. By contributing you agree that your contribution is licensed under the same terms.
