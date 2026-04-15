{-|
模块：Hson.Class

FromJson 类型类：把 `JsonValue` 自动反序列化为自定义 Haskell 类型。

这是挑战 6 的实现，展示了 Haskell 类型类的威力：
一旦你为类型 `a` 实现了 `FromJson`，`[a]`、`Maybe a` 等组合类型
也能自动获得实例（通过类型类推导）。

API 设计深受 `aeson` 启发，保持教学友好的简洁性。
-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE FlexibleInstances #-}

module Hson.Class
  ( FromJson(..)
  , withObject
  , withArray
  , (.:)
  , (.:?)
  ) where

import Hson.Types (JsonValue(..))

-- | FromJson 类型类。
--
-- 任何一个 Haskell 类型，只要你能写出 `JsonValue -> Either String a`，
-- 就可以成为 JSON 可反序列化的类型。
class FromJson a where
  fromJson :: JsonValue -> Either String a

-- | JsonValue 本身就是最平凡的 FromJson 实例。
instance FromJson JsonValue where
  fromJson = Right

-- | 布尔值
instance FromJson Bool where
  fromJson (JsonBool b) = Right b
  fromJson _            = Left "Expected boolean"

-- | 整数（从 Double 四舍五入转换）
instance FromJson Int where
  fromJson (JsonNumber n) = Right (round n)
  fromJson _              = Left "Expected number"

-- | Double 浮点数
instance FromJson Double where
  fromJson (JsonNumber n) = Right n
  fromJson _              = Left "Expected number"

-- | 字符串
instance {-# OVERLAPPING #-} FromJson String where
  fromJson (JsonString s) = Right s
  fromJson _              = Left "Expected string"

-- | 单个字符
instance FromJson Char where
  fromJson (JsonString [c]) = Right c
  fromJson _                = Left "Expected single-character string"

-- | 数组：要求元素类型也有 FromJson 实例
instance FromJson a => FromJson [a] where
  fromJson (JsonArray xs) = mapM fromJson xs
  fromJson _              = Left "Expected array"

-- | Maybe：JSON null 映射为 Nothing，其他值映射为 Just
instance FromJson a => FromJson (Maybe a) where
  fromJson JsonNull = Right Nothing
  fromJson x        = Just <$> fromJson x

-- ========================================================================
-- 辅助函数：让 Record 反序列化像读散文一样自然
-- ========================================================================

-- | 确保当前 JsonValue 是对象，然后对其字段列表执行回调。
withObject :: String -> ([(String, JsonValue)] -> Either String a) -> JsonValue -> Either String a
withObject _ f (JsonObject pairs) = f pairs
withObject expected _ _           = Left $ "Expected object for " ++ expected

-- | 确保当前 JsonValue 是数组，然后对其元素列表执行回调。
withArray :: String -> ([JsonValue] -> Either String a) -> JsonValue -> Either String a
withArray _ f (JsonArray xs) = f xs
withArray expected _ _       = Left $ "Expected array for " ++ expected

-- | 从对象字段中读取一个**必须存在**的字段。
(.:) :: FromJson a => [(String, JsonValue)] -> String -> Either String a
pairs .: key = case lookup key pairs of
  Just v  -> fromJson v
  Nothing -> Left $ "Missing required field: " ++ key

-- | 从对象字段中读取一个**可选**的字段。
-- 如果字段不存在，返回 `Right Nothing`；如果存在但类型不匹配，返回 `Left` 错误。
(.:?) :: FromJson a => [(String, JsonValue)] -> String -> Either String (Maybe a)
pairs .:? key = case lookup key pairs of
  Just v  -> Just <$> fromJson v
  Nothing -> Right Nothing
