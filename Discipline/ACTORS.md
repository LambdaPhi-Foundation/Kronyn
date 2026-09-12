# Kronyn Actors (`@actor` RTA)

## What it is

`@actor` marks a `define`d procedure as an **isolated coarse task**.
Every call runs in its own OS process — own GC, own heap, no shared
memory — and the caller blocks until the result (or error) comes back.

```kronyn
@actor
define afib fn(self) {
    if [$self == 0] {return 0} elif [$self == 1] {return 1} else {return [[$self - 1].afib() + [$self - 2].afib()]}
}
writeln 10.afib()  # 55, computed in a worker process
```

## Transport (v1): subprocess + marshal

- The parent serializes the call (`name`, `params`, `body`, `args`)
  with `std/marshal` to a temp job file and re-runs its own binary
  (`paramStr(0)`) as `kronyn --actor-run <job> <res>`.
- The child builds a **fresh interpreter** (`newInterpreter`, quiet),
  re-defines the procedure **by name** (plain, no actor wrapper), runs
  it, and writes the typed result (or error string) back.
- Values cross the boundary as data only. There is no shared `Env`,
  no shared cache, no shared variable. What the parent `set` stays
  with the parent; what the actor `set`s dies with the actor.

Why subprocess and not threads: Nim's `spawn`/`thread` require
GC-safe workers, and GC-safety inference does not converge over the
mutually recursive treewalker (`parseArg`/`parseChainArgs`,
`eval`/`evalStmt`/`evalArg`/`evalSub`). Marking the ~60-proc cluster
`gcsafe` by hand would blind the checker to future real violations.
A subprocess gives stronger isolation than threads anyway (separate
GC and heap by construction, crash-proof parent). Interpreter state
is already thread-shaped (`threadvar` caches/counters,
locked stdout) so a future in-process fast path stays possible.

## Discipline (read before using)

1. **Coarse tasks only.** Spawn cost is milliseconds (process +
   essentials load). `10.afib()` is fine; per-element mapping is not.
2. **Share-nothing.** Args and return values are deep-copied through
   serialization. Mutation never crosses. File and `exec` side
   effects are the only shared channel — coordinate those yourself.
3. **Closed world.** Inside an actor you see builtins, the essentials
   (`print`, `println`, …), and the actor itself (recursion
   works, e.g. `afib`). Other user procedures from the parent are
   NOT visible; calling one fails with `unknown command`, reported
   back as `actor <name>: …`. Mutual recursion across procedures is
   unsupported in v1 — inline helpers or split into stages.
4. **Errors come back as values-or-strings.** A worker failure
   raises `actor <name>: <msg>` in the caller; wrap the call in
   `try` to handle it. A worker *crash* (non-zero exit, missing
   result file) raises `actor <name>: worker failed (exit N)`.
5. **`@retry` order matters.**
   `@retry(n)` above `@actor` retries in the parent — each attempt
   is a fresh worker (fresh heap). `@retry(n)` below `@actor`
   retries inside the single worker (attempts share its heap).
   Keep counts small (2–3), especially on recursive actors.
6. **Bounded waits need `@timeout`.** A bare actor call blocks in
   `waitForExit` with no deadline — a hung worker hangs the caller.
   Add `@timeout(ms)` (see `TIMEOUT.md`) for a preemptive bound:
   past the budget the parent ends the worker and raises a
   catchable `timeout` error. Don't use bare actors on untrusted
   code.
7. **`@actor` only on `define`.** On any other statement it is a
   hard error, as are `@actor(...)` arguments, duplicates, and
   unknown `@anything` (typo protection).
8. **Process-wide exits and stdio.** `syscall proc.exit` inside an
   actor kills the worker (reported as worker failure), not the
   parent. Actor `writeln` goes to the parent's stdout (inherited);
   concurrent actors can interleave lines. `syscall io.input`
   inside actors races on stdin — don't. `syscall proc.args` is
   always empty inside workers (their real argv is job plumbing).
9. **Temp files.** Jobs/results live in the temp dir as
   `kronyn_actor_<pid>_<seq>.{job,res}` and are removed after each
   call, including on failure.
10. **Build.** No special flags: plain `nim c src/kronyn.nim`.
    Profile with `-d:kronynProfile` (per-process stats, shown with
    `-measure`; worker processes stay quiet in both modes).
