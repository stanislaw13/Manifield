---
id: cor-equivalence-of-comparable-complete-norms
type: corollary
name: Equivalence of comparable complete norms
status: source
depends_on: [cor-bounded-inverse]
resolves: []
tags: [functional-analysis, normed-spaces, banach-spaces]
source: baire-working-notes.tex
section: open-mapping-and-its-consequences
order: 3004
---
## Statement
Let $\norm{\cdot}_a$ and $\norm{\cdot}_b$ be two norms on the same vector space $V$, both making $V$ Banach. If there is $C>0$ such that $\norm{x}_b\le C\norm{x}_a$ for all $x\in V$, then there is $D>0$ with $\norm{x}_a\le D\norm{x}_b$ for all $x\in V$. Thus the norms are equivalent.

**Established corollary; proof not yet included.** Apply Corollary~\ref{cor:bounded-inverse} to the identity map from $(V,\norm{\cdot}_a)$ onto $(V,\norm{\cdot}_b)$. Both completeness assumptions matter in this argument; compare \cite[Corollary 8]{shalit}.
