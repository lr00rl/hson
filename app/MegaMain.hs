module Main where

import System.Environment (getArgs)
import System.IO (stdout)
import System.Console.ANSI (hSupportsANSI)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Text.Megaparsec (errorBundlePretty)
import Hson.MegaParser (runMega, parseJson)
import Hson.Query (queryString)
import Hson.ToJson (encode, encodeCompact, encodeColor, encodeCompactColor)
import Hson.Types (JsonValue(..))

isPath :: String -> Bool
isPath (c:_) = c == '.' || c == '['
isPath _     = False

isFlag :: String -> Bool
isFlag ('-':_) = True
isFlag _       = False

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

outputJson :: Bool -> (JsonValue -> String) -> JsonValue -> IO ()
outputJson True _ (JsonString s) = putStrLn (T.unpack s)
outputJson _    enc json         = putStrLn (enc json)

process :: Bool -> (JsonValue -> String) -> Maybe String -> T.Text -> IO ()
process raw enc mPath input = do
  case runMega parseJson input of
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
    Left bundle -> do
      putStrLn "Parse error:"
      putStrLn $ errorBundlePretty bundle

main :: IO ()
main = do
  allArgs <- getArgs
  let (compact, raw, explicitColor, explicitNoColor, args) = parseFlags allArgs
  enc <- selectEncoder compact explicitColor explicitNoColor

  case args of
    [file, path]
      | not (isPath file) -> do
          input <- TIO.readFile file
          process raw enc (Just path) input

    [arg]
      | isPath arg -> do
          input <- TIO.getContents
          process raw enc (Just arg) input
      | otherwise -> do
          input <- TIO.readFile arg
          process raw enc Nothing input

    [] -> do
      input <- TIO.getContents
      process raw enc Nothing input

    _ -> do
      putStrLn "Usage:"
      putStrLn "  hson-megaparsec [options] <file>              # Parse and pretty-print a JSON file"
      putStrLn "  hson-megaparsec [options] <file> <path>       # Query a JSON file with path"
      putStrLn "  hson-megaparsec [options] <path>              # Query JSON from stdin"
      putStrLn "  hson-megaparsec [options]                     # Parse and pretty-print JSON from stdin"
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
      putStrLn "  echo '{\"a\":1}' | hson-megaparsec"
      putStrLn "  echo '{\"a\":1}' | hson-megaparsec -c"
      putStrLn "  echo '{\"a\":1}' | hson-megaparsec .a"
      putStrLn "  echo '{\"name\":\"Alice\"}' | hson-megaparsec -r .name"
      putStrLn "  hson-megaparsec -c --color examples/nested.json"
      putStrLn "  cat examples/nested.json | hson-megaparsec .users[0].name"
