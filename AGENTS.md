# Agent Context: json-parser

## 项目定位

这是一个**教学型 Haskell 项目**，目标是帮助初学者从零理解 Parser Combinator、Functor/Applicative/Monad/Alternative 类型类，以及递归下降解析。

**核心约束**：
- 尽量不使用外部解析库（如 Parsec / Megaparsec），除非进入最终挑战。
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
| `src/Json/Types.hs` | JSON 的 ADT 定义，保持最小化 |
| `src/Json/Parser.hs` | Parser Combinator 框架 + JSON 解析逻辑，是教学核心 |
| `app/Main.hs` | IO 入口、命令行参数处理、美化打印输出 |
| `CHALLENGES.md` | 进阶路线图，不应被随意删减 |
| `README.md` | 面向人类学习者，保持友好和详细 |

## 常见修改场景

### 添加新解析器
如果要在 `Parser.hs` 里添加新的解析能力（如转义字符），请：
1. 先写独立的小解析器（如 `parseEscapedChar`）
2. 在原有解析器的适当位置用 `<|>` 组合进去
3. 在 `README.md` 或 `CHALLENGES.md` 中更新对应说明

### 修改核心类型
如果要将 `Maybe` 升级为 `Either`（挑战 3），需要同步修改：
1. `Parser` 的 `newtype` 定义
2. `Functor` / `Applicative` / `Monad` / `Alternative` / `MonadFail` 实例
3. `app/Main.hs` 中对 `runParser` 结果的模式匹配

### 运行测试
目前没有测试套件。验证方式是：
```bash
cabal build
echo '<json>' | cabal run exe:json-parser
```
