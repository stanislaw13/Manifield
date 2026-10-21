---
id: lem-proper-subspaces-have-empty-interior
type: lemma
name: Proper subspaces have empty interior
status: proof-drafted
depends_on: [def-normed-and-banach-spaces]
resolves: []
tags: [linear-subspace, interior, normed-space]
source: baire-working-notes.tex
section: banach-spaces-and-linear-operators
order: 1007
---
## Statement
Every proper linear subspace $M$ of a normed space $X$ (Definition~\ref{def:banach}) has empty interior.

## Proof
If $B_X(x_0,r)\subseteq M$, then $x_0\in M$, and subtracting $x_0$ gives $B_X(0,r)\subseteq M$. For any nonzero $x\in X$, a sufficiently small positive multiple $t x$ lies in this ball. Since $M$ is a linear subspace, $x=t^{-1}(t x)$ also lies in $M$. This forces $M=X$.
