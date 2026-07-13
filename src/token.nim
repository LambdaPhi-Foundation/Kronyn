type
  TokenKind* = enum
    tkWord,
    tkString,
    tkSub,
    tkBlock,
    tkDollar,
    tkDot,
    tkLParen,
    tkRParen,
    tkComma,
    tkNewline,

    #operators
    tkPlus, tkMinus, tkStar, tkSlash,              # +, -, *, /
    tkEqEq, tkBangEq, tkLt, tkGt,                  # ==, !=, <, >
    tkLtEq, tkGtEq,                                # <=, >=
    tkAnd, tkOr, tkBang,                           # &, |, !
    tkDotDot,                                      # .. (some concat type shit)

    tkEof

  Token* = object
    kind*: TokenKind
    lexeme*: string
    line*: int

proc `$`*(t: Token): string =
  "[" & $t.kind & " | " & t.lexeme & "]"
