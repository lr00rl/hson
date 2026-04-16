# Agent Context: hson

## 项目定位

这是一个**教学型 Haskell 项目**，目标是帮助初学者从零理解 Parser Combinator、Functor/Applicative/Monad/Alternative 类型类，以及递归下降解析。

**核心约束**：
- 手写解析器（`src/Hson/Parser.hs`）尽量零外部依赖；`hson-megaparsec`（`src/Hson/MegaParser.hs`）作为对比实现。
- 代码需要兼顾教学性和可运行性。
- 注释以中文为主，关键术语保留英文（如 `Functor`, `Applicative`, `Monad`）。

## 代码风格

- 使用 `Haskell2010` 或 `GHC2021` 语言标准
- 缩进：2 个空格
- 函数签名必须显式写出（除非非常简短的 where 局部函数）
- 每个导出函数和关键类型都应有 `-- | Haddock 风格` 的注释
- 避免过度优化，优先可读性

## 文件职责

| 文件 | 职责 |
|------|------|
| `src/Hson/Types.hs` | JSON 的 ADT 定义，保持最小化 |
| `src/Hson/Parser.hs` | 手写 Parser Combinator 框架 + JSON 解析逻辑，是教学核心 |
| `src/Hson/Query.hs` | JSON Path DSL（`.key`、`[index]`、`[]` 通配） |
| `src/Hson/Class.hs` | `FromJson` 类型类 + GHC.Generics 自动推导 |
| `src/Hson/ToJson.hs` | `ToJson` 类型类 + 编码器（pretty / compact / color） |
| `src/Hson/MegaParser.hs` | Megaparsec 实现的工业级对比版本 |
| `app/Main.hs` | `hson` CLI：IO 入口、参数处理、输出编码 |
| `app/MegaMain.hs` | `hson-megaparsec` CLI，需与 `app/Main.hs` 保持功能同步 |
| `test/Spec.hs` | Hspec 测试套件 |
| `CHALLENGES.md` | 进阶路线图，不应被随意删减 |
| `README.md` | 面向人类学习者，保持友好和详细 |

## 常见修改场景

### 添加新 CLI 功能
1. 在 `app/Main.hs` 中实现并手动测试。
2. **必须同步到 `app/MegaMain.hs`**（如参数解析、编码器选择、path 查询逻辑）。
3. 更新 `README.md` 中的 Quick Start 示例。
4. 如添加了新依赖（如 `ansi-terminal`），检查 `hson.cabal` 中 `executable hson` 与 `executable hson-megaparsec` 是否都已声明。

### 修改 Query / PathSegment
如果改动 `Hson.Query` 的 `PathSegment` 或 `query` 逻辑：
1. 在 `test/Spec.hs` 中补充用例。
2. 确保 `app/Main.hs` 与 `app/MegaMain.hs` 无需改动即可使用新查询能力。

### 运行测试
```bash
cabal build
cabal test
```

### 快速手动验证 CLI
```bash
# 基础解析 + 颜色
echo '{"a":1}' | cabal run hson -- --color

# 紧凑输出
echo '{"a":1}' | cabal run hson -- -c

# JSON Path 查询
echo '{"users":[{"name":"Alice"}]}' | cabal run hson -- .users[0].name

# 数组通配
echo '{"users":[{"name":"Alice"},{"name":"Bob"}]}' | cabal run hson -- .users[].name

# 原始字符串
echo '{"name":"Alice"}' | cabal run hson -- -r .name

# Megaparsec 版本功能一致性
echo '{"a":1}' | cabal run hson-megaparsec -- -c --color
```
