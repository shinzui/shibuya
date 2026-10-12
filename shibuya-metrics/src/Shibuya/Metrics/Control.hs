-- | Opt-in reversible intake control. This surface performs no authentication.
module Shibuya.Metrics.Control (controlApp) where

import Data.Aeson (encode, object, (.=))
import Data.Text (Text)
import Network.HTTP.Types (methodGet, methodPost, status200, status403, status404, status405, status409)
import Network.Wai (Application, mapResponseHeaders, pathInfo, requestHeaders, requestMethod, responseLBS)
import Shibuya.App (Master)
import Shibuya.Core.Metrics (ProcessorId (..))
import Shibuya.Internal.Runner.Master
  ( ControlOutcome (..),
    PauseState (..),
    pauseProcessorIO,
    resumeProcessorIO,
  )
import Shibuya.Metrics.Config (MetricsServerConfig (..))
import Shibuya.Metrics.Cors (isAllowedOrigin)
import Shibuya.Metrics.Error (errorResponse)

-- | Discovery and POST actions. Successful bodies describe the intake state at
-- the atomic decision; another operation may supersede it before delivery.
controlApp :: MetricsServerConfig -> Master -> Application
controlApp config master = \req respond -> case pathInfo req of
  ["control"]
    | requestMethod req == methodGet ->
        respond $
          json $
            object
              ["enabled" .= config.enableControl, "operations" .= (["pause", "resume"] :: [Text])]
    | otherwise -> respond $ methodRefusal "GET"
  ["control", "processors", pid, operation]
    | operation == "pause" || operation == "resume" ->
        if requestMethod req /= methodPost
          then respond $ methodRefusal "POST"
          else
            if not config.enableControl
              then respond $ errorResponse status403 "Control operations are disabled" "control_disabled" []
              else
                if not (allowedRequest req)
                  then respond $ errorResponse status403 "Origin not allowed" "origin_not_allowed" []
                  else do
                    outcome <- (if operation == "pause" then pauseProcessorIO else resumeProcessorIO) master (ProcessorId pid)
                    respond $ case outcome of
                      ControlApplied state -> success pid state
                      ControlAlreadyInState state -> success pid state
                      ControlNotFound -> refusal pid status404 "Processor not found" "processor_not_found"
                      ControlNotControllable -> refusal pid status409 "Processor is not controllable" "processor_not_controllable"
                      ControlTerminal -> refusal pid status409 "Processor has terminated" "processor_terminal"
                      ControlDraining -> refusal pid status409 "Processor is draining" "processor_draining"
  _ -> respond $ errorResponse status404 "Not found" "not_found" []
  where
    -- Compile once outside the request loop, including the empty policy. A
    -- bodyless/simple POST still requires its supplied Origin to be allowed.
    permits = isAllowedOrigin config.corsAllowedOrigins
    allowedRequest req = case [value | (name, value) <- requestHeaders req, name == "Origin"] of
      [] -> True
      [origin] -> permits origin
      _ -> False
    json = responseLBS status200 [("Content-Type", "application/json")] . encode
    methodRefusal allowed =
      mapResponseHeaders (("Allow", allowed) :) $
        errorResponse status405 "Method not allowed" "method_not_allowed" []
    refusal pid status message code = errorResponse status message code ["processor" .= pid]
    success pid state =
      json $
        object $
          ["processor" .= pid] ++ case state of
            IntakeRunning -> ["state" .= ("running" :: Text)]
            IntakePaused since -> ["state" .= ("paused" :: Text), "pausedAt" .= since]
