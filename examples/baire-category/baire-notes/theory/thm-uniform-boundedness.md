---
id: thm-uniform-boundedness
type: theorem
name: Uniform boundedness principle
status: proof-drafted
depends_on: [def-bounded-linear-operators, lem-boundedness-and-continuity, cor-closed-cover-form-of-baire]
resolves: []
tags: [banach-spaces, bounded-linear-operators, uniform-boundedness]
source: baire-working-notes.tex
section: uniform-boundedness-and-convergence
order: 2000
---
## Statement
Let $X$ be Banach, let $Y$ be normed, and let $\mathcal T\subseteq\mathcal L(X,Y)$ be a nonempty family of bounded linear operators (Definition~\ref{def:operator}). If
\[
 \sup_{T\in\mathcal T}\norm{Tx}<\infty\qquad\text{for every }x\in X,
\]
then $\sup_{T\in\mathcal T}\norm{T}<\infty$. The family need not be countable, and $Y$ need not be complete.

## Proof
For $m\ge1$, set $F_m=\{x\in X:\norm{Tx}\le m\text{ for every }T\in\mathcal T\}$. Each $F_m$ is an intersection of closed sets, since every $T$ is continuous by Lemma~\ref{lem:continuity}. The hypothesis gives $X=\bigcup_{m\ge1}F_m$. By Corollary~\ref{cor:closed-cover}, some $F_m$ contains a ball $B_X(x_0,r)$. For $\norm{u}\le1$, both $x_0$ and $x_0+(r/2)u$ belong to $F_m$, so, for every $T\in\mathcal T$,
\[
 \frac r2\norm{Tu}
 \le\norm{T(x_0+(r/2)u)}+\norm{Tx_0}\le2m.
\]
Taking the supremum over the unit ball gives $\norm{T}\le4m/r$, independently of $T$.
