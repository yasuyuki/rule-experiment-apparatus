# Rule experiment protocol

The controller owns declarations, variants, measurement definitions, records, promotion, and
rollback. A subject receives only the rendered variant and verbatim `workload.md`. Runtime rule
distribution beyond the experiment is outside the core.

## Comparison contract

- `base` is the workload repository commit shared by every arm.
- `baseline` is the verified stable rule-source tree.
- `variant` is a candidate rule-source tree.
- A measurement cycle changes only the variant and has one control plus one treatment arm.
- An estimation cycle has one arm and cannot be promoted.
- Every selected subject uses an isolated `configs/<arm>/<subject>/` copied from the same private
  authenticated template. Tool version and starting config identity are recorded, not written into
  the declaration.
- The copy excludes the subject descriptor's `credentialPaths` and the transcript root; credentials
  are instead symlinked in from a single credential store outside the release, so a rotated
  credential never needs to be recopied across arms or cycles. Starting config identity is the
  content hash of the copied plain files only: it excludes credentials and the per-arm marker, so
  it is expected to be identical across arms and stable across credential rotation.

## Variant and placement contract

Every promotable variant has `variants/<id>/source/{rules,placement.json,bin/rules.py}`. The core
checks the declared `variantTree`, rejects dirty or drifting source, renders outside the arm, and
copies only outputs whose subject descriptor placement is `proven:true`. Unused always-on paths
declared by `mustStayEmpty` must be absent.

## Execution contract

The declaration pins [`EXECUTION-UNIT.md`](EXECUTION-UNIT.md). At judge time, the core records all
declared subjects, their versions and starting config identities, every participating session and
span, and all arm commits in an execution manifest. Unclassified sessions, sessions belonging to a
different arm, missing declared subjects, and commits outside all owning session spans reject the
cycle. There is no subject or session count limit. Experiment-specific aggregation belongs to the
judge receiving `--execution <manifest.json>`.

## Promotion contract

Promotion revalidates the review hash, declaration, treatment tree, effect, regression, and
unknown results. No effect, any regression, any unknown, source drift, or dirty stable state writes
`not-promoted` without touching stable. A valid promotion synchronizes only the managed subset in a
temporary worktree, verifies path+bytes digest, runs renderer smoke and stable tests, writes a
`prepared` record atomically, and fast-forwards stable before recording `promoted`.

Rollback applies only to the latest promotion when stable HEAD still equals its recorded commit.
It reverts that commit in a temporary worktree, verifies the prior managed digest, tests it, and
fast-forwards stable. Push, tag, release, and runtime distribution are never performed.

## Estimation

`freeze`, `estimate`, and `calibrate` keep estimation separate from measurement. Frozen inputs are
content-addressed; estimation records cannot support promotion; an estimator must have calibration
with no mismatch before use.
