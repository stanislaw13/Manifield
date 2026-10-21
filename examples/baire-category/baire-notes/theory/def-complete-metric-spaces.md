---
id: def-complete-metric-spaces
type: definition
name: Complete metric spaces
status: proof-drafted
depends_on: []
resolves: []
tags: [metric-spaces, completeness, density]
source: baire-working-notes.tex
section: baire-category
order: 0
---
## Statement
For a metric space $(X,d)$, write
\[
 B(x,r)=\{y\in X:d(x,y)<r\},\qquad
 \overline B(x,r)=\{y\in X:d(x,y)\le r\}.
\]
The second notation denotes the closed ball; it need not be the closure of the open ball. A sequence $(x_n)$ is *Cauchy* if, for every $\varepsilon>0$, there is $N$ such that $d(x_m,x_n)<\varepsilon$ for $m,n\ge N$. The space is *complete* if every Cauchy sequence converges in $X$. A set is *dense* if it meets every nonempty open subset of $X$.
