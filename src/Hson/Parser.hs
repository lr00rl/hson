{-|
模块：Json.Parser

这是整个项目最核心的教学模块。我们在这里从零实现了一个
Parser Combinator 框架，并用它解析完整的 JSON。

核心知识点：
  1. Parser Combinator：把解析器抽象成 `String -> Maybe (a, String)`
  2. Functor：变换解析结果（fmap）
  3. Applicative：组合多个独立解析器（<*>）
  4. Monad：让后一步解析依赖前一步结果（>>= / do）
  5. Alternative：实现分支(<|>)、重复(many)、可选(optional)
-}
module Hson.Parser
  ( Parser(..)
  , parseJson
  ) where

import Control.Applicative (Alternative(..))
import Hson.Types (JsonValue(..))

-- ========================================================================
-- Part 1: Parser Combinator 基础框架
-- ========================================================================

-- | 解析器类型。
--
-- 给它一个字符串，它要么失败（Nothing），
-- 要么成功并返回（解析结果, 剩余未解析的字符串）。
--
-- 这是纯函数式解析的核心：没有可变状态，没有全局指针，只有函数组合。
newtype Parser a = Parser { runParser :: String -> Maybe (a, String) }

-- | 解析一个满足条件的字符。
-- 如果输入首字符满足谓词 p，则消费它并返回；否则失败。
satisfy :: (Char -> Bool) -> Parser Char
satisfy p = Parser $ \input -> case input of
  (c:cs) | p c -> Just (c, cs)
  _            -> Nothing

-- | 精确匹配一个字符。
char :: Char -> Parser Char
char c = satisfy (== c)

-- | 匹配任意一个字符（只要输入非空就成功）。
anyChar :: Parser Char
anyChar = Parser $ \input -> case input of
  (c:cs) -> Just (c, cs)
  []     -> Nothing

-- | 精确匹配一个字符串。
--
-- 这是递归 + Applicative 的经典组合：
--   (:) <$> char c <*> string cs
-- 意思是：先解析首字符 char c，再递归解析剩余字符串 string cs，
-- 最后用 (:) 把它们组合成一个列表。
string :: String -> Parser String
string []     = pure []
string (c:cs) = (:) <$> char c <*> string cs

-- | 消费零个或多个空白字符（空格、制表符、换行、回车）。
spaces :: Parser ()
spaces = () <$ many (satisfy (`elem` " \t\n\r"))

-- | 词法包裹器：自动跳过解析器前后的空白字符。
-- 这让 JSON 解析对空白不敏感。
lexeme :: Parser a -> Parser a
lexeme p = spaces *> p <* spaces

-- ========================================================================
-- Part 2: 类型类实例 —— 让 Parser 可以组合
-- ========================================================================

-- | Functor：对解析结果做映射。
--
-- 如果你有一个 `Parser Char`，但想要 `Parser Int`，
-- 只要 fmap ord 即可。
instance Functor Parser where
  fmap f p = Parser $ \input -> case runParser p input of
    Just (x, rest) -> Just (f x, rest)
    Nothing        -> Nothing

-- | Applicative：组合多个独立的解析器。
--
-- `pure x` 创建一个永远成功、不消费输入、返回 x 的解析器。
-- `pf <*> px` 先运行 pf 得到一个函数 f，再运行 px 得到参数 x，
-- 最后返回 f x。
instance Applicative Parser where
  pure x = Parser $ \input -> Just (x, input)
  pf <*> px = Parser $ \input -> case runParser pf input of
    Just (f, rest1) -> runParser (fmap f px) rest1
    Nothing         -> Nothing

-- | Monad：按顺序绑定解析结果。
--
-- 后一步可以依赖前一步的结果。这就是 `do` 语法的底层机制。
-- 例如：
--   do c <- char 'a'
--      d <- char 'b'
--      return [c, d]
instance Monad Parser where
  p >>= f = Parser $ \input -> case runParser p input of
    Just (x, rest) -> runParser (f x) rest
    Nothing        -> Nothing

-- | Alternative：实现“或”逻辑、失败、重复。
--
-- `empty` 是永远失败的解析器。
-- `p <|> q` 先尝试 p，如果 p 失败则回退（backtrack）并尝试 q。
-- `many p` 和 `some p` 由 Alternative 默认提供，分别表示
-- “零个或多个 p”和“一个或多个 p”。
instance Alternative Parser where
  empty = Parser $ const Nothing
  p <|> q = Parser $ \input -> case runParser p input of
    Just result -> Just result
    Nothing     -> runParser q input

-- | MonadFail：支持 do 语法中的可失败模式匹配。
--
-- 例如：`JsonString key <- parseString`，如果 parseString 返回的不是
-- JsonString，就会调用 fail，进而返回 Nothing。
instance MonadFail Parser where
  fail _ = Parser $ const Nothing

-- ========================================================================
-- Part 3: 组合子工具
-- ========================================================================

-- | 解析逗号分隔的列表。
--
-- 这是 Parser Combinator 的“Hello World”：
--   sepBy p sep = (:) <$> p <*> many (sep *> p) <|> pure []
--
-- 解读：
--   1. 先解析一个 p
--   2. 然后解析零个或多个 (分隔符 + p)
--   3. 用 (:) 组合成列表
--   4. 如果一开始就没有 p，则回退到返回空列表
sepBy :: Parser a -> Parser sep -> Parser [a]
sepBy p sep = (:) <$> p <*> many (sep *> p) <|> pure []

-- ========================================================================
-- Part 4: JSON 专用解析器
-- ========================================================================

-- | 解析 JSON Null。
-- `JsonNull <$ string "null"` 的意思是：如果匹配到 "null"，返回 JsonNull。
parseNull :: Parser JsonValue
parseNull = JsonNull <$ string "null"

-- | 解析 JSON Bool。
-- 用 `<|>` 组合两个分支：先尝试 true，失败则回退尝试 false。
parseBool :: Parser JsonValue
parseBool = JsonBool True  <$ string "true"
        <|> JsonBool False <$ string "false"

-- | 解析 JSON Number（简化版）。
--
-- 这里我们“借用”了 Haskell 内置的 `reads` 函数来识别数字。
-- 在挑战 2 中，你会尝试完全手写这个数字解析器。
parseNumber :: Parser JsonValue
parseNumber = Parser $ \input -> case reads input of
  [(n, rest)] -> Just (JsonNumber n, rest)
  _           -> Nothing

-- | 解析 JSON 字符串中的单个转义字符。
--
-- 支持的转义序列：\" \\ \n \t
-- 这是挑战 1 的核心实现，展示了 Alternative 的实战用法：
-- 先尝试匹配转义序列，如果输入不是反斜杠开头，则整体失败。
parseEscapedChar :: Parser Char
parseEscapedChar = do
  _ <- char '\\'
  c <- anyChar
  case c of
    '"'  -> return '"'
    '\\' -> return '\\'
    'n'  -> return '\n'
    't'  -> return '\t'
    _    -> fail $ "Unknown escape sequence: \\ " ++ [c]

-- | 解析 JSON String（支持转义字符）。
--
-- 流程：匹配左引号 -> 读取零个或多个（转义字符 或 普通非引号字符） -> 匹配右引号。
--
-- 关键组合：many (parseEscapedChar <|> satisfy (/= '"'))
--   - parseEscapedChar 处理 \", \\, \n, \t
--   - satisfy (/= '"') 处理普通字符
--   - <|> 让解析器在每一步自动选择正确的分支
parseString :: Parser JsonValue
parseString = do
  _ <- char '"'
  s <- many (parseEscapedChar <|> satisfy (/= '"'))
  _ <- char '"'
  return $ JsonString s

-- | 解析 JSON Array。
--
-- 流程：[ -> 可选空白 -> 元素列表（逗号分隔） -> 可选空白 -> ]
-- 注意：parseArray 调用 parseJson，parseJson 又可能调用 parseArray，
-- 形成递归。Haskell 的惰性求值让这种写法非常自然。
parseArray :: Parser JsonValue
parseArray = do
  _ <- char '['
  spaces
  elems <- sepBy parseJson (spaces *> char ',' <* spaces)
  spaces
  _ <- char ']'
  return $ JsonArray elems

-- | 解析 JSON Object。
--
-- 流程：{ -> 可选空白 -> 键值对列表（逗号分隔） -> 可选空白 -> }
-- 每个键值对的键必须是一个 JSON 字符串。
parseObject :: Parser JsonValue
parseObject = do
  _ <- char '{'
  spaces
  pairs <- sepBy parsePair (spaces *> char ',' <* spaces)
  spaces
  _ <- char '}'
  return $ JsonObject pairs
  where
    parsePair = do
      JsonString key <- lexeme parseString
      _ <- char ':'
      spaces
      value <- parseJson
      return (key, value)

-- | 解析任意 JSON 值 —— 这是总入口。
--
-- 顺序很重要：我们把更具体、更不容易混淆的类型放在前面。
-- 例如，parseBool 的 "true"/"false" 不会和 parseString 冲突，
-- 但 parseNumber 如果放在 parseBool 前面，在某些复杂解析器里可能导致问题。
parseJson :: Parser JsonValue
parseJson = lexeme $ parseNull
                    <|> parseBool
                    <|> parseString
                    <|> parseArray
                    <|> parseObject
                    <|> parseNumber
