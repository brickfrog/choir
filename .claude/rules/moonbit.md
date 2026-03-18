---
paths:
  - "**/*.mbt"
  - "**/moon.pkg.json"
  - "**/moon.mod.json"
---

# MoonBit Conventions

## Naming

- Functions, variables, methods: `snake_case`
- Types, traits, constructors: `PascalCase`
- Constants: `UPPER_CASE`
- Function names must NOT start with uppercase (compiler enforced)
- Constructor names must start with uppercase (compiler enforced)

## Type System

- Prefer `enum` for tagged unions, `struct` for records
- Use `derive(Show, Eq, Compare)` where appropriate
- Use `Result[T, E]` and `T?` (Option) for error handling, not exceptions
- Generic params in square brackets: `fn[T] foo(x : T) -> T`
- Functions that can fail use `!` suffix: `fn parse!(input : String) -> Ast`

## Style

- Immutable by default. `mut` is explicit.
- Prefer `|>` pipe operator for chaining
- Prefer pattern matching over conditionals
- `test { ... }` blocks for unit tests, `assert_eq!()` and `inspect!()` for assertions
- No semicolons (expression-based language)

## Project Structure

```
moon.mod.json          # module manifest (name, version, deps)
src/
  moon.pkg.json        # package manifest (imports, test-imports)
  *.mbt                # source files
  *_test.mbt           # test files (convention)
```

## Build and Test

```bash
moon check            # typecheck
moon build            # compile
moon test             # run all tests
moon fmt              # format code
moon info             # generate .mbti interface files
```

## C FFI (native backend)

```moonbit
extern "C" fn c_function(arg : Int) -> Int = "c_function_name"
```

C stubs declared via `"native-stub"` in `moon.pkg.json`. MoonBit `String` is UTF-16 with
length; C strings are null-terminated. Need conversion helpers at the boundary.

## Dependencies

- Add deps via `moon.mod.json` `"deps"` field
- Package registry: mooncakes.io (no semver resolution yet — pin versions)
- `moonbitlang/async` for native async I/O (TCP, process, fs, timers)
