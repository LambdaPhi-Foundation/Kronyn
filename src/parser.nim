import token, ast

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

proc isAtEnd(p: Parser): bool =
  p.peek().kind == tkEof

proc skipNewLines*(p: var Parser) = 
  while p.peek().kind == tkNewline:
    discard p.advance()


#----- dot chain parsinf ----------------------------------

proc parseChainArgs(p: var Parser): seq[Arg]
proc parseArg*(p: var Parser): Arg 

proc parseChainCall(p: var Parser): ChainCall =
  let name = p.advance().lexeme
  var args: seq[Arg]
  if p.peek().kind == tkLParen:
    discard p.advance()
    args = p.parseChainArgs()
    discard p.advance()
  ChainCall(name: name, args: args)

proc parseChainArgs(p: var Parser): seq[Arg] =
  if p.peek().kind == tkRParen: return @[]
  result.add(p.parseArg())
  while p.peek().kind == tkComma:
    discard p.advance()
    result.add(p.parseArg())

proc tryParseChain(p: var Parser, receiver: string): Arg = 
  if p.peek().kind == tkLParen:
    discard p.advance()
    var calls: seq[ChainCall]
    let args = p.parseChainArgs()
    discard p.advance()
    calls.add(ChainCall(name: receiver, args: args))
    return chainArg("", calls)

  if p.peek().kind != tkDot:
    return wordArg(receiver)
  var calls: seq[ChainCall]
  while p.peek().kind == tkDot:
    discard p.advance()
    calls.add(p.parseChainCall())
  chainArg(receiver, calls)

proc parsePrimary(p:var Parser): Arg =
  let t = p.peek()
  case t.kind
    of tkBang:
      discard p.advance()
      let operand = p.parsePrimary()
      return infixArg(wordArg(""), "!", operand)    # unary, bitch
      
    of tkString:
      discard p.advance()
      if p.peek().kind == tkDot:
        var calls: seq[ChainCall]
        while p.peek().kind == tkDot:
          discard p.advance()
          calls.add(p.parseChainCall())
        return chainArg(t.lexeme, calls)
      return strArg(t.lexeme)
    
    of tkSub:
      discard p.advance()
      if p.peek().kind == tkDot:
        var calls: seq[ChainCall]
        while p.peek().kind == tkDot:
          discard p.advance()
          calls.add(p.parseChainCall())
        return chainArg(t.lexeme, calls)
      return subArg(t.lexeme)

    of tkBlock:
      discard p.advance()
      return blockArg(t.lexeme)
    
    of tkWord:
      discard p.advance()
      return p.tryParseChain(t.lexeme)

    else:
      discard p.advance()
      return wordArg(t.lexeme)
  
proc isOperator(t: Token): bool =
  t.kind in {tkPLus, tkMinus, tkStar, tkSlash,
            tkEqEq, tkBangEq,
            tkLt, tkGt, tkLtEq, tkGtEq,
            tkAnd, tkOr, tkDotDot}

proc opString(t: Token): string =
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
    of tkDotDot: ".."
    else: ""

proc parseArg*(p: var Parser): Arg =
  var left = p.parsePrimary()

  if isOperator(p.peek()):
    let op = opString(p.advance())
    let right = p.parsePrimary()
    return infixArg(left, op, right)

  left

# ----------statement parsing--------------------------------

proc parseStmt*(p: var Parser): Stmt =
  let cmd = p.advance().lexeme
  var args: seq[Arg]

  while p.peek().kind notin {tkNewline, tkEof}:
    args.add(p.parseArg())

  Stmt(cmd: cmd, args: args)



proc parseBlock(p: var Parser): TopLevel =
  let name = p.advance().lexeme
  let body = p.advance().lexeme
  TopLevel(kind: tlBlock, label: name, body: body)

#-------entry ------------------------------------------------

proc parse*(tokens: seq[Token]): Program =
  var p = newParser(tokens)
  while not p.isAtEnd():
    p.skipNewlines()
    if p.isAtEnd(): break
    if p.peek().kind == tkAt:
      discard p.advance()
      result.add(p.parseBlock())
    else:
      result.add(TopLevel(kind: tlStmt, stmt: p.parseStmt()))



 
