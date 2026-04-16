module Main where

import System.Environment (getArgs)
import qualified Data.Text as T
import Hson.Parser (parse, parseJson, ParseError(..))
import Hson.Query (queryString)
import Hson.ToJson (encode)

-- | 判断一个字符串是否是 JSON Path（以 . 或 [ 开头）。
isPath :: String -> Bool
isPath (c:_) = c == '.' || c == '['
isPath _     = False

-- | 统一的输出处理：解析结果 + 可选的 path 查询。
process :: String -> Maybe String -> IO ()
process input mPath = do
  case parse parseJson (T.pack input) of
    Right (json, rest) -> do
      if not (T.all (\c -> c `elem` (" \t\n\r" :: String)) rest)
        then putStrLn $ "Warning: unparsed trailing input: " ++ T.unpack (T.take 50 rest)
        else return ()
      case mPath of
        Just path ->
          case queryString (T.pack path) json of
            Just result -> putStrLn (encode result)
            Nothing     -> putStrLn $ "Query failed or returned no result: " ++ path
        Nothing ->
          putStrLn (encode json)
    Left err ->
      putStrLn $ "Error at line " ++ show (peLine err) ++ ", column " ++ show (peCol err) ++ ": " ++ peMessage err

main :: IO ()
main = do
  args <- getArgs
  case args of
    -- 文件 + path
    [file, path]
      | not (isPath file) -> do
          input <- readFile file
          process input (Just path)

    -- 只有 path（从 stdin 读）
    [arg]
      | isPath arg -> do
          input <- getContents
          process input (Just arg)
      | otherwise -> do
          input <- readFile arg
          process input Nothing

    -- 无任何参数（从 stdin 读）
    [] -> do
      input <- getContents
      process input Nothing

    -- 其他情况：帮助信息
    _ -> do
      putStrLn "Usage:"
      putStrLn "  hson <file>              # Parse and pretty-print a JSON file"
      putStrLn "  hson <file> <path>       # Query a JSON file with path"
      putStrLn "  hson <path>              # Query JSON from stdin"
      putStrLn "  hson                     # Parse and pretty-print JSON from stdin"
      putStrLn ""
      putStrLn "Examples:"
      putStrLn "  echo '{\"a\":1}' | hson"
      putStrLn "  echo '{\"a\":1}' | hson .a"
      putStrLn "  hson examples/nested.json"
      putStrLn "  hson examples/nested.json .users[0].name"
