# Refactor — depend less on the Nim runtime (safe parts only)

Goal: make the Kronyn runtime depend less on Nim's runtime magic
(higher-order `sequtils` templates, per-comparison stringify closures,
exception-driven fast paths, per-call table allocation, quadratic string
growth) using **safe, pure-Nim** means only.

Non-goal (explicit): no `ptr` / `alloc` / `cast[gcsafe]` / `--checks:off` /
`--mm:none` in this round. Full arenas, `marshal` replacement, and any GC
mode switch are deferred to `FUTURE.md` with reasons.

## Safety rules (every change must satisfy all of these)

1. Pure Nim only — no `ptr`, `UncheckedArray`, `alloc`, `cast`, `emit`,
   no pragma/mode trickery (`checks`, `boundChecks`, `fieldChecks`,
   `overflowChecks`, `panics` untouched).
2. Observable behavior identical: stdout/stderr/exit codes, exact
   `line N:` messages, error kinds, trace format/cap, truthiness,
   operator semantics, B3 (dropped tails) / B4 (first-pair infix) quirks.
3. GC still owns everything — we only cut temporary allocations, closure
   traffic, and table re-allocations; no manual lifetimes.
4. One region per change (R1..R8 in `CHANGES.md`), each revertible alone.
5. Gate before merge: interpreter spot checks + `tests/compile/run.nim`
   28/28 + representative `tests/*.kr` twins + `39_perf_bench.kr -measure`.

## Inventory: where the Nim runtime is touched

| Touchpoint | File / proc | Dependence |
|---|---|---|
| List stringify `$` | `src/eval.nim` `$` | `sequtils.mapIt` + `strutils.join` per render |
| Int conversion `asInt` | `src/eval.nim` `asInt` | `parseInt` exception on every non-int fast-path probe |
| Trace render | `src/eval.nim` `formatStack` | repeated `&=` growth |
| Call frames | `src/eval.nim` `newEnv/callFn/trampolineCall/map-child` | 4 fresh `Table`s per call (PERF 3x frame cost) |
| List builtins | `split/lines/filter/count/first/last` | `split` + `mapIt/filterIt/join` chains, intermediate seqs |
| Dir listing sort | `src/eval.nim` `sysFsList` | `algorithm.sort` with `$`-per-comparison closure |
| C emitter | `src/codegen.nim` `cStr/sanitizeC/emit/join` | `&=` growth + `join` temporaries per node |
| Actor transport | `marshal $$/to[]`, `osproc` | deferred — see `FUTURE.md` (wire-format risk) |
| Lexer guards (B1), `set` target (B2) | `src/lexer.nim`, `set` case | deferred — behavior change, not MM |

## Docs in this folder

* `CHANGES.md` — per-change record (what / why safe / dependence removed).
* `RESULTS.md` — verification log (commands + outcomes, filled after runs).
* `FUTURE.md` — deferred manual-MM ideas with cost/benefit and why not now.

Rule: fix the docs when the code moves — never silently drop a row
(same discipline as `Negatives/`).
