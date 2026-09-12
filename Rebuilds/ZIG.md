# ZIG.md — Rewrite Kronyn in Zig (detailed instructions)

> Goal: a faithful Zig (stable 0.14.x, `std`-only, `build.zig`) port of the
> whole Kronyn tree (`src/*.nim`, `src/essentials.kr`, `src/kronyn_rt.*`,
> CLI, `-compile` transpiler, suites). Behavior gates are byte-identical
> stdout/stderr/exit codes vs the Nim binary. Read `SUPER.md` (canonical),
> `COMPILE.md` (transpiler contract + 16 deviations), `Discipline/*.md`
> (7 RTAs + errors/syscalls), `PERF.md`, `Negatives/` (B1–B8/L1–L11/R1–R5)
> first. Do not invent a VM. The treewalker stays the execution engine.
> The allocator is the main adversary — design `Value`/`Env` ownership up
> front (§5) before porting dispatch.

## 0. Source inventory (read in this order)

| File | Lines | What to extract |
|---|---|---|
| `src/token.nim` (31) | token kinds | `tkWord tkString tkSub tkBlock tkDollar tkAt tkDot tkLParen tkRParen tkComma tkColon tkNewline tkPlus tkMinus tkStar tkSlash tkEqEq tkBangEq tkLt tkGt tkLtEq tkGtEq tkAnd tkOr tkBang tkDotDot tkEof` + `line` per token |
| `src/lexer.nim` (147) | char scanner | `peek` (guarded) vs `advance` (**unguarded — B1**), `lexString` escapes (`\n \t \" \\`, else keep `\`), `lexNested` depth counting, `lexWord` stop-set, `.` vs `..`, `#` comments, `\n` tokens |
| `src/ast.nim` (60) | AST | `Arg = word\|string\|sub\|block\|var\|chain\|infix\|typedParam`, `ChainCall{name,args,retType,line}`, `Stmt{cmd,args,annotations,line}` |
| `src/parser.nim` (225) | recursive descent | `parseChainArgs`, `parseArg` (one infix max), `parsePrimary` (`!` prefix, `name(...)` + trailing `.m()` chain, `: ret` on calls), `parseTypedParam`, `parseStmt` (`@ann` prefix, `__expr` form when single chain/infix + newline/EOF, else `cmd(args...)` with optional `(...)` head), `parse` loop over newlines |
| `src/eval.nim` (1721) | runtime | everything in §4–§8 below |
| `src/kronyn.nim` (177) | CLI | `--actor-run`, `--forkexec-run`, `-compile` (FNV-1a cache + cc), `[-measure] file [args]` |
| `src/codegen.nim` (1229, `CodegenVersion=4`) | transpiler | AST→C emitter, subset refusals, ownership discipline |
| `src/kronyn_rt.h` (173) / `.c` (1463) | C runtime | `KRN_Value` refcounted, `KRN_Env`, builtins, syscalls, `setjmp` handlers, timeouts — **reuse as-is in phase 1** |
| `src/essentials.kr` (55) | stdlib | 10 `@typecheck`ed intents, load order beside-binary → cwd → embedded |

Tests that gate you: `tests/*.kr` numbered `01–39` basic→advanced —
`01–19` core (basics, control, procs, evolve, errors, I/O, shell),
`21–27/29/31` (actors), `28` (contracts), `30` (tailcall),
`32/33/34` (stdlib/syscall/error contracts), `35/36/37`
(deprecated/timeout/forkexec), `38` showcase, `39` bench,
`tests/compile/` (28 cases via `run.nim`), `movieSet/` (12 actor scenes),
`translation/` (13 transpile twins + rej/runfail).

## 1. Target layout (zig build, no external deps)

```
kronyn-zig/
  build.zig          # exe "kronyn", no dependencies, -O Debug default
  build.zig.zon      # name .kronyn, no .dependencies
  src/
    token.zig        # TokenKind enum, Token{kind, lexeme, line}
    lexer.zig        # Lexer struct
    ast.zig          # Arg union, ChainCall, Stmt, Program=ArrayList(Stmt)
    parser.zig       # Parser struct
    value.zig        # Value, KronynError, Control
    env.zig          # Env, registries
    eval.zig         # dispatch, builtins, syscalls, RTAs, actor transport
    codegen.zig      # transpiler (codegen.nim port)
    main.zig         # CLI driver
    essentials.kr
    kronyn_rt.h/.c (copied verbatim, phase 1 — compiled via build.zig addCSourceFile)
```

Single `kronyn` binary must sit beside `essentials.kr` and `kronyn_rt.c`
at runtime (same deploy rule as Nim). No `build.zig.zon` dependencies in
phase 1 — hand-roll FNV-1a + `std.json` for actor jobs. `zig build`
(debug) is the `nim c` equivalent; `zig build -Doptimize=ReleaseFast` is
the release counterpart for limiter comparisons (B5).

## 2. Semantics bible (must-match, test-gated)

* **Values:** `i64`, `[]const u8` (bytes), `list(ArrayList(*Value))`,
  `some(*Value)`, `none`. `wordToValue`: all-digits (`^[+-]?[0-9]+`,
  no whitespace, `tryWordInt` semantics) → `int` else `string`.
  `007` quoted stays `string`; bare `007` → `int 7`.
* **Coercion (`$`):** int canonical (`format("{d}")`), list join with single
  spaces (recursive `$`), `some(x)` → `$x`, `none`/nil → `""`.
* **Truthiness:** falsy = `""`, `"0"`, `0`, empty list, `none`. Everything
  else truthy **including `"false"`**.
* **Operators** (`evalArg` infix, `src/eval.nim:396-452`):
  `+` adds iff both `isInt` (int-kind OR int-like string) else concatenates;
  `..` always concatenates; `- * /` require ints (`type` error otherwise);
  `/` is `div`, `0` → `division` error line `-1`; comparisons `== !=`
  (int/int, string/string fast paths, else `$`-compare) and `< > <= >=`
  (`asInt`, may throw → mapped to `error`) and `&& || !` yield `int 1/0`;
  `contains` yields **strings** `"true"/"false"`.
* **Syntax forms:** `"..."` literal, `[...]` immediate, `{...}` deferred
  (block evaluates via `evalBody`, i.e. re-parse + cache; block *value* is
  its source string).
* **Calls:** `proc` intents as statements; `fn` dot-functions with `self`
  as first arg, chains left→right; bare `name(...)` takes no phantom args.
  Extra user-proc args ignored; missing → `arity` error. Builtins enforce
  exact arities (receiver counted). Shadowing a builtin deletes its arity
  entry — yours rules.
* **`set`:** `set name value…` — value is `evalArg(args[1])` only. Must
  **refuse** non-name targets (fix B2): if `args[0]` is not `.word` raise
  `arity/type` `set target must be a name` like `codegen.nim:610`
  instead of unwrapping the union payload unchecked.
* **`evolve/import`:** `evolve` = `evalSub` of the string in current scope;
  `import` = read file + `eval` in current scope, missing → `io`
  `import: file not found: <path>`.
* **`try`:** `try {body}` → `some(result)` or `none()`, sets root vars
  `err/errkind/errline/errtrace`. Catches `KronynError` + plain
  conversion failures (mapped to `kind=error line=-1`); never catches
  control signals or Zig errors outside the interpreter domain.

## 3. Lexer (fix B1, keep everything else)

Port `lexer.nim` 1:1 with one fix:

* `advance()` **must bounds-check**. Nim's `l.src[l.pos]` throws
  `IndexDefect` on unterminated `"…"` / trailing `\` (`lexString:38,45`).
  In Zig an unchecked `src[pos]` is a panic / safety violation in Debug.
  Repro `writeln ["[" .. ["x" .. "]"]]` must become a clean `KronynError`,
  not a panic. Guard every index (`if (pos >= src.len)`) and return
  `error.UnterminatedString`-mapped-to-`KronynError{kind="io",...}` — but
  gate it behind a dedicated commit so the current crash repro becomes a
  passing test you add.
* Keep: string-blind nesting is the *bug* — after the guard fix, implement
  the documented direction (string-aware `lexNested` + bounds guards) as
  its own commit with the B1 repro as regression.
* Keep exact token surface: `tkNewline` lexeme `"\\n"`, `=` alone is
  `tkWord("=")`, single `&`/`|` are `tkWord`, `-` lexes as operator
  (so negative literals are unrepresentable — `@timeout` discipline
  depends on it).

## 4. Parser (line-for-line)

Mirror `parser.nim` control flow including quirks:

* `parseArg` = `parsePrimary` + at most **one** operator + `parsePrimary`
  (no precedence climbing). This plus `evalSub`'s fast path is B4:
  `[$a + $b + $c]` evaluates first pair, drops rest. **Preserve** in the
  interpreter; the transpiler folds left-assoc (deviation #10) — the one
  deliberate fork, zero suite impact.
* `parseStmt`: `@`-annotations first, then try `parseArg`; if result is
  `chain/infix` and next is newline/EOF → `__expr` statement; else rewind
  and parse `cmd` + optional `(...)` head + space-separated args.
* `name: type` → `typedParam` only in `define` signatures; elsewhere raise
  `misplaced type annotation`. `name(...) : ret` supported on both dot and
  bare calls. Missing `)` / missing type name → errors with `line N:`
  prefix (these become `KronynError kind=error` via the generic catch in
  `try`/driver).
* `Arg` nodes carry `line` only for infix roots/chains; sub-sources re-lex
  from line 1 (L6 best-effort lines — do not "fix" by threading lines;
  compiled backend does true lines, deviation #1).

## 5. Ownership design (decide before dispatch — the whole port hinges here)

Zig has no GC, no exceptions, no closures. Fix the allocator story first:

```zig
pub const Kind = enum { int, str, list, some, none };
pub const Value = struct {
    kind: Kind,
    i: i64 = 0,
    s: []const u8 = "",
    items: []const *Value = &.{},
    inner: ?*Value = null,
};
pub const KronynError = struct { kind: []const u8, line: i32, msg: []const u8 };
pub const Control = union(enum) {
    ok: *Value,
    ret: *Value,      // return signal
    brk: void,        // break signal
    tail: []*Value,   // tail-call args
    err: KronynError,
};
```

* Recommended: one long-lived `ArenaAllocator` per interpreter run (backed
  by a `GeneralPurposeAllocator` in `main`), passed as `std.mem.Allocator`
  into every `eval_*`. Values are immutable after construction so aliasing
  (e.g. `str()` on a string returning the same pointer) is safe and no
  per-value free is needed; the arena is reset only on process exit.
  Actor children are separate processes, so no cross-process allocator
  sharing. Do **not** `dupe` every string — intern token lexemes / cache
  keys by reference into the source buffer where possible; `dupe` only
  across scope boundaries that outlive the source (`set`, job files).
* `Env`: struct with `StringHashMap(*Value)` vars,
  `StringHashMap(Command)` cmds, `StringHashMap([2]i32)` builtin arities,
  nested syscall tables, `parent: ?*Env`, `root: *Env`, `returning/breaking`
  flags, `retVal`, `tailFn/tailArity`. Commands are `*const fn` pointers
  or a `union` of builtin-fn vs user-proc closure struct
  (`{params, ptypes, body, rtype, ...}` allocated in the arena) — Zig has
  no capturing closures, so store the captured body explicitly.
* Control flow without exceptions: every `eval_*` returns
  `Control` (or `KronynError!Control` for OOM only). `err` is caught by
  `try`/RTA wrappers; `ret/brk/tail` propagate through `try/@retry`
  untouched (tail signals never swallowed — `TAILCALL.md` rule 6).
  `withFrame` = push `(name,line)` on entry, `defer pop`, snapshot
  `lastTrace` on first `err` (mirror `withFrame`, `eval.nim:133-141`).
  Trace cap 20 with middle-cut.
* Memory-failure policy: OOM (`error.OutOfMemory`) is fatal — print and
  exit 1, never map it to a catchable `KronynError`. Only interpreter
  domain failures become `Control.err`.

### Caches / observability

`threadlocal var body_cache / sub_cache: StringHashMap(Program/Arg)`,
`call_stack`, `timeout_stack`, `deprecated_seen`, plus counters
(`bodyCacheHits/Miss, callsEvalStmt/Arg/Sub`). `evalSub`: expression
shapes cached, statements not (B3: multi-stmt conditions keep first only).
`evalBody`: `checkTimeout()` then cache hit/miss + `eval`. `-measure`
prints `essentials load` + counters. Stdout via one global
`std.Thread.Mutex` (`withLock`); `print` with `std.io.getStdOut().writer()`
(Nim `echo` semantics — normalize `\r\n` in test comparisons).

## 6. Builtins + syscalls (exact table)

Port `builtinAritySpecs` + `initKernel` byte-for-byte (same checklist as
CPP.md §5.5): first-arg-only `writeln`, sentinel-word `if`
(`"elif"/"else"` words), per-iteration `evalSub/evalBody` loops honoring
`breaking/returning`, `split` on strings, `lines/filter/count/first/last`
split on `\n` (`filter` substring, `count/first/last` skip empties),
`char` bounds `0..255`, strict `int` (garbage → `error`), `contains` →
`"true"/"false"`, `map` with `it` in root-child and `none` short-circuit.

* Case conversion: Zig `std.ascii` is ASCII-only. Nim's is Unicode-aware.
  Either vendor a small Unicode fold table or document the ASCII-only fork
  per deviation #5 (the C runtime already takes the fork).
* `exec`: `std.process.Child` with `sh -c` (POSIX) / `cmd /c` (Windows),
  merged stderr, status ignored, output stripped of trailing newlines.
* Syscalls: `io.output/outputln/input`, `fs.read` (`some`, missing →
  `none`), `write/append` (`""`, failures → `io`), `exists` (`1/0`),
  `remove` (`""`, missing → `none`), `list` (sorted names only, missing →
  `none`, includes `.`/`..` — preserve `walkDir` semantics),
  `proc.exit [code]`, `proc.args` (root `argv`, empty in workers). Central
  arity table; unknown ns/method → `unknown-command`. `exec "rm -f"`
  banned in-tree. Stdin EOF → `io end of input`.

## 7. The seven RTAs (messages must match Nim strings)

Unknown `@anything` always hard-errors:

* `@retry(n)` — any position, statements + defines. Re-runs on
  `Control.err` up to `n`. `n<1` → 1.
* `@actor` — bare, `define`-only. §8.
* `@forkexec` — bare, `define`-only, never with `@actor`. Same transport
  as `@actor` but child inherits full world (all defines in registration
  order + root globals snapshot); new error kind `fork`.
* `@typecheck` — bare + inline `proc(x: int): ret`. `TypeNames =
  {int,string,list,some,none,any}`. Missing/unknown types fail at
  **define time**. Entry checks pre-retry/pre-spawn (zero workers on
  violation: `expects <t> for '<p>', got <g>`); return checked once
  post-success (`must return <t>, got <g>`). `nil` counts as `none`.
* `@tailcallopt` — bare, `define`-only. `matchTailSelfCall`: `return
  [self …]` (sub holding single `self`-headed stmt, no annotations) or
  `return [recv].self(…)` (chain ending in `self`). Arity enforced with
  usual message. `trampolineCall`: clear-vars loop, re-check contracts per
  iteration, `Control.tail` caught only by trampoline (never by
  `try/@retry`). Depth 100k verified (`tests/30_rta_tailcall`).
* `@deprecated` — bare or `("msg")`, `define`-only. First call per proc
  per process → `stderr: Kronyn deprecated: <name> (line <l>): <text>`,
  call still runs; parent-side only for actors.
* `@timeout(ms)` — one positive int, `define`-only. Cooperative
  wall-clock (`std.time.Instant`/`milliTimestamp`, IO waits count): push
  `min(outer, now+ms)` on entry, `checkTimeout()` in `evalBody`, pop on
  exit (`defer`); fresh window per `@retry` attempt; entry checks run
  before arming; `try` *inside* the body livelocks (documented, same as
  Python). Actor path preemptive (§8). Expiry = catchable `timeout`
  `<owner> timed out after <ms>ms`.

Compositions: `@retry` above `@actor` = fresh worker per attempt (outer);
below = retries inside one worker (inner). `@typecheck` outermost on
entry, innermost on exit. `return [self …]` with call annotations takes
the normal (non-tail) path.

## 8. Actors (subprocess, share-nothing)

Mirror `spawnActorCall`: every `@actor` call = one OS process.

1. `ActorJob{name,params,ptypes,body,rtype,args,retryMax,line,tailOpt}`
   (+ `timeoutMs` out-of-band) → serialize with `std.json.stringify` to
   `temp/kronyn_actor_<pid>_<seq>.job` (`Value` trees only — commands
   never cross; write a `SerValue` tagged union for the JSON shape).
2. Re-exec `current_exe (--actor-run <job> <res>)` via
   `std.process.Child` + `selfExePath()`.
3. Child: fresh quiet interpreter, re-register proc **plain**, inner-retry
   loop, write `ActorResult{ok,val,err}` (+ worker trace suffix).
4. Parent blocks (`wait`); `@timeout` polls then `kill()` + `wait()` — no
   orphans on any path. Missing result → `timeout` if clock ≥ budget−50ms
   else `actor <name>: worker failed (exit N)`. `ok==false` →
   `actor <name>: <msg>\n<worker trace>`.
5. Delete job+res files with `defer`/`errdefer` on all paths (RAII).
6. Closed world: builtins + essentials + itself only; parent vars read as
   `""`; worker `set` never leaks; `proc.args` empty; `proc.exit` kills
   worker (failure); `io.input` races — forbid; stdout inherited.

Why not threads: the treewalker mutates shared caches/scopes; a process
boundary is stronger and simpler, and Zig's allocator story stays trivial
(one arena per process). Keep caches `threadlocal` + stdout `Mutex` so a
future pool stays possible.

## 9. CLI + `-compile` (phase 1: emit C, reuse runtime)

* CLI strings match `kronyn.nim` exactly (keep B7 `file for found` typo
  until a usage assertion lands). `essentialsSource()`: beside-exe →
  cwd → `@embedFile("essentials.kr")`. `argv` → root `argv` list.
  `-measure` prints load + counters; workers quiet.
* Port `codegen.zig` fn-for-fn from `codegen.nim` (`Ctx/Define/fresh/emit/
  cStr/sanitizeC/kindConst`, two-pass `collectDefine` for forward refs,
  `genExpr/genStmt/...`). Emit C against the **unmodified**
  `kronyn_rt.h/.c` first (compile it via `addCSourceFile` in phase 1 if
  convenient, but the emitted program still shells to `gcc/clang/cc`).
  Keep `CodegenVersion = 4` in the FNV-1a cache key (reimplement the exact
  `cacheKey` in `kronyn.nim:5-14`), `tmp/kronyn_cache/<hex>/bin(.exe)`,
  `cached/compiled <src> -> <out>` messages, `--emit-c` (+ readable indent
  pass), `--no-cache` escape, 30-day prune, `gcc→clang→cc` lookup,
  `"<cc>" -O2 -fwrapv -I"<appdir>" …`, keep-`.c`-on-failure.
* Enforce the v1 subset with identical refusal strings and preserve all 16
  `COMPILE.md` deviations (#1 true lines, #4 refuse multi-stmt conds, #5
  ASCII case fork, #7 wrap + `-fwrapv`, #9 `list` incl. `.`/`..`, #10
  left-assoc chains vs B4, #11 forward refs, #12 deeper C recursion, #14
  ~7-Value catch leak census, #15 literals-only + cycle refusal, #16 shell
  `exec`). Static errors refuse at compile time (`try/@retry` catch
  runtime only).

## 10. Milestones & gates (do not skip)

* M1: values/ops/`set/if/while/loop/iter/break/return`/`try`/builtins
  minus `map`/syscalls/essentials → twins `01–13`, `19`, `02–04`, `18`
  (piped stdin).
* M2: `define proc/fn`, recursion + mutual, chains, shadowing, last-value
  returns, `@typecheck/@tailcallopt`, essentials deleted special-cases →
  `pass_procs/typecheck/tailcall` + `30_rta_tailcall` 100k.
* M3: `import` (inline/hermetic/cycle-guarded), `try` as `Control.err` +
  root vars, `@retry/@deprecated/@timeout`, `tests/compile/` 28/28.
* M4: `--emit-c`, `exec`, cache (~57× hits), leak audit (`gpa.deinit()`
  must report empty on success paths; document the per-catch bound instead
  of pools), full sweeps (`tests/*.kr`, `movieSet/`, `translation/`,
  newline-normalized diffs).
* Perf: `39_perf_bench.kr` + `-measure`; keep `PERF.md` reasoning (19×
  per-char floor, 3× composites from call frames) — cite numbers, don't
  chase a VM. Compare Debug vs ReleaseFast for the B5 recursion limiter
  note.

## 11. Pitfalls (from `Negatives/`)

B1 guard (no unchecked `src[pos]` — Debug panics; ReleaseFast is UB);
B2 refuse (exhaustive `switch` on `Arg` — the compiler forces the check
Nim missed); B3/B4 preserve; B5 trampoline (Zig call stack also overflows
— same mitigation); B6 delete `test1.nim`, wire `zig build test`;
B7 fix + assertion; B8 `*~ #*# .#*` in `.gitignore`. L1 ceiling accepted;
L3 coarse actors; L5 `try` = `Control.err` only; L6 lines best-effort;
L9–L11 compiled bounds; R2 Linux pass before POSIX claims; R3 no sandbox
— say so. Zig-specific: never hold an `ArrayList`/`HashMap` across a
recursive `eval` that may re-enter it without cloning out first; never mix
the arena with `page_allocator` for `Value` memory; OOM is fatal, never
catchable.
