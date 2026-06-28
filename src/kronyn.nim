import lexer, parser, ast, eval, os

when isMainModule:
  if paramCount() < 1:
    echo "usage: kronyn <file.kr>"
    quit(1)

  let interp = newInterpreter()

  let stdlibPath = getAppDir() / "stdlib.kr"
  if fileExists(stdlibPath):
    let stdSrc = readFile(stdlibPath)
    let stdToks = tokenize(stdSrc)
    let stdProg = parse(stdToks)
    discard interp.eval(stdProg)

  let path = paramStr(1)
  if not fileExists(path):
    echo "error: file not found: " & path
    quit(1)

  let src = readFile(path)
  let tokens = tokenize(src)
  let program = parse(tokens)

  try:
    discard interp.eval(program)
  except ValueError as e:
    echo "error: " & e.msg
    quit(1)
  

