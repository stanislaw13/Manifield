---
id: lem-nested-closed-balls
type: lemma
name: Nested closed balls
status: proof-drafted
depends_on: [def-complete-metric-spaces]
resolves: []
tags: [metric-spaces, completeness, closed-balls]
source: baire-working-notes.tex
section: baire-category
order: 2
---
## Statement
Let $(X,d)$ be complete in the sense of Definition~\ref{def:complete}. Suppose $K_n=\overline B(x_n,r_n)$ are nonempty closed balls, $K_{n+1}\subseteq K_n$, and $r_n\to0$. Then $\bigcap_{n=1}^{\infty}K_n$ contains exactly one point.

## Proof
For $m\ge n$, the centre $x_m$ belongs to $K_n$, so $d(x_m,x_n)\le r_n$. Thus $(x_n)$ is Cauchy and has a limit $x\in X$. For each fixed $n$, all later centres lie in the closed set $K_n$; therefore $x\in K_n$. If $x,y$ both lie in every $K_n$, then $d(x,y)\le d(x,x_n)+d(x_n,y)\le2r_n$ for every $n$, hence $x=y$.
