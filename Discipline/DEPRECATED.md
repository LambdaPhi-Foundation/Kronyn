# Kronyn Deprecation Marker (`@deprecated` RTA)

## What it is

`@deprecated` marks a `define`d procedure as deprecated. Calls still
run normally — the first call per procedure per process prints a
warning to **stderr**, later calls stay silent.

```kronyn
@deprecated
define oldadd proc(a, b) {
    return [$a + $b]
}

@deprecated("use newgreet instead")
define oldgreet proc(name) {
    return ["hi " .. $name]
}

writeln [oldadd 3 4]      # 7 + one stderr line
writeln [oldadd 10 20]    # 30, silent
```

Warning format (stderr, greppable):

```
Kronyn deprecated: oldadd (line 2): oldadd is deprecated
Kronyn deprecated: oldgreet (line 6): oldgreet is deprecated: use newgreet instead
```

## Discipline (read before using)

1. **Warn-once per proc per process.** The warned set is keyed by
   procedure name and lives for the process lifetime. A recursive
   proc (fib-style, ~177 calls for `fib(10)`) warns exactly once —
   deprecation can never flood output. Redefining a proc (`define`
   again) clears its entry, so the new definition gets a fresh
   warning budget.
2. **Call-time only.** Defining a deprecated proc is silent — unused
   compat shims produce no noise at load. Only invocation warns.
3. **Optional message, at most one.** Bare `@deprecated` uses the
   default text; `@deprecated("use X instead")` appends the custom
   text. The message is evaluated once at define time in the defining
   scope. Two or more arguments are an `annotation` error, as is a
   duplicate `@deprecated` on one definition.
4. **Warns after entry checks, before execution.** Arity and
   `@typecheck` parameter violations fail fast with no warning —
   only valid calls warn. The warning fires once outside the
   `@retry` loop, so retries never re-warn. Like `@typecheck` return
   checks, it costs nothing on the steady path after the first call
   (one table lookup).
5. **Actors warn in the parent only.** The warning fires pre-spawn on
   the caller side; the worker re-registers the procedure directly
   (never through the `define` path) and runs silently. No duplicate
   output crosses the process boundary.
6. **`@deprecated` is `define`-only.** On any other statement it is a
   hard `annotation` error, like `@actor`/`@typecheck`/`@tailcallopt`.
   Unknown `@anything` (e.g. `@deprecatd`) is rejected everywhere.
   Like all RTAs it composes positionally with `@retry`/`@actor`/
   `@typecheck`/`@tailcallopt` in any order.
7. **Stderr, not stdout.** Warnings go to stderr under the existing
   output lock, so piped program output stays clean and concurrent
   actor output cannot interleave mid-line.

## Verification

`tests/35_rta_deprecated.kr` covers behavior (bare/message/dot-form
still run), misuse negatives (two args, duplicate, typo), and
interplay (`@typecheck`/`@retry`/`@tailcallopt`/`@actor`). Warn-once
frequency and stderr routing cannot be asserted from inside Kronyn
(a script cannot capture its own stderr), so they are verified
manually: run with stderr redirected and count lines — one per
deprecated proc per process, including under recursion, 1000-deep
tail calls, and repeated actor calls.

## Compiled behavior (`-compile`)

Fully supported (see `COMPILE.md`): warn-once per proc per process
on stderr, after entry checks, literal messages only. Covered by
`tests/compile/pass_deprecated.kr` (stdout+stderr twinned).
