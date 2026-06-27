type 
  ArgKind* = enum 
    argWord,
    argString,
    argSub,
    argBlock,
    argChain,
    argInfix

  ChainCall* = object
    name*: string
    args*: seq[Arg]

  Arg* = ref object
    case kind*: ArgKind
      of argWord: word*: string
      of argString: str*: string
      of argSub: sub*: string
      of argBlock: body*: string
      of argChain:
        receiver*: string
        calls*: seq[ChainCall]
      of argInfix:
        left*: Arg
        op*: string
        right*: Arg

  Stmt* = object
    cmd*: string
    args*: seq[Arg]

  TopLevelKind* = enum 
    tlStmt,
    tlBlock

  TopLevel* = object
    case kind*: TopLevelKind
      of tlStmt: stmt*: Stmt
      of tlBlock:
        label*: string
        body*: string

  Program* = seq[TopLevel]


proc wordArg*(s: string): Arg = Arg(kind: argWord, word: s)
proc strArg*(s: string): Arg = Arg(kind: argString, str: s)
proc subArg*(s: string): Arg = Arg(kind: argSub, sub: s)
proc blockArg*(s: string): Arg = Arg(kind: argBlock, body: s)
proc chainArg*(receiver: string, calls: seq[ChainCall]): Arg =
  Arg(kind: argChain, receiver: receiver, calls: calls)
proc infixArg*(left: Arg, op: string, right: Arg): Arg =
  Arg(kind: argInfix, left: left, op: op, right: right)



