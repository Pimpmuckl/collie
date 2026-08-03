# AGENTS.md — Windows fork scope

Read and follow [`CLAUDE.md`](./CLAUDE.md) before changing anything.

This checkout is the `Pimpmuckl/collie` Windows-support fork. Work and review must stay inside the
fork delta from `AltanS/collie` (`origin/main`): native Windows support, cross-platform regressions
introduced by that support, fork release readiness, and directly related documentation.

- Do not fix or refactor pre-existing upstream behavior without explicit approval.
- Review against the `origin/main` merge base. Report upstream-only findings separately; do not act
  on them as fork findings.
- Preserve Linux and macOS behavior when changing shared files. Use only standard free GitHub-hosted
  runners in this public repository; never select larger billed runners.
- Keep fork-only defaults and documentation easy to identify when changes are later extracted into
  upstream pull requests.
- Open and validate fork pull requests first. Do not open an upstream pull request unless requested.

@CLAUDE.md
