# RESULTS — verification log

Filled after each verification run. Commands assume repo root `D:\kronyn`.

## Run template

* Date / binary (`nim c src/kronyn.nim` debug):
* Spot twins (`tests/01_basics_vars_arith.kr`, `32/33/34`, `39_perf_bench.kr -measure`):
* `nim r tests/compile/run.nim` (expect 28/28):
* `39_perf_bench.kr` essentials-load + cache/counter lines (before → after):
* Notes (any byte diff = red, investigate before proceeding):

## Runs

> Naming note: on 2026-09-12 the suite was renamed basic→advanced
> (`testN.kr` → `NN_type_topic.kr`, plus `bench/showcase/liststuff/shell`
> → `39/38/03/20`). Entries below use the new names.

## Runs

### 2026-09-12 — R1..R8 (safe round), `nim c src/kronyn.nim` debug

Build: success, 5.963s. Only pre-existing hints (`parser.nim`
unused `line`/`parseDotChain`, unused `lexer` import). `sequtils`
no longer in the compiled units (R1/R6) — verified in the `CC:` list.

Spot twins (all exit 0, output as expected):
* `tests/01_basics_vars_arith.kr` — core sample output unchanged.
* `tests/32_stdlib_essentials.kr` — full smoke incl. negatives (`needs D:\tmp`
  on Windows for its `/tmp/...` paths — pre-existing env requirement,
  same as `33`).
* `tests/33_syscalls.kr`, `tests/34_errors.kr` — all `neg-ok`
  lines + `done` markers.
* `tests/39_perf_bench.kr -measure` — `fib(20)=55`-family output, cache/counters
  print (`hits: 2548 miss: 6 evalStmt: 4776 evalArg: 27466 evalSub: 7220`).
* `tests/30_rta_tailcall.kr` — `5000050000`, 100k depth, `tailcall
  tests done` (pooled trampoline frame).
* `tests/22_rta_actor_basics.kr`, `31_rta_actor_tailcall.kr` — actor + tailcall
  interplay green.
* `tests/26_rta_actor_retry.kr` — green with piped stdin (`10/2 → 5`);
  bare run stops at the file's interactive `ask` demo (pre-existing,
  needs stdin, fails the same way before this refactor).

Full sweep across core + RTA files (old names `test.kr`–`test12`,
`test15`–`test19`, `test21`–`test23`, `test25`–`test27`, `test33`–`test34`,
`liststuff`, `showcase` — now `01–15`, `18`, `19`, `21`, `23–25`,
`27–29`, `35`, `36`, `03`, `38`): exit 0 throughout, except `16`/`17`
(old `test13`/`test14`) which exit 1
**by design** (unknown-command/type-error fixtures — see `COMPILE.md`
parity record).

`nim r tests/compile/run.nim`: **27/27 PASS, 0 failures** (10 twins +
delta + 4 runfails + 12 refusals) — covers the R8 emitter changes.

Notes: one compile-necessitated shape change during implementation —
R1's multi-statement `vkList` branch forced explicit `result =` in every
`$` case branch (Nim case-as-expression rule); semantics identical.
Repo note: the tree was already dirty before this refactor (uncommitted
evolution + CRLF warnings on several files); the R1..R8 delta rides on
top and is fenced by `Refactor R` markers (17 in `eval.nim`, 3 in
`codegen.nim`) plus this folder's records.
