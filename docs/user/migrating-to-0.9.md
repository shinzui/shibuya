# Migrating to Shibuya 0.9

Shibuya 0.9 adds application-defined permanent failures to the public
dead-letter vocabulary. Applications can now distinguish a valid message that
application policy rejects from a poison message, invalid payload, or exhausted
retry budget. The release is source-breaking because `DeadLetterReason` is an
exported datatype and gains the `ApplicationFailure` constructor.

## Version bounds

Under the Haskell Package Versioning Policy, adding a constructor to an exported
datatype requires an `A.B` version increase. The successor to 0.8.0.1 is
0.9.0.0. A downstream bound such as `shibuya-core ^>=0.8.0.1` intentionally
excludes 0.9; review exhaustive matches and then update the bound to
`shibuya-core ^>=0.9.0.0`.

## Application handlers

Validate each application-owned code once during startup and reuse the opaque
`DeadLetterCode` in handlers:

```haskell
case mkDeadLetterCode "keiro.router.selection.recipient_overflow" of
  Left err -> fail (unpack err)
  Right recipientOverflowCode ->
    startProcessor (mkRouterHandler recipientOverflowCode)

mkRouterHandler :: DeadLetterCode -> Handler es RouterMessage
mkRouterHandler recipientOverflowCode _message =
  pure $
    AckDeadLetter $
      ApplicationFailure
        recipientOverflowCode
        "selected 101 recipients; configured limit is 100"
```

Codes contain at least two dot-separated lowercase ASCII segments, each
matching `[a-z][a-z0-9_]*`, and are at most 128 characters. The `shibuya` first
segment is reserved. Codes must be stable and low-cardinality; details are
transported verbatim and must not contain secrets or unbounded backend output.

## Exhaustive adapter matches

An exhaustive match written for 0.8 no longer covers every reason:

```haskell
case reason of
  PoisonPill detail -> ...
  InvalidPayload detail -> ...
  MaxRetriesExceeded -> ...
```

Prefer the new total projections instead of adding another constructor match:

```haskell
let code = deadLetterCodeText (deadLetterReasonCode reason)
    detail = deadLetterReasonDetail reason
    rendered = renderDeadLetterReason reason
```

`code` is stable machine-facing text, `detail` is optional human context, and
`rendered` is the canonical compatibility representation. Existing encodings
remain byte-for-byte unchanged:

```text
PoisonPill "x"       -> poison_pill: x
InvalidPayload "x"   -> invalid_payload: x
MaxRetriesExceeded   -> max_retries_exceeded
```

`ApplicationFailure code detail` renders as `<code>: <detail>`. `Show` output is
for debugging and is not a wire format.

Adapters with structured storage should persist code and detail separately.
Adapters limited to one legacy text field can store `renderDeadLetterReason`.
Whether an existing schema backfills, adds columns, or retains both structured
and legacy fields belongs to that adapter's migration policy; Shibuya does not
prescribe a JSON envelope or database migration.

## Observability

Single-message processing spans now attach the stable code as
`shibuya.dead_letter.reason.code` and put the canonical rendered value in the
span's `Error` status description. Detail is not duplicated into an attribute,
and neither code nor detail becomes a Shibuya metric label. Batch finalization
preserves each message's complete reason but does not invent one aggregate code
for a batch that may contain several different failures.
