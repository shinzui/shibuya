-- | Temporary PostgreSQL setup for integration tests.
--
-- Uses tmp-postgres to create an ephemeral PostgreSQL instance
-- and pgmq-migration to install the pgmq schema.
module TmpPostgres
  ( -- * Test Execution
    withPgmqDb,
    withTestFixture,

    -- * Test Fixture
    TestFixture (..),

    -- * Utilities
    runPgmqSession,
  )
where

import Control.Exception (bracket)
import Data.ByteString (ByteString)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Data.Time (secondsToDiffTime)
import Data.Word (Word64)
import Database.Postgres.Temp
  ( StartError,
    toConnectionString,
    with,
  )
import Effectful (Eff, IOE, runEff, (:>))
import Hasql.Connection qualified as Connection
import Hasql.Connection.Setting qualified as Setting
import Hasql.Connection.Setting.Connection qualified as Connection.Setting
import Hasql.Pool qualified as Pool
import Hasql.Pool.Config qualified as PoolConfig
import Hasql.Session (Session)
import Hasql.Session qualified as Session
import Numeric (showHex)
import Pgmq.Effectful (Pgmq, runPgmq)
import Pgmq.Hasql.Sessions qualified as Pgmq
import Pgmq.Migration qualified as Migration
import Pgmq.Types (QueueName, parseQueueName)
import System.Random (randomIO)

-- | Test fixture containing pool and queue names for a test
data TestFixture = TestFixture
  { pool :: !Pool.Pool,
    queueName :: !QueueName,
    dlqName :: !QueueName
  }

-- | Run an action with a temporary PostgreSQL database with pgmq schema installed.
--
-- This creates an ephemeral PostgreSQL instance, installs the pgmq schema,
-- and then runs the provided action with a connection pool.
withPgmqDb :: (Pool.Pool -> IO a) -> IO (Either StartError a)
withPgmqDb action = with $ \db -> do
  let connStr = toConnectionString db

  -- Install pgmq schema
  installPgmqSchema connStr

  -- Create and use connection pool
  bracket
    (createPool connStr)
    Pool.release
    action

-- | Run an action with a test fixture (pool + unique queue names).
--
-- Creates unique queue names for each test to avoid collisions,
-- creates the queues, runs the test, then cleans up.
withTestFixture :: Pool.Pool -> (TestFixture -> IO a) -> IO a
withTestFixture pool action = do
  -- Generate unique queue names
  suffix <- randomSuffix
  let Right qName = parseQueueName $ "test_" <> suffix
      Right dlqName = parseQueueName $ "test_dlq_" <> suffix

  -- Create queues
  runPgmqSession pool $ do
    Pgmq.createQueue qName
    Pgmq.createQueue dlqName

  -- Run test
  result <- action TestFixture {pool, queueName = qName, dlqName}

  -- Cleanup queues
  runPgmqSession pool $ do
    Pgmq.dropQueue qName
    Pgmq.dropQueue dlqName

  pure result
  where
    randomSuffix :: IO Text
    randomSuffix = do
      uuid <- randomIO :: IO Word64
      pure $ Text.pack $ showHex uuid ""

-- | Run a hasql Session against the pool, throwing on error.
runPgmqSession :: Pool.Pool -> Session a -> IO a
runPgmqSession pool session = do
  result <- Pool.use pool session
  case result of
    Left err -> error $ "Session error: " <> show err
    Right a -> pure a

-- | Install pgmq schema into a PostgreSQL database.
installPgmqSchema :: ByteString -> IO ()
installPgmqSchema connStr = do
  let connSettings = [Setting.connection (Connection.Setting.string (TE.decodeUtf8 connStr))]
  connResult <- Connection.acquire connSettings
  case connResult of
    Left err -> error $ "Failed to connect for migration: " <> show err
    Right conn -> do
      result <- Session.run Migration.migrate conn
      Connection.release conn
      case result of
        Left sessionErr -> error $ "Migration session error: " <> show sessionErr
        Right (Left migrationErr) -> error $ "Migration error: " <> show migrationErr
        Right (Right ()) -> pure ()

-- | Create a connection pool from a connection string.
createPool :: ByteString -> IO Pool.Pool
createPool connStr = do
  let connSettings = [Setting.connection (Connection.Setting.string (TE.decodeUtf8 connStr))]
      poolConfig =
        PoolConfig.settings
          [ PoolConfig.size 10,
            PoolConfig.acquisitionTimeout (secondsToDiffTime 10),
            PoolConfig.agingTimeout (secondsToDiffTime 3600),
            PoolConfig.idlenessTimeout (secondsToDiffTime 60),
            PoolConfig.staticConnectionSettings connSettings
          ]
  Pool.acquire poolConfig
