---
okf_version: "0.2"
---

# Files

- [profile.dhall](profile.dhall)

# Friction Entry

- [getAppMetrics returns no processors after waitApp](1-getappmetrics-returns-no-processors-after-waitapp.md) - Shibuya.App.getAppMetrics reads the master's live registry, which drops finished processors, so a caller cannot read final counts through the public API after waitApp.
