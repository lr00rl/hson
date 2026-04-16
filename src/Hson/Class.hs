{-|
模块：Hson.Class

FromJson 类型类：把 `JsonValue` 自动反序列化为自定义 Haskell 类型。

这是挑战 6 的实现，展示了 Haskell 类型类的威力：
一旦你为类型 `a` 实现了 `FromJson`，`[a]`、`Maybe a` 等组合类型
也能自动获得实例（通过类型类推导）。

此外，本模块还包含了 GHC.Generics 的自动推导支持（地狱难度）。
只要你的类型实现了 `Generic`，就可以写：

    data User = User { name :: Text, age :: Int }
      deriving (Generic, FromJson)

API 设计深受 `aeson` 启发，保持教学友好的简洁性。
-}
{-# LANGUAGE TypeSynonymInstances   #-}
{-# LANGUAGE FlexibleInstances      #-}
{-# LANGUAGE FlexibleContexts       #-}
{-# LANGUAGE DefaultSignatures      #-}
{-# LANGUAGE TypeOperators          #-}
{-# LANGUAGE ScopedTypeVariables    #-}

module Hson.Class
  ( FromJson(..)
  , GFromJson(..)
  , withObject
  , withArray
  , (.:)
  , (.:?)
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import GHC.Generics ( Generic, Rep, to
                      , V1, U1(U1), K1(K1), M1(M1), D, C, S
                      , (:*:)((:*:)), (:+:)(L1)
                      , Datatype, Constructor, Selector, selName
                      )
import Hson.Types (JsonValue(..))

-- ========================================================================
-- Part 1: FromJson 类型类
-- ========================================================================

-- | FromJson 类型类。
class FromJson a where
  fromJson :: JsonValue -> Either String a

  default fromJson :: (Generic a, GFromJson (Rep a)) => JsonValue -> Either String a
  fromJson v = to <$> gFromJson v

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

-- | 字符串（Haskell String，需要 unpack）
instance {-# OVERLAPPING #-} FromJson String where
  fromJson (JsonString s) = Right (T.unpack s)
  fromJson _              = Left "Expected string"

-- | Text 字符串（零拷贝）
instance FromJson Text where
  fromJson (JsonString s) = Right s
  fromJson _              = Left "Expected string"

-- | 单个字符
instance FromJson Char where
  fromJson (JsonString s) | T.length s == 1 = Right (T.head s)
  fromJson _                                = Left "Expected single-character string"

-- | 数组：要求元素类型也有 FromJson 实例
instance FromJson a => FromJson [a] where
  fromJson (JsonArray xs) = mapM fromJson xs
  fromJson _              = Left "Expected array"

-- | Maybe：JSON null 映射为 Nothing，其他值映射为 Just
instance FromJson a => FromJson (Maybe a) where
  fromJson JsonNull = Right Nothing
  fromJson x        = Just <$> fromJson x

-- ========================================================================
-- Part 2: GHC.Generics 自动推导（地狱难度）
-- ========================================================================

-- | Generic 版本的 FromJson。
-- `f` 是 `Rep a` 的某种片段，如 K1、M1、(:*:) 等。
class GFromJson f where
  gFromJson :: JsonValue -> Either String (f p)

-- | 空类型（没有构造子的类型）。
instance GFromJson V1 where
  gFromJson _ = Left "Cannot deserialize empty type (V1)"

-- | 无字段的构造子。约定对应 JSON null。
instance GFromJson U1 where
  gFromJson JsonNull = Right U1
  gFromJson _        = Left "Expected null for constructor with no fields"

-- | 单个字段。
instance FromJson c => GFromJson (K1 i c) where
  gFromJson v = K1 <$> fromJson v

-- | Datatype 元数据。
instance (GFromJson f, Datatype d) => GFromJson (M1 D d f) where
  gFromJson v = M1 <$> gFromJson v

-- | Constructor 元数据。
instance (GFromJson f, Constructor c) => GFromJson (M1 C c f) where
  gFromJson v = M1 <$> gFromJson v

-- | Selector 元数据（字段名）。
-- 有名字段从 JsonObject 查找，无名字段透传。
instance (GFromJson f, Selector s) => GFromJson (M1 S s f) where
  gFromJson (JsonObject pairs) =
    case selName (undefined :: M1 S s f p) of
      ""   -> M1 <$> gFromJson (JsonObject pairs)
      name ->
        case lookup (T.pack name) pairs of
          Just v  -> M1 <$> gFromJson v
          Nothing -> M1 <$> gFromJson JsonNull  -- 字段不存在时传 null，让 Maybe 返回 Nothing
  gFromJson v =
    case selName (undefined :: M1 S s f p) of
      ""   -> M1 <$> gFromJson v
      name -> Left $ "Expected object for record field: " ++ name

-- | 积类型（record 的多个字段）。
-- 左右两边共享同一个 JsonObject。
instance (GFromJson a, GFromJson b) => GFromJson (a :*: b) where
  gFromJson obj@(JsonObject _) =
    (:*:) <$> gFromJson obj <*> gFromJson obj
  gFromJson _ = Left "Expected object for product type"

-- | 和类型（多个构造子）。
-- 教学版简化：只尝试左边（仅支持单构造子）。
instance (GFromJson a, GFromJson b) => GFromJson (a :+: b) where
  gFromJson v = L1 <$> gFromJson v

-- ========================================================================
-- Part 3: 辅助函数
-- ========================================================================

withObject :: String -> ([(Text, JsonValue)] -> Either String a) -> JsonValue -> Either String a
withObject _ f (JsonObject pairs) = f pairs
withObject expected _ _           = Left $ "Expected object for " ++ expected

withArray :: String -> ([JsonValue] -> Either String a) -> JsonValue -> Either String a
withArray _ f (JsonArray xs) = f xs
withArray expected _ _       = Left $ "Expected array for " ++ expected

(.:) :: FromJson a => [(Text, JsonValue)] -> Text -> Either String a
pairs .: key = case lookup key pairs of
  Just v  -> fromJson v
  Nothing -> Left $ "Missing required field: " ++ T.unpack key

(.:?) :: FromJson a => [(Text, JsonValue)] -> Text -> Either String (Maybe a)
pairs .:? key = case lookup key pairs of
  Just v  -> Just <$> fromJson v
  Nothing -> Right Nothing
