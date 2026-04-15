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

## 挑战 2：手写数字解析器

### 现状
当前 `parseNumber` 使用了 Haskell 内置的 `reads`，虽然能用，但**作弊了**。它不是一个真正的 Parser Combinator 作品。

### 目标
完全用 Parser Combinator 重写 `parseNumber`，支持：
- 整数：`42`, `-7`
- 小数：`3.14`, `-0.5`
- 科学计数法：`1e10`, `2.5E-3`

### 提示
把数字拆成几个小解析器组合：
```haskell
parseSign    = optional (char '-')    -- 负号可选
parseDigits  = some digit             -- 一个或多个数字
parseDot     = optional (...)         -- 小数点及后续数字可选
parseExp     = optional (...)         -- e/E 及后续指数可选
```

最后把它们拼接成一个 `String`，再用 `read :: String -> Double` 转成数字。

### 学习目标
- `optional`、`some`、`many` 的组合使用
- 如何把多个小解析器组装成复杂解析器

---

## 挑战 3：从 Maybe 到 Either — 精确错误报告

### 现状
解析失败时，我们只能得到冰冷的 `Nothing`，用户完全不知道哪里出错了。

### 目标
把解析器核心类型从：
```haskell
Parser a = String -> Maybe (a, String)
```
升级为：
```haskell
data ParseError = ParseError
  { peMessage :: String
  , peInput   :: String
  , peLine    :: Int
  , peCol     :: Int
  }

type Parser a = String -> Either ParseError (a, String)
```

然后修改所有类型类实例和解析器，使其在遇到失败时报告：
- 错误信息（如 `"Expected ',' but found '}'"`）
- 当前行号和列号

### 提示
- 需要修改 `newtype Parser a = Parser { runParser :: String -> Either ParseError (a, String) }`
- `satisfy`、`char`、`string` 等基础解析器是唯一真正消费输入的地方，错误报告主要在这里产生
- `Alternative` 的 `<|>` 在这里要注意：如果左边失败了，要尝试右边，但**如果两边都失败**，你应该返回更“深入”的那个错误，而不是第一个或最后一个

### 学习目标
- 理解 `Either` Monad
- 错误处理的设计权衡（错误恢复 vs 精确报告）
- 这是工业级解析器（如 Megaparsec）的核心课题

---

## 挑战 4：JSON Path 查询

### 目标
在 `JsonValue` 上实现一个查询函数：

```haskell
jsonQuery :: String -> JsonValue -> Maybe JsonValue
```

支持类似 JavaScript 的访问语法：
- `.name` -> 访问对象字段
- `[0]` -> 访问数组索引
- 链式组合：`.data.users[0].name`

### 示例
```haskell
let json = JsonObject [("data", JsonArray [JsonObject [("name", JsonString "Alice")]])]
jsonQuery ".data[0].name" json  -- => Just (JsonString "Alice")
```

### 提示
- 先实现一个小型路径解析器，把 `".data[0].name"` 解析成 `[Key "data", Index 0, Key "name"]`
- 然后对 `JsonValue` 做 fold

### 学习目标
- 递归数据结构上的遍历（fold）
- 小型领域特定语言（DSL）的构建

---

## 挑战 5：泛型反序列化 — FromJson 类型类

### 目标
实现一个类型类 `FromJson`，让 Haskell 能自动把 `JsonValue` 转换成自定义的 Record 类型：

```haskell
class FromJson a where
  fromJson :: JsonValue -> Either String a

data User = User
  { userName  :: String
  , userAge   :: Int
  , userEmail :: Maybe String
  } deriving (Show)

instance FromJson User where
  fromJson (JsonObject pairs) = do
    name  <- lookupField "name" pairs >>= asString
    age   <- lookupField "age" pairs >>= asInt
    email <- lookupOptional "email" pairs >>= traverse asString
    return $ User name age email
  fromJson _ = Left "Expected object"
```

### 进阶目标（地狱难度）
研究 `GHC.Generics`，让 `User` 类型可以自动派生 `FromJson`：
```haskell
data User = User { ... } deriving (Generic, FromJson)
```

### 学习目标
- Haskell 类型类的深层设计
- `Maybe`、`Either`、`traverse` 等函数的组合
- 泛型编程（Generics）的入门

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
