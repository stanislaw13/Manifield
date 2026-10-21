<!-- manifield:fulltext v1 | unit: section | segments: 6 -->

<!-- manifield:contents -->
- Baire category — segment 1
- Banach spaces and linear operators — segment 2
- Uniform boundedness and convergence — segment 3
- Open mapping and its consequences — segment 4
- Closed graphs — segment 5
- A question about dimension — segment 6

<!-- manifield:segment 1 | Baire category -->


\begin{definition}[Complete metric spaces]\label{def:complete}
For a metric space $(X,d)$, write
\[
 B(x,r)=\{y\in X:d(x,y)<r\},\qquad
 \overline B(x,r)=\{y\in X:d(x,y)\le r\}.
\]
The second notation denotes the closed ball; it need not be the closure of the
open ball. A sequence $(x_n)$ is \emph{Cauchy} if, for every $\varepsilon>0$,
there is $N$ such that $d(x_m,x_n)<\varepsilon$ for $m,n\ge N$.
The space is \emph{complete} if every Cauchy sequence converges in $X$.
A set is \emph{dense} if it meets every nonempty open subset of $X$.
\end{definition}

\begin{definition}[Nowhere dense, meagre, and residual]\label{def:category}
In a metric space as in Definition~\ref{def:complete}, a subset $A$ is
\emph{nowhere dense} if $\interior(\overline A)=\varnothing$.
It is \emph{meagre} if it is a countable union of nowhere dense sets.
It is \emph{residual} if $X\setminus A$ is meagre. All closures and interiors
are taken in the ambient space $X$. A \emph{Baire space} is a space in which
every countable intersection of open dense sets is dense.
\end{definition}

\begin{lemma}[Nested closed balls]\label{lem:nested-balls}
Let $(X,d)$ be complete in the sense of Definition~\ref{def:complete}.
Suppose $K_n=\overline B(x_n,r_n)$ are nonempty closed balls,
$K_{n+1}\subseteq K_n$, and $r_n\to0$. Then $\bigcap_{n=1}^{\infty}K_n$
contains exactly one point.
\end{lemma}
\begin{proof}
For $m\ge n$, the centre $x_m$ belongs to $K_n$, so
$d(x_m,x_n)\le r_n$. Thus $(x_n)$ is Cauchy and has a limit $x\in X$.
For each fixed $n$, all later centres lie in the closed set $K_n$;
therefore $x\in K_n$. If $x,y$ both lie in every $K_n$, then
$d(x,y)\le d(x,x_n)+d(x_n,y)\le2r_n$ for every $n$, hence $x=y$.
\end{proof}

\begin{theorem}[Baire category theorem]\label{thm:baire}
Every complete metric space is a Baire space
(Definition~\ref{def:category}). Equivalently, if $U_1,U_2,\ldots$ are
open dense subsets of a complete metric space $X$, then
$\bigcap_{n=1}^{\infty}U_n$ is dense in $X$.
\end{theorem}
\begin{proof}
The assertion is immediate if $X$ is empty. Otherwise, let $V$ be any
nonempty open set. Choose $x_1$ and $0<r_1\le2^{-1}$ so that
$\overline B(x_1,r_1)\subseteq V\cap U_1$.
This is possible because $V\cap U_1$ is nonempty and open: choose an
open ball inside it, then use a strictly smaller radius for the closed ball.
Inductively choose
\[
 \overline B(x_{n+1},r_{n+1})
 \subseteq B(x_n,r_n)\cap U_{n+1},\qquad
 0<r_{n+1}\le2^{-(n+1)}.
\]
Lemma~\ref{lem:nested-balls} gives a point in all these closed balls.
It belongs to $V$ and every $U_n$. Since $V$ was arbitrary, the intersection
is dense.
\end{proof}

\begin{corollary}[Closed-cover form of Baire]\label{cor:closed-cover}
If a nonempty complete metric space $X$ is covered by countably many closed
sets $F_n$, then at least one $F_n$ has nonempty interior.
\end{corollary}
\begin{proof}
If every $F_n$ had empty interior, each complement $X\setminus F_n$
would be open and dense. Theorem~\ref{thm:baire} would make their
intersection dense and therefore nonempty, contradicting $X=\bigcup_nF_n$.
\end{proof}

\begin{corollary}[Countable intersections of residual sets]\label{cor:residual}
In a complete metric space $X$, every countable intersection of residual
sets is residual and dense, with ``residual'' as in
Definition~\ref{def:category}.
\end{corollary}
\begin{proof}[Proof draft --- unfinished]
Write $X\setminus R_j=\bigcup_{k=1}^{\infty}A_{j,k}$, where each
$A_{j,k}$ is nowhere dense. Then
\[
 X\setminus\bigcap_{j=1}^{\infty}R_j
   =\bigcup_{j,k\ge1}A_{j,k},
\]
so the intersection is residual because $\N\times\N$ is countable.

\textbf{Still to write:} replace the $A_{j,k}$ by their closures, take
complements, and use Theorem~\ref{thm:baire} to justify density.
Residual sets themselves need not be open, so applying Baire directly
to the $R_j$ would leave a gap.
\renewcommand{\qedsymbol}{}
\end{proof}

\begin{corollary}[Complete spaces without isolated points]\label{cor:uncountable}
A nonempty complete metric space with no isolated points is uncountable.
\end{corollary}
\begin{proof}
If $X=\{x_1,x_2,\ldots\}$, the closed sets $F_n=\{x_n\}$ cover $X$.
None has interior, since a singleton is open precisely when its point
is isolated. This contradicts Corollary~\ref{cor:closed-cover}.
The same argument covers a finite enumeration by repetition.
\end{proof}



<!-- manifield:segment 2 | Banach spaces and linear operators -->


\begin{definition}[Normed and Banach spaces]\label{def:banach}
Let $\K$ be either $\R$ or $\C$. A norm on a $\K$-vector space $X$ is a
function $\norm{\cdot}:X\to[0,\infty)$ such that
$\norm{x}=0$ exactly when $x=0$,
$\norm{\lambda x}=|\lambda|\norm{x}$, and
$\norm{x+y}\le\norm{x}+\norm{y}$.
A normed space is \emph{Banach} if the metric $d(x,y)=\norm{x-y}$ is
complete (Definition~\ref{def:complete}). For a normed space $X$, write
$B_X(0,r)=\{x\in X:\norm{x}<r\}$.
\end{definition}

\begin{lemma}[Closed subspaces are Banach]\label{lem:closed-subspace}
Every closed linear subspace $M$ of a Banach space $X$ is Banach under
the restricted norm from Definition~\ref{def:banach}.
\end{lemma}
\begin{proof}
A Cauchy sequence in $M$ is also Cauchy in $X$, so it converges to some
$x\in X$. Closedness gives $x\in M$, and convergence uses the same norm.
\end{proof}

\begin{lemma}[Products of Banach spaces]\label{lem:product}
If $X$ and $Y$ are Banach spaces (Definition~\ref{def:banach}), then
$X\times Y$ is Banach for the norm
$\norm{(x,y)}=\norm{x}_X+\norm{y}_Y$.
\end{lemma}
\begin{proof}
The norm axioms follow by applying those in $X$ and $Y$ separately.
If $((x_n,y_n))$ is Cauchy, both coordinate sequences are Cauchy.
Let their limits be $x\in X$ and $y\in Y$. Then
$\norm{(x_n,y_n)-(x,y)}=\norm{x_n-x}+\norm{y_n-y}\to0$.
\end{proof}

\begin{definition}[Bounded linear operators]\label{def:operator}
For normed spaces over the same field (Definition~\ref{def:banach}), a
linear map $T:X\to Y$ is \emph{bounded} if there is $C\ge0$ such that
$\norm{Tx}\le C\norm{x}$ for every $x\in X$.
Write $\mathcal L(X,Y)$ for these operators and set
\[
 \norm{T}=\sup_{\norm{x}\le1}\norm{Tx}.
\]
This is the least possible bound $C$. In particular,
$\norm{Tx}\le\norm{T}\norm{x}$ for all $x$.
\end{definition}

\begin{lemma}[Boundedness and continuity]\label{lem:continuity}
A linear map between normed spaces is continuous if and only if it is
bounded as in Definition~\ref{def:operator}.
\end{lemma}
\begin{proof}
A bounded map satisfies
$\norm{Tx-Ty}\le\norm{T}\norm{x-y}$, so it is continuous.
Conversely, continuity at zero gives $\delta>0$ such that
$\norm{z}<\delta$ implies $\norm{Tz}<1$.
For $x\ne0$, take $z=\delta x/(2\norm{x})$. Linearity gives
$\norm{Tx}<2\norm{x}/\delta$; for $x=0$ the bound is automatic.
Thus $T$ is bounded.
\end{proof}

\begin{lemma}[Absolutely summable series]\label{lem:series}
In a Banach space $X$ (Definition~\ref{def:banach}), if
$\sum_{n=1}^{\infty}\norm{x_n}<\infty$, then the partial sums of
$\sum_{n=1}^{\infty}x_n$ converge to an element $x\in X$, and
$\norm{x}\le\sum_{n=1}^{\infty}\norm{x_n}$.
\end{lemma}
\begin{proof}
For $m>n$, the distance between the partial sums is at most
$\sum_{k=n+1}^{m}\norm{x_k}$, which tends to zero uniformly in $m>n$.
Completeness gives a limit $x$. Passing to the limit in
$\norm{\sum_{k=1}^{n}x_k}\le\sum_{k=1}^{n}\norm{x_k}$ gives the estimate.
\end{proof}

\begin{theorem}[Finite-dimensional subspaces are closed]\label{thm:finite-dimensional}
Every finite-dimensional linear subspace of a normed space
(Definition~\ref{def:banach}) is closed.

\normalfont\smallskip
\textbf{Established result; proof not yet included.}
This is standard finite-dimensional normed-space theory, used for example in
\cite[solution to Exercise 2.4]{belton}. The ambient space need not be complete.
\end{theorem}

\begin{lemma}[Proper subspaces have empty interior]\label{lem:proper-subspace}
Every proper linear subspace $M$ of a normed space $X$
(Definition~\ref{def:banach}) has empty interior.
\end{lemma}
\begin{proof}
If $B_X(x_0,r)\subseteq M$, then $x_0\in M$, and subtracting $x_0$
gives $B_X(0,r)\subseteq M$. For any nonzero $x\in X$, a sufficiently
small positive multiple $t x$ lies in this ball. Since $M$ is a linear
subspace, $x=t^{-1}(t x)$ also lies in $M$. This forces $M=X$.
\end{proof}



<!-- manifield:segment 3 | Uniform boundedness and convergence -->


\begin{theorem}[Uniform boundedness principle]\label{thm:uniform-boundedness}
Let $X$ be Banach, let $Y$ be normed, and let
$\mathcal T\subseteq\mathcal L(X,Y)$ be a nonempty family of bounded
linear operators (Definition~\ref{def:operator}). If
\[
 \sup_{T\in\mathcal T}\norm{Tx}<\infty\qquad\text{for every }x\in X,
\]
then $\sup_{T\in\mathcal T}\norm{T}<\infty$.
The family need not be countable, and $Y$ need not be complete.
\end{theorem}
\begin{proof}
For $m\ge1$, set
$F_m=\{x\in X:\norm{Tx}\le m\text{ for every }T\in\mathcal T\}$.
Each $F_m$ is an intersection of closed sets, since every $T$ is
continuous by Lemma~\ref{lem:continuity}. The hypothesis gives
$X=\bigcup_{m\ge1}F_m$.
By Corollary~\ref{cor:closed-cover}, some $F_m$ contains a ball
$B_X(x_0,r)$. For $\norm{u}\le1$, both $x_0$ and $x_0+(r/2)u$
belong to $F_m$, so, for every $T\in\mathcal T$,
\[
 \frac r2\norm{Tu}
 \le\norm{T(x_0+(r/2)u)}+\norm{Tx_0}\le2m.
\]
Taking the supremum over the unit ball gives $\norm{T}\le4m/r$,
independently of $T$.
\end{proof}

\begin{corollary}[Pointwise limits of operators]\label{cor:pointwise-limit}
Let $X$ be Banach and $Y$ normed. Suppose $T_n\in\mathcal L(X,Y)$
and $T_nx$ converges in $Y$ for every $x\in X$. Then
$Tx=\lim_{n\to\infty}T_nx$ defines an operator $T\in\mathcal L(X,Y)$,
and $M=\sup_n\norm{T_n}<\infty$ with $\norm{T}\le M$.
\end{corollary}
\begin{proof}[Proof draft --- unfinished]
For each fixed $x$, the convergent sequence $(T_nx)$ is bounded.
Theorem~\ref{thm:uniform-boundedness} therefore gives a common bound
$M=\sup_n\norm{T_n}<\infty$.

\textbf{Still to write:} pass to the limit in
$T_n(ax+by)=aT_nx+bT_ny$ and in $\norm{T_nx}\le M\norm{x}$.
These two steps must establish linearity and boundedness in the sense of
Definition~\ref{def:operator}. No completeness of $Y$ is needed because
the limits in $Y$ are part of the hypothesis.
\renewcommand{\qedsymbol}{}
\end{proof}

\begin{theorem}[Convergence from a dense subspace]\label{thm:dense-convergence}
Let $X,Y$ be Banach spaces and $D\subseteq X$ a dense linear subspace.
Suppose $T_n\in\mathcal L(X,Y)$, $M=\sup_n\norm{T_n}<\infty$, and
$(T_nd)$ converges in $Y$ for each $d\in D$. Then $T_nx$ converges
for every $x\in X$, and the limit is a bounded linear operator $T:X\to Y$
with $\norm{T}\le M$.

\normalfont\smallskip
\textbf{Established consequence; proof to be written.}
First use density and the operator estimate in
Definition~\ref{def:operator} to make $(T_nx)$ Cauchy. Completeness of
$Y$ from Definition~\ref{def:banach} supplies the limit; then use
Corollary~\ref{cor:pointwise-limit}. This is a standard density argument,
not an unresolved assertion about Banach spaces.
\end{theorem}

\begin{corollary}[Generic unboundedness]\label{cor:generic-unboundedness}
Let $X$ be Banach, $Y$ normed, and
$\mathcal T\subseteq\mathcal L(X,Y)$ a nonempty family with
$\sup_{T\in\mathcal T}\norm{T}=\infty$. Then
\[
 R=\{x\in X:\sup_{T\in\mathcal T}\norm{Tx}=\infty\}
\]
is a dense residual subset of $X$, in the sense of
Definition~\ref{def:category}.
\end{corollary}
\begin{proof}
Use the closed sets $F_m$ from the proof of
Theorem~\ref{thm:uniform-boundedness}; their closedness does not require
pointwise boundedness. If any $F_m$ contained a ball, the same translated
ball estimate would give a uniform bound on all operator norms,
contrary to the hypothesis. Thus every $F_m$ is closed with empty
interior. Since $X\setminus R=\bigcup_mF_m$, $R$ is residual.
Also $R=\bigcap_m(X\setminus F_m)$ is dense by Theorem~\ref{thm:baire}.
\end{proof}



<!-- manifield:segment 4 | Open mapping and its consequences -->


\begin{lemma}[Approximate openness]\label{lem:approximate-open}
Let $X$ be normed, let $Y$ be Banach, and let
$T\in\mathcal L(X,Y)$ be surjective. There is $\delta>0$ such that
\[
 B_Y(0,\delta)\subseteq\overline{T(B_X(0,1))}.
\]
The overline here means closure in $Y$, not the image of a closed ball.
\end{lemma}
\begin{proof}
Surjectivity implies $Y=\bigcup_{n\ge1}T(B_X(0,n))$ and hence
$Y=\bigcup_{n\ge1}\overline{T(B_X(0,n))}$.
Corollary~\ref{cor:closed-cover} gives $N\ge1$, $y_0\in Y$, and $r>0$
with $B_Y(y_0,r)\subseteq\overline{T(B_X(0,N))}$.
For $\norm{y}<r$, both $y_0+y$ and $y_0$ belong to this closure.
Choose $a_k,b_k\in B_X(0,N)$ with $Ta_k\to y_0+y$ and $Tb_k\to y_0$.
Then $T(a_k-b_k)\to y$ and $\norm{a_k-b_k}<2N$, so
$B_Y(0,r)\subseteq\overline{T(B_X(0,2N))}$.
Scaling by $1/(2N)$ gives the assertion with $\delta=r/(2N)$.
The notation for balls and bounded operators is from
Definitions~\ref{def:banach} and~\ref{def:operator}.
\end{proof}

\begin{lemma}[Geometric-series lifting]\label{lem:lifting}
Let $X$ be Banach, $Y$ normed, and $T\in\mathcal L(X,Y)$.
If $B_Y(0,\delta)\subseteq\overline{T(B_X(0,1))}$ for some $\delta>0$,
then
\[
 B_Y(0,\delta/2)\subseteq T(B_X(0,1)).
\]
\end{lemma}
\begin{proof}
Scaling the assumed inclusion gives
$B_Y(0,\delta2^{-n})\subseteq\overline{T(B_X(0,2^{-n}))}$ for $n\ge1$.
Fix $\norm{y}<\delta/2$. Recursively choose $x_n$ with
\[
 \norm{x_n}<2^{-n},\qquad
 \left\|y-T\sum_{k=1}^{n}x_k\right\|<\delta2^{-(n+1)}.
\]
For $n=1$ the initial residual is $y$; at each later step the preceding
residual lies in $B_Y(0,\delta2^{-n})$, so the scaled closure inclusion
allows an approximation with the displayed accuracy.
Lemma~\ref{lem:series} gives $x=\sum_{n\ge1}x_n\in X$ and
\[
 \norm{x}\le\sum_{n\ge1}\norm{x_n}
 \le\norm{x_1}+\sum_{n\ge2}2^{-n}<\tfrac12+\tfrac12=1.
\]
Continuity of $T$ (Lemma~\ref{lem:continuity}) and convergence of the
residuals give $Tx=y$. Notice that this step uses completeness of $X$;
it does not require completeness of $Y$.
\end{proof}

\begin{theorem}[Open mapping theorem]\label{thm:open-mapping}
Every surjective bounded linear operator $T:X\to Y$ between Banach
spaces is open: $T(U)$ is open in $Y$ whenever $U$ is open in $X$.
\end{theorem}
\begin{proof}
Lemma~\ref{lem:approximate-open} gives $\delta>0$ with a ball contained
in the closure of the image of the unit ball.
Lemma~\ref{lem:lifting} removes that closure and gives
$B_Y(0,\delta/2)\subseteq T(B_X(0,1))$.
Now let $x\in U$ and choose $\varepsilon>0$ with
$x+B_X(0,\varepsilon)\subseteq U$. By linearity and scaling,
\[
 Tx+B_Y(0,\varepsilon\delta/2)
 \subseteq T(x+B_X(0,\varepsilon))\subseteq T(U).
\]
Every point of $T(U)$ is therefore an interior point.
\end{proof}

\begin{corollary}[Bounded inverse theorem]\label{cor:bounded-inverse}
A bijective bounded linear operator between Banach spaces has a bounded
linear inverse.
\end{corollary}
\begin{proof}
If $T:X\to Y$ is such an operator, elementary linear algebra makes
$T^{-1}$ linear. For every open $U\subseteq X$,
$(T^{-1})^{-1}(U)=T(U)$ is open by Theorem~\ref{thm:open-mapping}.
Thus $T^{-1}$ is continuous, and Lemma~\ref{lem:continuity} makes it bounded.
\end{proof}

\begin{corollary}[Equivalence of comparable complete norms]\label{cor:equivalent-norms}
Let $\norm{\cdot}_a$ and $\norm{\cdot}_b$ be two norms on the same vector
space $V$, both making $V$ Banach. If there is $C>0$ such that
$\norm{x}_b\le C\norm{x}_a$ for all $x\in V$, then there is $D>0$ with
$\norm{x}_a\le D\norm{x}_b$ for all $x\in V$. Thus the norms are equivalent.

\normalfont\smallskip
\textbf{Established corollary; proof not yet included.}
Apply Corollary~\ref{cor:bounded-inverse} to the identity map from
$(V,\norm{\cdot}_a)$ onto $(V,\norm{\cdot}_b)$.
Both completeness assumptions matter in this argument; compare
\cite[Corollary 8]{shalit}.
\end{corollary}



<!-- manifield:segment 5 | Closed graphs -->


\begin{definition}[Graph of an operator]\label{def:graph}
For normed spaces $X,Y$ and an everywhere-defined linear map $T:X\to Y$,
its graph is the linear subspace
$G(T)=\{(x,Tx):x\in X\}\subseteq X\times Y$.
The map has a \emph{closed graph} if $G(T)$ is closed in the sum norm
$\norm{(x,y)}=\norm{x}+\norm{y}$ used in Lemma~\ref{lem:product}.
Equivalently, $x_n\to x$ and $Tx_n\to y$ imply $y=Tx$.
Closedness does not, by definition, assert that $Tx_n$ converges whenever
$x_n$ does.
\end{definition}

\begin{theorem}[Closed graph theorem]\label{thm:closed-graph}
Let $X$ and $Y$ be Banach spaces and let $T:X\to Y$ be an
everywhere-defined linear map. If its graph is closed in the sense of
Definition~\ref{def:graph}, then $T$ is bounded.
\end{theorem}
\begin{proof}[Proof draft --- unfinished]
By Lemma~\ref{lem:product}, $X\times Y$ is Banach. The graph $G(T)$ is
a closed linear subspace, so Lemma~\ref{lem:closed-subspace} makes it
Banach in the restricted sum norm.
The projection
$P:G(T)\to X$, $P(x,Tx)=x$, is linear, bijective, and bounded because
$\norm{x}\le\norm{x}+\norm{Tx}$.
Corollary~\ref{cor:bounded-inverse} gives a bounded inverse
$P^{-1}:X\to G(T)$.

\textbf{Still to write:} introduce the second-coordinate projection
$Q:G(T)\to Y$, prove its norm estimate, and use $T=QP^{-1}$ to obtain
an explicit bound for $\norm{Tx}$ in terms of $\norm{x}$.
The boundedness of $Q$ must come from the product norm, not from assuming
the conclusion that $T$ is already bounded.
\renewcommand{\qedsymbol}{}
\end{proof}



<!-- manifield:segment 6 | A question about dimension -->


\begin{conjecture}[No countable Hamel basis]\label{conj:hamel}
An infinite-dimensional Banach space has no countable Hamel basis.
Here a Hamel basis is a linearly independent set such that every vector
is a \emph{finite} linear combination of basis vectors.

\normalfont\smallskip
\textbf{Notebook status: conjecture, not proved here.}
This is a classical exercise, recorded as an unresolved task in these
working notes; it is not open in the mathematical literature.
If a basis could be enumerated as $(e_n)$, the candidate sets to examine
would be $F_n=\Span\{e_1,\ldots,e_n\}$.
Try combining Theorem~\ref{thm:finite-dimensional},
Lemma~\ref{lem:proper-subspace}, and Corollary~\ref{cor:closed-cover}.
Be careful: finite linear combinations are different from convergent
infinite series. Separability, meaning existence of a countable dense
subset, does not assert existence of a countable Hamel basis.
\end{conjecture}

\begin{thebibliography}{9}
\bibitem{kehle}
Christoph Kehle, \emph{Introduction to Functional Analysis}, MIT 18.102,
Spring 2025, Sections 1.5 and 2.3.
\href{https://math.mit.edu/~kehle/files/Introduction_to_functional_analysis_18_102.pdf}{Course notes}.

\bibitem{shalit}
Orr Shalit, \emph{Advanced Analysis, Notes 9: Banach spaces
(the three big theorems)}, 2012.
\href{https://oshalit.net.technion.ac.il/2012/11/11/advanced-analysis-notes-9-banach-spaces-the-three-big-theorems/}{Author's lecture notes}.

\bibitem{belton}
Alexander C. R. Belton, \emph{Functional Analysis}, revised edition, 2006,
Chapters 1--2 and the solutions to exercises.
\href{https://www.math.chalmers.se/Math/Grundutb/GU/MMA120/A14/lecture\%20notes/Belton\%20A.\%20Functional\%20analysis\%20\%28lecture\%20notes\%2C\%20free\%20web\%20version\%2C\%20Oxford\%2C\%202004\%29\%28127s\%29.pdf}{Lecture notes}.
\end{thebibliography}

\end{document}
