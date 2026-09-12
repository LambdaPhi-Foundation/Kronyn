# Kronyn Timeouts (`@timeout` RTA)

## What it is

`@timeout(ms)` gives a `define`d procedure an `ms`-millisecond window
to run. Expiry raises a catchable `timeout` error; the call does not
complete.

```kronyn
@timeout(500)
define fetch proc(url) {
    return [syscall fs.read $url]
}
set r [try {fetch "bigfile.txt"}]
if [$r.none?()] {
    writeln ["gave up: " .. $err]  # ... timed out after 500ms
}
```

Two enforcement mechanisms, chosen by dispatch:

- **Plain procedures: cooperative deadlines.** Entering the call
  pushes a wall-clock deadline (`epochTime`, never CPU time, so I/O
  waits count); a single check at the top of `evalBody` enforces it.
  Every block evaluation — loop iterations, call bodies, branches —
  passes through `evalBody`, so any code that can take time is
  covered. Cost when no timeout is armed: one length check.
- **`@actor` procedures: preemptive kill.** The parent waits on the
  worker with the timeout budget and ends the worker past it, so a
  hung worker (even one stuck outside the interpreter, e.g. in
  `exec`) cannot outlive its window. No orphan processes: the
  kill-then-reap sequence runs on every expiry path, and the
  `ActorJob` transport is unchanged.

## Discipline (read before using)

1. **Exactly one positive integer argument.** `@timeout(500)`.
   Missing, extra, non-integer, zero, or negative windows are
   `annotation` errors at define time, never at first call. (Bare
   `@timeout` and `@timeout(100, 200)` both fail; negative literals
   are unrepresentable anyway — `-` lexes as an operator.)
2. **Catchable, with one caveat.** Expiry is an ordinary
   `KronynError` of kind `timeout`: `try` catches it, `errkind` reads
   `"timeout"`, `@retry` treats it like any failure. But a `try`
   *inside* the timed body swallows the signal while the deadline
   stays armed, so `loop { try { ... } }` livelocks instead of
   terminating — put fallbacks around the *call*, not inside the
   body. (Same trade-off as Python's `TimeoutError`.)
3. **Fresh window per `@retry` attempt.** One attempt is one full run
   from the original args (see `TAILCALL.md` rule 5): each attempt
   re-arms now+ms, attempts stay linear. A hung proc under
   `@retry(3)` costs ~3 windows, then exhausts with the timeout.
4. **Nesting takes the minimum.** A callee can never extend its
   caller's window: each entry computes `min(outer deadline,
   now+ms)`. Direct and mutual recursion therefore cannot reset the
   clock — the window always spans the whole call tree. On exit the
   outer deadline is restored.
5. **Entry checks run before the window arms.** Arity and
   `@typecheck` violations fail fast with no timer started and no
   worker spawned. `@deprecated` warns as usual.
6. **Actor specifics.** The budget covers spawn + essentials load +
   run (~5ms floor — keep windows well above it). Each outer
   `@retry` attempt is a fresh worker with a fresh budget; worker
   `innerRetry` attempts share the attempt's budget. The worker does
   not enforce cooperatively — it doesn't need to, the parent ends
   it. An outer plain-proc window does not preempt a blocked actor
   wait; it resumes enforcement when the call returns. Crashed
   workers (no result file, died well before the budget) still
   report `worker failed (exit N)`, not a timeout.
7. **What a timeout cannot interrupt.** A single uninterruptible host
   call (`exec`, a giant `fs.read`) runs to completion; the error
   fires on the next block boundary. `proc.exit` inside a timed proc
   still exits the process (or the worker, reported as worker
   failure).
8. **`@timeout` is `define`-only.** On any other statement it is a
   hard `annotation` error, as are duplicates and unknown
   `@anything`. Composes positionally with all other RTAs.

## Verification

`tests/36_rta_timeout.kr` covers outcomes (generous window runs,
tight window on an infinite loop fires deterministically on any
machine), all six misuse negatives, `errkind` shape, and
`@retry`/`@typecheck`/`@tailcallopt`/`@actor` interplay (each retry a
fresh window; fast actor unaffected; slow actor worker killed with
no orphan). Wall-clock behavior (fires at ~ms, not early/late) and
orphan-freedom (`tasklist` after kills) are verified manually.

## Compiled behavior (`-compile`)

Fully supported (see `COMPILE.md`): cooperative arming per call tree
with checks at proc entries and loop heads, fresh windows per
`@retry` attempt, fail-fast entry checks. Message, kind, and
catchability are identical; `errline` follows the compiled true-line
rule (deviation #1).
