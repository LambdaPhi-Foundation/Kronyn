# Kronyn Syscall Discipline (`SYSCALL.md`)

## What it is

`syscall <namespace>.<method> <args...>` is the only way Kronyn code
touches the outside world. Calls dispatch through a registry
(`registerSyscall` in `src/eval.nim`): each entry declares its
namespace, method, and arity, so unknown names and wrong arg counts
fail as Kronyn `ValueError`s, never as interpreter tracebacks.

## Surface

- `io.output(msg)` / `io.outputln(msg)`: stdout (`""`).
- `io.input`: one stdin line (`string`).
- `fs.read(path)`: contents as `some`, missing **or unreadable**
  (directory, permissions) as `none`.
- `fs.write(path, contents)` / `fs.append(path, contents)`: (`""`).
- `fs.exists(path)`: plain `1` / `0` (not `Option` — there is no
  absent case to represent).
- `fs.remove(path)`: `""` on success, `none` when missing
  (`rm -f` callers simply ignore the result).
- `fs.list(dir)`: sorted entry names as a `list`; missing path or
  plain file is `none`.
- `proc.exit [code]`: terminates the whole process (default `0`).
- `proc.args`: trailing CLI args as a `list`
  (`kronyn prog.kr a b` → `a b`); always empty inside workers.

## Discipline (read before using)

1. **Arity is checked centrally.** Every call declares
   `min..maxArgs`; violations raise
   `syscall <ns>.<meth> expects N args, got M` (or `N..M` for
   `proc.exit`). Unknown namespaces and methods raise
   `unknown syscall namespace` / `unknown <ns> syscall`.
2. **`none` means "no value", not "error".** Absence and
   unreadability both read as `none` — branch with `none?` /
   `unwrapOr`, don't `try` them. Genuine failures (remove racing
   a directory, bad syscall shape) raise instead.
3. **No shell by default.** `exec` exists but prefer `fs.*`:
   `exec "rm -f"` is banned in-tree (four sites migrated); shell
   quoting, exit codes, and platform shells are all yours if you
   use it.
4. **Syscalls bypass RTAs.** `@typecheck`/`@retry` on definitions
   still apply around calls, but contracts cannot annotate the
   syscalls themselves — validate shapes (`none?`, `len`) at the
   call site. `@actor` is rejected on bare syscall statements like
   any non-`define`.
5. **Workers see an empty world plus disk.** Actor children get the
   same registry and the same filesystem — files are the only
   shared channel, coordinate them. `proc.exit` kills the worker
   (reported as worker failure); `io.input` races stdin; `argv`
   never leaks job plumbing.
6. **Adding a call:** one `SyscallFn` proc plus one
   `registerSyscall` line (namespace, method, arity) — never touch
   the dispatch branch. Cover it in `tests/33_syscalls.kr`
   (arity, shapes, missing-path policy) and extend § Surface above.
