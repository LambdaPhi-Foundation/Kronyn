# Kronyn Type Contracts (`@typecheck` RTA)

## What it is

`@typecheck` turns a procedure's inline signature into an enforced
contract. Types are the five runtime `ValueKind`s — `int`, `string`,
`list`, `some`, `none` — plus `any` as an explicit opt-out.

```kronyn
@typecheck
define adder proc(x: int, y: int): int {
    return [$x + $y]
}
adder 3 4      # 7
adder "3" 4    # Kronyn error: line L: adder expects int for 'x', got string
```

## Discipline (read before using)

1. **Declaration is inline, enforcement is opt-in.** Param types go
   in the signature (`proc(x: int, $prompt: string)`), the return
   type after it (`... ): int`). Without `@typecheck` the
   declarations parse but are never consulted. With it, every
   parameter must declare a type; the return type is optional
   (absent means the return is unchecked).
2. **Strict kinds, no coercion.** `"3"` is a `string`, never an
   `int`, even though it holds digits. `nil` (only reachable via
   actor transport edges) counts as `none`. Unknown type names and
   missing declarations fail at **define time**, never at first call.
3. **Fail fast, never retried, never spawned.** Param checks run
   before retry loops and before any actor spawn, so a violation
   costs one error, zero workers, zero side effects (the body never
   runs). Return checks run once after the call succeeds.
4. **`@typecheck` is bare and define-only.** `@typecheck(...)`
   with arguments, duplicates aside, is an error; on any non-`define`
   statement it is rejected like `@actor`. Unknown `@anything`
   is rejected everywhere. Typed `name: type` syntax outside a
   `define` signature (calls, sub-expressions, annotations) is a
   `misplaced type annotation` error.
5. **Actors are checked on both sides.** The parent checks args
   pre-spawn and re-checks the marshalled return post-spawn; the
   worker enforces the same contract on its self-definition
   (recursion included — each level is checked, attempts stay
   linear, see `ACTORS.md` rule 5).
6. **Ordering composes positionally.** `@retry`/`@actor` keep their
   existing inside-out rules; `@typecheck` is orthogonal and always
   outermost on entry (pre-dispatch) and innermost on exit
   (post-success).
7. **Whitespace-insensitive.** `f(x:int):int` and `f(x : int) : int`
   parse identically. A missing type after `:` is a parse error
   naming the line.
