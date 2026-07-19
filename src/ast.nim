type
  ArgKind* = enum
    argWord,            # bare word literal
    argString,          # "hello"
    argSub,             # [...] evaluated
    argBlock,           # {...} lazy
    argVar,             # $name
    argChain,           # x.method().method()
    argInfix            # x + y, x > y

  ChainCall* = object
    name*: string
    args*: seq[Arg]

  Arg* = ref object
    line*: int
    case kind*: ArgKind
    of argWord: word*: string
    of argString: str*: string
    of argSub: sub*: string
    of argBlock: body*: string
    of argVar: name*: string
    of argChain:
      receiver*: Arg
      calls*: seq[ChainCall]
    of argInfix:
      left*: Arg
      op*: string
      right*: Arg

  Stmt* = object
    cmd*: string
    args*: seq[Arg]
    line*: int
    
  Program* = seq[Stmt]

proc wordArg*(s: string): Arg = Arg(kind: argWord, word: s)
proc strArg*(s: string): Arg = Arg(kind: argString, str: s)
proc subArg*(s: string): Arg = Arg(kind: argSub, sub: s)
proc blockArg*(s: string): Arg = Arg(kind: argBlock, body: s)
proc varArg*(s: string): Arg = Arg(kind: argVar, name: s)
proc chainArg*(r: Arg, calls: seq[ChainCall]): Arg =
  Arg(kind: argChain, receiver: r, calls: calls)
proc infixArg*(l: Arg, op: string, r: Arg): Arg =
  Arg(kind: argInfix, left: l, op: op, right: r)
    
    



