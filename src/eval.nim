import token, ast, lexer, parser, tables, strutils, os, osproc, times, locks, marshal, algorithm
# Refactor: sequtils dropped (R1/R6 removed the last mapIt/filterIt uses).

#---- Value: tagged variant, Tcl-style surface with string coercion ----
type
  ValueKind* = enum
    vkString, vkInt, vkList, vkSome, vkNone

  Value* = ref object
    case kind*: ValueKind
    of vkString: strVal*: string
    of vkInt: intVal*: int
    of vkList: listVal*: seq[Value]
    of vkSome: someVal*: Value
    of vkNone: discard

proc newStr*(s: string): Value = Value(kind: vkString, strVal: s)
proc newInt*(i: int): Value = Value(kind: vkInt, intVal: i)
proc newList*(items: seq[Value]): Value = Value(kind: vkList, listVal: items)
proc mkSome(v: Value): Value = Value(kind: vkSome, someVal: v)
proc mkNone(): Value = Value(kind: vkNone)

proc `$`*(v: Value): string =
  if v == nil: return ""
  case v.kind
  of vkString: result = v.strVal
  of vkInt: result = $v.intVal
  of vkList:
    # Refactor R1: explicit single-pass join (was mapIt+join). Same order,
    # single spaces, empty list -> "". Capacity estimate avoids regrowth.
    # (Explicit `result =` per branch: the multi-statement list branch
    # can't be a case-expression value.)
    if v.listVal.len == 0: return ""
    var total = 0
    for it in v.listVal:
      total += ($it).len + 1
    result = newStringOfCap(total)
    for i, it in v.listVal:
      if i > 0: result.add(' ')
      result.add($it)
  of vkSome:
    if v.someVal == nil: result = "" else: result = $v.someVal
  of vkNone: result = ""

proc truthy*(v: Value): bool =
  if v == nil: return false
  case v.kind
  of vkNone: false
  of vkSome: true
  of vkInt: v.intVal != 0
  of vkList: v.listVal.len > 0
  of vkString: v.strVal != "" and v.strVal != "0"

proc tryWordInt(s: string, outVal: var int): bool

proc isInt*(v: Value): bool =
  case v.kind
  of vkInt: true
  of vkString:
    var n = 0
    tryWordInt(v.strVal, n)
  else: false

proc asInt*(v: Value): int =
  case v.kind
  of vkInt: v.intVal
  else:
    # Refactor R2: exception-free fast path. Canonical ints never touch
    # parseInt's ValueError; fallback preserves tolerant behavior/messages.
    var n = 0
    if tryWordInt($v, n): n
    else: parseInt($v)

proc tryWordInt(s: string, outVal: var int): bool =
  if s.len == 0: return false
  var i = 0
  var neg = false
  if s[0] == '-': neg = true; i = 1
  elif s[0] == '+': i = 1
  if i >= s.len: return false
  var acc = 0
  while i < s.len:
    let c = s[i]
    if c < '0' or c > '9': return false
    acc = acc * 10 + (ord(c) - ord('0'))
    inc i
  outVal = if neg: -acc else: acc
  true

proc wordToValue*(s: string): Value =
  var n = 0
  if tryWordInt(s, n): newInt(n)
  else: newStr(s)

template profNow(): float =
  when defined(kronynProfile): cpuTime()
  else: 0.0

template profAcc(acc: var float, t0: float) =
  when defined(kronynProfile): acc += cpuTime() - t0

const
  ESSENTIALS_EMBEDDED = staticRead("./essentials.kr")

proc essentialsSource*(): string =
  let besideBin = getAppDir() / "essentials.kr"
  if fileExists(besideBin):
    return readFile(besideBin)
  if fileExists("essentials.kr"):
    return readFile("essentials.kr")
  ESSENTIALS_EMBEDDED

#------ @timeout: cooperative deadlines (wall clock, dynamic scope) ------
type
  TimeoutFrame* = object
    owner*: string
    line*: int
    ms*: int
    deadline*: float

var
  bodyCache {.threadvar.}: Table[string, Program]
  subCache {.threadvar.}: Table[string, Arg]
  timeInEvalStmt* {.threadvar.}: float
  timeInEvalArg* {.threadvar.}: float
  timeInEvalSub* {.threadvar.}: float
  callsEvalStmt* {.threadvar.}: int
  callsEvalArg* {.threadvar.}: int
  callsEvalSub* {.threadvar.}: int
  bodyCacheHits* {.threadvar.}: int
  bodyCacheMiss* {.threadvar.}: int
  deprecatedWarned {.threadvar.}: Table[string, bool]
  timeoutStack {.threadvar.}: seq[TimeoutFrame]
  callStack {.threadvar.}: seq[tuple[name: string, line: int]]
  lastTrace {.threadvar.}: seq[tuple[name: string, line: int]]

var emptyStore {.threadvar.}: Value

proc emptyVal(): Value {.inline.} =
  if emptyStore == nil:
    emptyStore = Value(kind: vkString, strVal: "")
  emptyStore

proc initThreadCaches() =
  bodyCache = initTable[string, Program]()
  subCache = initTable[string, Arg]()
  callStack = @[]
  deprecatedWarned = initTable[string, bool]()
  timeoutStack = @[]

template withFrame(nm: string, ln: int, body: untyped): untyped =
  callStack.add((nm, ln))
  try:
    body
  finally:
    let ex = getCurrentException()
    if ex != nil and lastTrace.len == 0 and not (ex of TailCallSignal):
      lastTrace = callStack
    discard callStack.pop()

proc formatStack(frames: seq[tuple[name: string, line: int]], header: string): string =
  if frames.len == 0: return ""
  var show = frames
  var omitted = 0
  if show.len > 20:
    omitted = show.len - 20
    show = show[0..4] & show[^15..^1]
  # Refactor R3: pre-size trace render (was &= growth from "").
  result = newStringOfCap(header.len + show.len * 32)
  result.add(header)
  var skipped = false
  for i, f in show:
    if omitted > 0 and not skipped and i == 5:
      result.add("\n  ... (" & $omitted & " frames omitted)")
      skipped = true
    result.add("\n  at " & f.name & " (line " & $f.line & ")")

proc kronynTrace*(): string =
  formatStack(lastTrace, "Traceback (kronyn, innermost last):")

proc workerTraceSuffix*(): string =
  formatStack(lastTrace, "  worker trace (innermost last):")

proc clearTrace*() =
  lastTrace = @[]

var stdoutLock: Lock
initLock(stdoutLock)

#------ @deprecated: warn-once per proc per process, stderr, call still runs ------
proc warnDeprecated(name: string, line: int, msg: string) =
  let text = if msg == "": name & " is deprecated"
             else: name & " is deprecated: " & msg
  withLock(stdoutLock):
    stderr.writeLine("Kronyn deprecated: " & name &
      " (line " & $line & "): " & text)

proc maybeWarnDeprecated(name: string, line: int, found: bool, msg: string) =
  if not found: return
  if name in deprecatedWarned: return
  deprecatedWarned[name] = true
  warnDeprecated(name, line, msg)

#------environment let'sssss goooo ----------------------

type
  CommandFn* = proc(env: Env, args: seq[Value]): Value
  SyscallFn* = proc(env: Env, args: seq[Value]): Value

  SyscallDef* = object
    fn*: SyscallFn
    minArgs*: int
    maxArgs*: int

  # @forkexec world record: every define is recorded as plain data so a
  # forked child can rebuild the full procedure world. Closures never cross
  # the boundary (same constraint as actor transport).
  ForkDef* = object
    name*: string
    params*: seq[string]
    ptypes*: seq[string]
    body*: string
    rtype*: string
    line*: int
    tailOpt*: bool
    wantCheck*: bool
    retryMax*: int

  Env* = ref object
    vars*: Table[string, Value]
    cmds*: Table[string, CommandFn]
    builtinArities*: Table[string, tuple[minA: int, maxA: int]]
    syscalls*: Table[string, Table[string, SyscallDef]]
    forkDefs*: Table[string, ForkDef]
    forkOrder*: seq[string]
    parent*: Env
    rootCache*: Env
    returning*: bool
    retVal*: Value
    breaking*: bool
    tailFn*: string
    tailArity*: int

proc newEnv*(parent: Env = nil, varsSize = 64): Env =
  # Refactor R5: varsSize hint — roots keep 64, call frames pass 8.
  result = Env(vars: initTable[string, Value](varsSize),
  cmds: initTable[string, CommandFn](),
  builtinArities: initTable[string, tuple[minA: int, maxA: int]](),
  syscalls: initTable[string, Table[string, SyscallDef]](),
  forkDefs: initTable[string, ForkDef](),
  forkOrder: @[],

  parent: parent,
  returning: false,
  retVal: emptyVal(),
  breaking: false,
  tailFn: "",
  tailArity: 0)
  result.rootCache = if parent == nil: result else: parent.rootCache

proc root*(env: Env): Env {.inline.} =
  env.rootCache

# Refactor R4: pooled call frames. Declared here (after the Env type);
# drained in newInterpreter alongside initThreadCaches so a fresh
# interpreter (incl. actor workers) never reuses a stale-root frame.
var envPool {.threadvar.}: seq[Env]

# Refactor R4: pooled call frames. Children only ever populate `vars`
# (cmds/syscalls/arities live on the root and are found via the parent
# chain), but all four tables are cleared defensively and flags reset.
# Values are GC refs — releasing a frame never frees a live Value held by
# the result/args. Pool cap keeps worst-case retention bounded.
const envPoolCap = 64

proc acquireCallEnv(root: Env): Env =
  if envPool.len > 0:
    result = envPool.pop()
    result.vars.clear()
    result.cmds.clear()
    result.builtinArities.clear()
    result.syscalls.clear()
    result.forkDefs.clear()
    result.forkOrder.setLen(0)
    result.parent = root
    result.rootCache = root
    result.returning = false
    result.retVal = emptyVal()
    result.breaking = false
    result.tailFn = ""
    result.tailArity = 0
  else:
    result = newEnv(root, 8)

proc releaseCallEnv(child: Env) =
  if envPool.len < envPoolCap:
    # Drop references but keep bucket storage for the next call.
    child.vars.clear()
    child.cmds.clear()
    child.builtinArities.clear()
    child.syscalls.clear()
    child.forkDefs.clear()
    child.forkOrder.setLen(0)
    child.parent = nil
    child.rootCache = nil
    child.returning = false
    child.breaking = false
    child.retVal = nil
    child.tailFn = ""
    child.tailArity = 0
    envPool.add(child)
  # else: over cap — drop and let the GC collect.

proc getVar*(env: Env, name: string): Value =
  if name in env.vars: return env.vars[name]
  if env.parent != nil: return env.parent.getVar(name)
  emptyVal()

proc hasVar*(env: Env, name: string): bool =
  if name in env.vars: return true
  if env.parent != nil: return env.parent.hasVar(name)
  false

proc setVar*(env: Env, name: string, val: Value) =
  env.vars[name] = val

proc getCmd*(env: Env, name: string): CommandFn =
  if name in env.cmds: return env.cmds[name]
  if env.parent != nil: return env.parent.getCmd(name)
  nil

proc registerCmd*(env: Env, name: string, fn: CommandFn) =
  env.cmds[name] = fn

const builtinAritySpecs = [
  ("writeln", 1, 1), ("write", 1, 1), ("input", 0, 0),
  ("if", 2, -1), ("readln", 0, 0), ("iter", 2, 2),
  ("toUpper", 1, 1), ("toLower", 1, 1), ("len", 1, 1),
  ("trim", 1, 1), ("ascii", 1, 1), ("char", 1, 1),
  ("int", 1, 1), ("str", 1, 1),
  ("typeof", 1, 1), ("isInt", 1, 1), ("isString", 1, 1), ("isList", 1, 1),
  ("slice", 3, 3), ("index", 2, 2), ("contains", 2, 2),
  ("replace", 3, 3), ("split", 2, 2), ("concat", 2, 2),
  ("loop", 1, 1), ("while", 2, 2), ("mod", 2, 2), ("exec", 1, 1),
  ("lines", 1, 1), ("filter", 2, 2), ("count", 1, 1),
  ("first", 1, 1), ("last", 1, 1),
  ("some", 1, 1), ("none", 0, 0), ("some?", 1, 1), ("none?", 1, 1),
  ("unwrap", 1, 1), ("unwrapOr", 2, 2), ("map", 2, 2), ("try", 1, 1)
]

proc registerBuiltinArities(env: Env) =
  for (n, lo, hi) in builtinAritySpecs:
    env.builtinArities[n] = (lo, hi)

type
  KronynError* = object of ValueError
    kind*: string
    line*: int

proc kerr*(kind: string, line: int, msg: string): ref KronynError =
  new(result)
  result.kind = kind
  result.line = line
  result.msg = if line >= 0: "line " & $line & ": " & msg else: msg

proc builtinArityFor(env: Env, name: string): tuple[found: bool, minA: int, maxA: int] =
  if name in env.cmds:
    if name in env.builtinArities:
      let t = env.builtinArities[name]
      return (true, t.minA, t.maxA)
    return (false, 0, 0)
  if env.parent != nil: return env.parent.builtinArityFor(name)
  (false, 0, 0)

proc checkArity(line: int, name: string, got, minA, maxA: int) =
  if got < minA or (maxA >= 0 and got > maxA):
    if maxA < 0:
      raise kerr("arity", line, name &
        " expects at least " & $minA & " args, got " & $got)
    elif minA == maxA:
      raise kerr("arity", line, name &
        " expects " & $minA & " args, got " & $got)
    else:
      raise kerr("arity", line, name &
        " expects " & $minA & ".." & $maxA & " args, got " & $got)

# Single enforcement point for cooperative timeouts. Every block
# evaluation (loop iterations, call bodies, branches) passes through
# evalBody, so one check here covers any code that can take time.
# Zero cost when no timeout is armed (one length check); wall clock
# (epochTime), never CPU time, so I/O waits count against the window.
proc checkTimeout() {.inline.} =
  if timeoutStack.len > 0:
    let f = timeoutStack[^1]
    if epochTime() > f.deadline:
      raise kerr("timeout", f.line, f.owner &
        " timed out after " & $f.ms & "ms")

proc registerSyscall*(env: Env, ns, meth: string, minA, maxA: int, fn: SyscallFn) =
  if ns notin env.syscalls:
    env.syscalls[ns] = initTable[string, SyscallDef]()
  env.syscalls[ns][meth] = SyscallDef(fn: fn, minArgs: minA, maxArgs: maxA)

proc getSyscallNs(env: Env, ns: string): Table[string, SyscallDef] =
  if ns in env.syscalls: return env.syscalls[ns]
  if env.parent != nil: return env.parent.getSyscallNs(ns)
  initTable[string, SyscallDef]()

#-------- option helpers (proper variant, no hidden byte markers) -----
proc isSome(v: Value): bool = v != nil and v.kind == vkSome
proc isNone(v: Value): bool = v == nil or v.kind == vkNone
proc unwrapVal(v: Value): Value =
  if v != nil and v.kind == vkSome and v.someVal != nil: v.someVal
  else: emptyVal()

#----declare first cause shit's ain't C -----------------------

proc eval*(env: Env, program: Program): Value
proc evalStmt*(env: Env, stmt: Stmt): Value
proc evalArg*(env: Env, arg: Arg): Value
proc evalArgChain(env: Env, arg: Arg): Value
proc evalSub*(env: Env, src: string): Value
proc evalBody*(env: Env, src: string): Value
proc callFn*(env: Env, params: seq[string], body: string, args: seq[Value]): Value
proc spawnActorCall*(name: string, params: seq[string], ptypes: seq[string],
                     body: string, rtype: string,
                     args: seq[Value], retryMax: int, line: int,
                     tailOpt: bool, timeoutMs: int = 0): Value
proc spawnForkCall*(caller: Env, name: string, args: seq[Value], line: int,
                    innerRetry: int, timeoutMs: int = 0): Value

#------- Return type shit?(Depricated, but I did create some cool shit)---------

type
  ReturnSignal* = ref object of CatchableError
    value*: Value

  GotoSignal* = ref object of CatchableError
    label*: string

  TailCallSignal* = ref object of CatchableError
    args*: seq[Value]

#------- Evaluate the Arg ---------------------------------

proc evalChainCall*(env: Env, receiver: Value, call: ChainCall): Value =
  var args = @[receiver]
  for a in call.args:
    args.add(env.evalArg(a))
  let fn = env.getCmd(call.name)
  if fn == nil:
    raise kerr("unknown-command", call.line, "unknown method: " & call.name)
  let (haveAr, lo, hi) = env.builtinArityFor(call.name)
  if haveAr: checkArity(call.line, call.name, args.len, lo, hi)

  fn(env, args)


proc callFn(env: Env, params: seq[string], body: string, args: seq[Value]): Value =
  let r = env.rootCache
  # Refactor R4: pooled frame (released on all exits; result/retVal are
  # GC refs that survive the release).
  let child = acquireCallEnv(r)
  try:
    for i, p in params:
      if i < args.len:
        child.setVar(p, args[i])
    result = child.evalBody(body)
    if r.returning:
      result = child.retVal
  finally:
    releaseCallEnv(child)

proc evalArg*(env: Env, arg: Arg): Value =
  let t {.used.} = profNow()
  inc callsEvalArg
  case arg.kind
    of argString: result = newStr(arg.str)
    of argWord: result = wordToValue(arg.word)
    of argVar: result = env.getVar(arg.name)
    of argTypedParam:
      raise kerr("type", -1,
        "type annotation on '" & arg.pname & "' is only allowed in define signatures")
    of argSub: result = env.evalSub(arg.sub)
    of argBlock: result = newStr(arg.body)

    of argChain:
      result = env.evalArgChain(arg)

    of argInfix:
      let l = env.evalArg(arg.left)
      let r = env.evalArg(arg.right)
      case arg.op
        of "+":
          if l.isInt() and r.isInt(): result = newInt(l.asInt() + r.asInt())
          else: result = newStr($l & $r)
        of "-":
          if not l.isInt():
                               raise kerr("type", arg.line, "expected integer, got '" & $l & "'")
          elif not r.isInt():
                               raise kerr("type", arg.line, "expected integer, got '" & $r & "'")
          else: result = newInt(l.asInt() - r.asInt())
        of "*":
          if not l.isInt():
                               raise kerr("type", arg.line, "expected integer, got '" & $l & "'")
          elif not r.isInt():
                               raise kerr("type", arg.line, "expected integer, got '" & $r & "'")
          else: result = newInt(l.asInt() * r.asInt())
        of "/":
          if not l.isInt():
                               raise kerr("type", arg.line, "expected integer, got '" & $l & "'")
          elif not r.isInt():
                               raise kerr("type", arg.line, "expected integer, got '" & $r & "'")
          elif r.asInt() == 0:
            raise kerr("division", -1, "division by zero")
          else: result = newInt(l.asInt() div r.asInt())
        of "..": result = newStr($l & $r)
        of "==":
          if l.kind == vkInt and r.kind == vkInt:
            result = newInt(if l.intVal == r.intVal: 1 else: 0)
          elif l.kind == vkString and r.kind == vkString:
            result = newInt(if l.strVal == r.strVal: 1 else: 0)
          else:
            result = newInt(if $l == $r: 1 else: 0)
        of "!=":
          if l.kind == vkInt and r.kind == vkInt:
            result = newInt(if l.intVal != r.intVal: 1 else: 0)
          elif l.kind == vkString and r.kind == vkString:
            result = newInt(if l.strVal != r.strVal: 1 else: 0)
          else:
            result = newInt(if $l != $r: 1 else: 0)
        of "<":
          if l.asInt() < r.asInt(): result = newInt(1) else: result = newInt(0)
        of ">":
          if l.asInt() > r.asInt(): result = newInt(1) else: result = newInt(0)
        of "<=":
          if l.asInt() <= r.asInt(): result = newInt(1) else: result = newInt(0)
        of ">=":
          if l.asInt() >= r.asInt(): result = newInt(1) else: result = newInt(0)
        of "&&":
          if l.truthy() and r.truthy(): result = newInt(1) else: result = newInt(0)
        of "||":
          if l.truthy() or r.truthy(): result = newInt(1) else: result = newInt(0)
        of "!":
          if r.truthy(): result = newInt(0) else: result = newInt(1)
        else: result = emptyVal()

  profAcc(timeInEvalArg, t)

#-----substitute and evaluation stuff ----------------------------

proc evalSub*(env: Env, src: string): Value =
  let t {.used.} = profNow()
  inc callsEvalSub
  if src in subCache:
    result = env.evalArg(subCache[src])
    profAcc(timeInEvalSub, t)
    return result

  let tokens = tokenize(src)
  var p = newParser(tokens)
  p.skipNewlines()
  if p.isAtEnd(): return emptyVal()

  let second = if p.pos + 1 < p.tokens.len: p.tokens[p.pos + 1]
               else: Token(kind: tkEof)

  if second.kind in {tkPlus, tkMinus, tkStar, tkSlash,
                      tkEqEq, tkBangEq, tkLt, tkGt,
                      tkLtEq, tkGtEq, tkAnd, tkOr, tkDotDot}:
    let arg = p.parseArg()
    subCache[src] = arg
    result = env.evalArg(arg)
    profAcc(timeInEvalSub, t)
    return result

  if second.kind == tkDot:
    let arg = p.parseArg()
    subCache[src] = arg
    result = env.evalArg(arg)
    profAcc(timeInEvalSub, t)
    return result

  let stmt = p.parseStmt()
  result = env.evalStmt(stmt)

  profAcc(timeInEvalSub, t)

# Note that we cache expressions (argInfix, argChain) but not statements. Statements have side effects and their structure depends on context...

proc evalBody*(env: Env, src: string): Value =
  checkTimeout()
  if src notin bodyCache:
    inc bodyCacheMiss
    bodyCache[src] = parse(tokenize(src))
  else: inc bodyCacheHits
  env.eval(bodyCache[src])


#---------statement evaluation -------------------------------

proc retryAttempts(env: Env, stmt: Stmt): int =
  result = 1
  for ann in stmt.annotations:
    if ann.name == "retry":
      if ann.args.len < 1:
        raise kerr("annotation", stmt.line, "@retry requires a count, e.g. @retry(3)")
      let nStr = ($(env.evalArg(ann.args[0]))).strip()
      try:
        result = parseInt(nStr)
      except:
        raise kerr("annotation", stmt.line, "@retry count must be integer, got '" & nStr & "'")
      if result < 1: result = 1

proc parseRetryCount(env: Env, ann: ChainCall, stmt: Stmt): int =
  if ann.args.len < 1:
    raise kerr("annotation", stmt.line, "@retry requires a count, e.g. @retry(3)")
  let nStr = ($(env.evalArg(ann.args[0]))).strip()
  try:
    result = parseInt(nStr)
  except:
    raise kerr("annotation", stmt.line, "@retry count must be integer, got '" & nStr & "'")
  if result < 1: result = 1

proc validateStmtAnnotations(stmt: Stmt) =
  for ann in stmt.annotations:
    if ann.name == "actor":
      raise kerr("annotation", stmt.line, "@actor is only valid on define")
    elif ann.name == "forkexec":
      raise kerr("annotation", stmt.line, "@forkexec is only valid on define")
    elif ann.name == "typecheck":
      raise kerr("annotation", stmt.line, "@typecheck is only valid on define")
    elif ann.name == "tailcallopt":
      raise kerr("annotation", stmt.line, "@tailcallopt is only valid on define")
    elif ann.name == "deprecated":
      raise kerr("annotation", stmt.line, "@deprecated is only valid on define")
    elif ann.name == "timeout":
      raise kerr("annotation", stmt.line, "@timeout is only valid on define")
    elif ann.name != "retry":
      raise kerr("annotation", stmt.line, "unknown annotation: @" & ann.name)

proc splitSpawnAnnotations(env: Env, stmt: Stmt): tuple[hasActor, hasFork: bool, outerRetry, innerRetry: int] =
  result = (false, false, 1, 1)
  var seenActor = false
  var seenFork = false
  for ann in stmt.annotations:
    if ann.name == "actor":
      if ann.args.len > 0:
        raise kerr("annotation", stmt.line, "@actor takes no arguments")
      if seenActor:
        raise kerr("annotation", stmt.line, "duplicate @actor")
      if seenFork:
        raise kerr("annotation", stmt.line, "@actor and @forkexec are mutually exclusive")
      seenActor = true
    elif ann.name == "forkexec":
      if ann.args.len > 0:
        raise kerr("annotation", stmt.line, "@forkexec takes no arguments")
      if seenFork:
        raise kerr("annotation", stmt.line, "duplicate @forkexec")
      if seenActor:
        raise kerr("annotation", stmt.line, "@actor and @forkexec are mutually exclusive")
      seenFork = true
    elif ann.name == "retry":
      let n = parseRetryCount(env, ann, stmt)
      if seenActor or seenFork: result.innerRetry = n
      else: result.outerRetry = n
    elif ann.name == "typecheck":
      if ann.args.len > 0:
        raise kerr("annotation", stmt.line, "@typecheck takes no arguments; declare types in the signature")
      discard
    elif ann.name == "tailcallopt":
      if ann.args.len > 0:
        raise kerr("annotation", stmt.line, "@tailcallopt takes no arguments")
      discard
    elif ann.name == "deprecated":
      if ann.args.len > 1:
        raise kerr("annotation", stmt.line, "@deprecated takes at most one message argument")
      discard
    elif ann.name == "timeout":
      if ann.args.len != 1:
        raise kerr("annotation", stmt.line, "@timeout requires milliseconds, e.g. @timeout(500)")
      discard
    else:
      raise kerr("annotation", stmt.line, "unknown annotation: @" & ann.name)
  result.hasActor = seenActor
  result.hasFork = seenFork

const TypeNames = ["int", "string", "list", "some", "none", "any"]

proc kindName*(v: Value): string =
  if v == nil: "none"
  else:
    case v.kind
    of vkInt: "int"
    of vkString: "string"
    of vkList: "list"
    of vkSome: "some"
    of vkNone: "none"

proc checkKindMatches(expected: string, v: Value): bool =
  if expected == "any": true
  else: kindName(v) == expected

proc hasTypecheck(stmt: Stmt): bool =
  for ann in stmt.annotations:
    if ann.name == "typecheck": return true
  false

proc checkCallParams(name: string, line: int, captured: seq[string],
                     ptypes: seq[string], args: seq[Value]) =
  for i in 0..<captured.len:
    let t = ptypes[i]
    if t == "" or t == "any": continue
    if not checkKindMatches(t, args[i]):
      raise kerr("type", line, name &
        " expects " & t & " for '" & captured[i] & "', got " & kindName(args[i]))

proc checkReturnKind(name: string, line: int, retType: string, v: Value) =
  if retType == "" or retType == "any": return
  if not checkKindMatches(retType, v):
    raise kerr("type", line, name &
      " must return " & retType & ", got " & kindName(v))

proc hasTailOpt(stmt: Stmt): bool =
  for ann in stmt.annotations:
    if ann.name == "tailcallopt":
      if ann.args.len > 0:
        raise kerr("annotation", stmt.line, "@tailcallopt takes no arguments")
      return true
  false

proc parseDeprecated(env: Env, stmt: Stmt): tuple[found: bool, msg: string] =
  result = (false, "")
  var seen = false
  for ann in stmt.annotations:
    if ann.name == "deprecated":
      if seen:
        raise kerr("annotation", stmt.line, "duplicate @deprecated")
      seen = true
      if ann.args.len > 1:
        raise kerr("annotation", stmt.line, "@deprecated takes at most one message argument")
      if ann.args.len == 1:
        result.msg = $(env.evalArg(ann.args[0]))
  result.found = seen

proc parseTimeoutMs(env: Env, stmt: Stmt): int =
  result = 0
  var seen = false
  for ann in stmt.annotations:
    if ann.name == "timeout":
      if seen:
        raise kerr("annotation", stmt.line, "duplicate @timeout")
      seen = true
      if ann.args.len != 1:
        raise kerr("annotation", stmt.line, "@timeout requires milliseconds, e.g. @timeout(500)")
      let nStr = ($(env.evalArg(ann.args[0]))).strip()
      try:
        result = parseInt(nStr)
      except:
        raise kerr("annotation", stmt.line, "@timeout window must be integer milliseconds, got '" & nStr & "'")
      if result < 1:
        raise kerr("annotation", stmt.line, "@timeout window must be positive milliseconds, got " & $result)

proc matchTailSelfCall(env: Env, arg: Arg, name: string, arity: int,
                       line: int): tuple[isTail: bool, newArgs: seq[Value]] =
  result = (false, @[])
  if arg.kind == argSub:
    let tokens = tokenize(arg.sub)
    var p = newParser(tokens)
    p.skipNewlines()
    if p.isAtEnd(): return result
    let stmt = p.parseStmt()
    p.skipNewlines()
    if not p.isAtEnd(): return result
    if stmt.cmd != name: return result
    if stmt.annotations.len > 0: return result
    var newArgs: seq[Value] = @[]
    for a in stmt.args:
      newArgs.add(env.evalArg(a))
    if newArgs.len != arity:
      raise kerr("arity", line, name &
        " expects " & $arity & " args, got " & $newArgs.len)
    return (true, newArgs)
  elif arg.kind == argChain:
    if arg.calls.len == 0: return result
    if arg.calls[^1].name != name: return result
    var newArgs: seq[Value] = @[]
    if arg.calls.len == 1:
      newArgs.add(env.evalArg(arg.receiver))
    else:
      var prefix: seq[ChainCall] = @[]
      for i in 0..<arg.calls.len - 1:
        prefix.add(arg.calls[i])
      newArgs.add(env.evalArgChain(chainArg(arg.receiver, prefix)))
    for a in arg.calls[^1].args:
      newArgs.add(env.evalArg(a))
    if newArgs.len != arity:
      raise kerr("arity", line, name &
        " expects " & $arity & " args, got " & $newArgs.len)
    return (true, newArgs)

proc trampolineCall(env: Env, name: string, captured: seq[string],
                    capturedTypes: seq[string], body: string, line: int,
                    wantCheck: bool, args: seq[Value]): Value =
  var cur = args
  # Refactor R4: one pooled frame for the whole tail chain (was one fresh
  # Env per call). Tail-signal iterations keep it; every other exit
  # releases it. Per-iteration clearing preserves fresh-frame semantics.
  var child = acquireCallEnv(env.rootCache)
  child.tailFn = name
  child.tailArity = captured.len
  try:
    while true:
      child.vars.clear()
      child.returning = false
      child.breaking = false
      child.retVal = emptyVal()
      for i, p in captured:
        if i < cur.len: child.setVar(p, cur[i])
      if wantCheck: checkCallParams(name, line, captured, capturedTypes, cur)
      try:
        return child.evalBody(body)
      except TailCallSignal as tc:
        cur = tc.args
  finally:
    # Return-signal, value result, and error exits all release here.
    # TailCallSignal never reaches this finally: it is caught by the inner
    # except above and loops. If a future change lets it escape, the frame
    # is still released exactly once here.
    releaseCallEnv(child)

proc invokeDirect(env: Env, name: string, captured: seq[string],
                  capturedTypes: seq[string], body: string, line: int,
                  wantCheck, tailOpt: bool, args: seq[Value]): Value =
  if tailOpt:
    trampolineCall(env, name, captured, capturedTypes, body, line, wantCheck, args)
  else:
    callFn(env, captured, body, args)

proc evalStmt*(env: Env, stmt: Stmt): Value =
  let t {.used.} = profNow()
  inc callsEvalStmt
  let r {.used.} = env.rootCache
  case stmt.cmd
  # The sacred intents MORRIS declares: SET, RETURN, EVOLVE, DEFINE, and also, new ones like SYSCALL and IMPORT
    of "__expr":
      result = env.evalArg(stmt.args[0])
    of "return":
      if stmt.args.len > 0 and env.tailFn != "":
        let (isTail, newArgs) = matchTailSelfCall(env, stmt.args[0],
          env.tailFn, env.tailArity, stmt.line)
        if isTail:
          raise TailCallSignal(args: newArgs)
      let val = if stmt.args.len > 0: env.evalArg(stmt.args[0]) else: emptyVal()
      env.returning = true
      env.retVal = val
      return val

    of "set":
      if stmt.args.len < 2:
        raise kerr("arity", stmt.line, "set requires 2 arguments")
      let val = env.evalArg(stmt.args[1])
      env.setVar(stmt.args[0].word, val)
      result = val

    of "evolve":
      if stmt.args.len < 1:
        raise kerr("arity", stmt.line, "evolve requires a string argument")
      let code = $(env.evalArg(stmt.args[0]))
      result = env.evalSub(code)

    of "define":
      if stmt.args.len < 3:
        raise kerr("arity", stmt.line, "define requires name, signature, and body")
      let name = stmt.args[0].word
      let defArg = stmt.args[1]
      let bodyArg = stmt.args[2]
      if bodyArg.kind != argBlock:
        raise kerr("type", stmt.line, "define body must be a block {...}")

      var params: seq[string]
      var ptypes: seq[string]
      if defArg.kind == argChain and defArg.calls.len > 0:
        for a in defArg.calls[0].args:
          case a.kind
          of argWord: params.add(a.word); ptypes.add("")
          of argVar: params.add(a.name); ptypes.add("")
          of argTypedParam: params.add(a.pname); ptypes.add(a.ptype)
          else: discard
      var retType = ""
      if defArg.kind == argChain and defArg.calls.len > 0:
        retType = defArg.calls[0].retType

      let body = bodyArg.body
      let captured = params
      let capturedTypes = ptypes
      let capturedRet = retType
      let line = stmt.line
      let wantCheck = hasTypecheck(stmt)
      if wantCheck:
        for i in 0..<captured.len:
          if capturedTypes[i] == "":
            raise kerr("type", line, "@typecheck requires a declared type for parameter '" &
              captured[i] & "' of " & name)
          if capturedTypes[i] notin TypeNames:
            raise kerr("type", line, "@typecheck unknown type '" &
              capturedTypes[i] & "' for parameter '" & captured[i] & "' of " & name)
        if capturedRet != "" and capturedRet notin TypeNames:
          raise kerr("type", line, "@typecheck unknown return type '" &
            capturedRet & "' of " & name)
      let (hasActor, hasFork, outerRetry, innerRetry) = splitSpawnAnnotations(env, stmt)
      let tailOpt = hasTailOpt(stmt)
      let (depFound, depMsg) = parseDeprecated(env, stmt)
      let timeoutMs = parseTimeoutMs(env, stmt)
      # forkexec world registry: every define is recorded so a forked child
      # can rebuild the full procedure world (actor children only ever need
      # the single procedure; fork children need them all).
      if name notin r.forkDefs:
        r.forkOrder.add(name)
      r.forkDefs[name] = ForkDef(name: name, params: captured,
        ptypes: capturedTypes, body: body, rtype: capturedRet, line: line,
        tailOpt: tailOpt, wantCheck: wantCheck, retryMax: outerRetry)
      r.builtinArities.del(name)
      deprecatedWarned.del(name)
      if not hasActor and not hasFork:
        let maxAttempts = outerRetry
        r.registerCmd(name, proc(env: Env, args: seq[Value]): Value =
          if args.len < captured.len: raise kerr("arity", line, name & " expects " & $captured.len & " args, got " & $args.len)
          if wantCheck: checkCallParams(name, line, captured, capturedTypes, args)
          maybeWarnDeprecated(name, line, depFound, depMsg)
          withFrame(name, line):
            var res: Value = nil
            for attempt in 1..maxAttempts:
              try:
                if timeoutMs > 0:
                  var dl = epochTime() + timeoutMs.float / 1000.0
                  if timeoutStack.len > 0 and timeoutStack[^1].deadline < dl:
                    dl = timeoutStack[^1].deadline
                  timeoutStack.add(TimeoutFrame(owner: name, line: line, ms: timeoutMs, deadline: dl))
                try:
                  res = invokeDirect(env, name, captured, capturedTypes, body, line, wantCheck, tailOpt, args)
                finally:
                  if timeoutMs > 0:
                    discard timeoutStack.pop()
                break
              except ValueError:
                if attempt == maxAttempts: raise
                clearTrace()
            if wantCheck: checkReturnKind(name, line, capturedRet, res)
            res)
      elif hasActor:
        r.registerCmd(name, proc(env: Env, args: seq[Value]): Value =
          if args.len < captured.len: raise kerr("arity", line, name & " expects " & $captured.len & " args, got " & $args.len)
          if wantCheck: checkCallParams(name, line, captured, capturedTypes, args)
          maybeWarnDeprecated(name, line, depFound, depMsg)
          withFrame(name, line):
            var res: Value = nil
            for attempt in 1..outerRetry:
              try:
                res = spawnActorCall(name, captured, capturedTypes, body, capturedRet, args, innerRetry, line, tailOpt, timeoutMs)
                break
              except ValueError:
                if attempt == outerRetry: raise
                clearTrace()
            if wantCheck: checkReturnKind(name, line, capturedRet, res)
            res)
      else:
        # @forkexec: same transport shape as @actor, but the child inherits
        # the full world (all defines + root globals at fork time) instead
        # of a closed world. The result is the only channel back.
        r.registerCmd(name, proc(env: Env, args: seq[Value]): Value =
          if args.len < captured.len: raise kerr("arity", line, name & " expects " & $captured.len & " args, got " & $args.len)
          if wantCheck: checkCallParams(name, line, captured, capturedTypes, args)
          maybeWarnDeprecated(name, line, depFound, depMsg)
          withFrame(name, line):
            var res: Value = nil
            for attempt in 1..outerRetry:
              try:
                res = spawnForkCall(env, name, args, line, innerRetry, timeoutMs)
                break
              except ValueError:
                if attempt == outerRetry: raise
                clearTrace()
            if wantCheck: checkReturnKind(name, line, capturedRet, res)
            res)
      return emptyVal()

    of "break":
      env.breaking = true
      return emptyVal()

    of "syscall":
      if stmt.args.len < 1:
        raise kerr("arity", stmt.line, "syscall requires a namespace.method argument")
      let callArg = stmt.args[0]
      if callArg.kind != argChain:
        raise kerr("type", stmt.line, "syscall expects namespace.method")

      let ns = $(env.evalArg(callArg.receiver))
      let meth = callArg.calls[0].name
      let nsTab = env.getSyscallNs(ns)
      if nsTab.len == 0:
        raise kerr("unknown-command", stmt.line, "unknown syscall namespace: " & ns)
      if meth notin nsTab:
        raise kerr("unknown-command", stmt.line, "unknown " & ns & " syscall: " & meth)
      let def = nsTab[meth]

      var args: seq[Value]
      for a in stmt.args[1..^1]:
        args.add(env.evalArg(a))
      if args.len < def.minArgs or (def.maxArgs >= 0 and args.len > def.maxArgs):
        if def.minArgs == def.maxArgs:
          raise kerr("arity", stmt.line, "syscall " & ns & "." & meth &
            " expects " & $def.minArgs & " args, got " & $args.len)
        else:
          raise kerr("arity", stmt.line, "syscall " & ns & "." & meth &
            " expects " & $def.minArgs & ".." & $def.maxArgs & " args, got " & $args.len)
      return def.fn(env, args)

    of "import":
      if stmt.args.len < 1:
        raise kerr("arity", stmt.line, "import requires a path argument")
      let path = $(env.evalArg(stmt.args[0]))
      if not fileExists(path):
        raise kerr("io", stmt.line, "import: file not found: " & path)
      let src = readFile(path)
      let tokens = tokenize(src)
      let program = parse(tokens)
      result = env.eval(program)
    else:
      var args: seq[Value]
      for a in stmt.args:
        args.add(env.evalArg(a))
      let fn = env.getCmd(stmt.cmd)
      if fn == nil:
        raise kerr("unknown-command", stmt.line, "unknown command: " & stmt.cmd)
      let (haveAr, lo, hi) = env.builtinArityFor(stmt.cmd)
      if haveAr: checkArity(stmt.line, stmt.cmd, args.len, lo, hi)
      result = fn(env, args)
      profAcc(timeInEvalStmt, t)
      return result

  profAcc(timeInEvalStmt, t)

proc evalArgChain(env: Env, arg: Arg): Value =
  if arg.receiver.kind == argWord and arg.receiver.word == "" and arg.calls.len > 0:
    let first = arg.calls[0]
    var cargs: seq[Value] = @[]
    for a in first.args:
      cargs.add(env.evalArg(a))
    let fn = env.getCmd(first.name)
    if fn == nil:
      raise kerr("unknown-command", first.line, "unknown command: " & first.name)
    let (haveAr, lo, hi) = env.builtinArityFor(first.name)
    if haveAr: checkArity(first.line, first.name, cargs.len, lo, hi)
    var val = fn(env, cargs)
    for i in 1..<arg.calls.len:
      val = env.evalChainCall(val, arg.calls[i])
    return val
  var val = env.evalArg(arg.receiver)
  for call in arg.calls:
    val = env.evalChainCall(val, call)
  val


proc eval*(env: Env, program: Program): Value =
  for stmt in program:
    if stmt.cmd == "define" or stmt.annotations.len == 0:
      result = env.evalStmt(stmt)
    else:
      validateStmtAnnotations(stmt)
      let maxAttempts = env.retryAttempts(stmt)
      var attempt = 0
      while true:
        inc attempt
        try:
          result = env.evalStmt(stmt)
          break
        except ValueError:
          if attempt >= maxAttempts: raise
          clearTrace()
    if env.returning: break
    if env.breaking: break


#------ syscall implementations (registered by namespace below) -----

proc readInputLine(): string =
  try:
    readLine(stdin)
  except EOFError:
    raise kerr("io", -1, "end of input")

proc sysIoOutputln(env: Env, args: seq[Value]): Value =
  withLock(stdoutLock):
    echo $args[0]
  emptyVal()

proc sysIoOutput(env: Env, args: seq[Value]): Value =
  withLock(stdoutLock):
    write(stdout, $args[0])
    flushFile(stdout)
  emptyVal()

proc sysIoInput(env: Env, args: seq[Value]): Value =
  newStr(readInputLine())

proc sysFsRead(env: Env, args: seq[Value]): Value =
  try:
    if not fileExists($args[0]): return mkNone()
    mkSome(newStr(readFile($args[0])))
  except IOError, OSError:
    mkNone()

proc sysFsWrite(env: Env, args: seq[Value]): Value =
  try:
    writeFile($args[0], $args[1])
    emptyVal()
  except OSError as e:
    raise kerr("io", -1, "fs.write failed: " & e.msg)
  except IOError as e:
    raise kerr("io", -1, "fs.write failed: " & e.msg)

proc sysFsExists(env: Env, args: seq[Value]): Value =
  newInt(if fileExists($args[0]): 1 else: 0)

proc sysFsAppend(env: Env, args: seq[Value]): Value =
  try:
    let f = open($args[0], fmAppend)
    f.write($args[1])
    f.close()
    emptyVal()
  except OSError as e:
    raise kerr("io", -1, "fs.append failed: " & e.msg)
  except IOError as e:
    raise kerr("io", -1, "fs.append failed: " & e.msg)

proc sysFsRemove(env: Env, args: seq[Value]): Value =
  if not fileExists($args[0]): return mkNone()
  try:
    removeFile($args[0])
    emptyVal()
  except OSError as e:
    raise kerr("io", -1, "fs.remove failed: " & e.msg)

proc sysFsList(env: Env, args: seq[Value]): Value =
  let dir = $args[0]
  if not dirExists(dir): return mkNone()
  try:
    # Refactor R7: project to strings once, sort plain strings, rebuild.
    # Was sort(Value) with a `$`-per-comparison closure: O(n log n)
    # coercions + closure traffic for the same byte order.
    var strs: seq[string] = @[]
    for kind, path in walkDir(dir):
      strs.add(lastPathPart(path))
    strs.sort()
    var names = newSeqOfCap[Value](strs.len)
    for s in strs: names.add(newStr(s))
    newList(names)
  except OSError:
    mkNone()

proc sysProcExit(env: Env, args: seq[Value]): Value =
  let code = if args.len > 0: parseInt($args[0]) else: 0
  quit(code)

proc sysProcArgs(env: Env, args: seq[Value]): Value =
  let r = env.rootCache
  if r.hasVar("argv"): r.getVar("argv")
  else: newList(@[])

proc registerSyscalls*(env: Env) =
  env.registerSyscall("io", "outputln", 1, 1, sysIoOutputln)
  env.registerSyscall("io", "output", 1, 1, sysIoOutput)
  env.registerSyscall("io", "input", 0, 0, sysIoInput)
  env.registerSyscall("fs", "read", 1, 1, sysFsRead)
  env.registerSyscall("fs", "write", 2, 2, sysFsWrite)
  env.registerSyscall("fs", "exists", 1, 1, sysFsExists)
  env.registerSyscall("fs", "append", 2, 2, sysFsAppend)
  env.registerSyscall("fs", "remove", 1, 1, sysFsRemove)
  env.registerSyscall("fs", "list", 1, 1, sysFsList)
  env.registerSyscall("proc", "exit", 0, 1, sysProcExit)
  env.registerSyscall("proc", "args", 0, 0, sysProcArgs)

#------ some builtin stuff-----------------------------------

proc initKernel*(env: Env) =
  env.registerSyscalls()
  env.registerBuiltinArities()
  env.registerCmd("writeln", proc(env: Env, args: seq[Value]): Value =
    withLock(stdoutLock):
      echo $args[0]
    result = emptyVal())
  env.registerCmd("write", proc(env: Env, args: seq[Value]): Value =
    withLock(stdoutLock):
      write(stdout, $args[0])
    emptyVal())
  env.registerCmd("input", proc(env: Env, args: seq[Value]): Value =
    newStr(readInputLine()))

  env.registerCmd("if", proc(env: Env, arg: seq[Value]): Value =
    if arg[0].truthy():
      return env.evalBody($arg[1])
    if arg.len == 3 and $arg[2] != "elif" and $arg[2] != "else":
      return env.evalBody($arg[2])
    var i = 2
    while i < arg.len:
      if $arg[i] == "elif":
        if arg[i+1].truthy():
          return env.evalBody($arg[i+2])
        i += 3
      elif $arg[i] == "else":
        return env.evalBody($arg[i+1])
      else:
        inc i
    emptyVal())

  env.registerCmd("readln", proc(env: Env, args: seq[Value]): Value =
                                newStr(readInputLine()))

  env.registerCmd("iter", proc(env: Env, args: seq[Value]): Value =
    let cond = $args[0]
    let body = $args[1]
    while env.evalSub(cond).truthy():
      result = env.evalBody(body)
      if env.returning: break
    return emptyVal())


  # Some string ops cause...You know...everything's a string :)

  env.registerCmd("toUpper", proc(env: Env, args: seq[Value]): Value =
    newStr(($(args[0])).toUpper()))

  env.registerCmd("toLower", proc(env: Env, args: seq[Value]): Value =
    newStr(($(args[0])).toLower()))

  env.registerCmd("len", proc(env: Env, args: seq[Value]): Value =
    let a = args[0]
    if a.kind == vkList: newInt(a.listVal.len)
    else: newInt(($(a)).len))

  env.registerCmd("trim", proc(env: Env, args: seq[Value]): Value =
    newStr(($(args[0])).strip()))

  env.registerCmd("ascii", proc(env: Env, args: seq[Value]): Value =
    let s = $args[0]
    if s.len == 0: return newInt(0)
    newInt(ord(s[0])))

  env.registerCmd("char", proc(env: Env, args: seq[Value]): Value =
    let code = parseInt($args[0])
    if code < 0 or code > 255:
      raise kerr("bounds", -1, "char code out of range: " & $code)
    newStr($chr(code)))

  env.registerCmd("int", proc(env: Env, args: seq[Value]): Value =
    newInt(parseInt($args[0])))

  env.registerCmd("str", proc(env: Env, args: seq[Value]): Value =
    newStr($args[0]))

  env.registerCmd("typeof", proc(env: Env, args: seq[Value]): Value =
    newStr(kindName(args[0])))

  env.registerCmd("isInt", proc(env: Env, args: seq[Value]): Value =
    newInt(if args[0].kind == vkInt: 1 else: 0))

  env.registerCmd("isString", proc(env: Env, args: seq[Value]): Value =
    newInt(if args[0].kind == vkString: 1 else: 0))

  env.registerCmd("isList", proc(env: Env, args: seq[Value]): Value =
    newInt(if args[0].kind == vkList: 1 else: 0))

  env.registerCmd("slice", proc(env: Env, args: seq[Value]): Value =
    let s = parseInt($args[1])
    let e = parseInt($args[2])
    let src = $args[0]
    if s < 0 or e > src.len or s > e:
      raise kerr("bounds", -1, "slice out of bounds")
    newStr(src[s..e-1]))

  env.registerCmd("index", proc(env: Env, args: seq[Value]): Value =
    let idx = parseInt($args[1])
    let src = $args[0]
    if idx < 0 or idx >= src.len:
      raise kerr("bounds", -1, "index out of bounds")
    newStr($src[idx]))

  env.registerCmd("contains", proc(env: Env, args: seq[Value]): Value =
    if $args[1] in $args[0]: newStr("true") else: newStr("false"))

  env.registerCmd("replace", proc(env: Env, args: seq[Value]): Value =
    newStr(($(args[0])).replace($args[1], $args[2])))

  env.registerCmd("split", proc(env: Env, args: seq[Value]): Value =
    # Refactor R6: explicit loop (was split(...).mapIt(newStr(it))).
    let parts = ($(args[0])).split($args[1])
    var items = newSeqOfCap[Value](parts.len)
    for p in parts: items.add(newStr(p))
    newList(items))

  env.registerCmd("concat", proc(env: Env, args: seq[Value]): Value =
    newStr($args[0] & $args[1]))

  env.registerCmd("loop", proc(env: Env, args: seq[Value]): Value =
    let body = $args[0]
    while true:
      result = env.evalBody(body)
      if env.breaking:
        env.breaking = false
        break
      if env.returning: break
    return emptyVal())

  env.registerCmd("while", proc(env: Env, args: seq[Value]): Value =
    let cond = $args[0]
    let body = $args[1]
    while env.evalSub(cond).truthy():
      result = env.evalBody(body)
      if env.breaking:
        env.breaking = false
        break
      if env.returning: break
    return emptyVal())
  env.registerCmd("mod", proc(env: Env, args: seq[Value]): Value =
    let m = parseInt($args[0])
    let n = parseInt($args[1])
    if n == 0:
      raise kerr("division", -1, "division by zero")
    newInt(m mod n))

  env.registerCmd("exec", proc(env: Env, args: seq[Value]): Value =
    try:
      when defined(windows):
        let (output, _) = execCmdEx("cmd /c " & $args[0])
      else:
        let (output, _) = execCmdEx("/bin/sh -c " & $args[0])
      newStr(output.strip())
    except OSError as e:
      raise kerr("io", -1, "exec failed: " & e.msg))

  env.registerCmd("lines", proc(env: Env, args: seq[Value]): Value =
    # Refactor R6: explicit loop (was split(...).mapIt(newStr(it))).
    let parts = ($(args[0])).split('\n')
    var items = newSeqOfCap[Value](parts.len)
    for p in parts: items.add(newStr(p))
    newList(items))

  env.registerCmd("filter", proc(env: Env, args: seq[Value]): Value =
    # Refactor R6: single pass with pre-sized buffer (was
    # filterIt(...).join — two passes + closure + temp seq).
    let src = $args[0]
    let needle = $args[1]
    var outp = newStringOfCap(src.len)
    var firstKept = true
    for line in src.split('\n'):
      if needle in line:
        if not firstKept: outp.add('\n')
        outp.add(line)
        firstKept = false
    newStr(outp))

  env.registerCmd("count", proc(env: Env, args: seq[Value]): Value =
    # Refactor R6: count without building (was split+filterIt+len).
    var n = 0
    for line in ($(args[0])).split('\n'):
      if line.len > 0: inc n
    newInt(n))

  env.registerCmd("first", proc(env: Env, args: seq[Value]): Value =
    # Refactor R6: scan without building (was split+filterIt+[0]).
    for line in ($(args[0])).split('\n'):
      if line.len > 0: return newStr(line)
    emptyVal())

  env.registerCmd("last", proc(env: Env, args: seq[Value]): Value =
    # Refactor R6: scan without building (was split+filterIt+[^1]).
    var found = false
    var lastLine = ""
    for line in ($(args[0])).split('\n'):
      if line.len > 0:
        lastLine = line
        found = true
    if found: newStr(lastLine) else: emptyVal())

  env.registerCmd("some", proc(env: Env, args: seq[Value]): Value =
    mkSome(args[0]))

  env.registerCmd("none", proc(env: Env, args: seq[Value]): Value =
    mkNone())

  env.registerCmd("some?", proc(env: Env, args: seq[Value]): Value =
    if isSome(args[0]): newInt(1) else: newInt(0))

  env.registerCmd("none?", proc(env: Env, args: seq[Value]): Value =
    if isNone(args[0]): newInt(1) else: newInt(0))

  env.registerCmd("unwrap", proc(env: Env, args: seq[Value]): Value =
    if not isSome(args[0]):
      raise kerr("option", -1, "unwrap called on none")
    unwrapVal(args[0]))

  env.registerCmd("unwrapOr", proc(env: Env, args: seq[Value]): Value =
    if isSome(args[0]): unwrapVal(args[0])
    else: args[1])

  env.registerCmd("map", proc(env: Env, args: seq[Value]): Value =
    if isNone(args[0]): return mkNone()
    let val = unwrapVal(args[0])
    let body = $args[1]
    # Refactor R4: pooled child frame.
    let child = acquireCallEnv(env.rootCache)
    try:
      child.setVar("it", val)
      let res = child.evalSub(body)
      mkSome(res)
    finally:
      releaseCallEnv(child))

  env.registerCmd("try", proc(env: Env, args: seq[Value]): Value =
    try:
      mkSome(env.evalBody($args[0]))
    except KronynError as e:
      let r = env.rootCache
      r.setVar("err", newStr(e.msg))
      r.setVar("errkind", newStr(e.kind))
      r.setVar("errline", newInt(e.line))
      r.setVar("errtrace", newStr(kronynTrace()))
      clearTrace()
      mkNone()
    except ValueError as e:
      let r = env.rootCache
      r.setVar("err", newStr(e.msg))
      r.setVar("errkind", newStr("error"))
      r.setVar("errline", newInt(-1))
      r.setVar("errtrace", newStr(kronynTrace()))
      clearTrace()
      mkNone())

#------- entry -------------------------------------------

proc newInterpreter*(quiet = false, argv: seq[string] = @[]): Env =
  initThreadCaches()
  # Refactor R4: pooled frames hold the previous root — drop them with the
  # caches so a fresh interpreter (incl. actor workers) starts clean.
  envPool.setLen(0)
  let env = newEnv()
  env.initKernel()
  var av: seq[Value] = @[]
  for a in argv: av.add(newStr(a))
  env.setVar("argv", newList(av))
  let t0 = cpuTime()
  discard env.eval(parse(tokenize(essentialsSource())))
  if not quiet:
    echo "essentials load: ", cpuTime() - t0, "s"
  env

#------- @actor: isolated calls, share-nothing, caller blocks -------
# Transport v1: OS subprocess (own process = own GC + heap, no shared
# memory by construction). The job crosses the boundary via marshal
# serialization; the child re-runs this same binary with --actor-run.
# Coarse tasks only: spawn cost is milliseconds, not microseconds.

type
  ActorJob* = object
    name*: string
    params*: seq[string]
    ptypes*: seq[string]
    body*: string
    rtype*: string
    args*: seq[Value]
    retryMax*: int
    line*: int
    tailOpt*: bool

  ActorResult* = object
    ok*: bool
    val*: Value
    err*: string

var actorSeq {.threadvar.}: int

proc actorRunLocal(job: ActorJob): ActorResult =
  try:
    let wenv = newInterpreter(quiet = true)
    let wroot = wenv
    let wname = job.name
    let wparams = job.params
    let wptypes = job.ptypes
    let wbody = job.body
    let wrtype = job.rtype
    let wretry = job.retryMax
    let wline = job.line
    let wtailOpt = job.tailOpt
    let wcheck = wptypes.len > 0
    wroot.builtinArities.del(wname)
    wroot.registerCmd(wname, proc(env: Env, args: seq[Value]): Value =
      if args.len < wparams.len:
        raise kerr("arity", wline, "actor " & wname & " expects " &
          $wparams.len & " args, got " & $args.len)
      if wcheck: checkCallParams(wname, wline, wparams, wptypes, args)
      withFrame(wname, wline):
        let res = invokeDirect(env, wname, wparams, wptypes, wbody, wline, wcheck, wtailOpt, args)
        if wcheck: checkReturnKind(wname, wline, wrtype, res)
        res)
    let fn = wroot.getCmd(wname)
    var lastErr = ""
    for attempt in 1..wretry:
      try:
        let res = fn(wroot, job.args)
        return ActorResult(ok: true, val: res, err: "")
      except ValueError as e:
        lastErr = e.msg
        if attempt == wretry:
          let wt = workerTraceSuffix()
          if wt != "":
            lastErr &= "\n" & wt
          return ActorResult(ok: false, val: nil, err: lastErr)
        clearTrace()
    return ActorResult(ok: false, val: nil, err: lastErr)
  except TailCallSignal:
    raise
  except Exception as e:
    ActorResult(ok: false, val: nil, err: e.msg)

proc runActorJobFile*(jobPath, resPath: string) =
  let job = to[ActorJob](readFile(jobPath))
  writeFile(resPath, $$(actorRunLocal(job)))

proc spawnActorCall*(name: string, params: seq[string], ptypes: seq[string],
                     body: string, rtype: string,
                     args: seq[Value], retryMax: int, line: int,
                     tailOpt: bool, timeoutMs: int = 0): Value =
  inc actorSeq
  let base = getTempDir() / "kronyn_actor_" & $getCurrentProcessId() & "_" & $actorSeq
  let jobPath = base & ".job"
  let resPath = base & ".res"
  try:
    let ajob = ActorJob(name: name, params: params, ptypes: ptypes,
                        body: body, rtype: rtype,
                        args: args, retryMax: retryMax, line: line,
                        tailOpt: tailOpt)
    writeFile(jobPath, $$ajob)
    let exe = paramStr(0)
    let p = startProcess(exe, args = @["--actor-run", jobPath, resPath],
                         options = {poParentStreams})
    let t0 = epochTime()
    var code = 0
    if timeoutMs > 0:
      # Preemptive path: the timed wait bounds the worker. Its return
      # value is meaningless on timeout (0 on Windows either way), so
      # expiry is classified below via the missing result file + clock.
      discard p.waitForExit(timeoutMs)
      # No orphan on any platform: Windows' timed wait already ends the
      # child; elsewhere it keeps running, so end it if still alive.
      try:
        if p.running(): p.kill()
      except: discard
      try: code = p.waitForExit() except: discard
    else:
      code = p.waitForExit()
    try: p.close() except: discard
    if not fileExists(resPath):
      if timeoutMs > 0 and (epochTime() - t0) * 1000.0 >= timeoutMs.float - 50.0:
        raise kerr("timeout", line,
          "actor " & name & ": timed out after " & $timeoutMs & "ms")
      raise kerr("actor", line,
        "actor " & name & ": worker failed (exit " & $code & ")")
    let res = to[ActorResult](readFile(resPath))
    if res.ok:
      if res.val == nil: emptyVal() else: res.val
    else:
      raise kerr("actor", line, "actor " & name & ": " & res.err)
  finally:
    try: removeFile(jobPath) except: discard
    try: removeFile(resPath) except: discard

#------- @forkexec: forked calls, full-world inheritance, caller blocks ---
# Transport v1: OS subprocess like @actor (own process = own GC + heap, no
# shared memory by construction), but the child inherits the FULL world:
# every define in registration order plus the root globals snapshotted at
# fork time. The child re-runs this same binary with --forkexec-run.
# The call boundary is the only channel in (call-frame locals are NOT
# inherited — v1 boundary); the result is the only channel back.
# Coarse tasks only: spawn cost is milliseconds, not microseconds.

type
  ForkJob* = object
    target*: string
    args*: seq[Value]
    line*: int
    innerRetry*: int
    defines*: seq[ForkDef]
    vars*: seq[tuple[name: string, val: Value]]

# Re-register one world define as a plain procedure (own helper proc so
# each closure captures its own define — never a shared loop variable).
# Retry wrappers are preserved per define; @actor/@forkexec wrappers are
# NOT restored: isolation boundaries do not nest (same rule as actor
# workers). Deprecation warnings stay parent-side only.
proc registerForkDef(wroot: Env, d: ForkDef, retryOverride = -1) =
  let dp = d.params
  let dt = d.ptypes
  let db = d.body
  let dr = d.rtype
  let dline = d.line
  let dname = d.name
  let dcheck = d.wantCheck
  let dtail = d.tailOpt
  let dretry = if retryOverride >= 0: retryOverride else: d.retryMax
  wroot.builtinArities.del(dname)
  wroot.registerCmd(dname, proc(env: Env, args: seq[Value]): Value =
    if args.len < dp.len:
      raise kerr("arity", dline, dname & " expects " & $dp.len & " args, got " & $args.len)
    if dcheck: checkCallParams(dname, dline, dp, dt, args)
    withFrame(dname, dline):
      var res: Value = nil
      for attempt in 1..dretry:
        try:
          res = invokeDirect(env, dname, dp, dt, db, dline, dcheck, dtail, args)
          break
        except ValueError:
          if attempt == dretry: raise
          clearTrace()
      if dcheck: checkReturnKind(dname, dline, dr, res)
      res)

proc forkRunLocal(job: ForkJob): ActorResult =
  try:
    let wenv = newInterpreter(quiet = true)
    let wroot = wenv
    for d in job.defines:
      # The target's own retry wrapper is stripped: job.innerRetry drives
      # retries for it (otherwise outer x inner would multiply). Helpers
      # keep their recorded wrappers.
      if d.name == job.target:
        registerForkDef(wroot, d, 1)
      else:
        registerForkDef(wroot, d)
    # Restore fork-time globals. Copies, not shared — child `set`s die
    # with the child, exactly like forked address-space copies.
    for pair in job.vars:
      wroot.setVar(pair.name, pair.val)
    let fn = wroot.getCmd(job.target)
    if fn == nil:
      return ActorResult(ok: false, val: nil,
        err: "unknown command: " & job.target)
    var lastErr = ""
    for attempt in 1..job.innerRetry:
      try:
        let res = fn(wroot, job.args)
        return ActorResult(ok: true, val: res, err: "")
      except ValueError as e:
        lastErr = e.msg
        if attempt == job.innerRetry:
          let wt = workerTraceSuffix()
          if wt != "":
            lastErr &= "\n" & wt
          return ActorResult(ok: false, val: nil, err: lastErr)
        clearTrace()
    return ActorResult(ok: false, val: nil, err: lastErr)
  except TailCallSignal:
    raise
  except Exception as e:
    ActorResult(ok: false, val: nil, err: e.msg)

proc runForkJobFile*(jobPath, resPath: string) =
  let job = to[ForkJob](readFile(jobPath))
  writeFile(resPath, $$(forkRunLocal(job)))

var forkSeq {.threadvar.}: int

proc spawnForkCall*(caller: Env, name: string, args: seq[Value], line: int,
                    innerRetry: int, timeoutMs: int = 0): Value =
  let r = caller.rootCache
  var defs: seq[ForkDef] = @[]
  for n in r.forkOrder:
    if n in r.forkDefs:
      defs.add(r.forkDefs[n])
  var vs: seq[tuple[name: string, val: Value]] = @[]
  for k, v in r.vars:
    vs.add((k, v))
  inc forkSeq
  let base = getTempDir() / "kronyn_fork_" & $getCurrentProcessId() & "_" & $forkSeq
  let jobPath = base & ".job"
  let resPath = base & ".res"
  try:
    let fjob = ForkJob(target: name, args: args, line: line,
                       innerRetry: innerRetry, defines: defs, vars: vs)
    writeFile(jobPath, $$fjob)
    let exe = paramStr(0)
    let p = startProcess(exe, args = @["--forkexec-run", jobPath, resPath],
                         options = {poParentStreams})
    let t0 = epochTime()
    var code = 0
    if timeoutMs > 0:
      # Preemptive path, mirroring spawnActorCall: the timed wait bounds
      # the worker; expiry is classified via the missing result file.
      discard p.waitForExit(timeoutMs)
      try:
        if p.running(): p.kill()
      except: discard
      try: code = p.waitForExit() except: discard
    else:
      code = p.waitForExit()
    try: p.close() except: discard
    if not fileExists(resPath):
      if timeoutMs > 0 and (epochTime() - t0) * 1000.0 >= timeoutMs.float - 50.0:
        raise kerr("timeout", line,
          "fork " & name & ": timed out after " & $timeoutMs & "ms")
      raise kerr("fork", line,
        "fork " & name & ": worker failed (exit " & $code & ")")
    let res = to[ActorResult](readFile(resPath))
    if res.ok:
      if res.val == nil: emptyVal() else: res.val
    else:
      raise kerr("fork", line, "fork " & name & ": " & res.err)
  finally:
    try: removeFile(jobPath) except: discard
    try: removeFile(resPath) except: discard
