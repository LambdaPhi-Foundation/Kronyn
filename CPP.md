# CPP.md — Rewrite Kronyn in C++ (detailed instructions)

> Goal: a faithful C++17 (or C++20) port of the whole Kronyn tree
> (`src/*.nim`, `src/essentials.kr`, `src/kronyn_rt.*`, CLI, `-compile`
> transpiler, suites). Behavior gates are byte-identical stdout/stderr/exit
> codes vs the Nim binary. Read `SUPER.md` (canonical), `COMPILE.md`
> (transpiler contract + 16 deviations), `Discipline/*.md` (6 RTAs +
> errors/syscalls), `PERF.md`, `Negatives/` (B1–B8/L1–L11/R1–R5) first.
> Do not invent a VM. The treewalker stays the execution engine.

## 0. Source inventory (read in this order)

| File | Lines | What to extract |
|---|---|---|
| `src/token.nim` (31) | token kinds | `tkWord tkString tkSub tkBlock tkDollar tkAt tkDot tkLParen tkRParen tkComma tkColon tkNewline tkPlus tkMinus tkStar tkSlash tkEqEq tkBangEq tkLt tkGt tkLtEq tkGtEq tkAnd tkOr tkBang tkDotDot tkEof` + `line` per token |
| `src/lexer.nim` (147) | char scanner | `peek` (guarded) vs `advance` (**unguarded — B1**), `lexString` escapes (`\n \t \" \\`, else keep `\`), `lexNested` depth counting, `lexWord` stop-set, `.` vs `..`, `#` comments, `\n` tokens |
| `src/ast.nim` (60) | AST | `Arg = word\|string\|sub\|block\|var\|chain\|infix\|typedParam`, `ChainCall{name,args,retType,line}`, `Stmt{cmd,args,annotations,line}` |
| `src/parser.nim` (225) | recursive descent | `parseChainArgs`, `parseArg` (one infix max), `parsePrimary` (`!` prefix, `name(...)` + trailing `.m()` chain, `: ret` on calls), `parseTypedParam`, `parseStmt` (`@ann` prefix, `__expr` form when single chain/infix + newline/EOF, else `cmd(args...)` with optional `(...)` head), `parse` loop over newlines |
| `src/eval.nim` (1390) | runtime | everything in §4–§8 below |
| `src/kronyn.nim` (166) | CLI | `--actor-run`, `-compile` (cache + cc), `[-measure] file [args]` |
| `src/codegen.nim` (1214, `CodegenVersion=4`) | transpiler | AST→C emitter, subset refusals, ownership discipline |
| `src/kronyn_rt.h/.c` | C runtime | `KRN_Value` refcounted, `KRN_Env`, builtins, syscalls, `setjmp` handlers, timeouts — **reuse as-is in phase 1** |
| `src/essentials.kr` (55) | stdlib | 10 `@typecheck`ed intents, load order beside-binary → cwd → embedded |

Tests that gate you: `tests/*.kr` numbered `01–39` basic→advanced —
`01–19` core (basics, control, procs, evolve, errors, I/O, shell),
`21–27/29/31` (actors), `28` (contracts), `30` (tailcall),
`32/33/34` (stdlib/syscall/error contracts), `35/36/37`
(deprecated/timeout/forkexec), `38` showcase, `39` bench,
`tests/compile/` (28 cases via `run.nim`), `movieSet/` (12 actor scenes),
`translation/` (13 transpile twins + rej/runfail).

## 1. Target layout (CMake, no external deps)

```
kronyn-cpp/
  CMakeLists.txt (C++17, -Wall -Wextra; MSVC /W4)
  src/
    token.h      # TokenKind enum, Token{kind,lexeme,line}
    lexer.h/.cpp # Lexer class
    ast.h        # Arg variant, ChainCall, Stmt, Program=vector<Stmt>
    parser.h/.cpp
    value.h/.cpp # Value, KronynError, signals
    env.h/.cpp   # Env, registries
    eval.h/.cpp  # dispatch, builtins, syscalls, RTAs, actor transport
    codegen.h/.cpp
    main.cpp     # CLI driver
    essentials.kr
    kronyn_rt.h/.c (copied verbatim, phase 1)
  tests/ (symlink or copy of ../tests, movieSet, translation)
```

Single `kronyn` binary must sit beside `essentials.kr` and `kronyn_rt.c`
at runtime (same deploy rule as Nim). No Boost/Abseil/nlohmann in phase 1 —
hand-roll FNV-1a + minimal JSON for actor jobs (or vendor single-header
`nlohmann/json.hpp` only for actor transport if you justify it).

## 2. Semantics bible (must-match, test-gated)

* **Values:** `int64`, `string` (bytes), `list<vector<ValuePtr>>`,
  `some(ValuePtr)`, `none`. `wordToValue`: all-digits (`^[+-]?[0-9]+`,
  no whitespace, `tryWordInt` semantics) → `int` else `string`.
  `007` quoted stays `string`; bare `007` → `int 7`.
* **Coercion (`$`):** int canonical, list join with single spaces
  (recursive `$`), `some(x)` → `$x`, `none`/nil → `""`.
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
  entry (`builtinArities.del(name)`) — yours rules.
* **`set`:** `set name value…` — value is `evalArg(args[1])` (only one;
  extra args are evaluated? No — Nim evaluates `args[1]` only; mirror it).
  Must **refuse** non-name targets (fix B2): if `args[0].kind != word`
  raise `arity/type` `set target must be a name` like `codegen.nim:610`
  instead of dereferencing the variant (which in Nim throws `FieldDefect`).
* **`evolve/import`:** `evolve` = `evalSub($arg)` in current scope;
  `import` = read file + `eval` in current scope, missing → `io`
  `import: file not found: <path>`.
* **`try`:** `try {body}` → `some(result)` or `none()`, sets root vars
  `err/errkind/errline/errtrace`. Catches `KronynError` + plain
  conversion failures (mapped to `kind=error line=-1`); never catches
  control signals or native bugs.

## 3. Lexer (fix B1, keep everything else)

Port `lexer.nim` 1:1 with one fix:

* `advance()` **must bounds-check**. Nim's `l.src[l.pos]` throws
  `IndexDefect` on unterminated `"…"` / trailing `\` (`lexString:38,45`).
  Repro `writeln ["[" .. ["x" .. "]"]]` must become a clean `KronynError`,
  not a crash. Add `if (pos >= src.size())` guards returning `\0`/raising
  `kerr("io",line,"unterminated string")` — but gate it behind a flag so
  the current crash repro becomes a passing test you add.
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
  bare calls. Missing `)` / missing type name → `ValueError`-class errors
  with `line N:` prefix (these become `KronynError kind=error` via the
  generic `ValueError` catch in `try`/driver).
* `Arg` nodes carry `line` only for infix roots/chains; sub-sources re-lex
  from line 1 (L6 best-effort lines — do not "fix" by threading lines;
  compiled backend does true lines, deviation #1).

## 5. Runtime core

### 5.1 `Value`

```cpp
enum class Kind { Int, String, List, Some, None };
struct Value {
  Kind kind;
  long long i = 0;
  std::string s;
  std::vector<std::shared_ptr<Value>> items;
  std::shared_ptr<Value> inner;
};
using ValuePtr = std::shared_ptr<Value>;
```

Helpers: `toString(v)` (`$`), `truthy(v)`, `isInt(v)` (kind==Int OR
all-digits string), `asInt(v)` (`stoll`, throw on garbage),
`kindName(v)`, `emptyVal()` (shared `""` instance).
Values immutable after construction (aliasing safe, e.g. `str()` on a
string may return the same pointer). `NONE` singleton immortal if you
later refcount the C runtime — in C++ `shared_ptr` is fine.

### 5.2 `Env`

```cpp
using CommandFn = std::function<ValuePtr(std::shared_ptr<Env>, std::vector<ValuePtr>)>;
struct SyscallDef { SyscallFn fn; int minArgs, maxArgs; };
struct Env : std::enable_shared_from_this<Env> {
  std::unordered_map<std::string, ValuePtr> vars;
  std::unordered_map<std::string, CommandFn> cmds;
  std::unordered_map<std::string, std::pair<int,int>> builtinArities;
  std::unordered_map<std::string, std::unordered_map<std::string,SyscallDef>> syscalls;
  std::shared_ptr<Env> parent, rootCache;
  bool returning=false, breaking=false;
  ValuePtr retVal;
  std::string tailFn; int tailArity=0;
};
```

`newEnv(parent)`: `rootCache = parent ? parent->rootCache : self`.
`getVar` walks parents, missing → `emptyVal()`. `callFn`: fresh child of
`rootCache`, bind params positionally (extras ignored), `evalBody(body)`,
if `root->returning` return `child->retVal`. `getCmd` walks parents.

### 5.3 Errors

```cpp
struct KronynError : std::runtime_error {
  std::string kind; int line;
  KronynError(std::string k,int l,std::string m);
};
// message format: (line>=0 ? "line "+to_string(line)+": " : "") + msg
struct ReturnSignal : std::exception { ValuePtr v; };
struct BreakSignal : std::exception {};
struct TailCallSignal : std::exception { std::vector<ValuePtr> args; };
```

Kinds: `arity type unknown-command annotation division bounds option io
actor timeout error`. Uncaught driver output: `Kronyn error: <msg>` +
`kronynTrace()` (`Traceback (kronyn, innermost last):` + `  at <name>
(line <n>)`, cap 20 with `... (N frames omitted)` middle-cut, tail loops
show as one frame). `try` catches `KronynError` (+ `std::invalid_argument`
from conversions mapped to `error/-1`) and snapshots `err/errkind/errline/
errtrace` on **root**, then clears trace. Retry loops clear per swallowed
attempt. Anything else (including `TailCallSignal`) propagates.

Convert at source (ERRORS.md rule 3): missing-arg indexing, `/0`/`mod 0`,
`char` outside 0..255, zero-arg `import`/`syscall`, `fs.write/append` IO,
stdin EOF (`end of input`) — all become `KronynError`, never native
crashes. `slice` OOB raises like `index` (not `""`).

### 5.4 Dispatch + caches + observability

* `eval(program)`: for each `Stmt`, `define`/unannotated → `evalStmt`
  directly; annotated → `validateStmtAnnotations` + `@retry` loop
  (`retryAttempts`), catch `KronynError`, `clearTrace()` per swallow.
  Break on `returning`/`breaking`.
* `evalSub(src)`: `subCache` hit → `evalArg(cached)`. Else tokenize; if
  second token is operator → `parseArg`, cache as expression; elif `.` →
  `parseArg`, cache; else `parseStmt` + `evalStmt` (**not cached**).
  Multi-statement conditions therefore evaluate only the first (B3 — keep;
  compiler refuses them).
* `evalBody(src)`: `checkTimeout()` first, then `bodyCache` hit/miss +
  `eval(cached)`.
* `evalArgChain`: empty-receiver + first call = bare `name(...)` command;
  else receiver then chain left→right via `evalChainCall` (arity-checked,
  receiver counted).
* Counters: `thread_local long bodyCacheHits/Miss, callsEvalStmt/Arg/Sub`;
  `-measure` prints `essentials load` timing + counters; optional
  `KRONYN_PROFILE` macro adds per-proc timings. `thread_local` caches +
  `std::mutex` around stdout (`withLock`).

### 5.5 Builtins (exact arities in `builtinAritySpecs`, `eval.nim:246-260`)

`writeln/write/input/readln/if/iter/toUpper/toLower/len/trim/ascii/char/
int/str/typeof/isInt/isString/isList/slice/index/contains/replace/split/
concat/loop/while/mod/exec/lines/filter/count/first/last/some/none/some?/
none?/unwrap/unwrapOr/map/try`. Port semantics from `initKernel`
(`eval.nim:1037-1255`) byte-for-byte:

* `writeln` echoes first arg only (`echo $args[0]`); `if` takes
  `cond then (elif cond then)* (else then)?` with `"elif"/"else"` sentinel
  words; `while/iter/loop` re-enter `evalSub/evalBody` per iteration and
  honor `breaking/returning`; `toUpper/toLower` Unicode-aware (C++:
  `std::toupper` per byte is **wrong** — use ICU or document ASCII-only
  fork like the C runtime deviation #5); `split(delim)` on strings,
  `lines/filter/count/first/last` split on `\n` (`filter` substring match,
  `count/first/last` skip empties); `char` bounds `0..255`; `int` uses
  strict `stoll` (garbage → `error`); `contains` → `"true"/"false"`;
  `exec` = `cmd /c` (Windows) / `/bin/sh -c` (POSIX), merged stderr,
  status ignored, output stripped; `map` runs body in child of root with
  `it` bound, `none` short-circuits.

### 5.6 Syscalls (`registerSyscalls`, `eval.nim:1022-1033`)

`io.output/outputln/input`, `fs.read` (`some`, missing/unreadable→`none`),
`write/append` (`""`, failures→`io`), `exists` (`1/0`), `remove`
(`""`, missing→`none`), `list` (sorted names only, missing→`none`,
includes `.`/`..` via `walkDir` semantics — preserve), `proc.exit [code]`,
`proc.args` (root `argv` list, empty in workers). Central arity table;
unknown ns/method → `unknown-command`. `exec "rm -f"` banned in-tree.

## 6. The seven RTAs (order-sensitive, typo-strict)

Unknown `@anything` always hard-errors. Validation messages must match
Nim strings (suite greps them):

* `@retry(n)` — any position, statements + defines. Re-runs on
  `KronynError` up to `n`. `n<1` → 1.
* `@actor` — bare, `define`-only. §7.
* `@forkexec` — bare, `define`-only, never with `@actor`. Same transport
  shape as `@actor`, but the child inherits the full world (all defines
  in registration order + root globals snapshot); new error kind `fork`.
* `@typecheck` — bare + inline `proc(x: int): ret`. `TypeNames =
  {int,string,list,some,none,any}`. Missing/unknown types fail at
  **define time**. Entry checks pre-retry/pre-spawn (zero workers on
  violation: `expects <t> for '<p>', got <g>`); return checked once
  post-success (`must return <t>, got <g>`). `nil` counts as `none`.
* `@tailcallopt` — bare, `define`-only. `matchTailSelfCall`: `return
  [self …]` (sub holding single `self`-headed stmt, no annotations) or
  `return [recv].self(…)` (chain ending in `self`). Arity enforced with
  usual message. `trampolineCall`: clear-vars loop, re-check contracts per
  iteration, `TailCallSignal` caught only by trampoline (never by
  `try/@retry`). Depth 100k verified (`tests/30_rta_tailcall`).
* `@deprecated` — bare or `("msg")`, `define`-only. First call per proc
  per process → `stderr: Kronyn deprecated: <name> (line <l>): <text>`,
  call still runs; parent-side only for actors.
* `@timeout(ms)` — one positive int, `define`-only. Cooperative wall-clock
  (`steady_clock`, `epochTime` semantics incl. IO waits): push
  `min(outer, now+ms)` on entry, `checkTimeout()` in `evalBody`, pop on
  exit; fresh window per `@retry` attempt; entry checks run before arming;
  `try` *inside* the body livelocks (documented, same as Python).
  Actor path preemptive (§7). Expiry = catchable `timeout`
  `<owner> timed out after <ms>ms`.

Compositions: `@retry` above `@actor` = fresh worker per attempt (outer);
below = retries inside one worker (inner). `@typecheck` outermost on
entry, innermost on exit. `return [self …]` with call annotations takes
the normal (non-tail) path.

## 7. Actors (subprocess, share-nothing)

Every `@actor` call = one OS process (own heap/GC — in C++: own address
space by construction). Steps mirroring `spawnActorCall`
(`eval.nim:1344-1390`):

1. `ActorJob{name,params,ptypes,body,rtype,args,retryMax,line,tailOpt}`
   (+ `timeoutMs` out-of-band) → serialize to
   `temp/kronyn_actor_<pid>_<seq>.job` (JSON; `Value` trees only — commands
   never cross).
2. Re-exec `current_executable --actor-run <job> <res>`.
3. Child: fresh interpreter (quiet), re-register proc **plain** (recursion
   stays in-process), run with inner-retry loop, write
   `ActorResult{ok,val,err}` (+ worker trace suffix on failure).
4. Parent blocks (`WaitForSingleObject` / `waitpid`); `@timeout` uses timed
   wait then `TerminateProcess`/`kill` + reap (no orphans on any path).
   Missing result file → `timeout` (if clock ≥ budget−50ms) else
   `actor <name>: worker failed (exit N)`. `ok==false` →
   `actor <name>: <msg>\n<worker trace>`.
5. Delete job+res files in RAII `finally` (success and failure).
6. Closed world: child sees builtins + essentials + itself only; parent
   vars invisible (read as `""`); worker `set` never leaks; `proc.args`
   empty; `proc.exit` kills worker (reported as failure); `io.input`
   races — forbid; stdout inherited (interleaving allowed).

Why not threads: Nim's `spawn` needs `gcsafe` over the mutually recursive
treewalker — same argument in C++ is Data-race freedom: the treewalker
mutates shared caches/scopes; a process boundary is stronger and simpler.
Keep caches `thread_local` + stdout `mutex` so a future thread pool stays
possible.

## 8. CLI driver (`main.cpp`, mirror `kronyn.nim`)

```
kronyn [-measure] <file.kr> [args...]
kronyn -compile <file.kr> [-o out] [--emit-c] [--no-cache]
kronyn --actor-run <job> <res>
```

* Missing file: preserve exact wording incl. B7 typo `error: file for
  found: <path>` until you add a usage-text assertion and fix it.
* `argv` → root `argv` list. Boot: `newInterpreter(argv, quiet=!measure)`
  → `initKernel` → `eval(parse(tokenize(essentialsSource())))` where
  `essentialsSource()` = beside-binary → cwd → embedded
  (`#include "essentials.inc"` generated via `xxd -i`, same as
  `staticRead`). `quiet` suppresses the `essentials load: …s` line;
  `-measure` prints it + cache/counter lines at end. Workers stay quiet.
* `-compile`: `compileProgram(readFile(src))` → `ccode`; `rtSrc =
  readFile(appdir/kronyn_rt.c)`; `key = FNV1a(CodegenVersion + ccode +
  rtSrc)` (exact `cacheKey` in `kronyn.nim:5-14`); `tmp/kronyn_cache/<key>/
  bin(.exe)` hit → copy to `-o` (+ `<out>.c` under `--emit-c`), print
  `cached <src> -> <out>`; else write temp `.c`, `findExe(gcc/clang/cc)`,
  invoke `"<cc>" -O2 -fwrapv -I"<appdir>" "<cfile>" "<appdir>/kronyn_rt.c"
  -o "<out>"`, on failure keep `.c` + print compiler output, exit 1;
  on success copy to cache + prune entries older than 30 days. Default
  `-o`: change ext to `.exe` (Windows) / strip (POSIX). No metrics chart
  from compiled binaries; trailing CLI args become `proc.args`.

## 9. Transpiler (phase 1: reuse C runtime; phase 2: optional C++ retarget)

Port `codegen.nim` procedure-for-procedure (`Ctx`, `Define`, `fresh`,
`emit`, `cStr`, `sanitizeC` (`?→_q`, `!→_b`, else `_xHH`), `kindConst`,
`collectDefine` two-pass for forward refs, `genExpr/genStmt/gen*`).
Enforce the v1 subset with identical messages (`COMPILE.md` + refusal
suite): `evolve`/`map`/`@actor`/other `@`/nested define+import/non-block
bodies/multi-statement conditions/dynamic paths/counts/non-literal `set`
targets/counts > 2³¹−1. Static mistakes (unknown commands, arities) are
**compile errors**, so `try/@retry` catch runtime failures only.
Preserve all 16 deviations (#1 true lines, #4 refuse multi-stmt conds,
#5 ASCII case/trim fork if you skip ICU, #7 `LLONG_MIN/-1` + `-fwrapv`
wrap, #9 `fs.list` incl. `.`/`..`, #10 left-assoc chains, #11 forward
refs resolve, #12 deeper plain recursion in C, #14 ~7-Value catch leak
with `KRN_LEAK_CHECK` census 0/0 on success, #15 literals-only
RTA/imports + cycle refusal, #16 platform-shell `exec`). Keep
`--emit-c` readable via the string-aware indent pass. Bump
`CodegenVersion` on any emitter change.

## 10. Milestones & gates (do not skip)

* M1: values, operators, `set/if/while/loop/iter/break/return`, `try`,
  builtins minus `map`, syscalls, `essentials` wholesale → twin
  `01–13`, `19`, `02–04` string basics, `18` (piped stdin).
* M2: `define proc/fn`, recursion + mutual, dot chains, shadowing,
  last-value returns, `@typecheck/@tailcallopt`, essentials deleted
  special-cases → twin `pass_procs/typecheck/tailcall` + `30_rta_tailcall` 100k.
* M3: `import` (inline, hermetic, cycle-guarded), `try` (C++ exceptions
  or `setjmp` in emitted C — keep runtime's), `@retry/@deprecated/
  @timeout`, `tests/compile/` 28/28.
* M4: `--emit-c`, `exec` via `popen`, content cache (~57× hits),
  leak audit, full sweeps (`tests/*.kr`, `movieSet/`, `translation/`
  twin runs with `fc`/diff, newline-normalized).
* Perf: `39_perf_bench.kr` (fib+loop+string) with `-measure`; twin `toUpper`
  must stay ~19× reasoning (Nim-number ported: per-char treewalk can
  never approach one native call — document, don't chase).

## 11. Porting pitfalls (from `Negatives/`)

B1 guard fix; B2 refuse (never deref variant blindly — use
`std::get_if`/`holds_alternative`); B3/B4 preserve; B5 trampoline (plain
recursion will still blow C++ stack — same mitigation); B6 delete
`test1.nim`/wire `ctest`; B7 one-word fix + assertion; B8 extend
`.gitignore` (`*~ #*# .#*`). L1 accepted ceiling; L3 coarse actors only;
L5 `try` catches value-errors only; L6 lines best-effort; L9–L11 compiled
boundaries; R2 run `tests/compile` on Linux before claiming POSIX; R3 no
sandbox — state it to users.
