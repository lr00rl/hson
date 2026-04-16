# HSON

> **My learning-haskell project** — a zero-dependency JSON parser built from scratch to explore Parser Combinators, Functor, Applicative, Monad, and recursive descent parsing.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)

---

## ✨ What is this?

**HSON** is both a **personal learning journal** and an **open-source tutorial** for anyone who wants to understand functional parsing from the ground up. It contains no external parsing libraries — just core Haskell syntax and the power of function composition.

If you are learning Haskell and wondering *"How do Functor, Applicative, and Monad actually work in the real world?"*, this project is for you.

---

## 🚀 Quick Start

```bash
# Build
cabal build

# Run the test suite (45+ examples covering parser, query, serialization, generics)
cabal test

# Parse JSON from stdin
echo '{"name": "Haskell", "level": 42}' | cabal run hson

# Query stdin with JSON Path (jq-like!)
echo '{"users":[{"name":"Alice"}]}' | cabal run hson -- .users[0].name

# Parse a JSON file
cabal run hson -- examples/nested.json

# JSON Path query from file
cabal run hson -- examples/nested.json .users[0].name

# Pipe file + query (also works!)
cat examples/nested.json | cabal run hson -- .users[0].name
```

> **New to Haskell?** `cabal` is the build tool and package manager for Haskell — think of it as `npm` + `make` combined. The `hson.cabal` file is the project blueprint: it declares the package name, version, dependencies, source directories, and how to build the library / executables / tests. See [`LEARNING_LOG.md`](./LEARNING_LOG.md) for a detailed beginner-friendly explanation.

---

## 📁 Project Structure

```
.
├── hson.cabal             # Cabal build configuration
├── LICENSE                # MIT License
├── README.md              # You are here
├── CHALLENGES.md          # Roadmap of progressive exercises
├── AGENTS.md              # Development notes for contributors / AI agents
├── app/
│   └── Main.hs            # Executable entrypoint (IO + pretty-printing)
├── examples/
│   ├── sample.json        # Basic nested example
│   └── nested.json        # Array-of-objects example
└── src/
    └── Json/
        ├── Types.hs       # JSON ADT (Algebraic Data Type)
        └── Parser.hs      # Hand-written Parser Combinator framework
```

---

## 🧠 Core Concepts

### 1. Parser as a Pure Function

Instead of mutable state and pointers, a parser is just a function:

```haskell
newtype Parser a = Parser { runParser :: String -> Maybe (a, String) }
```

Give it a string, and it either **fails** (`Nothing`) or returns a **result plus the unconsumed remainder** (`Just (a, String)`).

### 2. Four Type Classes, One Parser

| Type Class | Superpower | Example in this project |
|------------|------------|-------------------------|
| `Functor` | Transform the result of a parser | `fmap` turns a `Parser Char` into a `Parser Int` |
| `Applicative` | Combine independent parsers | `(:) <$> char c <*> string cs` builds a list |
| `Monad` | Sequence parsers where later steps depend on earlier ones | `do` notation for `parseObject` |
| `Alternative` | Choice (`<\|>`), repetition (`many`), and optional parsing | `parseNull <\|> parseBool <\|> parseString` |

### 3. Recursive Data, Recursive Functions

JSON is recursive by specification. Haskell models this perfectly:

```haskell
data JsonValue
  = JsonArray  [JsonValue]
  | JsonObject [(String, JsonValue)]
  | ...
```

`parseArray` calls `parseJson`, which may call `parseArray` again. Lazy evaluation makes this natural and safe.

---

## 📖 Code Highlights

**Parsing a comma-separated list (the "Hello World" of Parser Combinators):**

```haskell
sepBy :: Parser a -> Parser sep -> Parser [a]
sepBy p sep = (:) <$> p <*> many (sep *> p) <|> pure []
```

**Top-level JSON dispatcher:**

```haskell
parseJson :: Parser JsonValue
parseJson = lexeme $ parseNull
                    <|> parseBool
                    <|> parseString
                    <|> parseArray
                    <|> parseObject
                    <|> parseNumber
```

See [`src/Json/Parser.hs`](./src/Json/Parser.hs) for detailed, line-by-line comments in Chinese.

---

## 🏔️ Learning Roadmap

We prepared 6 progressive challenges in [`CHALLENGES.md`](./CHALLENGES.md), and record detailed notes for each iteration in [`LEARNING_LOG.md`](./LEARNING_LOG.md).

| # | Challenge | Status |
|---|-----------|--------|
| 1 | **Escape sequences in strings** — `\"`, `\\`, `\n`, `\t` | ✅ Completed |
| 2 | **Hand-written number parser** — integers, decimals, negatives, scientific notation | ✅ Completed |
| 3 | **RFC 8259 full compliance** — `\b`, `\f`, `\r`, `\uXXXX`, surrogate pairs, reject bare control chars | ✅ Completed |
| 4 | **Error reporting** — upgrade from `Maybe` to `Either ParseError` with line/column info | ✅ Completed |
| 5 | **JSON Path queries** — implement `.data.users[0].name`-style lookups | ✅ Completed |
| 6 | **Generic deserialization** — write a `FromJson` type class | ✅ Completed |
| 7 | **Performance** — migrate from `String` to `Data.Text` | ✅ Completed |
| 8 | **Generic serialization** — `ToJson` + `encode` + round-trip safety | ✅ Completed |
| 🐉 | **Final Boss:** Re-implement with [Megaparsec](https://hackage.haskell.org/package/megaparsec) | ✅ Completed |

---

## 🤝 Contributing

This is a learning project, so **questions and discussions are contributions too**! Feel free to open an issue if:
- Something in the code or comments is confusing
- You have a cleaner, more idiomatic way to write a function
- You want to share your solution to one of the challenges

If you submit code changes, please keep the teaching spirit: clarity over cleverness.

---

## 📚 Resources

- [Learn You a Haskell for Great Good!](http://learnyouahaskell.com/)
- [Haskell Wiki: Parser combinator](https://wiki.haskell.org/Parser_combinator)
- [Real World Haskell, Ch. 16](http://book.realworldhaskell.org/read/using-parsec.html)
- [What I Wish I Knew When Learning Haskell](http://dev.stephendiehl.com/hask/)

---

## 📝 License

[MIT](./LICENSE) — free to learn, modify, and share.
