{-|
模块：Hson.Parser

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

import Control.Applicative (Alternative(..), optional)
import Data.Char (chr, ord)
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

-- | 重复运行解析器 n 次，收集结果列表。
count :: Int -> Parser a -> Parser [a]
count n _ | n <= 0    = pure []
count n p             = (:) <$> p <*> count (n - 1) p

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

-- | Alternative：实现"或"逻辑、失败、重复。
--
-- `empty` 是永远失败的解析器。
-- `p <|> q` 先尝试 p，如果 p 失败则回退（backtrack）并尝试 q。
-- `many p` 和 `some p` 由 Alternative 默认提供，分别表示
-- "零个或多个 p"和"一个或多个 p"。
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
-- 这是 Parser Combinator 的"Hello World"：
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
-- Part 4: JSON 专用解析器（严格遵循 RFC 8259）
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

-- | 解析 JSON Number（严格遵循 RFC 8259）。
--
-- ABNF（RFC 8259 Section 6）：
--   number = [ minus ] int [ frac ] [ exp ]
--   int    = zero / ( digit1-9 *DIGIT )
--   frac   = decimal-point 1*DIGIT
--   exp    = e [ minus / plus ] 1*DIGIT
--
-- 非法示例：01, 1., .5, 1e, 1e+
parseNumber :: Parser JsonValue
parseNumber = do
  sign     <- optional (char '-')
  intPart  <- parseInt
  fracPart <- optional parseFrac
  expPart  <- optional parseExp
  let numStr = maybe "" (:[]) sign ++ intPart ++ maybe "" id fracPart ++ maybe "" id expPart
  return $ JsonNumber (read numStr)
  where
    parseInt = do
      first <- satisfy (`elem` "0123456789")
      if first == '0'
        then return "0"
        else do
          rest <- many (satisfy (`elem` "0123456789"))
          return (first : rest)

    parseFrac = do
      _      <- char '.'
      digits <- some (satisfy (`elem` "0123456789"))
      return ('.' : digits)

    parseExp = do
      e      <- satisfy (`elem` "eE")
      sign   <- optional (satisfy (`elem` "+-"))
      digits <- some (satisfy (`elem` "0123456789"))
      return (e : maybe "" (:[]) sign ++ digits)

-- | 解析十六进制数字字符。
hexDigit :: Parser Char
hexDigit = satisfy (`elem` "0123456789abcdefABCDEF")

-- | 解析 \uXXXX Unicode 转义序列。
--
-- 根据 RFC 8259，如果 \uXXXX 是一个高代理项（U+D800-U+DBFF），
-- 则后面必须紧跟一个低代理项（\uDC00-\uDFFF），两者组合成一个
-- Unicode code point（如 U+1D11E 表示为 \uD834\uDD1E）。
parseUnicodeEscape :: Parser Char
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

-- | 解析 JSON 字符串中的单个转义字符。
--
-- 严格遵循 RFC 8259 的 escape 定义：
--   \" \\ \/ \b \f \n \r \t \uXXXX
parseEscapedChar :: Parser Char
parseEscapedChar = do
  _ <- char '\\'
  c <- anyChar
  case c of
    '"'  -> return '"'
    '\\' -> return '\\'
    '/'  -> return '/'
    'b'  -> return '\b'
    'f'  -> return '\f'
    'n'  -> return '\n'
    'r'  -> return '\r'
    't'  -> return '\t'
    'u'  -> parseUnicodeEscape
    _    -> fail $ "Invalid escape sequence: \\ " ++ [c]

-- | 判断字符是否是合法的 JSON 未转义字符。
--
-- RFC 8259: unescaped = %x20-21 / %x23-5B / %x5D-10FFFF
-- 即：不允许裸的 control characters (U+0000-U+001F)、引号、反斜杠。
isUnescaped :: Char -> Bool
isUnescaped c = ord c >= 0x20 && c /= '"' && c /= '\\'

-- | 解析 JSON String（严格遵循 RFC 8259）。
--
-- 流程：匹配左引号 -> 读取零个或多个（转义字符 或 合法未转义字符） -> 匹配右引号。
parseString :: Parser JsonValue
parseString = do
  _ <- char '"'
  s <- many (parseEscapedChar <|> satisfy isUnescaped)
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
