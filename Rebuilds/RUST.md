# RUST.md — Rewrite Kronyn in Rust (detailed instructions)

> Goal: a faithful Rust (stable, edition 2021) port of the whole Kronyn
> tree (`src/*.nim`, `src/essentials.kr`, `src/kronyn_rt.*`, CLI,
> `-compile` transpiler, suites). Behavior gates are byte-identical
> stdout/stderr/exit codes vs the Nim binary. Read `SUPER.md`
> (canonical), `COMPILE.md` (transpiler contract + 16 deviations),
> `Discipline/*.md`, `PERF.md`, `Negatives/` (B1–B8/L1–L11/R1–R5) first.
> Do not invent a VM. The treewalker stays the execution engine.
> The borrow checker is the main adversary — design `Env`/`Value`
> ownership up front (§5) before porting dispatch.

## 0. Source inventory (read in this order)

| File | Lines | What to extract |
|---|---|---|
| `src/token.nim` (31) | token kinds | `tkWord tkString tkSub tkBlock tkDollar tkAt tkDot tkLParen tkRParen tkComma tkColon tkNewline tkPlus tkMinus tkStar tkSlash tkEqEq tkBangEq tkLt tkGt tkLtEq tkGtEq tkAnd tkOr tkBang tkDotDot tkEof` + per-token `line` |
| `src/lexer.nim` (147) | char scanner | `peek` (guarded) vs `advance` (**unguarded — B1**), `lexString` escapes (`\n \t \" \\`), `lexNested` depth counting, `lexWord` stop-set, `.` vs `..`, `#` comments |
| `src/ast.nim` (60) | AST | `Arg = word\|string\|sub\|block\|var\|chain\|infix\|typedParam`, `ChainCall{name,args,retType,line}`, `Stmt{cmd,args,annotations,line}` |
| `src/parser.nim` (225) | recursive descent | `parseChainArgs`, single-infix `parseArg`, `parsePrimary` (`!`, `name(...)` + `.m()` chains, `: ret`), `parseTypedParam`, `parseStmt` (`@ann` + `__expr` vs `cmd` forms), `parse` loop |
| `src/eval.nim` (1390) | runtime | everything in §4–§8 below |
| `src/kronyn.nim` (166) | CLI | `--actor-run`, `-compile` (FNV-1a cache + cc), `[-measure] file [args]` |
| `src/codegen.nim` (1214, `CodegenVersion=4`) | transpiler | AST→C emitter, refusals, ownership discipline |
| `src/kronyn_rt.h/.c` | C runtime | refcounted `KRN_Value`, envs, builtins, `setjmp` handlers — **reuse as-is in phase 1** (§9) |
| `src/essentials.kr` (55) | stdlib | 10 `@typecheck`ed intents, load order beside-binary → cwd → embedded (`include_str!` fallback) |

Gates: `tests/*.kr` numbered `01–39` basic→advanced — `01–19` core,
`21–27/29/31` (actors), `28` (contracts), `30` (100k tailcall),
`32/33/34` (stdlib/syscall/error contracts), `35/36/37`
(deprecated/timeout/forkexec), `38` showcase, `39` bench,
`tests/compile/` (28 via `run.nim`),
`movieSet/` (12 actor scenes), `translation/` (13 twins + rej/runfail).

## 1. Target layout (cargo, minimal deps)

```toml
# Cargo.toml — keep deps to: serde{derive}, serde_json
[package] name="kronyn" edition="2021"
[dependencies] serde={version="1",features=["derive"]} serde_json="1"
# wait-timeout or polling loop for actor timeouts (or std-only polling)
```

```
src/
  main.rs      # CLI driver (kronyn.nim port)
  token.rs     # TokenKind, Token
  lexer.rs     # Lexer struct
  ast.rs       # Arg, ChainCall, Stmt, Program
  parser.rs    # Parser struct
  value.rs     # Value, KronynError, Control
  env.rs       # Env, registries
  eval.rs      # dispatch, builtins, syscalls, RTAs, actor transport
  codegen.rs   # transpiler (codegen.nim port)
  essentials.kr
  kronyn_rt.h / kronyn_rt.c (copied verbatim, phase 1)
```

Binary must sit beside `essentials.kr` + `kronyn_rt.c` at runtime.
`cargo build` (debug) is the `nim c` equivalent; `cargo build --release`
is the release counterpart for limiter comparisons (B5).

## 2. Semantics bible (must-match)

* **Values:** `int(i64)`, `string(String)` (bytes), `list(Vec<ValueRef>)`,
  `some(ValueRef)`, `none`. `word_to_value`: strict all-digits
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
* **`set`:** evaluate `args[1]` only; target must be `word` — **refuse**
  otherwise (fix B2; Nim derefs the variant → `FieldDefect`). Message:
  `set target must be a name` (match `codegen.nim:610`).
* **`evolve/import/try`:** `evolve` = `eval_sub` in current scope;
  `import` = read + `eval`, missing → `io import: file not found: <p>`;
  `try {b}` → `some/none` + root `err/errkind/errline/errtrace`.

## 3. Lexer (fix B1)

Direct port with one fix: Nim `advance (lexer.nim:15-16)` indexes
`src[pos]` unchecked — unterminated `"` / trailing `\` / `writeln ["[" ..
["x" .. "]"]]` panics with `IndexDefect` in Rust terms (index OOB).
Use `str.as_bytes()` + checked indexing (`get(pos)`) and return a clean
`KronynError` instead. Then implement the documented direction
(string-aware `lex_nested` + bounds guards) with the B1 repro as
regression. Preserve: escapes, stop-set, `.`/`..`, `#` comments,
`tkNewline("\\\\n")`, lone `=`/`&`/`|` as words, `-` as operator (negatives
unrepresentable — `@timeout` relies on it).

## 4. Parser (line-for-line)

Mirror `parser.nim` including quirks: one-infix-max `parse_arg` (B4:
`[$a+$b+$c]` keeps first pair — **preserve** in interpreter; transpiler
folds left-assoc, deviation #10, zero suite impact); `__expr` vs `cmd`
in `parse_stmt` (rewind on miss); `typedParam` define-only
(`misplaced type annotation` elsewhere); `: ret` on calls; missing
`)`/type → `line N:` errors. Do not thread file lines into `Arg`
(L6 best-effort; compiled true-lines are deviation #1).

## 5. Ownership design (decide before dispatch — the whole port hinges here)

Recommended (simplest that passes the suites):

```rust
pub type ValueRef = std::rc::Rc<Value>;
#[derive(Debug, Clone)]
pub enum Value { Int(i64), Str(String), List(Vec<ValueRef>), Some(ValueRef), None }

pub struct KronynError { pub kind: String, pub line: i32, pub msg: String }
// display: (line>=0 ? format!("line {}: ", line) : "") + msg
pub enum Control { Return(ValueRef), Break, Tail(Vec<ValueRef>), Err(KronynError) }
pub type KResult = Result<ValueRef, Control>;
```

* Values immutable → `Rc` aliasing safe (mirrors `krn_retain` aliasing).
  `None` needs no immortality under `Rc`.
* `Env` needs shared mutability + parent chain + closures capturing
  define-time `params/body`:

```rust
pub type EnvRef = std::rc::Rc<std::cell::RefCell<Env>>;
pub type Command = std::rc::dyn Fn(EnvRef, Vec<ValueRef>) -> KResult;
pub struct Env {
  pub vars: HashMap<String, ValueRef>,
  pub cmds: HashMap<String, Command>,
  pub arities: HashMap<String, (i32,i32)>,
  pub syscalls: HashMap<String, HashMap<String, SyscallDef>>,
  pub parent: Option<EnvRef>, pub root: EnvRef, // set at construction
  pub returning: bool, pub ret: ValueRef, pub breaking: bool,
  pub tail_fn: String, pub tail_arity: usize,
}
```

  `root` self-reference needs `Rc::new_cyclic` or two-step init
  (`new_env(None)` then `root = self`). `call_fn`: fresh child of `root`,
  bind positionally, `eval_body`, honor `root.borrow().returning`.
  Borrow discipline: never hold `borrow_mut()` across `eval_*` recursion
  (clone `Command`/`ValueRef`s out first) or you will panic on
  re-entrant borrows — the most common Rust-port failure.
* Alternative for `Send`: actors are processes, interpreter is
  single-threaded — `Rc<RefCell>` is sufficient. Only stdout/deprecated
  state needs `static Mutex` + `thread_local!` caches (below). Do not
  reach for `Arc<Mutex>` per value/env unless you plan a threaded actor
  fast path (out of scope; keep `thread_local!` shape so it stays possible,
  mirroring Nim's rationale in `ACTORS.md`).
* Control flow without exceptions: every `eval_*` returns `KResult`.
  `?` propagates; `try` matches `Err(Control::Err(e))` only (plus string-
  parse failures mapped to `error/-1`); `Tail/Break/Return` propagate
  through `try/@retry` untouched (tail signals never swallowed —
  `TAILCALL.md` rule 6). `with_frame` = push `(name,line)` on entry,
  `Drop` guard pops + snapshots `last_trace` on first `Err` (mirror
  `withFrame`, `eval.nim:133-141`). Trace cap 20 with middle-cut.

### Caches / observability

`thread_local! { BODY_CACHE: RefCell<HashMap<String,Program>>,
SUB_CACHE: RefCell<HashMap<String,Arg>>, CALL_STACK, TIMEOUT_STACK,
DEPRECATED_SEEN, counters… }`. `eval_sub`: expression shapes cached,
statements not (B3: multi-stmt conditions keep first only). `eval_body`:
`check_timeout()` then cache hit/miss + `eval`. `-measure` prints
`essentials load` + `body cache hits/miss` + `evalStmt/Arg/Sub` counts.
Stdout via one `static Mutex<()>` (`withLock`); `println!` semantics =
Nim `echo` (platform newlines — normalize to `\n` in test comparisons).

## 6. Builtins + syscalls (exact table)

Port `builtinAritySpecs (eval.nim:246-260)` + `initKernel (1037-1255)`
byte-for-byte (see CPP.md §5.5 for the semantic checklist — same list
applies: first-arg-only `writeln`, sentinel-word `if`, per-iteration
`eval_sub/eval_body` loops honoring `breaking/returning`, Unicode-aware
case (use `char::to_uppercase`, not byte `to_ascii_uppercase`, or document
the ASCII fork per deviation #5), `\n`-split `lines/filter/count/first/
last`, `char 0..255`, strict `int`, `"true"/"false"` contains, shell
`exec` with merged stderr + ignored status + stripped output, `map` with
`it` in root-child, `none` short-circuit).
Syscalls (`1022-1033`): `io.output/outputln/input`, `fs.read/write/append/
exists/remove/list` (`none` vs `""` policies + sorted names incl. `.`/`..`),
`proc.exit/proc.args` (empty in workers). Central arity checks; `exec
"rm -f"` banned. `read_line` EOF → `io end of input`.

## 7. The seven RTAs (messages must match Nim strings)

* `@retry(n)` anywhere incl. plain statements; swallow `Err` only.
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
  `Instant+Duration` (`min(outer, now+ms)`, check in `eval_body`, fresh per
  retry, entry checks pre-arm, inner-`try` livelock documented); actor path
  preemptive (§8); expiry `timeout <owner> timed out after <ms>ms`.
  Ordering: retry-above-actor = fresh worker/attempt; below = shared heap;
  typecheck outermost-in/innermost-out; annotated tail-calls go normal path.

## 8. Actors (subprocess + serde, share-nothing)

Mirror `spawnActorCall (1344-1390)` + `actorRunLocal/runActorJobFile`:

```rust
#[derive(Serialize, Deserialize)] struct ActorJob {
  name: String, params: Vec<String>, ptypes: Vec<String>, body: String,
  rtype: String, args: Vec<SerValue>, retry_max: usize, line: i32, tail_opt: bool }
```

1. Convert `ValueRef` ↔ `SerValue` (untagged enum mirroring `Value`;
   commands never cross).
2. Write `temp/kronyn_actor_<pid>_<seq>.job` (serde_json), re-exec
   `std::env::current_exe() --actor-run <job> <res>`.
3. Child: fresh quiet interpreter, re-register proc **plain**, inner-retry
   loop, write `ActorResult{ok,val,err}` (+ worker-trace suffix).
4. Parent blocks; `@timeout` polls (`try_wait` + sleep) then `kill()` +
   `wait()` — no orphans. Missing result → `timeout` if clock ≥
   budget−50ms else `actor <n>: worker failed (exit N)`; `!ok` →
   `actor <n>: <msg>` + trace.
5. RAII cleanup of job+res on all paths (scope guard / `Drop`).
6. Closed world (§7 of CPP.md applies verbatim: builtins+essentials+self
   only, `argv` empty, `proc.exit` = worker failure, `io.input` forbidden,
   stdout inherited).

## 9. CLI + `-compile` (phase 1: emit C, reuse runtime)

* CLI strings match `kronyn.nim` exactly (keep B7 `file for found` typo
  until a usage assertion lands). `essentialsSource()`: beside-exe →
  cwd → `include_str!("essentials.kr")`. `argv` → root `argv` list.
  `-measure` prints load + counters; workers quiet.
* Port `codegen.rs` fn-for-fn from `codegen.nim` (`Ctx/Define/fresh/emit/
  c_str/sanitize_c/kind_const`, two-pass `collect_define` for forward
  refs, `gen_expr/gen_stmt/...`). Emit C against the **unmodified**
  `kronyn_rt.h/.c` first (fastest path to 27/27); retarget to Rust-emitted
  Rust only if re-proposed. Keep `CodegenVersion = 4` in the FNV-1a cache
  key (`version + ccode + rtSrc`), `tmp/kronyn_cache/<hex>/bin(.exe)`,
  `cached/compiled <src> -> <out>` messages, `--emit-c` (+ readable indent
  pass), `--no-cache` escape, 30-day prune, `gcc→clang→cc` lookup,
  `"<cc>" -O2 -fwrapv -I"<appdir>" …` invocation, keep-`.c`-on-failure.
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
* M3: `import` (inline/hermetic/cycle-guarded), `try` as `Control::Err`
  + root vars, `@retry/@deprecated/@timeout`, `tests/compile/` 28/28.
* M4: `--emit-c`, `exec`, cache (~57× hits), `KRN_LEAK_CHECK`-equivalent
  audit (Rust: `cargo test` + drop-count assertion on success paths;
  document the per-catch bound instead of pools), full sweeps
  (`tests/*.kr`, `movieSet/`, `translation/`, newline-normalized diffs).
* Perf: `39_perf_bench.kr` + `-measure`; keep `PERF.md` reasoning (19× per-char
  floor, 3× composites from call frames) — cite numbers, don't chase a VM.

## 11. Pitfalls (from `Negatives/`)

B1 guard / B2 refuse (use exhaustive `match` on `Arg` — the compiler
forces the check Nim missed); B3/B4 preserve; B5 trampoline (Rust stack
also overflows on plain recursion — same mitigation, compare debug vs
release); B6 delete `test1.nim`, wire `cargo test`; B7 fix + assertion;
B8 `*~ #*# .#*` in `.gitignore`. L1 ceiling accepted; L3 coarse actors;
L5 `try` = `Control::Err` only; L6 lines best-effort; L9–L11 compiled
bounds; R2 Linux pass before POSIX claims; R3 no sandbox — say so.
