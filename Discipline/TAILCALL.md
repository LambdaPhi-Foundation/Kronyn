# Kronyn Tail-Call Optimization (`@tailcallopt` RTA)

## What it is

`@tailcallopt` marks a `define`d procedure for tail-call optimization.
A body that ends in a direct self-call — `return [self ...]` (intent
style) or `return [recv].self(...)` (dot-chain style) — loops in one
Nim frame instead of recursing. Without it, even depth ~1000 trips
Nim's call-depth limiter (each Kronyn level costs ~6+ Nim frames);
with it, depth 100000 returns normally.

```kronyn
@tailcallopt
define countdown proc(n, acc) {
    if [$n == 0] {return $acc} else {return [countdown [$n - 1] [$acc + $n]]}
}
writeln [countdown 100000 0]  # 5000050000, constant Nim stack
```

## Discipline (read before using)

1. **Only direct self tail calls loop.** `return [self args...]`
   and `return [recv].self(args...)` qualify. `return [[self ...] + 1]`
   (fib-style), trailing bare `[self ...]` expression statements, and
   mutual recursion do NOT — they recurse normally. Non-tail bodies
   are unaffected (the annotation is a harmless no-op for them).
2. **Frames reset per iteration.** Each loop rebinds params on a
   cleared frame, so conditionally-`set` locals never leak across
   iterations (semantically identical to fresh recursion frames).
3. **`@tailcallopt` is bare and define-only.** With arguments, or on
   any non-`define` statement, it is a hard error, as is any unknown
   `@anything`. A `return [self ...]` carrying statement annotations
   (e.g. `@retry` on the call itself) takes the normal path.
4. **Arity is enforced with the usual message.** A miscounted tail
   call raises `line L: <name> expects N args, got M`, same as a
   normal mis-call.
5. **Composes positionally.** `@retry` stays outside (one attempt =
   one full trampolined run from the original args). `@actor`
   carries the flag into the worker, so deep tail recursion is safe
   inside worker processes too. `@typecheck` checks entry args
   fail-fast, re-checks computed args each iteration, and verifies
   the final return once.
6. **Signals stay inside.** The loop runs on a `TailCallSignal`
   that is deliberately *not* a `ValueError`, so `try`/`@retry`
   never swallow it; only the trampoline catches it. (Actor
   transport re-raises it as a backstop — it must never cross a
   process boundary.)
7. **Costs.** Each tail iteration re-parses its tiny call
   sub-expression (~70µs/iter measured: 100k in ~7s). Non-tail
   nesting still uses real stack per nesting level — only tail
   *chains* flatten. Caching tail-call descriptors and reusing
   (instead of clearing) frames are the planned follow-up micro-opts.
