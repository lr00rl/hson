module Main where

import System.Environment (getArgs)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Text.Megaparsec (errorBundlePretty)
import Hson.MegaParser (runMega, parseJson)
import Hson.ToJson (encode)

main :: IO ()
main = do
  args <- getArgs
  case args of
    [file] -> do
      input <- TIO.readFile file
      case runMega parseJson input of
        Right (json, rest) -> do
          putStrLn (encode json)
          if T.all (`elem` " \t\n\r") rest
            then return ()
            else putStrLn $ "Warning: unparsed trailing input: " ++ T.unpack (T.take 50 rest)
        Left bundle -> do
          putStrLn "Parse error:"
          putStrLn $ errorBundlePretty bundle
    _ -> do
      putStrLn "Usage: hson-megaparsec <file>"
      putStrLn "  file : JSON file to parse"
