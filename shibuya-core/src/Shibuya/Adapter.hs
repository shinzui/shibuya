-- | Adapter API - library-author facing.
-- Adapters bridge external systems to the framework.
-- Adapter owns queue semantics; runner never touches offsets directly.
module Shibuya.Adapter
  ( Adapter (..),

    -- * Telemetry options
    AdapterTelemetry (traceCorrelation),
    defaultAdapterTelemetry,
    TraceCorrelation (..),
  )
where

import Data.Text (Text)
import Effectful (Eff)
import Shibuya.Core.Ingested (Ingested)
import Shibuya.Telemetry.Correlation (AdapterTelemetry (traceCorrelation), TraceCorrelation (..), defaultAdapterTelemetry)
import Streamly.Data.Stream (Stream)

-- | Queue adapter interface.
-- Provides a stream of ingested messages and shutdown capability.
data Adapter es msg = Adapter
  { -- | Name for logging/observability
    adapterName :: !Text,
    -- | Stream of leased messages
    source :: Stream (Eff es) (Ingested es msg),
    -- | Stop polling, release resources
    shutdown :: Eff es (),
    -- | Telemetry options for this adapter's processing spans, such as the
    -- 'TraceCorrelation' policy. Start from 'defaultAdapterTelemetry' and
    -- expose the value in the adapter's own configuration so users can
    -- override it. Read once per processor.
    telemetry :: !AdapterTelemetry
  }
