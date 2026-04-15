{-|
模块：Hson.MegaParser

最终挑战：用工业级库 Megaparsec 重写 JSON 解析器，
与手写的 Hson.Parser 进行对比。

你会发现：核心思路几乎相同，但 Megaparsec 提供了大量
开箱即用的组合子和更好的错误信息。
-}
{-# LANGUAGE OverloadedStrings #-}

module Hson.MegaParser
  ( parseJson
  , runMega
  ) where

import Data.Char (chr, ord)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Read as TR
import Data.Void (Void)
import Text.Megaparsec
import Text.Megaparsec.Char
import qualified Text.Megaparsec.Char.Lexer as L
import Hson.Types (JsonValue(..))

-- | 基于 Megaparsec 的解析器类型。
-- Void 表示我们不使用自定义错误组件，Text 是输入类型。
type Parser = Parsec Void Text

-- | 空白字符消费器（空格、制表符、换行、回车）。
sc :: Parser ()
sc = L.space space1 empty empty

-- | 自动跳过前后空白的词法解析器。
lexeme :: Parser a -> Parser a
lexeme = L.lexeme sc

-- | 精确匹配一个符号字符串，并跳过后续空白。
symbol :: Text -> Parser Text
symbol = L.symbol sc

-- | 便捷的入口函数。
runMega :: Parser a -> Text -> Either (ParseErrorBundle Text Void) (a, Text)
runMega p input = runParser p' "<input>" input
  where
    p' = do
      result <- p
      rest   <- getInput
      return (result, rest)

-- | 解析 JSON 入口。
parseJson :: Parser JsonValue
parseJson = between sc eof pValue

-- | 解析任意 JSON 值。
pValue :: Parser JsonValue
pValue = choice
  [ pNull
  , pBool
  , pString
  , pArray
  , pObject
  , pNumber
  ]

pNull :: Parser JsonValue
pNull = JsonNull <$ symbol "null"

pBool :: Parser JsonValue
pBool = JsonBool True  <$ symbol "true"
    <|> JsonBool False <$ symbol "false"

-- | 解析 JSON String 的原始 Text 内容。
pStringText :: Parser Text
pStringText = T.pack <$> between (char '"') (char '"') (many pChar)
  where
    pChar = pEscaped <|> satisfy (\c -> c /= '"' && c /= '\\' && ord c >= 0x20)

    pEscaped = char '\\' >> choice
      [ '"'  <$ char '"'
      , '\\' <$ char '\\'
      , '/'  <$ char '/'
      , '\b' <$ char 'b'
      , '\f' <$ char 'f'
      , '\n' <$ char 'n'
      , '\r' <$ char 'r'
      , '\t' <$ char 't'
      , char 'u' >> pUnicode
      ]

    pUnicode = do
      hex <- count 4 hexDigitChar
      let code = read ("0x" ++ hex) :: Int
      if code >= 0xD800 && code <= 0xDBFF
        then do
          _ <- char '\\'
          _ <- char 'u'
          hex2 <- count 4 hexDigitChar
          let low = read ("0x" ++ hex2) :: Int
          if low >= 0xDC00 && low <= 0xDFFF
            then return $ chr $ 0x10000 + ((code - 0xD800) * 0x400) + (low - 0xDC00)
            else fail "Invalid surrogate pair"
        else return $ chr code

pString :: Parser JsonValue
pString = JsonString <$> lexeme pStringText

-- | 解析 JSON Number（严格遵循 RFC 8259）。
pNumber :: Parser JsonValue
pNumber = lexeme $ do
  sign     <- optional (char '-')
  intPart  <- pInt
  fracPart <- optional pFrac
  expPart  <- optional pExp
  let numTxt = maybe T.empty T.singleton sign <> intPart <> maybe T.empty id fracPart <> maybe T.empty id expPart
  case TR.double numTxt of
    Right (n, rest) | T.null rest -> return $ JsonNumber n
    _                             -> fail "Invalid number format"
  where
    pInt = do
      first <- digitChar
      if first == '0'
        then do
          notFollowedBy digitChar
          return (T.singleton '0')
        else do
          rest <- many digitChar
          return (T.pack (first : rest))

    pFrac = do
      _      <- char '.'
      digits <- some digitChar
      return (T.cons '.' (T.pack digits))

    pExp = do
      e      <- char 'e' <|> char 'E'
      sign'  <- optional (char '+' <|> char '-')
      digits <- some digitChar
      return (T.pack (e : maybe [] (:[]) sign' ++ digits))

pArray :: Parser JsonValue
pArray = JsonArray <$> between (symbol "[") (symbol "]") (pValue `sepBy` symbol ",")

pObject :: Parser JsonValue
pObject = JsonObject <$> between (symbol "{") (symbol "}") (pPair `sepBy` symbol ",")
  where
    pPair = do
      key <- lexeme pStringText
      _ <- symbol ":"
      value <- pValue
      return (key, value)
