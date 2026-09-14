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

## User waiting and resource limits

Assume that the user will not wait and is not willing to wait. Avoidable waiting, monitoring, and repeated intervention are usability defects even when an operation eventually succeeds. Do not require the user to restate this assumption or set a time budget for every task. Keeping initial setup and repair separate from routine use does not exempt them from reducing avoidable waiting.

Start from the ideal path with no avoidable user waiting. Apply the improvement order to remove unnecessary work and dependencies before accelerating retained steps. Within required quality, safety, approvals, and applicable cost and resource limits, prioritize reducing both elapsed time from the user's request to a usable result and the time during which the user is blocked from useful work. Speed is not an unlimited spending mandate. Early acknowledgement or returning control alone is not acceptance.

For irreducibly long operations, minimize necessary blocking and allow genuinely independent work to proceed. Use existing execution and result-retrieval paths so the user need not poll, reconstruct state, or return to advance mechanical steps. Do not claim that submission is completion, or treat deferred work still blocking the requested result as eliminated waiting.

Choose operation-appropriate latency targets when improving a path, rather than accepting its current duration as necessary. Apply established budgets and resource allowances alongside these targets. Judge the path with representative observations and reusable evidence, making unavoidable waits and any timing exclusions explicit. Numeric limits belong to the affected operation or approved operating profile, not to a universal threshold here.

Additional spend or scarce usage is justified only by a meaningful, proportionate reduction in time to a usable result or user burden, and must remain within authorized limits. Budget headroom is not a target to consume. Evaluate total resources across preparation, management, handoffs, implementation, review, retries, validation, and result delivery, not only one model's unit price or one stage's duration. Include one-time improvement effort and realistic recurring costs where they affect the decision. Distinguish reference cost estimates, actual charges, and consumption of limited usage allowances; missing measurements are not zero cost.

Reuse established budgets, approved operating profiles, and available evidence. Do not infer authorization for materially higher spending, greater usage, premium tiers, extra agents, or speculative duplicate runs merely from an instruction to be fast. Where a material increase is not covered by existing authorization, use an authorized lower-resource path if it meets the requirements, or surface the specific trade-off before incurring the increase. Do not require a new budget question for routine actions already within authorization. If the latency target cannot be met within the applicable limits, report the unmet target rather than silently exceeding a limit or declaring acceptance.

Preserve required checks and approvals, constitutional invariants, result validity, and responsibility boundaries. Speed and deferral must not bypass protection or relabel pending required validation as completed. Do not add orchestration or budget-management layers, per-task checklists, cost reports, or duplicate records merely to assert this principle.

## Normal-path acceptance

When changing a normal entry point or the rules governing it, check the affected path with representative use after initial setup. Humans should not need to reconstruct environment-specific commands; controller agents should not need to rebuild routine state from multiple histories or repeatedly explain the same mechanical checks. Keep task-relevant specifications and evidence available on demand.

Preserve required checks at the operations they protect, including revalidation after relevant state changes. Unrelated diagnostics must not become blanket prerequisites. Keep first-time setup, migration inventories, and incident repair distinct from routine use.

Use existing tests and evidence where possible. These are acceptance criteria for system changes, not new per-task gates, declarations, reports, or review records. Do not modify the Subject workload or evaluated instruction bytes to demonstrate compliance. Assess reductions in repeated work, time to a usable result, and user blocking within the applicable cost and resource limits; do not treat hidden output, early acknowledgement, work transferred to another agent, or unaccounted resource increases as sufficient.
