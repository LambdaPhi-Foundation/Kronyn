# PRODUCTION.md — Actor RTA Intensive Tests (`movieSet/`)

> Production-grade verification of the `@actor` RTA: every scene is a
> self-asserting script (`PASS` lines, `proc.exit 1` on first `FAIL`),
> run against the real binary. Detail spec: `../Discipline/ACTORS.md`.

## 1. Environment

- OS: Windows/amd64. Toolchain: Nim 2.2.12, `nim c src/kronyn.nim`
  (debug build). Binary: `src/kronyn.exe`.
- Working directory for all runs: repo root (`D:\kronyn`), so the
  relative marker path `movieSet/marker_*.txt` resolves portably
  (no `/tmp` dependency — the `tests/` suite needs `D:\tmp` on
  Windows, these scenes deliberately do not).
- Method: each scene run individually, exit code + wall time
  recorded (`Measure-Command`). Any `FAIL` line or nonzero exit is a
  red run. Orphan audit after the suite: `tasklist` for stray
  `kronyn.exe` workers and leftover `kronyn_actor_*` temp files.

## 2. How the actor RTA works (under test)

`@actor` on a `define` makes every call spawn its own OS process
(own GC, own heap — share-nothing by construction). Transport: the
parent serializes the call with `std/marshal` to a temp job file and
re-runs its own binary as `kronyn --actor-run <job> <res>`; the child
builds a fresh interpreter, re-registers the procedure **plain** (so
recursion inside the worker stays in-process), runs it, and writes
the typed result back. The caller blocks. Temp files are removed
after each call, including on failure.

## 3. How to re-run

```powershell
# from the repo root, one scene:
./src/kronyn.exe movieSet/scene01_fib.kr; echo $LASTEXITCODE
# the whole stage (expects no output but PASS/done lines, exit 0 each):
foreach ($f in 1..12) { $n = "scene{0:D2}" -f $f; ./src/kronyn.exe "movieSet/$n_*.kr" }
```

## 4. Scene catalog and results

| Scene | Goal | Workers | Result | Time |
|---|---|---|---|---|
| `scene01_fib.kr` | Correctness: `afib` 0/1/10/12/20 → 0/1/55/144/6765 | 5 | 5/5 PASS | 2.62s |
| `scene02_faults.kr` | Faults: div-by-zero, unknown command (kind `actor` + message), `proc.exit 3` crash → `worker failed (exit 3)` | 3 | 4/4 PASS | 0.07s |
| `scene03_isolation.kr` | Share-nothing: parent vars read as `""` in worker, worker `set` never leaks back | 2 | 3/3 PASS | 0.05s |
| `scene04_retry.kr` | `@retry(3)` above `@actor`: attempt 1 fails, attempt 2 (fresh worker) sees the marker file and succeeds; `@retry(2)` hopeless exhausts with kind `actor` | 4 | 2/2 PASS | 0.09s |
| `scene05_farm.kr` | Farm: squares 1..10 across 11 sequential workers, sum 385 + spot check | 11 | 2/2 PASS | 0.25s |
| `scene06_contracts.kr` | `@typecheck` x `@actor`: valid call runs; bad params rejected **pre-spawn** (kind `type`); bad return enforced in worker (kind `actor`) | 3 spawned, 1 rejected | 5/5 PASS | 0.05s |
| `scene07_deep.kr` | `@tailcallopt` x `@actor`: `countdown 20000` → 200010000 inside the worker | 1 | 1/1 PASS | 2.90s |
| `scene08_timeout.kr` | `@timeout` x `@actor`: bounded fast worker unaffected; infinite-loop worker ended at 400ms, kind `timeout` | 2 | 3/3 PASS | 0.44s |
| `scene09_deprecated.kr` | `@deprecated` x `@actor`: calls run; stderr holds **exactly 1 line** for 2 calls (warn-once, parent-side only) | 2 | 2/2 PASS | 0.05s |
| `scene10_stress.kr` | 30 back-to-back minimal round trips, every value exact | 30 | 30/30 PASS | 0.51s |
| `scene11_payload.kr` | 2KB string across `marshal` both ways: size + byte-exact equality | 1 | 3/3 PASS | 0.07s |
| `scene12_cleanup.kr` | fs discipline mid-stage: write/exists/read/remove/none-on-missing | 0 | 4/4 PASS | 0.02s |

Totals: **12/12 scenes green, 64 workers spawned, 0 orphans, 0 temp
leftovers, 0 marker files left behind** (scenes remove their own
markers; verified by directory listing after the run).

## 5. Findings

1. **Spawn cost (Windows): ~15–25ms per minimal round trip.**
   Scene10: 30 spawns in 0.51s (≈17ms each); scene05: 11 in 0.25s.
   An order of magnitude above the `PERF.md` Linux figure (~4ms),
   same conclusion: coarse tasks only, never per-element mapping.
2. **Recursion inside workers is local and fast.** Scene01's five
   top-level spawns dominate its 2.62s; `fib(20)` (≈22k local calls)
   rides along inside one worker. Do not confuse top-level spawns
   with in-worker recursion.
3. **Fault taxonomy holds across the boundary.** Worker `KronynError`
   kinds flatten to parent kind `actor` with the worker message and
   worker trace appended; a dead worker (no result file) reports
   `worker failed (exit N)` with the true exit code (scene02's
   `exit 3` proves the code path, not just the message).
4. **Contracts are enforced on both sides, fail-fast on entry.**
   Scene06 pins the asymmetry: bad params → kind `type`, zero
   workers spawned; bad return → kind `actor` after the round trip.
5. **Preemptive timeout kills cleanly.** Scene08's infinite-loop
   worker dies at the 400ms budget; post-suite audit shows no stray
   `kronyn.exe` and no `kronyn_actor_*` files. Implementation note
   (see `../Discipline/TIMEOUT.md`): on Windows, Nim's `waitForExit(timeout)`
   ends the child itself and returns a bogus `0`, so expiry is
   classified by missing-result-file + clock, with an explicit
   kill-if-alive for other platforms.
6. **Deprecation crosses silently on the worker side.** Scene09's
   two actor calls produce exactly one parent-side stderr line —
   warn-once and parent-only compose (see `../Discipline/DEPRECATED.md`).
7. **Tail-call flag crosses into workers.** Scene07's 20k-deep sum
   returns 200010000 from inside a worker (≈2.9s, consistent with the
   ~70µs/iter trampoline cost in `../Discipline/TAILCALL.md`).
8. **Payloads round-trip byte-exact.** 2KB through `marshal` both
   ways, verified by full-string equality (scene11).
9. **New-proc budget scoping is per process.** Each scene is its own
   process, so warn-once/deadline state never leaks between scenes.

## 6. Limits reconfirmed (not re-tested here)

- Caller blocks per call — the farm is sequential, there is no
  parallelism in v1.
- Closed world: only builtins + essentials + the actor itself are
  visible in workers (scene03 pins the variable half; mutual
  recursion across procedures remains unsupported).
- `syscall io.input` inside workers races stdin; `proc.args` is
  empty in workers; `proc.exit` kills the worker, not the parent
  (scene02 leans on the last one).
- Bare actor waits have no deadline — pair with `@timeout`
  (scene08) on untrusted code.

## 7. Files

`scene01_fib.kr` `scene02_faults.kr` `scene03_isolation.kr`
`scene04_retry.kr` `scene05_farm.kr` `scene06_contracts.kr`
`scene07_deep.kr` `scene08_timeout.kr` `scene09_deprecated.kr`
`scene10_stress.kr` `scene11_payload.kr` `scene12_cleanup.kr`
— plus this document. No binaries, no fixtures, no leftovers.
