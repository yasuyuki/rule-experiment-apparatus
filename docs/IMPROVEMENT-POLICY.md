# Improvement Policy

This document has the same standing as `CONSTITUTION.md`. Together they are the constitutional documents of this apparatus: `CONSTITUTION.md` defines the system's purpose, boundaries, invariants, and required quality of normal operation, and this document defines how to reduce and improve it without losing them.

Neither constitutional document is a candidate for the deletion this document orders. Changing either is a deliberate change of purpose, boundaries, required quality, or improvement order, not a simplification step.

## Purpose

The system exists to:

1. evaluate changes to agent rules through controlled experiments;
2. adopt a validated result as the new stable baseline without changing what was validated.

The second purpose is not generic release management. Transparent normal operation is a required quality of fulfilling these purposes, not an additional product purpose.

## Core boundary

A component belongs in the apparatus core only if it is directly required to:

- perform or judge an experiment;
- adopt a validated result as the stable baseline;
- enforce a Constitution invariant required by those operations; or
- make those operations transparently usable within the existing responsibility boundary.

Something may be required to operate the wider system without belonging in the apparatus core. Usability does not move responsibilities excluded by the Constitution into the core; improve the layer that owns them.

## Improvement rule

For every existing or proposed element, prefer, in this order:

1. delete;
2. separate from the apparatus core;
3. simplify;
4. keep;
5. add.

Existing code, documents, abstractions, compatibility, and historical effort are not reasons to keep something.

If an element cannot be justified by a current system purpose or constitutional requirement in a current operation, delete or separate it.

Apply the improvement order to end-to-end work, including work imposed on humans and controller agents, not only to repository size. Removing an entry point while requiring users to reconstruct its behavior is not simplification. Prefer existing entry points, declarations, and records before adding a new layer or another source of truth.

Promotion must remain limited to preserving the identity, integrity, and provenance of the validated result while establishing it as the new stable baseline.

## Normal-path acceptance

When changing a normal entry point or the rules governing it, check the affected path with representative use after initial setup. Humans should not need to reconstruct environment-specific commands; controller agents should not need to rebuild routine state from multiple histories or repeatedly explain the same mechanical checks. Keep task-relevant specifications and evidence available on demand.

Preserve required checks at the operations they protect, including revalidation after relevant state changes. Unrelated diagnostics must not become blanket prerequisites. Keep first-time setup, migration inventories, and incident repair distinct from routine use.

Use existing tests and evidence where possible. These are acceptance criteria for system changes, not new per-task gates, declarations, reports, or review records. Do not modify the Subject workload or evaluated instruction bytes to demonstrate compliance. Assess reduced repeated work, not merely hidden output or work transferred to another agent.
