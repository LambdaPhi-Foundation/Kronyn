# Changes in Kronyn v0.002

### [.] Rules regarding named blocks and goto handling -
#### 1. You can use goto to any block (programmer's responsibility)
#### 2. Nested blocks are not allowed (while function definitions are allowed)
#### 3. The interpreter implicitly declares "goto main", so the execution starts at @main{...}

# Changes in Kronyn v0.003
## Named blocks and "goto" intent are temporarily removed to fix infinite recursion and scope mangling issues
