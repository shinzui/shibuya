module Shibuya.Metrics.CorsSpec (spec) where

import Control.Exception (IOException)
import Control.Monad (forM_)
import Data.Aeson (decode, object, (.=))
import Data.ByteString (ByteString)
import Data.Char (toLower)
import Data.List (isInfixOf)
import Data.Text (Text)
import Network.HTTP.Types (RequestHeaders, hContentType, status200, status204, status403, status404, status503)
import Network.Wai (Application, requestHeaders, requestMethod, responseLBS)
import Network.Wai.Test (SResponse (..), defaultRequest, request, runSession, setPath)
import Shibuya.App (Master)
import Shibuya.Core.Metrics (ProcessorId (..))
import Shibuya.Metrics.Config (MetricsServerConfig (..), defaultConfig)
import Shibuya.Metrics.Cors (corsMiddleware, isAllowedOrigin)
import Shibuya.Metrics.Server (combinedApp, startMetricsServer)
import Shibuya.Metrics.TestSupport (registerFailedProcessor, registerIdleProcessor, withMaster)
import Shibuya.Metrics.WebSocket (newWebSocketState)
import Test.Hspec (Spec, around, describe, it, shouldBe, shouldSatisfy, shouldThrow)

spec :: Spec
spec = around withMaster $ do
  describe "cross-origin HTTP policy" $ do
    it "answers allowed preflights with an empty 204 and explicit policy" $ \master -> do
      app <- appFor master
      forM_ ["GET", "POST", "OPTIONS"] $ \method -> do
        response <- send app "OPTIONS" "/metrics" (preflight method)
        response.simpleStatus `shouldBe` status204
        response.simpleBody `shouldBe` ""
        lookup "Access-Control-Allow-Origin" response.simpleHeaders `shouldBe` Just origin
        lookup "Access-Control-Allow-Methods" response.simpleHeaders `shouldBe` Just "GET, POST, OPTIONS"
        lookup "Access-Control-Allow-Headers" response.simpleHeaders `shouldBe` Just "Content-Type"
        lookup "Access-Control-Max-Age" response.simpleHeaders `shouldBe` Just "600"
        lookup "Vary" response.simpleHeaders `shouldBe` Just "Origin, Access-Control-Request-Method, Access-Control-Request-Headers"
        lookup "Access-Control-Allow-Credentials" response.simpleHeaders `shouldBe` Nothing

    it "adds headers to every allowed read route, including 404s" $ \master -> do
      _ <- registerIdleProcessor master (ProcessorId "known")
      app <- appFor master
      forM_ ["/metrics", "/metrics/known", "/metrics/prometheus", "/health", "/health/live", "/health/ready", "/metrics/missing", "/ws", "/unknown"] $ \path -> do
        plain <- send app "GET" path []
        response <- send app "GET" path [("Origin", origin)]
        response.simpleStatus `shouldBe` plain.simpleStatus
        response.simpleBody `shouldBe` plain.simpleBody
        lookup "Access-Control-Allow-Origin" response.simpleHeaders `shouldBe` Just origin
        lookup "Vary" response.simpleHeaders `shouldBe` Just "Origin"
        lookup "Access-Control-Allow-Credentials" response.simpleHeaders `shouldBe` Nothing
      missing <- send app "GET" "/metrics/missing" [("Origin", origin)]
      missing.simpleStatus `shouldBe` status404
      decode missing.simpleBody
        `shouldBe` Just
          ( object
              ["error" .= ("Processor not found" :: Text), "code" .= ("processor_not_found" :: Text), "processor" .= ("missing" :: Text)]
          )

    it "adds allowed-origin headers to unhealthy 503 responses" $ \master -> do
      _ <- registerFailedProcessor master (ProcessorId "failed")
      app <- appFor master
      response <- send app "GET" "/health/ready" [("Origin", origin)]
      response.simpleStatus `shouldBe` status503
      lookup "Access-Control-Allow-Origin" response.simpleHeaders `shouldBe` Just origin

    it "refuses disallowed preflights but preserves ordinary read responses" $ \master -> do
      app <- appFor master
      response <- send app "OPTIONS" "/metrics" [("Origin", "https://evil.example.com"), ("Access-Control-Request-Method", "GET")]
      response.simpleStatus `shouldBe` status403
      decode response.simpleBody `shouldBe` Just (object ["error" .= ("Origin not allowed" :: Text), "code" .= ("origin_not_allowed" :: Text)])
      lookup hContentType response.simpleHeaders `shouldBe` Just "application/json"
      noAccessHeaders response
      lookup "Vary" response.simpleHeaders `shouldBe` Just "Origin, Access-Control-Request-Method, Access-Control-Request-Headers"
      plain <- send app "GET" "/metrics" []
      refused <- send app "GET" "/metrics" [("Origin", "https://evil.example.com")]
      refused.simpleStatus `shouldBe` status200
      refused.simpleBody `shouldBe` plain.simpleBody
      noAccessHeaders refused
      lookup "Vary" refused.simpleHeaders `shouldBe` Just "Origin"
      lookup "Vary" plain.simpleHeaders `shouldBe` Just "Origin"

    it "validates and echoes requested header tokens" $ \master -> do
      app <- appFor master
      response <- send app "OPTIONS" "/metrics" (preflight "GET" <> [("Access-Control-Request-Headers", "x-trace-id, Content-Type")])
      response.simpleStatus `shouldBe` status204
      lookup "Access-Control-Allow-Headers" response.simpleHeaders `shouldBe` Just "x-trace-id, Content-Type"
      forM_ ["", "bad header", "x-trace-id,", "x-trace-id\r\nInjected: yes", "*"] $ \headers -> do
        invalid <- send app "OPTIONS" "/metrics" (preflight "GET" <> [("Access-Control-Request-Headers", headers)])
        invalid.simpleStatus `shouldBe` status403
        noAccessHeaders invalid
      repeatedEmpty <-
        send
          app
          "OPTIONS"
          "/metrics"
          (preflight "GET" <> [("Access-Control-Request-Headers", ""), ("Access-Control-Request-Headers", "x-trace-id")])
      repeatedEmpty.simpleStatus `shouldBe` status403
      noAccessHeaders repeatedEmpty

    it "rejects forbidden, malformed, and repeated requested methods" $ \master -> do
      app <- appFor master
      forM_ ["DELETE", "get", "GET, POST", ""] $ \method -> do
        response <- send app "OPTIONS" "/metrics" (preflight method)
        response.simpleStatus `shouldBe` status403
        decode response.simpleBody `shouldBe` Just (object ["error" .= ("CORS method not allowed" :: Text), "code" .= ("cors_method_not_allowed" :: Text)])
        noAccessHeaders response
      repeated <- send app "OPTIONS" "/metrics" (preflight "GET" <> [("Access-Control-Request-Method", "POST")])
      repeated.simpleStatus `shouldBe` status403

    it "fails closed for malformed or multiple Origin values" $ \master -> do
      app <- appFor master
      forM_ [[("Origin", "null")], [("Origin", "")], [("Origin", "https://ops.example.com https://evil.example.com")], [("Origin", "https://ops.example.com,https://evil.example.com")], [("Origin", origin <> "/")], [("Origin", origin), ("origin", origin)]] $ \origins -> do
        response <- send app "OPTIONS" "/metrics" (origins <> [("Access-Control-Request-Method", "GET")])
        response.simpleStatus `shouldBe` status403
        noAccessHeaders response
        ordinary <- send app "GET" "/metrics" origins
        noAccessHeaders ordinary

    it "routes plain OPTIONS normally when preflight headers are absent" $ \master -> do
      app <- appFor master
      response <- send app "OPTIONS" "/unknown" [("Origin", origin)]
      response.simpleStatus `shouldBe` status404
      methodOnly <- send app "OPTIONS" "/unknown" [("Access-Control-Request-Method", "GET")]
      methodOnly.simpleStatus `shouldBe` status404

    it "merges Vary tokens and replaces any stale CORS policy headers" $ \_ -> do
      let inner _ respond =
            respond $
              responseLBS
                status200
                [("Vary", "Accept-Encoding, origin"), ("vary", "Accept-Language"), ("Access-Control-Allow-Origin", "*"), ("Access-Control-Allow-Credentials", "true")]
                "body"
          app = corsMiddleware ["https://ops.example.com"] inner
      forM_ [[], [("Origin", origin)], [("Origin", "https://evil.example.com")]] $ \headers -> do
        response <- send app "GET" "/" headers
        lookup "Vary" response.simpleHeaders `shouldBe` Just "Accept-Encoding, origin, Accept-Language"
        length (filter ((== "Vary") . fst) response.simpleHeaders) `shouldBe` 1
        lookup "Access-Control-Allow-Credentials" response.simpleHeaders `shouldBe` Nothing
      allowed <- send app "GET" "/" [("Origin", origin)]
      filter ((== "Access-Control-Allow-Origin") . fst) allowed.simpleHeaders `shouldBe` [("Access-Control-Allow-Origin", origin)]
      refused <- send app "GET" "/" [("Origin", "https://evil.example.com")]
      noAccessHeaders refused
      wildcard <- send (corsMiddleware ["https://ops.example.com"] (\_ respond -> respond $ responseLBS status200 [("Vary", "*")] "body")) "GET" "/" []
      lookup "Vary" wildcard.simpleHeaders `shouldBe` Just "*"

    it "compares origin bytes exactly without normalizing or prefix matching" $ \_ -> do
      let allowed = isAllowedOrigin ["https://ops.example.com"]
      allowed origin `shouldBe` True
      forM_ ["https://OPS.example.com", "https://ops.example.com:443", "https://ops.example.com.evil", "https://ops.example.com/"] $ \other -> allowed other `shouldBe` False

    it "rejects invalid configured origins before opening a listener" $ \master ->
      forM_ ["*", "", "https://ops.example.com/", "ops.example.com", "1https://ops.example.com", "://ops.example.com", "https://", "https://ops.example.com?x=1", "https://ops.example.com#x", "https://ops. example.com", "https://ops.example.com\t"] $ \invalid ->
        startMetricsServer defaultConfig {corsAllowedOrigins = [invalid]} master
          `shouldThrow` (\err -> "corsAllowedOrigins" `isInfixOf` show (err :: IOException))

origin :: ByteString
origin = "https://ops.example.com"

preflight :: ByteString -> RequestHeaders
preflight method = [("Origin", origin), ("Access-Control-Request-Method", method)]

send :: Application -> ByteString -> ByteString -> RequestHeaders -> IO SResponse
send app method path headers =
  runSession
    (request $ setPath defaultRequest {requestMethod = method, requestHeaders = headers} path)
    app

appFor :: Master -> IO Application
appFor master = do
  wsState <- newWebSocketState defaultConfig.wsMaxConnections
  pure $ combinedApp defaultConfig {corsAllowedOrigins = ["https://ops.example.com"]} master wsState []

noAccessHeaders :: SResponse -> IO ()
noAccessHeaders response =
  response.simpleHeaders
    `shouldSatisfy` (not . any (\(name, _) -> "access-control-" `isInfixOf` map toLower (show name)))
