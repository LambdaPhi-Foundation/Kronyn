# ODIN.md — Rewrite Kronyn in Odin (detailed instructions)

> Goal: a faithful Odin (recent `dev` release, `core`-only, `odin build`)
> port of the whole Kronyn tree (`src/*.nim`, `src/essentials.kr`,
> `src/kronyn_rt.*`, CLI, `-compile` transpiler, suites). Behavior gates are
> byte-identical stdout/stderr/exit codes vs the Nim binary. Read `SUPER.md`
> (canonical), `COMPILE.md` (transpiler contract + 16 deviations),
> `Discipline/*.md` (7 RTAs + errors/syscalls), `PERF.md`, `Negatives/`
> (B1–B8/L1–L11/R1–R5) first. Do not invent a VM. The treewalker stays the
> execution engine. The context allocator is the main adversary — design
> `Value`/`Env` ownership up front (§5) before porting dispatch.

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
| `src/kronyn_rt.h` (173) / `.c` (1463) | C runtime | refcounted `KRN_Value`, envs, builtins, `setjmp` handlers — **reuse as-is in phase 1** (§9, `foreign import`) |
| `src/essentials.kr` (55) | stdlib | 10 `@typecheck`ed intents, load order beside-binary → cwd → embedded (`#load` fallback) |

Gates: `tests/*.kr` numbered `01–39` basic→advanced — `01–19` core,
`21–27/29/31` (actors), `28` (contracts), `30` (100k tailcall),
`32/33/34` (stdlib/syscall/error contracts), `35/36/37`
(deprecated/timeout/forkexec), `38` showcase, `39` bench,
`tests/compile/` (28 via `run.nim`),
`movieSet/` (12 actor scenes), `translation/` (13 twins + rej/runfail).

## 1. Target layout (odin build, core-only)

```
kronyn-odin/
  src/
    token.odin     # Token_Kind enum, Token struct
    lexer.odin     # Lexer struct
    ast.odin       # Arg union, Chain_Call, Stmt, Program=[dynamic]Stmt
    parser.odin    # Parser struct
    value.odin     # Value, Kronyn_Error, Control
    env.odin       # Env, registries
    eval.odin      # dispatch, builtins, syscalls, RTAs, actor transport
    codegen.odin   # transpiler (codegen.nim port)
    main.odin      # CLI driver (package main)
    essentials.kr
    kronyn_rt.h / kronyn_rt.c (copied verbatim, phase 1)
```

Build with `odin build src -out:bin/kronyn` (debug default). No
`shared`/`vendor` deps in phase 1 — `core:encoding/json`,
`core:os/os2`, `core:time`, `core:strings`, `core:strconv`,
`core:path/filepath`, `core:fmt` cover everything. Binary must sit beside
`essentials.kr` + `kronyn_rt.c` at runtime. `-o:speed` is the release
counterpart for limiter comparisons (B5).

## 2. Semantics bible (must-match)

* **Values:** `int(i64)`, `string` (bytes), `list([dynamic]^Value)`,
  `some(^Value)`, `none`. `word_to_value`: strict all-digits
  (`^[+-]?[0-9]+`, no whitespace — mirror `tryWordInt`) → int else string.
* **Coercion (`$`):** int canonical, list space-joined (recursive), `some`
  unwraps, `none` → `""`.
* **Truthiness:** falsy = `""`, `"0"`, `0`, empty list, `none`; `"false"`
  truthy.
* **Operators** (`eval.nim:396-452`): `+` adds iff both `is_int`
  (int-kind or int-like string) else concat; `..` always concat; `- * /`
  require ints; `/` = `div`, `0` → `division` line `-1`; `== !=` with
  int/int + string/string fast paths else `$`-compare; `< > <= >=` via
  `as_int`; `&& || !` → `1/0`; `contains` → `"true"/"false"` strings.
* **Calls:** `proc` statements; `fn` dot-chains (`self` first, L→R); bare
  `name(...)` no phantom args. Extra user args ignored; missing → `arity`.
  Builtins exact arities (receiver counted). Shadowing a builtin removes
  its arity entry.
* **`set`:** evaluate `args[1]` only; target must be `.word` — **refuse**
  otherwise (fix B2; Nim derefs the variant → `FieldDefect`). Message:
  `set target must be a name` (match `codegen.nim:610`).
* **`evolve/import/try`:** `evolve` = `eval_sub` in current scope;
  `import` = read + `eval`, missing → `io import: file not found: <p>`;
  `try {b}` → `some/none` + root `err/errkind/errline/errtrace`.

## 3. Lexer (fix B1)

Direct port with one fix: Nim `advance (lexer.nim:15-16)` indexes
`src[pos]` unchecked — unterminated `"` / trailing `\` / `writeln ["[" ..
["x" .. "]"]]` is an out-of-bounds read (in Odin: a bounds panic with
`-debug`, silent garbage without). Guard every index (`if pos >= len(src)`)
and return a clean `Kronyn_Error` instead. Then implement the documented
direction (string-aware `lex_nested` + bounds guards) with the B1 repro as
regression. Preserve: escapes, stop-set, `.`/`..`, `#` comments,
`tkNewline("\\n")`, lone `=`/`&`/`|` as words, `-` as operator (negatives
unrepresentable — `@timeout` relies on it).

## 4. Parser (line-for-line)

Mirror `parser.nim` including quirks: one-infix-max `parse_arg` (B4:
`[$a+$b+$c]` keeps first pair — **preserve** in interpreter; transpiler
folds left-assoc, deviation #10, zero suite impact); `__expr` vs `cmd`
in `parse_stmt` (rewind on miss via saved position); `typedParam`
define-only (`misplaced type annotation` elsewhere); `: ret` on calls;
missing `)`/type → `line N:` errors. Do not thread file lines into `Arg`
(L6 best-effort; compiled true-lines are deviation #1).

## 5. Ownership design (decide before dispatch — the whole port hinges here)

Odin has no GC by default, no exceptions, no closures. Fix the allocator
story first:

```odin
Value_Kind :: enum { Int, Str, List, Some, None }
Value :: struct {
    kind: Value_Kind,
    i: i64,
    s: string,
    items: [dynamic]^Value, // only for List
    inner: ^Value,          // only for Some
}

Kronyn_Error :: struct { kind: string, line: i32, msg: string }
// display: (line>=0 ? "line X: " : "") + msg
Control :: union { ^Value, Return_Sig, Break_Sig, Tail_Sig, Kronyn_Error }
Return_Sig :: struct { v: ^Value }
Break_Sig  :: struct {}
Tail_Sig   :: struct { args: []^Value }
```

* Recommended: one `arena.Arena` per interpreter run (backed by
  `context.allocator` in `main`), threaded explicitly as
  `eval_allocator: mem.Allocator` — do **not** rely on implicit `context`
  inside deep recursion (push a known allocator at the driver and pass it
  down). Values immutable → aliasing safe. `new(Value)` from the arena;
  strings cloned into the arena only when they outlive their source
  (`set`, job files); otherwise slice the source buffer. Free the whole
  arena on process exit; actor children are separate processes.
* `Env`: struct with `vars: map[string]^Value`,
  `cmds: map[string]Command`, `arities: map[string][2]int`,
  `syscalls` nested maps, `parent, root: ^Env`, `returning/breaking`
  flags, `ret: ^Value`, `tail_fn/tail_arity`. `Command` is a union of
  `Builtin_Proc` (`proc(^Env, []^Value, Allocator) -> Control`) vs
  `User_Proc` struct (`params/ptypes/body/rtype/...`) — Odin procedures
  don't capture, so store the body explicitly like Zig.
* Control flow without exceptions: every `eval_*` returns `Control`.
  Match on it; `Kronyn_Error` is caught by `try`/RTA wrappers only (plus
  `strconv` parse failures mapped to `error/-1`); `Return/Break/Tail`
  propagate through `try/@retry` untouched (tail signals never swallowed —
  `TAILCALL.md` rule 6). `with_frame` = append `(name,line)` on entry,
  `defer pop`, snapshot `last_trace` on first error (mirror `withFrame`,
  `eval.nim:133-141`). Trace cap 20 with middle-cut.
* Allocator-failure policy: allocation failure is fatal — print and
  `os.exit(1)`, never a catchable `Kronyn_Error`.

### Caches / observability

`@(thread_local)` globals for `body_cache/sub_cache: map[string]...`,
`call_stack`, `timeout_stack`, `deprecated_seen`, counters. `eval_sub`:
expression shapes cached, statements not (B3: multi-stmt conditions keep
first only). `eval_body`: `check_timeout()` then cache hit/miss + `eval`.
`-measure` prints `essentials load` + counts. Stdout via one global
`sync.Mutex` (`withLock`); `fmt.println` semantics = Nim `echo`
(normalize newlines in test comparisons).

## 6. Builtins + syscalls (exact table)

Port `builtinAritySpecs (eval.nim:246-260)` + `initKernel (1037-1255)`
byte-for-byte (same checklist as CPP.md §5.5: first-arg-only `writeln`,
sentinel-word `if`, per-iteration `eval_sub/eval_body` loops honoring
`breaking/returning`, `\n`-split `lines/filter/count/first/last`,
`char 0..255`, strict `int`, `"true"/"false"` contains, `map` with `it`
in root-child and `none` short-circuit, shell `exec` with merged stderr +
ignored status + stripped output).

* Case conversion: `core:strings` is byte/ASCII-oriented. Nim's is
  Unicode-aware. Either vendor a fold table or document the ASCII-only
  fork per deviation #5 (the C runtime already takes the fork).
* Syscalls (`1022-1033`): `io.output/outputln/input`, `fs.read/write/append/
  exists/remove/list` (`none` vs `""` policies + sorted names incl. `.`/`..`),
  `proc.exit/proc.args` (empty in workers). Central arity checks; `exec
  "rm -f"` banned. `os2.read` EOF → `io end of input`.

## 7. The seven RTAs (messages must match Nim strings)

* `@retry(n)` anywhere incl. plain statements; swallow `Kronyn_Error` only.
* `@actor` bare define-only → §8.
* `@forkexec` bare define-only, never with `@actor`; full-world snapshot
  (all defines + root vars), new error kind `fork`.
* `@typecheck` bare + `proc(x: int): ret`; `TypeNames =
  [int,string,list,some,none,any]`; define-time failures; entry checks
  pre-retry/pre-spawn (`expects <t> for '<p>', got <g>`), return check
  post-success (`must return <t>, got <g>`); `None` for nil.
* `@tailcallopt` bare define-only; `match_tail_self_call` for
  `return [self …]` / `return [recv].self(…)` (single-stmt sub, no call
  annotations, arity-checked); `trampoline_call` loop clearing vars,
  re-checking contracts per iteration; 100k verified (`30_rta_tailcall`).
* `@deprecated` bare/`("msg")` define-only; warn-once per proc per process
  on stderr (`Kronyn deprecated: <n> (line <l>): <t>`), parent-side only
  for actors.
* `@timeout(ms)` one positive int define-only; cooperative
  `time.now()` + durations (`min(outer, now+ms)`, check in `eval_body`,
  fresh per retry, entry checks pre-arm, inner-`try` livelock documented);
  actor path preemptive (§8); expiry `timeout <owner> timed out after
  <ms>ms`. Ordering: retry-above-actor = fresh worker/attempt; below =
  shared heap; typecheck outermost-in/innermost-out; annotated tail-calls
  go normal path.

## 8. Actors (subprocess + json, share-nothing)

Mirror `spawnActorCall (1344-1390)` + `actorRunLocal/runActorJobFile`:

```odin
Actor_Job :: struct {
    name: string, params: []string, ptypes: []string, body: string,
    rtype: string, args: []Ser_Value, retry_max: int, line: int, tail_opt: bool,
}
```

1. Convert `^Value` ↔ `Ser_Value` (JSON-tagged mirror; commands never
   cross) via `core:encoding/json`.
2. Write `temp/kronyn_actor_<pid>_<seq>.job`, re-exec
   `os2.current_exe() --actor-run <job> <res>` via `os2.process_start`.
3. Child: fresh quiet interpreter, re-register proc **plain**, inner-retry
   loop, write `Actor_Result{ok,val,err}` (+ worker-trace suffix).
4. Parent blocks (`process_wait`); `@timeout` polls then `process_kill()`
   + `process_wait()` — no orphans. Missing result → `timeout` if clock ≥
   budget−50ms else `actor <n>: worker failed (exit N)`; `!ok` →
   `actor <n>: <msg>` + trace.
5. `defer` cleanup of job+res on all paths.
6. Closed world (§7 of CPP.md applies verbatim: builtins+essentials+self
   only, `argv` empty, `proc.exit` = worker failure, `io.input` forbidden,
   stdout inherited).

## 9. CLI + `-compile` (phase 1: emit C, reuse runtime)

* CLI strings match `kronyn.nim` exactly (keep B7 `file for found` typo
  until a usage assertion lands). `essentials_source()`: beside-exe →
  cwd → `#load("essentials.kr", string)` fallback. `argv` → root `argv`
  list. `-measure` prints load + counters; workers quiet.
* Port `codegen.odin` proc-for-proc from `codegen.nim`
  (`Ctx/Define/fresh/emit/c_str/sanitize_c/kind_const`, two-pass
  `collect_define` for forward refs, `gen_expr/gen_stmt/...`). Emit C
  against the **unmodified** `kronyn_rt.h/.c` first — optionally
  `foreign import` it for in-process testing, but the shipped
  `-compile` path still shells to `gcc/clang/cc`. Keep `CodegenVersion =
  4` in the FNV-1a cache key (reimplement the exact `cacheKey` in
  `kronyn.nim:5-14`), `tmp/kronyn_cache/<hex>/bin(.exe)`,
  `cached/compiled <src> -> <out>` messages, `--emit-c` (+ readable indent
  pass), `--no-cache` escape, 30-day prune, `gcc→clang→cc` lookup,
  `"<cc>" -O2 -fwrapv -I"<appdir>" …`, keep-`.c`-on-failure.
* Enforce the v1 subset with identical refusal strings (`evolve`/`map`/
  `@actor`/nested/literal/count-cap 2³¹−1/…) and preserve all 16
  `COMPILE.md` deviations (#1 true lines, #4 refuse multi-stmt conds, #5–7
  ASCII/empty-split/wrap incl. `-fwrapv`, #9 `list` incl. `.`/`..`, #10
  left-assoc chains vs B4, #11 forward refs, #12 deeper C recursion, #14
  ~7-Value catch leak census, #15 literals-only + cycle refusal, #16 shell
  `exec`). Static errors refuse at compile time (`try/@retry` catch
  runtime only).

## 10. Milestones & gates

* M1: values/ops/`set/if/while/loop/iter/break/return`/`try`/builtins
  minus `map`/syscalls/essentials → twins `01–13`, `19`, `02–04`
  string basics, `18` (piped stdin).
* M2: `define proc/fn`, recursion, chains, shadowing, `@typecheck/
  @tailcallopt` → `pass_procs/typecheck/tailcall` + `30_rta_tailcall` 100k.
* M3: `import` (inline/hermetic/cycle-guarded), `try` as `Kronyn_Error` +
  root vars, `@retry/@deprecated/@timeout`, `tests/compile/` 28/28.
* M4: `--emit-c`, `exec`, cache (~57× hits), allocation audit (arena
  high-water mark 0-growth on success-path re-runs; document the per-catch
  bound instead of pools), full sweeps (`tests/*.kr`, `movieSet/`,
  `translation/`, newline-normalized diffs).
* Perf: `39_perf_bench.kr` + `-measure`; keep `PERF.md` reasoning (19×
  per-char floor, 3× composites from call frames) — cite numbers, don't
  chase a VM.

## 11. Pitfalls (from `Negatives/`)

B1 guard (Odin slices panic with `-debug` — keep `-debug` on until M4 so
the guard is tested); B2 refuse (exhaustive `switch` on `Arg` — the
compiler forces the check Nim missed); B3/B4 preserve; B5 trampoline
(Odin stack also overflows on plain recursion — same mitigation, compare
debug vs `-o:speed`); B6 delete `test1.nim`, wire `odin test`;
B7 fix + assertion; B8 `*~ #*# .#*` in `.gitignore`. L1 ceiling accepted;
L3 coarse actors; L5 `try` = `Kronyn_Error` only; L6 lines best-effort;
L9–L11 compiled bounds; R2 Linux pass before POSIX claims; R3 no sandbox
— say so. Odin-specific: never rely on implicit `context` inside the
treewalker (pass the arena explicitly); `defer` inside hot loops is fine
but `map`/`dynamic` reallocation inside `eval` must use the arena, never
`temp_allocator`; `or_return` is for Odin errors only, never for
`Control` propagation.
