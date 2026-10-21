---
id: def-bounded-linear-operators
type: definition
name: Bounded linear operators
status: proof-drafted
depends_on: [def-normed-and-banach-spaces]
resolves: []
tags: [linear-operator, bounded-operator, operator-norm]
source: baire-working-notes.tex
section: banach-spaces-and-linear-operators
order: 1003
---
## Statement
For normed spaces over the same field (Definition~\ref{def:banach}), a linear map $T:X\to Y$ is *bounded* if there is $C\ge0$ such that $\norm{Tx}\le C\norm{x}$ for every $x\in X$. Write $\mathcal L(X,Y)$ for these operators and set
\[
 \norm{T}=\sup_{\norm{x}\le1}\norm{Tx}.
\]
This is the least possible bound $C$. In particular, $\norm{Tx}\le\norm{T}\norm{x}$ for all $x$.
