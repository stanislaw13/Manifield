---
id: def-normed-and-banach-spaces
type: definition
name: Normed and Banach spaces
status: proof-drafted
depends_on: [def-complete-metric-spaces]
resolves: []
tags: [normed-space, banach-space, norm, metric]
source: baire-working-notes.tex
section: banach-spaces-and-linear-operators
order: 1000
---
## Statement
Let $\K$ be either $\R$ or $\C$. A norm on a $\K$-vector space $X$ is a function $\norm{\cdot}:X\to[0,\infty)$ such that $\norm{x}=0$ exactly when $x=0$, $\norm{\lambda x}=|\lambda|\norm{x}$, and $\norm{x+y}\le\norm{x}+\norm{y}$. A normed space is *Banach* if the metric $d(x,y)=\norm{x-y}$ is complete (Definition~\ref{def:complete}). For a normed space $X$, write $B_X(0,r)=\{x\in X:\norm{x}<r\}$.
