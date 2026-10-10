-- | Pure, strictly bounded outbound admission. Constructors for frames and queues
-- are private so cached sizes cannot diverge from the retained strict payloads.
module Shibuya.Metrics.Outbound
  ( Retention (..),
    Frame,
    frame,
    payload,
    generation,
    retention,
    Limits (..),
    OutboundQueue,
    empty,
    queuedFrames,
    queuedBytes,
    entries,
    Outcome (..),
    enqueue,
    pop,
    discardUpdates,
  )
where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Foldable (toList)
import Data.Sequence (Seq, ViewL (..), (><))
import Data.Sequence qualified as Seq

-- | Pongs are expendable but their loss does not invalidate the metrics ledger.
data Retention = Required | Update | Ephemeral
  deriving stock (Eq, Show)

data Frame = Frame !Int !Retention !ByteString
  deriving stock (Eq, Show)

frame :: Int -> Retention -> ByteString -> Frame
frame = Frame

payload :: Frame -> ByteString
payload (Frame _ _ bytes) = bytes

generation :: Frame -> Int
generation (Frame value _ _) = value

retention :: Frame -> Retention
retention (Frame _ value _) = value

data Limits = Limits {maxFrames :: !Int, maxBytes :: !Int}
  deriving stock (Eq, Show)

data OutboundQueue = Queue !(Seq Frame) !Int
  deriving stock (Eq, Show)

empty :: OutboundQueue
empty = Queue Seq.empty 0

queuedFrames :: OutboundQueue -> Int
queuedFrames (Queue values _) = Seq.length values

queuedBytes :: OutboundQueue -> Int
queuedBytes (Queue _ bytes) = bytes

entries :: OutboundQueue -> [Frame]
entries (Queue values _) = toList values

data Outcome = Enqueued | DroppedUpdates | MustClose
  deriving stock (Eq, Show)

-- | Admit the entire batch atomically or none of it. Evict expendable frames
-- oldest-first; never evict a required frame. Saturation by required frames
-- closes the connection instead of exceeding either limit. A rejected update
-- marks the comparison ledger as needing a full resynchronization.
enqueue :: Limits -> [Frame] -> OutboundQueue -> (Outcome, OutboundQueue)
enqueue limits batch original = go False original
  where
    incoming = Seq.fromList batch
    bytes = sum $ map (toInteger . BS.length . payload) batch
    fits q =
      toInteger (queuedFrames q) + toInteger (length batch) <= toInteger limits.maxFrames
        && toInteger (queuedBytes q) + bytes <= toInteger limits.maxBytes
    go dropped q@(Queue values size)
      | fits q = (if dropped then DroppedUpdates else Enqueued, Queue (values >< incoming) (size + fromInteger bytes))
      | otherwise = case Seq.findIndexL ((/= Required) . retention) values of
          Just index ->
            let victim = Seq.index values index
                next = Queue (Seq.deleteAt index values) (size - BS.length (payload victim))
             in go (dropped || retention victim == Update) next
          Nothing
            | any ((== Required) . retention) batch -> (MustClose, original)
            | otherwise -> (if dropped || any ((== Update) . retention) batch then DroppedUpdates else Enqueued, q)

pop :: OutboundQueue -> Maybe (Frame, OutboundQueue)
pop (Queue values size) = case Seq.viewl values of
  EmptyL -> Nothing
  value :< rest -> Just (value, Queue rest (size - BS.length (payload value)))

-- | Remove only unsent metrics updates. Required frames keep their order.
discardUpdates :: OutboundQueue -> OutboundQueue
discardUpdates (Queue values _) =
  let kept = Seq.filter ((/= Update) . retention) values
   in Queue kept (sum $ fmap (BS.length . payload) kept)
