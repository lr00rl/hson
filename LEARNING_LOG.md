# 学习笔记 / Learning Log

> 记录 HSON 项目每次迭代的心得、踩坑与领悟。

---

## 2025-04-16 | 挑战 1：支持字符串转义

### 目标
让 JSON 字符串解析器支持标准转义序列：`\"`、`\\`、`
`、`	`。

### 实现思路

#### 1. 新增 `anyChar` 解析器
```haskell
anyChar :: Parser Char
anyChar = Parser $ \input -> case input of
  (c:cs) -> Just (c, cs)
  []     -> Nothing
```
这是所有字符解析器的基础原子。

#### 2. 新增 `parseEscapedChar` 解析器
```haskell
parseEscapedChar = do
  _ <- char '\\'
  c <- anyChar
  case c of
    '"'  -> return '"'
    '\\' -> return '\\'
    'n'  -> return '\n'
    't'  -> return '\t'
    _    -> fail "Unknown escape sequence"
```

**关键点**：
- 先用 `char '\\'` 消费反斜杠
- 再用 `anyChar` 读取下一个字符
- 用 `case` 做分支映射，不认识的转义序列调用 `fail` 让解析器整体失败

#### 3. 改造 `parseString`
原来的实现是：
```haskell
s <- many (satisfy (/= '"'))
```

改造后：
```haskell
s <- many (parseEscapedChar <|> satisfy (/= '"'))
```

这一步完美展示了 `Alternative` 的威力：
- 在字符串的每一个字符位置，解析器先尝试 `parseEscapedChar`
- 如果失败（不是反斜杠开头），则**回退**并尝试 `satisfy (/= '"')`
- `many` 会自动重复这个过程直到遇到结束引号

#### 4. 修复 pretty-print 输出
解析器已经能正确把 `\n` 转成换行符存储在内存中，但 `prettyPrint` 直接输出原始字符串会导致终端显示混乱，而且输出不再是合法 JSON。

于是给 `JsonString` 的打印加了 `escapeString`：
```haskell
escapeString = concatMap $ \c -> case c of
  '"'  -> "\\\""
  '\\' -> "\\\\"
  '\n' -> "\\n"
  '\t' -> "\\t"
  _    -> [c]
```

这样输入和输出都是对称的、合法的 JSON。

### 踩坑记录

**坑 1：Haskell 字符串字面量的多层转义**
在写 `examples/escape.json` 测试文件时，需要时刻区分：
- JSON 层面的转义：`\"`
- Shell heredoc 层面的转义
- 最终文件里应该只保留 JSON 层面的转义

用 `cat > file << 'EOF'`（加单引号）可以避免 shell 提前解释反斜杠。

**坑 2：where 块中函数定义的排列顺序**
在修改 `app/Main.hs` 时，一开始把 `escapeString` 的定义插在了 `go` 的多条模式匹配中间，GHC 报错了：
```
Conflicting definitions for 'go'
```

**教训**：Haskell 中同一个函数的多条模式匹配定义必须连续，中间不能插入其他定义。

### 学习收获

1. **`<|>` 的回退机制**：Parser Combinator 中，失败不会破坏输入状态，`q` 会从头开始尝试。这让"尝试 A，不行就试 B"的写法变得非常自然。
2. **`MonadFail` 的实战价值**：`do` 语法中的 `fail` 在这里用来处理不认识的转义序列，让错误处理融入控制流。
3. **解析与序列化的对称性**：只写解析器是不够的，输出端（pretty-print）也要同步考虑，否则端到端体验会断裂。

### 验证命令
```bash
cabal run hson -- examples/escape.json
```

输出：
```json
{
  "message": "She said \"Hello\" to me",
  "path": "C:\\Users\\Alice\\Documents",
  "multiline": "Line 1\nLine 2\tIndented",
  "empty": ""
}
```

完美通过 ✅

---

## 2025-04-16 | RFC 8259 合规性升级：字符串与数字

### 目标
让整个解析器严格遵循 RFC 8259（The JavaScript Object Notation Data Interchange Format），重点补齐字符串转义和数字格式。

### 字符串：从"部分支持"到"严格标准"

#### RFC 8259 要求
- 必须支持的转义序列：`\"` `\\` `\/` `\b` `\f` `\n` `\r` `\t` `\uXXXX`
- 字符串中**不允许出现裸控制字符**（U+0000..U+001F）
- `\uXXXX` 如果表示高代理项（U+D800..U+DBFF），必须紧跟一个低代理项，组合成完整的 Unicode code point

#### 实现

**1. `parseUnicodeEscape` — Unicode 转义解析**
```haskell
parseUnicodeEscape = do
  hex <- count 4 hexDigit
  let code = read ("0x" ++ hex) :: Int
  if code >= 0xD800 && code <= 0xDBFF
    then do
      -- 高代理项，必须紧跟低代理项
      _    <- char '\\'
      _    <- char 'u'
      hex2 <- count 4 hexDigit
      let low = read ("0x" ++ hex2) :: Int
      if low >= 0xDC00 && low <= 0xDFFF
        then return $ chr $ 0x10000 + ((code - 0xD800) * 0x400) + (low - 0xDC00)
        else fail "Invalid surrogate pair"
    else return $ chr code
```

**2. `parseEscapedChar` 扩展**
新增了 `/`、`b`、`f`、`r`、`u` 分支。

**3. 拒绝裸控制字符**
```haskell
isUnescaped c = ord c >= 0x20 && c /= '"' && c /= '\\'
```
这等价于 RFC 8259 的 ABNF：
```
unescaped = %x20-21 / %x23-5B / %x5D-10FFFF
```

#### 踩坑
**坑：重复消费 `u`**
最初的实现中，`parseEscapedChar` 已经消费了 `u`，但 `parseUnicodeEscape` 开头又写了一个 `char 'u'`，导致解析 `\u0048` 时变成消费了 `uu004`，只读 3 位十六进制。

**教训**：在 Parser Combinator 中，要时刻注意**输入指针的位置**。`do` 语法让代码看起来像命令式，但底层是纯函数式的状态传递，多消费一个字符就会级联出错。

### 数字：完全手写 RFC 8259 ABNF

#### RFC 8259 的 number ABNF
```
number = [ minus ] int [ frac ] [ exp ]
int    = zero / ( digit1-9 *DIGIT )
frac   = decimal-point 1*DIGIT
exp    = e [ minus / plus ] 1*DIGIT
```

#### 实现
完全用 Parser Combinator 组装：
```haskell
parseNumber = do
  sign     <- optional (char '-')
  intPart  <- parseInt
  fracPart <- optional parseFrac
  expPart  <- optional parseExp
  let numStr = ...
  return $ JsonNumber (read numStr)
```

其中 `parseInt` 严格处理了前导零：
- 如果首字符是 `'0'`，则直接返回 `"0"`，不再读取后续数字（防止 `01`）
- 如果首字符是 `1-9`，则可以跟任意多个数字

`parseFrac` 要求 `.` 后面必须至少有一个数字（防止 `1.`）。
`parseExp` 要求 `e`/`E` 后面必须至少有一个数字，可选 `+`/`-`（防止 `1e`、`1e+`）。

#### 非法输入测试结果
| 输入 | 结果 |
|------|------|
| `{"a":01}` | ✅ 拒绝 |
| `{"a":1.}` | ✅ 拒绝 |
| `{"a":.5}` | ✅ 拒绝 |
| `{"a":1e}` | ✅ 拒绝 |
| `{"a":1e+}` | ✅ 拒绝 |
| `{"a":"line1\nline2"}` | ✅ 拒绝 |

### 输出端同步升级
`app/Main.hs` 的 `escapeString` 也同步支持了 `\b`、`\f`、`\r`，并把 U+0000..U+001F 范围内的其他控制字符统一输出为 `\uXXXX`。

### 验证命令
```bash
cabal run hson -- examples/rfc8259.json
```

输出：
```json
{
  "string_escapes": "\b\f\n\r\t\\/\"",
  "unicode": "Hello",
  "surrogate": "𝄞",
  ...
}
```

`surrogate` 字段的 `\uD834\uDD1E` 被正确解码为音乐符号 𝄞，证明代理对处理完美通过 ✅

### 学习收获

1. **ABNF 到 Haskell 的直接映射**：RFC 的 formal grammar 和 Parser Combinator 的代码结构几乎是一一对应的，这是函数式解析的巨大优势。
2. **Parser 组合的可组合性**：`parseInt`、`parseFrac`、`parseExp` 三个小组件独立编写、独立测试，最后用 `optional` 和 `<*>` 组合成完整的 `parseNumber`。
3. **端到端的一致性**：解析和输出必须对称。如果只升级解析器而不升级 `prettyPrint`， round-trip（解析后再打印）就会破坏数据。
4. **`read` 的安全使用**：虽然 `read` 本身比较"宽容"，但因为我们已经用 Parser 做了严格的语法验证，所以 `read numStr` 在这里是安全的。

---

## 2025-04-16 | 挑战 4：精确错误报告 — 从 Maybe 到 Either ParseError

### 目标
把解析器的核心类型从 `Maybe` 升级为 `Either ParseError`，并追踪行号和列号，让错误信息像真正的编译器一样精确。

### 核心设计

#### 1. 引入状态类型 `State`
```haskell
data State = State
  { sInput :: String  -- 剩余输入
  , sLine  :: Int     -- 当前行号
  , sCol   :: Int     -- 当前列号
  }
```

#### 2. 新的 Parser 类型
```haskell
newtype Parser a = Parser { runParser :: State -> Either ParseError (a, State) }
```

以及便捷的入口函数：
```haskell
parse :: Parser a -> String -> Either ParseError (a, String)
parse p input = runParser p (State input 1 1)
```

#### 3. 行列号更新逻辑 `advanceState`
```haskell
advanceState :: State -> Char -> State
advanceState st c
  | c == '\n' = State (tailInput) (sLine st + 1) 1
  | otherwise = State (tailInput) (sLine st) (sCol st + 1)
```

### 类型类实例重写

**Functor / Applicative / Monad**：
结构和原来几乎一样，只是把 `Just`/`Nothing` 换成 `Right`/`Left`。

**Alternative 的 `<|>`**：
这是最有意思的部分。关键决策：
- 如果 `p` 成功，直接返回 `p` 的结果
- 如果 `p` 失败，尝试 `q`
- 如果两边都失败，返回"走得更远"的那个错误

```haskell
p <|> q = Parser $ \st -> case runParser p st of
  Right ok    -> Right ok
  Left err1   -> case runParser q st of
    Right ok    -> Right ok
    Left err2   -> Left (farthestError err1 err2)
```

`farthestError` 比较行号和列号，优先保留位置更靠后的错误。这符合人类直觉：如果 `parseNull` 已经解析了 `n` 然后失败，它比什么都没匹配的 `parseBool` 更"接近"用户的意图。

### 踩坑

#### 坑 1：`sepBy` 的过度回退
原来的 `sepBy` 实现是：
```haskell
sepBy p sep = (:) <$> p <*> many (sep *> p) <|> pure []
```

这会导致一个严重问题：如果 `p` 已经消费了输入然后失败（比如对象里的 `"a": 01`），`<|> pure []` 会回退到 `p` 开始前的状态，并返回空列表。这会让对象解析器忽略已经解析的内容，直接期望 `}`，最终报出一个莫名其妙的位置错误。

**修复**：让 `sepBy` 只在 `p` **完全没有消费输入**的情况下才回退到空列表。

```haskell
sepBy p sep = Parser $ \st -> case runParser p st of
  Right (x, st1) -> case runParser (many (sep *> p)) st1 of
    Right (xs, st2) -> Right (x:xs, st2)
    Left err        -> Left err
  Left err ->
    if peLine err == sLine st && peCol err == sCol st
      then Right ([], st)
      else Left err
```

这是" committed parsing "（承诺解析）的一个简化版教学实现。它保证了：如果解析器已经开始吃了输入，就必须负责到底。

#### 坑 2：`optional` 与错误信息的丢失
在 `parseNumber` 中，`optional parseFrac` 如果 `parseFrac` 已经消费了 `.` 然后失败，`optional` 会回退状态并返回 `Nothing`。这导致 `1.` 的错误不会直接来自 `parseFrac`，而是来自外层的对象解析器（"Expected '}' but found '.'"）。

**思考**：要完全修复这个问题需要引入 `try` 语义（Megaparsec 的做法）或更复杂的错误类型（trivial vs fancy errors）。对于当前的教学项目，我们认为"位置正确"比"信息绝对精准"更有价值。用户的输入确实在 `1.` 处出错了，虽然报错信息不是最内层的，但位置足够指引修复方向。

### 验证结果

| 非法输入 | 错误输出 |
|----------|----------|
| `{"a": 01}` | `Error at line 1, column 8: Leading zeros are not allowed in JSON numbers` |
| `[1, 2, 3` | `Error at line 2, column 1: Expected ']' but reached end of input` |
| `{"a": "hello\nworld"}` | `Error at line 1, column 13: Expected '"' but found '\n'` |

全部精准定位 ✅

### 学习收获

1. **Either 作为错误通道**：`Either ParseError (a, State)` 让解析器从"黑盒失败"变成了"白盒诊断"。
2. **位置的精确性比信息的完美性更重要**：用户首先关心"哪里错了"，其次才是"为什么错"。
3. **组合子的语义设计**：`sepBy` 和 `<|>` 的"是否回退"直接影响错误报告的质量。这是工业级解析器（Parsec / Megaparsec）的核心课题。
4. **ABNF 到代码的映射依然成立**：即使加入了错误和状态追踪，Parser Combinator 的高阶组合模式依然优雅。
