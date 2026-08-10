module Bench.DeadLetterReason (benchmarks) where

import Data.Text (Text)
import Shibuya
  ( DeadLetterCode,
    DeadLetterReason (..),
    mkDeadLetterCode,
    renderDeadLetterReason,
  )
import Test.Tasty.Bench (Benchmark, bench, bgroup, nf, whnf)

benchmarks :: Benchmark
benchmarks =
  bgroup
    "dead-letter-reason"
    [ bench "validate-application-code" $
        whnf mkDeadLetterCode applicationCodeText,
      bench "render-poison-pill" $
        nf renderDeadLetterReason (PoisonPill typicalDetail),
      bench "render-application-failure" $
        nf
          renderDeadLetterReason
          (ApplicationFailure applicationCode typicalDetail)
    ]

applicationCodeText :: Text
applicationCodeText = "keiro.router.selection.recipient_overflow"

applicationCode :: DeadLetterCode
applicationCode =
  case mkDeadLetterCode applicationCodeText of
    Left err -> error ("invalid benchmark fixture: " <> show err)
    Right code -> code

typicalDetail :: Text
typicalDetail = "selected 101 recipients; configured limit is 100"
