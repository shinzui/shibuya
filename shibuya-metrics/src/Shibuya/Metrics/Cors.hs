-- | Opt-in, exact-origin browser response policy. This is not authentication.
module Shibuya.Metrics.Cors
  ( corsMiddleware,
    isAllowedOrigin,
    isValidOrigin,
  )
where

import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BS
import Data.Char (isAsciiLower, isAsciiUpper, isSpace, toLower)
import Data.List (foldl')
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding (encodeUtf8)
import Network.HTTP.Types (HeaderName, RequestHeaders, ResponseHeaders, status204, status403)
import Network.Wai (Middleware, mapResponseHeaders, requestHeaders, requestMethod, responseLBS)
import Shibuya.Metrics.Error (errorResponse)

-- | Check configured origin syntax. Entries must still be written exactly as the
-- browser serializes them; matching does not normalize scheme, host or port.
isValidOrigin :: Text -> Bool
isValidOrigin origin =
  not (Text.any isSpace origin)
    && case Text.breakOn "://" origin of
      (scheme, suffix) ->
        case Text.uncons scheme of
          Nothing -> False
          Just (first, rest) ->
            asciiLetter first
              && Text.all (\c -> asciiLetter c || asciiDigit c || c `elem` ("+-." :: String)) rest
              && not (Text.null suffix)
              && let authority = Text.drop 3 suffix
                  in not (Text.null authority)
                       && Text.all (\c -> c > '\x20' && c < '\x7f' && c `notElem` ("/?#,@\\" :: String)) authority
  where
    asciiLetter c = isAsciiLower c || isAsciiUpper c
    asciiDigit c = c >= '0' && c <= '9'

-- | Compile the allow list once when constructing an application. Matching is
-- byte-for-byte: no case folding, default-port removal or prefix matching.
isAllowedOrigin :: [Text] -> ByteString -> Bool
isAllowedOrigin origins = (`Set.member` compiled)
  where
    compiled = Set.fromList $ map encodeUtf8 origins

-- | Disabled by an empty list. When enabled, ordinary reads keep their status and
-- body, and every response varies by Origin. Only explicit allowed origins get
-- response permission. Preflights validate methods and header names before 204.
-- This middleware does not authorize mutation; control routes must validate the
-- actual request's single Origin before acting, even when CORS is disabled.
corsMiddleware :: [Text] -> Middleware
corsMiddleware [] = id
corsMiddleware origins = \app req respond ->
  let headers = requestHeaders req
      suppliedOrigin = singleHeader "Origin" headers
      allowed = maybe False permits suppliedOrigin
      preflight =
        requestMethod req == "OPTIONS"
          && hasHeader "Origin" headers
          && hasHeader "Access-Control-Request-Method" headers
      decorate =
        mapResponseHeaders $
          if preflight
            then mergeVary preflightVary
            else decorateHeaders (if allowed then suppliedOrigin else Nothing)
   in if preflight
        then respond $ decorate $ case () of
          _
            | not allowed -> errorResponse status403 "Origin not allowed" "origin_not_allowed" []
            | maybe True (`notElem` ["GET", "POST", "OPTIONS"]) (singleHeader "Access-Control-Request-Method" headers) ->
                errorResponse status403 "CORS method not allowed" "cors_method_not_allowed" []
            | otherwise -> case requestedHeaders headers of
                Nothing -> errorResponse status403 "CORS headers not allowed" "cors_headers_not_allowed" []
                Just names ->
                  responseLBS
                    status204
                    [ ("Access-Control-Allow-Origin", maybe "" id suppliedOrigin),
                      ("Access-Control-Allow-Methods", "GET, POST, OPTIONS"),
                      ("Access-Control-Allow-Headers", names),
                      ("Access-Control-Max-Age", "600")
                    ]
                    ""
        else app req (respond . decorate)
  where
    permits = isAllowedOrigin origins

singleHeader :: HeaderName -> RequestHeaders -> Maybe ByteString
singleHeader name headers = case [value | (key, value) <- headers, key == name] of
  [value] -> Just value
  _ -> Nothing

hasHeader :: HeaderName -> RequestHeaders -> Bool
hasHeader name = any ((== name) . fst)

requestedHeaders :: RequestHeaders -> Maybe ByteString
requestedHeaders headers = case [value | (key, value) <- headers, key == "Access-Control-Request-Headers"] of
  [] -> Just "Content-Type"
  values ->
    let names = concatMap (map trim . BS.split ',') values
     in if not (null names) && all validToken names then Just (BS.intercalate ", " names) else Nothing
  where
    validToken token = not (BS.null token) && token /= "*" && BS.all tokenChar token
    tokenChar c =
      isAsciiLower c
        || isAsciiUpper c
        || (c >= '0' && c <= '9')
        || c `elem` ("!#$%&'*+-.^_`|~" :: String)

trim :: ByteString -> ByteString
trim = BS.dropWhileEnd horizontalSpace . BS.dropWhile horizontalSpace
  where
    horizontalSpace c = c == ' ' || c == '\t'

preflightVary :: [ByteString]
preflightVary = ["Origin", "Access-Control-Request-Method", "Access-Control-Request-Headers"]

-- Preserve unrelated Vary tokens and collapse all Vary fields, including a
-- pre-existing wildcard. Strip stale permission/credential headers from hosts.
decorateHeaders :: Maybe ByteString -> ResponseHeaders -> ResponseHeaders
decorateHeaders origin headers =
  mergeVary ["Origin"] (filter (\(name, _) -> name `notElem` permissionHeaders) headers)
    <> maybe [] (\value -> [("Access-Control-Allow-Origin", value)]) origin
  where
    permissionHeaders =
      [ "Access-Control-Allow-Origin",
        "Access-Control-Allow-Credentials",
        "Access-Control-Allow-Methods",
        "Access-Control-Allow-Headers",
        "Access-Control-Max-Age",
        "Access-Control-Expose-Headers"
      ]

mergeVary :: [ByteString] -> ResponseHeaders -> ResponseHeaders
mergeVary required headers =
  let existing = concatMap (map trim . BS.split ',') [value | (name, value) <- headers, name == "Vary"]
      tokens = foldl' addToken [] (filter (not . BS.null) existing <> required)
      vary = if "*" `elem` tokens then "*" else BS.intercalate ", " tokens
      kept = filter ((/= "Vary") . fst) headers
   in kept <> [("Vary", vary)]
  where
    addToken tokens token
      | any (\existing -> BS.map toLower existing == BS.map toLower token) tokens = tokens
      | otherwise = tokens <> [token]
