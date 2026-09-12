# PRODUCTION.md — Transpiler Intensive Tests (`translation/`)

> Production-grade verification of the `-compile` transpiler: every
> scene is self-asserting (`PASS` lines, `proc.exit 1` on first
> `FAIL`) and runs **twice** — interpreted and compiled — with
> byte-identical stdout, stderr, and exit codes required. Detail
> spec: `../COMPILE.md`.

## 1. Environment

- OS: Windows/amd64. Toolchain: Nim 2.2.12 (`nim c src/kronyn.nim`,
  debug build) + gcc 15.2.0 (only `cc` on `PATH`; no clang).
- Working directory for all runs: repo root (`D:\kronyn`), so the
  relative paths (`translation/tmp_*.txt`, `translation/lib_trans.kr`)
  resolve identically at interpret time, compile time (import
  splicing), and binary runtime (portable, no `/tmp` dependency).
- Method: per scene — run interpreted (exit code + stdout + stderr
  captured), `-compile --no-cache` (full gcc path every time, so the
  cache can hide nothing), run the binary the same way, `fc` both
  streams. Any `FAIL` line, exit-code mismatch, or byte difference
  is a red scene.

## 2. How to re-run

```bat
rem from the repo root; twin batches A-D live in %TEMP%\opencode\*.bat
rem single scene, interpreted vs compiled:
src\kronyn.exe translation\trans01_core.kr
src\kronyn.exe -compile translation\trans01_core.kr -o trans01.exe
trans01.exe
rem special invocations:
src\kronyn.exe translation\trans09_syscalls.kr alpha beta
trans09_syscalls.exe alpha beta
echo bob | src\kronyn.exe translation\trans12_stdin.kr
```

## 3. Scene catalog and results

| Scene | Goal | Result |
|---|---|---|
| `trans01_core.kr` | M1 surface: arithmetic, strings, lists, options, if/elif/else, while, loop+break (35 checks) | SAME, 0/0 |
| `trans02_procs.kr` | Recursion, dot chains, mutual recursion, shadowing, last-value, `?`-names, greet side effect | SAME, 0/0 |
| `trans03_contracts.kr` | `@typecheck` valid calls + caught param/return violations (kinds + messages) | SAME, 0/0 |
| `trans04_tailcall.kr` | Intent + dot tail loops (20k/5k), typechecked tail sum | SAME, 0/0 |
| `trans05_try.kr` | try shapes, err vars, try-in-proc, break-across-try + later catch | SAME, 0/0 |
| `trans06_retry.kr` | Marker-driven eventual success, exhaustion, fast path, statement retry + recovery | SAME, 0/0 |
| `trans07_deptimeout.kr` | Deprecated runs (warn-once stderr twinned), generous/tight/retry timeouts | SAME, 0/0 |
| `trans08_import.kr` + `lib_trans.kr` | Proc + binding spliced from a relative import, hermetic binary | SAME, 0/0 |
| `trans09_syscalls.kr` | fs write/exists/read/append/remove/list, io output, `proc.args` with `alpha beta` | SAME, 0/0 |
| `trans09b_exit.kr` | `proc.exit 7` terminates with code 7 | exit 7 both, same out |
| `trans10_exec.kr` | Portable `echo`, merged shell-error text | SAME, 0/0 |
| `trans11_stress.kr` | 50k loop, string churn, 50-proc farm, fib(20)=6765 | SAME, 0/0 |
| `trans12_stdin.kr` | `ask` + `io.input` over piped stdin | SAME, 0/0 |
| `rej01_evolve.kr` | `evolve` refused | `evolve is not compilable in v1` |
| `rej02_actor.kr` | `@actor` refused | `@actor is not compilable in v1` |
| `rej03_unknown.kr` | Unknown command refused | `unknown command: nosuchcmd_here` |
| `rej04_arity.kr` | Arity refused at compile time | `writeln expects 1 args, got 2` |
| `runfail_divzero.kr` | Uncaught division: both die | exit 1/1, `division by zero` |
| `runfail_contract.kr` | Uncaught contract violation: both die | exit 1/1, `expects int for 'x'` |
| `runfail_timeout.kr` | Uncaught 150ms timeout: both die | exit 1/1, `timed out after 150ms` |

Totals: **13/13 twin scenes identical on both streams; 4/4 refusals
precise; 3/3 runfails matched on code + substring.**

## 4. Compile-level results

| Check | Result |
|---|---|
| `--no-cache` | `compiled` message, nothing stored |
| Miss → hit | `compiled` then `cached`, hit binary runs correctly |
| `--emit-c` | `.c` kept, includes `kronyn_rt.h`, contains `krn_fn_*` symbols |
| Generated C under `gcc -O2 -Wall` | zero warnings |
| Cache content-addressing | identical sources under different names share one entry |
| Changed source | new hash, recompiles; failures store nothing |

## 5. Measured timings (wall, this machine)

| Case | Interpreted | Binary | Notes |
|---|---|---|---|
| trans11 (50k loop + churn + farm + fib20) | 4.34s | 1.09s | ~4x on loop-heavy code |
| trans04 (25k tail iterations total) | 4.08s | 0.03s | ~136x; C loop vs ~70µs/iter trampoline |
| gcc invocation (test3-class) | — | 2.3s compile | dominates; cache hit 0.04s (~57x) |

Numbers, not claims: the transpiler removes dispatch overhead
(~4x on mixed code) and the trampoline re-parse cost (~136x on
tail loops); gcc time dominates short programs, which is what the
cache is for.

## 6. Findings

1. **Twin parity holds byte-identically on both streams** across the
   whole stage, including stderr (deprecation warnings) and exit
   codes — the same-parser-both-backends bet pays off.
2. **Tail-call shapes are exact.** Staging caught a double-bracketed
   `return [[$self - 1].tick()]`: it recurses normally in *both*
   backends (the matcher only accepts `return [$self - 1].tick()`)
   and trips the host limiter at depth 5000 in the interpreter
   while the binary loops. The single-bracket form twins perfectly.
3. **Deviation #10 observed live.** A chained `"[" .. X .. "]"`
   during prep printed with the trailing `"]"` in the binary and
   without it interpreted (first-pair-only walker rule) — exactly
   as documented in `COMPILE.md`; scenes use nested single-`..`.
4. **Static mistakes refuse early with interpreter-class messages**
   (`unknown command`, arity text), so `try`/`@retry` in scenes only
   ever see runtime failures — the split from `COMPILE.md` #13 held
   everywhere it was probed.
5. **Hermetic imports work end to end**: relative path, proc +
   binding, no runtime reread, missing/circular/nested/dynamic
   cases refused (covered in `tests/compile/`).
6. **`exec` twins on both outcomes** on the same machine (success
   text and merged shell-error text), with exit status ignored on
   both sides — the `popen`+`2>&1` design from M4.
7. **No lexer-bracket scenes.** Nested `[...]` with `]` inside
   strings crashes *both* backends identically (shared lexer,
   filed in `SUPER.md` §14); scenes route around it via `93.char()`.

## 7. Limits reconfirmed (not re-tested here)

- `evolve`, `map`, `@actor` refuse (see `rej*` + `tests/compile/`).
- `errline` follows the compiled true-line rule (deviation #1):
  scenes assert kinds/messages, never raw `errline`.
- Timeout windows need headroom over the work they bound; actor
  paths are interpreter-only (see `movieSet/`).
- Shell error text twins per platform only (same shell both sides).

## 8. Files

`trans01_core.kr` `trans02_procs.kr` `trans03_contracts.kr`
`trans04_tailcall.kr` `trans05_try.kr` `trans06_retry.kr`
`trans07_deptimeout.kr` `trans08_import.kr` `lib_trans.kr`
`trans09_syscalls.kr` `trans09b_exit.kr` `trans10_exec.kr`
`trans11_stress.kr` `trans12_stdin.kr` `rej01_evolve.kr`
`rej02_actor.kr` `rej03_unknown.kr` `rej04_arity.kr`
`runfail_divzero.kr` `runfail_contract.kr` `runfail_timeout.kr`
— plus this document. Markers self-clean; no binaries, no fixtures.
