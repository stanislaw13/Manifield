---
id: def-graph-of-an-operator
type: definition
name: Graph of an operator
status: proof-drafted
depends_on: [def-normed-and-banach-spaces, lem-products-of-banach-spaces]
resolves: []
tags: [operator, graph, closed-graph]
source: baire-working-notes.tex
section: closed-graphs
order: 4000
---
## Statement
For normed spaces $X,Y$ and an everywhere-defined linear map $T:X\to Y$, its graph is the linear subspace $G(T)=\{(x,Tx):x\in X\}\subseteq X\times Y$. The map has a *closed graph* if $G(T)$ is closed in the sum norm $\norm{(x,y)}=\norm{x}+\norm{y}$ used in Lemma~\ref{lem:product}. Equivalently, $x_n\to x$ and $Tx_n\to y$ imply $y=Tx$. Closedness does not, by definition, assert that $Tx_n$ converges whenever $x_n$ does.
