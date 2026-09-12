# D.md — Rewrite Kronyn in D (detailed instructions)

> Goal: a faithful D (DMD 2.10x / LDC 1.3x, `dub`, no third-party deps
> beyond Phobos) port of the whole Kronyn tree (`src/*.nim`,
> `src/essentials.kr`, `src/kronyn_rt.*`, CLI, `-compile` transpiler,
> suites). Behavior gates are byte-identical stdout/stderr/exit codes vs
> the Nim binary. Read `SUPER.md` (canonical), `COMPILE.md` (transpiler
> contract + 16 deviations), `Discipline/*.md` (7 RTAs + errors/syscalls),
> `PERF.md`, `Negatives/` (B1–B8/L1–L11/R1–R5) first. Do not invent a VM.
> The treewalker stays the execution engine. The GC is the main
> consideration — keep the design GC-simple up front (§5) before porting
> dispatch.

## 0. Source inventory (read in this order)

| File | Lines | What to extract |
|---|---|---|
| `src/token.nim` (31) | token kinds | `tkWord tkString tkSub tkBlock tkDollar tkAt tkDot tkLParen tkRParen tkComma tkColon tkNewline tkPlus tkMinus tkStar tkSlash tkEqEq tkBangEq tkLt tkGt tkLtEq tkGtEq tkAnd tkOr tkBang tkDotDot tkEof` + per-token `line` |
| `src/lexer.nim` (147) | char scanner | `peek` (guarded) vs `advance` (**unguarded — B1**), `lexString` escapes (`\n \t \" \\`), `lexNested` depth counting, `lexWord` stop-set, `.` vs `..`, `#` comments |
| `src/ast.nim` (60) | AST | `Arg = word\|string\|sub\|block\|var\|chain\|infix\|typedParam`, `ChainCall{name,args,retType,line}`, `Stmt{cmd,args,annotations,line}` |
| `src/parser.nim` (225) | recursive descent | `parseChainArgs`, single-infix `parseArg`, `parsePrimary` (`!`, `name(...)` + `.m()` chains, `: ret`), `parseTypedParam`, `parseStmt` (`@ann` + `__expr` vs `cmd` forms), `parse` loop |
| `src/eval.nim` (1721) | runtime | everything in §4–§8 below |
| `src/kronyn.nim` (177) | CLI | `--actor-run`, `--forkexec-run`, `-compile` (FNV-1a cache + cc), `[-measure] file [args]` |
| `src/codegen.nim` (1229, `CodegenVersion=4`) | transpiler | AST→C emitter, refusals, ownership discipline |
| `src/kronyn_rt.h` (173) / `.c` (1463) | C runtime | refcounted `KRN_Value`, envs, builtins, `setjmp` handlers — **reuse as-is in phase 1** (§9, `extern(C)` link or shell-out) |
| `src/essentials.kr` (55) | stdlib | 10 `@typecheck`ed intents, load order beside-binary → cwd → embedded (`import("essentials.kr")` fallback) |

Gates: `tests/*.kr` numbered `01–39` basic→advanced — `01–19` core,
`21–27/29/31` (actors), `28` (contracts), `30` (100k tailcall),
`32/33/34` (stdlib/syscall/error contracts), `35/36/37`
(deprecated/timeout/forkexec), `38` showcase, `39` bench,
`tests/compile/` (28 via `run.nim`),
`movieSet/` (12 actor scenes), `translation/` (13 twins + rej/runfail).

## 1. Target layout (dub, Phobos-only)

```json
// dub.json — no "dependencies" in phase 1
{ "name": "kronyn", "targetType": "executable", "sourcePaths": ["source"],
  "dflags": ["-w"], "versions": ["KronynProfile"] }
```

```
kronyn-d/
  dub.json
  source/
    token.d      // TokenKind, Token
    lexer.d      // Lexer struct
    ast.d        // Arg, ChainCall, Stmt, Program
    parser.d     // Parser struct
    value.d      // Value, KronynError, Control signals
    env.d        // Env, registries
    eval.d       // dispatch, builtins, syscalls, RTAs, actor transport
    codegen.d    // transpiler (codegen.nim port)
    app.d        // CLI driver (kronyn.nim port)
    essentials.kr
    kronyn_rt.h / kronyn_rt.c (copied verbatim, phase 1)
```

Binary must sit beside `essentials.kr` + `kronyn_rt.c` at runtime.
`dub build` (debug, `dmd`) is the `nim c` equivalent;
`dub build -b release --compiler=ldc2` is the release counterpart for
limiter comparisons (B5). Keep everything `@safe`-adjacent but do not let
`@safe` purity fights delay M1 — mark the treewalker `@trusted` where it
touches the C runtime or process APIs and move on.

## 2. Semantics bible (must-match)

* **Values:** `long`, `string` (bytes, immutable), `list(Value[])`,
  `some(Value)`, `none`. `wordToValue`: strict all-digits
  (`^[+-]?[0-9]+`, no whitespace — mirror `tryWordInt`) → int else string.
* **Coercion (`$`):** int canonical (`to!string`), list space-joined
  (recursive), `some` unwraps, `none` → `""`.
* **Truthiness:** falsy = `""`, `"0"`, `0`, empty list, `none`; `"false"`
  truthy.
* **Operators** (`eval.nim:396-452`): `+` adds iff both `isInt`
  (int-kind or int-like string) else concat; `..` always concat; `- * /`
  require ints; `/` = `div`, `0` → `division` line `-1`; `== !=` with
  int/int + string/string fast paths else `$`-compare; `< > <= >=` via
  `asInt`; `&& || !` → `1/0`; `contains` → `"true"/"false"` strings.
* **Calls:** `proc` statements; `fn` dot-chains (`self` first, L→R); bare
  `name(...)` no phantom args. Extra user args ignored; missing → `arity`.
  Builtins exact arities (receiver counted). Shadowing a builtin removes
  its arity entry.
* **`set`:** evaluate `args[1]` only; target must be `word` — **refuse**
  otherwise (fix B2; Nim derefs the variant → `FieldDefect`). Message:
  `set target must be a name` (match `codegen.nim:610`).
* **`evolve/import/try`:** `evolve` = `evalSub` in current scope;
  `import` = read + `eval`, missing → `io import: file not found: <p>`;
  `try {b}` → `some/none` + root `err/errkind/errline/errtrace`.

## 3. Lexer (fix B1)

Direct port with one fix: Nim `advance (lexer.nim:15-16)` indexes
`src[pos]` unchecked — unterminated `"` / trailing `\` / `writeln ["[" ..
["x" .. "]"]]` is an out-of-bounds read (in D: a `RangeError` in `@safe`
bounds-checked code, silent garbage with `-boundscheck=off`). Guard every
index (`if (pos >= src.length)`) and throw a clean `KronynError` instead.
Then implement the documented direction (string-aware `lexNested` +
bounds guards) with the B1 repro as regression. Preserve: escapes,
stop-set, `.`/`..`, `#` comments, `tkNewline("\\n")`, lone `=`/`&`/`|` as
words, `-` as operator (negatives unrepresentable — `@timeout` relies on
it).

## 4. Parser (line-for-line)

Mirror `parser.nim` including quirks: one-infix-max `parseArg` (B4:
`[$a+$b+$c]` keeps first pair — **preserve** in interpreter; transpiler
folds left-assoc, deviation #10, zero suite impact); `__expr` vs `cmd`
in `parseStmt` (rewind on miss via saved index); `typedParam` define-only
(`misplaced type annotation` elsewhere); `: ret` on calls; missing
`)`/type → `line N:` errors. Do not thread file lines into `Arg`
(L6 best-effort; compiled true-lines are deviation #1).

## 5. Ownership design (decide before dispatch — GC-simple wins)

D has a GC, exceptions, delegates, and `SumType` — the closest match to
Nim of the three rebuilds. Stay GC-simple:

```d
// value.d
import std.sumtype;
alias ValueList = Value[];
struct SomeWrap { Value v; }
struct Value {
    SumType!(long, string, ValueList, SomeWrap, None) payload;
    // helpers: toStr ($), truthy, isInt, asInt, kindName
}
struct None {}
class KronynError : Exception {
    string kind; int line;
    this(string k, int l, string m) { super(fmtMsg(l, m)); kind=k; line=l; }
}
class ReturnSignal : Throwable { Value v; this(Value v){super("");this.v=v;} }
class BreakSignal : Throwable { this(){super("");} }
class TailSignal : Throwable { Value[] args; this(Value[] a){super("");args=a;} }
```

* Values as a `struct Value` wrapping `SumType` (value semantics, GC
  references inside) is the simplest that passes the suites — immutable
  after construction so aliasing (e.g. `str()` on a string) is safe.
  Alternative `class Value` with `final` subclasses works too, but the
  `SumType` + exhaustive `match!` forces the B2 check Nim missed, so
  prefer it.
* `Env`: `class Env` with `Value[string] vars`, `Command[string] cmds`
  (`alias Command = Value delegate(Env, Value[])`), `int[2][string]`
  builtin arities, nested syscall AA tables, `Env parent, root`,
  `returning/breaking` flags, `ret`, `tailFn/tailArity`. `newEnv(parent)`:
  `root = parent ? parent.root : this`. `callFn`: fresh child of `root`,
  bind positionally, `evalBody`, honor `root.returning`. Delegates capture
  define-time `params/body` naturally — no closure encoding needed (unlike
  Zig/Odin).
* Control flow with exceptions (mirrors Nim 1:1): `eval_*` throw
  `ReturnSignal/BreakSignal/TailSignal` + `KronynError`; `try` catches
  `KronynError` only (plus `ConvException` from conversions mapped to
  `error/-1`); `Tail/Break/Return` propagate through `try/@retry`
  untouched (tail signals never swallowed — `TAILCALL.md` rule 6).
  `withFrame` = push `(name,line)` on entry, `scope(exit) pop`, snapshot
  `lastTrace` on first `KronynError` (mirror `withFrame`,
  `eval.nim:133-141`). Trace cap 20 with middle-cut.
* GC policy: rely on the GC for the whole treewalker (no manual `free`,
  no `RefCounted`). Disable the GC only inside the emitted-C timing
  micro-benchmarks if at all. Never `GC.disable` around `eval` — actor
  children are processes, pause times don't cross the isolation boundary.

### Caches / observability

`static` (optionally `__gshared` + mutex, or `thread_local`-style via
`static` in a `thread` context) AA caches for `bodyCache/subCache`,
`callStack`, `timeoutStack`, `deprecatedSeen`, plus counters
(`bodyCacheHits/Miss, callsEvalStmt/Arg/Sub`). `evalSub`: expression
shapes cached, statements not (B3: multi-stmt conditions keep first only).
`evalBody`: `checkTimeout()` then cache hit/miss + `eval`. `-measure`
prints `essentials load` + counts. Stdout via one global
`core.sync.mutex.Mutex` (`withLock` / `synchronized`); `writeln` semantics
= Nim `echo` (normalize newlines in test comparisons).

## 6. Builtins + syscalls (exact table)

Port `builtinAritySpecs (eval.nim:246-260)` + `initKernel (1037-1255)`
byte-for-byte (same checklist as CPP.md §5.5: first-arg-only `writeln`,
sentinel-word `if`, per-iteration `evalSub/evalBody` loops honoring
`breaking/returning`, `split` on strings, `lines/filter/count/first/last`
split on `\n`, `char 0..255`, strict `int` via `to!long` (garbage →
`error`), `"true"/"false"` contains, `map` with `it` in root-child and
`none` short-circuit, shell `exec` with merged stderr + ignored status +
stripped output via `std.process.executeShell`).

* Case conversion: use `std.uni.toUpper/toLower` (Unicode-aware, matches
  Nim) — no deviation #5 fork needed. If you use `std.ascii` for speed,
  document the ASCII fork like the C runtime.
* Syscalls (`1022-1033`): `io.output/outputln/input`, `fs.read/write/append/
  exists/remove/list` (`none` vs `""` policies + sorted names incl. `.`/`..`
  via `dirEntries`, span-mode sorted), `proc.exit/proc.args` (empty in
  workers). Central arity checks; `exec "rm -f"` banned. `readln` null
  (EOF) → `io end of input`.

## 7. The seven RTAs (messages must match Nim strings)

* `@retry(n)` anywhere incl. plain statements; swallow `KronynError` only.
* `@actor` bare define-only → §8.
* `@forkexec` bare define-only, never with `@actor`; full-world snapshot
  (all defines + root vars), new error kind `fork`.
* `@typecheck` bare + `proc(x: int): ret`; `TypeNames =
  [int,string,list,some,none,any]`; define-time failures; entry checks
  pre-retry/pre-spawn (`expects <t> for '<p>', got <g>`), return check
  post-success (`must return <t>, got <g>`); `None` for nil.
* `@tailcallopt` bare define-only; `matchTailSelfCall` for
  `return [self …]` / `return [recv].self(…)` (single-stmt sub, no call
  annotations, arity-checked); `trampolineCall` loop clearing vars,
  re-checking contracts per iteration; 100k verified (`30_rta_tailcall`).
* `@deprecated` bare/`("msg")` define-only; warn-once per proc per process
  on stderr (`Kronyn deprecated: <n> (line <l>): <t>`), parent-side only
  for actors.
* `@timeout(ms)` one positive int define-only; cooperative
  `MonoTime`/`SysTime` (`min(outer, now+ms)`, check in `evalBody`, fresh
  per retry, entry checks pre-arm, inner-`try` livelock documented); actor
  path preemptive (§8); expiry `timeout <owner> timed out after <ms>ms`.
  Ordering: retry-above-actor = fresh worker/attempt; below = shared heap;
  typecheck outermost-in/innermost-out; annotated tail-calls go normal path.

## 8. Actors (subprocess + std.json, share-nothing)

Mirror `spawnActorCall (1344-1390)` + `actorRunLocal/runActorJobFile`:

```d
struct ActorJob {
    string name; string[] params; string[] ptypes; string body;
    string rtype; JSONValue[] args; size_t retryMax; int line; bool tailOpt;
}
```

1. Convert `Value` ↔ `JSONValue` (`std.json`; commands never cross).
2. Write `temp/kronyn_actor_<pid>_<seq>.job` (`std.file.write`,
   `std.process.thisProcessID`), re-exec `thisExePath()
   --actor-run <job> <res>` via `std.process.spawnProcess` +
   `wait`/`tryWait`.
3. Child: fresh quiet interpreter, re-register proc **plain**, inner-retry
   loop, write `ActorResult{ok,val,err}` (+ worker-trace suffix).
4. Parent blocks; `@timeout` polls (`tryWait` + `Thread.sleep`) then
   `kill()` + `wait()` — no orphans. Missing result → `timeout` if clock ≥
   budget−50ms else `actor <n>: worker failed (exit N)`; `!ok` →
   `actor <n>: <msg>` + trace.
5. `scope(exit)` cleanup of job+res on all paths.
6. Closed world (§7 of CPP.md applies verbatim: builtins+essentials+self
   only, `argv` empty, `proc.exit` = worker failure, `io.input` forbidden,
   stdout inherited).

## 9. CLI + `-compile` (phase 1: emit C, reuse runtime)

* CLI strings match `kronyn.nim` exactly (keep B7 `file for found` typo
  until a usage assertion lands). `essentialsSource()`: beside-exe →
  cwd → `import("essentials.kr")` (string import) fallback. `argv` →
  root `argv` list. `-measure` prints load + counters; workers quiet.
* Port `codegen.d` fn-for-fn from `codegen.nim` (`Ctx/Define/fresh/emit/
  cStr/sanitizeC/kindConst`, two-pass `collectDefine` for forward refs,
  `genExpr/genStmt/...` with `std.array.Appender!string`). Emit C against
  the **unmodified** `kronyn_rt.h/.c` first (link it via
  `extern(C)`/`dub` `sourceFiles` only for in-process tests if convenient;
  the shipped `-compile` path still shells to `gcc/clang/cc`). Keep
  `CodegenVersion = 4` in the FNV-1a cache key (reimplement the exact
  `cacheKey` in `kronyn.nim:5-14`), `tmp/kronyn_cache/<hex>/bin(.exe)`,
  `cached/compiled <src> -> <out>` messages, `--emit-c` (+ readable indent
  pass), `--no-cache` escape, 30-day prune, `gcc→clang→cc` lookup,
  `"<cc>" -O2 -fwrapv -I"<appdir>" …`, keep-`.c`-on-failure.
* Enforce the v1 subset with identical refusal strings and preserve all 16
  `COMPILE.md` deviations (#1 true lines, #4 refuse multi-stmt conds, #5
  n/a if you use `std.uni`, #6–7 empty-split/wrap incl. `-fwrapv`, #9
  `list` incl. `.`/`..`, #10 left-assoc chains vs B4, #11 forward refs,
  #12 deeper C recursion, #14 ~7-Value catch leak census, #15
  literals-only + cycle refusal, #16 shell `exec`). Static errors refuse
  at compile time (`try/@retry` catch runtime only).

## 10. Milestones & gates

* M1: values/ops/`set/if/while/loop/iter/break/return`/`try`/builtins
  minus `map`/syscalls/essentials → twins `01–13`, `19`, `02–04`
  string basics, `18` (piped stdin).
* M2: `define proc/fn`, recursion, chains, shadowing, `@typecheck/
  @tailcallopt` → `pass_procs/typecheck/tailcall` + `30_rta_tailcall` 100k.
* M3: `import` (inline/hermetic/cycle-guarded), `try` as
  `catch(KronynError)` + root vars, `@retry/@deprecated/@timeout`,
  `tests/compile/` 28/28.
* M4: `--emit-c`, `exec`, cache (~57× hits), GC audit (`GC.stats` /
  `GC.profileStats` on success paths; document the per-catch bound instead
  of pools), full sweeps (`tests/*.kr`, `movieSet/`, `translation/`,
  newline-normalized diffs).
* Perf: `39_perf_bench.kr` + `-measure`; keep `PERF.md` reasoning (19×
  per-char floor, 3× composites from call frames) — cite numbers, don't
  chase a VM. Compare `dmd -debug` vs `ldc2 -O` for the B5 limiter note.

## 11. Pitfalls (from `Negatives/`)

B1 guard (keep bounds checks on — never build with
`-boundscheck=off` until M4 green); B2 refuse (exhaustive `match!` on
`Arg` — the compiler forces the check Nim missed); B3/B4 preserve;
B5 trampoline (D stack also overflows on plain recursion, GC frames make
it worse — same mitigation); B6 delete `test1.nim`, wire `dub test`;
B7 fix + assertion; B8 `*~ #*# .#*` in `.gitignore`. L1 ceiling accepted;
L3 coarse actors; L5 `try` = `KronynError` only (never catch `Throwable`);
L6 lines best-effort; L9–L11 compiled bounds; R2 Linux pass before POSIX
claims; R3 no sandbox — say so. D-specific: never catch `Exception` where
`KronynError` is meant (you will swallow `ConvException` paths that must
map to `error/-1` explicitly); `synchronized` stdout only — never one
mutex per `Env`; keep `Value` a `struct`, `Env` a `class` (reversing them
fights the GC for zero benefit).
