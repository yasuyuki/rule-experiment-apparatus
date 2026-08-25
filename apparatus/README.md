# Apparatus core

The core reads a private environment descriptor and ignored cycle declarations. It has two
executors only: `{kind:"wsl", distro, user}` uses `wsl.exe ... bash -lc`; `{kind:"local-posix"}`
uses `bash -lc` directly.

The environment names `variantSourceRoot`, `stableRules: {root, branch}`, and each active
subject's authenticated `configTemplate`. A declaration contains immutable comparison inputs:
`base`, `subjects`, content hashes, and arms. Measurement cycles have exactly one control and one
treatment arm; estimation cycles have one arm.

Promotable variants live at `experiments/<experiment>/variants/<variant>/source/` and contain the
complete managed source: `rules/`, `placement.json`, and `bin/rules.py`. `variantTree` is the Git
tree of that `source/` directory. Snapshot manifests are not accepted.

`handoff` clones templates into `configs/<arm>/<subject>/`, strips descriptor `credentialPaths` and
the transcript root from the clone, symlinks credentials in from the optional `credentialStore`,
overlays the marker contract, computes `configIdentity` as the content hash of the surviving plain
files (credentials and the marker are excluded, since they are expected to differ per arm or per
run), and writes a separate handoff record. `judge` discovers every declared
subject session, rejects unclassified or out-of-arm sessions and commits outside session spans,
writes one execution manifest, then passes it to every arm with `--execution`.

Promotion copies only the managed subset through a temporary worktree, runs renderer smoke and
stable tests, records `prepared`, then fast-forwards the declared stable branch. Rollback only
reverts the latest promotion when stable HEAD is unchanged. Neither operation pushes, tags,
releases, or distributes runtime files.

JSON Schemas in [`schemas/`](schemas/environment.schema.json) are authoritative. The end-to-end
fixture is [`tests/test_cycle.py`](tests/test_cycle.py); CI also runs the same materialization
contract from a Windows controller through WSL.
