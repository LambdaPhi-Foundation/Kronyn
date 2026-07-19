
# [*] Kronyn

**Kronyn** is an extensible, interpreted programming language that blends the "everything is a string" philosophy of [Tcl](https://www.tcl.tk/) with the structured "Intent" patterns of the [MORRIS standards](https://github.com/Stanislaw3737/MORRIS-shell). 

Written in **Nim**, Kronyn is designed for flexibility and extensibility, providing a bridge between a loose scripting environment and a rigid functional structure.

---

## 🏛 The Vision: A Language-Based OS
The ultimate goal of Kronyn is to transcend being a mere interpreter and instead serve as the core of a **Language-Based Operating System**. 

Inspired by the architectural purity of **Lisp Machines** and the **Oberon OS**, Kronyn aims to collapse the boundary between the programming language and the operating system. In this vision:
- The interpreter *is* the kernel.
- System resources are managed as language objects.
- The environment is entirely malleable, allowing the OS to be extended or modified in real-time using the language itself.

---

## [|] Philosophy
In Kronyn, **everything is a string**. However, unlike Tcl, Kronyn introduces a level of rigidity to prevent the "string soup" problem, utilizing three distinct ways to represent strings and a powerful dot-chaining system for operations.

### String Representations
| Syntax | Type | Description |
| :--- | :--- | :--- |
| `"..."` | **Literal** | A standard string literal. |
| `[...]` | **Inferred** | A string whose meaning/value is inferred or evaluated (similar to Tcl's `{}`). |
| `{...}` | **Block** | A block of string, typically split by newline characters. |

---

## [+] Language Features

### Intents & Functions
Kronyn distinguishes between general commands (**Intents**) and object-like methods (**Dot Functions**).

#### 1. Custom Intents
Intents are the primary way to extend the language.
```kronyn
define <name> proc(<param1>, <param2>) {
    # Logic goes here
}
```

#### 2. Dot Function Chaining
Kronyn supports method-style chaining, allowing you to call functions directly on values.
```kronyn
define <name> fn(<param1>, <param2>) {
    # Logic goes here
}

# Usage:
"Hello".reverse()
```

---

## [:] Examples

### [:.] Fibonacci Sequence
Demonstrating recursion and dot-chaining.
```kronyn
define fib fn(self) {
    if [$self == 0] {return 0} 
    elif [$self == 1] {return 1} 
    else {return [[$self - 1].fib() + [$self - 2].fib()]}
}

writeln 0.fib()
writeln 1.fib()
writeln 5.fib()
writeln 10.fib()
```

### [:.] String Reversal
Demonstrating loops, variable assignment, and string indexing.
```kronyn
define reverse fn(self) {
    set result ""
    set i [$self.len() - 1]
    loop {
        if [$i < 0] {break}
        set result [$result .. $self.index($i)]
        set i [$i - 1]
    }
    return $result
}

writeln "hello".reverse()
writeln "Kronyn".reverse()
```

### [:.] I/O & System Calls
```kronyn
# User Input
syscall io.output "enter your name: "
set name [syscall io.input]
writeln ["Hello " .. $name]

# File Operations
syscall fs.write "test.txt" "hello from Kronyn"
set contents [syscall fs.read "test.txt"]
writeln $contents
```

---

## [[]] Standard Library (Built-ins)

All core functions are defined in `stdlib.kr` and are imported automatically.

### [-] Control Flow
- `if` / `elif` / `else`: Conditional branching.
- `while`: Executes a block while a condition is truthy.
- `loop`: An infinite loop (use `break` to exit).
- `iter`: Iteration logic.

### [""] String Manipulation
- `.len()`: Returns string length.
- `.toUpper()` / `.toLower()`: Changes case.
- `.trim()`: Removes whitespace.
- `.slice(start, end)`: Extracts a substring.
- `.index(idx)`: Gets character at position.
- `.contains(str)`: Returns true/false.
- `.replace(old, new)`: Replaces text.
- `.split(delim)`: Splits string into a space-joined list.
- `concat` / `..`: Joins two strings.

### [&] Data Conversion & Math
- `int`: Converts string to integer.
- `str`: Ensures value is a string.
- `ascii`: Returns ASCII value of the first character.
- `char`: Converts an integer to an ASCII character.
- `mod`: Returns the remainder of a division.

---

## [=]Technical Architecture

- **Implementation Language:** [Nim](https://nim-lang.org/)
- **Current State:** Treewalk Interpreter.
- **Roadmap to OS:**
    - [ ] **Phase 1:** Transition to a **Bytecode Interpreter** for performance.
    - [ ] **Phase 2:** Expand the `stdlib.kr` and refine `syscall` interfaces.
    - [ ] **Phase 3:** Develop a minimal kernel/runtime to host the interpreter as the primary system interface.
    - [ ] **Phase 4:** Implement a fully integrated environment (The "Kronyn Machine").


## [~] Credits
Kronyn is heavily inspired by:
- **Tcl**: For the "everything is a string" philosophy.
- **MORRIS Standards**: For the implementation of "Intents".