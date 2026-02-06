module BenchSetup
  ( -- * Pool Management
    withBenchPool,
    runSession,

    -- * Queue Lifecycle
    createBenchQueue,
    dropBenchQueue,
    purgeQueue,
    seedQueue,
    seedQueueWithHeaders,

    -- * Queue Naming
    benchQueueName,
    uniqueQueueName,

    -- * Schema Installation
    installPgmqSchema,

    -- * Payload Generation
    generatePayload,
    generatePayloads,
  )
where

import BenchConfig (BenchConfig (..), PayloadSize (..), payloadBytes)
import Control.Exception (bracket)
import Data.Aeson (Value (..), object, (.=))
import Data.ByteString (ByteString)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Data.Time (secondsToDiffTime)
import Data.Vector qualified as V
import Data.Word (Word64)
import Hasql.Connection qualified as Connection
import Hasql.Connection.Setting qualified as Setting
import Hasql.Connection.Setting.Connection qualified as Connection.Setting
import Hasql.Pool qualified as Pool
import Hasql.Pool.Config qualified as PoolConfig
import Hasql.Session qualified as Session
import Numeric (showHex)
import Pgmq.Hasql.Sessions qualified as Pgmq
import Pgmq.Hasql.Statements.Types qualified as Q
import Pgmq.Migration qualified as Migration
import Pgmq.Types
  ( MessageBody (..),
    MessageHeaders (..),
    QueueName,
    parseQueueName,
  )
import System.Random (randomIO)

-- | Run an action with a connection pool configured from BenchConfig.
withBenchPool :: BenchConfig -> (Pool.Pool -> IO a) -> IO a
withBenchPool config action = do
  pool <- createPool config.connectionString
  bracket (pure pool) Pool.release action

-- | Create a connection pool from a connection string.
createPool :: ByteString -> IO Pool.Pool
createPool connStr = do
  let connSettings = [Setting.connection (Connection.Setting.string (TE.decodeUtf8 connStr))]
      poolConfig =
        PoolConfig.settings
          [ PoolConfig.size 20,
            PoolConfig.acquisitionTimeout (secondsToDiffTime 30),
            PoolConfig.agingTimeout (secondsToDiffTime 3600),
            PoolConfig.idlenessTimeout (secondsToDiffTime 60),
            PoolConfig.staticConnectionSettings connSettings
          ]
  Pool.acquire poolConfig

-- | Run a hasql Session against the pool, throwing on error.
runSession :: Pool.Pool -> Session.Session a -> IO a
runSession pool session = do
  result <- Pool.use pool session
  case result of
    Left err -> error $ "Session error: " <> show err
    Right a -> pure a

-- | Install pgmq schema into a PostgreSQL database.
installPgmqSchema :: Pool.Pool -> IO ()
installPgmqSchema pool = do
  let connStr = "" -- We need to use the pool differently for migrations
  -- Actually, we can run migrate through the pool
  result <- Pool.use pool Migration.migrate
  case result of
    Left sessionErr -> error $ "Migration session error: " <> show sessionErr
    Right (Left migrationErr) -> error $ "Migration error: " <> show migrationErr
    Right (Right ()) -> pure ()

-- | Create a benchmark queue with a given base name.
createBenchQueue :: Pool.Pool -> QueueName -> IO ()
createBenchQueue pool qName =
  runSession pool $ Pgmq.createQueue qName

-- | Drop a benchmark queue.
dropBenchQueue :: Pool.Pool -> QueueName -> IO ()
dropBenchQueue pool qName = do
  _ <- runSession pool $ Pgmq.dropQueue qName
  pure ()

-- | Delete all messages from a queue.
purgeQueue :: Pool.Pool -> QueueName -> IO ()
purgeQueue pool qName = do
  _ <- runSession pool $ Pgmq.deleteAllMessagesFromQueue qName
  pure ()

-- | Seed a queue with a specified number of messages of a given payload size.
seedQueue :: Pool.Pool -> QueueName -> Int -> PayloadSize -> IO ()
seedQueue pool qName count payloadSize = do
  let payloads = generatePayloads count payloadSize
  -- Send in batches of 1000 for efficiency
  mapM_ (sendBatch pool qName) (chunksOf 1000 payloads)
  where
    sendBatch :: Pool.Pool -> QueueName -> [Value] -> IO ()
    sendBatch p q msgs = do
      let bodies = map MessageBody msgs
          req =
            Q.BatchSendMessage
              { queueName = q,
                messageBodies = bodies,
                delay = Nothing
              }
      _ <- runSession p $ Pgmq.batchSendMessage req
      pure ()

-- | Seed a queue with messages that have FIFO group headers.
seedQueueWithHeaders :: Pool.Pool -> QueueName -> Int -> Int -> PayloadSize -> IO ()
seedQueueWithHeaders pool qName count numGroups payloadSize = do
  let payloads = generatePayloads count payloadSize
      withGroups = zipWith addGroupHeader payloads (cycle [1 .. numGroups])
  mapM_ (sendBatchWithHeaders pool qName) (chunksOf 1000 withGroups)
  where
    addGroupHeader :: Value -> Int -> (Value, MessageHeaders)
    addGroupHeader payload groupNum =
      ( payload,
        MessageHeaders $ object ["x-pgmq-group" .= ("group-" <> Text.pack (show groupNum))]
      )

    sendBatchWithHeaders :: Pool.Pool -> QueueName -> [(Value, MessageHeaders)] -> IO ()
    sendBatchWithHeaders p q msgs = do
      let bodies = [MessageBody body | (body, _) <- msgs]
          headers = [hdr | (_, hdr) <- msgs]
          req =
            Q.BatchSendMessageWithHeaders
              { queueName = q,
                messageBodies = bodies,
                messageHeaders = headers,
                delay = Nothing
              }
      _ <- runSession p $ Pgmq.batchSendMessageWithHeaders req
      pure ()

-- | Create a deterministic queue name with a given prefix.
benchQueueName :: Text -> QueueName
benchQueueName prefix =
  case parseQueueName ("bench_" <> prefix) of
    Left err -> error $ "Invalid queue name: " <> show err
    Right qName -> qName

-- | Create a unique queue name with a random suffix.
uniqueQueueName :: Text -> IO QueueName
uniqueQueueName prefix = do
  suffix <- randomSuffix
  case parseQueueName ("bench_" <> prefix <> "_" <> suffix) of
    Left err -> error $ "Invalid queue name: " <> show err
    Right qName -> pure qName
  where
    randomSuffix :: IO Text
    randomSuffix = do
      uuid <- randomIO :: IO Word64
      pure $ Text.pack $ take 8 $ showHex uuid ""

-- | Generate a single payload of the specified size.
generatePayload :: PayloadSize -> Int -> Value
generatePayload size idx =
  object
    [ "id" .= idx,
      "size" .= show size,
      "data" .= Text.replicate padLength "x"
    ]
  where
    -- Approximate padding to reach target size
    -- JSON overhead is roughly 50 bytes for the structure
    targetBytes = payloadBytes size
    padLength = max 0 (targetBytes - 50)

-- | Generate a list of payloads with incrementing IDs.
generatePayloads :: Int -> PayloadSize -> [Value]
generatePayloads count size = [generatePayload size i | i <- [1 .. count]]

-- | Split a list into chunks of a given size.
chunksOf :: Int -> [a] -> [[a]]
chunksOf _ [] = []
chunksOf n xs =
  let (chunk, rest) = splitAt n xs
   in chunk : chunksOf n rest
