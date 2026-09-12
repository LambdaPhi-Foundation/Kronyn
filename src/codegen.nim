# Kronyn ahead-of-time transpiler (-compile): AST -> C source.
#
# Strategy: the SAME parser feeds both backends, so any accepted program
# means the same thing up to the documented subset. Anything outside the
# compilable subset v1 is refused here with a file:line message instead
# of silently miscompiling.
#
# v1 subset: values, int/string/list/option ops, all kernel builtins
# except map, if/elif/else, while/loop/iter/break, top-level return,
# set, try, user `define` (proc/fn, recursion, dot-chaining,
# `@typecheck`/`@tailcallopt`/`@retry`/`@deprecated`/`@timeout`),
# top-level `import` (spliced inline), essentials.kr compiled
# wholesale (single source of truth), writeln-style intents,
# dot-chaining, [...] holding a single expression or call, {...} in
# control-flow positions, and the full syscall registry.
# Refused: evolve, nested defines/imports, @actor, @forkexec and every
# other @annotation, non-block if/while/try bodies, multi-statement
# @annotation, non-block if/while/try bodies, multi-statement
# conditions, dynamic import paths and RTA counts, non-literal set
# targets. See COMPILE.md for the subset table and deviations.
#
# Memory discipline of the emitted code: every emitted KRN_Value* is an
# OWNED reference (see kronyn_rt.h). Each statement collects the temps
# it creates and releases them in reverse order before moving on; stored
# values are retained by krn_set. Runtime helpers borrow their inputs.

import lexer, parser, ast, eval, strutils, tables, token, os

type
  CompileError* = object of ValueError

# Bumped on any emitter change affecting output. Hashed into the
# -compile cache key (with the emitted C and runtime sources), so no
# manual cache invalidation is ever needed for codegen work.
const CodegenVersion* = 4

proc cerr(line: int, msg: string): ref CompileError =
  new(result)
  result.msg = if line >= 0: "line " & $line & ": " & msg else: msg

type
  Ctx = object
    body: string
    funcs: string
    tmp: int
    loopDepth: int
    tmps: seq[string]
    # proc compilation state (M2)
    reg: Table[string, Define]
    order: seq[string]
    inProc: bool
    rootExpr: string
    procName: string
    procParams: seq[string]
    tailOpt: bool
    wantCheck: bool
    # M3 lexical scopes: handlerDepth counts active try/retry handlers
    # (every nonlocal exit pops this many); loopBases records the depth
    # at each enclosing Kronyn loop for break-across-try.
    handlerDepth: int
    loopBases: seq[int]
    imports: seq[string]

  Define = object
    name: string
    cname: string
    params: seq[string]
    ptypes: seq[string]
    retType: string
    bodySrc: string
    line: int
    tailOpt: bool
    wantCheck: bool
    retryMax: int
    depFound: bool
    depMsg: string
    timeoutMs: int

const TypeNames = ["int", "string", "list", "some", "none", "any"]

proc kindConst(t: string): string =
  case t
  of "int": "KRN_INT"
  of "string": "KRN_STR"
  of "list": "KRN_LIST"
  of "some": "KRN_SOME"
  of "none": "KRN_NONE"
  else: ""

# C identifiers cannot hold `?`/`!` (both legal in Kronyn names).
proc sanitizeC(s: string): string =
  # Refactor R8: pre-sized buffer (was &= growth from "").
  result = newStringOfCap(s.len + 8)
  for ch in s:
    if ch in {'a'..'z', 'A'..'Z', '0'..'9', '_'}:
      result.add(ch)
    elif ch == '?':
      result.add("_q")
    elif ch == '!':
      result.add("_b")
    else:
      result.add("_x" & toHex(ord(ch), 2))

proc fresh(c: var Ctx, prefix: string): string =
  result = prefix & $c.tmp
  inc c.tmp

proc emit(c: var Ctx, line: string) =
  c.body &= line & "\n"

# C-escape a byte string into a "..." literal body
proc cStr(s: string): string =
  # Refactor R8: pre-sized buffer (was &= growth from "").
  result = newStringOfCap(s.len + 8)
  for ch in s:
    case ch
    of '"': result.add("\\\"")
    of '\\': result.add("\\\\")
    of '\n': result.add("\\n")
    of '\t': result.add("\\t")
    of '\r': result.add("\\r")
    else:
      if ord(ch) < 32 or ord(ch) > 126:
        result.add("\\x" & toHex(ord(ch), 2))
      else:
        result.add(ch)

# Refactor R8: manual comma join with capacity (was join temporaries).
proc joinComma(items: openArray[string]): string =
  if items.len == 0: return ""
  var total = 0
  for it in items: total += it.len + 2
  result = newStringOfCap(total)
  for i, it in items:
    if i > 0: result.add(", ")
    result.add(it)

type
  Builtin = tuple[cfn: string, minA, maxA: int]

# Mirrors builtinAritySpecs in eval.nim (counts include the receiver for
# dot calls, which is also correct for intent calls). `map` and the
# control commands are refused with dedicated messages instead.
const builtins = [
  ("writeln", "krn_b_writeln", 1, 1), ("write", "krn_b_write", 1, 1),
  ("input", "krn_b_input", 0, 0), ("readln", "krn_b_readln", 0, 0),
  ("toUpper", "krn_b_toUpper", 1, 1), ("toLower", "krn_b_toLower", 1, 1),
  ("len", "krn_b_len", 1, 1), ("trim", "krn_b_trim", 1, 1),
  ("ascii", "krn_b_ascii", 1, 1), ("char", "krn_b_char", 1, 1),
  ("int", "krn_b_int", 1, 1), ("str", "krn_b_str", 1, 1),
  ("typeof", "krn_b_typeof", 1, 1), ("isInt", "krn_b_isInt", 1, 1),
  ("isString", "krn_b_isString", 1, 1), ("isList", "krn_b_isList", 1, 1),
  ("slice", "krn_b_slice", 3, 3), ("index", "krn_b_index", 2, 2),
  ("contains", "krn_b_contains", 2, 2), ("replace", "krn_b_replace", 3, 3),
  ("split", "krn_b_split", 2, 2), ("concat", "krn_b_concat", 2, 2),
  ("mod", "krn_b_mod", 2, 2), ("exec", "krn_b_exec", 1, 1),
  ("lines", "krn_b_lines", 1, 1), ("filter", "krn_b_filter", 2, 2),
  ("count", "krn_b_count", 1, 1), ("first", "krn_b_first", 1, 1),
  ("last", "krn_b_last", 1, 1),
  ("some", "krn_b_some", 1, 1), ("none", "krn_b_none", 0, 0),
  ("some?", "krn_b_somep", 1, 1), ("none?", "krn_b_nonep", 1, 1),
  ("unwrap", "krn_b_unwrap", 1, 1), ("unwrapOr", "krn_b_unwrapOr", 2, 2),
]

proc findBuiltin(name: string): tuple[found: bool, b: Builtin] =
  for b in builtins:
    if b[0] == name:
      return (true, (b[1], b[2], b[3]))
  (false, ("", 0, 0))

const controlCmds = ["if", "while", "loop", "iter"]
const refusedCmds = ["map", "define", "evolve", "import"]

proc checkArity(line: int, what: string, got, minA, maxA: int) =
  if got < minA or (maxA >= 0 and got > maxA):
    if maxA < 0:
      raise cerr(line, what & " expects at least " & $minA &
        " args, got " & $got)
    elif minA == maxA:
      raise cerr(line, what & " expects " & $minA & " args, got " & $got)
    else:
      raise cerr(line, what & " expects " & $minA & ".." & $maxA &
        " args, got " & $got)

# RTA counts/windows are evaluated at define time in the walker, but the
# compiler has no defining scope — they must be literals. Text goes
# through the same word grammar as runtime words (sign + digits).
proc literalInt(raw: string): tuple[ok: bool, n: int] =
  let w = wordToValue(raw.strip())
  if w.kind == vkInt:
    (true, w.intVal)
  else:
    (false, 0)

proc parseRetryLiteral(c: var Ctx, ann: ChainCall, line: int): int =
  if ann.args.len < 1:
    raise cerr(line, "@retry requires a count, e.g. @retry(3)")
  if ann.args[0].kind != argWord and ann.args[0].kind != argString:
    raise cerr(line, "@retry count must be a literal integer in compiled v1")
  let raw = if ann.args[0].kind == argWord: ann.args[0].word
            else: ann.args[0].str
  let (ok, n) = literalInt(raw)
  if not ok:
    raise cerr(line, "@retry count must be a literal integer in compiled v1")
  if n < 1: 1
  elif n > 2147483647:
    raise cerr(line, "@retry count too large (max 2147483647)")
  else: n

# Top-level imports splice inline (hermetic binary: no runtime reread).
# Cycle-guarded; nested imports stay for genStmt to refuse.
proc expandProg(prog: Program, c: var Ctx): Program =
  result = @[]
  for s in prog:
    if s.cmd == "import":
      if s.annotations.len > 0:
        raise cerr(s.line, "@" & s.annotations[0].name &
          " on import is not compilable in v1")
      if s.args.len < 1:
        raise cerr(s.line, "import requires a path argument")
      if s.args[0].kind != argString:
        raise cerr(s.line, "import path must be a string literal " &
          "in compiled v1")
      let path = s.args[0].str
      let canon =
        try:
          absolutePath(path)
        except OSError:
          raise cerr(s.line, "import: file not found: " & path)
      if canon in c.imports:
        raise cerr(s.line, "import: circular import of " & path)
      var content = ""
      try:
        content = readFile(canon)
      except IOError, OSError:
        raise cerr(s.line, "import: file not found: " & path)
      c.imports.add(canon)
      for s2 in expandProg(parse(tokenize(content)), c):
        result.add(s2)
      discard c.imports.pop()
    else:
      result.add(s)

# forward declarations (emitter is mutually recursive like the walker)
proc genExpr(c: var Ctx, a: Arg): string
proc genStmt(c: var Ctx, s: Stmt)
proc genStmts(c: var Ctx, p: Program)
proc genCallValue(c: var Ctx, name: string, args: seq[Arg],
                  line: int): string
proc genSyscall(c: var Ctx, stmt: Stmt): string
proc genSetValue(c: var Ctx, target: Arg, val: Arg, line: int): string
proc genMethodCall(c: var Ctx, recv: string, call: ChainCall): string
proc genIterMethod(c: var Ctx, condSrc, bodySrc: string, line: int): string
proc genTryValue(c: var Ctx, body: Arg, line: int): string
proc releaseTmps(c: var Ctx, base: int)
proc updateLast(c: var Ctx, t: string)
proc genUserCall(c: var Ctx, d: Define, argTemps: seq[string],
                 line: int): string
proc collectDefine(c: var Ctx, s: Stmt)
proc genDefine(c: var Ctx, d: Define)

# Analyze a [...] / {...} source used in value position: exactly one
# statement, either a bare expression or a compilable call.
type CodeKind = enum ckExpr, ckCall

proc isChainOp(t: Token): bool =
  t.kind in {tkPlus, tkMinus, tkStar, tkSlash,
              tkEqEq, tkBangEq, tkLt, tkGt,
              tkLtEq, tkGtEq, tkAnd, tkOr, tkBang, tkDotDot}

proc chainOpText(t: Token): string =
  case t.kind
  of tkPlus: "+"
  of tkMinus: "-"
  of tkStar: "*"
  of tkSlash: "/"
  of tkEqEq: "=="
  of tkBangEq: "!="
  of tkLt: "<"
  of tkGt: ">"
  of tkLtEq: "<="
  of tkGtEq: ">="
  of tkAnd: "&&"
  of tkOr: "||"
  of tkBang: "!"
  of tkDotDot: ".."
  else: ""

# Left-associative expression chains (`$a + $b + $c` means `(a+b)+c`).
# Dispatch mirrors evalSub exactly: a lone word/var/string is a COMMAND
# (full-parse path — `[$x]` is "unknown command: x" in the walker too),
# dot-chains and `!x` are expressions, an operator second token starts
# an expression. Two deliberate deviations, both documented (#10):
# clean multi-op chains fold fully (the walker drops past the first
# pair), while trailing junk after a pair keeps the walker's
# first-pair-only reading. No suite test chains operators.
proc tryChain(src: string, line: int): tuple[ok: bool, arg: Arg] =
  try:
    var px = newParser(tokenize(src))
    px.skipNewlines()
    if px.isAtEnd():
      return (false, nil)
    var left = px.parsePrimary()
    if not isChainOp(px.peek()):
      if px.peek().kind in {tkNewline, tkEof} and
          left.kind in {argChain, argInfix}:
        px.skipNewlines()
        return (true, left)
      return (false, nil)
    let firstOp = chainOpText(px.advance())
    if px.peek().kind in {tkNewline, tkEof}:
      return (false, nil)
    let firstRight = px.parsePrimary()
    let firstPair = infixArg(left, firstOp, firstRight)
    var folded = firstPair
    while isChainOp(px.peek()):
      let op = chainOpText(px.advance())
      if px.peek().kind in {tkNewline, tkEof}:
        return (false, nil)
      folded = infixArg(folded, op, px.parsePrimary())
    px.skipNewlines()
    if px.isAtEnd():
      return (true, folded)
    (true, firstPair)
  except ValueError:
    (false, nil)

proc analyzeCode(src: string, line: int, what: string
                ): tuple[kind: CodeKind, arg: Arg, stmt: Stmt] =
  let (ok, folded) = tryChain(src, line)
  if ok:
    return (ckExpr, folded,
            Stmt(cmd: "__expr", args: @[folded], annotations: @[], line: line))
  let p = parse(tokenize(src))
  if p.len != 1:
    raise cerr(line, what & " must be a single expression (line " &
      $line & ")")
  if p[0].cmd == "__expr":
    (ckExpr, p[0].args[0], p[0])
  else:
    (ckCall, nil, p[0])

# A block source used as a statement body: any number of compilable
# statements (each validated when emitted).
proc analyzeProg(src: string): Program =
  parse(tokenize(src))

proc genExpr(c: var Ctx, a: Arg): string =
  case a.kind
  of argString:
    result = c.fresh("t")
    c.tmps.add(result)
    c.emit("KRN_Value *" & result & " = krn_str_c(\"" & cStr(a.str) & "\");")
  of argWord:
    let w = wordToValue(a.word)
    result = c.fresh("t")
    c.tmps.add(result)
    if w.kind == vkInt:
      c.emit("KRN_Value *" & result & " = krn_int(" & $w.intVal & "LL);")
    else:
      c.emit("KRN_Value *" & result & " = krn_str_c(\"" & cStr(w.strVal) & "\");")
  of argVar:
    result = c.fresh("t")
    c.tmps.add(result)
    c.emit("KRN_Value *" & result & " = krn_get(env, \"" & cStr(a.name) & "\");")
  of argTypedParam:
    raise cerr(a.line, "type annotation is only allowed in define signatures")
  of argBlock:
    raise cerr(a.line, "block {...} is not a value in compiled v1 " &
      "(control-flow positions only)")
  of argSub:
    let code = analyzeCode(a.sub, a.line, "sub-expression")
    if code.kind == ckExpr:
      result = c.genExpr(code.arg)
    else:
      result = c.genCallValue(code.stmt.cmd, code.stmt.args, code.stmt.line)
  of argChain:
    if a.receiver.kind == argWord and a.receiver.word == "" and
        a.calls.len > 0:
      result = c.genCallValue(a.calls[0].name, a.calls[0].args,
                              a.calls[0].line)
      for i in 1..<a.calls.len:
        result = c.genMethodCall(result, a.calls[i])
    elif a.calls.len == 1 and a.calls[0].name == "iter" and
        a.receiver.kind == argBlock and a.calls[0].args.len == 1 and
        a.calls[0].args[0].kind == argBlock:
      result = c.genIterMethod(a.receiver.body, a.calls[0].args[0].body,
                               a.calls[0].line)
    else:
      var recv = c.genExpr(a.receiver)
      for call in a.calls:
        recv = c.genMethodCall(recv, call)
      result = recv
  of argInfix:
    if a.op == "!":
      let r = c.genExpr(a.right)
      result = c.fresh("t")
      c.tmps.add(result)
      c.emit("KRN_Value *" & result & " = krn_knot(" & r & ");")
    else:
      let l = c.genExpr(a.left)
      let r = c.genExpr(a.right)
      let fn = case a.op
        of "+": "krn_add"
        of "-": "krn_sub"
        of "*": "krn_mul"
        of "/": "krn_divide"
        of "..": "krn_concat"
        of "==": "krn_eq"
        of "!=": "krn_ne"
        of "<": "krn_lt"
        of ">": "krn_gt"
        of "<=": "krn_lte"
        of ">=": "krn_gte"
        of "&&": "krn_kand"
        of "||": "krn_kor"
        else: raise cerr(a.line, "unknown operator: " & a.op)
      result = c.fresh("t")
      c.tmps.add(result)
      c.emit("KRN_Value *" & result & " = " & fn & "(" & l & ", " & r & ");")

proc genMethodCall(c: var Ctx, recv: string, call: ChainCall): string =
  # User procs first: a define shadows same-named builtins, and any
  # proc (not just fn) is dot-callable with the receiver as args[0].
  if c.reg.hasKey(call.name):
    var ins = @[recv]
    for x in call.args:
      ins.add(c.genExpr(x))
    return c.genUserCall(c.reg[call.name], ins, call.line)
  if call.name == "iter":
    raise cerr(call.line, "iter needs literal blocks in compiled v1")
  if call.name in controlCmds:
    raise cerr(call.line, call.name & " must be used as a statement " &
      "in compiled v1")
  if call.name == "try":
    raise cerr(call.line, "try must be used as a statement " &
      "in compiled v1")
  if call.name in refusedCmds:
    raise cerr(call.line, call.name & " is not compilable in v1")
  let (found, b) = findBuiltin(call.name)
  if not found:
    raise cerr(call.line, "unknown method: " & call.name)
  var ins = @[recv]
  for x in call.args:
    ins.add(c.genExpr(x))
  checkArity(call.line, call.name, ins.len, b.minA, b.maxA)
  result = c.fresh("t")
  c.tmps.add(result)
  c.emit("KRN_Value *" & result & " = " & b.cfn & "(" & joinComma(ins) & ");")

proc genCallValue(c: var Ctx, name: string, args: seq[Arg],
                  line: int): string =
  if c.reg.hasKey(name):
    var ins: seq[string] = @[]
    for x in args:
      ins.add(c.genExpr(x))
    return c.genUserCall(c.reg[name], ins, line)
  if name in controlCmds:
    raise cerr(line, name & " must be used as a statement in compiled v1")
  if name in refusedCmds:
    raise cerr(line, name & " is not compilable in v1")
  if name == "try":
    if args.len != 1:
      raise cerr(line, "try expects 1 args, got " & $args.len)
    return c.genTryValue(args[0], line)
  if name == "return" or name == "break":
    raise cerr(line, name & " must be used as a statement in compiled v1")
  if name == "syscall":
    if args.len < 1:
      raise cerr(line, "syscall requires a namespace.method argument")
    return c.genSyscall(Stmt(cmd: "syscall", args: args,
                             annotations: @[], line: line))
  if name == "set":
    if args.len < 2:
      raise cerr(line, "set requires 2 arguments")
    return c.genSetValue(args[0], args[1], line)
  let (found, b) = findBuiltin(name)
  if not found:
    raise cerr(line, "unknown command: " & name)
  var ins: seq[string] = @[]
  for x in args:
    ins.add(c.genExpr(x))
  checkArity(line, name, ins.len, b.minA, b.maxA)
  result = c.fresh("t")
  c.tmps.add(result)
  c.emit("KRN_Value *" & result & " = " & b.cfn & "(" & joinComma(ins) & ");")

proc genSyscall(c: var Ctx, stmt: Stmt): string =
  let line = stmt.line
  if stmt.args.len < 1:
    raise cerr(line, "syscall requires a namespace.method argument")
  let callArg = stmt.args[0]
  if callArg.kind != argChain or callArg.calls.len != 1:
    raise cerr(line, "syscall expects namespace.method")
  if callArg.calls[0].args.len != 0:
    raise cerr(line, "syscall arguments go after the method")
  if callArg.receiver.kind != argWord or callArg.receiver.word == "":
    raise cerr(line, "syscall namespace must be literal")
  let ns = callArg.receiver.word
  let meth = callArg.calls[0].name
  var ins: seq[string] = @[]
  for x in stmt.args[1..^1]:
    ins.add(c.genExpr(x))
  let what = "syscall " & ns & "." & meth
  case ns & "." & meth
  of "io.output":
    checkArity(line, what, ins.len, 1, 1)
    result = c.fresh("t"); c.tmps.add(result)
    c.emit("KRN_Value *" & result & " = krn_sys_io_output(" & ins[0] & ");")
  of "io.outputln":
    checkArity(line, what, ins.len, 1, 1)
    result = c.fresh("t"); c.tmps.add(result)
    c.emit("KRN_Value *" & result & " = krn_sys_io_outputln(" & ins[0] & ");")
  of "io.input":
    checkArity(line, what, ins.len, 0, 0)
    result = c.fresh("t"); c.tmps.add(result)
    c.emit("KRN_Value *" & result & " = krn_sys_io_input();")
  of "fs.read":
    checkArity(line, what, ins.len, 1, 1)
    result = c.fresh("t"); c.tmps.add(result)
    c.emit("KRN_Value *" & result & " = krn_sys_fs_read(" & ins[0] & ");")
  of "fs.write":
    checkArity(line, what, ins.len, 2, 2)
    result = c.fresh("t"); c.tmps.add(result)
    c.emit("KRN_Value *" & result & " = krn_sys_fs_write(" &
      ins[0] & ", " & ins[1] & ");")
  of "fs.exists":
    checkArity(line, what, ins.len, 1, 1)
    result = c.fresh("t"); c.tmps.add(result)
    c.emit("KRN_Value *" & result & " = krn_sys_fs_exists(" & ins[0] & ");")
  of "fs.append":
    checkArity(line, what, ins.len, 2, 2)
    result = c.fresh("t"); c.tmps.add(result)
    c.emit("KRN_Value *" & result & " = krn_sys_fs_append(" &
      ins[0] & ", " & ins[1] & ");")
  of "fs.remove":
    checkArity(line, what, ins.len, 1, 1)
    result = c.fresh("t"); c.tmps.add(result)
    c.emit("KRN_Value *" & result & " = krn_sys_fs_remove(" & ins[0] & ");")
  of "fs.list":
    checkArity(line, what, ins.len, 1, 1)
    result = c.fresh("t"); c.tmps.add(result)
    c.emit("KRN_Value *" & result & " = krn_sys_fs_list(" & ins[0] & ");")
  of "proc.exit":
    checkArity(line, what, ins.len, 0, 1)
    result = c.fresh("t"); c.tmps.add(result)
    if ins.len == 0:
      c.emit("KRN_Value *" & result & " = krn_sys_proc_exit(0, 0);")
    else:
      let arr = c.fresh("a")
      c.emit("KRN_Value *" & arr & "[] = {" & ins[0] & "};")
      c.emit("KRN_Value *" & result & " = krn_sys_proc_exit(1, " & arr & ");")
  of "proc.args":
    checkArity(line, what, ins.len, 0, 0)
    result = c.fresh("t"); c.tmps.add(result)
    c.emit("KRN_Value *" & result & " = krn_sys_proc_args();")
  else:
    if ns != "io" and ns != "fs" and ns != "proc":
      raise cerr(line, "unknown syscall namespace: " & ns)
    raise cerr(line, "unknown " & ns & " syscall: " & meth)

# `{cond}.iter({body})`: the only method form with control flow. Both
# sides must be literal blocks (anything dynamic is refused at the call
# site); like the walker it yields "".
proc genIterMethod(c: var Ctx, condSrc, bodySrc: string, line: int): string =
  let cond = analyzeCode(condSrc, line, "condition")
  let wbody = analyzeProg(bodySrc)
  c.emit("krn_line(" & $line & ");")
  c.emit("while (1) {")
  c.emit("krn_check_timeout();")
  let b = c.tmps.len
  var cc: string
  if cond.kind == ckExpr:
    cc = c.genExpr(cond.arg)
  else:
    cc = c.genCallValue(cond.stmt.cmd, cond.stmt.args, cond.stmt.line)
  var vv = c.fresh("c")
  c.emit("int " & vv & " = krn_truthy(" & cc & ");")
  c.releaseTmps(b)
  c.emit("if (!" & vv & ") break;")
  inc c.loopDepth
  c.loopBases.add(c.handlerDepth)
  c.genStmts(wbody)
  c.loopBases.setLen(c.loopBases.len - 1)
  dec c.loopDepth
  c.emit("}")
  result = c.fresh("t")
  c.tmps.add(result)
  c.emit("KRN_Value *" & result & " = krn_str_c(\"\");")

# `try {body}` as a value: some(body value), or none with
# err/errkind/errline/errtrace set. On catch, _last is RESET without
# reading it (its pre-catch value is indeterminate after longjmp; the
# abandoned ref is bounded leak, same policy as in-flight temps).
proc genTryValue(c: var Ctx, body: Arg, line: int): string =
  if body.kind != argBlock:
    raise cerr(line, "try body must be a block {...} in compiled v1")
  let hn = c.fresh("h")
  result = c.fresh("t")
  c.tmps.add(result)
  c.emit("KRN_Value *" & result & ";")
  c.emit("KRN_Handler " & hn & ";")
  c.emit("krn_push_handler(&" & hn & ");")
  c.emit("if (setjmp(" & hn & ".jb) == 0) {")
  inc c.handlerDepth
  c.genStmts(analyzeProg(body.body))
  dec c.handlerDepth
  c.emit("krn_pop_handler();")
  c.emit(result & " = krn_some(krn_retain(_last));")
  c.emit("} else {")
  c.emit("_last = krn_str_c(\"\");")
  c.emit("krn_set(env, \"err\", krn_str_c(krn_err_msg()));")
  c.emit("krn_set(env, \"errkind\", krn_str_c(krn_err_kind()));")
  c.emit("krn_set(env, \"errline\", krn_int(krn_err_line()));")
  c.emit("krn_set(env, \"errtrace\", krn_str_c(krn_err_trace()));")
  c.emit(result & " = krn_none();")
  c.emit("}")

# `set` as a value (e.g. `[set x 1]` returns 1, mirroring the walker):
# stores and transfers the same owned temp to the caller.
proc genSetValue(c: var Ctx, target: Arg, val: Arg, line: int): string =
  if target.kind != argWord:
    raise cerr(line, "set target must be a name")
  result = c.genExpr(val)
  c.emit("krn_set(env, \"" & cStr(target.word) & "\", " & result & ");")

# Emit a Value-producing expression for an `if` condition slot: the
# walker tests the already-evaluated value, so any expression form
# works here (blocks would test their source text — refused).
proc genCondIf(c: var Ctx, a: Arg, line: int): string =
  case a.kind
  of argSub:
    let code = analyzeCode(a.sub, a.line, "condition")
    if code.kind == ckExpr:
      c.genExpr(code.arg)
    else:
      c.genCallValue(code.stmt.cmd, code.stmt.args, code.stmt.line)
  of argBlock:
    raise cerr(line, "if condition must be [...] in compiled v1")
  else:
    c.genExpr(a)

# Emit a Value-producing expression for a `while`/`iter` condition slot:
# the walker re-evaluates the slot as code every iteration, so only
# [...] / {...} holding one expression or call are compilable.
proc genCondLoop(c: var Ctx, a: Arg, line: int): string =
  case a.kind
  of argSub:
    let code = analyzeCode(a.sub, a.line, "condition")
    if code.kind == ckExpr:
      c.genExpr(code.arg)
    else:
      c.genCallValue(code.stmt.cmd, code.stmt.args, code.stmt.line)
  of argBlock:
    let code = analyzeCode(a.body, a.line, "condition")
    if code.kind == ckExpr:
      c.genExpr(code.arg)
    else:
      c.genCallValue(code.stmt.cmd, code.stmt.args, code.stmt.line)
  else:
    raise cerr(line, "while condition must be [...] or {...} " &
      "in compiled v1")

proc releaseTmps(c: var Ctx, base: int) =
  var i = c.tmps.len - 1
  while i >= base:
    c.emit("krn_release(" & c.tmps[i] & ");")
    dec i
  c.tmps.setLen(base)

# Proc bodies AND main track the "last statement value" (callFn parity
# for procs; try-body values for both — hence unconditional).
proc updateLast(c: var Ctx, t: string) =
  c.emit("krn_release(_last);")
  c.emit("_last = krn_retain(" & t & ");")

# Pop every handler abandoned by a nonlocal exit (return/goto/continue).
proc emitPops(c: var Ctx, n: int) =
  for _ in 0..<n:
    c.emit("krn_pop_handler();")

# Retry loop shared by @retry defines and @retry statements. Attempts > 1
# run under a recovery handler each; the final failure rethrows to the
# next handler up (or fails fatally). The attempt counter is volatile:
# it is read after longjmp having been modified past setjmp.
template withRetry(c: var Ctx, attempts: int, bod: untyped) =
  if attempts > 1:
    let an = c.fresh("a")
    let hn = c.fresh("h")
    c.emit("volatile int " & an & " = 0;")
    c.emit("for (" & an & " = 0; " & an & " < " & $attempts & "; " &
      an & "++) {")
    c.emit("KRN_Handler " & hn & ";")
    c.emit("krn_push_handler(&" & hn & ");")
    c.emit("if (setjmp(" & hn & ".jb) == 0) {")
    inc c.handlerDepth
    bod
    dec c.handlerDepth
    c.emit("krn_pop_handler();")
    c.emit("break;")
    c.emit("} else {")
    c.emit("if (" & an & " == " & $(attempts - 1) & ") krn_rethrow();")
    c.emit("}")
    c.emit("}")
  else:
    bod

# Pass 1: register a top-level define (mirrors eval's define parsing).
# Later registrations win: user code overwrites essentials, and repeat
# user defines resolve to the last one — exactly like re-registerCmd.
proc collectDefine(c: var Ctx, s: Stmt) =
  if s.args.len < 3:
    raise cerr(s.line, "define requires name, signature, and body")
  if s.args[0].kind != argWord:
    raise cerr(s.line, "define requires a name")
  let name = s.args[0].word
  let defArg = s.args[1]
  let bodyArg = s.args[2]
  if bodyArg.kind != argBlock:
    raise cerr(s.line, "define body must be a block {...}")
  var params: seq[string] = @[]
  var ptypes: seq[string] = @[]
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
  var wantCheck = false
  var tailOpt = false
  var retryMax = 1
  var depFound = false
  var depMsg = ""
  var timeoutMs = 0
  for ann in s.annotations:
    if ann.name == "typecheck":
      if ann.args.len > 0:
        raise cerr(s.line, "@typecheck takes no arguments; declare types in the signature")
      wantCheck = true
    elif ann.name == "tailcallopt":
      if ann.args.len > 0:
        raise cerr(s.line, "@tailcallopt takes no arguments")
      tailOpt = true
    elif ann.name == "retry":
      retryMax = c.parseRetryLiteral(ann, s.line)
    elif ann.name == "deprecated":
      if depFound:
        raise cerr(s.line, "duplicate @deprecated")
      depFound = true
      if ann.args.len > 1:
        raise cerr(s.line, "@deprecated takes at most one message argument")
      if ann.args.len == 1:
        if ann.args[0].kind != argString and ann.args[0].kind != argWord:
          raise cerr(s.line, "@deprecated message must be a literal " &
            "in compiled v1")
        depMsg = if ann.args[0].kind == argString: ann.args[0].str
                 else: $(wordToValue(ann.args[0].word))
    elif ann.name == "timeout":
      if timeoutMs != 0:
        raise cerr(s.line, "duplicate @timeout")
      if ann.args.len != 1:
        raise cerr(s.line, "@timeout requires milliseconds, e.g. @timeout(500)")
      if ann.args[0].kind != argWord and ann.args[0].kind != argString:
        raise cerr(s.line, "@timeout window must be a literal integer " &
          "in compiled v1")
      let raw = if ann.args[0].kind == argWord: ann.args[0].word
                else: ann.args[0].str
      let (ok, n) = literalInt(raw)
      if not ok:
        raise cerr(s.line, "@timeout window must be a literal integer " &
          "in compiled v1")
      if n < 1:
        raise cerr(s.line, "@timeout window must be positive milliseconds, got " & $n)
      if n > 2147483647:
        raise cerr(s.line, "@timeout window too large (max 2147483647)")
      timeoutMs = n
    elif ann.name == "actor":
      raise cerr(s.line, "@actor is not compilable in v1")
    elif ann.name == "forkexec":
      raise cerr(s.line, "@forkexec is not compilable in v1")
    else:
      raise cerr(s.line, "unknown annotation: @" & ann.name)
  if wantCheck:
    for i in 0..<params.len:
      if ptypes[i] == "":
        raise cerr(s.line, "@typecheck requires a declared type for parameter '" &
          params[i] & "' of " & name)
      if ptypes[i] notin TypeNames:
        raise cerr(s.line, "@typecheck unknown type '" &
          ptypes[i] & "' for parameter '" & params[i] & "' of " & name)
    if retType != "" and retType notin TypeNames:
      raise cerr(s.line, "@typecheck unknown return type '" &
        retType & "' of " & name)
  if name notin c.reg:
    c.order.add(name)
  c.reg[name] = Define(name: name, cname: "krn_fn_" & sanitizeC(name),
                       params: params, ptypes: ptypes, retType: retType,
                       bodySrc: bodyArg.body, line: s.line,
                       tailOpt: tailOpt, wantCheck: wantCheck,
                       retryMax: retryMax, depFound: depFound, depMsg: depMsg,
                       timeoutMs: timeoutMs)

# Call a user proc: argc is checked at runtime (same message as the
# define closure); extras were evaluated by the caller and are ignored.
proc genUserCall(c: var Ctx, d: Define, argTemps: seq[string],
                 line: int): string =
  if argTemps.len < d.params.len:
    raise cerr(line, d.name & " expects " & $d.params.len & " args, got " &
      $argTemps.len)
  result = c.fresh("t")
  c.tmps.add(result)
  if d.params.len == 0:
    c.emit("KRN_Value *" & result & " = " & d.cname & "(" &
      c.rootExpr & ", 0, 0);")
  else:
    let arr = c.fresh("a")
    c.emit("KRN_Value *" & arr & "[" & $d.params.len & "] = {" &
      joinComma(argTemps[0..<d.params.len]) & "};")
    c.emit("KRN_Value *" & result & " = " & d.cname & "(" &
      c.rootExpr & ", " & $d.params.len & ", " & arr & ");")

# Tail-call shapes mirror matchTailSelfCall: `return [self ...]` and
# `return [recv].self(...)`, with no annotations on the inner call.
# Emits param rebinding over a cleared frame + continue; the runtime
# argc check stays authoritative for miscounts here (uniform rule).
proc tryTailReturn(c: var Ctx, retArg: Arg, base: int): bool =
  if not c.tailOpt or c.loopDepth != 0:
    return false
  let d = c.reg[c.procName]
  var newArgs: seq[Arg] = @[]
  if retArg.kind == argSub:
    let p = parse(tokenize(retArg.sub))
    if p.len != 1:
      return false
    if p[0].cmd != c.procName or p[0].annotations.len > 0:
      return false
    newArgs = p[0].args
  elif retArg.kind == argChain:
    if retArg.calls.len == 0 or retArg.calls[^1].name != c.procName:
      return false
    if retArg.calls.len == 1:
      newArgs.add(retArg.receiver)
    else:
      var prefix: seq[ChainCall] = @[]
      for i in 0..<retArg.calls.len - 1:
        prefix.add(retArg.calls[i])
      newArgs.add(chainArg(retArg.receiver, prefix))
    for a in retArg.calls[^1].args:
      newArgs.add(a)
  else:
    return false
  if newArgs.len != d.params.len:
    raise cerr(retArg.line, c.procName & " expects " & $d.params.len &
      " args, got " & $newArgs.len)
  var temps: seq[string] = @[]
  for a in newArgs:
    temps.add(c.genExpr(a))
  c.emit("krn_env_clear(env);")
  for i, p in d.params:
    c.emit("krn_set(env, \"" & cStr(p) & "\", " & temps[i] & ");")
  if c.wantCheck:
    for i, p in d.params:
      if d.ptypes[i] != "" and d.ptypes[i] != "any":
        c.emit("krn_check_kind(" & temps[i] & ", " & kindConst(d.ptypes[i]) &
          ", \"" & cStr(d.name) & "\", \"" & cStr(p) & "\", " & $d.line & ");")
  c.releaseTmps(base)
  c.emitPops(c.handlerDepth)
  c.emit("continue;")
  true

# Emit one user proc as a C function. Calls evaluate in a fresh child
# of the root (never the caller's frame); the value is the explicit
# return or, like callFn, the last statement's value tracked in _last.
# Every exit path pops its traceback frame and frees its env.
proc genDefine(c: var Ctx, d: Define) =
  let savedBody = c.body
  c.body = ""
  let savedProc = c.inProc
  let savedRoot = c.rootExpr
  let savedName = c.procName
  let savedParams = c.procParams
  let savedTail = c.tailOpt
  let savedCheck = c.wantCheck
  let savedLoop = c.loopDepth
  let savedBases = c.loopBases
  c.inProc = true
  c.rootExpr = "root"
  c.procName = d.name
  c.procParams = d.params
  c.tailOpt = d.tailOpt
  c.wantCheck = d.wantCheck
  c.loopDepth = 0
  c.loopBases = @[]
  c.emit("KRN_Value *" & d.cname & "(KRN_Env *root, int argc, KRN_Value **argv) {")
  c.emit("if (argc < " & $d.params.len & ") krn_fail_arity(\"" &
    cStr(d.name) & "\", " & $d.line & ", " & $d.params.len & ", argc);")
  for i, p in d.params:
    if d.wantCheck and d.ptypes[i] != "" and d.ptypes[i] != "any":
      c.emit("krn_check_kind(argv[" & $i & "], " & kindConst(d.ptypes[i]) &
        ", \"" & cStr(d.name) & "\", \"" & cStr(p) & "\", " & $d.line & ");")
  if d.depFound:
    let text = if d.depMsg == "": d.name & " is deprecated"
               else: d.name & " is deprecated: " & d.depMsg
    c.emit("krn_warn_deprecated(\"" & cStr(d.name) & "\", " & $d.line &
      ", \"" & cStr(text) & "\");")
  c.emit("krn_push_frame(\"" & cStr(d.name) & "\", " & $d.line & ");")
  c.emit("krn_check_timeout();")
  c.emit("KRN_Value *_last = krn_str_c(\"\");")
  c.emit("KRN_Env *env;")
  withRetry(c, d.retryMax):
    c.emit("env = krn_new_env(root);")
    for i, p in d.params:
      c.emit("krn_set(env, \"" & cStr(p) & "\", argv[" & $i & "]);")
    c.emit("krn_release(_last);")
    c.emit("_last = krn_str_c(\"\");")
    if d.timeoutMs > 0:
      c.emit("krn_timeout_arm(\"" & cStr(d.name) & "\", " & $d.line &
        ", " & $d.timeoutMs & ");")
    if d.tailOpt:
      c.emit("while (1) {")
    c.genStmts(analyzeProg(d.bodySrc))
    if d.tailOpt:
      c.emit("}")
    if d.timeoutMs > 0:
      c.emit("krn_timeout_pop();")
    c.emit("krn_free_env(env);")
  c.emit("goto _end;")
  c.emit("_end:;")
  if d.timeoutMs > 0:
    c.emit("krn_timeout_pop();")
  if d.wantCheck and d.retType != "" and d.retType != "any":
    c.emit("krn_check_return(_last, " & kindConst(d.retType) & ", \"" &
      cStr(d.name) & "\", " & $d.line & ");")
  c.emit("krn_pop_frame();")
  c.emit("return _last;")
  c.emit("}")
  c.funcs &= c.body
  c.body = savedBody
  c.inProc = savedProc
  c.rootExpr = savedRoot
  c.procName = savedName
  c.procParams = savedParams
  c.tailOpt = savedTail
  c.wantCheck = savedCheck
  c.loopDepth = savedLoop
  c.loopBases = savedBases

proc genIfBody(c: var Ctx, a: Arg, line: int): Program =
  if a.kind != argBlock:
    raise cerr(line, "if body must be a block {...} in compiled v1")
  analyzeProg(a.body)

# Nested emission keeps every `else` attached to its `if`: conditions
# are fully computed (and their temps released) before each branch, so
# no statement ever lands between `}` and `else`.
proc emitBranches(c: var Ctx, conds: seq[Arg], bodies: seq[Program],
                  elseBody: Program, hasElse: bool, idx: int) =
  let b = c.tmps.len
  var cc = c.genCondIf(conds[idx], conds[idx].line)
  var vv = c.fresh("c")
  c.emit("int " & vv & " = krn_truthy(" & cc & ");")
  c.releaseTmps(b)
  c.emit("if (" & vv & ") {")
  c.genStmts(bodies[idx])
  c.emit("}")
  if idx + 1 < conds.len:
    c.emit("else {")
    c.emitBranches(conds, bodies, elseBody, hasElse, idx + 1)
    c.emit("}")
  elif hasElse:
    c.emit("else {")
    c.genStmts(elseBody)
    c.emit("}")

proc genStmt(c: var Ctx, s: Stmt) =
  # Only @retry is supported on statements (literal count, last wins);
  # every other annotation is define-only or unknown, mirroring eval.
  var retryN = 1
  for ann in s.annotations:
    if ann.name == "retry":
      retryN = c.parseRetryLiteral(ann, s.line)
    elif ann.name in ["actor", "forkexec", "typecheck", "tailcallopt", "deprecated",
                      "timeout"]:
      raise cerr(s.line, "@" & ann.name & " is only valid on define")
    else:
      raise cerr(s.line, "unknown annotation: @" & ann.name)
  withRetry(c, retryN):
    c.emit("krn_line(" & $s.line & ");")
    let base = c.tmps.len
    case s.cmd
    of "__expr":
      let xe = c.genExpr(s.args[0])
      c.updateLast(xe)
      c.releaseTmps(base)
    of "set":
      if s.args.len < 2:
        raise cerr(s.line, "set requires 2 arguments")
      let xs = c.genSetValue(s.args[0], s.args[1], s.line)
      c.updateLast(xs)
      c.releaseTmps(base)
    of "return":
      if c.inProc:
        if s.args.len > 0 and c.tryTailReturn(s.args[0], base):
          discard
        else:
          var t: string
          if s.args.len > 0:
            t = c.genExpr(s.args[0])
          else:
            t = c.fresh("t")
            c.tmps.add(t)
            c.emit("KRN_Value *" & t & " = krn_str_c(\"\");")
          c.updateLast(t)
          c.releaseTmps(base)
          c.emitPops(c.handlerDepth)
          c.emit("krn_free_env(env);")
          c.emit("goto _end;")
      else:
        if s.args.len > 0:
          discard c.genExpr(s.args[0])
        c.releaseTmps(base)
        c.emitPops(c.handlerDepth)
        c.emit("krn_release(_last);")
        c.emit("krn_free_env(env);")
        c.emit("return 0;")
    of "break":
      if c.loopDepth > 0:
        c.emitPops(c.handlerDepth - c.loopBases[^1])
        c.emit("break;")
      else:
        c.emitPops(c.handlerDepth)
        c.emit("krn_release(_last);")
        c.emit("_last = krn_str_c(\"\");")
        c.emit("krn_free_env(env);")
        c.emit("goto _end;")
    of "try":
      if s.args.len != 1:
        raise cerr(s.line, "try expects 1 args, got " & $s.args.len)
      let xt = c.genTryValue(s.args[0], s.line)
      c.updateLast(xt)
      c.releaseTmps(base)
    of "if":
      if s.args.len < 2:
        raise cerr(s.line, "if expects at least 2 args, got " & $s.args.len)
      var conds: seq[Arg] = @[s.args[0]]
      var bodies: seq[Program] = @[c.genIfBody(s.args[1], s.line)]
      var elseBody: Program = @[]
      var hasElse = false
      var i = 2
      if i < s.args.len and
          not (s.args[i].kind == argWord and
               (s.args[i].word == "elif" or s.args[i].word == "else")):
        elseBody = c.genIfBody(s.args[2], s.line)
        hasElse = true
      else:
        while i < s.args.len:
          if s.args[i].kind == argWord and s.args[i].word == "elif":
            if i + 2 >= s.args.len:
              raise cerr(s.line, "malformed if: elif needs a condition and a body")
            conds.add(s.args[i + 1])
            bodies.add(c.genIfBody(s.args[i + 2], s.line))
            i += 3
          elif s.args[i].kind == argWord and s.args[i].word == "else":
            if i + 1 >= s.args.len:
              raise cerr(s.line, "malformed if: else needs a body")
            elseBody = c.genIfBody(s.args[i + 1], s.line)
            hasElse = true
            break
          else:
            inc i
      c.emit("krn_release(_last);")
      c.emit("_last = krn_str_c(\"\");")
      c.emitBranches(conds, bodies, elseBody, hasElse, 0)
    of "while", "iter":
      if s.args.len != 2:
        raise cerr(s.line, s.cmd & " expects 2 args, got " & $s.args.len)
      if s.args[1].kind != argBlock:
        raise cerr(s.line, s.cmd & " body must be a block {...} in compiled v1")
      let wbody = analyzeProg(s.args[1].body)
      c.emit("while (1) {")
      c.emit("krn_check_timeout();")
      let b2 = c.tmps.len
      var cc = c.genCondLoop(s.args[0], s.line)
      var vv = c.fresh("c")
      c.emit("int " & vv & " = krn_truthy(" & cc & ");")
      c.releaseTmps(b2)
      c.emit("if (!" & vv & ") break;")
      inc c.loopDepth
      c.loopBases.add(c.handlerDepth)
      c.genStmts(wbody)
      c.loopBases.setLen(c.loopBases.len - 1)
      dec c.loopDepth
      c.emit("}")
      c.emit("krn_release(_last);")
      c.emit("_last = krn_str_c(\"\");")
    of "loop":
      if s.args.len != 1:
        raise cerr(s.line, "loop expects 1 args, got " & $s.args.len)
      if s.args[0].kind != argBlock:
        raise cerr(s.line, "loop body must be a block {...} in compiled v1")
      c.emit("while (1) {")
      c.emit("krn_check_timeout();")
      inc c.loopDepth
      c.loopBases.add(c.handlerDepth)
      c.genStmts(analyzeProg(s.args[0].body))
      c.loopBases.setLen(c.loopBases.len - 1)
      dec c.loopDepth
      c.emit("}")
      c.emit("krn_release(_last);")
      c.emit("_last = krn_str_c(\"\");")
    of "syscall":
      let ys = c.genSyscall(s)
      c.updateLast(ys)
      c.releaseTmps(base)
    of "import":
      raise cerr(s.line, "nested import is not compilable in v1")
    of "evolve":
      raise cerr(s.line, s.cmd & " is not compilable in v1")
    of "define":
      raise cerr(s.line, "nested define is not compilable in v1")
    else:
      let zs = c.genCallValue(s.cmd, s.args, s.line)
      c.updateLast(zs)
      c.releaseTmps(base)

proc genStmts(c: var Ctx, p: Program) =
  for s in p:
    c.genStmt(s)

# Post-pass C indentation (readable --emit-c). String-aware brace
# scan: emitted string literals never span lines (cStr escapes
# newlines), so per-line stripping is safe.
proc indentC(src: string): string =
  var depth = 0
  for raw in src.splitLines():
    let s = raw.strip()
    if s == "":
      result &= "\n"
      continue
    var lead = 0
    while lead < s.len and s[lead] == '}':
      inc lead
    depth = max(0, depth - lead)
    result &= "  ".repeat(depth) & s & "\n"
    var opens = 0
    var closes = 0
    var i = 0
    var inStr = false
    var inChr = false
    while i < s.len:
      let ch = s[i]
      if inStr:
        if ch == '\\':
          inc i
        elif ch == '"':
          inStr = false
      elif inChr:
        if ch == '\\':
          inc i
        elif ch == '\'':
          inChr = false
      elif ch == '"':
        inStr = true
      elif ch == '\'':
        inChr = true
      elif ch == '/' and i + 1 < s.len and s[i + 1] == '/':
        break
      elif ch == '{':
        inc opens
      elif ch == '}':
        inc closes
      inc i
    depth += opens - closes + lead

proc compileProgram*(src: string): string =
  var c = Ctx(body: "", funcs: "", tmp: 0, loopDepth: 0, tmps: @[],
              reg: initTable[string, Define](), order: @[],
              inProc: false, rootExpr: "env", procName: "", procParams: @[],
              tailOpt: false, wantCheck: false,
              handlerDepth: 0, loopBases: @[], imports: @[])
  # Pass 1: register every top-level define — essentials first so user
  # code wins on collision, exactly like re-registerCmd. Nested defines
  # stay refused (registration would be order-dependent at runtime).
  # Top-level imports splice inline first (cycle-guarded, hermetic).
  let essProg = parse(tokenize(essentialsSource()))
  let userProg = expandProg(parse(tokenize(src)), c)
  var essTop: Program = @[]
  for s in essProg:
    if s.cmd == "define":
      c.collectDefine(s)
    else:
      essTop.add(s)
  var userTop: Program = @[]
  for s in userProg:
    if s.cmd == "define":
      c.collectDefine(s)
    else:
      userTop.add(s)
  # Pass 2: forward declarations (mutual recursion included), bodies,
  # then essentially-booted top-level statements as main.
  for nm in c.order:
    let d = c.reg[nm]
    c.funcs &= "KRN_Value *" & d.cname &
      "(KRN_Env *root, int argc, KRN_Value **argv);\n"
  for nm in c.order:
    c.genDefine(c.reg[nm])
  c.rootExpr = "env"
  c.genStmts(essTop)
  c.genStmts(userTop)
  result = "#include \"kronyn_rt.h\"\n" &
    "\n" &
    c.funcs &
    "\n" &
    "int main(int argc, char *argv[]) {\n" &
    "KRN_Env *env = krn_new_env(0);\n" &
    "krn_init(argc - 1, argv + 1);\n" &
    "KRN_Value *_last = krn_str_c(\"\");\n" &
    c.body &
    "goto _end;\n" &
    "_end:;\n" &
    "krn_release(_last);\n" &
    "krn_free_env(env);\n" &
    "return 0;\n" &
    "}\n"
  result = indentC(result)
