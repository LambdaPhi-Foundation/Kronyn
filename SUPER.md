# Kronyn SUPER.md — Everything About This Project

> Canonical project document. It supersedes `SPEC.md` (which still
> describes the retired "everything is a string" model, the deleted
> KASM/VM pipeline, and byte-marker Options — all historical).
> Detail docs: `Discipline/ACTORS.md`, `Discipline/FORKEXEC.md`,
> `Discipline/TYPES.md`,
> `Discipline/TAILCALL.md`, `Discipline/DEPRECATED.md`,
> `Discipline/TIMEOUT.md`, `Discipline/ERRORS.md`,
> `Discipline/SYSCALL.md`, `PERF.md`,
> `GOCRAZY.md` (on hold).

## 1. Identity

**Kronyn** is an extensible, interpreted programming language written
in **Nim** (≥ 2.2.8, `kronyn.nimble`). It blends the *command
philosophy* of [Tcl](https://www.tcl.tk/) — uniform `command arg…`
syntax, everything invokable, code as data — with the structured
"Intent" patterns of the MORRIS standards, plus opt-in strictness
(RTAs, contracts) where Tcl traditionally has none. Long-term
direction: a language-based operating system in the Lisp Machine /
Oberon spirit, where the interpreter *is* the kernel and the
environment is malleable at runtime.

Build: `nim c src/kronyn.nim`. No dependencies beyond the Nim
tool Rhinehart. Tests are `.kr` scripts run as
`kronyn tests/<name>.kr` (plus `tests/39_perf_bench.kr` for performance).

## 2. Motivation & Reasons

- **Why Tcl-like?** Maximum flexibility and extensibility per
  syntactic unit: new control structures, DSLs, and system
  interfaces are all just new commands (`define`), usable
  immediately with no compiler changes.
- **Why not strict EIAS?** "Everything is a string" was the
  starting point and was deliberately retired: untyped strings
  pushed all errors to runtime, leaked control-byte markers for
  Options, and made `12 - "this"`-class bugs silent. Values are
  now a tagged variant with a string surface (Tcl ergonomics,
  real types underneath).
- **Why a treewalker, still?** It keeps `evolve`/`import`/REPL
  trivially fully general, makes RTAs (`@retry`, `@actor`,
  `@typecheck`, `@tailcallopt`) implementable as interpreter-level
  wrappers, and matches the project's actual bottleneck profile
  (see `PERF.md`: dispatch, not parsing).
- **Why Nim?** Seamless C interop for syscalls, `marshal` for actor
  IPC, deterministic builds, and a single static binary.
- **Why each RTA exists:** `@retry` (transient-failure tolerance),
  `@actor` (fault isolation with OS-process strength),
  `@forkexec` (forked calls that inherit the full world — helpers and
  globals travel, unlike actors' closed world),
  `@typecheck` (fail-fast contracts at call boundaries),
  `@tailcallopt` (constant-stack deep recursion the host language
  cannot otherwise survive — each Kronyn level costs ~6+ Nim
  frames; depth ~1000 already trips Nim's call-depth limiter),
  `@deprecated` (graceful API evolution without breaking callers),
  `@timeout` (bounded windows — cooperative for plain calls,
  preemptive kill for actor/fork workers).

## 3. Philosophy

1. **Commands first.** If it can be a command, it is one — including
   former builtins (the `registerCmd` ladder only holds what
   *must* touch interpreter internals).
2. **Strictness is opt-in, never ambient.** Untyped code runs
   exactly as before; `@typecheck` switches contracts on per
   procedure. Typo protection (unknown `@anything` rejected) is
   the only global strictness.
3. **Measure, don't assume.** Numbers gate every migration
   (`PERF.md`); behavior changes require twin-parity runs.
4. **Fail fast, fail loudly, fail catchably.** Errors are values
   with kinds/lines/traces, never silent wrong answers
   (`Discipline/ERRORS.md`).
5. **Share nothing across isolation boundaries.** Actors copy
   through serialization; temp files are always cleaned up.

## 4. Architecture

```
.kr source
  → Lexer (src/lexer.nim, tokens in src/token.nim)
  → Parser (src/parser.nim → AST in src/ast.nim)
  → Treewalk evaluator (src/eval.nim)
      ├── Env scopes (vars/cmds/syscalls/arity tables, parent chain)
      ├── bodyCache / subCache (thread-local AST caches)
      ├── RTA wrappers (retry / actor / contracts / trampoline)
      └── syscall registry (io / fs / proc)
  → CLI driver (src/kronyn.nim)
```

| Module | Role |
|---|---|
| `src/token.nim` | Token kinds (`tkWord`, `tkString`, `tkSub`, `tkBlock`, `tkDollar`, `tkAt`, `tkDot`, parens/comma/colon/newline, operator set, `tkEof`) |
| `src/lexer.nim` | Char scanner; `"…"` with `\n \t \" \\` escapes, nest-aware `[...]`/`{...}`, `$name`, `@`, `.` vs `..`, `:` as its own token |
| `src/ast.nim` | `Arg` variants (`word string sub block var chain infix typedParam`), `ChainCall` (`name args retType line`), `Stmt` (`cmd args annotations line`) |
| `src/parser.nim` | Recursive descent; `name(...)` calls, `name: type` params, `): ret` returns, `@ann` attachments, expression-statement `__expr` form |
| `src/eval.nim` | Everything runtime: values, scopes, dispatch, builtins, syscalls, RTAs, errors, actor transport |
| `src/kronyn.nim` | CLI: `kronyn <file.kr> [args…]`, hidden `--actor-run <job> <res>`, run stats |
| `src/essentials.kr` | The curated standard intents (see §8) |

### Values (`ValueKind`: `int string list some none`)

- Literals: bare numeric words evaluate as `int` (`007` stays the
  string `"007"` only when quoted); everything else word-like is a
  string; `[...]` evaluates immediately, `{...}` stays deferred.
- Coercion (`$`): ints print canonically, lists join with spaces,
  `some(x)` displays as `x`, `none`/`nil` display as `""`.
- Truthiness: `""`, `"0"`, `0`, empty lists, and `none` are falsy;
  **everything else is truthy — including the string `"false"`**.
- Comparisons `== != < > <= >=` and `&& ||` yield `int` `1`/`0`;
  `contains` yields the **strings** `"true"`/`"false"`.
  `+` adds when both sides are int-like, else concatenates; `..`
  always concatenates; `- * /` (`div`) require integers.

### Scopes

`Env` holds variable, command, syscall, and arity tables plus a
parent link. Calls evaluate in a **fresh child of the root** —
`set` inside a procedure never leaks out (verified by the actor
isolation tests). `callStack`/`bodyCache`/`subCache`/counters are
thread-local; stdout goes through a global lock.

### Essentials loading

Every boot reads `essentials.kr` **before** running any file:
beside the binary first, then the working directory, then a
compile-time embedded fallback (`staticRead`), so the binary always
boots. Runtime files win — no recompile needed to customize.

## 5. Syntax

```kronyn
# comment to end of line
set x 10                          # assignment (value is the result)
set y [$x + 5]                    # [...] evaluates now
set code {writeln $x}             # {...} defers: a block value
writeln "hello"                   # command + args
writeln $y                        # $name interpolates the variable

define greet proc(name) {         # intent: top-level command
    writeln ["Hello " .. $name]
}
greet "World"

define double fn(self) {          # dot-function: receiver is self
    return [$self * 2]
}
writeln 5.double().double()       # 20, chains left to right

if [$x == 0] {return 0} \         # elif/else chain, or bare {else} block
elif [$x == 1] {return 1} \
else {return [$x * 2]}
while {$i < 5} { set i [$i + 1] } # cond block + body block
loop { if [$i > 9] {break} }      # infinite loop, break to exit
```

- `proc` intents are called as statements; `fn` dot-functions hang
  off a receiver (`recv.method(args…)`). A bare `name(...)` call
  takes no phantom args.
- Extra args to user procs are ignored; missing args are an `arity`
  error. Builtins enforce exact arities (dot calls count the
  receiver). Shadowing a builtin with `define` drops its contract —
  yours rules instead.
- `evolve <string>` runs code in the current scope; `import <path>`
  runs a file in it. `try {…}` yields `some(value)` or `none()`,
  setting `err`/`errkind`/`errline`/`errtrace`.

## 6. Core intents (kernel builtins)

Control: `if elif else`, `while cond body`, `loop body`, `iter`
(cond-first, method form `{cond}.iter({body})`), `return`, `break`.
Strings: `len toUpper toLower trim slice index contains replace
split concat`, `..`. Conversion/math: `int str ascii char mod`.
Predicates: `typeof` (`int/string/list/some/none`), strict
`isInt isString isList` (`1`/`0`). Lists arrive via `split`/`lines`
and are threaded with `filter count first last`. Options:
`some none some? none? unwrap unwrapOr map`. Plus `exec`, `try`,
`evolve`, `import`, `set`, `define`, and the `writeln/write/input/
readln` I/O family. (`writeln` echoes its first arg only.)

## 7. Syscalls (full surface in `Discipline/SYSCALL.md`)

`io.output outputln input`; `fs.read` (`some`, missing/unreadable is
`none`) `write append` (`""`) `exists` (plain `1`/`0`) `remove`
(`""`, missing is `none`) `list` (sorted names, missing is `none`);
`proc.exit [code]`, `proc.args` (trailing CLI args, empty in
workers). Central registry with arity checks; `exec "rm -f"` is
banned in-tree.

## 8. `essentials.kr` (the curated set, all `@typecheck`ed)

I/O: `print println ask readfile writefile`. Algorithms: `fib`,
`factorial`, `reverse`, `isPalindrome`, tail-recursive `sum`.
Runnable contract: `tests/32_stdlib_essentials.kr`. Capped by policy —
further libraries ship as opt-in `import` modules, never baked core
(actor spawns re-evaluate essentials at ~4ms each).

## 9. RTAs (full discipline in `Discipline/ACTORS.md` `Discipline/FORKEXEC.md` `Discipline/TYPES.md` `Discipline/TAILCALL.md` `Discipline/DEPRECATED.md` `Discipline/TIMEOUT.md`)

| RTA | Form | Effect |
|---|---|---|
| `@retry(n)` | bare, any position relative to others | re-runs the call up to n times on `ValueError` |
| `@actor` | bare, `define`-only | each call runs in its own OS process (own GC+heap), caller blocks; share-nothing via `marshal`; files are the only shared channel |
| `@forkexec` | bare, `define`-only | like `@actor`, but the child inherits the full world (all defines in registration order + root globals at fork time); result is the only channel back; never combined with `@actor` |
| `@typecheck` | bare + inline `proc(x: int): ret` | strict kind checks on entry (fail fast, pre-spawn), return checked once after success; untyped code unaffected |
| `@tailcallopt` | bare, `define`-only | direct self tail calls (`return [self …]`, `return [r].self(…)`) loop in one frame; depth 100k verified |
| `@deprecated` | bare or `("msg")`, `define`-only | first call per proc per process warns on stderr, call still runs; parent-side only for actors |
| `@timeout(ms)` | one positive int arg, `define`-only | `ms`-millisecond window; plain procs enforced cooperatively per call tree, `@actor`/`@forkexec` workers ended preemptively; expiry is a catchable `timeout` error |

Ordering composes positionally (e.g. `@retry` above `@actor` =
fresh worker per attempt; below = attempts share one heap).
Unknown `@anything` is always a hard error.

## 10. Errors (full taxonomy in `Discipline/ERRORS.md`)

`KronynError(kind, line, message)`; kinds: `arity type
unknown-command annotation division bounds option io actor fork timeout
error`.
Uncaught failures print the message plus a capped logical stack
(TailCall loops show as one frame; worker frames append under
`actor <name>:` or `fork <name>:`). Lines are best-effort (`Arg` nodes don't carry
file lines; sub-sources re-lex from 1) — read traces, not prefixes.

## 11. CLI & observability

```
kronyn [-measure] <file.kr> [args...]  # args visible as list via proc.args
kronyn -compile <file.kr> [-o out] [--emit-c] [--no-cache]  # AOT transpile via cc (see COMPILE.md)
kronyn --actor-run <job> <res>  # internal: worker entry point
kronyn --forkexec-run <job> <res>  # internal: fork worker entry point
```

Normal runs print only program output. With `-measure`, the run
additionally prints the `essentials load` timing up front and the
`body cache hits/miss` plus `evalStmt/Arg/Sub` call counts at the
end; `-d:kronynProfile` builds add per-proc timings there too.
Workers (`--actor-run`, `--forkexec-run`) stay quiet in both modes. `tests/39_perf_bench.kr`
(fib + loop + string pipeline) is the regression benchmark —
run it with `-measure`.

## 12. Tests

`tests/01_basics_vars_arith.kr 02–05` (values, strings, options),
`06–09` (control flow: iter, loop, while, branching),
`10–14` (procedures: chaining, params, recursion, fib, string algos),
`15` (evolve), `16–17` (designed errors), `18–19` (I/O),
`20` (interactive shell), `21–27` (retry + actor demos: fib, faults,
state, retry, farm), `28` (contracts), `29` (actor×contracts),
`30–31` (tail calls, incl. in-worker), `32` (essentials smoke +
negatives), `33` (syscalls), `34` (errors), `35` (deprecated),
`36` (timeouts), `37` (forkexec: world inheritance, isolation,
retry, contracts, tailcall, timeout, misuse negatives), `38_demo_showcase.kr`,
`18_io_stdin.kr` (stdin), `39_perf_bench.kr`. `movieSet/` holds the production
actor stage: 12 self-asserting scenes plus `PRODUCTION.md`.
`tests/compile/` holds the transpiler suite (10 twin + 1 delta + 4
runfail + 13 refusal cases, run with `nim r tests/compile/run.nim`).
`translation/` holds the production transpile stage: 13 twin scenes
plus refusal/runfail probes and `PRODUCTION.md`.
`tests/test1.nim` is an unrelated stock nimble template;
`config.nims` wires `src/` onto the Nim path.

## 13. Implementation methodology

How this codebase is actually built: reproduce-then-fix (every
bug gets a failing script first), twin-parity gates for migrations
(Kronyn-level reimplementation must match builtin output
value-by-value or it stays in Nim), byte-identical full-suite runs
across refactors (28+ files diffed per change), discipline docs
written alongside features (not after), and honest measurement
files (`PERF.md`) that record negative results too.

## 14. Limitations, bugs, risks → `Negatives/`

The canonical ledger lives in `Negatives/` (`README.md` index,
`BUGS.md`, `LIMITS.md`, `RISKS.md`) — this section is the summary.
Rule: fix the bug or update the row, never silently drop one.

| Area | Standing |
|---|---|
| Tree-walk dispatch overhead (~19× per-char) | Accepted and measured (`PERF.md`); mitigations are caches, contracts, RTAs, and `-compile`. No VM is planned — the treewalker stays |
| No static types; contracts runtime-only | By design (opt-in strictness) |
| Actors are processes (~4ms Linux / ~15–25ms Windows per spawn), caller blocks, share-nothing | By design (`Discipline/ACTORS.md`); coarse tasks only |
| Forks are processes with full-world snapshots (all defines + globals per call); locals not inherited, no nesting | By design (`Discipline/FORKEXEC.md`, `Negatives/LIMITS.md` L12); coarse tasks only |
| No timeouts by default | Pair with `@timeout` (`Discipline/TIMEOUT.md`) |
| `try` catches `ValueError` only; lines best-effort; `exec` is platform-shell-defined | By design (`Discipline/ERRORS.md`, `Discipline/SYSCALL.md`) |
| Compiled catch-leaks (~7 small Values per catch, measured) | Documented (`COMPILE.md` #14); pools declined with numbers |
| Lexer string-blind bracket nesting can crash (`IndexDefect`) | Open bug, both backends (`Negatives/BUGS.md` B1) |
| `set` on non-names, dropped cond tails, first-pair infix, deep-recursion limiter, dead `test1.nim`, usage typo, backup-file litter, stale `SPEC.md` | Tracked (`Negatives/BUGS.md` B2–B8, R5) |
| No sandbox; vision–engine gap; POSIX-only-reviewed branches; bus factor | Open concerns (`Negatives/RISKS.md`) |

## 15. Future goals

- **GOCRAZY phases 0–3** (`GOCRAZY.md`): profile → `--dump-state`/mainbox → `-gocrazy` self-specializing driver → tracing emitter backend. Explicitly on hold.
- **Opt-in import modules** beyond the capped essentials core.
- **Actor hardening:** `@timeout` bounds hung workers; remaining:
  watchdog policies for untrusted code, richer worker argv story.
- **Tail-call micro-opts:** cached tail-call descriptors, frame reuse instead of clearing (~70µs/iter today).
- **Housekeeping:** archive `SPEC.md`, remove dead `test1.nim`, clean backup files, fix the `file for found` typo.

## 16. Map

- Start here → `SUPER.md` (this file)
- RTA + subsystem discipline → `Discipline/` (`ACTORS.md` `FORKEXEC.md` `TYPES.md` `TAILCALL.md` `DEPRECATED.md` `TIMEOUT.md` `ERRORS.md` `SYSCALL.md`)
- Issues, concerns, limitations → `Negatives/` (`README.md` index)
- Transpiler → `COMPILE.md` (distinct from `GOCRAZY.md`, which is the on-hold Futamura track)
- Numbers → `PERF.md` · Deferred compiler dream → `GOCRAZY.md`
- Code → `src/eval.nim` (runtime) `src/{lexer,parser,ast,token}.nim` `src/kronyn.nim` `src/essentials.kr`
- Proof → `tests/*.kr` (numbered `01–39` basic→advanced; `32/33/34` are the subsystem contracts), `tests/39_perf_bench.kr`
