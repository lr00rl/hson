{-|
模块：Hson.Parser

这是整个项目最核心的教学模块。我们在这里从零实现了一个
Parser Combinator 框架，并用它解析完整的 JSON。

核心知识点：
  1. Parser Combinator：把解析器抽象成状态传递函数
  2. Functor：变换解析结果（fmap）
  3. Applicative：组合多个独立解析器（<*>）
  4. Monad：让后一步解析依赖前一步结果（>>= / do）
  5. Alternative：实现分支(<|>)、重复(many)、可选(optional)
  6. 精确错误报告：Either ParseError + 行列号追踪
-}
module Hson.Parser
  ( Parser(..)
  , ParseError(..)
  , parse
  , parseJson
  ) where

import Control.Applicative (Alternative(..), optional)
import Data.Char (chr, ord)
import Hson.Types (JsonValue(..))

-- ========================================================================
-- Part 1: 状态与错误类型
-- ========================================================================

-- | 解析状态，包含剩余输入、当前行号和列号。
data State = State
  { sInput :: String  -- ^ 剩余未解析的输入
  , sLine  :: Int     -- ^ 当前行号（从 1 开始）
  , sCol   :: Int     -- ^ 当前列号（从 1 开始）
  } deriving (Show)

-- | 解析错误，包含错误信息、发生位置和上下文。
data ParseError = ParseError
  { peMessage :: String  -- ^ 错误描述
  , peLine    :: Int     -- ^ 错误发生的行号
  , peCol     :: Int     -- ^ 错误发生的列号
  , peInput   :: String  -- ^ 错误发生时的剩余输入（用于调试）
  } deriving (Eq, Show)

-- | 根据消费的字符更新行列号。
advanceState :: State -> Char -> State
advanceState st c
  | c == '\n' = State (tailInput) (sLine st + 1) 1
  | otherwise = State (tailInput) (sLine st) (sCol st + 1)
  where
    tailInput = case sInput st of
      (_:cs) -> cs
      []     -> []

-- | 选择"走得更远"的错误。
--
-- 在 Parser Combinator 的 "或" 分支中，如果两边都失败，
-- 通常意味着用户期望的是"走得最远"的那个语法结构。
farthestError :: ParseError -> ParseError -> ParseError
farthestError e1 e2
  | peLine e1 > peLine e2 = e1
  | peLine e1 < peLine e2 = e2
  | peCol e1 >= peCol e2  = e1
  | otherwise             = e2

-- ========================================================================
-- Part 2: Parser Combinator 基础框架
-- ========================================================================

-- | 解析器类型。
--
-- 给它一个 State，它要么失败并返回 ParseError（带行列号），
-- 要么成功并返回（结果, 新状态）。
newtype Parser a = Parser { runParser :: State -> Either ParseError (a, State) }

-- | 便捷的入口函数：从字符串开始解析。
parse :: Parser a -> String -> Either ParseError (a, String)
parse p input = case runParser p (State input 1 1) of
  Right (x, st) -> Right (x, sInput st)
  Left err      -> Left err

-- | 解析一个满足条件的字符。
-- 如果输入首字符满足谓词 p，则消费它并返回；否则失败，带上当前位置信息。
satisfy :: (Char -> Bool) -> Parser Char
satisfy p = Parser $ \st -> case sInput st of
  (c:_) | p c -> Right (c, advanceState st c)
  (c:cs)      -> Left $ ParseError ("Unexpected character: " ++ show c ++ " (expected something else)") (sLine st) (sCol st) (c:cs)
  []          -> Left $ ParseError "Unexpected end of input" (sLine st) (sCol st) []

-- | 精确匹配一个字符。
char :: Char -> Parser Char
char expected = Parser $ \st -> case sInput st of
  (c:_) | c == expected -> Right (c, advanceState st c)
  (c:cs)                -> Left $ ParseError ("Expected '" ++ [expected] ++ "' but found " ++ show c) (sLine st) (sCol st) (c:cs)
  []                    -> Left $ ParseError ("Expected '" ++ [expected] ++ "' but reached end of input") (sLine st) (sCol st) []

-- | 匹配任意一个字符（只要输入非空就成功）。
anyChar :: Parser Char
anyChar = Parser $ \st -> case sInput st of
  (c:_) -> Right (c, advanceState st c)
  []    -> Left $ ParseError "Unexpected end of input" (sLine st) (sCol st) []

-- | 精确匹配一个字符串。
string :: String -> Parser String
string []     = pure []
string (c:cs) = (:) <$> char c <*> string cs

-- | 重复运行解析器 n 次，收集结果列表。
count :: Int -> Parser a -> Parser [a]
count n _ | n <= 0    = pure []
count n p             = (:) <$> p <*> count (n - 1) p

-- | 消费零个或多个空白字符。
spaces :: Parser ()
spaces = () <$ many (satisfy (`elem` " \t\n\r"))

-- | 词法包裹器：自动跳过解析器前后的空白字符。
lexeme :: Parser a -> Parser a
lexeme p = spaces *> p <* spaces

-- ========================================================================
-- Part 3: 类型类实例
-- ========================================================================

instance Functor Parser where
  fmap f p = Parser $ \st -> case runParser p st of
    Right (x, st') -> Right (f x, st')
    Left err       -> Left err

instance Applicative Parser where
  pure x = Parser $ \st -> Right (x, st)
  pf <*> px = Parser $ \st -> case runParser pf st of
    Right (f, st1) -> runParser (fmap f px) st1
    Left err       -> Left err

instance Monad Parser where
  p >>= f = Parser $ \st -> case runParser p st of
    Right (x, st') -> runParser (f x) st'
    Left err       -> Left err

instance Alternative Parser where
  empty = Parser $ \st -> Left $ ParseError "Empty alternative" (sLine st) (sCol st) (sInput st)
  p <|> q = Parser $ \st -> case runParser p st of
    Right ok    -> Right ok
    Left err1   -> case runParser q st of
      Right ok    -> Right ok
      Left err2   -> Left (farthestError err1 err2)

instance MonadFail Parser where
  fail msg = Parser $ \st -> Left $ ParseError msg (sLine st) (sCol st) (sInput st)

-- ========================================================================
-- Part 4: 组合子工具
-- ========================================================================

-- | 解析逗号分隔的列表。
--
-- 关键语义：如果 p 在消费了输入后失败，错误会被传播（不会回退为空列表）。
-- 只有 p 在完全没有消费输入的情况下失败，才返回空列表。
sepBy :: Parser a -> Parser sep -> Parser [a]
sepBy p sep = Parser $ \st -> case runParser p st of
  Right (x, st1) -> case runParser (many (sep *> p)) st1 of
    Right (xs, st2) -> Right (x:xs, st2)
    Left err        -> Left err
  Left err ->
    if peLine err == sLine st && peCol err == sCol st
      then Right ([], st)
      else Left err

-- ========================================================================
-- Part 5: JSON 专用解析器（严格遵循 RFC 8259）
-- ========================================================================

parseNull :: Parser JsonValue
parseNull = JsonNull <$ string "null"

parseBool :: Parser JsonValue
parseBool = JsonBool True  <$ string "true"
        <|> JsonBool False <$ string "false"

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
        then do
          -- RFC 8259: 前导零后面不能紧跟数字
          Parser $ \st -> case sInput st of
            (c:_) | c `elem` "0123456789" ->
              Left $ ParseError "Leading zeros are not allowed in JSON numbers" (sLine st) (sCol st) (sInput st)
            _ -> Right ((), st)
          return "0"
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

hexDigit :: Parser Char
hexDigit = satisfy (`elem` "0123456789abcdefABCDEF")

parseUnicodeEscape :: Parser Char
parseUnicodeEscape = do
  hex <- count 4 hexDigit
  let code = read ("0x" ++ hex) :: Int
  if code >= 0xD800 && code <= 0xDBFF
    then do
      _    <- char '\\'
      _    <- char 'u'
      hex2 <- count 4 hexDigit
      let low = read ("0x" ++ hex2) :: Int
      if low >= 0xDC00 && low <= 0xDFFF
        then return $ chr $ 0x10000 + ((code - 0xD800) * 0x400) + (low - 0xDC00)
        else fail "Invalid surrogate pair"
    else return $ chr code

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

isUnescaped :: Char -> Bool
isUnescaped c = ord c >= 0x20 && c /= '"' && c /= '\\'

parseString :: Parser JsonValue
parseString = do
  _ <- char '"'
  s <- many (parseEscapedChar <|> satisfy isUnescaped)
  _ <- char '"'
  return $ JsonString s

parseArray :: Parser JsonValue
parseArray = do
  _ <- char '['
  spaces
  elems <- sepBy parseJson (spaces *> char ',' <* spaces)
  spaces
  _ <- char ']'
  return $ JsonArray elems

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

parseJson :: Parser JsonValue
parseJson = lexeme $ parseNull
                    <|> parseBool
                    <|> parseString
                    <|> parseArray
                    <|> parseObject
                    <|> parseNumber
