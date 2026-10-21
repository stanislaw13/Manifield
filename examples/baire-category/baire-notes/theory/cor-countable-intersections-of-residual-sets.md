---
id: cor-countable-intersections-of-residual-sets
type: corollary
name: Countable intersections of residual sets
status: proof-drafted
depends_on: [def-nowhere-dense-meagre-and-residual, thm-baire-category-theorem]
resolves: []
tags: [baire-category, residual-sets]
source: baire-working-notes.tex
section: baire-category
order: 5
---
## Statement
In a complete metric space $X$, every countable intersection of residual sets is residual and dense, with ``residual'' as in Definition~\ref{def:category}.

## Proof
Write $X\setminus R_j=\bigcup_{k=1}^{\infty}A_{j,k}$, where each $A_{j,k}$ is nowhere dense. Then
\[
 X\setminus\bigcap_{j=1}^{\infty}R_j
   =\bigcup_{j,k\ge1}A_{j,k},
\]
so the intersection is residual because $\N\times\N$ is countable.

**Still to write:** replace the $A_{j,k}$ by their closures, take complements, and use Theorem~\ref{thm:baire} to justify density. Residual sets themselves need not be open, so applying Baire directly to the $R_j$ would leave a gap.
