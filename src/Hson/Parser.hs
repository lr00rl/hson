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
  7. Data.Text 迁移：用高效的文本表示替代 [Char]
-}
{-# LANGUAGE OverloadedStrings #-}

module Hson.Parser
  ( Parser(..)
  , ParseError(..)
  , parse
  , parseJson
  ) where

import Control.Applicative (Alternative(..), optional)
import Data.Char (chr, ord)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Read as TR
import Hson.Types (JsonValue(..))

-- ========================================================================
-- Part 1: 状态与错误类型
-- ========================================================================

-- | 解析状态，包含剩余输入、当前行号和列号。
--
-- 使用 Data.Text 替代 String，避免 [Char] 链表的线性索引开销。
data State = State
  { sInput :: Text    -- ^ 剩余未解析的输入
  , sLine  :: Int     -- ^ 当前行号（从 1 开始）
  , sCol   :: Int     -- ^ 当前列号（从 1 开始）
  } deriving (Show)

-- | 解析错误，包含错误信息、发生位置和上下文。
data ParseError = ParseError
  { peMessage :: String  -- ^ 错误描述
  , peLine    :: Int     -- ^ 错误发生的行号
  , peCol     :: Int     -- ^ 错误发生的列号
  , peInput   :: Text    -- ^ 错误发生时的剩余输入（用于调试）
  } deriving (Eq, Show)

-- | 根据消费的字符更新行列号。
advanceState :: State -> Char -> State
advanceState st c
  | c == '\n' = State (T.tail (sInput st)) (sLine st + 1) 1
  | otherwise = State (T.tail (sInput st)) (sLine st) (sCol st + 1)

-- | 选择"走得更远"的错误。
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
newtype Parser a = Parser { runParser :: State -> Either ParseError (a, State) }

-- | 便捷的入口函数：从 Text 开始解析。
parse :: Parser a -> Text -> Either ParseError (a, Text)
parse p input = case runParser p (State input 1 1) of
  Right (x, st) -> Right (x, sInput st)
  Left err      -> Left err

-- | 解析一个满足条件的字符。
satisfy :: (Char -> Bool) -> Parser Char
satisfy p = Parser $ \st -> case T.uncons (sInput st) of
  Just (c, _) | p c -> Right (c, advanceState st c)
  Just (c, _)       -> Left $ ParseError ("Unexpected character: " ++ show c ++ " (expected something else)") (sLine st) (sCol st) (sInput st)
  Nothing           -> Left $ ParseError "Unexpected end of input" (sLine st) (sCol st) (sInput st)

-- | 精确匹配一个字符。
char :: Char -> Parser Char
char expected = Parser $ \st -> case T.uncons (sInput st) of
  Just (c, _) | c == expected -> Right (c, advanceState st c)
  Just (c, _)                 -> Left $ ParseError ("Expected '" ++ [expected] ++ "' but found " ++ show c) (sLine st) (sCol st) (sInput st)
  Nothing                     -> Left $ ParseError ("Expected '" ++ [expected] ++ "' but reached end of input") (sLine st) (sCol st) (sInput st)

-- | 匹配任意一个字符（只要输入非空就成功）。
anyChar :: Parser Char
anyChar = Parser $ \st -> case T.uncons (sInput st) of
  Just (c, _) -> Right (c, advanceState st c)
  Nothing     -> Left $ ParseError "Unexpected end of input" (sLine st) (sCol st) (sInput st)

-- | 精确匹配一个 Text 前缀。
string :: Text -> Parser Text
string expected = Parser $ \st ->
  let inp = sInput st
  in if T.isPrefixOf expected inp
       then Right (expected, st { sInput = T.drop (T.length expected) inp })
       else Left $ ParseError ("Expected " ++ show expected) (sLine st) (sCol st) inp

-- | 重复运行解析器 n 次，收集结果列表。
count :: Int -> Parser a -> Parser [a]
count n _ | n <= 0    = pure []
count n p             = (:) <$> p <*> count (n - 1) p

-- | 字符是否在指定的字符串中（辅助函数，避免 OverloadedStrings 带来的类型歧义）。
charIn :: String -> Char -> Bool
charIn chars c = c `elem` chars

-- | 消费零个或多个空白字符。
spaces :: Parser ()
spaces = () <$ many (satisfy (charIn " \t\n\r"))

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

-- | 解析 JSON Number（严格遵循 RFC 8259）。
--
-- 使用 Data.Text.Read.double 进行高性能数字转换。
parseNumber :: Parser JsonValue
parseNumber = do
  sign     <- optional (char '-')
  intPart  <- parseInt
  fracPart <- parseOptionalFrac
  expPart  <- optional parseExp
  let numTxt = maybe T.empty (T.singleton) sign <> intPart <> maybe T.empty id fracPart <> maybe T.empty id expPart
  case TR.double numTxt of
    Right (n, rest) | T.null rest -> return $ JsonNumber n
    _                             -> fail "Invalid number format"
  where
    parseInt = do
      first <- satisfy (charIn "0123456789")
      if first == '0'
        then do
          Parser $ \st -> case T.uncons (sInput st) of
            Just (c, _) | charIn "0123456789" c ->
              Left $ ParseError "Leading zeros are not allowed in JSON numbers" (sLine st) (sCol st) (sInput st)
            _ -> Right ((), st)
          return (T.singleton '0')
        else do
          rest <- many (satisfy (charIn "0123456789"))
          return (T.pack (first : rest))

    parseOptionalFrac = Parser $ \st ->
      case T.uncons (sInput st) of
        Just ('.', _) ->
          case runParser parseFrac st of
            Right (txt, st') -> Right (Just txt, st')
            Left err         -> Left err
        _ -> Right (Nothing, st)
      where
        parseFrac = do
          _      <- char '.'
          digits <- some (satisfy (charIn "0123456789"))
          return (T.cons '.' (T.pack digits))

    parseExp = do
      e      <- satisfy (charIn "eE")
      sign'  <- optional (satisfy (charIn "+-"))
      digits <- some (satisfy (charIn "0123456789"))
      return (T.pack (e : maybe [] (:[]) sign' ++ digits))

hexDigit :: Parser Char
hexDigit = satisfy (charIn "0123456789abcdefABCDEF")

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
  return $ JsonString (T.pack s)

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
