# Example: Baire category and the three big theorems

A small Manifield project you can open and look around in, with or without AI.

These are working notes in the style of a student notebook on Baire category and classical functional analysis: Baire's theorem, uniform boundedness, open mapping, bounded inverse and closed graph. The notes were written for this example. Every asserted result is classical, and the one conjecture is a standard exercise that is open only inside the notebook.

| File | What it is |
| --- | --- |
| [`baire-working-notes.tex`](baire-working-notes.tex) | The LaTeX source: six sections, standalone, no `.bib` or figures needed |
| [`baire-working-notes.pdf`](baire-working-notes.pdf) | The same notes typeset (6 pages) |
| [`baire-notes/`](baire-notes/) | The Manifield project made by importing the `.tex` file |

## What is in the notes

| Material | Count | Examples |
| --- | ---: | --- |
| Definitions | 5 | Complete metric spaces; nowhere dense, meagre and residual sets; Banach spaces; bounded operators; graph of an operator |
| Results with a complete written proof | 15 | Baire category theorem, uniform boundedness, open mapping, bounded inverse |
| Proof drafts marked unfinished | 3 | Countable intersections of residual sets, pointwise limits of operators, closed graph theorem |
| Established results cited without proof | 3 | Finite-dimensional subspaces are closed, convergence from a dense subspace, equivalence of comparable complete norms |
| Notebook conjecture | 1 | An infinite-dimensional Banach space has no countable Hamel basis |

The 27 labelled items and their 45 `\ref`s form one connected, acyclic dependency graph. Its three branches are category and dimension; operators and convergence; and open mapping and closed graphs.

## Open it

1. In Manifield: **Open Project…** and choose `examples/baire-category/baire-notes`.
2. **All Items** lists the 27 items by section, with your macros rendered.
3. **Dependency Graph** shows how they connect. Start at the Baire category theorem: it feeds uniform boundedness through the closed-cover corollary, and it feeds open mapping through approximate openness. From open mapping, follow bounded inverse up to the closed graph theorem.
4. Open the **Closed graph theorem**. Its proof stops at a paragraph marked **Still to write**, and the item's status is *Proof drafted*. The other two unfinished drafts are the residual-intersections corollary and the pointwise-limits corollary.

None of this needs a model or an account. Opening the project writes a search index and a graph cache next to it, plus a `sessions/` folder once you chat. All of them are rebuildable, and the repository's `.gitignore` ignores them.

## Things to try with an AI provider

**Close a gap, under review.** Configure a provider (Settings → AI Providers), open a chat in **Propose** mode and ask:

> Read the closed graph theorem and its prerequisites. Complete only the step marked "Still to write", preserve the existing argument, and propose the proof edit for review. Explain which assumptions are used.

The missing step is a few lines: the second-coordinate projection $Q(x,Tx)=Tx$ has norm at most 1 in the sum norm, and $T=QP^{-1}$. A good answer reads the cited items first, bounds $Q$ from the product norm without assuming that $T$ is bounded, and arrives as a proposed edit that you accept or reject. Accepting it does not raise the status above *Proof drafted*; review and approval are separate steps.

**Redo the import yourself.** Make a new project, go to **Import → Import into the library**, choose `baire-working-notes.tex`, and give these instructions if you like:

> Preserve each named definition, lemma, theorem, corollary, and conjecture as a separate item. Preserve every unfinished-proof marker and TODO; do not fill gaps or solve the notebook conjecture during import. Use the explicit references and the mathematics to identify dependencies, including the proposed prerequisites named in unfinished work. Do not create theory items from the title or bibliography.

You review every proposed item before anything is written. Then compare the result with `baire-notes/`, and read the next section first: the import has known problems.

## What was fixed by hand after the import

`baire-notes/` is the importer's output with two kinds of corrections. Both are importer bugs. They are fixed here so that the example shows the notes' real structure, and they are written down so you know what an import gives you today.

1. **14 dependencies pointed to ids that don't exist.** The importer works through the document section by section. When a statement referred to an item in another section, it guessed an id from the LaTeX label (`def-operator`, `lem-continuity`, `cor-closed-cover`, `def-banach`, `thm-baire`, `def-category`, `lem-series`) instead of using the id the item actually got. As imported, the graph split into two pieces. Those references were pointed at the real items, and one omitted link was added (Banach spaces → complete metric spaces). Now every one of the 45 references in the LaTeX is a dependency edge. The importer also inferred three edges that the LaTeX doesn't spell out, and they were kept because they are mathematically right: Baire → complete metric spaces, boundedness and continuity → normed spaces, and graph of an operator → normed spaces. That makes 48 edges.
2. **Four items were marked *Human approved*, though nobody approved them.** The three established results that the notes cite without proof are now *Cited literature*. The definition of the graph of an operator is now *Proof drafted*, like the other four definitions.

Everything else is unchanged: item text, names, ids, sections, and the three unfinished proofs with their markers. The run state was removed (index, chat session), along with a link to a literature source that is not part of this repository.

Statuses in the project now: 23 *Proof drafted* (the five definitions, the 15 written proofs and the 3 unfinished drafts), 3 *Cited literature*, 1 *Conjecture*. *Proof drafted* on a complete proof means a written proof exists and nobody has reviewed it in Manifield. It is not a claim that the proof is correct.

**Still visible in the app:** `\ref{…}` in an item renders as its label in parentheses, e.g. "Theorem (thm:baire)", not as a link. `\cite[Corollary 8]{shalit}` renders as "[shalit]" and loses the locator. The importer also copied a layout-only `\renewcommand{\qedsymbol}{}` into `macros.tex`; it is harmless.

## Sources for the mathematics

The theorem statements were checked against [Christoph Kehle's MIT 18.102 notes](https://math.mit.edu/~kehle/files/Introduction_to_functional_analysis_18_102.pdf), [Orr Shalit's notes on the three big theorems](https://oshalit.net.technion.ac.il/2012/11/11/advanced-analysis-notes-9-banach-spaces-the-three-big-theorems/) and [Alexander Belton's functional analysis notes](https://www.math.chalmers.se/Math/Grundutb/GU/MMA120/A14/lecture%20notes/Belton%20A.%20Functional%20analysis%20%28lecture%20notes%2C%20free%20web%20version%2C%20Oxford%2C%202004%29%28127s%29.pdf). The notebook conjecture is Exercise 2.4 in Belton. The PDF was built with Tectonic.
