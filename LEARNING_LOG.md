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

---

## 2025-04-16 | 挑战 5：JSON Path 查询 DSL

### 目标
在解析出的 `JsonValue` 上实现 `.data.users[0].name` 风格的查询语法。

### 设计

#### 1. 路径段的 ADT
```haskell
data PathSegment = Key String | Index Int
  deriving (Eq, Show)
```

#### 2. 路径解析器 `parsePath`
没有动用庞大的 Parser Combinator 框架，而是用 Haskell 标准库的 `span` + 递归完成：

```haskell
parsePath :: String -> Maybe [PathSegment]
parsePath ('.':cs) =
  let (key, rest) = span (`notElem` "[.") cs
  in (Key key :) <$> parsePath rest
parsePath ('[':cs) =
  case span isDigit cs of
    (digits, ']':rest) -> (Index (read digits) :) <$> parsePath rest
    _ -> Nothing
```

**第一次踩坑**：最初把 `.` 的分隔符忘了，写了 `span (/= '[')`，导致 `.settings.theme` 被解析成 `Key "settings.theme"` 而不是 `[Key "settings", Key "theme"]`。

修复：把 `.` 也加入分隔符集合：`span (`notElem` "[.")`。

#### 3. 查询函数 `query`
```haskell
query :: [PathSegment] -> JsonValue -> Maybe JsonValue
query [] json = Just json
query (Key k : rest) (JsonObject pairs) = lookup k pairs >>= query rest
query (Index i : rest) (JsonArray xs)
  | i >= 0 && i < length xs = query rest (xs !! i)
  | otherwise               = Nothing
query _ _ = Nothing
```

这里展示了 Haskell 处理递归数据结构的典型模式：
- 基本情况（base case）：空路径，返回当前值
- 递归情况：根据 `PathSegment` 类型分支，用 `lookup` 或数组索引找到下一层，然后递归调用 `query`
- 失败处理：任意一步不匹配（对象没有该 key、数组越界、类型不匹配），立即返回 `Nothing`

#### 4. CLI 集成
`Main.hs` 的命令行参数扩展为支持 `[file] [path]`：
```bash
cabal run hson -- examples/nested.json .users[0].name
# => "Alice"
```

### 验证结果

| 查询 | 结果 |
|------|------|
| `.users[0].name` | `"Alice"` ✅ |
| `.users[1].roles[0]` | `"user"` ✅ |
| `.settings.theme` | `"dark"` ✅ |
| `.users[0].age` | `Query failed...` ✅ (key 不存在) |
| `.users[2].name` | `Query failed...` ✅ (数组越界) |

### 学习收获

1. **ADT 不仅用于解析结果，也用于中间表示**：`PathSegment` 就是查询 AST 的节点。
2. **不是所有解析都需要 Parser Combinator**：对于简单的、无回溯的线性语法，`span` + 递归往往更清晰。
3. **`Maybe` Monad 的链式失败**：`lookup k pairs >>= query rest` 让错误传播变得零成本，代码专注于"成功路径"。
4. **CLI 设计要自然**：把查询路径作为第二个命令行参数，符合 Unix 工具的使用直觉。

---

## 2025-04-16 | 挑战 6：Generic 反序列化 — FromJson 类型类

### 目标
实现一个 `FromJson` 类型类，让 Haskell 能自动把 `JsonValue` 转换成自定义 Record 类型。

### 设计

#### 1. 类型类定义
```haskell
class FromJson a where
  fromJson :: JsonValue -> Either String a
```

#### 2. 基础实例
为 `Bool`、`Int`、`Double`、`String`、`[a]`、`Maybe a` 分别实现实例。

其中 `String` 是一个特殊案例，因为 `String` 在 Haskell 中只是 `[Char]` 的类型别名。如果只为 `[a]` 写实例，那么 `String` 会期望 JSON 数组而不是 JSON 字符串。因此需要显式为 `String` 写实例，并标记 `{-# OVERLAPPING #-}` 让它优先于 `[a]` 实例。

```haskell
instance {-# OVERLAPPING #-} FromJson String where
  fromJson (JsonString s) = Right s
  fromJson _              = Left "Expected string"
```

#### 3. 辅助函数：`withObject`、`withArray`、`.:`、`.:?`
这些 API 设计深受 `aeson` 启发：

```haskell
withObject :: String -> ([(String, JsonValue)] -> Either String a) -> JsonValue -> Either String a
(.:)  :: FromJson a => [(String, JsonValue)] -> String -> Either String a        -- 必填
(.:?) :: FromJson a => [(String, JsonValue)] -> String -> Either String (Maybe a) -- 可选
```

#### 4. Record 手动实例示例
```haskell
data User = User
  { userName :: String
  , userAge :: Int
  , userActive :: Bool
  , userEmail :: Maybe String
  } deriving (Show)

instance FromJson User where
  fromJson = withObject "User" $ \o ->
    User <$> o .: "name" <*> o .: "age" <*> o .: "active" <*> o .:? "email"
```

这里用到了 `Applicative` 的 `<*>`：四个字段的解析都是 `Either String a`，它们可以无缝组合成一个 `Either String User`。如果任何一个字段失败，整个组合立即返回 `Left` 错误。

### 踩坑

#### 坑：`String` 与 `[a]` 的 Overlapping Instances
第一次尝试时，没有为 `String` 写独立实例，而是指望 `[a]` 自动覆盖 `[Char]`。结果 `String` 的 JSON 反序列化变成了"期望数组"。

**修复**：显式写 `instance {-# OVERLAPPING #-} FromJson String`。

这也让我们学到了 Haskell 中 `String` 的真相：它不是一个独立的类型，而是 `type String = [Char]`。

### 验证结果

| 场景 | 结果 |
|------|------|
| 完整 JSON 反序列化 | `Right (User {userName = "Alice", userAge = 30, ...})` ✅ |
| 缺少可选字段 `email` | `Right (User {..., userEmail = Nothing})` ✅ |
| 类型不匹配（`age` 为字符串） | `Left "Expected number"` ✅ |

### 学习收获

1. **类型类是真正的接口**：`FromJson` 让任何类型都能声明"我可以从 JSON 来"，这比面向对象的继承更灵活。
2. **组合即力量**：`Applicative` 让多个 `Either String a` 的组合看起来像同步代码，但底层是自动的错误短路。
3. **类型同义词的陷阱**：`String = [Char]` 在实例推导时会产生重叠，需要用 `OVERLAPPING` pragma 显式控制优先级。
4. **从零到 aeson**：我们现在理解了一个简化版 `aeson` 的核心原理。工业级库只是在这个骨架上增加了泛型推导（Generics）和更完善的错误堆栈。

---

## 2025-04-16 | 挑战 7：性能优化 — 从 String 到 Data.Text

### 目标
将项目中的 `String`（即 `[Char]` 链表）全面替换为 `Data.Text`，提升解析大文件时的内存和速度表现。

### 核心改动

#### 1. `hson.cabal` 引入 `text` 依赖
```cabal
build-depends: base >=4.14 && <5, text >=1.2 && <3
```

#### 2. `Hson.Types`：键和字符串值改用 `Text`
```haskell
data JsonValue
  = ...
  | JsonString Text
  | JsonObject [(Text, JsonValue)]
```

#### 3. `Hson.Parser`：解析器核心输入从 `String` 改为 `Text`

**State 类型更新**：
```haskell
data State = State { sInput :: Text, sLine :: Int, sCol :: Int }
```

**字符消费**：原来用列表模式匹配 `(c:cs)`，现在用 `T.uncons`：
```haskell
satisfy p = Parser $ \st -> case T.uncons (sInput st) of
  Just (c, _) | p c -> Right (c, advanceState st c)
  ...
```

**字符串匹配**：原来用递归 `char` 组合，现在直接用 `T.isPrefixOf`：
```haskell
string :: Text -> Parser Text
string expected = Parser $ \st ->
  let inp = sInput st
  in if T.isPrefixOf expected inp
       then Right (expected, st { sInput = T.drop (T.length expected) inp })
       else Left ...
```

**数字转换**：从 `read` 改为 `Data.Text.Read.double`：
```haskell
case TR.double numTxt of
  Right (n, rest) | T.null rest -> return $ JsonNumber n
```

#### 4. `Hson.Query`
- `parsePath` 的输入和 `Key` 构造子全部改为 `Text`
- `T.break` 替代 `span`，`T.uncons` 替代模式匹配

#### 5. `Hson.Class`
- `fromJson (JsonString s)` 对 `String` 实例需要 `T.unpack`
- 新增 `FromJson Text` 实例，实现零拷贝反序列化
- `withObject` 和 `.:` / `.:?` 的键类型改为 `Text`

#### 6. `app/Main.hs`
- 文件读取从 `readFile` 改为 `Data.Text.IO.readFile`
- `prettyPrint` 中对 `JsonString` 使用 `T.unpack` 输出
- 命令行路径查询参数用 `T.pack` 转换

### 踩坑

#### 坑 1：`OverloadedStrings` 与 `elem` 的类型歧义
开启 `OverloadedStrings` 后，`"abc"` 既可以是 `String` 也可以是 `Text`。当写 `satisfy (`elem` "0123456789")` 时，GHC 无法推断 `"0123456789"` 到底是哪个 `Foldable`。

**修复**：写一个显式类型的辅助函数：
```haskell
charIn :: String -> Char -> Bool
charIn chars c = c `elem` chars
```

#### 坑 2：`String` 实例与 `[a]` 实例的重叠
在 `Class.hs` 中，`instance FromJson String` 和 `instance FromJson [a]` 仍然需要 `{-# OVERLAPPING #-}` pragma，因为 `String = [Char]` 的语义没有改变。

### 性能测试

生成 1.6 MB 的大 JSON 文件（包含 10,000 个用户对象），用 `time` 测试：

```bash
time cabal run hson -- examples/large.json > /dev/null
# real  0m0.793s
# user  0m0.791s
# sys   0m0.207s
```

对于一个手写、零依赖的 Parser Combinator，在 GHC 9.4.8 上不到 1 秒解析 1.6 MB 是完全可以接受的性能。主要的性能收益来自：
- `Text` 的紧凑内存布局（每个字符 1-4 字节，而非链表指针）
- `T.uncons` 和 `T.isPrefixOf` 的 O(1) / O(n) 批量操作
- 避免了 `String` 的堆分配和 GC 压力

### 学习收获

1. **String 是链表，Text 是数组**：在解析器这种频繁索引和切片的场景中，数据结构的选择直接决定性能天花板。
2. **`OverloadedStrings` 不是免费的**：它带来方便的同时也引入了类型推断的复杂性，需要显式注解或辅助函数。
3. **Text 生态完备**：`Data.Text.Read.double` 让数字解析无需再 `unpack` 回 `String`。
4. **端到端迁移**：从输入读取（`TIO.readFile`）到内部表示（`JsonString Text`）再到输出（`T.unpack`），每一步都要同步考虑。

---

## 2025-04-16 | 最终挑战 🐉：用 Megaparsec 重写

### 目标
用工业级 Parser Combinator 库 [Megaparsec](https://hackage.haskell.org/package/megaparsec) 重写 JSON 解析器，并与手写版本进行全面对比。

### 实现

#### 新建模块 `src/Hson/MegaParser.hs`
Megaparsec 版本的核心代码仅约 **130 行**（不含注释），而手写版本约 **300+ 行**。差距主要来自：

1. **内置的词法分析器**：`Text.Megaparsec.Char.Lexer` 提供了 `space`、`lexeme`、`symbol` 等现成工具
2. **内置的 `between` 和 `sepBy`**：无需自己实现
3. **自动的空格管理**：`sc`（space consumer）一旦定义，组合子自动跳过空白
4. **不需要手动写 `Functor`/`Applicative`/`Monad`/`Alternative` 实例**

#### 关键代码对比

**手写版 `string` 解析器**（递归 + Applicative）：
```haskell
string :: Text -> Parser Text
string expected = Parser $ \st ->
  let inp = sInput st
  in if T.isPrefixOf expected inp
       then Right (expected, st { sInput = T.drop (T.length expected) inp })
       else Left ...
```

**Megaparsec 版**：
```haskell
symbol :: Text -> Parser Text
symbol = L.symbol sc
```

**手写版 `sepBy`**（需要处理承诺解析语义）：
```haskell
sepBy p sep = Parser $ \st -> case runParser p st of
  ...
```

**Megaparsec 版**：
```haskell
pArray = JsonArray <$> between (symbol "[") (symbol "]") (pValue `sepBy` symbol ",")
```

### 性能对比

用 1.6 MB 大 JSON 文件测试：

| 版本 | 耗时 |
|------|------|
| 手写 Parser（Text 版） | **0.873s** |
| Megaparsec 版 | **0.623s** |

**结论**：Megaparsec 不仅代码更短、错误信息更好，而且**更快**。这归功于它底层的优化（如 inline 密集的解析原语、高效的状态传递、延迟错误计算等）。

### 错误信息对比

**手写版**：
```
Error at line 1, column 8: Leading zeros are not allowed in JSON numbers
```

**Megaparsec 版**：
```
<input>:1:8:
  |
1 | {"a": 01}
  |        ^
unexpected '1'
```

Megaparsec 自带可视化箭头指向错误位置，并支持多行上下文、彩色输出（在终端中）。工业级项目的用户体验确实更胜一筹。

### 踩坑

#### 坑 1：Megaparsec 的 `parse` 函数与我们的导出函数重名
我们在 `Hson.MegaParser` 里导出了 `parse`，但它和 `Text.Megaparsec.parse` 冲突。最终把导出名改成了 `runMega`。

#### 坑 2：Megaparsec 的 `State` 类型字段复杂
我们最初想用 `runParser'` 直接操作底层 `State` 来获取剩余输入，但 `State` 构造子参数较多且版本相关。更好的方案是使用 `getInput` 组合子：
```haskell
runMega p input = runParser p' "<input>" input
  where
    p' = do result <- p; rest <- getInput; return (result, rest)
```

### 学习收获

1. **核心思想完全一致**：无论是手写还是 Megaparsec，底层都是 `Functor + Applicative + Monad + Alternative`。
2. **库的价值在于细节**：Megaparsec 把我们手动实现的 300 行基础设施压缩成了几行导入，而且在错误报告和性能上都更优。
3. **手写不是浪费时间**：正是因为亲手实现了 `Parser` 类型类实例、状态传递、错误合并，我们才能一眼看懂 Megaparsec 的源码和文档。
4. **工业级选择的启示**：在实际项目中，没有理由从零写 Parser Combinator 框架，但**每个优秀的库用户都应该是半个实现者**。

### 项目最终状态

| 挑战 | 状态 |
|------|------|
| 1. 字符串转义 | ✅ |
| 2. 手写数字解析器 | ✅ |
| 3. RFC 8259 完整合规 | ✅ |
| 4. 精确错误报告 | ✅ |
| 5. JSON Path 查询 | ✅ |
| 6. FromJson 类型类 | ✅ |
| 7. Text 性能迁移 | ✅ |
| 🐉 最终挑战：Megaparsec 重写 | ✅ |

**全部完成！** 🎉

---

## 2025-04-16 | 挑战 8：ToJson 类型类 + GHC.Generics 自动序列化

### 目标
为项目添加 `ToJson` 类型类，实现 `FromJson` 的对称能力——把 Haskell 类型自动序列化为 `JsonValue`。
同时，给 `ToJson` 也加上 GHC.Generics 自动推导支持，让用户能写：

```haskell
data User = User { name :: Text, age :: Int }
  deriving (Generic, FromJson, ToJson)
```

### 设计

#### 1. ToJson 类型类定义
```haskell
class ToJson a where
  toJson :: a -> JsonValue

  default toJson :: (Generic a, GToJson (Rep a)) => a -> JsonValue
  toJson x = gToJson (from x)
```

基础实例覆盖了 `Bool`、`Int`、`Double`、`Text`、`String`、`Char`、`[a]`、`Maybe a`。

#### 2. 辅助 API
```haskell
type Pair = (Text, JsonValue)
object :: [Pair] -> JsonValue
(.=) :: ToJson a => Text -> a -> Pair
```

示例：
```haskell
let json = object
      [ "name" .= ("Bob" :: Text)
      , "age" .= (25 :: Int)
      ]
```

#### 3. GToJson 的 Generic 实现
与 `GFromJson` 对称但更简单：

```haskell
class GToJson f where
  gToJson :: f p -> JsonValue
```

- `K1`：直接调用 `toJson`
- `M1 S`：如果字段有名字，包装成 `JsonObject [(name, value)]`；无名字则透传
- `(:*:)`: 合并左右两边的 `JsonObject`，把字段列表拼起来
- `M1 D / M1 C`：透传

这样对于 `User { name = "Alice", age = 30 }`：
- `M1 S name` → `JsonObject [("name", JsonString "Alice")]`
- `M1 S age` → `JsonObject [("age", JsonNumber 30)]`
- `(:*:)` 合并 → `JsonObject [("name", ...), ("age", ...)]`

#### 4. 序列化函数 `encode`
`Hson.ToJson` 还提供了 `encode :: JsonValue -> String`，输出带缩进的 JSON 字符串。
`app/Main.hs` 和 `app/MegaMain.hs` 都更新为导入 `Hson.ToJson.encode`，不再保留本地的 `prettyPrint`。

### 踩坑

#### 坑 1：GToJson 的 `(:*:)` 合并逻辑
如果左边或右边不是 `JsonObject`（比如无名字段的构造子），直接合并会失败。我们加了保护：
```haskell
merge (JsonObject xs) (JsonObject ys) = JsonObject (xs ++ ys)
merge JsonNull y = y
merge x JsonNull = x
merge _ _ = JsonNull
```

#### 坑 2：FromJson 的 `Maybe` 字段缺失行为
在测试 round-trip 时发现：Generics 推导的 `fromJson` 在字段不存在时直接报错 "Missing field"。但 `Maybe` 字段应该是可选的。

**修复**：在 `GFromJson (M1 S s f)` 实例中，字段不存在时不再报错，而是传入 `JsonNull`：
```haskell
Nothing -> M1 <$> gFromJson JsonNull
```
这样 `Maybe a` 的 `fromJson` 会正确返回 `Nothing`，而 `Int` 等必填字段仍会报错。

### 验证结果

**ToJson + Generic 推导：**
```haskell
let user = User "Alice" 30 True (Just (Address "Shanghai" "200000"))
encode (toJson user)
```
输出：
```json
{
  "name": "Alice",
  "age": 30.0,
  "active": true,
  "address": {
    "city": "Shanghai",
    "zipCode": "200000"
  }
}
```

**Round-trip 测试：**
```haskell
toJson user |> fromJson :: Either String User
-- Right (User {name = "Alice", age = 30, active = True, address = Just (Address {city = "Shanghai", zipCode = "200000"})})
```

完美对称 ✅

### 学习收获

1. **类型类的双向性**：`FromJson` 和 `ToJson` 共同构成了 Haskell 中与 JSON 的"同构映射"。这是 `aeson` 的核心骨架。
2. **Generics 的威力翻倍**：一次 `deriving (Generic, FromJson, ToJson)`，就同时获得了反序列化和序列化能力，编译器在幕后生成了所有样板代码。
3. **Optional 字段的语义设计**："字段不存在 = null" 是 JSON 生态中处理可选字段的常见约定，我们的 Generics 实现成功模拟了这一点。
4. **API 的一致性**：`object` / `.=` 的组合让手动构造 JSON 变得非常自然，与 `aeson` 的 `object` / `.=` 几乎一致。

### 项目能力总结

现在我们的 `hson` 项目已经具备了：
- **解析**：手写 Parser Combinator + Megaparsec 双实现
- **序列化**：`ToJson` 类型类 + `encode`
- **查询**：JSON Path DSL
- **泛型**：`deriving (Generic, FromJson, ToJson)` 自动推导
- **性能**：`Data.Text` 核心
- **错误报告**：精确行号列号

除了没有 `Vector` / `HashMap` / `Scientific` 等工业级数据结构外，核心能力已经非常接近 `aeson` 的简化教学版了。

---

## 2025-04-16 | 补全测试套件：从 0 到 45 个自动化用例

### 目标
为项目添加完整的 Hspec 测试套件，覆盖核心功能，并修复测试中暴露的解析器 bug。

### 测试设计

在 `test/Spec.hs` 中编写了 45 个测试用例，分为 5 个模块：

1. **Hson.Parser（18 个用例）**
   - 基础类型：null、bool、number、string
   - 转义字符： `"\n"`、unicode escape、surrogate pair
   - 复合类型：empty array、nested array、empty object、nested object
   - 错误输入：leading zeros、trailing dot、bare control chars
   - 空白处理

2. **Hson.Query（6 个用例）**
   - 对象字段查询 `.settings.theme`
   - 数组索引查询 `.users[0].name`
   - 缺失 key、越界索引、非法路径

3. **Hson.Class / FromJson（9 个用例）**
   - 基础类型反序列化：Bool、Int、Text、[Int]、Maybe
   - 类型不匹配错误报告
   - Generics 自动推导：嵌套 record、缺失 Maybe 字段

4. **Hson.ToJson（9 个用例）**
   - 基础类型序列化
   - `object` / `.=` 手动构造
   - Generics 自动序列化
   - `encode` 输出验证

5. **Round-trip（3 个用例）**
   - `JsonValue` 的 parse → encode → parse 一致性
   - Generic record 的 toJson → fromJson 一致性
   - 缺失 Maybe 字段的 round-trip 一致性

### 测试中暴露的 Bug：trailing dot 未被拒绝

测试用例 `rejects trailing dot in number` 最初失败了。

**原因**：`parseNumber` 中对 `fracPart` 使用了 `optional parseFrac`：
```haskell
parseFrac = do
  _      <- char '.'
  digits <- some (satisfy (charIn "0123456789"))
  ...
```

当输入为 `1.` 时，`char '.'` 成功消费了 `.`，但后续的 `some digitChar` 失败。`optional` 捕获了这个失败并**回退**到 `.` 之前的状态，导致 `1.` 被当成合法的 `1` 解析。

**修复**：引入 `parseOptionalFrac`，实现"承诺解析"（committed parsing）：
```haskell
parseOptionalFrac = Parser $ \st ->
  case T.uncons (sInput st) of
    Just ('.', _) ->
      case runParser parseFrac st of
        Right (txt, st') -> Right (Just txt, st')
        Left err         -> Left err
    _ -> Right (Nothing, st)
```

逻辑：如果输入下一个字符是 `.`，则运行 `parseFrac`，无论成败都不回退；如果不是 `.`，则直接返回 `Nothing`。

### 验证结果

```bash
cabal test
```

输出：
```
Finished in 0.0032 seconds
45 examples, 0 failures
```

全部通过 ✅

### 学习收获

1. **测试是最好的设计工具**：在写测试的过程中，我们发现了 trailing dot 这个隐藏 bug，这是手动运行示例无法覆盖的。
2. **承诺解析的重要性**：`optional` 的默认语义是"原子性失败"，但在解析器已经消费了输入后，回退会掩盖语法错误。这在工业级解析器中是经典陷阱。
3. **Hspec 的简洁性**：45 个测试用例写在一个文件里，结构清晰，运行迅速。对于教学项目来说，测试代码本身就是文档。

---

## 2025-04-16 | 工具链基础：`cabal` 与 `hson.cabal` 是什么

### 问题
作为一个 Haskell 初学者，第一次看到 `cabal build`、`cabal test`、`hson.cabal` 时，完全不知道这套工具在做什么。它和 `make` 有什么区别？和 `package.json` 有什么关系？

### 一句话解释

> **`cabal` 是 Haskell 世界的包工头，`hson.cabal` 是它看的设计图纸。**
> 你负责写 Haskell 代码，它负责：找人（下载依赖）、搬砖（编译源码）、验收（跑测试）。

### 类比映射

| 你熟悉的工具 | 对应 Haskell 工具 | 作用 |
|-------------|-------------------|------|
| `npm` / `yarn` | `cabal` | 下载包、管理依赖版本 |
| `package.json` | `hson.cabal` | 项目元数据 + 依赖列表 |
| `Makefile` | `cabal build` / `cabal test` / `cabal run` | 编排编译和运行流程 |
| `CMakeLists.txt` | `hson.cabal` 里的 `hs-source-dirs`、`ghc-options` | 告诉编译器源代码在哪、怎么编译 |

### `hson.cabal` 核心字段解读

```cabal
name:                hson               -- 项目名字（类似 package.json 的 name）
version:             0.1.0.0            -- 版本号
build-depends:       base >=4.14 && <5  -- 依赖列表（类似 dependencies）
                     , text >=1.2 && <3
                     , megaparsec >=9.0 && <10

library
  exposed-modules:   Hson.Parser, ...   -- 对外暴露的模块（类似 exports）
  hs-source-dirs:    src                -- 源码目录
  ghc-options:       -Wall              -- 编译器参数（如开启所有警告）

executable hson
  main-is:           Main.hs            -- 可执行文件入口
  build-depends:     base, text, hson   -- 这个 exe 额外需要的依赖

test-suite hson-test
  type:              exitcode-stdio-1.0 -- 标准测试套件
  main-is:           Spec.hs            -- 测试入口文件
  build-depends:     base, text, hson, hspec
```

### 最常用的 cabal 命令

```bash
cabal build          # 编译库 + 可执行文件 + 测试
cabal test           # 编译并运行测试套件
cabal run hson       # 编译并运行名为 hson 的可执行文件
cabal repl           # 进入交互式环境（类似 ghci，但自动加载项目模块）
cabal update         # 更新 Hackage 包列表（类似 apt update / npm update）
```

### 一个关键认知
`cabal` 不是 Haskell 的编译器，**GHC 才是编译器**。`cabal` 是 GHC 的"调度器"：
- 它根据 `hson.cabal` 的图纸，决定哪些文件先编译、哪些后编译
- 它处理模块之间的依赖图（比如 `Hson.Parser` 依赖 `Hson.Types`，`cabal` 会保证先编译 `Types`）
- 它从 Hackage 下载缺失的第三方库，并自动解决版本冲突

### 学习收获
1. **`hson.cabal` 是项目的唯一真实来源（single source of truth）**：名字、版本、依赖、模块列表、编译选项，全部都在这里。
2. **`cabal` 的本质是"包管理器 + 构建系统"**：它比 `make` 更智能（内置了 Haskell 编译规则），比 `npm` 更低层（直接调度编译器）。
3. **初学者不需要精通 cabal 的所有高级特性**：先记住 `build`、`test`、`run`、`repl` 四个命令，足以应付 90% 的日常开发。

---

## 2025-04-16 | CLI 增强：让 hson 更像 jq

### 目标
给 `hson` 命令行工具添加三个实用功能，让它在终端使用时更像 `jq`：
1. **紧凑输出** `-c` / `--compact`
2. **原始字符串输出** `-r` / `--raw-output`
3. **ANSI 颜色高亮** `--color`

### 实现

#### 1. `Hson.ToJson` 新增序列化函数

在 `src/Hson/ToJson.hs` 中扩展了序列化家族：

```haskell
encode              :: JsonValue -> String   -- 带缩进（原有）
encodeCompact       :: JsonValue -> String   -- 无缩进、无换行
encodeColor         :: JsonValue -> String   -- 带缩进 + ANSI 颜色
encodeCompactColor  :: JsonValue -> String   -- 紧凑 + ANSI 颜色
```

**ANSI 颜色方案（ColorScheme）**：
- `key`：黄色 `\x1b[33m`
- `string`：绿色 `\x1b[32m`
- `number`：洋红 `\x1b[35m`
- `bool/null`：蓝色 `\x1b[34m`

#### 2. `app/Main.hs` 的手动参数解析

为了不引入重量级依赖（如 `optparse-applicative`），我们用手动模式匹配实现了轻量级 flag 解析：

```haskell
parseFlags :: [String] -> (Bool, Bool, Bool, [String])
-- 返回 (是否 compact, 是否 raw, 是否 color, 剩余非 flag 参数)
```

逻辑规则：
- 以 `-` 开头的参数视为 flag
- `-c` / `--compact` → 紧凑输出
- `-r` / `--raw-output` → 原始字符串（`JsonString` 不加引号）
- `--color` → ANSI 颜色高亮

**`-r` 的特殊处理**：
```haskell
outputJson :: Bool -> (JsonValue -> String) -> JsonValue -> IO ()
outputJson True _ (JsonString s) = putStrLn (T.unpack s)  -- 不加引号
outputJson _    enc json         = putStrLn (enc json)
```

这完全模拟了 `jq -r` 的行为：如果查询结果是一个 JSON 字符串，就打印它的原始内容。

#### 3. 测试覆盖

新增了 4 个 Hspec 测试用例：
- `encodeCompact produces compact JSON`
- `encodeColor contains ANSI escape codes`
- `encodeCompactColor contains ANSI codes without newlines`
- `round-trips through compact encode and parse`

总测试数从 45 提升到 **49**，全部通过。

### 验证结果

```bash
# 紧凑输出
echo '{"a":1}' | cabal run hson -- -c
# => {"a":1.0}

# 原始字符串
echo '{"name":"Alice"}' | cabal run hson -- -r .name
# => Alice

# 颜色高亮
echo '{"a":1}' | cabal run hson -- --color
# => 黄色 key + 洋红 number（在支持 ANSI 的终端中可见）
```

### 学习收获

1. **不引入新依赖也能做好 CLI**：Haskell 的模式匹配非常适合轻量级的参数解析，几十行代码就能实现 `-c`、`-r`、`--color`。
2. **函数组合决定输出格式**：我们把"编码器选择"抽象成一个纯函数 `selectEncoder :: Bool -> Bool -> (JsonValue -> String)`，这让 CLI 逻辑和核心序列化逻辑完全解耦。
3. **`-r` 是用户体验的关键细节**：不加这个选项，每次查字符串都会得到带引号的 `"Alice"`，这对于脚本处理非常不友好。`jq` 之所以受欢迎，很大程度上是因为这些小细节。
4. **ANSI 颜色其实很简单**：就是一些 `\x1b[33m` 这样的转义序列，不需要任何外部库。
