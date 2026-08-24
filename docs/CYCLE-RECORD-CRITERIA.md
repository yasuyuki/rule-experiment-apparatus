# Cycle record contract

JSON Schema is authoritative for environment, cycle declaration, subject, handoff, execution,
cycle review, frozen input, promotion, and rollback records. Cross-field checks that JSON Schema
cannot express live in `cycle.py` and are exercised by `apparatus/tests/test_cycle.py`.

New reviews use `schemaVersion: 3`; declarations never contain subject versions, config identities,
launch commands, or session paths. Those runtime facts live in handoff and execution records.
Existing private records using older schemas are historical and are not read through a compatibility
branch.
