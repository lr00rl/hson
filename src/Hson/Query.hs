{-|
模块：Hson.Query

JSON Path 查询的小型 DSL。

支持语法：
  - .key        访问对象字段
  - [n]         访问数组索引
  - []          遍历数组所有元素
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
  | All
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
      case T.uncons cs of
        Just (']', rest) -> (All :) <$> parsePath rest
        _ ->
          let (digits, rest0) = T.span isDigit cs
          in case T.uncons rest0 of
               Just (']', rest) | not (T.null digits) ->
                 (Index (read (T.unpack digits)) :) <$> parsePath rest
               _ -> Nothing
    _ -> Nothing

-- | 用路径段列表查询 JsonValue，支持 [] 多值结果。
-- 如果查询返回多个值，会包装为 JsonArray；无结果则返回 Nothing。
query :: [PathSegment] -> JsonValue -> Maybe JsonValue
query segs json =
  case queryMulti segs json of
    []  -> Nothing
    [x] -> Just x
    xs  -> Just (JsonArray xs)

queryMulti :: [PathSegment] -> JsonValue -> [JsonValue]
queryMulti [] json = [json]
queryMulti (Key k : rest) (JsonObject pairs) =
  case lookup k pairs of
    Just v  -> queryMulti rest v
    Nothing -> []
queryMulti (Index i : rest) (JsonArray xs)
  | i >= 0 && i < length xs = queryMulti rest (xs !! i)
  | otherwise               = []
queryMulti (All : rest) (JsonArray xs) =
  concatMap (queryMulti rest) xs
queryMulti _ _ = []

-- | 便捷的字符串路径查询入口。
queryString :: Text -> JsonValue -> Maybe JsonValue
queryString path json = parsePath path >>= flip query json
