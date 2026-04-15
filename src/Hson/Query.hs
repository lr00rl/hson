{-|
模块：Hson.Query

JSON Path 查询的小型 DSL。

支持语法：
  - .key        访问对象字段
  - [n]         访问数组索引
  - 链式组合    .data.users[0].name

这是挑战 5 的实现，展示了如何在纯函数中构建小型领域特定语言。
-}
{-# LANGUAGE OverloadedStrings #-}

module Hson.Query
  ( PathSegment(..)
  , parsePath
  , query
  , queryString
  ) where

import Data.Char (isDigit)
import Data.Text (Text)
import qualified Data.Text as T
import Hson.Types (JsonValue(..))

-- | 路径段的代数数据类型。
data PathSegment
  = Key Text
  | Index Int
  deriving (Eq, Show)

-- | 解析路径字符串为路径段列表。
parsePath :: Text -> Maybe [PathSegment]
parsePath t | T.null t = Just []
parsePath t =
  case T.uncons t of
    Just ('.', cs) ->
      let (key, rest) = T.break (`elem` ['[', '.']) cs
      in if T.null key
           then Nothing
           else (Key key :) <$> parsePath rest
    Just ('[', cs) ->
      let (digits, rest0) = T.span isDigit cs
      in case T.uncons rest0 of
           Just (']', rest) | not (T.null digits) ->
             (Index (read (T.unpack digits)) :) <$> parsePath rest
           _ -> Nothing
    _ -> Nothing

-- | 用路径段列表查询 JsonValue。
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
queryString :: Text -> JsonValue -> Maybe JsonValue
queryString path json = parsePath path >>= flip query json
