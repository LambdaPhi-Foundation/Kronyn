import token, ast, lexer

type 
  Parser* = object
    tokens*: seq[Token]
    pos*: int

proc newParser*(token: seq[Token]): Parser =
  Parser(tokens: token, pos: 0)

#------HELPER FUNCTIONS--------------

proc peek*(p: Parser): Token =
  p.tokens[p.pos]

proc advance*(p: var Parser): Token =
  result = p.tokens[p.pos]
  inc p.pos

proc isAtEnd*(p: Parser): bool =
  p.peek().kind == tkEof

proc skipNewlines*(p: var Parser) = 
  while p.peek().kind == tkNewline:
    discard p.advance()

proc isOperator(t: Token): bool =
  t.kind in {tkPlus, tkMinus, tkStar, tkSlash,
              tkEqEq, tkBangEq, tkLt, tkGt,
              tkLtEq, tkGtEq, tkAnd, tkOr, tkBang, tkDotDot}

proc opStr(t: Token): string =
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

#--- Declare ahead cause shit's ain't Java --------------------------
proc parseChainArgs*(p: var Parser): seq[Arg]
proc parseArg*(p: var Parser): Arg
proc parsePrimary*(p:var Parser): Arg
proc parseChainCall*(p: var Parser): ChainCall
proc parseAnnotation(p: var Parser): seq[ChainCall]

proc collectChainCall(p: var Parser): seq[ChainCall] =
  while p.peek().kind == tkDot:
    discard p.advance()
    result.add(p.parseChainCall())

proc attachChain(p: var Parser, base: Arg): Arg =
  let calls = p.collectChainCall()
  if calls.len == 0: base else: chainArg(base, calls)


proc parseChainCall*(p: var Parser): ChainCall =
  let line = p.peek().line
  let name = p.advance().lexeme
  var args: seq[Arg]
  if p.peek().kind == tkLParen:
    discard p.advance()
    args = p.parseChainArgs()
    discard p.advance()
  var retType = ""
  if p.peek().kind == tkColon:
    discard p.advance()
    if p.peek().kind != tkWord:
      raise newException(ValueError,
        "line " & $p.peek().line & ": expected return type name after ':'")
    retType = p.advance().lexeme
  ChainCall(name: name, args: args, retType: retType, line: line)

proc parseTypedParam(p: var Parser, base: Arg): Arg =
  discard p.advance()
  if p.peek().kind != tkWord:
    raise newException(ValueError,
      "line " & $p.peek().line & ": expected type name after ':'")
  let tname = p.advance().lexeme
  case base.kind
  of argWord: typedParamArg(base.word, tname)
  of argVar: typedParamArg(base.name, tname)
  else:
    raise newException(ValueError,
      "line " & $base.line & ": type annotations only allowed on parameter names")

proc parseChainArgs*(p: var Parser): seq[Arg] =
  let line = p.peek().line
  if p.peek().kind == tkRParen: return @[]
  var first = p.parseArg()
  if p.peek().kind == tkColon:
    first = p.parseTypedParam(first)
  result.add(first)
  while p.peek().kind == tkComma:
    discard p.advance()
    var next = p.parseArg()
    if p.peek().kind == tkColon:
      next = p.parseTypedParam(next)
    result.add(next)

proc parseDotChain(p: var Parser, receiver: string): Arg {.deprecated.} =
  let line = p.peek().line
  if p.peek().kind notin {tkDot, tkLParen}:
    return wordArg(receiver)
  var calls: seq[ChainCall]
  if p.peek().kind == tkLParen:
    discard p.advance()
    let args = p.parseChainArgs()
    discard p.advance()
    calls.add(ChainCall(name: receiver, args: args, line: line))
    while p.peek().kind == tkDot:
      discard p.advance()
      calls.add(p.parseChainCall())
    return chainArg(wordArg(""), calls)
  while p.peek().kind == tkDot:
    discard p.advance()
    calls.add(p.parseChainCall())
  chainArg(wordArg(receiver), calls)

proc parsePrimary*(p: var Parser): Arg =
  let line = p.peek().line
  let t = p.peek()
  case t.kind
  of tkBang:
    discard p.advance()
    return infixArg(wordArg(""), "!", p.parsePrimary())

  of tkString:
    discard p.advance()
    return p.attachChain(strArg(t.lexeme))

  of tkSub:
    discard p.advance()
    return p.attachChain(subArg(t.lexeme))

  of tkBlock:
    discard p.advance()
    return p.attachChain(blockArg(t.lexeme))

  of tkDollar:
    discard p.advance()
    return p.attachChain(varArg(t.lexeme))

  of tkWord:
    discard p.advance()
    if p.peek().kind == tkLParen:
      discard p.advance()
      let args = p.parseChainArgs()
      discard p.advance()
      var calls = @[ChainCall(name: t.lexeme, args: args, retType: "", line: line)]
      calls.add(p.collectChainCall())
      if p.peek().kind == tkColon:
        discard p.advance()
        if p.peek().kind != tkWord:
          raise newException(ValueError,
            "line " & $p.peek().line & ": expected return type name after ':'")
        calls[0].retType = p.advance().lexeme
      return chainArg(wordArg(""), calls)
    return p.attachChain(wordArg(t.lexeme))

  else:
    discard p.advance()
    return wordArg(t.lexeme)

proc parseArg*(p: var Parser): Arg =
  let line = p.peek().line
  let left = p.parsePrimary()
  if isOperator(p.peek()):
    let op = opStr(p.advance())
    let right = p.parsePrimary()
    return infixArg(left, op, right)
  left

proc parseAnnotation(p: var Parser): seq[ChainCall] =
  while p.peek().kind == tkAt:
    discard p.advance()
    result.add(p.parseChainCall())
    p.skipNewlines()

proc parseStmt*(p: var Parser): Stmt =
  let annotations = p.parseAnnotation()
  let line = p.peek().line
  let savedPos = p.pos
  let first = p.parseArg()
  if first.kind in {argChain, argInfix} and p.peek().kind in {tkNewline, tkEof}:
    return Stmt(cmd: "__expr", args: @[first], annotations: annotations, line: line)
  p.pos = savedPos
  let cmd = p.advance().lexeme
  var args: seq[Arg]
  if p.peek().kind == tkLParen:
    discard p.advance()
    for a in p.parseChainArgs():
      args.add(a)
    if p.peek().kind == tkRParen:
      discard p.advance()
    else:
      raise newException(ValueError,
        "line " & $p.peek().line & ": expected ')' to close call arguments")
  while p.peek().kind notin {tkNewline, tkEof}:
    args.add(p.parseArg())
  Stmt(cmd: cmd, args: args, annotations: annotations, line: line)

#------ And finally ------------------------------
proc parse*(tokens: seq[Token]): Program =
  var p = newParser(tokens)
  while not p.isAtEnd():
    p.skipNewlines()
    if p.isAtEnd(): break
    result.add(p.parseStmt())
  
  



 
