# Rejected and superseded performance captures

None of the JSON files in this directory is release evidence. They are retained to make the
candidate-selection history auditable.

The `diagnostic-*` and `extension-h6f5-*` files measured intermediate masking boundaries while
the keyed scheduler performance defect was being isolated. The unprefixed `baseline-n1`,
`candidate-n1`, and `verdict-n1` files used a superseded harness. The unprefixed `initial-40-*`
and `extension-*` files used a worktree whose production source contents matched the final
candidate but whose change was not yet represented by a clean candidate checkout.

Release evidence is limited to the `clean-*` source datasets, the assembled `final-*` datasets,
the two passing `final-verdict-*` files, and `../provenance.json`. The candidate side of those
runs was built from clean committed production source
`e28a95893a534a15302529850eea54f6e0682de0`; only the separately identified benchmark harness
was overlaid from `6f5f5e237e6f5839b9e4ba2fe1e387e0c6b0bec2`.
