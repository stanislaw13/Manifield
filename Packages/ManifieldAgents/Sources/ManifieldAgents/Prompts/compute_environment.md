Computational environment available to the tasks you plan:

- Python 3 in a local sandbox with **no network access** and a hard per-call timeout (600s maximum, 120s by default). Long searches must be split across calls or made to fit.
- The only third-party packages installed are: {{PACKAGES}}. Nothing else can be fetched or installed — there is no SAT solver, no ILP or MILP solver, no CAS beyond sympy, and no proof assistant.
- The standard library is available, so hand-written branch-and-bound, bitset enumeration and dynamic programming are all fine, and are usually the right tool here.

Plan only methods this environment can actually run. A task that calls for a solver which is not installed cannot be executed, and in an unattended run it burns the branch's budget before anyone notices. If a method genuinely needs one, say so in the task title and plan the fallback that the sandbox can run.
