{-# LANGUAGE DeriveGeneric       #-}
{-# LANGUAGE DeriveAnyClass      #-}
{-# LANGUAGE OverloadedStrings   #-}

module Main where

import Test.Hspec
import Data.Text (Text)
import qualified Data.Text as T

import Hson.Parser (parse, parseJson, ParseError(..))
import Hson.Types (JsonValue(..))
import Hson.Query (queryString)
import Hson.Class (FromJson(..))
import Hson.ToJson (ToJson(..), encode, object, (.=))
import GHC.Generics (Generic)

-- ========================================================================
-- 测试数据类型
-- ========================================================================

data Address = Address
  { city    :: Text
  , zipCode :: Text
  } deriving (Eq, Show, Generic, FromJson, ToJson)

data User = User
  { name    :: Text
  , age     :: Int
  , active  :: Bool
  , address :: Maybe Address
  } deriving (Eq, Show, Generic, FromJson, ToJson)

-- ========================================================================
-- 测试入口
-- ========================================================================

main :: IO ()
main = hspec $ do
  parserTests
  queryTests
  fromJsonTests
  toJsonTests
  roundTripTests

-- ========================================================================
-- Parser 测试
-- ========================================================================

parserTests :: Spec
parserTests = describe "Hson.Parser" $ do
  it "parses null" $ do
    parse parseJson "null" `shouldBe` Right (JsonNull, "")

  it "parses true" $ do
    parse parseJson "true" `shouldBe` Right (JsonBool True, "")

  it "parses false" $ do
    parse parseJson "false" `shouldBe` Right (JsonBool False, "")

  it "parses an integer" $ do
    parse parseJson "42" `shouldBe` Right (JsonNumber 42.0, "")

  it "parses a negative number" $ do
    parse parseJson "-3.14" `shouldBe` Right (JsonNumber (-3.14), "")

  it "parses scientific notation" $ do
    parse parseJson "1e5" `shouldBe` Right (JsonNumber 100000.0, "")

  it "parses a simple string" $ do
    parse parseJson "\"hello\"" `shouldBe` Right (JsonString "hello", "")

  it "parses escaped characters" $ do
    parse parseJson "\"hello\\nworld\""
      `shouldBe` Right (JsonString "hello\nworld", "")

  it "parses unicode escape" $ do
    parse parseJson "\"\\u0048\\u0065\\u006c\\u006c\\u006f\""
      `shouldBe` Right (JsonString "Hello", "")

  it "parses surrogate pair" $ do
    parse parseJson "\"\\uD834\\uDD1E\""
      `shouldBe` Right (JsonString "𝄞", "")

  it "parses an empty array" $ do
    parse parseJson "[]" `shouldBe` Right (JsonArray [], "")

  it "parses a nested array" $ do
    parse parseJson "[1, [2, 3]]"
      `shouldBe` Right (JsonArray [JsonNumber 1.0, JsonArray [JsonNumber 2.0, JsonNumber 3.0]], "")

  it "parses an empty object" $ do
    parse parseJson "{}" `shouldBe` Right (JsonObject [], "")

  it "parses a nested object" $ do
    parse parseJson "{\"a\": {\"b\": 1}}"
      `shouldBe` Right (JsonObject [("a", JsonObject [("b", JsonNumber 1.0)])], "")

  it "rejects leading zeros" $ do
    case parse parseJson "01" of
      Left (ParseError msg _ _ _) -> msg `shouldContain` "Leading zeros"
      _                           -> expectationFailure "Expected parse error for leading zeros"

  it "rejects trailing dot in number" $ do
    case parse parseJson "1." of
      Left _ -> return ()
      _      -> expectationFailure "Expected parse error for trailing dot"

  it "rejects bare control characters in string" $ do
    case parse parseJson "\"hello\x01world\"" of
      Left _ -> return ()
      _      -> expectationFailure "Expected parse error for control char"

  it "skips whitespace around values" $ do
    parse parseJson "  {  \"x\"  :  1  }  "
      `shouldBe` Right (JsonObject [("x", JsonNumber 1.0)], "")

-- ========================================================================
-- Query 测试
-- ========================================================================

queryTests :: Spec
queryTests = describe "Hson.Query" $ do
  let json = JsonObject
        [ ("users", JsonArray
            [ JsonObject [("name", JsonString "Alice"), ("age", JsonNumber 30.0)]
            , JsonObject [("name", JsonString "Bob"),   ("age", JsonNumber 25.0)]
            ])
        , ("settings", JsonObject [("theme", JsonString "dark")])
        ]

  it "queries object field" $ do
    queryString ".settings.theme" json `shouldBe` Just (JsonString "dark")

  it "queries array index" $ do
    queryString ".users[0].name" json `shouldBe` Just (JsonString "Alice")

  it "queries nested array" $ do
    queryString ".users[1].age" json `shouldBe` Just (JsonNumber 25.0)

  it "returns Nothing for missing key" $ do
    queryString ".users[0].email" json `shouldBe` Nothing

  it "returns Nothing for out-of-bounds index" $ do
    queryString ".users[5].name" json `shouldBe` Nothing

  it "returns Nothing for invalid path" $ do
    queryString ".users[abc]" json `shouldBe` Nothing

-- ========================================================================
-- FromJson 测试
-- ========================================================================

fromJsonTests :: Spec
fromJsonTests = describe "Hson.Class (FromJson)" $ do
  it "deserializes Bool" $ do
    fromJson (JsonBool True) `shouldBe` (Right True :: Either String Bool)

  it "deserializes Int" $ do
    fromJson (JsonNumber 42.0) `shouldBe` (Right 42 :: Either String Int)

  it "deserializes Text" $ do
    fromJson (JsonString "hello") `shouldBe` (Right "hello" :: Either String Text)

  it "deserializes [Int]" $ do
    fromJson (JsonArray [JsonNumber 1.0, JsonNumber 2.0])
      `shouldBe` (Right [1, 2] :: Either String [Int])

  it "deserializes Maybe with Just" $ do
    fromJson (JsonString "x") `shouldBe` (Right (Just "x") :: Either String (Maybe Text))

  it "deserializes Maybe with Nothing from null" $ do
    fromJson JsonNull `shouldBe` (Right Nothing :: Either String (Maybe Text))

  it "reports type mismatch" $ do
    case fromJson (JsonString "oops") :: Either String Int of
      Left msg -> msg `shouldContain` "Expected number"
      _        -> expectationFailure "Expected type mismatch error"

  it "deserializes nested record via Generics" $ do
    let json = JsonObject
          [ ("name", JsonString "Alice")
          , ("age", JsonNumber 30.0)
          , ("active", JsonBool True)
          , ("address", JsonObject
              [ ("city", JsonString "Shanghai")
              , ("zipCode", JsonString "200000")
              ])
          ]
    fromJson json `shouldBe`
      Right (User "Alice" 30 True (Just (Address "Shanghai" "200000")))

  it "deserializes record with missing Maybe field via Generics" $ do
    let json = JsonObject
          [ ("name", JsonString "Bob")
          , ("age", JsonNumber 25.0)
          , ("active", JsonBool False)
          ]
    fromJson json `shouldBe`
      Right (User "Bob" 25 False Nothing)

-- ========================================================================
-- ToJson 测试
-- ========================================================================

toJsonTests :: Spec
toJsonTests = describe "Hson.ToJson" $ do
  it "serializes Bool" $ do
    toJson True `shouldBe` JsonBool True

  it "serializes Int" $ do
    toJson (42 :: Int) `shouldBe` JsonNumber 42.0

  it "serializes Text" $ do
    toJson ("hello" :: Text) `shouldBe` JsonString "hello"

  it "serializes [Int]" $ do
    toJson ([1, 2, 3] :: [Int]) `shouldBe` JsonArray [JsonNumber 1.0, JsonNumber 2.0, JsonNumber 3.0]

  it "serializes Maybe Nothing as null" $ do
    toJson (Nothing :: Maybe Int) `shouldBe` JsonNull

  it "serializes Maybe Just" $ do
    toJson (Just 42 :: Maybe Int) `shouldBe` JsonNumber 42.0

  it "constructs object with (.=)" $ do
    let json = object [ "name" .= ("Alice" :: Text), "age" .= (30 :: Int) ]
    json `shouldBe` JsonObject [("name", JsonString "Alice"), ("age", JsonNumber 30.0)]

  it "serializes nested record via Generics" $ do
    let user = User "Alice" 30 True (Just (Address "Shanghai" "200000"))
    toJson user `shouldBe` JsonObject
      [ ("name", JsonString "Alice")
      , ("age", JsonNumber 30.0)
      , ("active", JsonBool True)
      , ("address", JsonObject
          [ ("city", JsonString "Shanghai")
          , ("zipCode", JsonString "200000")
          ])
      ]

  it "encode produces valid JSON string" $ do
    encode (JsonObject [("x", JsonNumber 1.0)])
      `shouldContain` "\"x\":"

-- ========================================================================
-- Round-trip 测试
-- ========================================================================

roundTripTests :: Spec
roundTripTests = describe "Round-trip" $ do
  it "round-trips a complex value through parse and encode" $ do
    let original = JsonObject
          [ ("name", JsonString "Alice")
          , ("tags", JsonArray [JsonString "a", JsonString "b"])
          , ("count", JsonNumber 42.0)
          ]
    let text = T.pack (encode original)
    case parse parseJson text of
      Right (parsed, rest) -> do
        T.all (\c -> c `elem` (" \t\n\r" :: String)) rest `shouldBe` True
        parsed `shouldBe` original
      Left err -> expectationFailure $ "Parse failed: " ++ show err

  it "round-trips a generic record through toJson and fromJson" $ do
    let user = User "Alice" 30 True (Just (Address "Shanghai" "200000"))
    fromJson (toJson user) `shouldBe` Right user

  it "round-trips a generic record with missing Maybe field" $ do
    let user = User "Bob" 25 False Nothing
    fromJson (toJson user) `shouldBe` Right user
