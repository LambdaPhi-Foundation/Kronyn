import lexer, parser, eval, token, ast

let src = """ 
import "stdlib.kr"

syscall io.outputln "enter a filename: "
set path [syscall io.input]
set exists [syscall fs.exists path]
if [exists == "true"] {
  set contents [syscall fs.read path]
  syscall io.outputln contents
}

if [exists == "false"] {
  syscall io.outputln "file not found"
}
"""


try:
  let tokens = tokenize(src)
  let program = parse(tokens)

  let interpreter = newInterpreter()
  discard interpreter.eval(program)

except Exception as e:
  echo "Error: ", e.msg