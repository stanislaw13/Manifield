---
id: thm-baire-category-theorem
type: theorem
name: Baire category theorem
status: proof-drafted
depends_on: [def-complete-metric-spaces, def-nowhere-dense-meagre-and-residual, lem-nested-closed-balls]
resolves: []
tags: [baire-category, metric-spaces, completeness]
source: baire-working-notes.tex
section: baire-category
order: 3
---
## Statement
Every complete metric space is a Baire space (Definition~\ref{def:category}). Equivalently, if $U_1,U_2,\ldots$ are open dense subsets of a complete metric space $X$, then $\bigcap_{n=1}^{\infty}U_n$ is dense in $X$.

## Proof
The assertion is immediate if $X$ is empty. Otherwise, let $V$ be any nonempty open set. Choose $x_1$ and $0<r_1\le2^{-1}$ so that $\overline B(x_1,r_1)\subseteq V\cap U_1$. This is possible because $V\cap U_1$ is nonempty and open: choose an open ball inside it, then use a strictly smaller radius for the closed ball. Inductively choose
\[
 \overline B(x_{n+1},r_{n+1})
 \subseteq B(x_n,r_n)\cap U_{n+1},\qquad
 0<r_{n+1}\le2^{-(n+1)}.
\]
Lemma~\ref{lem:nested-balls} gives a point in all these closed balls. It belongs to $V$ and every $U_n$. Since $V$ was arbitrary, the intersection is dense.
