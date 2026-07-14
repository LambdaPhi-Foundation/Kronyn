import token, ast, lexer, parser, tables, strutils, os, sequtils

#---- Value ---------------------------------------------
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
    returning*: bool
    retVal*: Value

proc newEnv*(parent: Env = nil): Env =
  Env(vars: initTable[string, Value](),
  cmds: initTable[string, CommandFn](),
  parent: parent,
  returning: false,
  retVal: "")

proc root*(env: Env): Env =
  if env.parent == nil: env else: env.parent.root()

proc getVar*(env: Env, name: string): Value =
  if name in env.vars: return env.vars[name]
  if env.parent != nil: return env.parent.getVar(name)
  ""

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

#----declare first cause shit's ain't C -----------------------

proc eval*(env: Env, program: Program): Value
proc evalStmt*(env: Env, stmt: Stmt): Value
proc evalArg*(env: Env, arg: Arg): Value
proc evalArgChain(env: Env, arg: Arg): Value 
proc evalSub*(env: Env, src: string): Value
proc evalBody*(env: Env, src: string): Value
proc callFn*(env: Env, params: seq[string], body: string, args: seq[Value]): Value

#------- Return type shit?(Depricated, but I did create some cool shit)---------

type 
  ReturnSignal* = ref object of CatchableError
    value*: Value

  GotoSignal* = ref object of CatchableError
    label*: string

#------- Evaluate the Arg ---------------------------------

proc evalChainCall*(env: Env, receiver: Value, call: ChainCall): Value =
  var args = @[receiver]
  for a in call.args:
    args.add(env.evalArg(a))
  let fn = env.getCmd(call.name)
  if fn == nil:
    raise newException(ValueError, "unknown method: " & call.name)

  fn(env, args)


proc callFn(env: Env, params: seq[string], body: string, args: seq[Value]): Value =
  let r = env.root()
  let child = newEnv(r)
  child.returning = false
  child.retVal = ""
  for i, p in params:
    if i < args.len:
      child.setVar(p, args[i])
  result = child.evalBody(body)
  if r.returning:
    result = child.retVal

proc evalArg*(env: Env, arg: Arg): Value =
  case arg.kind
    of argString: arg.str
    of argWord: arg.word
    of argVar: env.getVar(arg.name)
    of argSub: env.evalSub(arg.sub)
    of argBlock: arg.body

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

proc evalBody*(env: Env, src: string): Value =
  let tokens  = tokenize(src)
  let program = parse(tokens)
  env.eval(program)


#---------statement evaluation -------------------------------


proc evalStmt*(env: Env, stmt: Stmt): Value =
  let r = env.root()
  case stmt.cmd
  # The sacred intents MORRIS declares: SET, RETURN, EVOLVE, DEFINE, and also, new ones like SYSCALL and IMPORT
    of "return":
      let val = if stmt.args.len > 0: env.evalArg(stmt.args[0]) else: ""
      env.returning = true
      env.retVal = val
      return val

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

      var params: seq[string]
      if defArg.kind == argChain and defArg.calls.len > 0:
        for a in defArg.calls[0].args:
          case a.kind
          of argWord: params.add(a.word)
          
          of argVar: params.add(a.name)
          else: discard

      let body = bodyArg.body
      let captured = params 
      r.registerCmd(name, proc(env: Env, args: seq[Value]): Value =
                    callFn(env, captured, body, args))
      return ""


    of "syscall":
      let callArg = stmt.args[0]
      if callArg.kind != argChain:
        raise newException(ValueError, "syscall expects namespace.method")

      let ns = env.evalArg(callArg.receiver)
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
  var val = env.evalArg(arg.receiver)
  for call in arg.calls:
    val = env.evalChainCall(val, call)
  val


proc eval*(env: Env, program: Program): Value =
  for stmt in program:
    result = env.evalStmt(stmt)
    if env.returning: break


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
      return env.evalBody(arg[1])
    elif arg.len > 2:
      return env.evalBody(arg[2]))

  env.registerCmd("readln", proc(env: Env, args: seq[Value]): Value =
                                readLine(stdin))

  env.registerCmd("iter", proc(env: Env, args: seq[Value]): Value =
    let cond = args[0]
    let body = args[1]
    while env.evalSub(cond).truthy():
      result = env.evalBody(body)
      if env.root().returning: break
      return "")
                              

  # Some string ops cause...You know...everything's a string :)

  env.registerCmd("toUpper", proc(env: Env, args: seq[Value]): Value =
    args[0].toUpper())

  env.registerCmd("toLower", proc(env: Env, args: seq[Value]): Value =
    args[0].toLower())

  env.registerCmd("len", proc(env: Env, args: seq[Value]): Value =
    $args[0].len)

  env.registerCmd("trim", proc(env: Env, args: seq[Value]): Value =
    args[0].strip())

  env.registerCmd("ascii", proc(env: Env, args: seq[Value]): Value =
    if args[0].len == 0: return "0"
    $ord(args[0][0]))

  env.registerCmd("char", proc(env: Env, args: seq[Value]): Value =
    $chr(parseInt(args[0])))

  env.registerCmd("int", proc(env: Env, args: seq[Value]): Value =
    $parseInt(args[0]))

  env.registerCmd("str", proc(env: Env, args: seq[Value]): Value =
    args[0])

  env.registerCmd("slice", proc(env: Env, args: seq[Value]): Value =
    let s = parseInt(args[1])
    let e = parseInt(args[2])
    if s < 0 or e > args[0].len or s > e: ""
    else: args[0][s..e-1])

  env.registerCmd("index", proc(env: Env, args: seq[Value]): Value =
    let idx = parseInt(args[1])
    if idx < 0 or idx >= args[0].len:
      raise newException(ValueError, "index out of bounds")
    $args[0][idx])

  env.registerCmd("contains", proc(env: Env, args: seq[Value]): Value =
    if args[1] in args[0]: "true" else: "false")

  env.registerCmd("replace", proc(env: Env, args: seq[Value]): Value =
    args[0].replace(args[1], args[2]))

  env.registerCmd("split", proc(env: Env, args: seq[Value]): Value =
    args[0].split(args[1]).join(" "))

  env.registerCmd("concat", proc(env: Env, args: seq[Value]): Value =
    args[0] & args[1])

#------- entry -------------------------------------------

proc newInterpreter*(): Env =
  let env = newEnv()
  env.initKernel()
  env


