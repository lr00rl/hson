module Main where

import System.Environment (getArgs)
import qualified Data.Text as T
import Hson.Parser (parse, parseJson, ParseError(..))
import Hson.Query (queryString)
import Hson.ToJson (encode, encodeCompact, encodeColor, encodeCompactColor)
import Hson.Types (JsonValue(..))

-- | 判断一个字符串是否是 JSON Path（以 . 或 [ 开头）。
isPath :: String -> Bool
isPath (c:_) = c == '.' || c == '['
isPath _     = False

-- | 判断是否是 flag 参数。
isFlag :: String -> Bool
isFlag ('-':_) = True
isFlag _       = False

-- | 解析 flag：返回 (是否 compact, 是否 raw-output, 是否 color, 剩余非 flag 参数)
parseFlags :: [String] -> (Bool, Bool, Bool, [String])
parseFlags = go False False False []
  where
    go c r color rest [] = (c, r, color, reverse rest)
    go c r color rest (arg:args)
      | arg == "-c"        || arg == "--compact"    = go True r color rest args
      | arg == "-r"        || arg == "--raw-output" = go c True color rest args
      | arg == "--color"                            = go c r True rest args
      | isFlag arg                                  = go c r color rest args  -- 忽略未知 flag
      | otherwise                                   = go c r color (arg:rest) args

-- | 选择编码器。
selectEncoder :: Bool -> Bool -> (JsonValue -> String)
selectEncoder compact color
  | compact && color = encodeCompactColor
  | compact          = encodeCompact
  | color            = encodeColor
  | otherwise        = encode

-- | 输出 JSON 值，支持 raw-output 模式。
outputJson :: Bool -> (JsonValue -> String) -> JsonValue -> IO ()
outputJson True _ (JsonString s) = putStrLn (T.unpack s)  -- -r 模式：原始字符串不加引号
outputJson _    enc json         = putStrLn (enc json)    -- 正常模式

-- | 统一的输出处理：解析结果 + 可选的 path 查询 + 编码选项。
process :: Bool -> (JsonValue -> String) -> Maybe String -> String -> IO ()
process raw enc mPath input = do
  case parse parseJson (T.pack input) of
    Right (json, rest) -> do
      if not (T.all (\c -> c `elem` (" \t\n\r" :: String)) rest)
        then putStrLn $ "Warning: unparsed trailing input: " ++ T.unpack (T.take 50 rest)
        else return ()
      case mPath of
        Just path ->
          case queryString (T.pack path) json of
            Just result -> outputJson raw enc result
            Nothing     -> putStrLn $ "Query failed or returned no result: " ++ path
        Nothing ->
          outputJson raw enc json
    Left err ->
      putStrLn $ "Error at line " ++ show (peLine err) ++ ", column " ++ show (peCol err) ++ ": " ++ peMessage err

main :: IO ()
main = do
  allArgs <- getArgs
  let (compact, raw, color, args) = parseFlags allArgs
  let enc = selectEncoder compact color

  case args of
    -- 文件 + path
    [file, path]
      | not (isPath file) -> do
          input <- readFile file
          process raw enc (Just path) input

    -- 只有 path（从 stdin 读）
    [arg]
      | isPath arg -> do
          input <- getContents
          process raw enc (Just arg) input
      | otherwise -> do
          input <- readFile arg
          process raw enc Nothing input

    -- 无任何参数（从 stdin 读）
    [] -> do
      input <- getContents
      process raw enc Nothing input

    -- 帮助信息
    _ -> do
      putStrLn "Usage:"
      putStrLn "  hson [options] <file>              # Parse and pretty-print a JSON file"
      putStrLn "  hson [options] <file> <path>       # Query a JSON file with path"
      putStrLn "  hson [options] <path>              # Query JSON from stdin"
      putStrLn "  hson [options]                     # Parse and pretty-print JSON from stdin"
      putStrLn ""
      putStrLn "Options:"
      putStrLn "  -c, --compact      # Compact output (no indentation)"
      putStrLn "  -r, --raw-output   # Raw string output (no quotes)"
      putStrLn "  --color            # Enable ANSI color highlighting"
      putStrLn ""
      putStrLn "Examples:"
      putStrLn "  echo '{\"a\":1}' | hson"
      putStrLn "  echo '{\"a\":1}' | hson -c"
      putStrLn "  echo '{\"a\":1}' | hson .a"
      putStrLn "  echo '{\"name\":\"Alice\"}' | hson -r .name"
      putStrLn "  hson -c --color examples/nested.json"
      putStrLn "  cat examples/nested.json | hson .users[0].name"
