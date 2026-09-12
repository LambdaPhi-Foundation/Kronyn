# GOCRAZY: Self-Specializing Interpreter (ON HOLD)

## The idea

A performance-heavy `xyz.kr` plus a `-gocrazy` flag. The interpreter
has a "mainbox": running `kronyn` with no file boots into it.
`kronyn -gocrazy xyz.kr` calls the system toolchain (Nim + C) to
recompile the interpreter's own source with `xyz.kr` already parsed
and evaluated, baked in as the mainbox. The new interpreter runs the
content natively while retaining all original interpreter abilities
(any other file still interprets normally).

Formally, this is the **first Futamura projection**: specializing the
tree-walking interpreter with respect to a fixed source program.

## Honest accounting (read before implementing)

Baking evaluated state alone does **not** speed up loop throughput.
If a long loop is evaluated at build time, the loop already ran —
its *result* is what's baked. What phases 1–2 below deliver is
instant boot plus free precomputation. Only phase 3 (an emitter
backend) moves loop throughput. Do not promise "near native speeds"
until phase 3 exists.

Hard limits baked into the design:

1. `cmds` hold Nim closures, which cannot marshal. Snapshots cover
   `Env` **variables**; procedures re-register from baked source.
2. Toplevel side effects (`writeln`, `fs.write`, `exec`) happen at
   **build** time under evaluated-state semantics.
3. Requires Nim + a C compiler on the target machine.

## Staged plan

### Phase 0 — Measure first

Profile a real heavy file with `-d:kronynProfile` (run it with
`-measure` to see the timings). If tree-walking
(not I/O) dominates, proceed. Startup cost today is ~1ms
(`essentials load`), so baking only pays when scripts run often or
toplevel precomputation is valuable on its own.

### Phase 1 — Baked precomputation (no compiler magic)

- `--dump-state <file>`: run toplevel once, marshal resulting `Env`
  vars via the existing `std/marshal` path (actor jobs already prove
  `Value` trees round-trip).
- Boot with no file arg loads the snapshot as the mainbox
  (today: `usage:` + quit; shell precedent in `src/shell.kr`).
  With a file arg, behave exactly as today.

### Phase 2 — The `-gocrazy` driver

- `kronyn -gocrazy xyz.kr [-- <args>]`: hash source (+ interpreter
  version) → cache dir → write state file + generated `baked.nim`
  with `const BAKED_STATE = staticRead("state.bin")` (extends the
  existing `STDLIB = staticRead(...)` pattern) → shell out to
  `nim c` → `exec` the specialized binary, forwarding args.
- Cache hits skip the build; missing toolchain errors clearly with
  normal-interpretation fallback.

### Phase 3 — The actual near-native part (large)

A tracing specializer: run under the profiler, record hot intent
sequences with concrete `ValueKind`s, emit straight-line Nim
(counted `while` loops over ints first), compile *that* instead of
embedding the AST. Drops into the phase-2 cache/exec flow behind a
`--emit-nim` experiment flag.

## Status

ON HOLD. Precedents already in tree: `staticRead` baking, `--actor-run`
self-reinvocation via `paramStr(0)`, `marshal` IPC, content-hashable
sources. Nothing implemented; start at phase 0 when resumed.
