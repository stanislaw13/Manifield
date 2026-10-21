---
id: cor-generic-unboundedness
type: corollary
name: Generic unboundedness
status: proof-drafted
depends_on: [thm-uniform-boundedness, thm-baire-category-theorem, def-nowhere-dense-meagre-and-residual]
resolves: []
tags: [banach-spaces, baires-category-theorem, generic-properties, bounded-linear-operators]
source: baire-working-notes.tex
section: uniform-boundedness-and-convergence
order: 2003
---
## Statement
Let $X$ be Banach, $Y$ normed, and $\mathcal T\subseteq\mathcal L(X,Y)$ a nonempty family with $\sup_{T\in\mathcal T}\norm{T}=\infty$. Then
\[
 R=\{x\in X:\sup_{T\in\mathcal T}\norm{Tx}=\infty\}
\]
is a dense residual subset of $X$, in the sense of Definition~\ref{def:category}.

## Proof
Use the closed sets $F_m$ from the proof of Theorem~\ref{thm:uniform-boundedness}; their closedness does not require pointwise boundedness. If any $F_m$ contained a ball, the same translated ball estimate would give a uniform bound on all operator norms, contrary to the hypothesis. Thus every $F_m$ is closed with empty interior. Since $X\setminus R=\bigcup_mF_m$, $R$ is residual. Also $R=\bigcap_m(X\setminus F_m)$ is dense by Theorem~\ref{thm:baire}.
