---
id: lem-products-of-banach-spaces
type: lemma
name: Products of Banach spaces
status: proof-drafted
depends_on: [def-normed-and-banach-spaces]
resolves: []
tags: [banach-space, product-space, norm]
source: baire-working-notes.tex
section: banach-spaces-and-linear-operators
order: 1002
---
## Statement
If $X$ and $Y$ are Banach spaces (Definition~\ref{def:banach}), then $X\times Y$ is Banach for the norm $\norm{(x,y)}=\norm{x}_X+\norm{y}_Y$.

## Proof
The norm axioms follow by applying those in $X$ and $Y$ separately. If $((x_n,y_n))$ is Cauchy, both coordinate sequences are Cauchy. Let their limits be $x\in X$ and $y\in Y$. Then $\norm{(x_n,y_n)-(x,y)}=\norm{x_n-x}+\norm{y_n-y}\to0$.
