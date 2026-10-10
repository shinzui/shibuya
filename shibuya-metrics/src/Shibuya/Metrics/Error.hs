-- | The shared HTTP error shape: human-readable text, a stable code, and context.
module Shibuya.Metrics.Error (errorResponse) where

import Data.Aeson (encode, object, (.=))
import Data.Aeson.Types (Pair)
import Data.Text (Text)
import Network.HTTP.Types (Status, hContentType)
import Network.Wai (Response, responseLBS)

-- | Render an error as JSON. Extra context cannot override @error@ or @code@.
errorResponse :: Status -> Text -> Text -> [Pair] -> Response
errorResponse status message code extras =
  responseLBS status [(hContentType, "application/json")] $
    encode $
      object $
        ["error" .= message, "code" .= code]
          <> filter (\(key, _) -> key /= "error" && key /= "code") extras
