# RISKS — concerns and open questions

> Judgment calls and future-facing worries, stated with evidence.
> Promote to LIMITS when decided, to BUGS when reproduced.

## R1 — Vision–engine gap (medium)

The north star is a language-based OS in the Lisp Machine / Oberon
spirit, but the engine is a treewalker with a measured dispatch
ceiling (~19x per-char). The honest paths are: (a) revive a
throughput track (GOCRAZY phase 3, currently on hold), (b) narrow
the vision to scripting + orchestration where the engine already
wins, or (c) accept the gap explicitly. Currently (c) by default —
worth a deliberate choice before new performance promises are made.

## R2 — POSIX branches review-only (medium)

`fs.list` (`readdir`), `exec` (`popen`), and the realtime clock have
a Windows-measured twin and a POSIX read-through, but no Linux run
has happened. Mitigation: one Linux pass of `nim r
tests/compile/run.nim` with gcc present converts the caveats to
facts. The runner is portable (newlines normalized) precisely for
this.

## R3 — No sandbox: untrusted `.kr` is arbitrary code execution (high)

`exec`, `evolve`, `import`, and the full `fs` surface mean any
`.kr` file (or any string reaching `evolve`) runs with the user's
privileges. There is deliberately no sandbox, no capability model,
no timeout by default. Anyone embedding Kronyn (REPLs, `shell.kr`,
actor workers on shared inputs) must treat scripts as fully trusted
code and say so to their users. `@timeout` bounds CPU, not access.

## R4 — Single-author bus factor (low)

One author (`kronyn.nimble`), no CI, no changelog discipline past
v0.003. Mitigations in place: spec-in-`SUPER.md`, discipline docs
per feature, twin suites that encode behavior. Still: get the suite
running somewhere automatic before the tree grows further.

## R5 — Doc drift (low)

`SPEC.md` still describes retired systems (KASM/VM, byte-marker
Options, strict EIAS) and is only disclaimed, not archived; this
folder now overlaps `SUPER.md` §14 by design (ledger canonical,
summary there). Slated: archive `SPEC.md`, keep one map (`SUPER.md`
§16) accurate on every docs change.
