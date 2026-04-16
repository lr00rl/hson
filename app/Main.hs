-- ═══════════════════════════════════════════════════════════════════════════════
-- 知识点 1：模块声明 (Module Declaration)
-- ═══════════════════════════════════════════════════════════════════════════════
-- Haskell 的每个源文件都必须以 `module <ModuleName> where` 开头。
-- `Main` 是一个特殊的模块名：GHC 把它视为可执行程序（executable）的入口。
-- 编译器会在 `Main` 模块里寻找一个类型为 `IO ()` 的 `main` 函数，作为程序执行的起点。
-- `where` 关键字表示“该模块的具体定义从下面开始”。
-- ═══════════════════════════════════════════════════════════════════════════════
module Main where

-- ═══════════════════════════════════════════════════════════════════════════════
-- 知识点 2：Import 语法
-- ═══════════════════════════════════════════════════════════════════════════════
-- `import System.Environment (getArgs)` 表示：
--   从 `System.Environment` 模块中，**只导入 `getArgs` 这一个名字**。
-- 如果不写括号，直接 `import System.Environment`，则会导入该模块导出的所有名字。
-- `qualified`（如 `import qualified Data.Text as T`）表示：
--   导入的名字必须带前缀使用，例如 `T.pack`、`T.unpack`，避免命名冲突。
-- ═══════════════════════════════════════════════════════════════════════════════
import System.Environment (getArgs)
import System.IO (stdout)
import System.Console.ANSI (hSupportsANSI)
import qualified Data.Text as T
import Hson.Parser (parse, parseJson, ParseError(..))
import Hson.Query (queryString)
import Hson.ToJson (encode, encodeCompact, encodeColor, encodeCompactColor)
import Control.Monad (when)
import Hson.Types (JsonValue(..))

-- | 判断一个字符串是否是 JSON Path（以 . 或 [ 开头）。
isPath :: String -> Bool
isPath (c:_) = c == '.' || c == '['
isPath _     = False

-- | 判断是否是 flag 参数。
isFlag :: String -> Bool
isFlag ('-':_) = True
isFlag _       = False

-- ═══════════════════════════════════════════════════════════════════════════════
-- 知识点 4：类型签名 (Type Signature)
-- ═══════════════════════════════════════════════════════════════════════════════
-- `parseFlags :: [String] -> (Bool, Bool, Bool, Bool, [String])` 表示：
--   输入是一个字符串列表 `[String]`，输出是一个五元组 `(Bool, Bool, Bool, Bool, [String])`。
--   元组 (tuple) 可以打包多个不同类型的值一起返回。
--   这里依次返回：是否 compact / 是否 raw / 是否显式 color / 是否显式 no-color / 剩余参数。
-- ═══════════════════════════════════════════════════════════════════════════════

-- ═══════════════════════════════════════════════════════════════════════════════
-- 知识点 5：where 与局部辅助函数
-- ═══════════════════════════════════════════════════════════════════════════════
-- `parseFlags = go False False False False []` 把具体工作交给局部函数 `go`。
-- `where` 关键字用于在函数体后面定义局部变量或局部函数，只在 `parseFlags` 内部可见。
-- 这种模式叫做"尾递归辅助函数"：主函数给初始值，辅助函数负责循环遍历。
-- ═══════════════════════════════════════════════════════════════════════════════

-- ═══════════════════════════════════════════════════════════════════════════════
-- 知识点 6：模式匹配 (Pattern Matching)
-- ═══════════════════════════════════════════════════════════════════════════════
-- `go c r color noColor rest [] = ...` 匹配"列表为空"，是递归的终止条件。
-- `go c r color noColor rest (arg:args)` 匹配"非空列表"：
--   `arg` 是列表的第一个元素（头），`args` 是剩下的部分（尾）。
-- `(arg:args)` 是 Haskell 列表的构造语法， analogous to `head :: tail`。
-- ═══════════════════════════════════════════════════════════════════════════════

-- ═══════════════════════════════════════════════════════════════════════════════
-- 知识点 7：Guard（守卫）语法
-- ═══════════════════════════════════════════════════════════════════════════════
-- `|` 叫做 guard，用于根据布尔条件选择不同的分支，比嵌套 if-else 更清晰。
-- 从上往下匹配，第一个为 True 的 guard 会被执行；如果都不满足，走 `otherwise`（恒为 True）。
-- ═══════════════════════════════════════════════════════════════════════════════

-- ═══════════════════════════════════════════════════════════════════════════════
-- 知识点 8：尾递归 (Tail Recursion)
-- ═══════════════════════════════════════════════════════════════════════════════
-- `go` 每次调用自己时，都把新的状态作为参数传下去（如 `True` 替换 `c`）。
-- 因为递归调用是函数的最后一个动作，编译器可以优化成循环，不会爆栈。
-- `rest` 用来收集非 flag 参数，但它是用 `arg:rest` 往前插的，所以最终要 `reverse` 一下恢复顺序。
-- ═══════════════════════════════════════════════════════════════════════════════

-- ═══════════════════════════════════════════════════════════════════════════════
-- 知识点 9：逐步推演示例
-- ═══════════════════════════════════════════════════════════════════════════════
-- 假设命令行输入：hson -c --color examples/sample.json .users[0].name
-- 则 allArgs = ["-c", "--color", "examples/sample.json", ".users[0].name"]
--
-- 初始调用：
--   go False False False False [] ["-c", "--color", "examples/sample.json", ".users[0].name"]
--
-- 第 1 轮：arg="-c", guard 命中 `arg == "-c"`
--   -> go True False False False [] ["--color", "examples/sample.json", ".users[0].name"]
--
-- 第 2 轮：arg="--color", guard 命中 `arg == "--color"`
--   -> go True False True False [] ["examples/sample.json", ".users[0].name"]
--
-- 第 3 轮：arg="examples/sample.json", 不是 flag，走 otherwise
--   -> go True False True False ["examples/sample.json"] [".users[0].name"]
--     (注意 arg:rest 是把新元素插到列表头部)
--
-- 第 4 轮：arg=".users[0].name", 不是 flag，走 otherwise
--   -> go True False True False [".users[0].name", "examples/sample.json"] []
--
-- 第 5 轮：args 为空，匹配终止条件，reverse rest 恢复顺序
--   -> (True, False, True, False, ["examples/sample.json", ".users[0].name"])
-- ═══════════════════════════════════════════════════════════════════════════════
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

-- ═══════════════════════════════════════════════════════════════════════════════
-- 知识点 10：柯里化与"空格即函数应用"
-- ═══════════════════════════════════════════════════════════════════════════════
-- Haskell 没有 `f(a,b,c)` 这种调用语法，而是 `f a b c`。
-- 这得益于"柯里化"(Currying)：每个函数本质上只接收一个参数，返回一个新函数。
-- 例如 `add :: Int -> Int -> Int` 实际上是 `Int -> (Int -> Int)`。
--
-- 怎么区分谁是函数、谁是参数？
--   1. 看类型签名：最后一个 `->` 右边是返回值，左边都是参数。
--   2. 看定义等号左边：最左边的名字通常是函数，后面跟着的是它的参数。
--   3. 看大小写：大写开头通常是类型/构造器（如 `True`, `Just`），小写是函数或变量。
--   4. 看上下文：在 `enc json` 中，`enc` 是函数，`json` 是参数（等价于 `enc(json)`）。
--
-- 实战技巧：看到两个标识符并排 `a b`，立刻在脑子里补括号，读成 `a(b)`。
-- ═══════════════════════════════════════════════════════════════════════════════

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

-- ═══════════════════════════════════════════════════════════════════════════════
-- 知识点 11：Either 类型与错误处理
-- ═══════════════════════════════════════════════════════════════════════════════
-- `parse` 的返回值类型是 `Either ParseError (JsonValue, Text)`。
-- `Either a b` 是 Haskell 中表示"可能失败"的标准类型：
--   - `Left a`  表示失败，携带错误信息
--   - `Right b` 表示成功，携带正确结果
-- 这种设计强制调用方处理错误，不会出现静默的 null/异常。
-- ═══════════════════════════════════════════════════════════════════════════════

-- ═══════════════════════════════════════════════════════════════════════════════
-- 知识点 12：Maybe 类型与可选值
-- ═══════════════════════════════════════════════════════════════════════════════
-- `Maybe String` 表示"可能有，也可能没有"的字符串：
--   - `Just "hello"` 表示有值
--   - `Nothing`      表示没有值
-- 在 `process` 的 `mPath` 参数中，`Just path` 意味着用户传了 JSON Path 要查询；
-- `Nothing` 意味着用户只是想要格式化输出整个 JSON。
-- ═══════════════════════════════════════════════════════════════════════════════

-- ═══════════════════════════════════════════════════════════════════════════════
-- 知识点 13：process 函数逐行解剖
-- ═══════════════════════════════════════════════════════════════════════════════
-- 类型签名：process :: Bool -> (JsonValue -> String) -> Maybe String -> String -> IO ()
--   - Bool              : 是否开启 raw-output 模式
--   - (JsonValue -> String) : 编码器函数（由 selectEncoder 根据 flag 选择）
--   - Maybe String      : 可选的 JSON Path（如 `Just ".users[0].name"`）
--   - String            : 原始 JSON 输入文本
--   - IO ()             : 最终副作用（打印结果或错误信息到 stdout）
--
-- 执行流程：
--   1. `T.pack input` 把 Haskell 的 `String` 转成更高效的 `Text` 类型。
--   2. `parse parseJson (T.pack input)` 运行手写解析器。
--      - 失败（Left err）-> 打印行号、列号和错误信息。
--      - 成功（Right (json, rest)）-> `json` 是解析出的 AST，`rest` 是剩余未解析文本。
--   3. 检查 `rest` 是否全是空白字符：如果不是，说明 JSON 后面还有垃圾数据，打印警告。
--   4. 对 `mPath` 做模式匹配：
--      - `Just path` -> 用 `queryString` 在 AST 中查找。
--        * 找到（Just result）-> 用 `outputJson` 输出。
--        * 未找到（Nothing）-> 打印查询失败提示。
--      - `Nothing` -> 直接输出整个 `json`。
-- ═══════════════════════════════════════════════════════════════════════════════

-- | 统一的输出处理：解析结果 + 可选的 path 查询 + 编码选项。
process :: Bool -> (JsonValue -> String) -> Maybe String -> String -> IO ()
process raw enc mPath input = do
  case parse parseJson (T.pack input) of
    Right (json, rest) -> do
      when (not (T.all (\c -> c `elem` (" \t\n\r" :: String)) rest)) $
        putStrLn $ "Warning: unparsed trailing input: " ++ T.unpack (T.take 50 rest)
      case mPath of
        Just path ->
          case queryString (T.pack path) json of
            Just result -> outputJson raw enc result
            Nothing     -> putStrLn $ "Query failed or returned no result: " ++ path
        Nothing ->
          outputJson raw enc json
    Left err ->
      putStrLn $ "Error at line " ++ show (peLine err) ++ ", column " ++ show (peCol err) ++ ": " ++ peMessage err

-- ═══════════════════════════════════════════════════════════════════════════════
-- 知识点 3：IO Monad 与 `<-` 绑定
-- ═══════════════════════════════════════════════════════════════════════════════
-- `getArgs` 的类型是 `IO [String]`，它不是普通的列表，而是一个"会产生副作用的 IO 动作"。
-- 在 `do` 块中，`allArgs <- getArgs` 表示：
--   "执行 `getArgs` 这个动作，把得到的纯值 `[String]` 绑定到变量 `allArgs` 上"。
-- 是的，它会原封不动地把命令行参数传进来。例如运行 `hson -c file.json .a`，
-- `allArgs` 的值就是 `["-c", "file.json", ".a"]`。
-- `main :: IO ()` 中的 `IO ()` 表示：main 是一个 IO 动作，最终返回 unit（空值）。
-- ═══════════════════════════════════════════════════════════════════════════════
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
