---
id: cor-closed-cover-form-of-baire
type: corollary
name: Closed-cover form of Baire
status: proof-drafted
depends_on: [thm-baire-category-theorem]
resolves: []
tags: [baire-category, closed-sets]
source: baire-working-notes.tex
section: baire-category
order: 4
---
## Statement
If a nonempty complete metric space $X$ is covered by countably many closed sets $F_n$, then at least one $F_n$ has nonempty interior.

## Proof
If every $F_n$ had empty interior, each complement $X\setminus F_n$ would be open and dense. Theorem~\ref{thm:baire} would make their intersection dense and therefore nonempty, contradicting $X=\bigcup_nF_n$.
