# Shibuya 0.9.0.3 pre-remediation performance calibration

These artifacts freeze the released production behavior before the lifecycle remediation
children change hot paths. `pre-remediation-n1.json` and `pre-remediation-n4.json` each contain
ten fresh-process samples for all 16 workload scenarios after one discarded warmup per
scenario. Every sample completed and acknowledged its expected work.

The measured production code is commit
`7512b5c692af1c005392e4445cfa26a9be41f9ea`, upstream tag `v0.9.0.3`. A diff of
`shibuya-core/` and `shibuya-metrics/` against that tag was empty. The workload executable is
from harness commit `886f5910a5f1a47b5465dce9380bce831467fe2b`; the Cabal solver-plan SHA-256 is
`47f9680ce1ad6be1220c85dfc30c850d097e20d4e97bef9d4394cbce30ec4dc4`.
Both captures used GHC 9.12.4 with optimization `O2`, RTS statistics, a 32 MiB allocation
area, and the same `MacBookPro18,2` running Darwin arm64. One used `-N1`; the other used
`-N4`.

These files have `pairedComparisonEligible: false`. They calibrate budgets and prove that a
baseline existed before remediation, but they were necessarily collected before a candidate
existed and therefore are not alternating paired evidence. EP-45 pass two must rebuild this
exact baseline identity and alternate its processes with the candidate. The comparator rejects
these calibration files if they are supplied as a final baseline or candidate.
