# compile-suite runner: twin / delta / runfail / refusal cases.
# Run from the repo root AFTER `nim c src/kronyn.nim`:
#   nim r tests/compile/run.nim
# Exit code is the failure count (0 = green).
#
# Kinds:
#   twin    - interpreted and compiled runs: exit 0, identical stdout
#             AND stderr (deprecation warnings included).
#   delta   - compiled stdout must equal <name>.expected; the
#             interpreter must only exit 0 (documents an intended
#             improvement, e.g. true errline in COMPILE.md #1).
#   runfail - compiles fine, binary exits nonzero, output contains
#             the given substring.
#   refusal - compilation fails, output contains the given substring.
# Case files live beside this runner; libs (lib_*.kr) are helpers,
# never cases. Compiled binaries go to tests/compile/out/.

import osproc, os, strutils, streams

let root = getCurrentDir()
let kronyn = root / "src" / addFileExt("kronyn", ExeExt)
let cdir = root / "tests" / "compile"
let outdir = cdir / "out"

if not fileExists(kronyn):
  quit("build first: nim c src/kronyn.nim", 1)
createDir(outdir)

var fails = 0

# Both backends emit platform newlines (\r\n on Windows consoles);
# normalize so fixtures are portable.
proc norm(s: string): string =
  s.replace("\r\n", "\n")

proc say(ok: bool, label, detail: string) =
  if ok:
    echo "PASS: " & label
  else:
    inc fails
    if detail == "":
      echo "FAIL: " & label
    else:
      echo "FAIL: " & label & " :: " & detail

proc runProg(exe: string, args: seq[string]): tuple[outp, errp: string,
    code: int] =
  var p = startProcess(exe, args = args, options = {poUsePath})
  result.outp = p.outputStream.readAll()
  result.errp = p.errorStream.readAll()
  result.code = p.waitForExit()
  p.close()

proc twin(name: string) =
  let kr = cdir / name & ".kr"
  let interp = runProg(kronyn, @[kr])
  if interp.code != 0:
    say(false, name, "interpreter exit " & $interp.code & ": " & interp.outp)
    return
  let exe = outdir / addFileExt(name, ExeExt)
  let cc = runProg(kronyn, @["-compile", kr, "-o", exe])
  if cc.code != 0:
    say(false, name, "compile failed: " & cc.outp & cc.errp)
    return
  let comp = runProg(exe, @[])
  if comp.code != 0:
    say(false, name, "binary exit " & $comp.code & ": " & comp.outp)
    return
  if norm(comp.outp) != norm(interp.outp):
    say(false, name, "stdout differs:\n--- interp ---\n" & interp.outp &
      "--- compiled ---\n" & comp.outp)
    return
  if norm(comp.errp) != norm(interp.errp):
    say(false, name, "stderr differs:\n--- interp ---\n" & interp.errp &
      "--- compiled ---\n" & comp.errp)
    return
  say(true, name, "")

proc delta(name: string) =
  let kr = cdir / name & ".kr"
  let interp = runProg(kronyn, @[kr])
  if interp.code != 0:
    say(false, name, "interpreter exit " & $interp.code)
    return
  let exe = outdir / addFileExt(name, ExeExt)
  let cc = runProg(kronyn, @["-compile", kr, "-o", exe])
  if cc.code != 0:
    say(false, name, "compile failed: " & cc.outp & cc.errp)
    return
  let comp = runProg(exe, @[])
  let want =
    try:
      readFile(cdir / name & ".expected")
    except IOError, OSError:
      say(false, name, "missing " & name & ".expected")
      return
  if norm(comp.outp) != norm(want):
    say(false, name, "output differs:\n--- want ---\n" & want &
      "--- got ---\n" & comp.outp)
    return
  say(true, name, "")

proc runfail(name, sub: string) =
  let kr = cdir / name & ".kr"
  let exe = outdir / addFileExt(name, ExeExt)
  let cc = runProg(kronyn, @["-compile", kr, "-o", exe])
  if cc.code != 0:
    say(false, name, "compile failed: " & cc.outp & cc.errp)
    return
  let comp = runProg(exe, @[])
  if comp.code == 0:
    say(false, name, "binary should have failed")
    return
  if sub notin comp.outp:
    say(false, name, "missing " & sub & " in: " & comp.outp)
    return
  say(true, name, "")

proc refusal(name, sub: string) =
  let kr = cdir / name & ".kr"
  let exe = outdir / addFileExt(name, ExeExt)
  let cc = runProg(kronyn, @["-compile", kr, "-o", exe])
  if cc.code == 0:
    say(false, name, "compile should have failed")
    return
  if sub notin cc.outp and sub notin cc.errp:
    say(false, name, "missing " & sub & " in: " & cc.outp & cc.errp)
    return
  say(true, name, "")

twin("pass_subset")
twin("pass_procs")
twin("pass_typecheck")
twin("pass_try")
twin("pass_retry")
twin("pass_deprecated")
twin("pass_timeout")
twin("pass_exec")
twin("pass_import")
twin("pass_tailcall")
delta("delta_errline")
runfail("runfail_contract_param", "expects int for 'x'")
runfail("runfail_contract_return", "must return int")
runfail("runfail_divzero", "division by zero")
runfail("runfail_timeout", "timed out after 150ms")
refusal("refuse_evolve", "evolve is not compilable in v1")
refusal("refuse_actor", "@actor is not compilable in v1")
refusal("refuse_forkexec", "@forkexec is not compilable in v1")
refusal("refuse_map", "map is not compilable in v1")
refusal("refuse_import_missing", "import: file not found")
refusal("refuse_import_circular", "circular import")
refusal("refuse_nested_import", "nested import is not compilable in v1")
refusal("refuse_nested_define", "nested define is not compilable in v1")
refusal("refuse_unknown_cmd", "unknown command: nosuchcmd_here")
refusal("refuse_unknown_method", "unknown method: nosuchm")
refusal("refuse_bad_arity", "writeln expects 1 args, got 0")
refusal("refuse_nonblock_body", "if body must be a block")
refusal("refuse_multistmt_cond", "must be a single expression")

echo "compile-suite: " & $fails & " failures"
quit(fails)
