---
id: thm-open-mapping
type: theorem
name: Open mapping theorem
status: proof-drafted
depends_on: [lem-approximate-openness, lem-geometric-series-lifting]
resolves: []
tags: [functional-analysis, bounded-linear-operators, open-maps]
source: baire-working-notes.tex
section: open-mapping-and-its-consequences
order: 3002
---
## Statement
Every surjective bounded linear operator $T:X\to Y$ between Banach spaces is open: $T(U)$ is open in $Y$ whenever $U$ is open in $X$.

## Proof
Lemma~\ref{lem:approximate-open} gives $\delta>0$ with a ball contained in the closure of the image of the unit ball. Lemma~\ref{lem:lifting} removes that closure and gives $B_Y(0,\delta/2)\subseteq T(B_X(0,1))$. Now let $x\in U$ and choose $\varepsilon>0$ with $x+B_X(0,\varepsilon)\subseteq U$. By linearity and scaling,
\[
 Tx+B_Y(0,\varepsilon\delta/2)
 \subseteq T(x+B_X(0,\varepsilon))\subseteq T(U).
\]
Every point of $T(U)$ is therefore an interior point.
