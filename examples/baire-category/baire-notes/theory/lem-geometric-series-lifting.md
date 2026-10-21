---
id: lem-geometric-series-lifting
type: lemma
name: Geometric-series lifting
status: proof-drafted
depends_on: [lem-absolutely-summable-series, lem-boundedness-and-continuity]
resolves: []
tags: [functional-analysis, bounded-linear-operators, completeness]
source: baire-working-notes.tex
section: open-mapping-and-its-consequences
order: 3001
---
## Statement
Let $X$ be Banach, $Y$ normed, and $T\in\mathcal L(X,Y)$. If $B_Y(0,\delta)\subseteq\overline{T(B_X(0,1))}$ for some $\delta>0$, then
\[
 B_Y(0,\delta/2)\subseteq T(B_X(0,1)).
\]

## Proof
Scaling the assumed inclusion gives $B_Y(0,\delta2^{-n})\subseteq\overline{T(B_X(0,2^{-n}))}$ for $n\ge1$. Fix $\norm{y}<\delta/2$. Recursively choose $x_n$ with
\[
 \norm{x_n}<2^{-n},\qquad
 \left\|y-T\sum_{k=1}^{n}x_k\right\|<\delta2^{-(n+1)}.
\]
For $n=1$ the initial residual is $y$; at each later step the preceding residual lies in $B_Y(0,\delta2^{-n})$, so the scaled closure inclusion allows an approximation with the displayed accuracy. Lemma~\ref{lem:series} gives $x=\sum_{n\ge1}x_n\in X$ and
\[
 \norm{x}\le\sum_{n\ge1}\norm{x_n}
 \le\norm{x_1}+\sum_{n\ge2}2^{-n}<\tfrac12+\tfrac12=1.
\]
Continuity of $T$ (Lemma~\ref{lem:continuity}) and convergence of the residuals give $Tx=y$. Notice that this step uses completeness of $X$; it does not require completeness of $Y$.
