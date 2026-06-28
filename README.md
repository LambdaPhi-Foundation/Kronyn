

#  Kronyn

**Kronyn** is an extensible scripting language inspired by the architecture of [Tcl](https://www.tcl.tk/) and built upon the [MORRIS standards](https://github.com/Stanislaw3737/MORRIS-shell). 

Implemented in **Nim**, Kronyn aims for a minimal kernel where most of the language's power is derived from its own standard library (`stdlib.kr`), allowing it to be highly flexible and evolving.

## [->] Core Concepts

### "Everything is a String"
Following the Tcl philosophy, everything in Kronyn is conceptually a string. However, Kronyn introduces a level of rigidity through three distinct string types:

| Syntax | Type | Description |
| :--- | :--- | :--- |
| `"..."` | **Normal String** | A literal sequence of characters. |
| `[...]` | **Inferred String** | A string where the value is evaluated, substituted, or inferred. |
| `{...}` | **Block String** | A multiline string block separated by newline characters. |

### Intents and Dot Functions
Kronyn distinguishes between **Intents** (similar to Tcl commands) and **Functions** (supporting dot-chaining).

#### 1. Intents (`proc`)
Intents take arguments directly and are the primary way to define procedures.
```kr
define max proc(a, b) {
    if [a > b] {return a}
    if [b > a] {return b}
}

set x 10
set y 20
set maximum [max a b]
writeln "Maximum is " .. maximum
```

#### 2. Dot Functions (`fn`)
Inspired by [mshell](https://github.com/Stanislaw3737/mshell), Kronyn supports dot functions and chaining, allowing for a more object-oriented style of data manipulation.
```kr
define mult fn(self, a) {
    return [self * a]  # value is inferred via [ ]
}

set product [x.mult(y)]
writeln "Product is " .. product
```

---

## [*] Language Features

### [[]] Named Blocks & Control Flow
Kronyn does not use a traditional `main()` function. Instead, it uses **Named Blocks**. These blocks provide encapsulation and act as jump targets for flow control.

- **Entry Point:** The interpreter starts execution at `@main { ... }`.
- **Jump Logic:** Use `goto` statements to move between blocks, simulating assembly-style flow. 
- **Loops:** While `for` and `while` are not keywords in the kernel, they are implemented as higher-level constructs within `stdlib.kr`.

```kr
@main {
    goto start_loop
}

@start_loop {
    writeln "Hello from the loop!"
    goto start_loop
}
```

### [^] The `evolve` Intent
The `evolve` intent is a powerful tool for meta-programming. It takes a valid Kronyn string and executes it immediately.
```kr
evolve "writeln 5" 
# Output: 5
```

### [*] Inbuilt Intents & Syscalls
The minimal kernel provides a set of essential primitives:
- **Core Intents:** `SET`, `EVOLVE`, `WRITELN`, `WRITE`, `DEFINE`, `RETURN`, `GOTO`, `IMPORT`, `SYSCALL`, `IF`.
- **Syscalls:** Basic `input`, `output`, and `read file` capabilities.

*(Note: `write` and `writeln` are currently in the kernel but will be moved to `stdlib.kr` in future versions to keep the kernel lean.)*

---

## [+] Implementation Details

- **Language:** Written in [Nim](https://nim-lang.org/).
- **Philosophy:** The interpreter is kept intentionally short. Almost all extended functionality is written in Kronyn itself via the standard library.
- **Future Roadmap:** 
    - - **Actor Model:** Integration of an Erlang-like actor model for named blocks using Nim's Continuous Passing Style (CPS) library.
    - - **Stdlib Expansion:** Moving hardcoded string functions (like `toUpper()`, `toLower()`, `trim()`, `len()`) into `stdlib.kr`.

## -> Getting Started



### Prerequisites
- Nim Compiler (`choosenim` or `nim install`)

### Installation
```bash
git clone https://github.com/yourusername/kronyn.git
cd kronyn
nim c -d:release -o:kronyn kronyn.nim
```

### Running a script
```bash
./kronyn script.kr
```

## [-] Credits & Inspiration
- **MORRIS Standards:** [MORRIS-shell](https://github.com/Stanislaw3737/MORRIS-shell) & [mshell](https://github.com/Stanislaw3737/mshell).
- **Tcl:** For the "everything is a string" architecture.
- **Erlang:** For the upcoming Actor model inspiration.