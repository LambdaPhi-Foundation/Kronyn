# Negatives — issues, concerns, limitations

> The canonical ledger of everything wrong, bounded, or risky about
> Kronyn. Nothing here is hidden: bugs are reproduced before they are
> listed, limits carry measurements or pointers to them, risks state
> their evidence plainly. `SUPER.md` §14 summarizes; this folder
> details.

## Severity scale

- **high** — crashes, wrong answers, or security-relevant. Fix or
  fence before building on top.
- **medium** — real constraints that shape what you should attempt.
- **low** — cosmetic, hygiene, or edge-case only.

## Master table

| ID | Title | Severity | Status |
|---|---|---|---|
| B1 | Lexer: string-blind bracket nesting can crash (`IndexDefect`) | high | open |
| B2 | `set` with non-name target crashes the interpreter | medium | open (compiled side refuses cleanly) |
| B3 | Dropped trailing statements in multi-statement conditions | medium | kept intentionally (compiler refuses) |
| B4 | First-pair-only chained infix in `[...]` subs | low | kept intentionally (compiler folds left-assoc, documented) |
| B5 | Deep plain recursion trips the debug call-depth limiter | medium | mitigated (`@tailcallopt`) |
| B6 | Dead `tests/test1.nim` template + broken `nimble test` | low | open |
| B7 | `kronyn.nim` usage typo (`file for found`) | low | open, cosmetic |
| B8 | Editor backup files litter `src/` and `tests/` | low | hygiene backlog |
| L1 | Treewalk dispatch overhead (~19x per-char, ~3x composites) | medium | accepted, measured (`PERF.md`) |
| L2 | No static types; contracts are runtime-only and opt-in | medium | by design |
| L3 | Actors are OS processes: ~15–25ms spawn, caller blocks, share-nothing, closed world | medium | by design (`Discipline/ACTORS.md`) |
| L4 | No timeouts by default (hung actor/loop hangs caller) | medium | mitigated (`@timeout`) |
| L5 | `try` catches `ValueError` only; `Defect` means interpreter bug | low | by design |
| L6 | Line numbers are best-effort; traces carry location | low | by design, declined fix |
| L7 | Caught errors leak ~7 small Values per catch (compiled) | low | measured, pools declined (`COMPILE.md` #14) |
| L8 | `exec` is platform-shell-defined; banned in-tree | low | by design (`Discipline/SYSCALL.md`) |
| L9 | Compiled subset refusals (`evolve`, `map`, `@actor`, `@forkexec`, …) | medium | by design (`COMPILE.md`) |
| L10 | RTA counts/paths must be literals; imports resolve at compile time | low | by design, documented |
| L11 | C-string edge semantics (ASCII case/trim, empty-delim split, int wrap) | low | documented (`COMPILE.md` #5–7) |
| L12 | Forks are OS processes with full-world snapshots; locals not inherited, no nesting, no compiled support | medium | by design (`Discipline/FORKEXEC.md`) |
| R1 | Vision–engine gap (language-based OS vs treewalker throughput) | medium | open question |
| R2 | POSIX branches review-only; no Linux CI run yet | medium | mitigation proposed |
| R3 | No sandbox: running untrusted `.kr` is arbitrary code execution | high | must state to users |
| R4 | Single-author bus factor | low | noted |
| R5 | Doc drift (`SPEC.md` stale; two doc sources) | low | slated (archive `SPEC.md`) |

Details: `BUGS.md` (B1–B8) · `LIMITS.md` (L1–L12) · `RISKS.md`
(R1–R5). Rule: fix the bug or update the row — never silently drop
one. Removing a row requires the fix to land in the suite first
(reproduce-then-fix, like everything else here).
