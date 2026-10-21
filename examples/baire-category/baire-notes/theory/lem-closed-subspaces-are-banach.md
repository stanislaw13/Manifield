---
id: lem-closed-subspaces-are-banach
type: lemma
name: Closed subspaces are Banach
status: proof-drafted
depends_on: [def-normed-and-banach-spaces]
resolves: []
tags: [banach-space, closed-subspace, completeness]
source: baire-working-notes.tex
section: banach-spaces-and-linear-operators
order: 1001
---
## Statement
Every closed linear subspace $M$ of a Banach space $X$ is Banach under the restricted norm from Definition~\ref{def:banach}.

## Proof
A Cauchy sequence in $M$ is also Cauchy in $X$, so it converges to some $x\in X$. Closedness gives $x\in M$, and convergence uses the same norm.
