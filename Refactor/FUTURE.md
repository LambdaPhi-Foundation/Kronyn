# FUTURE — deferred manual-MM ideas (not this round)

Each item: idea, expected win, why deferred (risk or evidence gap).
Promote only with workload evidence + twin gates green.

## F1 — `marshal` → hand-rolled actor wire format

* Win: removes the `cmds hold closures can't marshal` constraint surface
  from Nim's `marshal` module; explicit escaping, no module magic.
* Deferred: changes the parent/worker wire format. Parent and worker are
  the same binary (`paramStr(0)` re-exec) so rollout is atomic, but any
  escaping bug breaks all 64 `movieSet` workers at once. Needs its own
  reproduce-then-fix cycle with payload fuzz (`scene11` 2KB → larger,
  binary-ish strings, unicode) before touching `spawnActorCall`.

## F2 — `Value` arena per `evalBody`/iteration with promotion on escape

* Win: bump-allocate short-lived temps, free whole arena on frame exit.
* Deferred: escape points are numerous (`setVar`, return, `some(inner)`,
  `unwrapOr` transfer, `emptyVal` singleton, `nil==none`, marshal copy).
  Sound promotion needs an audit at every transfer; a missed one is UAF.
  PERF says dispatch dominates, so arena would not move the 19x floor.

## F3 — GC mode switch (`--mm:arc/orc/none`, `--threads`, `tlsEmulation`)

* Deferred: trades managed safety for manual lifetimes across the mutually
  recursive treewalker; `gcsafe` inference does not converge there
  (`Discipline/ACTORS.md`). `none` breaks `marshal`/`osproc`/`tables` and
  exception control flow. Revisit only if alloc profiles implicate GC
  pauses specifically (not yet shown).

## F4 — Full pools for caught-error temps (compiled `kronyn_rt.c`)

* Deferred with measurement: `COMPILE.md #14` — 20k catches → exactly
  140000 values, 0 envs; sound reclamation needs store barriers on every
  retain/release for UAF safety. Keep `try/@retry` out of hot failing
  loops per discipline instead.

## F5 — Lexer B1 string-aware nesting + bounds guards

* Deferred: behavior change (crash → clean error), shared lexer affects
  both backends. Own reproduce-then-fix cycle with full regression, not a
  side effect of an MM refactor.
