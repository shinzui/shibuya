module Shibuya.PublicApiSpec (spec) where

import Shibuya
import Test.Hspec

spec :: Spec
spec =
  describe "Shibuya.PublicApi" $ do
    it "constructs and projects an application-defined dead-letter reason" $ do
      case mkDeadLetterCode "keiro.router.selection.recipient_overflow" of
        Left err -> expectationFailure $ "valid public code was rejected: " <> show err
        Right code -> do
          let _handler = mkRouterHandler code
              reason = routerReason code
          deadLetterCodeText (deadLetterReasonCode reason)
            `shouldBe` "keiro.router.selection.recipient_overflow"
          deadLetterReasonDetail reason
            `shouldBe` Just "selected 101 recipients; configured limit is 100"
          renderDeadLetterReason reason
            `shouldBe` "keiro.router.selection.recipient_overflow: selected 101 recipients; configured limit is 100"

mkRouterHandler :: DeadLetterCode -> Handler es RouterMessage
mkRouterHandler code _message = pure $ AckDeadLetter $ routerReason code

routerReason :: DeadLetterCode -> DeadLetterReason
routerReason code =
  ApplicationFailure
    code
    "selected 101 recipients; configured limit is 100"

type RouterMessage = ()
