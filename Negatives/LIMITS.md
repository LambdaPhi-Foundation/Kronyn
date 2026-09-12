# LIMITS — inherent constraints (facts, not faults)

> Boundaries to design around. Each carries its measurement or its
> pointer. Changing one is a project decision, not a bugfix.

## Performance envelope

- **L1 — Treewalk dispatch overhead.** Per-character tree-walking
  measures ~19x vs one Nim call; composite builtins ~3x (almost all
  user-proc frame cost). See `PERF.md`. Mitigations in play: AST
  caches, fail-fast contracts, `@tailcallopt`, and compiling hot
  programs (`translation/` stage: ~4x on mixed code, ~136x on tail
  loops). No bytecode VM is planned — this ceiling is accepted.

## Type system

- **L2 — No static types.** Contracts (`@typecheck`) are runtime
  checks, opt-in per procedure; untyped code gets no checking at
  all. Typo protection (unknown `@anything` rejected) is the only
  global strictness.

## Isolation and time

- **L3 — Actors are OS processes.** ~15–25ms spawn on Windows (~4ms
  on Linux per `PERF.md`), caller blocks (no parallelism), args and
  results deep-copy through serialization, workers see only
  builtins + essentials + themselves. Coarse tasks only. Full
  discipline: `Discipline/ACTORS.md`; production proof: `movieSet/`.
- **L4 — No timeouts by default.** A hung actor (`waitForExit`
  blocks) or hung loop hangs the caller. Pair with `@timeout`
  (preemptive kill for actors, cooperative windows otherwise) on
  anything untrusted. See `Discipline/TIMEOUT.md`.
- **L12 — Forks are OS processes with full-world snapshots.** Same
  spawn class as actors (caller blocks, result-only channel), plus the
  snapshot grows with program size (all defines + root globals cross
  per call). Call-frame locals are not inherited; nested isolation
  boundaries run in-process; no compiled support. Full discipline:
  `Discipline/FORKEXEC.md`; contract: `tests/37_rta_forkexec.kr`.

## Errors and introspection

- **L5 — `try` catches `ValueError` only, by design.** `Defect`
  always means a real interpreter bug (known defect sites are
  converted at source — `Discipline/ERRORS.md` rule 3).
- **L6 — Line numbers are best-effort.** `Arg` nodes don't carry
  file lines and `[...]` sub-sources re-lex from line 1; read trace
  frames (define-site lines), not prefixes. Threading lines through
  `Arg` was explicitly declined. The *compiled* backend does better
  here (true lines — `COMPILE.md` #1).
- **L7 — Caught errors leak ~7 small Values per catch (compiled).**
  Measured via `KRN_LEAK_CHECK` (20k catches → exactly 140000
  values, 0 envs reclaimed). Success paths read 0/0. Full pools
  were costed and declined — see `COMPILE.md` #14.

## Shell and platform

- **L8 — `exec` is platform-shell-defined and banned in-tree.**
  Output merges child stderr, status is ignored, quoting and shells
  are the caller's problem (`Discipline/SYSCALL.md` rule 3). Twins
  per platform only.

## Transpiler boundaries

- **L9 — Compiled subset refusals.** `evolve` (needs the evaluator
  at runtime), `map`, `@actor` / `@forkexec` (need a transport
  decision), nested defines/imports, non-block bodies, multi-statement
  conditions. Static mistakes refuse at compile time, so `try`/`@retry`
  catch *runtime* failures only. See `COMPILE.md`.
- **L10 — Literals-only RTA counts/paths/messages; imports resolve
  at compile time** (hermetic binaries, cycles refused); retry and
  timeout counts cap at 2^31-1.
- **L11 — C-string edge semantics.** Byte-based case/trim, empty-
  delim split yields one item, huge-int wrap (`-fwrapv`;
  `LLONG_MIN / -1` excepted), chained-infix left-assoc, forward
  references resolve, deeper plain recursion survives. All in
  `COMPILE.md` #5–7, #10–12.
