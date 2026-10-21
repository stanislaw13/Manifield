# How Manifield works

The [README](../README.md) gives the overview. This page covers each part in more detail, including the parts that are experimental or incomplete.

- [Items and statuses](#items-and-statuses)
- [Figures](#figures)
- [Files kept with a project](#files-kept-with-a-project)
- [Literature sources](#literature-sources)
- [Chat and the proposal gate](#chat-and-the-proposal-gate)
- [Conjecture checking](#conjecture-checking)
- [Proving and reviewing](#proving-and-reviewing)
- [Research programs](#research-programs)
- [Sharing projects](#sharing-projects)
- [Math rendering](#math-rendering)
- [Privacy, diagnostics and feedback](#privacy-diagnostics-and-feedback)
- [Security notes](#security-notes)
- [Updates](#updates)

## Items and statuses

An item is one file in `theory/`: YAML frontmatter, then `## Statement`, and optionally `## Proof` and other sections. The frontmatter fields:

| Field | Meaning |
| --- | --- |
| `id` | Stable identifier, used in links and `depends_on` |
| `type` | `definition`, `axiom`, `theorem`, `lemma`, `proposition`, `corollary`, `conjecture`, `open-problem`, `remark`, `example`, `figure` and about twenty more (`claim`, `inequality`, `algorithm`, …) |
| `name` | Short human name, e.g. "Closed graph theorem" |
| `status` | Position on the trust ladder (below) |
| `depends_on` | Ids this item uses. A literature citation is written `source-slug:item-id` |
| `section` | Section slug; items are grouped by it in the library |
| `tags`, `order`, `source` | Optional: free tags, ordering within a section, the file it was imported from |

**The trust ladder:** `conjecture → tested → proof-drafted → reviewed-no-errors → human-approved → formally-verified`, plus `source` ("Cited literature") for established results taken from a reference, and `illustration` for figures. Agents may set the first four in every mode. *Human approved*, *Cited literature* and *Formally verified* are yours alone: a tool call that tries to set them is rejected with an explanation.

**Breakage propagation.** Downgrading an item offers to reset every dependent that currently claims review or approval back to *Proof drafted*, transitively.

**Research memory.** `memory.md` holds the project's working state: the goal, strategies tried and eliminated (with the reason), insights and next steps. Agents read it every turn and keep it current; you can edit it freely.

## Figures

A figure is a theory item like any other (`type: figure`, its own id, its own node in the graph), not something embedded inside a theorem. That matches how papers are written and keeps item files plain text: the picture lives in `figures/`, and the `.md` holds only the caption.

```yaml
---
id: fig-2-dominating-set
type: figure
name: A minimum 2-dominating set
status: illustration
depends_on: [def-k-domination, def-domination-number]   # what it illustrates
image: figures/fig-2-dominating-set.png
generator: figures/fig-2-dominating-set.py              # optional
---
## Caption
A graph on seven vertices with the 2-dominating set …
```

- **The figure names what it illustrates**, not the other way round. A theorem does not depend on a picture, and adding a figure should not mean editing the items it depicts.
- **`illustration` is off the trust ladder.** A figure asserts nothing that could be proved, so it never takes part in breakage propagation.
- **Item files never contain image markup.** The app builds the image from the `image:` field and serves it over an internal `manifield-figure://` scheme. That is the only image source the renderer accepts, so Markdown written by a model cannot make a page fetch anything.
- PNG and JPEG only for now.

Add one with **New Item → Figure**. The assistant draws with `create_visualization`, but those images land in a scratch run folder. `save_figure` promotes one into the library together with the script that drew it, through the usual confirmation. Agents cannot see images: `read_figure` returns the caption, what the figure illustrates and its generator source, and says so. That is why `save_figure` insists on a caption.

## Files kept with a project

The **Import** tab separates two things that cost different amounts:

- **Add files to the project** copies PDFs or `.tex` files in and extracts their text locally. It makes no model calls and uses no network.
- **Import into the library** runs the Organizer, which proposes definitions, theorems and lemmas for review. *Keep the original file in the project* (on by default) stores the document before the first model call, so a cancelled or failed run still leaves you the file.

Kept files appear in the sidebar's **Files** section. You can read them in the built-in PDF viewer, rename them, re-extract text after OCRing a scan, or hand them to the Organizer. On disk each is `documents/<slug>/`, holding `document.json`, the original, and a segmented `fulltext.md`.

Agents reach kept files through `search_documents` and `read_document`. Those tools are capped and search-first, so a long PDF cannot flood the context. They are also gated: the assistant asks with `request_document_access` (Allow/Deny in the chat), or you switch on *auto-allow reading full documents* in the composer. Background runs (research branches, the prover) can read documents only under that standing permission, because nobody is there to ask.

## Literature sources

A book or paper can be imported as a **source**: chunked chapter by chapter into citable items with the *Cited literature* status, plus the original PDF and an agent-friendly `fulltext.md` (headers and footers stripped, hyphenation undone, segmented per page, with the PDF outline as a table of contents). Processing into items is optional. Untick *Process into citable items* to add a long paper as a document-only source with no model calls.

Sources live in `~/Documents/Manifield/Sources/` and can be attached to several projects. Agents search them with `search_sources` and `read_source_item`, and cite them in `depends_on` as `source-slug:item-id`. They read a source's full text only with permission (per chat, or the standing *Full texts* toggle). Large imports run in the background with bounded parallelism, progress, and a cost warning before conversions longer than about ten chunks.

## Chat and the proposal gate

Prismo, the in-app assistant, works through tools: search and read items, notation, memory, documents and sources; propose edits; run Python; look up the OEIS. The composer has four modes:

| Mode | What the assistant may do |
| --- | --- |
| Ask | Read and discuss only |
| Plan | Draft a research target, then start it with your approval |
| Propose (default) | Everything, but every edit to the library waits for your approval |
| Auto | Edit the library directly, without approval |

The status rules apply in every mode, Auto included.

## Conjecture checking

Ask the assistant to check a conjecture. It writes a Python script (networkx, sympy, numpy, matplotlib) and runs it through `run_python`:

- **No network, writes confined to the run folder, a hard timeout** (a macOS seatbelt profile).
- **Every run is an artifact.** `artifacts/<timestamp>-<label>/` holds `script.py`, `stdout.txt`, `stderr.txt` and `meta.json`, the audit trail behind every "I tested N graphs" claim. The chat toolbar's *Artifacts* button opens the folder.
- Results are attached to items with `record_test_evidence`. Like every agent write, that is a proposal. A clean run moves `conjecture → tested`; a counterexample resets to `conjecture`.
- One-time setup: *Settings → General → Python environment → Set Up Environment* creates a shared virtualenv in `~/Library/Application Support/Manifield/pyenv`. It needs the network once, for pip.

## Proving and reviewing

The **Prover** drafts a proof grounded in your items and attached sources, and it must read what it cites. The **Reviewer** is prompted adversarially, can re-read every citation and run Python spot checks, and hunts for flaws. Issues go back to the Prover for revision, up to a round limit. Everything arrives as proposals. The best possible outcome is *Review found no errors*.

The Prover may use well-known theorems that are not in your project. Each one is proposed to you as a separate item (*Cited literature*, marked as model-cited and unverified) plus a citation in `depends_on`, and you accept or reject each. A stricter policy (project items and attached sources only, with anything else left as an explicit gap) exists in the code, but no setting exposes it yet.

At the moment the Prover is reached only as a task inside a research program. A direct entry point for a single item is planned.

## Research programs

**Start research… → Hand to the director** turns a goal into a theory item and freezes its statement and conventions. One persistent director conversation searches the library, dispatches work, reads reports, and decides what to do next. Work goes either to a *direct worker* (a focused conversation) or a *planned branch* (a task plan with dependencies, proof review and its own history), one to four at a time.

Claims that the goal is solved, or that it is wrong as stated, each get independent checks before they count. Unresolved proof gaps do not unlock dependent tasks. Reports may honestly contain no result.

Limits for tool calls, tokens, elapsed time and repair rounds are set under **Settings → Limits → Research** or per run, and they are saved with each program. **Cost is the open problem here:** runs on small problems have used hundreds of thousands of tokens, mostly input, and the cause is not yet established. Start with tight limits.

The program page has four tabs: Overview, Assignments, Evidence and Log. The Assignments tab's *Map* view is a placeholder for now.

## Sharing projects

*File → Export as Package…* writes a `.manifieldpack` file. It is a zip of the project's content (theory, notation, macros, figures, kept documents, metadata) without personal state (chats, run artifacts, the search index). *Import Package…* turns one back into a project, revalidating and reindexing it on the way in.

Because kept documents and figures travel inside the package, share one only when you have the right to redistribute that material. `project.json` can carry publishing metadata (`kind`, `authors`, `license`, `citation`), so a processed book or article can be passed on as a ready-to-attach source. The format is plain files in a zip on purpose: anything can generate it, and no app is required.

## Math rendering

- Custom macros live in the project's `macros.tex` (*Notation → Math Macros*). Importing a `.tex` file harvests its `\newcommand`, `\def` and `\DeclareMathOperator` definitions. An undefined macro shows as red raw LaTeX with the KaTeX error in a tooltip, never silently.
- Text-mode LaTeX in item bodies (`\emph`, `\textbf`, `enumerate`/`itemize`, `proof` environments) is converted to Markdown at render time, and `equation`/`align` environments render as display math.
- `\ref{…}` currently renders as the label key in parentheses, and `\cite[…]{…}` as the key without its locator.

## Privacy, diagnostics and feedback

The rule is consent: **the log and the diagnostics snapshot never contain project content.** That means no item text, statements, proofs, prompts or model output. In the code, `DiagnosticsValue` is the redaction rule: it has no case for free text, so content has no way into a log line, and `Redactor` scrubs what does get in (home paths, key-like strings) on the way to disk. Project paths are logged as opaque handles, because a folder name says what someone is working on.

*Help → Report a Bug…* opens the feedback form. *Show exactly what will be sent* displays the literal request body. Attaching the log is a separate toggle, the crash report is off unless you switch it on, and **Save to File…** / **Copy to Clipboard** work if sending fails. Reports go to `feedback.manifield.net`, a small Cloudflare Worker whose source is in [`Scripts/feedback-worker.js`](../Scripts/feedback-worker.js). Its defences are a rate limit, a size cap and a shape check, not a secret URL.

Logs rotate under `~/Library/Logs/Manifield/`.

## Security notes

- Rendered Markdown, including model output, is sanitized with DOMPurify before insertion. KaTeX renders with HTML output only.
- The app is **not** in the App Sandbox, because the Python checks need to spawn a local process. Release builds are signed with Developer ID under the hardened runtime and notarized.
- Codex runs with its own shell, file, write, browser, network, MCP and plugin tools disabled. The model reaches project text only through Manifield's tools, which enforce the chat's access grants. Manifield runs Codex with its own private `CODEX_HOME`, so it does not inherit your personal Codex configuration.
- API keys are stored in the macOS Keychain.

## Updates

Release builds update themselves with [Sparkle 2](https://sparkle-project.org). *Manifield → Check for Updates…* checks on demand, and *Settings → General → Updates* has the automatic-check toggle. Update packages are signed with an EdDSA key whose public half is in `project.yml`. The feed is at `updates.manifield.net/appcast.xml`, and the DMGs are on [GitHub Releases](https://github.com/stanislaw13/manifield-releases/releases).
