import std/rdstdin

proc main() =
  var
    x: int
    y: int

  x = readLineFromStdin("Enter a number: ").parseInt()
  y = 12

  echo x, y

when isMainModule:
  main()
