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
