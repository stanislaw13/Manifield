---
id: conj-no-countable-hamel-basis
type: conjecture
name: No countable Hamel basis
status: conjecture
depends_on: [thm-finite-dimensional-subspaces-are-closed, lem-proper-subspaces-have-empty-interior, cor-closed-cover-form-of-baire]
resolves: []
tags: [banach-spaces, hamel-bases, baires-theorem]
source: baire-working-notes.tex
section: a-question-about-dimension
order: 5000
---
## Statement
An infinite-dimensional Banach space has no countable Hamel basis.

Here a Hamel basis is a linearly independent set such that every vector is a *finite* linear combination of basis vectors.

## Proof
**Notebook status: conjecture, not proved here.**

This is a classical exercise, recorded as an unresolved task in these working notes; it is not open in the mathematical literature. If a basis could be enumerated as $(e_n)$, the candidate sets to examine would be $F_n=\Span\{e_1,\ldots,e_n\}$. Try combining Theorem~\ref{thm:finite-dimensional}, Lemma~\ref{lem:proper-subspace}, and Corollary~\ref{cor:closed-cover}. Be careful: finite linear combinations are different from convergent infinite series. Separability, meaning existence of a countable dense subset, does not assert existence of a countable Hamel basis.
