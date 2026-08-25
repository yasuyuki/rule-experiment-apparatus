# Operator guide

Create an ignored declaration at `apparatus/cycles/<cycle>.json`, pin all hashes and the exact
`variants/<id>/source/` Git trees, then run:

```console
python3 apparatus/cycle.py --environment <environment.json> materialize --cycle <cycle>
python3 apparatus/cycle.py --environment <environment.json> handoff --cycle <cycle>
```

Run each printed subject launch command and give each subject the same verbatim `workload.md`. For
a subject whose credential rotates (see `subjects.<id>.credentialStore` in the setup guide), launch
its arms one at a time rather than concurrently, since they share the same credential file through
a symlink to the store. After all sessions finish and arm changes are committed:

```console
python3 apparatus/cycle.py --environment <environment.json> transcripts --cycle <cycle>
python3 apparatus/cycle.py --environment <environment.json> judge --cycle <cycle>
python3 apparatus/cycle.py --environment <environment.json> promote --cycle <cycle>
```

Use `rollback --cycle <cycle>` only for the latest promotion. Re-measurement uses a new cycle id and
the same immutable inputs. Improved reruns change only the variant tree. Never edit a failed cycle
to make it comparable.
