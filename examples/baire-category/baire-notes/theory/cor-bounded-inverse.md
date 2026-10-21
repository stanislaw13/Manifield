---
id: cor-bounded-inverse
type: corollary
name: Bounded inverse theorem
status: proof-drafted
depends_on: [thm-open-mapping, lem-boundedness-and-continuity]
resolves: []
tags: [functional-analysis, bounded-linear-operators, inverse-operators]
source: baire-working-notes.tex
section: open-mapping-and-its-consequences
order: 3003
---
## Statement
A bijective bounded linear operator between Banach spaces has a bounded linear inverse.

## Proof
If $T:X\to Y$ is such an operator, elementary linear algebra makes $T^{-1}$ linear. For every open $U\subseteq X$, $(T^{-1})^{-1}(U)=T(U)$ is open by Theorem~\ref{thm:open-mapping}. Thus $T^{-1}$ is continuous, and Lemma~\ref{lem:continuity} makes it bounded.
