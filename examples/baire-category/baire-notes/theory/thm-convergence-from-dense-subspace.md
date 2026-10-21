---
id: thm-convergence-from-dense-subspace
type: theorem
name: Convergence from a dense subspace
status: source
depends_on: [def-bounded-linear-operators, def-normed-and-banach-spaces, cor-pointwise-limits-of-operators]
resolves: []
tags: [banach-spaces, dense-subspaces, operator-convergence]
source: baire-working-notes.tex
section: uniform-boundedness-and-convergence
order: 2002
---
## Statement
Let $X,Y$ be Banach spaces and $D\subseteq X$ a dense linear subspace. Suppose $T_n\in\mathcal L(X,Y)$, $M=\sup_n\norm{T_n}<\infty$, and $(T_nd)$ converges in $Y$ for each $d\in D$. Then $T_nx$ converges for every $x\in X$, and the limit is a bounded linear operator $T:X\to Y$ with $\norm{T}\le M$.

**Established consequence; proof to be written.** First use density and the operator estimate in Definition~\ref{def:operator} to make $(T_nx)$ Cauchy. Completeness of $Y$ from Definition~\ref{def:banach} supplies the limit; then use Corollary~\ref{cor:pointwise-limit}. This is a standard density argument, not an unresolved assertion about Banach spaces.
