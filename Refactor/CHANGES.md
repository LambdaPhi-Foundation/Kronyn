# CHANGES — safe refactor records (R1..R8)

Convention: each entry lists location (proc name — line numbers shift),
before/after shape, why it is safe, and which Nim-runtime dependence it
reduces. All preserve observable behavior.

## R1 — `$` list join without `mapIt/join` (`src/eval.nim`, proc `$`)

* Before: `v.listVal.mapIt($it).join(" ")` — intermediate `seq[string]`,
  one closure instantiation, one `join` pass.
* After: explicit loop with `newStringOfCap` estimate + `add`, single pass,
  separators added inline.
* Safe: same order, same single-space separator, empty list → `""`.
* Dependence removed: per-render `sequtils` closure + temporary seq.

## R2 — `asInt` fast path via `tryWordInt` (`src/eval.nim`, proc `asInt`)

* Before: `parseInt($v)` for every int probe — exception allocation on
  each non-integer (exception = Nim runtime control flow).
* After: `tryWordInt` first (no exceptions, existing helper with identical
  digit grammar); `parseInt` only as fallback (whitespace-tolerant inputs
  keep old behavior/messages).
* Safe: canonical ints never touch the exception path; garbage still
  raises the same `ValueError` → `kind=error line=-1`.
* Dependence removed: exception frequency on hot `isInt/asInt` probes
  (`+ - * /` comparisons, contracts).

## R3 — `formatStack` pre-sized (`src/eval.nim`, proc `formatStack`)

* Before: `result &= ...` per frame from `""`.
* After: `newStringOfCap(header.len + frames.len * 32)` estimate, then `add`.
* Safe: identical text incl. 20-frame cap + `... (N frames omitted)` cut.
* Dependence removed: repeated string reallocation during trace render.

## R4 — pooled call-frame `Env`s (`src/eval.nim`, `newEnv/callFn/trampolineCall/map`)

* Before: every `callFn`/`map`-child/`trampolineCall` setup did
  `newEnv(root)` = one ORC `ref` + 4 fresh `Table`s; trampoline cleared
  `vars` per iteration but still allocated once per call.
* After: `threadvar envPool: seq[Env]` (cap 64) + `acquireCallEnv(root)` /
  `releaseCallEnv(child)`. Acquire pops or news (children use small initial
  table sizes); release resets `vars/cmds/builtinArities/syscalls`
  (children never populate non-`vars` tables — cleared defensively),
  `returning/breaking/retVal/tailFn/tailArity`, re-parents to the current
  root, pushes back unless over cap. `trampolineCall` acquires once outside
  the loop, releases on return and on non-tail exceptions (tail-signal
  path keeps the frame by design). `newInterpreter` drains the pool alongside
  `initThreadCaches` (the pool is declared after the `Env` type, so the
  drain lives at entry) so a
  fresh interpreter (incl. actor workers) never reuses a stale-root frame.
* Safe: GC still owns all `Value`s — results/args are `ref`s surviving the
  release; pool only recycles table storage. LIFO stack discipline is
  recursion-safe (nested calls acquire deeper entries).
* Dependence removed: per-call `Table` init churn behind PERF's ~3x
  composite frame cost; fewer ORC allocations per call.

## R5 — child `Table` initial sizes (`src/eval.nim`, `newEnv`)

* Before: children paid full-size default tables though only `vars` is used.
* After: `newEnv(parent, varsSize = 64)`-style hint; call-frame path passes
  a small size (8). Root path unchanged.
* Safe: same semantics, only initial bucket count differs.
* Dependence removed: over-allocation per frame.

## R6 — list builtins without `mapIt/filterIt/join` chains

Locations: `split`, `lines`, `filter`, `count`, `first`, `last`
(`src/eval.nim`, `initKernel`).

* Before: e.g. `split(...).mapIt(newStr(it))`,
  `split('\n').filterIt(...).join(...)`, `filterIt(it.len>0).len`.
* After: explicit loops with `newSeqOfCap` / counted pre-pass and manual
  `join` with `newStringOfCap`. `filter` appends separator inline;
  `count` counts without building; `first/last` scan without building.
* Safe: same split grammar (delimiter/`\n`), same empty-skipping, same
  `""` vs value results. `filter` on no-match still yields `""`.
* Dependence removed: 2–3 intermediate seqs + closures per call.

## R7 — `sysFsList` sort without per-compare stringify (`src/eval.nim`)

* Before: `names.sort(proc(x,y:Value):int = cmp($x,$y))` — `$` twice per
  comparison + closure allocation.
* After: project once to `seq[string]`, `sort` plain strings, rebuild
  `seq[Value]`. `algorithm` still used, but on strings with the default
  comparator.
* Safe: same byte-order sorted names-only output.
* Dependence removed: O(n log n) redundant coercion + closure traffic.

## R8 — emitter buffers (`src/codegen.nim`, `cStr/sanitizeC/emit` joins)

* Before: `result &= ...` per char/escape in `cStr`/`sanitizeC`;
  `ins.join(", ")` temporaries per emitted call (2 sites) + arg-list join.
* After: `newStringOfCap(s.len + 8)` estimates + `add`; manual comma joins
  with capacity (`len * 8` heuristic).
* Safe: byte-identical C output (escaping/sanitizing tables untouched:
  `?→_q`, `!→_b`, else `_xHH`; C escapes `\" \\ \n \t \r`, non-printables
  `\xHH`).
* Dependence removed: quadratic growth + `join` temporaries on the
  largest generated files (essentials wholesale).

## Deliberately untouched (see `FUTURE.md`)

* `marshal` actor wire format, `--mm`/checks pragmas, lexer B1 guard,
  `set` B2 refusal, `toUpper/toLower` Unicode semantics, `exec` shelling.
