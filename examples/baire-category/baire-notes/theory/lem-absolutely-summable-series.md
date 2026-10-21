---
id: lem-absolutely-summable-series
type: lemma
name: Absolutely summable series
status: proof-drafted
depends_on: [def-normed-and-banach-spaces]
resolves: []
tags: [banach-space, series, absolute-convergence]
source: baire-working-notes.tex
section: banach-spaces-and-linear-operators
order: 1005
---
## Statement
In a Banach space $X$ (Definition~\ref{def:banach}), if $\sum_{n=1}^{\infty}\norm{x_n}<\infty$, then the partial sums of $\sum_{n=1}^{\infty}x_n$ converge to an element $x\in X$, and $\norm{x}\le\sum_{n=1}^{\infty}\norm{x_n}$.

## Proof
For $m>n$, the distance between the partial sums is at most $\sum_{k=n+1}^{m}\norm{x_k}$, which tends to zero uniformly in $m>n$. Completeness gives a limit $x$. Passing to the limit in $\norm{\sum_{k=1}^{n}x_k}\le\sum_{k=1}^{n}\norm{x_k}$ gives the estimate.
