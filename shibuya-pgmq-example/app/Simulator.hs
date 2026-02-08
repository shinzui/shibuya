-- | Message simulator for the PGMQ example.
--
-- Produces realistic test messages to various queues.
--
-- Usage:
--
-- @
-- export DATABASE_URL="postgres://user:pass@localhost/pgmq"
-- cabal run shibuya-pgmq-simulator -- --queue orders --count 100
-- cabal run shibuya-pgmq-simulator -- --queue payments --count 50 --rate 10
-- cabal run shibuya-pgmq-simulator -- --queue notifications --count 1000 --batch 50
-- @
module Main (main) where

import Control.Concurrent (threadDelay)
import Control.Monad (forM_, replicateM, when)
import Data.Aeson (Value, decode, encode, object, (.=))
import Data.ByteString.Char8 qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as Text
import Data.Time.Clock (getCurrentTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import Example.Config
  ( QueueTarget (..),
    parseQueueTarget,
  )
import Example.Database
  ( createQueues,
    notificationsQueueName,
    ordersQueueName,
    paymentsQueueName,
    withDatabasePool,
  )
import Hasql.Pool qualified as Pool
import Pgmq.Hasql.Sessions qualified as Pgmq
import Pgmq.Hasql.Statements.Types qualified as Q
import Pgmq.Types
  ( MessageBody (..),
    MessageHeaders (..),
    QueueName,
  )
import System.Environment (getArgs, getEnv)
import System.Random (randomRIO)

--------------------------------------------------------------------------------
-- CLI Parsing
--------------------------------------------------------------------------------

data CliArgs = CliArgs
  { queue :: !QueueTarget,
    count :: !Int,
    rate :: !Int,
    batchSize :: !Int
  }

parseArgs :: IO CliArgs
parseArgs = do
  args <- getArgs
  let parsed = parseArgPairs args
  queue <- case lookup "--queue" parsed of
    Just q -> case parseQueueTarget q of
      Just t -> pure t
      Nothing -> fail $ "Invalid queue: " <> q <> ". Use: orders, payments, notifications"
    Nothing -> pure OrdersQueue

  count <- getArgInt parsed "--count" 100
  rate <- getArgInt parsed "--rate" 50
  batch <- getArgInt parsed "--batch-size" 10

  pure
    CliArgs
      { queue = queue,
        count = count,
        rate = rate,
        batchSize = batch
      }

parseArgPairs :: [String] -> [(String, String)]
parseArgPairs [] = []
parseArgPairs [_] = []
parseArgPairs (k : v : rest) = (k, v) : parseArgPairs rest

getArgInt :: [(String, String)] -> String -> Int -> IO Int
getArgInt pairs key def = pure $ maybe def read (lookup key pairs)

--------------------------------------------------------------------------------
-- Message Generation
--------------------------------------------------------------------------------

-- | Generate a random order message.
generateOrder :: Int -> IO LBS.ByteString
generateOrder idx = do
  numItems <- randomRIO (1, 5 :: Int)
  items <- replicateM numItems generateOrderItem
  let totalAmount = sum [fromIntegral q * p | (_, _, q, p) <- items]
  pure $
    encode $
      object
        [ "orderId" .= ("ORD-" <> show idx),
          "customerId" .= ("CUST-" <> show (idx `mod` 100)),
          "items" .= [mkItem i | i <- items],
          "totalAmount" .= totalAmount,
          "status" .= ("Pending" :: Text)
        ]
  where
    mkItem (prodId, name, qty, price) =
      object
        [ "productId" .= prodId,
          "productName" .= name,
          "quantity" .= qty,
          "unitPrice" .= price
        ]

    generateOrderItem :: IO (Text, Text, Int, Double)
    generateOrderItem = do
      prodIdx <- randomRIO (1, 1000 :: Int)
      qty <- randomRIO (1, 5)
      price <- randomRIO (9.99, 199.99 :: Double)
      pure
        ( "PROD-" <> Text.pack (show prodIdx),
          "Product " <> Text.pack (show prodIdx),
          qty,
          price
        )

-- | Generate a random payment message.
-- Returns (message, customerId for FIFO grouping)
generatePayment :: Int -> IO (LBS.ByteString, Text)
generatePayment idx = do
  customerId <- pure $ "CUST-" <> Text.pack (show (idx `mod` 50))
  amount <- randomRIO (10.0, 5000.0 :: Double)
  methodIdx <- randomRIO (0, 3 :: Int)
  let methods = ["CreditCard", "DebitCard", "BankTransfer", "Wallet"] :: [Text]
      method = methods !! methodIdx
  pure
    ( encode $
        object
          [ "paymentId" .= ("PAY-" <> show idx),
            "orderId" .= ("ORD-" <> show idx),
            "customerId" .= customerId,
            "amount" .= amount,
            "currency" .= ("USD" :: Text),
            "method" .= method,
            "status" .= ("PaymentPending" :: Text)
          ],
      customerId
    )

-- | Generate a random notification message.
generateNotification :: Int -> IO LBS.ByteString
generateNotification idx = do
  typeIdx <- randomRIO (0, 2 :: Int)
  priorityIdx <- randomRIO (0, 3 :: Int)
  let types = ["Email", "SMS", "Push"] :: [Text]
      priorities = ["Low", "Normal", "High", "Urgent"] :: [Text]
  pure $
    encode $
      object
        [ "notificationId" .= ("NOTIF-" <> show idx),
          "userId" .= ("USER-" <> show (idx `mod` 1000)),
          "notificationType" .= (types !! typeIdx),
          "title" .= ("Notification " <> show idx),
          "body" .= ("This is notification message #" <> show idx),
          "priority" .= (priorities !! priorityIdx)
        ]

--------------------------------------------------------------------------------
-- Sending Logic
--------------------------------------------------------------------------------

sendToQueue ::
  Pool.Pool ->
  QueueTarget ->
  Int ->
  Int ->
  Int ->
  IO ()
sendToQueue pool target count rate batchSize = do
  let queueName = targetToQueueName target
      delayMicros = if rate > 0 then 1_000_000 `div` rate else 0

  Text.putStrLn $ "Sending " <> Text.pack (show count) <> " messages to " <> Text.pack (show target)
  Text.putStrLn $ "  Rate: " <> Text.pack (show rate) <> " msg/s"
  Text.putStrLn $ "  Batch size: " <> Text.pack (show batchSize)
  Text.putStrLn ""

  case target of
    OrdersQueue -> sendBatched pool queueName count batchSize delayMicros generateOrder
    PaymentsQueue -> sendPaymentsFifo pool queueName count delayMicros
    NotificationsQueue -> sendBatched pool queueName count batchSize delayMicros generateNotification

targetToQueueName :: QueueTarget -> QueueName
targetToQueueName OrdersQueue = ordersQueueName
targetToQueueName PaymentsQueue = paymentsQueueName
targetToQueueName NotificationsQueue = notificationsQueueName

-- | Send messages in batches.
sendBatched ::
  Pool.Pool ->
  QueueName ->
  Int ->
  Int ->
  Int ->
  (Int -> IO LBS.ByteString) ->
  IO ()
sendBatched pool queueName count batchSize delayMicros generator = do
  let batches = [1, 1 + batchSize .. count]
  forM_ (zip [1 ..] batches) $ \(batchNum, startIdx) -> do
    let endIdx = min (startIdx + batchSize - 1) count
        indices = [startIdx .. endIdx]

    -- Generate messages for this batch
    bodies <- mapM generator indices
    let messageBodies = map (MessageBody . decodePayload) bodies
        req =
          Q.BatchSendMessage
            { queueName = queueName,
              messageBodies = messageBodies,
              delay = Nothing
            }

    result <- Pool.use pool $ Pgmq.batchSendMessage req
    case result of
      Left err -> Text.putStrLn $ "Error sending batch: " <> Text.pack (show err)
      Right _ -> do
        when (batchNum `mod` 10 == 0) $
          Text.putStrLn $
            "  Sent batch " <> Text.pack (show batchNum) <> " (" <> Text.pack (show endIdx) <> "/" <> Text.pack (show count) <> ")"

    when (delayMicros > 0) $ threadDelay delayMicros

  Text.putStrLn $ "Done! Sent " <> Text.pack (show count) <> " messages."

-- | Send payment messages with FIFO grouping by customerId.
sendPaymentsFifo ::
  Pool.Pool ->
  QueueName ->
  Int ->
  Int ->
  IO ()
sendPaymentsFifo pool queueName count delayMicros = do
  forM_ [1 .. count] $ \idx -> do
    (body, customerId) <- generatePayment idx
    let req =
          Q.SendMessageWithHeaders
            { queueName = queueName,
              messageBody = MessageBody (decodePayload body),
              messageHeaders = MessageHeaders $ object ["x-pgmq-group" .= customerId],
              delay = Nothing
            }

    result <- Pool.use pool $ Pgmq.sendMessageWithHeaders req
    case result of
      Left err -> Text.putStrLn $ "Error sending payment: " <> Text.pack (show err)
      Right _ ->
        when (idx `mod` 50 == 0) $
          Text.putStrLn $
            "  Sent " <> Text.pack (show idx) <> "/" <> Text.pack (show count) <> " payments"

    when (delayMicros > 0) $ threadDelay delayMicros

  Text.putStrLn $ "Done! Sent " <> Text.pack (show count) <> " payments with FIFO grouping."

-- | Decode lazy bytestring to Aeson Value.
decodePayload :: LBS.ByteString -> Value
decodePayload bs = case decode bs of
  Just v -> v
  Nothing -> error "Failed to decode payload"

--------------------------------------------------------------------------------
-- Main
--------------------------------------------------------------------------------

main :: IO ()
main = do
  Text.putStrLn "=== Shibuya PGMQ Simulator ==="
  Text.putStrLn ""

  args <- parseArgs
  connStr <- fmap BS.pack $ getEnv "DATABASE_URL"

  now <- getCurrentTime
  Text.putStrLn $ "Started at: " <> Text.pack (formatTime defaultTimeLocale "%Y-%m-%d %H:%M:%S" now)
  Text.putStrLn ""

  withDatabasePool connStr $ \pool -> do
    Text.putStrLn "Creating queues if needed..."
    createQueues pool
    Text.putStrLn ""

    sendToQueue pool args.queue args.count args.rate args.batchSize

  Text.putStrLn ""
  Text.putStrLn "Simulator finished."
