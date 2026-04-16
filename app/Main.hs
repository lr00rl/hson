module Main where

import System.Environment (getArgs)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Hson.Parser (parse, parseJson, ParseError(..))
import Hson.Query (queryString)
import Hson.ToJson (encode)
import Hson.Types (JsonValue(..))

main :: IO ()
main = do
  args <- getArgs
  case args of
    [file, path] -> do
      input <- TIO.readFile file
      case parse parseJson input of
        Right (json, rest) -> do
          if T.all (`elem` " \t\n\r") rest
            then case queryString (T.pack path) json of
              Just result -> putStrLn (encode result)
              Nothing     -> putStrLn $ "Query failed or returned no result: " ++ path
            else putStrLn $ "Warning: unparsed trailing input: " ++ T.unpack (T.take 50 rest)
        Left err ->
          putStrLn $ "Error at line " ++ show (peLine err) ++ ", column " ++ show (peCol err) ++ ": " ++ peMessage err

    [file] -> do
      input <- TIO.readFile file
      case parse parseJson input of
        Right (json, rest) -> do
          putStrLn (encode json)
          if T.all (`elem` " \t\n\r") rest
            then return ()
            else putStrLn $ "Warning: unparsed trailing input: " ++ T.unpack (T.take 50 rest)
        Left err ->
          putStrLn $ "Error at line " ++ show (peLine err) ++ ", column " ++ show (peCol err) ++ ": " ++ peMessage err

    [] -> do
      input <- TIO.getContents
      case parse parseJson input of
        Right (json, rest) -> do
          putStrLn (encode json)
          if T.all (`elem` " \t\n\r") rest
            then return ()
            else putStrLn $ "Warning: unparsed trailing input: " ++ T.unpack (T.take 50 rest)
        Left err ->
          putStrLn $ "Error at line " ++ show (peLine err) ++ ", column " ++ show (peCol err) ++ ": " ++ peMessage err

    _ -> do
      putStrLn "Usage: hson [file] [path]"
      putStrLn "  file   : JSON file to parse"
      putStrLn "  path   : optional JSON path query, e.g. .users[0].name"
