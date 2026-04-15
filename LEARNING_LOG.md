# 学习笔记 / Learning Log

> 记录 HSON 项目每次迭代的心得、踩坑与领悟。

---

## 2025-04-16 | 挑战 1：支持字符串转义

### 目标
让 JSON 字符串解析器支持标准转义序列：`\"`、`\\`、`\n`、`\t`。

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

1. **`<|>` 的回退机制**：Parser Combinator 中，失败不会破坏输入状态，`q` 会从头开始尝试。这让“尝试 A，不行就试 B”的写法变得非常自然。
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
