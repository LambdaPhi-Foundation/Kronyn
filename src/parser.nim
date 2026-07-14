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

proc advance(p: var Parser): Token =
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

#--- Declare ahead cause shit's ain't C --------------------------
proc parseChainArgs*(p: var Parser): seq[Arg]
proc parseArg*(p: var Parser): Arg
proc parsePrimary*(p:var Parser): Arg

proc parseChainCall*(p: var Parser): ChainCall =
  let name = p.advance().lexeme
  var args: seq[Arg]
  if p.peek().kind == tkLParen:
    discard p.advance()
    args = p.parseChainArgs()
    discard p.advance()
  ChainCall(name: name, args: args)

proc parseChainArgs*(p: var Parser): seq[Arg] =
  if p.peek().kind == tkRParen: return @[]
  result.add(p.parseArg())
  while p.peek().kind == tkComma:
    discard p.advance()
    result.add(p.parseArg())

proc parseDotChain(p: var Parser, receiver: string): Arg =
  if p.peek().kind notin {tkDot, tkLParen}:
    return wordArg(receiver)
  var calls: seq[ChainCall]
  if p.peek().kind == tkLParen:
    discard p.advance()
    let args = p.parseChainArgs()
    discard p.advance()
    calls.add(ChainCall(name: receiver, args: args))
    while p.peek().kind == tkDot:
      discard p.advance()
      calls.add(p.parseChainCall())
    return chainArg("", calls)
  while p.peek().kind == tkDot:
    discard p.advance()
    calls.add(p.parseChainCall())
  chainArg(receiver, calls)

proc parsePrimary*(p: var Parser): Arg =
  echo "parsePrimary token: ", p.peek()
  
  let t = p.peek()
  case t.kind
  of tkBang:
    discard p.advance()
    return infixArg(wordArg(""), "!", p.parsePrimary())

  of tkString:
    discard p.advance()
    if p.peek().kind == tkDot:
      var calls: seq[ChainCall]
      while p.peek().kind == tkDot:
        discard p.advance()
        calls.add(p.parseChainCall())
      return chainArg(strArg(t.lexeme), calls)
    return strArg(t.lexeme)

  of tkSub:
    discard p.advance()
    if p.peek().kind == tkDot:
      var calls: seq[ChainCall]
      while p.peek().kind == tkDot:
        discard p.advance()
        calls.add(p.parseChainCall())
      return chainArg(subArg(t.lexeme), calls)
    return subArg(t.lexeme)

  of tkBlock:
    echo "HIT TKBLOCK"
    discard p.advance()
    return blockArg(t.lexeme)

  of tkDollar:
    discard p.advance()
    if p.peek().kind == tkDot:
      var calls: seq[ChainCall]
      while p.peek().kind == tkDot:
        discard p.advance()
        calls.add(p.parseChainCall())
      return chainArg(varArg(t.lexeme), calls)
    return varArg(t.lexeme)

  of tkWord:
    discard p.advance()
    if p.peek().kind == tkLParen:
      discard p.advance()
      let args = p.parseChainArgs()
      discard p.advance()
      var calls: seq[ChainCall]
      calls.add(ChainCall(name: t.lexeme, args: args))
      while p.peek().kind == tkDot:
        discard p.advance()
        calls.add(p.parseChainCall())
      return chainArg(wordArg(""), calls)
    if p.peek().kind == tkDot:
      var calls: seq[ChainCall]
      while p.peek().kind == tkDot:
        discard p.advance()
        calls.add(p.parseChainCall())
      return chainArg(wordArg(t.lexeme), calls)
    return wordArg(t.lexeme)

  else:
    discard p.advance()
    return wordArg(t.lexeme)

proc parseArg*(p: var Parser): Arg =
  let left = p.parsePrimary()
  if isOperator(p.peek()):
    let op = opStr(p.advance())
    let right = p.parsePrimary()
    return infixArg(left, op, right)
  left

proc parseStmt*(p: var Parser): Stmt =
  let cmd = p.advance().lexeme
  var args: seq[Arg]
  echo "parseStmt cmd=", cmd
  while p.peek().kind notin {tkNewline, tkEof}:
    echo "  next token: ", p.peek()
    args.add(p.parseArg())
  Stmt(cmd: cmd, args: args)

#------ And finally ------------------------------
proc parse*(tokens: seq[Token]): Program =
  var p = newParser(tokens)
  while not p.isAtEnd():
    p.skipNewlines()
    if p.isAtEnd(): break
    result.add(p.parseStmt())
  
  



 
