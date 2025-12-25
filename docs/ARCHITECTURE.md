1. Core API (framework-wide primitives)

These types exist everywhere and should be extremely stable.


```haskell
module Framework.Core where

import Data.Text (Text)
import Data.Time (UTCTime, NominalDiffTime)

-- Stable identity for idempotency & observability
newtype MessageId = MessageId Text
  deriving (Eq, Ord, Show)

-- Optional cursor / offset / global position
data Cursor
  = CursorInt  Int
  | CursorText Text
  deriving (Eq, Ord, Show)

-- Normalized message envelope (Broadway.Message equivalent)
data Envelope msg = Envelope
  { envId         :: MessageId
  , envCursor     :: Maybe Cursor
  , envPartition  :: Maybe Text
  , envEnqueuedAt :: Maybe UTCTime
  , envPayload    :: msg
  }
```


Why this is minimal

This is exactly Broadway’s Message concept

No behavior, no effects, no policy

Just identity + payload + metadata

2. Ack semantics (explicit, semantic)

Handlers decide meaning, not mechanics.

```haskell
module Framework.Ack where

import Data.Text (Text)
import Data.Time (NominalDiffTime)

newtype RetryDelay =
  RetryDelay NominalDiffTime
  deriving (Eq, Show)

data DeadLetterReason
  = PoisonPill Text
  | InvalidPayload Text
  | MaxRetriesExceeded
  deriving (Eq, Show)

data HaltReason
  = HaltOrderedStream Text
  | HaltFatal Text
  deriving (Eq, Show)

-- Handler outcome (semantic)
data AckDecision
  = AckOk
  | AckRetry RetryDelay
  | AckDeadLetter DeadLetterReason
  | AckHalt HaltReason
  deriving (Eq, Show)
```


Why this exists

Broadway spreads this across producer + acknowledger

You must make it explicit to support halt-on-error

3. Lease (optional, adapter-specific)

Lease exists only to model temporary ownership (SQS, DB locks, etc).


```haskell
module Framework.Lease where

import Data.Time (NominalDiffTime)

-- Optional capability for sources with visibility / ownership
data Lease m = Lease
  { leaseId     :: Text
  , leaseExtend :: NominalDiffTime -> m ()
  }
```


Important

Kafka adapters won’t use this

MessageDB adapters probably won’t

SQS / Redis / DB queues will

This stays optional.

4. AckHandle (mechanical, effectful)

This is the Broadway.Acknowledger equivalent, but typed.

```haskell
module Framework.AckHandle where

import Framework.Ack

newtype AckHandle m =
  AckHandle
    { finalize :: AckDecision -> m ()
    }
```


Invariant

Must be called exactly once

Adapter enforces idempotency

5. Ingested message (what handlers receive)


```
module Framework.Ingested where

import Framework.Core
import Framework.Lease
import Framework.AckHandle

-- What flows through the runner into handlers
data Ingested m msg = Ingested
  { envelope :: Envelope msg
  , ack      :: AckHandle m
  , lease    :: Maybe (Lease m)
  }
```


Why this is correct

Broadway.Message + Acknowledger + optional lease

No extra conceptual layer

Exactly one thing flows through the system

6. Handler API (client-facing)

This is all application authors need to know.

```haskell

module Framework.Handler where

import Framework.Ingested
import Framework.Ack
import Effectful (Eff)

type Handler es msg =
  Ingested (Eff es) msg -> Eff es AckDecision
```


Key property

Handlers cannot ack directly

Handlers cannot influence concurrency

Handlers express intent only

7. Adapter API (library-author facing)

Adapters bridge external systems → framework.


```haskell

module Framework.Adapter where

import Framework.Ingested
import Effectful (Eff)
import Streamly.Prelude (Stream)

data Adapter es msg = Adapter
  { adapterName :: Text

  -- Stream of leased messages
  , source :: Stream (Eff es) (Ingested (Eff es) msg)

  -- Stop polling, release resources
  , shutdown :: Eff es ()
  }
```


Notes

Adapter owns queue semantics

AckHandle inside Ingested performs commit / retry / DLQ

Runner never touches offsets directly

8. Ordering & concurrency (runner policy)
module Framework.Runtime.Policy where

```haskell
data Ordering
  = StrictInOrder        -- event-sourced subscriptions
  | PartitionedInOrder  -- Kafka-style
  | Unordered
  deriving (Eq, Show)


data Concurrency
  = Serial
  | Aheadly  Int
  | Asyncly  Int
  deriving (Eq, Show)
```


Invariant (enforced by runner)

StrictInOrder ⇒ Serial

Violations are configuration errors

9. Runner configuration (client-facing)

```haskell
module Framework.Runner where

import Framework.Adapter
import Framework.Handler
import Framework.Runtime.Policy

data RunnerConfig es msg = RunnerConfig
  { adapter     :: Adapter es msg
  , handler     :: Handler es msg
  , ordering    :: Ordering
  , concurrency :: Concurrency
  , inboxSize   :: Int
  }
```


This is the API users configure

Which adapter

Which handler

How much concurrency

What ordering guarantees

10. Client API (top-level entry)


```haskell
module Framework.App where

import Framework.Runner
import Effectful (Eff)

runApp
  :: RunnerConfig es msg
  -> Eff es ()
runApp = undefined
```


This is where:

Streamly wiring happens

Actor supervision happens

Ack lifecycle is enforced

Halt semantics are applied
