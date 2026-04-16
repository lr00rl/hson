{-|
模块：Hson.ToJson

ToJson 类型类：把 Haskell 类型自动序列化为 `JsonValue`。

这是 FromJson 的对称挑战，展示了 Haskell 类型类的双向能力：
不仅能从 JSON 来，也能到 JSON 去。

同时，本模块还提供了 GHC.Generics 的自动推导支持，
让用户可以写 `deriving (Generic, ToJson)`。

此外还包含 `encode`、`encodeCompact`、`encodeColor` 等函数，
用于把 `JsonValue` 输出为不同格式的 JSON 字符串。
-}
{-# LANGUAGE TypeSynonymInstances   #-}
{-# LANGUAGE FlexibleInstances      #-}
{-# LANGUAGE FlexibleContexts       #-}
{-# LANGUAGE DefaultSignatures      #-}
{-# LANGUAGE TypeOperators          #-}
{-# LANGUAGE ScopedTypeVariables    #-}

module Hson.ToJson
  ( ToJson(..)
  , GToJson(..)
  , Pair
  , object
  , (.=)
  , encode
  , encodeCompact
  , encodeColor
  , encodeCompactColor
  , ColorScheme(..)
  , defaultColorScheme
  ) where

import Data.Char (ord)
import Data.List (intercalate)
import Data.Text (Text)
import qualified Data.Text as T
import Numeric (showHex)
import GHC.Generics
  ( Generic, Rep, from
  , V1, U1(U1), K1(K1), M1(M1), D, C, S
  , (:*:)((:*:)), (:+:)(L1, R1)
  , Datatype, Constructor, Selector, selName
  )
import Hson.Types (JsonValue(..))

-- ========================================================================
-- Part 1: ToJson 类型类
-- ========================================================================

class ToJson a where
  toJson :: a -> JsonValue

  default toJson :: (Generic a, GToJson (Rep a)) => a -> JsonValue
  toJson x = gToJson (from x)

instance ToJson JsonValue where
  toJson = id

instance ToJson Bool where
  toJson = JsonBool

instance ToJson Int where
  toJson = JsonNumber . fromIntegral

instance ToJson Double where
  toJson = JsonNumber

instance ToJson Text where
  toJson = JsonString

instance ToJson String where
  toJson = JsonString . T.pack

instance ToJson Char where
  toJson c = JsonString (T.singleton c)

instance ToJson a => ToJson [a] where
  toJson = JsonArray . map toJson

instance ToJson a => ToJson (Maybe a) where
  toJson Nothing  = JsonNull
  toJson (Just x) = toJson x

-- ========================================================================
-- Part 2: 辅助函数
-- ========================================================================

type Pair = (Text, JsonValue)

-- | 从键值对列表构造 JSON 对象。
object :: [Pair] -> JsonValue
object = JsonObject

-- | 便捷的中缀构造子：key .= value
(.=) :: ToJson a => Text -> a -> Pair
key .= value = (key, toJson value)

-- ========================================================================
-- Part 3: GHC.Generics 自动推导（对称地狱难度）
-- ========================================================================

class GToJson f where
  gToJson :: f p -> JsonValue

instance GToJson U1 where
  gToJson _ = JsonNull

instance GToJson V1 where
  gToJson _ = JsonNull  -- 不可能到达的分支

instance ToJson c => GToJson (K1 i c) where
  gToJson (K1 x) = toJson x

instance (GToJson f, Datatype d) => GToJson (M1 D d f) where
  gToJson (M1 x) = gToJson x

instance (GToJson f, Constructor c) => GToJson (M1 C c f) where
  gToJson (M1 x) = gToJson x

instance (GToJson f, Selector s) => GToJson (M1 S s f) where
  gToJson (M1 x) =
    case selName (undefined :: M1 S s f p) of
      ""   -> gToJson x
      name -> JsonObject [(T.pack name, gToJson x)]

instance (GToJson a, GToJson b) => GToJson (a :*: b) where
  gToJson (a :*: b) = merge (gToJson a) (gToJson b)
    where
      merge (JsonObject xs) (JsonObject ys) = JsonObject (xs ++ ys)
      merge JsonNull y = y
      merge x JsonNull = x
      merge _ _ = JsonNull  -- 异常回退

instance (GToJson a, GToJson b) => GToJson (a :+: b) where
  gToJson (L1 x) = gToJson x
  gToJson (R1 x) = gToJson x

-- ========================================================================
-- Part 4: 序列化为字符串
-- ========================================================================

-- | 把 JsonValue 序列化为带缩进的 JSON 字符串。
encode :: JsonValue -> String
encode = go 0
  where
    go _ JsonNull       = "null"
    go _ (JsonBool b)   = if b then "true" else "false"
    go _ (JsonNumber n) = show n
    go _ (JsonString s) = "\"" ++ escapeString (T.unpack s) ++ "\""
    go _ (JsonArray []) = "[]"
    go n (JsonArray xs) =
      "[\n"
      ++ intercalate ",\n" (map (\x -> indent (n+1) ++ go (n+1) x) xs)
      ++ "\n" ++ indent n ++ "]"
    go _ (JsonObject []) = "{}"
    go n (JsonObject ps) =
      "{\n"
      ++ intercalate ",\n" (map (\(k,v) -> indent (n+1) ++ "\"" ++ T.unpack k ++ "\": " ++ go (n+1) v) ps)
      ++ "\n" ++ indent n ++ "}"

    indent d = replicate (d * 2) ' '

    escapeString :: String -> String
    escapeString = concatMap escapeChar
      where
        escapeChar c = case c of
          '"'  -> "\\\""
          '\\' -> "\\\\"
          '\b' -> "\\b"
          '\f' -> "\\f"
          '\n' -> "\\n"
          '\r' -> "\\r"
          '\t' -> "\\t"
          _    -> let code = ord c in
                  if code < 0x20
                    then "\\u" ++ padHex 4 code
                    else [c]
        padHex len n = let h = showHex n "" in replicate (len - length h) '0' ++ h

-- | 紧凑输出：无缩进、无换行。
encodeCompact :: JsonValue -> String
encodeCompact = go
  where
    go JsonNull       = "null"
    go (JsonBool b)   = if b then "true" else "false"
    go (JsonNumber n) = show n
    go (JsonString s) = "\"" ++ escapeString (T.unpack s) ++ "\""
    go (JsonArray xs) = "[" ++ intercalate "," (map go xs) ++ "]"
    go (JsonObject ps) = "{" ++ intercalate "," (map (\(k,v) -> "\"" ++ T.unpack k ++ "\":" ++ go v) ps) ++ "}"

    escapeString = concatMap escapeChar
      where
        escapeChar c = case c of
          '"'  -> "\\\""
          '\\' -> "\\\\"
          '\b' -> "\\b"
          '\f' -> "\\f"
          '\n' -> "\\n"
          '\r' -> "\\r"
          '\t' -> "\\t"
          _    -> let code = ord c in
                  if code < 0x20
                    then "\\u" ++ padHex 4 code
                    else [c]
        padHex len n = let h = showHex n "" in replicate (len - length h) '0' ++ h

-- ========================================================================
-- Part 5: ANSI 颜色高亮
-- ========================================================================

-- | 颜色方案。
data ColorScheme = ColorScheme
  { colorKey    :: String -> String  -- ^ 对象键
  , colorString :: String -> String  -- ^ 字符串
  , colorNumber :: String -> String  -- ^ 数字
  , colorBool   :: String -> String  -- ^ 布尔/null
  , colorReset  :: String            -- ^ 重置
  }

-- | 默认终端颜色方案。
defaultColorScheme :: ColorScheme
defaultColorScheme = ColorScheme
  { colorKey    = \s -> "\x1b[33m" ++ s ++ "\x1b[0m"   -- 黄色
  , colorString = \s -> "\x1b[32m" ++ s ++ "\x1b[0m"   -- 绿色
  , colorNumber = \s -> "\x1b[35m" ++ s ++ "\x1b[0m"   -- 洋红
  , colorBool   = \s -> "\x1b[34m" ++ s ++ "\x1b[0m"   -- 蓝色
  , colorReset  = "\x1b[0m"
  }

-- | 带缩进的颜色输出。
encodeColor :: JsonValue -> String
encodeColor = encodeWithColor defaultColorScheme 0

-- | 紧凑的颜色输出。
encodeCompactColor :: JsonValue -> String
encodeCompactColor = encodeCompactWithColor defaultColorScheme

encodeWithColor :: ColorScheme -> Int -> JsonValue -> String
encodeWithColor cs = go
  where
    go _ JsonNull       = colorBool cs "null"
    go _ (JsonBool b)   = colorBool cs $ if b then "true" else "false"
    go _ (JsonNumber n) = colorNumber cs $ show n
    go _ (JsonString s) = colorString cs $ "\"" ++ escapeString (T.unpack s) ++ "\""
    go _ (JsonArray []) = "[]"
    go n (JsonArray xs) =
      "[\n"
      ++ intercalate ",\n" (map (\x -> indent (n+1) ++ go (n+1) x) xs)
      ++ "\n" ++ indent n ++ "]"
    go _ (JsonObject []) = "{}"
    go n (JsonObject ps) =
      "{\n"
      ++ intercalate ",\n" (map (\(k,v) -> indent (n+1) ++ "\"" ++ colorKey cs (T.unpack k) ++ "\": " ++ go (n+1) v) ps)
      ++ "\n" ++ indent n ++ "}"

    indent d = replicate (d * 2) ' '

    escapeString = concatMap escapeChar
      where
        escapeChar c = case c of
          '"'  -> "\\\""
          '\\' -> "\\\\"
          '\b' -> "\\b"
          '\f' -> "\\f"
          '\n' -> "\\n"
          '\r' -> "\\r"
          '\t' -> "\\t"
          _    -> let code = ord c in
                  if code < 0x20
                    then "\\u" ++ padHex 4 code
                    else [c]
        padHex len n = let h = showHex n "" in replicate (len - length h) '0' ++ h

encodeCompactWithColor :: ColorScheme -> JsonValue -> String
encodeCompactWithColor cs = go
  where
    go JsonNull       = colorBool cs "null"
    go (JsonBool b)   = colorBool cs $ if b then "true" else "false"
    go (JsonNumber n) = colorNumber cs $ show n
    go (JsonString s) = colorString cs $ "\"" ++ escapeString (T.unpack s) ++ "\""
    go (JsonArray xs) = "[" ++ intercalate "," (map go xs) ++ "]"
    go (JsonObject ps) = "{" ++ intercalate "," (map (\(k,v) -> "\"" ++ colorKey cs (T.unpack k) ++ "\":" ++ go v) ps) ++ "}"

    escapeString = concatMap escapeChar
      where
        escapeChar c = case c of
          '"'  -> "\\\""
          '\\' -> "\\\\"
          '\b' -> "\\b"
          '\f' -> "\\f"
          '\n' -> "\\n"
          '\r' -> "\\r"
          '\t' -> "\\t"
          _    -> let code = ord c in
                  if code < 0x20
                    then "\\u" ++ padHex 4 code
                    else [c]
        padHex len n = let h = showHex n "" in replicate (len - length h) '0' ++ h
