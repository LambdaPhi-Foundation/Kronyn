# [*] Kronyn

**Kronyn** is an extensible, interpreted programming language that blends the command philosophy of [Tcl](https://www.tcl.tk/) — uniform `command arg…` syntax, everything invokable, code as data — with the structured "Intent" patterns of the [MORRIS standards](https://github.com/Stanislaw3737/MORRIS-shell).

Written in **Nim** (≥ 2.2.8, no dependencies beyond the toolchain), Kronyn is designed for flexibility and extensibility, providing a bridge between a loose scripting environment and a rigid functional structure.

> The interpreter is a **treewalker, and stays one**. There is no bytecode VM plan: measured profiles show dispatch — not parsing — dominates, and tree-walking keeps `evolve`/`import`/REPL fully general. Performance comes from parse caching, opt-in contracts, RTAs, and the ahead-of-time `-compile` transpiler — never from a new backend.

---

## 🏛 The Vision: A Language-Based OS
The ultimate goal of Kronyn is to transcend being a mere interpreter and instead serve as the core of a **Language-Based Operating System**.

Inspired by the architectural purity of **Lisp Machines** and the **Oberon OS**, Kronyn aims to collapse the boundary between the programming language and the operating system. In this vision:
- The interpreter *is* the kernel.
- System resources are managed as language objects.
- The environment is entirely malleable, allowing the OS to be extended or modified in real-time using the language itself.

---

## [>] Quickstart

```sh
nim c src/kronyn.nim            # build (binary lands in src/)
./src/kronyn tests/01_basics_vars_arith.kr     # run a script
./src/kronyn -measure prog.kr   # run with the performance chart
./src/kronyn -compile prog.kr -o prog   # transpile to C, build native exe
nim r tests/compile/run.nim     # run the transpiler suite (from repo root)
```

Every boot reads `essentials.kr` — beside the binary first, then the working directory — with a compile-time embedded copy (`staticRead`) as fallback, so the binary always boots and runtime files win without recompiling.

---

## [|] Language Overview

### Values & syntax
Values are a tagged variant (`int string list some none`) with a Tcl-like string surface. Three syntactic forms keep strings structured:

| Syntax | Meaning |
| :--- | :--- |
| `"..."` | **Literal** string (`\n \t \" \\` escapes). |
| `[...]` | **Inferred**: sub-expression, evaluated immediately. |
| `{...}` | **Block**: deferred code (bodies, loops, callbacks). |

Bare numeric words are `int`s; `$name` reads a variable. Falsy: `""`, `"0"`, `0`, empty lists, `none` — everything else is truthy, **including `"false"`**. Comparisons (`== != < > <= >=`) and `&& ||` yield `int` `1`/`0`; `+` adds when both sides are int-like else concatenates; `..` always concatenates; `- * /` require integers.

### Intents & dot-functions
Top-level commands (**Intents**, `proc`) extend the language; method-style calls (**dot-functions**, `fn`) receive the caller as `self` and chain left to right:

```kronyn
define greet proc(name) {
    writeln ["Hello " .. $name]
}
greet "World"

define double fn(self) {
    return [$self * 2]
}
writeln 5.double().double()   # 20
```

### Control flow & metaprogramming
- `if` / `elif` / `else`, `while cond body`, `loop body` + `break`, `iter`, `return`.
- `set` assigns (a call evaluates in a fresh child scope, so `set` never leaks out).
- `evolve <string>` runs code in the current scope; `import <path>` runs a file in it.
- `try {…}` yields `some(value)` or `none()`, setting `err` / `errkind` / `errline` / `errtrace`.

### ["" ] Kernel builtins
Strings: `len toUpper toLower trim slice index contains replace split concat` (plus `..`; note `contains` returns the strings `"true"`/`"false"`). Conversion/math: `int str ascii char mod exec`. Predicates: `typeof` plus strict `isInt isString isList` (`1`/`0`). Lists arrive via `split`/`lines` and thread through `filter count first last`. Options: `some none some? none? unwrap unwrapOr map`. I/O: `writeln write input readln`.

### [<>] Syscalls — the only outside world
`syscall <namespace>.<method> <args…>`, arity-checked through a central registry:

| Namespace | Calls |
| :--- | :--- |
| `io` | `output(msg)` / `outputln(msg)`, `input` (one stdin line) |
| `fs` | `read` (`some`, missing/unreadable is `none`), `write` / `append`, `exists` (`1`/`0`), `remove`, `list` (sorted names) |
| `proc` | `exit [code]`, `args` (trailing CLI args as a list) |

### [+] Standard intents (`essentials.kr`, all `@typecheck`ed)
I/O: `print println ask readfile writefile`. Algorithms: `fib`, `factorial`, `reverse`, `isPalindrome`, tail-recursive `sum`. Capped by policy — further libraries ship as opt-in `import` modules, never baked core. Runnable contract: `tests/32_stdlib_essentials.kr`.

### [@] Runtime annotations (RTAs)
Opt-in strictness per procedure; unknown `@anything` is always a hard error:

| RTA | Form | Effect |
|---|---|---|
| `@retry(n)` | any position | re-runs the call up to n times on failure |
| `@actor` | bare, `define`-only | each call runs in its own OS process (own GC+heap), caller blocks; share-nothing |
| `@forkexec` | bare, `define`-only | like `@actor`, but the child inherits the full world (all defines + globals); result is the only channel back |
| `@typecheck` | bare + inline `proc(x: int): ret` | strict kind contracts on entry (fail fast) and return |
| `@tailcallopt` | bare, `define`-only | direct self tail calls loop in one frame (depth 100k verified) |
| `@deprecated` | bare or `("msg")`, `define`-only | first call per proc warns on stderr; the call still runs |
| `@timeout(ms)` | `define`-only | millisecond window; expiry is a catchable `timeout` error (preemptive kill for actors) |

### [!] Errors
All failures are `KronynError(kind, line, message)` with kinds `arity type unknown-command annotation division bounds option io actor fork timeout error`. Uncaught errors print the message plus a capped logical stack. See `Discipline/ERRORS.md`.

---

## [:] Examples

### [:.] Fibonacci (recursion + dot-chaining)
```kronyn
define fib fn(self) {
    if [$self == 0] {return 0}
    elif [$self == 1] {return 1}
    else {return [[$self - 1].fib() + [$self - 2].fib()]}
}

writeln 0.fib()
writeln 5.fib()
writeln 10.fib()   # 55
```

### [:.] String reversal (loops + assignment + indexing)
```kronyn
define reverse fn(self) {
    set result ""
    set i [$self.len() - 1]
    loop {
        if [$i < 0] {break}
        set result [$result .. $self.index($i)]
        set i [$i - 1]
    }
    return $result
}

writeln "hello".reverse()
```

### [:.] I/O & system calls
```kronyn
syscall io.output "enter your name: "
set name [syscall io.input]
writeln ["Hello " .. $name]

syscall fs.write "test.txt" "hello from Kronyn"
set contents [syscall fs.read "test.txt"]
writeln [$contents.unwrap()]
```

---

## [?] Tooling & tests

```
kronyn [-measure] <file.kr> [args...]          # run; args via proc.args
kronyn -compile <file.kr> [-o out] [--emit-c] [--no-cache]  # transpile to C, build exe
kronyn --actor-run <job> <res>                 # internal worker entry point
kronyn --forkexec-run <job> <res>              # internal fork worker entry point
```

- `-measure` adds the `essentials load` timing plus `body cache` and `eval*` counters (`-d:kronynProfile` builds add timings).
- `-compile` translates a declared subset to C (`kronyn_rt.h/.c` runtime) and shells to gcc/clang — refusals (`evolve`, `@actor`, `@forkexec`, …) carry file:line diagnostics. See `COMPILE.md`.
- `tests/*.kr` numbered basic→advanced: `01–05` basics, `06–09` control flow, `10–14` procedures, `15` evolve, `16–17` errors, `18–19` I/O, `20` shell, `21–31` RTAs (retry/actor/typecheck/tailcall), `32–34` stdlib/syscall/error contracts, `35–37` deprecated/timeout/forkexec, `38` showcase, `39` bench.
- `tests/compile/` (run with `nim r tests/compile/run.nim`): 28 transpiler cases — twin, delta, runfail, refusal.
- `movieSet/`: 12-scene production actor stage + `PRODUCTION.md`.
- `translation/`: 13-scene production transpile stage + `PRODUCTION.md`.

---

## [<>] Architecture

```
.kr source → Lexer → Parser → AST → Treewalk evaluator → Env scopes
                                            ├── bodyCache / subCache (AST caches)
                                            ├── RTA wrappers (retry / actor / contracts / trampoline / warn / deadlines)
                                            └── syscall registry (io / fs / proc)
```

| Module | Role |
|---|---|
| `src/token.nim` `src/lexer.nim` | Tokens; char scanner (`"…"` escapes, nest-aware `[...]`/`{...}`, `$name`, `@`, `.` vs `..`) |
| `src/ast.nim` `src/parser.nim` | AST (`word string sub block var chain infix typedParam`); recursive descent with `name(...)` calls, `name: type` params, `@ann` attachments |
| `src/eval.nim` | The runtime: values, scopes, dispatch, builtins, syscalls, RTAs, errors, actor/fork transport |
| `src/kronyn.nim` | CLI driver |
| `src/essentials.kr` | Curated standard intents, baked in via `staticRead` |
| `src/codegen.nim` `src/kronyn_rt.h/.c` | Transpiler emitter + shared C runtime behind `-compile` |

---

## [#] Roadmap

- [x] Treewalk interpreter with parse caching and embedded kernel.
- [x] Seven RTAs: `@retry`, `@actor`, `@forkexec`, `@typecheck`, `@tailcallopt`, `@deprecated`, `@timeout`.
- [x] `-measure` observability and `-compile` transpiler (M1–M4) with twin-parity suites and production stages.
- [ ] Opt-in `import` modules beyond the capped essentials core.
- [ ] Actor hardening: timeouts/watchdog for untrusted code, richer worker story.
- [ ] Tail-call micro-opts (cached descriptors, frame reuse).
- [ ] The long arc stays what it always was: GOCRAZY-style self-specialization research on hold, while the treewalker remains the one and only execution engine — and, stepwise, the language-based machine itself.

## [~] Docs & credits

- Start here → this file. Canonical reference → `SUPER.md`.
- Subsystems → `Discipline/ACTORS.md` `Discipline/FORKEXEC.md` `Discipline/TYPES.md` `Discipline/TAILCALL.md` `Discipline/DEPRECATED.md` `Discipline/TIMEOUT.md` `Discipline/ERRORS.md` `Discipline/SYSCALL.md` · numbers → `PERF.md` · transpiler → `COMPILE.md` · issues → `Negatives/` · deferred compiler dream → `GOCRAZY.md` (on hold).
- Kronyn is heavily inspired by **Tcl** (command philosophy) and the **MORRIS standards** (Intents).
