---
id: lem-boundedness-and-continuity
type: lemma
name: Boundedness and continuity
status: proof-drafted
depends_on: [def-normed-and-banach-spaces, def-bounded-linear-operators]
resolves: []
tags: [linear-operator, bounded-operator, continuity]
source: baire-working-notes.tex
section: banach-spaces-and-linear-operators
order: 1004
---
## Statement
A linear map between normed spaces is continuous if and only if it is bounded as in Definition~\ref{def:operator}.

## Proof
A bounded map satisfies $\norm{Tx-Ty}\le\norm{T}\norm{x-y}$, so it is continuous. Conversely, continuity at zero gives $\delta>0$ such that $\norm{z}<\delta$ implies $\norm{Tz}<1$. For $x\ne0$, take $z=\delta x/(2\norm{x})$. Linearity gives $\norm{Tx}<2\norm{x}/\delta$; for $x=0$ the bound is automatic. Thus $T$ is bounded.
