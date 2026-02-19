-- | Database pool setup and queue creation for the PGMQ example.
module Example.Database
  ( -- * Pool Management
    withDatabasePool,
    createPool,

    -- * Queue Setup
    createQueues,
    installSchema,

    -- * Queue Names
    ordersQueueName,
    paymentsQueueName,
    notificationsQueueName,
    dlqOrdersQueueName,
    dlqPaymentsQueueName,
  )
where

import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BS
import Data.Text qualified as Text
import Hasql.Connection.Settings qualified as Settings
import Hasql.Pool qualified as Pool
import Hasql.Pool.Config qualified as PoolConfig
import Pgmq.Hasql.Sessions qualified as Pgmq
import Pgmq.Migration qualified as Migration
import Pgmq.Types (QueueName, parseQueueName)

-- | Queue name for orders.
ordersQueueName :: QueueName
ordersQueueName = case parseQueueName "orders" of
  Left err -> error $ "Invalid queue name: " <> show err
  Right q -> q

-- | Queue name for payments.
paymentsQueueName :: QueueName
paymentsQueueName = case parseQueueName "payments" of
  Left err -> error $ "Invalid queue name: " <> show err
  Right q -> q

-- | Queue name for notifications.
notificationsQueueName :: QueueName
notificationsQueueName = case parseQueueName "notifications" of
  Left err -> error $ "Invalid queue name: " <> show err
  Right q -> q

-- | Dead-letter queue for orders.
dlqOrdersQueueName :: QueueName
dlqOrdersQueueName = case parseQueueName "dlq_orders" of
  Left err -> error $ "Invalid queue name: " <> show err
  Right q -> q

-- | Dead-letter queue for payments.
dlqPaymentsQueueName :: QueueName
dlqPaymentsQueueName = case parseQueueName "dlq_payments" of
  Left err -> error $ "Invalid queue name: " <> show err
  Right q -> q

-- | Create a connection pool.
createPool :: ByteString -> IO Pool.Pool
createPool connStr = do
  let connSettings = Settings.connectionString (Text.pack (BS.unpack connStr))
      poolConfig =
        PoolConfig.settings
          [ PoolConfig.size 20,
            PoolConfig.staticConnectionSettings connSettings
          ]
  Pool.acquire poolConfig

-- | Bracket pattern for pool lifecycle.
withDatabasePool :: ByteString -> (Pool.Pool -> IO a) -> IO a
withDatabasePool connStr action = do
  pool <- createPool connStr
  result <- action pool
  Pool.release pool
  pure result

-- | Install PGMQ schema and create all queues.
createQueues :: Pool.Pool -> IO ()
createQueues pool = do
  installSchema pool
  createQueue pool ordersQueueName
  createQueue pool paymentsQueueName
  createQueue pool notificationsQueueName
  createQueue pool dlqOrdersQueueName
  createQueue pool dlqPaymentsQueueName

-- | Install PGMQ schema.
installSchema :: Pool.Pool -> IO ()
installSchema pool = do
  result <- Pool.use pool Migration.migrate
  case result of
    Left err -> error $ "Migration session error: " <> show err
    Right (Left err) -> error $ "Migration error: " <> show err
    Right (Right ()) -> pure ()

-- | Create a single queue (no-op if exists).
createQueue :: Pool.Pool -> QueueName -> IO ()
createQueue pool qName = do
  result <- Pool.use pool $ Pgmq.createQueue qName
  case result of
    Left err -> error $ "Create queue error: " <> show err
    Right _ -> pure ()
