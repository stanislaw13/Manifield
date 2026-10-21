---
id: lem-approximate-openness
type: lemma
name: Approximate openness
status: proof-drafted
depends_on: [cor-closed-cover-form-of-baire, def-normed-and-banach-spaces, def-bounded-linear-operators]
resolves: []
tags: [functional-analysis, bounded-linear-operators, surjectivity]
source: baire-working-notes.tex
section: open-mapping-and-its-consequences
order: 3000
---
## Statement
Let $X$ be normed, let $Y$ be Banach, and let $T\in\mathcal L(X,Y)$ be surjective. There is $\delta>0$ such that
\[
 B_Y(0,\delta)\subseteq\overline{T(B_X(0,1))}.
\]
The overline here means closure in $Y$, not the image of a closed ball.

## Proof
Surjectivity implies $Y=\bigcup_{n\ge1}T(B_X(0,n))$ and hence $Y=\bigcup_{n\ge1}\overline{T(B_X(0,n))}$. Corollary~\ref{cor:closed-cover} gives $N\ge1$, $y_0\in Y$, and $r>0$ with $B_Y(y_0,r)\subseteq\overline{T(B_X(0,N))}$. For $\norm{y}<r$, both $y_0+y$ and $y_0$ belong to this closure. Choose $a_k,b_k\in B_X(0,N)$ with $Ta_k\to y_0+y$ and $Tb_k\to y_0$. Then $T(a_k-b_k)\to y$ and $\norm{a_k-b_k}<2N$, so $B_Y(0,r)\subseteq\overline{T(B_X(0,2N))}$. Scaling by $1/(2N)$ gives the assertion with $\delta=r/(2N)$. The notation for balls and bounded operators is from Definitions~\ref{def:banach} and~\ref{def:operator}.
