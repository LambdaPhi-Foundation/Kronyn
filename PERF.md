# Kronyn Performance Notes (measured, not assumed)

Binary: `nim c` (debug), Nim 2.2.8, Linux/amd64. Reproduce with the
`phase_*.kr` patterns below (200 iterations for string ops,
2000 for composites).

## Ladder vs essentials: the gate held, nothing moved

Rule adopted: a builtin moves to `essentials.kr` only if its Kronyn-level
twin measures ~free. Outcome: **no moves.**

| Candidate | Twin | Ratio (twin : builtin) | Verdict |
|---|---|---|---|
| `toUpper` | char loop via `index`/`ascii`/`char`/`..` | **~19x** (0.269s vs 0.014s) | stays in Nim, permanently |
| `some?`/`none?`/`unwrapOr`/`concat`/`str` | via `typeof`, `..`, builtins | **~3x** (0.295s vs 0.099s) | stays in Nim (over gate) |
| `first`/`last`/`lines`/`filter`/`count` | — | not expressible | stays in Nim |

Notes:

- The 19x is a floor: the twin still calls builtin `trim`/`len`/
  `index`/`ascii`/`char`. A pure-Kronyn version would be worse.
  Per-character tree-walking (~10+ `eval` calls per char) can never
  approach one Nim call.
- The 3x on composites is almost entirely the extra user-proc call
  frame (`callFn` + child `Env` + `if`/`return` dispatch) around the
  same inner builtin. Twins were verified output-identical, so the
  only cost of keeping them in Nim is surface area, not behavior.
- `first`/`last`/friends cannot be written with current primitives
  at all: there is no list indexing and no substring search
  (`index` takes a position, `contains` is boolean). Enabling the
  move would mean adding *new* Nim primitives — defeating its purpose.
- `staticRead` was never the bottleneck: load is ~1ms either way.
  Steady-state dispatch is the whole game.

## Spawn baseline (cap justification)

20 minimal `@actor` round-trips: **0.081s wall (~4ms/spawn)**,
covering process spawn + essentials re-evaluation. Baked core stays
capped at current order (~15 intents); further libraries go to
opt-in `import` modules, never the baked core. Re-time spawns if
essentials grows.

## Counter guidance

`@typecheck` contract checks call the Nim helpers directly, never
the `isInt`-family commands — ladder placement of predicates does
not affect contract speed either way.
