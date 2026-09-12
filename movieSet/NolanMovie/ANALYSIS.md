# NolanMovie — actor ceiling test: how many actors can the interpreter handle?

> Stage: `movieSet/NolanMovie/`. Probe: `nolan.kr` (parameterized,
> self-asserting). Verdict up front: **no breaking point found up to
> 3200 sequential `@actor` calls** — every value exact, zero orphans,
> zero temp leftovers, flat ~16–17ms per spawn. The limit is linear wall
> time, not a resource cliff.

## 1. Method

`nolan.kr` takes `N` from trailing CLI args (`syscall proc.args`,
default 100) and performs `N` back-to-back minimal `@actor` round trips
(`nolanEcho`: return the int it receives). Every result is checked
value-by-value; any mismatch exits 1 with no `PASS` line. One round trip
= one full spawn: temp job file → child process (fresh interpreter +
essentials re-evaluation) → result file → parent read → both files
deleted.

Run from the repo root, one rung at a time:

```powershell
./src/kronyn.exe movieSet/NolanMovie/nolan.kr 100
```

After the heavy rungs, two audits (both must read 0):

```powershell
Get-Process kronyn -ErrorAction SilentlyContinue | Measure-Object
Get-ChildItem $env:TEMP -Filter "kronyn_actor_*" | Measure-Object
```

## 2. Environment

- OS: Windows/amd64. Binary: `src/kronyn.exe`, `nim c` debug build.
- Working directory for all runs: repo root (`D:\kronyn`).
- Payload: minimal (single int each way) — this isolates spawn count;
  payload scaling is covered separately by `movieSet/scene11_payload.kr`.

## 3. Results

| N (spawns) | Wall time | Per spawn | Exit | Orphans | Temp leftovers |
|---|---|---|---|---|---|
| 5 | — | — | 0 | — | — |
| 10 | 0.17s | 16.9ms | 0 | — | — |
| 50 | 0.83s | 16.6ms | 0 | — | — |
| 100 (default, no args: 1.64s) | 1.75s | 17.5ms | 0 | — | — |
| 200 | 3.26s | 16.3ms | 0 | — | — |
| 400 | 6.53s | 16.3ms | 0 | — | — |
| 800 | 13.17s | 16.5ms | 0 | 0 | 0 |
| 1600 | 26.31s | 16.4ms | 0 | 0 | 0 |
| 3200 | 53.59s | 16.7ms | 0 | 0 | 0 |

Every rung printed its `PASS nolan N=…` line (exit 0 = all `N` values
exact). Per-spawn cost is flat across two orders of magnitude — no
degradation, no cliff.

## 4. Breaking point: none observed (and why that is expected)

There is no count at which this design breaks, because there is no
accumulating state:

- **No shared heap.** Each worker is its own OS process; when it exits
  the kernel reclaims all its pages in bulk. 3200 spawns never coexist —
  at most 2 Kronyn processes exist at any instant (parent + one worker).
- **No leftover channels.** Job/result files are deleted in a `finally`
  on every path including failures and timeout kills (audits above read
  0/0 after 800, 1600, and 3200 spawns).
- **Bounded parent state.** The caller's per-call work is one pooled
  `Env` frame (cap 64, reused — see `Refactor/` R4) plus two small temp
  files; nothing grows with `N`. The flat per-spawn column is the
  evidence: handle or memory leakage would show as a rising slope.
- **Unique job names.** Temp files are `kronyn_fork_<pid>_<seq>` /
  `kronyn_actor_<pid>_<seq>` with a monotonic per-process sequence, so
  rapid reuse can never collide — including PID reuse across runs.

What *does* scale with `N` is wall time, strictly linear at ~16–17ms per
spawn on this box (process creation + essentials re-evaluation +
marshal round trip). Practical budget table:

| Budget | Max sequential actors |
|---|---|
| 1s | ~60 |
| 10s | ~600 |
| 1min | ~3500 |
| 10min | ~35000 |

So the honest breaking point is operational, not structural: past a few
thousand sequential actors you are spending minutes of wall time, and the
correct move is coarser tasks (fewer, bigger workers — the standing
`Discipline/ACTORS.md` rule 1), not more spawns.

## 5. What was NOT tested (out of scope)

- **Payload scaling** (large args/results per call) — see `scene11`.
- **Distinct-procedure count** (registry growth over many different
  `@actor` defines rather than many calls of one). The transport is
  identical per call, so no separate cliff is expected, but it was not
  laddered here.
- **Parallel spawns** — the caller blocks by design (`waitForExit`); there
  is no fan-out primitive, so "at most" here means sequential depth.
- **Timeout-kill storms** (many preempted workers in a row) — kill+reap
  runs on every expiry path and the audits above cover the clean path;
  a kill-heavy ladder would be a worthwhile sequel stage.

## 6. Re-run checklist

1. `nim c src/kronyn.nim` (debug).
2. Ladder `5 → 3200` as in §1 from the repo root.
3. Expect exit 0 + `PASS` at every rung; audits 0/0 after the heavy rungs.
4. Any nonzero exit, missing `PASS`, stray `kronyn.exe`, or leftover
   `kronyn_actor_*` file is a red run — file it against the transport
   (`spawnActorCall` cleanup / `waitForExit` handling), not the counter.
