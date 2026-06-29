import token, ast, lexer, parser, tables, strutils, os 

type Value* = string

proc truthy*(v: Value): bool =
  v != "" and v != "0" and v != "false"

proc isInt*(v: Value): bool =
  try: discard parseInt(v); true
  except: false

#------environment let'sssss goooo ----------------------

type
  CommandFn* = proc(env: Env, args: seq[Value]): Value 

  Env* = ref object
    vars*: Table[string, Value]
    cmds*: Table[string, CommandFn]
    parent*: Env

proc newEnv*(parent: Env = nil): Env =
  Env(vars: initTable[string, Value](),
  cmds: initTable[string, CommandFn](),
  parent: parent)

proc getVar*(env: Env, name: string): Value =
  if name in env.vars: return env.vars[name]
  if env.parent != nil: return env.parent.getVar(name)
  ""

proc setVar*(env: Env, name: string, val: Value) =
  env.vars[name] = val

proc getCmd*(env: Env, name: string): CommandFn =
  if name in env.cmds: return env.cmds[name]
  if env.parent != nil: return env.parent.getCmd(name)
  nil

proc registerCmd*(env: Env, name: string, fn: CommandFn) = 
  env.cmds[name] = fn

proc hasVar*(env: Env, name: string): bool =
  if name in env.vars: return true
  if env.parent != nil: return env.parent.hasVar(name)
  false

#----declare first cause shit's ain't C -----------------------

proc eval*(env: Env, program: Program): Value
proc evalStmt*(env: Env, stmt: Stmt): Value
proc evalArg*(env: Env, arg: Arg): Value 
proc evalSub*(env: Env, src: string): Value
proc evalBlock*(env: Env, src: string, createChild: bool = true): Value
proc evalArgChain(env: Env, arg: Arg): Value 
proc evalBlockBody*(env: Env, src: string): Value 

#------- Return type shit?------------------------------------

type 
  ReturnSignal* = ref object of CatchableError
    value*: Value

  GotoSignal* = ref object of CatchableError
    label*: string

#------- Evaluate the Arg ---------------------------------

proc evalChainCall(env: Env, receiver: Value, call: ChainCall): Value =
  var args = @[receiver]
  for a in call.args:
    args.add(env.evalArg(a))
  let fn = env.getCmd(call.name)
  if fn == nil:
    raise newException(ValueError, "unknown method: " & call.name)

  fn(env, args)

  
proc callFn(env: Env, params: seq[string], body: string, args: seq[Value]): Value =
  let child = newEnv(env)
  for i, p in params:
    if i < args.len:
      child.setVar(p, args[i])
  try:
    result = child.evalBlockBody(body)
  except ReturnSignal as r:
    result = r.value


proc substituteVars*(env: Env, s: string): Value =
  var result = ""
  var i = 0

  while i < s.len:
    let c = s[i]

    if c == '$' and i + 1 < s.len:
      inc i

      if s[i] == '{':
        inc i 
        var name = ""
        while i < s.len and s[i] != '}':
          name.add(s[i])
          inc i

        if i < s.len and s[i] == '}':
          inc i
        else:
          result.add("${" & name)
        result.add(env.getVar(name))

      else:
        var name = ""
        while i < s.len and s[i] in {'a'..'z', 'A'..'Z', '0'..'9', '_'}:
          name.add(s[i])
          inc i

        if name.len > 0:
          result.add(env.getVar(name))
        else:
          result.add('$')

    else:
      result.add(c)
      inc i

  result

proc evalArg*(env: Env, arg: Arg): Value =
  
  case arg.kind
    of argString:
      arg.str

    of argWord:
      if env.hasVar(arg.word):
        return env.getVar(arg.word)
      arg.word
    
    of argSub:
      env.evalSub(arg.sub)

    of argBlock:
      arg.body

    of argChain:
      env.evalArgChain(arg)

    of argInfix:
      let l = env.evalArg(arg.left)
      let r = env.evalArg(arg.right)
      case arg.op
        of "+":
          if l.isInt() and r.isInt(): $(parseInt(l) + parseInt(r))
          else: l & r
        of "-": $(parseInt(l) - parseInt(r))
        of "*": $(parseInt(l) * parseInt(r))
        of "/": $(parseInt(l) div parseInt(r))
        of "..": l & r
        of "==": 
          if l == r: "true" else: "false"
        of "!=": 
          if l != r: "true" else: "false"
        of "<": 
          if parseInt(l) < parseInt(r): "true" else: "false"
        of ">": 
          if parseInt(l) > parseInt(r): "true" else: "false"
        of "<=": 
          if parseInt(l) <= parseInt(r): "true" else: "false"
        of ">=": 
          if parseInt(l) >= parseInt(r): "true" else: "false"
        of "&&": 
          if l.truthy() and r.truthy(): "true" else: "false"
        of "||": 
          if l.truthy() or r.truthy(): "true" else: "false"
        of "!": 
          if r.truthy(): "false" else: "true"
        else: ""

#-----substitute and evaluation stuff ----------------------------

proc evalInner(env: Env, program: Program): Value =
  var localMap: Table[string, int]
  for i, top in program:
    if top.kind == tlBlock:
      localMap[top.label] = i 

  var pc = 0
  while pc < program.len:
    let top = program[pc]
    case top.kind
      of tlStmt:
        try:
          result = env.evalStmt(top.stmt)
          inc pc
        except GotoSignal as g:
          if g.label in localMap:
            pc = localMap[g.label]
          else:
            raise

        except ReturnSignal as r:
          result = r.value
          return
      of tlBlock:
        raise newException(ValueError,
          "Line " & $top.label & ": nested @blocks are not alloweds")

proc evalSub*(env: Env, src: string): Value =
  let tokens = tokenize(src)
  var p = newParser(tokens)
  p.skipNewLines()
  if p.isAtEnd(): return ""

  let first = p.peek()
  let second = if p.pos + 1 < p.tokens.len: p.tokens[p.pos + 1]
               else: Token(kind: tkEof)

  if second.kind in {tkPlus, tkMinus, tkStar, tkSlash,
                      tkEqEq, tkBangEq, tkLt, tkGt,
                      tkLtEq, tkGtEq, tkAnd, tkOr, tkDotDot}:
    let arg = p.parseArg()
    return env.evalArg(arg)

  if second.kind == tkDot:
    let arg = p.parseArg()
    return env.evalArg(arg)

  let stmt = p.parseStmt()
  env.evalStmt(stmt)
  

proc evalBlock*(env: Env, src: string, createChild: bool = true): Value =
  let tokens = tokenize(src)
  let program = parse(tokens)
  let runEnv = if createChild: newEnv(env) else: env
  result = runEnv.evalInner(program)

proc evalBlockBody*(env: Env, src: string): Value =
  let tokens = tokenize(src)
  let program = parse(tokens)

  var localMap: Table[string, int]
  for i, top in program:
    if top.kind == tlBlock:
      localMap[top.label] = i

  var pc = 0
  while pc < program.len:
    let top = program[pc]
    try:
      case top.kind
        of tlStmt:
          result = env.evalStmt(top.stmt)
          inc pc
        of tlBlock:
          inc pc
    except GotoSignal as g:
      if g.label in localMap:
        pc = localMap[g.label]
      else:
        raise 

    except ReturnSignal as r:
      result = r.value
      break

#---------statement evaluation -------------------------------


proc evalStmt*(env: Env, stmt: Stmt): Value =
  case stmt.cmd
  # The sacred intents MORRIS declares: SET, RETURN, EVOLVE, DEFINE, and also, new ones like SYSCALL and IMPORT
    of "return":
      let val = if stmt.args.len > 0: env.evalArg(stmt.args[0]) else: ""
      raise ReturnSignal(value: val)

    of "set":
      let val = env.evalArg(stmt.args[1])
      env.setVar(stmt.args[0].word, val)
      result = val

    of "evolve":
      let code = env.evalArg(stmt.args[0])
      result = env.evalSub(code)

    of "define":
      let name = stmt.args[0].word
      let defArg = stmt.args[1]
      let bodyArg = stmt.args[2]

      var paramNames: seq[string]
      if defArg.kind == argChain:
        if defArg.calls.len > 0:
          for a in defArg.calls[0].args:
            paramNames.add(a.word)

      let body = bodyArg.body
      let captured = paramNames 
      let capturedBody = body

      env.registerCmd(name, proc(env: Env, args: seq[Value]): Value =
        callFn(env, captured, capturedBody, args))
      
      return ""

    of "goto":
      let label = env.evalArg(stmt.args[0])
      raise GotoSignal(label: label)

    of "syscall":
      let callArg = stmt.args[0]
      if callArg.kind != argChain:
        raise newException(ValueError, "syscall expects namespace.method")

      let ns = callArg.receiver
      let meth = callArg.calls[0].name

      var args: seq[Value]
      for a in stmt.args[1..^1]:
        args.add(env.evalArg(a))

      case ns
        of "io":
          case meth
            of "outputln":
              echo args[0]
              result = ""
            of "output":
              write(stdout, args[0])
              result = ""
            of "input":
              result = readLine(stdin)
            else:
              raise newException(ValueError, "unknown io syscall: " & meth)

          
        of "fs":
          case meth
            of "read":
              if not fileExists(args[0]):
                raise newException(ValueError, "file not found: " & args[0])
              result = readFile(args[0])
            of "write":
              writeFile(args[0], args[1])
              result = ""
            of "exists":
              result = if fileExists(args[0]): "true" else: "false"
            of "append":
              let f = open(args[0], fmAppend)
              f.write(args[1])
              f.close()
              result = ""
            else:
              raise newException(ValueError, "Unknown fs syscall: " & meth)

        of "proc":
          case meth
            of "exit":
              let code = if args.len > 0: parseInt(args[0]) else: 0
              quit(code)
            else:
              raise newException(ValueError, "unknown proc syscall: " & meth)

        else:
          raise newException(ValueError, "unknown syscall namespace: " & ns)

    of "import":
      let path = env.evalArg(stmt.args[0])
      if not fileExists(path):
        raise newException(ValueError, "import: file not found: " & path)
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
        raise newException(ValueError, "unknown command: " & stmt.cmd)
      return fn(env, args)

proc evalArgChain(env: Env, arg: Arg): Value =
  var val: Value
  if env.hasVar(arg.receiver):
    val = env.getVar(arg.receiver)
  else:
    val = arg.receiver

  for call in arg.calls:
    val = env.evalChainCall(val, call)
  val


proc eval*(env: Env, program: Program): Value =
  var blockMap: Table[string, int]
  for i, top in program:
    if top.kind == tlBlock:
      blockMap[top.label] = i

  for top in program:
    if top.kind == tlStmt:
      try:
        result = env.evalStmt(top.stmt)
      except GotoSignal as g:
        raise newException(ValueError,
          "goto outside block: " & g.label)

  #Always go to main
  if "main" notin blockMap:
    return result

  var pc = blockMap["main"]

  while pc >= 0 and pc < program.len:
    let top = program[pc]
    case top.kind
      of tlStmt:
        inc pc
        continue
      of tlBlock:
        try:
          result = env.evalInner(parse(tokenize(top.body)))
          break
        except GotoSignal as g:
          if g.label notin blockMap:
            raise newException(ValueError, "undefined block: " & g.label)
          pc = blockMap[g.label]
        except ReturnSignal as r:
          result = r.value
          break


#------ some builtin stuff-----------------------------------

proc initKernel*(env: Env) = 
  env.registerCmd("writeln", proc(env: Env, args: seq[Value]): Value =
    echo args[0];result =  "")

  env.registerCmd("write", proc(env: Env, args: seq[Value]): Value =
    write(stdout, args[0]); "")

  env.registerCmd("input", proc(env: Env, args: seq[Value]): Value =
    readLine(stdin))

  env.registerCmd("if", proc(env: Env, arg: seq[Value]): Value =
    if arg[0].truthy():
      return env.evalBlockBody(arg[1])
    elif arg.len > 2:
      return env.evalBlockBody(arg[2])
    "")

  # Some string ops cause...You know...everything's a string :)

  env.registerCmd("toUpper", proc(env: Env, args: seq[Value]): Value =
    args[0].toUpper())

  env.registerCmd("toLower", proc(env: Env, args: seq[Value]): Value =
    args[0].toLower())

  env.registerCmd("len", proc(env: Env, args: seq[Value]): Value =
    $args[0].len)

  env.registerCmd("trim", proc(env: Env, args: seq[Value]): Value =
    args[0].strip())

#-------entry -------------------------------------------

proc newInterpreter*(): Env =
  let env = newEnv()
  env.initKernel()
  env


