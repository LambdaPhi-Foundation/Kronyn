# BUGS — confirmed broken behavior

> Reproduce first, list second. Each entry has a reproducer (or the
> reason one is unnecessary), the blast radius, and the fix direction.
> Statuses: **open** (acknowledged, unfixed), **mitigated** (a
> supported path avoids it), **kept** (intentional, documented).

## B1 — Lexer: string-blind bracket nesting can crash (high, open)

`lexNested` counts `[`/`]`/`{`/`}` without respecting `"…"`
strings, and `lexString` runs past the end of input on unterminated
strings. A `]` inside a string at depth 1 ends the token early;
nested `[...]` inside `[...]` with bracket-chars in strings crashes
both backends with `IndexDefect` (shared lexer):

```kronyn
writeln ["[" .. ["x" .. "]"]]   # IndexDefect in interpreter AND binary
```

Workaround: keep bracket characters out of strings inside subs and
blocks (e.g. build `"]"` via `93.char()`). Fix direction:
string-aware nesting in `lexNested` plus bounds guards in
`lexString`/`lexNested`, as its own reproduce-then-fix cycle with a
full regression — it touches the shared lexer, so it is *not* a
transpiler-side patch.

## B2 — `set` with a non-name target crashes the interpreter (medium, open)

`set $x 1` / `set "x" 1` read the wrong variant field and die with
`FieldDefect`. The compiled backend refuses these cleanly (`set
target must be a name`), which is the intended behavior everywhere.
Fix direction: same refusal in `eval.nim`'s `set` case.

## B3 — Dropped trailing statements in multi-statement conditions (medium, kept)

`evalSub` parses one statement and silently drops the rest, so a
multi-statement `while` condition evaluates only its first line.
Kept for compatibility; the compiler refuses such conditions
(`COMPILE.md` #4) rather than enshrine the drop.

## B4 — First-pair-only chained infix in `[...]` subs (low, kept)

`[$a + $b + $c]` evaluates `a+b` and drops `+ $c` (fast-path shape);
at statement level the same text is an arity/unknown-command error.
Kept for compatibility; the compiler folds left-assoc instead
(`COMPILE.md` #10) — the one deliberate semantic fork, with zero
suite impact (no test chains operators).

## B5 — Deep plain recursion trips the debug call-depth limiter (medium, mitigated)

Each Kronyn level costs ~6+ Nim frames; depth ~1000 already trips the
`nim c` (debug) limiter. Mitigations, in order: `@tailcallopt` for
direct self tail calls (depth 100k verified, and a real C loop when
compiled), otherwise restructure into loops. Not a crash in release
builds, but the debug default is what developers run.

## B6 — Dead `tests/test1.nim` template + broken `nimble test` (low, open)

Stock nimble template importing a nonexistent `prettybored` module;
`nimble test` additionally shells to `git`, which may not exist.
Unrelated to Kronyn execution. Fix direction: delete `test1.nim`
and either wire `nimble test` to `nim r tests/compile/run.nim` or
drop the task.

## B7 — Usage typo `file for found` (low, open)

`src/kronyn.nim` prints `error: file for found:` for missing script
files. Cosmetic; the `-compile` path already uses the correct
wording. Fix direction: one-word edit plus a usage-text assertion.

## B8 — Editor backup files litter `src/` and `tests/` (low, hygiene)

`#…#`, `.#…`, `*.kr~` files from editing sessions sit in the tree,
untracked. Fix direction: delete them and extend `.gitignore` with
`*~`, `#*#`, `.#*`.
