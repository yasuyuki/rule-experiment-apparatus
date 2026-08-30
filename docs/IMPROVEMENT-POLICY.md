# Improvement Policy

This document has the same standing as `CONSTITUTION.md`. Together they are the constitutional documents of this apparatus: `CONSTITUTION.md` defines what the system is, and this document defines how to reduce and improve it without losing that purpose.

Neither constitutional document is a candidate for the deletion this document orders. Changing either is a deliberate change of purpose or of improvement order, not a simplification step.

## Purpose

The system exists to:

1. evaluate changes to agent rules through controlled experiments;
2. adopt a validated result as the new stable baseline without changing what was validated.

The second purpose is not generic release management.

## Core boundary

A component belongs in the apparatus core only if it is directly required to:

- perform or judge an experiment;
- adopt a validated result as the stable baseline; or
- enforce a Constitution invariant required by those operations.

Something may be required to operate the wider system without belonging in the apparatus core.

## Improvement rule

For every existing or proposed element, prefer, in this order:

1. delete;
2. separate from the apparatus core;
3. simplify;
4. keep;
5. add.

Existing code, documents, abstractions, compatibility, and historical effort are not reasons to keep something.

If an element cannot be justified by a current system purpose and current operation, delete or separate it.

Promotion must remain limited to preserving the identity, integrity, and provenance of the validated result while establishing it as the new stable baseline.
