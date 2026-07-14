import lexer, parser, ast, eval, os

when isMainModule:
  if paramCount() < 1:
    echo "usage: kronyn <file.kr>"
    quit(1)

  let interp = newInterpreter()

  let stdlibPath = getAppDir() / "stdlib.kr"
  if fileExists(stdlibPath):
    let src = readFile(stdlibPath)
    discard interp.eval(parse(tokenize(src)))

  let path = paramStr(1)
  if not fileExists(path):
    echo "error: file for found: " & path
    quit(1)

  try:
    let src = readFile(path)
    discard interp.eval(parse(tokenize(src)))
  except ValueError as e:
    echo "error: " & e.msg
    quit(1)
