-- | Compatibility re-export for the pre-1.0 public API.
-- Prefer importing "Shibuya" in new code.
module Shibuya.Core {-# DEPRECATED "Use Shibuya instead." #-} (module Shibuya) where

import Shibuya
