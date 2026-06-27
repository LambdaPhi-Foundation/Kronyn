type
  TokenKind* = enum 
    tkWord,
    tkString,
    tkSub,
    tkBlock,
    tkDot,
    tkLParen,
    tkRParen,
    tkComma,
    tkNewline,

    tkPlus, tkMinus, tkStar, tkSlash,                      # + - * /
    tkEqEq, tkBangEq, tkLt, tkGt, tkLtEq, tkGtEq           # == != < > <= >= 
    tkAnd, tkOr, tkBang,                                    # & | !
    tkDotDot,                                                # .. (some concat type shit)

    tkAt,                                                   # @
    tkColon,                                                # :
    
    tkSyscall,                                              # do some real stuff 
    tkImport,                                               # do some more real stuff

    tkEof



  Token* = object
    kind*: TokenKind
    lexeme*: string
    line*: int

proc `$`*(t: Token): string =
  "[" & $t.kind & " | " & t.lexeme & "]"