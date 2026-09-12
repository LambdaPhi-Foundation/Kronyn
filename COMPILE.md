# Kronyn Ahead-of-Time Transpiler (`-compile`)

> NOT the Futamura projection: `-gocrazy` (see `GOCRAZY.md`, on hold)
> specializes the interpreter with respect to a program and bakes
> evaluated state. `-compile` translates `.kr` source to C and shells
> to the system compiler for a standalone native binary. Different
> mechanism, different output, shared honesty rule (measure first).

## Usage

```
kronyn -compile prog.kr [-o out] [--emit-c] [--no-cache]
```

- Default output is `prog` / `prog.exe` beside the source.
- `--emit-c` keeps the intermediate `<out>.c` for inspection; without
  it the C file lives briefly in the temp dir and is removed (on C
  compiler failure it is kept and its path is printed).
- Requires gcc, clang, or cc on `PATH`; the runtime sources
  (`kronyn_rt.h`, `kronyn_rt.c`) must sit beside the `kronyn` binary
  (same deploy rule as `essentials.kr`).
- Compiled binaries take trailing CLI args as `proc.args` and print
  only program output — no metrics chart (that stays an interpreter
  `-measure` feature).

## Architecture

```
prog.kr → Lexer → Parser → AST → subset check → emitter → prog.c
                                                        ↘ cc → prog
```

- `src/codegen.nim`: the **same parser** feeds both backends, so an
  accepted program means the same thing up to the subset below.
  Anything outside it is refused with `Compile error: line N: ...`
  instead of silently miscompiling.
- `src/kronyn_rt.h` / `src/kronyn_rt.c`: shared runtime (values,
  scopes, builtins, syscalls, errors). Emitted C is small readable
  glue calling into it.
- Ownership: every `KRN_Value*` is an **owned** reference;
  helpers borrow inputs and return owned results; `krn_set` retains;
  emitted code releases statement temps explicitly. Values are
  immutable, so aliasing (e.g. `to_str` on a string) is safe.

## v1 subset (M1+M2+M3, shipped)

Values, int/string arithmetic and comparisons (`+` adds when both
sides are int-like else concatenates, `- * /` require integers;
multi-operator chains fold **left-assoc**, see deviation 10),
`..`, `&& || !`, all kernel builtins **except** `map`,
`if/elif/else`, `while`/`loop`/`iter`/`break`, top-level `return`,
`set`, `try` (some/none values + err vars), user `define`
(`proc`/`fn`, recursion incl. mutual, dot- and intent-calls,
shadowing, last-value returns, `@typecheck` contracts,
`@tailcallopt` trampolined loops, `@retry` with fresh windows,
`@deprecated` warn-once, `@timeout` cooperative windows), `import`
of compilable files (spliced inline, hermetic binary),
`essentials.kr` compiled wholesale, writeln-style intents,
dot-chaining, `[...]` holding a single expression or
builtin/syscall/user call, `{...}` in control-flow positions, and
the full `syscall` registry.

Refused with file:line diagnostics: `evolve` `map` (no
dynamic-code backends), `@actor` and `@forkexec` (need a transport
decision), every other `@annotation`, nested defines/imports, non-block
if/while/try bodies, multi-statement conditions, dynamic import
paths and RTA counts/windows, retry/timeout counts above 2^31-1,
non-literal `set` targets.

## Parity record (twin gate: byte-identical stdout vs interpreter)

- `tests/01_basics_vars_arith.kr 02_basics_string_pipeline.kr
  03_basics_concat.kr 06_control_iter.kr 07_control_loop_break.kr
  08_control_while.kr 09_control_branching_fizzbuzz.kr
  10_procs_dot_chaining.kr 11_procs_params.kr 12_procs_recursion.kr
  13_procs_fib.kr 19_io_files.kr`,
  `tests/18_io_stdin.kr` (piped stdin), `tests/30_rta_tailcall.kr`
  (100k-deep C loop, plain fib, typechecked tail sum) — identical.
- `essentials.kr` wholesale: fib/factorial/reverse/isPalindrome/sum/
  println/readfile/writefile verified through a dedicated demo.
- `@typecheck` contracts: valid calls, param violations (fail fast,
  no traceback — entry checks sit outside the pushed frame, mirroring
  the closure), return violations — identical incl. messages.
- Designed-error tests `test13/14.kr`: interpreter fails at runtime,
  compiled refuses at compile time; same `line N: unknown command`.
- Runtime errors match by substring + exit code: `division by zero`,
  `index/slice out of bounds`, `unwrap called on none`,
  `invalid integer` (kind `error`, no line — mirrors the raw
  `ValueError` fallback), essentials `expects string for 'msg'`.
- Refusal battery: 10/10 refused with precise messages, exit 1
  (M1 set).
- `tests/compile/` (run with `nim r tests/compile/run.nim`):
  10 twin cases (subset, procs, typecheck, try, retry, deprecated
  incl. stderr, timeout, exec, import, tailcall), 1 delta case
  (true `errline`), 4 runfail cases (contract param/return,
  division, uncaught timeout), 13 refusal cases — 28/28 green.
- `exec` twins on both outcomes (portable `echo`, merged shell
  error text); `tests/04_basics_builtins_exec.kr` identical.

## Known deviations from the interpreter (all documented, none silent)

1. **Error lines are real, not best-effort.** Where the walker
   hardcodes `line -1` (`/ 0`, `mod 0`, `char`, `slice`, `index`,
   `unwrap`, conversions), compiled errors carry the true Kronyn
   line. Substring gates still match.
2. **Block bodies re-lex from line 1**, exactly like the walker's
   `bodyCache` — by construction (same parser on the same source).
3. **`set` with a non-name target is refused.** The walker crashes
   with a `FieldDefect` there; refusing loudly is strictly better.
4. **Multi-statement conditions are refused.** The walker's `evalSub`
   silently drops trailing statements; we decline to enshrine that.
5. **`toUpper`/`toLower`/`trim` are byte/ASCII-based** (Nim's are
   Unicode-aware). ASCII programs — the whole suite — are unaffected.
6. **`split` with an empty delimiter** yields the whole string as one
   item (Nim edge semantics unverified; no test covers it).
7. **Huge-int overflow wraps** (C `long long`, built with
    `-fwrapv` so the wrap is defined, not UB; `LLONG_MIN / -1`
    excepted). The walker raises an `OverflowDefect` in debug
    builds. Both are outside the spec.
8. **`if` conditions must be `[...]`** (or plain values); `while`
   conditions `[...]`/`{...}`. A `{...}` `if`-condition tests its
   source text in the walker — a footgun we refuse.
9. **`fs.list` includes `.`/`..`** like Nim's `walkDir`, on both
   platforms. Sorted with byte order, names only.
10. **Chained infix folds left-assoc** (`$a + $b + $c` is `(a+b)+c`).
    The walker's `evalSub` fast path evaluates the first pair and
    silently drops the rest; no suite test chains operators, and the
    compositional reading is the only sane contract for new code.
11. **Forward references resolve.** Two-pass registration means a
    proc is callable before its `define` executes; the walker fails
    such calls at runtime. Accepted liberalization (standard AOT).
12. **Deep plain recursion survives further in C** (tiny frames vs
    the debug build's call-depth limiter). Same direction as the
    `@tailcallopt` loop, which is a true loop with cleared frames
    and per-iteration contract re-checks, mirroring the trampoline.
13. **Static vs dynamic errors split at compile time.** Unknown
    commands, arity mistakes, and other rejections are compile
    errors, so `try`/`@retry` can only catch *runtime* failures
    (division, bounds, options, contracts, timeouts, I/O). A
    `try` around a static mistake refuses to compile instead of
    catching at runtime.
14. **Caught errors leak ~7 small Values per catch, measured.**
    Recovery reclaims whole abandoned envs (census: 0 envs) plus
    deadline frames, but in-flight value temps are not swept (C has
    no stack walk). Leak-check binaries (`gcc -DKRN_LEAK_CHECK`,
    `krn-leak-check` report on stderr) read 0/0 on every success
    path; a 20k-catch loop leaves exactly 140000 values. Linear and
    bounded per catch — keep `try`/`@retry` out of hot infinite
    loops with perpetually failing bodies, as the discipline docs
    already demand. Full pools were costed and declined: sound
    reclamation needs store barriers on every retain/release for
    UAF safety; the measured bound does not justify it. Revisit
    with workload evidence.
15. **RTA counts/windows/paths/messages must be literals**
    (`@retry(3)`, `@timeout(500)`, `import "x.kr"`, `@deprecated`
    word/string; counts/windows capped at 2^31-1). The walker
    evaluates them in the defining scope; the compiler has no such
    scope. Imports resolve at compile time (hermetic binary, no
    runtime reread) and cycles are refused.
16. **`exec` output is platform-shell-defined.** The binary merges
    child stderr like the walker and ignores status; twin gates
    involving shell error text hold per platform (verified on
    Windows for success and failure).

## Roadmap (per the agreed milestones)

- **M1 — done:** runtime + straight-line subset, `-compile` driver.
- **M2 — done:** procedures, `@typecheck`, `@tailcallopt` loops,
  essentials wholesale (M1's special cases deleted).
- **M3 — done:** `import` (inline, hermetic, cycle-guarded), `try`
  via `setjmp`/`longjmp` (some/none + err vars), `@retry`
  (defines + statements, fresh windows), `@deprecated` (warn-once),
  `@timeout` (cooperative windows), `tests/compile/` (27/27, now 28/28
  with the `@forkexec` refusal).
- **M4 — done:** readable `--emit-c` (string-aware indent pass),
  `exec` via `popen` (merged output, status ignored), content-
  addressed output caching (`md5(version + C + runtime)`, 30-day
  prune, `--no-cache` escape; ~57x on hits), memory audit
  (dynamic failure messages, `-fwrapv`, empty-dir `qsort` guard,
  2^31 RTA caps, `KRN_LEAK_CHECK` census: 0/0 on success paths,
  pools declined with measurement), full sweeps green.
- Explicitly out of scope until re-proposed: `evolve` (needs the
  evaluator at runtime — antithetical to AOT), compiled `@actor` /
  `@forkexec` workers (need a transport decision; both keep refusing).

## Output caching

`kronyn -compile` hashes `CodegenVersion` + emitted C (which already
embeds source, transitive imports, and essentials) + `kronyn_rt.c`
content (local FNV-1a; cryptographic strength is unnecessary for a
build cache). Hits copy the cached binary to `-o` (`cached a.kr -> b`
vs `compiled …`, ~0.04s vs ~2.3s measured) and restore `<out>.c`
under `--emit-c`. Entries live under `kronyn_cache/` in the temp
dir, pruned past 30 days on store; failures never populate it.
Bump `CodegenVersion` in `codegen.nim` on any emitter change.

## Platform matrix

Developed and swept on Windows (gcc 15.2.0). The POSIX branches
(`fs.list` via `readdir`, `popen`, realtime clock) are
review-by-inspection; run `nim r tests/compile/run.nim` on Linux
with gcc present for the second column — the runner is portable
(newlines normalized) and needs no other changes.
