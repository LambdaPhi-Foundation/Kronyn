# Kronyn Error Handling (`ERRORS.md`)

## Model

All interpreter-raised errors are `KronynError` (a `ValueError`):
a `kind` code, a `line` (`-1` when unknown), and a message.
`try` catches `ValueError` — including every `KronynError` — and
sets four root vars: `err` (message, unchanged and substring-stable),
`errkind`, `errline`, `errtrace` (logical stack snapshot at catch
time). Plain `ValueError`s from conversions surface as
kind `"error"`, line `-1`. `Defect`s are never caught: known defect
sites are converted at source (below) so a `Defect` always means a
real interpreter bug.

## Kinds

`arity` (wrong arg count — builtins via a central table, user procs
via closures, syscalls via the registry), `type` (contract and
conversion mismatches), `unknown-command` (intents, methods,
namespaces), `annotation` (RTA misuse), `division` (zero divisor),
`bounds` (`char`/`slice`/`index`), `option` (`unwrap` on `none`),
`io` (EOF, file failures, `exec`, bad imports), `actor` (worker
failures, wrapping the worker message), `fork` (`@forkexec` worker
failures, wrapping the worker message), `timeout` (`@timeout`
deadline expiry — plain or worker-killed, catchable like the rest),
`error` (unclassified).

## Rules that bite

1. **Arity is checked for every builtin** at both dispatch sites
   (intents and dot calls, receiver counted). Shadowing a builtin
   with `define` drops its contract — yours rules instead.
2. **`try` snapshots, then clears.** Caught errors leave no trace
   residue; retry loops clear per swallowed attempt. Uncaught errors
   print `Kronyn error: <msg>` plus a capped (20-frame) logical
   stack, innermost last. Tail-call loops appear as one frame.
3. **Failures that used to be tracebacks are errors now:**
   missing builtin args (`IndexDefect`), `10 / 0` and `mod 0`
   (`DivByZeroDefect`), `char` outside 0..255 (`RangeDefect`),
   `import`/bare `syscall` with no args, `fs.write`/`append` I/O
   failures, stdin EOF (`end of input`, so piped input ends
   cleanly). `slice` out of bounds raises like `index` instead of
   returning `""`.
4. **Lines are best-effort.** `Arg` nodes don't carry file lines
   and `[...]` sub-sources re-lex from line 1 — read the trace
   frames (define-site lines), not the `line N:` prefix, for
   location. `nil` counts as `none` in contract checks.
5. **Actors and forks flatten errors to text.** Worker failures arrive as
   `actor <name>: <msg>` / `fork <name>: <msg>` with the worker trace
   appended; kind/line do not cross the process boundary (parent reports
   kind `"actor"` / `"fork"`). A crashed worker (non-zero exit, no result
   file) reports `worker failed (exit N)`.
6. **Statement-position `name(...)` calls take no phantom args.**
   Bare `none()` means zero args (previously it silently received
   `"("`/`")"` junk that lenient builtins ignored).
