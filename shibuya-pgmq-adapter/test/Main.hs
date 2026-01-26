module Main (main) where

import Shibuya.Adapter.Pgmq.ConvertSpec qualified as ConvertSpec
import Test.Hspec

main :: IO ()
main = hspec $ do
  describe "Shibuya.Adapter.Pgmq.Convert" ConvertSpec.spec
