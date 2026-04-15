module Main where

import System.Environment (getArgs)
import Data.List (intercalate)
import Data.Char (ord)
import Numeric (showHex)
import Hson.Parser (parse, parseJson, ParseError(..))
import Hson.Query (queryString)
import Hson.Types (JsonValue(..))

-- | 美化打印 JSON（带缩进）
prettyPrint :: JsonValue -> String
prettyPrint = go 0
  where
    go _ JsonNull       = "null"
    go _ (JsonBool b)   = if b then "true" else "false"
    go _ (JsonNumber n) = show n
    go _ (JsonString s) = "\"" ++ escapeString s ++ "\""
    go _ (JsonArray []) = "[]"
    go n (JsonArray xs) =
      "[\n"
      ++ intercalate ",\n" (map (\x -> indent (n+1) ++ go (n+1) x) xs)
      ++ "\n" ++ indent n ++ "]"
    go _ (JsonObject []) = "{}"
    go n (JsonObject ps) =
      "{\n"
      ++ intercalate ",\n" (map (\(k,v) -> indent (n+1) ++ "\"" ++ k ++ "\": " ++ go (n+1) v) ps)
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

main :: IO ()
main = do
  args <- getArgs
  case args of
    [file, path] -> do
      input <- readFile file
      case parse parseJson input of
        Right (json, rest) -> do
          if all (`elem` " \t\n\r") rest
            then case queryString path json of
              Just result -> putStrLn (prettyPrint result)
              Nothing     -> putStrLn $ "Query failed or returned no result: " ++ path
            else putStrLn $ "Warning: unparsed trailing input: " ++ take 50 rest
        Left err ->
          putStrLn $ "Error at line " ++ show (peLine err) ++ ", column " ++ show (peCol err) ++ ": " ++ peMessage err

    [file] -> do
      input <- readFile file
      case parse parseJson input of
        Right (json, rest) -> do
          putStrLn (prettyPrint json)
          if all (`elem` " \t\n\r") rest
            then return ()
            else putStrLn $ "Warning: unparsed trailing input: " ++ take 50 rest
        Left err ->
          putStrLn $ "Error at line " ++ show (peLine err) ++ ", column " ++ show (peCol err) ++ ": " ++ peMessage err

    [] -> do
      input <- getContents
      case parse parseJson input of
        Right (json, rest) -> do
          putStrLn (prettyPrint json)
          if all (`elem` " \t\n\r") rest
            then return ()
            else putStrLn $ "Warning: unparsed trailing input: " ++ take 50 rest
        Left err ->
          putStrLn $ "Error at line " ++ show (peLine err) ++ ", column " ++ show (peCol err) ++ ": " ++ peMessage err

    _ -> do
      putStrLn "Usage: hson [file] [path]"
      putStrLn "  file   : JSON file to parse"
      putStrLn "  path   : optional JSON path query, e.g. .users[0].name"
