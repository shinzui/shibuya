---
okf_version: "0.2"
---

# Files

- [profile.dhall](profile.dhall)

# Review

- [Master lifecycle review confirms an abandoned linked mailbox can crash healthy workers](REV-1-master-lifecycle-gc-regression.md) - Examination of the master module confirms the pre-fix GC crash, traces its introduction to 0.8, and identifies the limits of existing lifecycle coverage.
- [Application lifecycle audit finds shutdown cleanup and duplicate identity defects](REV-2-application-lifecycle-audit.md) - Source review of App identifies lost processor handles and missing exception-safe shutdown cleanup; runtime reproduction remains pending.

