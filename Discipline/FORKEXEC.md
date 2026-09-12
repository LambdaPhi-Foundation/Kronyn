# Kronyn forkexec (`@forkexec` RTA)

## What it is

`@forkexec` marks a `define`d procedure as a **forked call**: every call
runs in its own OS process — own GC, own heap, no shared memory — and the
caller blocks until the result (or error) comes back. It is the sibling of
`@actor` with one decisive difference: the child inherits the **full
world** (every `define` in registration order plus the root globals
snapshotted at fork time) instead of a closed world.

```kronyn
set base 100
define addbase fn(self) {
    return [$self + $base]
}
@forkexec
define fvia fn(self) {
    return [$self.addbase() + 1]  # helper + global visible: 106 for 5
}
writeln 5.fvia()
```

An `@actor` child would fail the same call with `unknown command:
addbase` — that is the whole point of the fork: helpers, libraries, and
configuration globals travel with the call.

## Transport (v1): subprocess + marshal, full-world snapshot

- Every `define` (plain, retried, typechecked, tail-optimized — any of
  them) is recorded on the root env as plain data (`ForkDef`: params,
  types, body source, return type, line, flags). Closures never cross the
  boundary — the same constraint as actor transport, satisfied the same
  way (source re-registers, not functions).
- At call time the parent snapshots the world: all defines in
  registration order plus the root `vars` table. The snapshot crosses via
  `std/marshal` to a temp job file; the parent re-runs its own binary as
  `kronyn --forkexec-run <job> <res>`.
- The child builds a **fresh interpreter** (`newInterpreter`, quiet),
  re-registers every define **plain** (recursion stays in-process),
  restores the globals as copies, runs the target with its inner-retry
  budget, and writes the typed result (or error string) back.
- What the parent `set` at top level, the child sees as copies; what the
  child `set`s dies with the child. The **result is the only channel
  back**; files and `exec` side effects are the only other shared
  channel — coordinate those yourself.

## Discipline (read before using)

1. **Coarse tasks only.** Spawn cost is milliseconds (process + world
   snapshot + essentials load). One fork per request is fine;
   per-element mapping is not.
2. **Fork of the module-level world.** Globals (`set` at top level, incl.
   `argv`) and every procedure travel. **Call-frame locals do not**:
   calling a forked proc from inside another proc sees the globals, not
   the enclosing proc's locals (v1 boundary — the call boundary is the
   only channel in). A true address-space `fork(2)` would inherit the
   stack; this transport cannot rebuild a call stack in a fresh
   interpreter, so it does not try.
3. **Helpers keep their wrappers — except isolation.** Retried,
   typechecked, and tail-optimized helpers behave as defined in the
   child. But `@actor`/`@forkexec` wrappers are **not** restored there:
   isolation boundaries do not nest (same rule as actor workers). A
   nested isolation call runs in-process. The target's own retry wrapper
   is likewise stripped in favor of its inner-retry budget (otherwise
   outer × inner would multiply).
4. **Errors come back as values-or-strings.** A worker failure raises
   `fork <name>: <msg>` (kind `"fork"`) with the worker trace appended;
   wrap the call in `try` to handle it. A worker *crash* (non-zero exit,
   missing result file) raises `fork <name>: worker failed (exit N)`.
   A crashed `proc.exit` inside the fork is a worker failure, not a
   parent exit.
5. **`@retry` order matters.**
   `@retry(n)` above `@forkexec` retries in the parent — each attempt
   is a fresh fork (fresh heap, fresh world snapshot). `@retry(n)` below
   `@forkexec` retries inside the single worker (attempts share its
   heap). Keep counts small (2–3), especially on recursive forks.
6. **Bounded waits need `@timeout`.** A bare fork call blocks in
   `waitForExit` with no deadline — a hung worker hangs the caller.
   Add `@timeout(ms)` for a preemptive bound: past the budget the parent
   ends the worker and raises a catchable `timeout` error. Don't use bare
   forks on untrusted code. Generous windows on fast forks are unaffected
   (see `tests/37_rta_forkexec.kr`).
7. **`@forkexec` only on `define`, never with `@actor`.** On any other
   statement it is a hard error, as are `@forkexec(...)` arguments,
   duplicates, and `@actor` + `@forkexec` together (mutually exclusive).
   Unknown `@anything` stays a hard error everywhere (typo protection).
8. **Contracts are checked on both sides.** The parent checks args
   pre-spawn and re-checks the returned value post-spawn; the worker
   enforces the same contract on its re-registered definitions. Entry
   violations cost one `type` error and zero workers.
9. **Temp files.** Jobs/results live in the temp dir as
   `kronyn_fork_<pid>_<seq>.{job,res}` and are removed after each call,
   including on failure and on timeout kills.
10. **Build.** No special flags: plain `nim c src/kronyn.nim`. Not
    compilable: `-compile` refuses `@forkexec` with
    `@forkexec is not compilable in v1` (needs a transport decision —
    same rationale as `@actor`).
11. **Remaining RTA interplay.** `@deprecated` warns parent-side only
    (first call per proc per process on stderr; the worker never warns).
    `@tailcallopt` travels into the worker, so deep tail recursion is
    safe inside forked processes too. Entry arity and `@typecheck`
    violations fail fast with no worker spawned.

## When to use `@forkexec` vs `@actor`

| | `@actor` | `@forkexec` |
|---|---|---|
| Child sees | builtins + essentials + itself | builtins + essentials + **all defines + globals** |
| Snapshot cost | one proc + args | whole world (grows with program size) |
| Mutual recursion / helpers | unsupported (inline them) | works |
| Fault containment | process-strong | process-strong |
| Error kind | `actor` | `fork` |

Rule of thumb: `@actor` for self-contained leaf tasks (smallest snapshot,
fastest spawn); `@forkexec` when the task needs the program around it.
