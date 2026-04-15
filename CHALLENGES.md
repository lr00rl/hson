# 进阶挑战路线图

> 这个 JSON 解析器是一个**活的脚手架**。每完成一个挑战，你都会更深刻地理解 Haskell 的一个侧面。

建议按顺序完成，难度逐步递增。

---

## ✅ 挑战 1：支持字符串转义（已完成）

### 现状
当前 `parseString` 一遇到 `"` 就结束，完全无法处理字符串内部包含 `"` 的情况。例如：

```json
{"msg": "She said \"Hello\""}
```

这段 JSON 会导致解析失败。

### 目标
让 `parseString` 正确解析以下转义序列：
- `\\` -> `\`
- `\"` -> `"`
- `\n` -> 换行符
- `\t` -> 制表符

### 实现总结
参见 [`LEARNING_LOG.md`](./LEARNING_LOG.md) 的详细笔记。

核心改动：
1. 新增 `anyChar` 解析器
2. 新增 `parseEscapedChar`：先匹配反斜杠，再用 `case` 映射后续字符
3. 修改 `parseString`：
   ```haskell
   s <- many (parseEscapedChar <|> satisfy (/= '"'))
   ```
4. 同步修复 `prettyPrint` 中的字符串输出，加入 `escapeString` 保证输出仍是合法 JSON

### 关键代码
```haskell
parseEscapedChar = do
  _ <- char '\\'
  c <- anyChar
  case c of
    'n'  -> return '\n'
    't'  -> return '\t'
    '"'  -> return '"'
    '\\' -> return '\\'
    _    -> fail "Unknown escape sequence"
```

### 学习目标
- `Alternative` 的实际应用（`<|>` 的回退机制）
- 在 Monad 中处理分支逻辑
- 解析器与序列化器（pretty-print）的对称性设计

---

## ✅ 挑战 2：手写数字解析器（已完成）

### 现状
当前 `parseNumber` 使用了 Haskell 内置的 `reads`，虽然能用，但**作弊了**。它不是一个真正的 Parser Combinator 作品。

### 目标
完全用 Parser Combinator 重写 `parseNumber`，严格遵循 RFC 8259 的 `number` ABNF：
```
number = [ minus ] int [ frac ] [ exp ]
int    = zero / ( digit1-9 *DIGIT )
frac   = decimal-point 1*DIGIT
exp    = e [ minus / plus ] 1*DIGIT
```

支持：
- 整数：`42`, `-7`, `0`
- 小数：`3.14`, `-0.5`
- 科学计数法：`1e10`, `2.5E-3`, `-1.23e+4`

并正确拒绝非法输入：`01`, `1.`, `.5`, `1e`, `1e+`

### 实现总结
参见 [`LEARNING_LOG.md`](./LEARNING_LOG.md) 的详细笔记。

核心改动在 `src/Hson/Parser.hs`：
```haskell
parseNumber = do
  sign     <- optional (char '-')
  intPart  <- parseInt
  fracPart <- optional parseFrac
  expPart  <- optional parseExp
  let numStr = maybe "" (:[]) sign ++ intPart ++ maybe "" id fracPart ++ maybe "" id expPart
  return $ JsonNumber (read numStr)
```

其中 `parseInt` 的关键逻辑：
```haskell
parseInt = do
  first <- satisfy (`elem` "0123456789")
  if first == '0'
    then return "0"           -- 禁止前导零：01 非法
    else do
      rest <- many (satisfy (`elem` "0123456789"))
      return (first : rest)
```

### 学习目标
- `optional`、`some`、`many` 的组合使用
- 如何把多个小解析器组装成复杂解析器
- ABNF 到 Parser Combinator 的直接映射
- 用严格的语法验证保证后续 `read` 的安全性

---

## ✅ 挑战 3：从 Maybe 到 Either — 精确错误报告（已完成）

### 现状
解析失败时，我们只能得到冰冷的 `Nothing`，用户完全不知道哪里出错了。

### 目标
把解析器核心类型从 `String -> Maybe (a, String)` 升级为携带行列号的状态传递：
```haskell
data State = State { sInput :: String, sLine :: Int, sCol :: Int }
data ParseError = ParseError { peMessage :: String, peLine :: Int, peCol :: Int, peInput :: String }
newtype Parser a = Parser { runParser :: State -> Either ParseError (a, State) }
```

然后修改所有类型类实例和解析器，使其在遇到失败时报告精确的行号、列号和错误描述。

### 实现总结
参见 [`LEARNING_LOG.md`](./LEARNING_LOG.md) 的详细笔记。

核心改动：
1. 新增 `State` 类型追踪行列号，`advanceState` 在消费 `\n` 时换行
2. `satisfy` 和 `char` 在失败时构造 `ParseError` 并带上当前位置
3. `Alternative` 的 `<|>` 使用 `farthestError` 选择"走得更远"的错误
4. `sepBy` 被改造为"承诺解析"：如果 `p` 已经消费了输入再失败，**不会**回退为空列表

### 关键代码
```haskell
farthestError :: ParseError -> ParseError -> ParseError
farthestError e1 e2
  | peLine e1 > peLine e2 = e1
  | peLine e1 < peLine e2 = e2
  | peCol e1 >= peCol e2  = e1
  | otherwise             = e2

sepBy :: Parser a -> Parser sep -> Parser [a]
sepBy p sep = Parser $ \st -> case runParser p st of
  Right (x, st1) -> ...
  Left err ->
    if peLine err == sLine st && peCol err == sCol st
      then Right ([], st)   -- p 没吃输入，允许回退到空列表
      else Left err          -- p 已经吃了输入，必须传播错误
```

### 验证示例
| 非法输入 | 错误输出 |
|----------|----------|
| `{"a": 01}` | `Error at line 1, column 8: Leading zeros are not allowed...` |
| `[1, 2, 3` | `Error at line 2, column 1: Expected ']' but reached end of input` |

### 学习目标
- 理解 `Either` Monad 作为错误通道
- 错误处理的设计权衡（错误恢复 vs 精确报告）
- 这是工业级解析器（如 Megaparsec）的核心课题

---

## ✅ 挑战 5：JSON Path 查询（已完成）

### 目标
在 `JsonValue` 上实现一个查询函数：

```haskell
jsonQuery :: String -> JsonValue -> Maybe JsonValue
```

支持类似 JavaScript 的访问语法：
- `.name` -> 访问对象字段
- `[0]` -> 访问数组索引
- 链式组合：`.data.users[0].name`

### 实现总结
参见 [`LEARNING_LOG.md`](./LEARNING_LOG.md) 的详细笔记。

核心实现位于 `src/Hson/Query.hs`：
1. **ADT 定义**：`data PathSegment = Key String | Index Int`
2. **路径解析**：用 `span` + 递归把 `.data.users[0].name` 解析成 `[Key "data", Key "users", Index 0, Key "name"]`
3. **查询执行**：
   ```haskell
   query :: [PathSegment] -> JsonValue -> Maybe JsonValue
   query (Key k : rest) (JsonObject pairs) = lookup k pairs >>= query rest
   query (Index i : rest) (JsonArray xs)   = query rest (xs !! i)
   ```
4. **CLI 集成**：`Main.hs` 支持 `hson file.json .path[0].query`

### 关键代码
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

### 验证示例
```bash
cabal run hson -- examples/nested.json .users[0].name
# => "Alice"
```

### 学习目标
- 递归数据结构上的遍历
- 小型领域特定语言（DSL）的构建
- `Maybe` Monad 的链式失败传播

---

## ✅ 挑战 5：泛型反序列化 — FromJson 类型类（已完成）

### 目标
实现一个类型类 `FromJson`，让 Haskell 能自动把 `JsonValue` 转换成自定义的 Record 类型。

### 实现总结
参见 [`LEARNING_LOG.md`](./LEARNING_LOG.md) 的详细笔记。

核心实现位于 `src/Hson/Class.hs`：
1. **类型类定义**：`class FromJson a where fromJson :: JsonValue -> Either String a`
2. **基础实例**：`Bool`、`Int`、`Double`、`String`（`{-# OVERLAPPING #-}`）、`[a]`、`Maybe a`
3. **辅助 API**（aeson 风格）：
   - `withObject` / `withArray`
   - `.:`  读取必填字段
   - `.:?` 读取可选字段
4. **Record 手动实例示例**：
   ```haskell
   instance FromJson User where
     fromJson = withObject "User" $ \o ->
       User <$> o .: "name" <*> o .: "age" <*> o .: "active" <*> o .:? "email"
   ```

### 关键踩坑
`String` 是 `[Char]` 的类型别名，如果不写独立的 `FromJson String` 实例，它会匹配 `[a]` 实例并期望 JSON 数组。解决方案：
```haskell
instance {-# OVERLAPPING #-} FromJson String where
  fromJson (JsonString s) = Right s
```

### 验证示例
```haskell
fromJson jsonValue :: Either String User
-- Right (User {userName = "Alice", userAge = 30, userActive = True, userEmail = Just "alice@example.com"})
```

### 学习目标
- Haskell 类型类的深层设计
- `Applicative` 组合多个 `Either` 的自动短路机制
- 类型同义词（`String = [Char]`）在实例推导中的特殊处理
- 从零理解 `aeson` 的核心骨架

### 进阶目标（地狱难度，留待未来）
研究 `GHC.Generics`，让 `User` 类型可以自动派生 `FromJson`：
```haskell
data User = User { ... } deriving (Generic, FromJson)
```

---

## 挑战 6：性能优化 — 从 String 到 Text

### 现状
我们使用的是 Haskell 的 `String`，本质是 `[Char]` 链表，性能很差。

### 目标
把整个解析器迁移到 `Data.Text`：
1. 把 `String` 全部换成 `Text`
2. 输入不再用 `String -> Maybe (...)`，而是用 `Text` 的索引方式
3. 对比解析大 JSON 文件时的性能差异（可以用 `time` 命令）

### 学习目标
- 理解 Haskell 中 `String`、`Text`、`ByteString` 的区别
- 工业级 Haskell 项目的性能意识

---

## 最终挑战：用 Megaparsec 重写

当你完全理解了这个手写的 Parser Combinator 框架后，尝试用工业级库 [Megaparsec](https://hackage.haskell.org/package/megaparsec) 重写整个 JSON 解析器。

对比两者：
- 代码量差异
- 错误信息质量
- 性能差异
- API 设计哲学

这会是一次非常有价值的“站在巨人肩膀上”的体验。
