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

#----declare first cause shit's ain't C -----------------------

proc eval*(env: Env, program: Program): Value
proc evalStmt*(env: Env, stmt: Stmt): Value
proc evalArg*(env: Env, arg: Arg): Value 
proc evalSub*(env: Env, src: string): Value
proc evalBlock*(env: Env, src: string): Value

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
      let v = env.getVar(arg.word)
      if v != "": return v
      arg.word
    
    of argSub:
      env.evalSub(arg.sub)

    of argBlock:
      arg.body

    of argChain:
      var val = env.getVar(arg.receiver)
      if val == "": val = arg.receiver
      for call in arg.calls:
        val = env.evalChainCall(val, call)
      val

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
  for top in program:
    case top.kind
      of tlStmt:
        result = env.evalStmt(top.stmt)
      of tlBlock:
        raise newException(ValueError,
          "nested @blocks are not allowed")

proc evalSub*(env: Env, src: string): Value =
  let tokens = tokenize(src)
  var p = newParser(tokens)
  p.skipNewLines()
  let first = parser.peek(p)
  if first.kind == tkWord and first.lexeme in ["syscall", "return", "evolve", "import"]:
    let stmt = p.parseStmt()
    return env.evalStmt(stmt)

  let arg = p.parseArg()
  env.evalArg(arg)

proc evalBlock*(env: Env, src: string): Value =
  let tokens = tokenize(src)
  let program = parse(tokens)
  let child = newEnv(env)
  try: result = child.evalInner(program)
  except ReturnSignal as r: result = r.value

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

      env.registerCmd(name, proc(env: Env, args: seq[Value]): Value =
        let child = newEnv(env)
        for i, p in captured:
          if i < args.len:
            child.setVar(p, args[i])
        try:
          result = child.evalBlock(body)
        except ReturnSignal as r:
          result = r.value)
      
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


proc eval*(env: Env, program: Program): Value =
  var blockMap: Table[string, int]
  for i, top in program:
    if top.kind == tlBlock:
      blockMap[top.label] = i
      

  for top in program:
    if top.kind == tlBlock: continue
    try:
      result = env.evalStmt(top.stmt)
    except GotoSignal as g:
      var pc = blockMap.getOrDefault(g.label, -1)
      if pc == -1:
        raise newException(ValueError, "undefined block: " & g.label)
      while pc >= 0 and pc < program.len:
        let top = program[pc]
        if top.kind != tlBlock:
          inc pc
          continue
        try:
          let tokens = tokenize(top.body)
          let prog = parse(tokens)
          result = env.evalInner(prog)
          break
        except GotoSignal as g2:
          pc = blockMap.getOrDefault(g2.label, -1)
          if pc == -1:
            raise newException(ValueError, "undefined block: " & g2.label)
        except ReturnSignal as r:
          return r.value
      return result

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
      return env.evalBlock(arg[1])
    elif arg.len > 2:
      return env.evalBlock(arg[2])
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


