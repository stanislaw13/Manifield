---
id: thm-closed-graph
type: theorem
name: Closed graph theorem
status: proof-drafted
depends_on: [def-graph-of-an-operator, lem-products-of-banach-spaces, lem-closed-subspaces-are-banach, cor-bounded-inverse]
resolves: []
tags: [operator, closed-graph, boundedness, banach-space]
source: baire-working-notes.tex
section: closed-graphs
order: 4001
---
## Statement
Let $X$ and $Y$ be Banach spaces and let $T:X\to Y$ be an everywhere-defined linear map. If its graph is closed in the sense of Definition~\ref{def:graph}, then $T$ is bounded.

## Proof
By Lemma~\ref{lem:product}, $X\times Y$ is Banach. The graph $G(T)$ is a closed linear subspace, so Lemma~\ref{lem:closed-subspace} makes it Banach in the restricted sum norm. The projection $P:G(T)\to X$, $P(x,Tx)=x$, is linear, bijective, and bounded because $\norm{x}\le\norm{x}+\norm{Tx}$. Corollary~\ref{cor:bounded-inverse} gives a bounded inverse $P^{-1}:X\to G(T)$.

**Still to write:** introduce the second-coordinate projection $Q:G(T)\to Y$, prove its norm estimate, and use $T=QP^{-1}$ to obtain an explicit bound for $\norm{Tx}$ in terms of $\norm{x}$. The boundedness of $Q$ must come from the product norm, not from assuming the conclusion that $T$ is already bounded.
