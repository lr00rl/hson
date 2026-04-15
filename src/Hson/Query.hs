{-|
模块：Hson.Query

JSON Path 查询的小型 DSL。

支持语法：
  - .key        访问对象字段
  - [n]         访问数组索引
  - 链式组合    .data.users[0].name

这是挑战 5 的实现，展示了如何在纯函数中构建小型领域特定语言。
-}
module Hson.Query
  ( PathSegment(..)
  , parsePath
  , query
  , queryString
  ) where

import Data.Char (isDigit)
import Hson.Types (JsonValue(..))

-- | 路径段的代数数据类型。
--
-- `Key String`  表示对象字段访问，如 `.name`
-- `Index Int`   表示数组索引访问，如 `[0]`
data PathSegment
  = Key String
  | Index Int
  deriving (Eq, Show)

-- | 解析路径字符串为路径段列表。
--
-- 示例：
--   parsePath ".data.users[0].name"
--   => Just [Key "data", Key "users", Index 0, Key "name"]
--
--   parsePath "[0][1]"
--   => Just [Index 0, Index 1]
parsePath :: String -> Maybe [PathSegment]
parsePath [] = Just []
parsePath ('.':cs) =
  let (key, rest) = span (`notElem` "[.") cs
  in if null key
       then Nothing
       else (Key key :) <$> parsePath rest
parsePath ('[':cs) =
  case span isDigit cs of
    (digits, ']':rest) | not (null digits) ->
      (Index (read digits) :) <$> parsePath rest
    _ -> Nothing
parsePath _ = Nothing

-- | 用路径段列表查询 JsonValue。
--
-- 如果任意一步不匹配（类型错误或索引越界），返回 Nothing。
query :: [PathSegment] -> JsonValue -> Maybe JsonValue
query [] json = Just json
query (Key k : rest) (JsonObject pairs) =
  case lookup k pairs of
    Just v  -> query rest v
    Nothing -> Nothing
query (Index i : rest) (JsonArray xs)
  | i >= 0 && i < length xs = query rest (xs !! i)
  | otherwise               = Nothing
query _ _ = Nothing

-- | 便捷的字符串路径查询入口。
queryString :: String -> JsonValue -> Maybe JsonValue
queryString path json = parsePath path >>= flip query json
