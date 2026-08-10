{-# LANGUAGE ImportQualifiedPost #-}

module Main (main) where

import Shibuya.App.BatchSpec qualified
import Shibuya.App.LifecycleSpec qualified
import Shibuya.Batch.ReliabilitySpec qualified
import Shibuya.BatchSpec qualified
import Shibuya.Core.AckSpec qualified
import Shibuya.Core.RetrySpec qualified
import Shibuya.Core.TypesSpec qualified
import Shibuya.PolicySpec qualified
import Shibuya.PublicApiSpec qualified
import Shibuya.Runner.BatchProcessorSpec qualified
import Shibuya.Runner.BatcherSpec qualified
import Shibuya.Runner.PartitionOrderingSpec qualified
import Shibuya.Runner.SupervisedSpec qualified
import Shibuya.RunnerSpec qualified
import Shibuya.Telemetry.EffectSpec qualified
import Shibuya.Telemetry.PropagationSpec qualified
import Shibuya.Telemetry.SemanticSpec qualified
import Test.Hspec

main :: IO ()
main = hspec $ do
  Shibuya.App.BatchSpec.spec
  Shibuya.App.LifecycleSpec.spec
  Shibuya.Batch.ReliabilitySpec.spec
  Shibuya.BatchSpec.spec
  describe "Shibuya.Core.Types" Shibuya.Core.TypesSpec.spec
  describe "Shibuya.Core.Ack" Shibuya.Core.AckSpec.spec
  describe "Shibuya.Core.Retry" Shibuya.Core.RetrySpec.spec
  describe "Shibuya.Policy" Shibuya.PolicySpec.spec
  Shibuya.PublicApiSpec.spec
  describe "Shibuya.Runner" Shibuya.RunnerSpec.spec
  Shibuya.Runner.BatcherSpec.spec
  Shibuya.Runner.BatchProcessorSpec.spec
  Shibuya.Runner.PartitionOrderingSpec.spec
  Shibuya.Runner.SupervisedSpec.spec
  Shibuya.Telemetry.EffectSpec.spec
  Shibuya.Telemetry.PropagationSpec.spec
  Shibuya.Telemetry.SemanticSpec.spec
