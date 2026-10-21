---
id: cor-pointwise-limits-of-operators
type: corollary
name: Pointwise limits of operators
status: proof-drafted
depends_on: [thm-uniform-boundedness, def-bounded-linear-operators]
resolves: []
tags: [banach-spaces, pointwise-convergence, bounded-linear-operators]
source: baire-working-notes.tex
section: uniform-boundedness-and-convergence
order: 2001
---
## Statement
Let $X$ be Banach and $Y$ normed. Suppose $T_n\in\mathcal L(X,Y)$ and $T_nx$ converges in $Y$ for every $x\in X$. Then $Tx=\lim_{n\to\infty}T_nx$ defines an operator $T\in\mathcal L(X,Y)$, and $M=\sup_n\norm{T_n}<\infty$ with $\norm{T}\le M$.

## Proof
*Proof draft --- unfinished*

For each fixed $x$, the convergent sequence $(T_nx)$ is bounded. Theorem~\ref{thm:uniform-boundedness} therefore gives a common bound $M=\sup_n\norm{T_n}<\infty$.

**Still to write:** pass to the limit in $T_n(ax+by)=aT_nx+bT_ny$ and in $\norm{T_nx}\le M\norm{x}$. These two steps must establish linearity and boundedness in the sense of Definition~\ref{def:operator}. No completeness of $Y$ is needed because the limits in $Y$ are part of the hypothesis.
