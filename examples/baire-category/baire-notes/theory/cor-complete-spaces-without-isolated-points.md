---
id: cor-complete-spaces-without-isolated-points
type: corollary
name: Complete spaces without isolated points
status: proof-drafted
depends_on: [cor-closed-cover-form-of-baire]
resolves: []
tags: [baire-category, metric-spaces, cardinality, isolated-points]
source: baire-working-notes.tex
section: baire-category
order: 6
---
## Statement
A nonempty complete metric space with no isolated points is uncountable.

## Proof
If $X=\{x_1,x_2,\ldots\}$, the closed sets $F_n=\{x_n\}$ cover $X$. None has interior, since a singleton is open precisely when its point is isolated. This contradicts Corollary~\ref{cor:closed-cover}. The same argument covers a finite enumeration by repetition.
