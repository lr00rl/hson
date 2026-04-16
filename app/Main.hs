module Main where

import System.Environment (getArgs)
import System.IO (stdout)
import System.Console.ANSI (hSupportsANSI)
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

-- | 解析 flag：返回 (是否 compact, 是否 raw-output, 是否显式 color, 是否显式 no-color, 剩余非 flag 参数)
parseFlags :: [String] -> (Bool, Bool, Bool, Bool, [String])
parseFlags = go False False False False []
  where
    go c r color noColor rest [] = (c, r, color, noColor, reverse rest)
    go c r color noColor rest (arg:args)
      | arg == "-c"        || arg == "--compact"    = go True r color noColor rest args
      | arg == "-r"        || arg == "--raw-output" = go c True color noColor rest args
      | arg == "--color"                            = go c r True noColor rest args
      | arg == "--no-color"                         = go c r color True rest args
      | isFlag arg                                  = go c r color noColor rest args
      | otherwise                                   = go c r color noColor (arg:rest) args

-- | 选择编码器。颜色规则：
--   - 显式 --color    => 开
--   - 显式 --no-color => 关
--   - 否则检测 stdout 是否是 TTY => 自动开关
selectEncoder :: Bool -> Bool -> Bool -> IO (JsonValue -> String)
selectEncoder compact explicitColor explicitNoColor = do
  useColor <- if explicitNoColor
                then return False
                else if explicitColor
                  then return True
                  else hSupportsANSI stdout
  return $ case (compact, useColor) of
    (True,  True)  -> encodeCompactColor
    (True,  False) -> encodeCompact
    (False, True)  -> encodeColor
    (False, False) -> encode

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
  let (compact, raw, explicitColor, explicitNoColor, args) = parseFlags allArgs
  enc <- selectEncoder compact explicitColor explicitNoColor

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
      putStrLn "  --color            # Force ANSI color highlighting"
      putStrLn "  --no-color         # Disable ANSI color highlighting"
      putStrLn ""
      putStrLn "Color default: enabled on TTY, disabled when piped."
      putStrLn ""
      putStrLn "Examples:"
      putStrLn "  echo '{\"a\":1}' | hson"
      putStrLn "  echo '{\"a\":1}' | hson -c"
      putStrLn "  echo '{\"a\":1}' | hson .a"
      putStrLn "  echo '{\"name\":\"Alice\"}' | hson -r .name"
      putStrLn "  hson -c --color examples/nested.json"
      putStrLn "  cat examples/nested.json | hson .users[0].name"
