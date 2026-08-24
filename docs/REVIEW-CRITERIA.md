# Review criteria

A current measurement review has `schemaVersion: 3`, one control arm, one treatment arm, and a hash
of the execution manifest. Criterion numbers are complete and unique per arm; comparable criterion
text is byte-identical; judge and workload hashes match across arms.

Promotion requires at least one comparable treatment improvement, no comparable regression, no
`unknown`, and every incomparable criterion to be `met`. The review's variant trees must match the
declaration and current private source. Estimation records are never review evidence for promotion.
