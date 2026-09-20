-- | Run one EP-45 lifecycle workload and emit one JSON sample.
--
-- Usage:
--
-- @
-- lifecycle-load --scenario serial-small-inbox --sample-id baseline-n1-01
-- lifecycle-load --list
-- @
module Main (main) where

import Bench.Lifecycle
  ( lifecycleResultValue,
    lookupScenario,
    overrideMessageCount,
    runLifecycleScenario,
    scenarioNames,
  )
import Data.Aeson (encode)
import Data.ByteString.Lazy.Char8 qualified as LazyByteString
import Data.Text (Text)
import Data.Text qualified as Text
import System.Environment (getArgs)

main :: IO ()
main = do
  args <- getArgs
  if args == ["--list"]
    then mapM_ (putStrLn . Text.unpack) scenarioNames
    else do
      options <- either (ioError . userError) pure (parseOptions args)
      requested <- requireOption "--scenario" options
      sampleId <- requireOption "--sample-id" options
      scenario <-
        maybe
          (ioError (userError ("unknown scenario: " <> Text.unpack requested)))
          pure
          (lookupScenario requested)
      scenario' <-
        case lookup "--messages" options of
          Nothing -> pure scenario
          Just rawCount ->
            case reads (Text.unpack rawCount) of
              [(count, "")] | count >= 0 -> pure (overrideMessageCount count scenario)
              _ -> ioError (userError "--messages must be a nonnegative integer")
      result <- runLifecycleScenario scenario'
      LazyByteString.putStrLn (encode (lifecycleResultValue sampleId result))

parseOptions :: [String] -> Either String [(Text, Text)]
parseOptions = go []
  where
    go result [] = Right result
    go _ [key] = Left ("missing value for option " <> key)
    go result (key : value : rest)
      | "--" `Text.isPrefixOf` Text.pack key = go ((Text.pack key, Text.pack value) : result) rest
      | otherwise = Left ("unexpected argument " <> key)

requireOption :: Text -> [(Text, Text)] -> IO Text
requireOption key options =
  maybe
    (ioError (userError ("missing required option " <> Text.unpack key)))
    pure
    (lookup key options)
