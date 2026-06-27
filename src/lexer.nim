import token, strutils

type Lexer* = object
  src*: string
  pos*: int
  line*: int

proc newLexer*(src: string): Lexer =
  Lexer(src: src, pos: 0, line: 1)

proc peek(l: Lexer, offsetL: int = 0): char =
  let i = l.pos + offsetL
  if i < l.src.len: l.src[i] else: '\0'

proc advance(l: var Lexer): char =
  result = l.src[l.pos]
  if result == '\n': inc l.line
  inc l.pos

proc skipWhitespace(l: var Lexer) =
  while l.pos < l.src.len:
    let c = l.peek()
    if c in {' ', '\t', '\r'}: discard l.advance()
    elif c == '#':
      while l.pos < l.src.len and l.peek() != '\n': discard l.advance()
    else: break

proc makeToken(l: Lexer, kind: TokenKind, lexeme: string): Token =
  Token(kind: kind, lexeme: lexeme, line: l.line)

proc lexString(l: var Lexer): Token =
  discard l.advance()
  var s = ""
  while l.pos < l.src.len and l.peek() != '"':
    let c = l.advance()
    if c == '\\':
      case l.advance()
        of 'n': s.add('\n')
        of 't': s.add('\t')
        of '"': s.add('"')
        of '\\': s.add('\\')
        else: s.add('\\')
    else: s.add(c)
  discard l.advance()
  l.makeToken(tkString, s)

proc lexNested(l: var Lexer, open, close: char, kind: TokenKind): Token =
  discard l.advance()
  var s = ""
  var depth = 1
  while l.pos < l.src.len and depth > 0:
    let c = l.advance()
    if c == open: inc depth; s.add(c)
    elif c == close:
      dec depth
      if depth > 0: s.add(c)
    else: s.add(c)
  l.makeToken(kind, s.strip())

proc lexWord(l: var Lexer): Token =
  var s = ""
  while l.pos < l.src.len and l.peek() notin {' ', '\t', '\r', '\n',
                                              '(', ')', ',', 
                                              '.', '"', '[', ']', 
                                              '{', '}', '#'}:
    s.add(l.advance())
  if s.len == 0:
    let c = l.advance()
    return l.makeToken(tkWord, $c)
  l.makeToken(tkWord, s)

proc nextToken*(l: var Lexer): Token =
  l.skipWhitespace()
  if l.pos >= l.src.len:
    return l.makeToken(tkEof, "")

  let c = l.peek()
  case c
    of '\n':
      discard l.advance()
      l.makeToken(tkNewline, "\\n")
    of '"': l.lexString()
    of '[': l.lexNested('[', ']', tkSub)
    of '{': l.lexNested('{', '}', tkBlock)
    of '(': discard l.advance(); l.makeToken(tkLParen, "(")
    of ')': discard l.advance(); l.makeToken(tkRParen, ")")
    of ',': discard l.advance(); l.makeToken(tkComma, ",")
    of '.':
      discard l.advance()
      if l.peek() == '.':
        discard l.advance()
        l.makeToken(tkDotDot, "..")
      else:
        l.makeToken(tkDot, ".")
    of '+':
      discard l.advance()
      l.makeToken(tkPLus, "+")
    of '-':
      discard l.advance()
      l.makeToken(tkMinus, "-")
    of '*':
      discard l.advance()
      l.makeToken(tkStar, "*")
    of '/':
      discard l.advance()
      l.makeToken(tkSlash, "/")
    of '!':
      discard l.advance()
      if l.peek() == '=':
        discard l.advance()
        l.makeToken(tkBangEq, "!=")
      else:
        l.makeToken(tkBang, "!")
    of '=':
      discard l.advance()
      if l.peek() == '=':
        discard l.advance()
        l.makeToken(tkEqEq, "=")
      else:
        l.makeToken(tkWord, "=")
    of '<':
      discard l.advance()
      if l.peek() == '=':
        l.makeToken(tkLtEq, "<=")
      else:
        l.makeToken(tkLt, ">")
    of '>':
      discard l.advance()
      if l.peek() == '=':
        discard l.advance()
        l.makeToken(tkGtEq, ">=")
      else:
        l.makeToken(tkGt, ">")
    of '&':
      discard l.advance()
      if l.peek() == '&':
        discard l.advance()
        l.makeToken(tkAnd, "&&")
      else:
        l.makeToken(tkWord, "&")
    of '|':
      discard l.advance()
      if l.peek() == '|':
        discard l.advance()
        l.makeToken(tkOr, "||")
      else:
        l.makeToken(tkWord, "|")
    of '@':
      discard l.advance()
      l.makeToken(tkAt, "@")
    of ':':
      discard l.advance()
      l.makeToken(tkColon, ":")
    else:
      l.lexWord()

proc tokenize*(src: string): seq[Token] =
  var l = newLexer(src)
  while true:
    let t = l.nextToken()
    result.add(t)
    if t.kind == tkEof: break

