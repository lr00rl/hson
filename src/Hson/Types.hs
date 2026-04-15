module Hson.Types
  ( JsonValue(..)
  ) where

import Data.Text (Text)

-- | JSON 的代数数据类型（Algebraic Data Type, ADT）表示。
--
-- 为什么用 ADT？因为 JSON 规范本身就是递归的：
-- 一个数组里可以放任意 JSON 值，一个对象里的值也是任意 JSON 值。
-- Haskell 的 ADT 天然支持这种递归结构，代码与数据规范完全同构。
--
-- 例如：
-- >>> JsonObject [("name", JsonString "Haskell"), ("year", JsonNumber 1990)]
-- 对应 JSON: {"name": "Haskell", "year": 1990}
data JsonValue
  = JsonNull                      -- ^ null
  | JsonBool   Bool               -- ^ true / false
  | JsonNumber Double             -- ^ 数字（用 Double 简化处理）
  | JsonString Text               -- ^ 字符串（使用 Data.Text 提升性能）
  | JsonArray  [JsonValue]        -- ^ 数组（递归：元素仍是 JsonValue）
  | JsonObject [(Text, JsonValue)]  -- ^ 对象（递归：键和值使用 Text）
  deriving (Eq, Show)
