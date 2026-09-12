import lexer, parser, eval, codegen, os, osproc, times

# Content hash for the -compile cache (local FNV-1a: deterministic,
# dependency-free; cryptographic strength is unnecessary here).
proc cacheKey(s: string): string =
  var h = 14695981039346656037'u64
  for ch in s:
    h = h xor uint64(ord(ch))
    h = h * 1099511628211'u64
  const digits = "0123456789abcdef"
  result = newString(16)
  for i in 0..<16:
    result[15 - i] = digits[int(h and 0xF'u64)]
    h = h shr 4

proc pruneCache(dir: string) =
  if not dirExists(dir):
    return
  let now = getTime()
  for kind, path in walkDir(dir):
    if kind == pcDir:
      try:
        if now - getLastModificationTime(path) > initDuration(days = 30):
          removeDir(path)
      except OSError:
        discard

when isMainModule:
  if paramCount() >= 1 and paramStr(1) == "--actor-run":
    if paramCount() < 3:
      echo "usage: kronyn --actor-run <jobfile> <resfile>"
      quit(2)
    try:
      runActorJobFile(paramStr(2), paramStr(3))
    except Exception as e:
      echo "Kronyn actor error: " & e.msg
      quit(1)
    quit(0)

  if paramCount() >= 1 and paramStr(1) == "--forkexec-run":
    if paramCount() < 3:
      echo "usage: kronyn --forkexec-run <jobfile> <resfile>"
      quit(2)
    try:
      runForkJobFile(paramStr(2), paramStr(3))
    except Exception as e:
      echo "Kronyn fork error: " & e.msg
      quit(1)
    quit(0)

  if paramCount() >= 1 and paramStr(1) == "-compile":
    const compileUsage = "usage: kronyn -compile <file.kr> [-o <out>] [--emit-c] [--no-cache]"
    if paramCount() < 2:
      echo compileUsage
      quit(1)
    let csrc = paramStr(2)
    if not fileExists(csrc):
      echo "error: file not found: " & csrc
      quit(1)
    var cout = ""
    var emitC = false
    var noCache = false
    var ci = 3
    while ci <= paramCount():
      if paramStr(ci) == "-o":
        if ci + 1 > paramCount():
          echo compileUsage
          quit(1)
        cout = paramStr(ci + 1)
        ci += 2
      elif paramStr(ci) == "--emit-c":
        emitC = true
        ci += 1
      elif paramStr(ci) == "--no-cache":
        noCache = true
        ci += 1
      else:
        echo compileUsage
        quit(1)
    if cout == "":
      when defined(windows):
        cout = changeFileExt(csrc, "exe")
      else:
        cout = changeFileExt(csrc, "")
    var ccode = ""
    try:
      ccode = compileProgram(readFile(csrc))
    except ValueError as e:
      echo "Compile error: " & e.msg
      quit(1)
    let appdir = getAppDir()
    var rtSrc = ""
    try:
      rtSrc = readFile(appdir / "kronyn_rt.c")
    except IOError, OSError:
      discard
    let ckey = cacheKey($CodegenVersion & ccode & rtSrc)
    let cdir = getTempDir() / "kronyn_cache" / ckey
    let cbin = cdir / addFileExt("bin", ExeExt)
    if not noCache and fileExists(cbin):
      copyFile(cbin, cout)
      if emitC:
        writeFile(cout & ".c", ccode)
      echo "cached " & csrc & " -> " & cout
      quit(0)
    let cfile = if emitC: cout & ".c"
                else: getTempDir() / "kronyn_cc_" & $getCurrentProcessId() & ".c"
    writeFile(cfile, ccode)
    var cc = findExe("gcc")
    if cc == "":
      cc = findExe("clang")
    if cc == "":
      cc = findExe("cc")
    if cc == "":
      echo "Compile error: no C compiler found (install gcc or clang)"
      quit(1)
    let (ccout, cccode) = execCmdEx("\"" & cc & "\" -O2 -fwrapv -I\"" & appdir &
      "\" \"" & cfile & "\" \"" & appdir / "kronyn_rt.c" &
      "\" -o \"" & cout & "\"")
    if cccode != 0:
      if ccout != "":
        echo ccout
      echo "Compile error: C compiler failed (exit " & $cccode & "); kept " & cfile
      quit(1)
    if not emitC:
      try: removeFile(cfile) except: discard
    if not noCache:
      try:
        createDir(cdir)
        copyFile(cout, cbin)
        writeFile(cdir / "bin.c", ccode)
        pruneCache(getTempDir() / "kronyn_cache")
      except OSError, IOError:
        discard
    echo "compiled " & csrc & " -> " & cout
    quit(0)

  var measure = false
  var scriptIdx = 1
  if paramCount() >= 1 and paramStr(1) == "-measure":
    measure = true
    scriptIdx = 2

  if paramCount() < scriptIdx:
    echo "usage: kronyn [-measure] <file.kr> [args...]"
    quit(1)

  let path = paramStr(scriptIdx)
  if not fileExists(path):
    echo "error: file for found: " & path
    quit(1)

  var argv: seq[string] = @[]
  if paramCount() >= scriptIdx + 1:
    for i in scriptIdx + 1..paramCount():
      argv.add(paramStr(i))
  let interp = newInterpreter(argv = argv, quiet = not measure)

  try:
    let src = readFile(path)
    discard interp.eval(parse(tokenize(src)))
  except ValueError as e:
    echo "Kronyn error: " & e.msg
    let tr = kronynTrace()
    if tr != "":
      echo tr
    quit(1)
if measure:
  echo "body cache hits: ", bodyCacheHits
  echo "body cache miss: ", bodyCacheMiss
  echo "evalStmt calls: ", callsEvalStmt
  echo "evalArg calls: ", callsEvalArg
  echo "evalSub calls: ", callsEvalSub
  when defined(kronynProfile):
    echo "evalStmt time: ", timeInEvalStmt, "s"
    echo "evalArg time: ", timeInEvalArg, "s"
    echo "evalSub time: ", timeInEvalSub, "s"  
