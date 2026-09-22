# Rejected in-memory ledger diagnostic

This directory preserves the first 1,800-second Kafka rc2 soak as diagnostic
evidence. The run used Kafka adapter source
`6d0b15dee7d6fdc5a0a97eef799033f0b3c185b2` and reconciled all 3,593 delivery
identities, but the fixture retained produced and processed identities in
in-process `Set`s while collecting heap samples. The run passed the numeric
budget with a 13,354.8-byte/minute post-restart slope, but it is deliberately
ineligible for the final release verdict because the ledger could distort the
measurement and because the final adapter source SHA changed.

The retained candidate uses
`mori://shinzui/shibuya-kafka-adapter` source
`adadf9f` or later, which streams identities to external files during the run
and reconciles them only after the final heap sample. No file in this directory
is referenced by the rc2 candidate manifest.
