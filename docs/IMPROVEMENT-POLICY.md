# Improvement Policy

This document has the same standing as `CONSTITUTION.md`. Together they are the constitutional documents of this apparatus: `CONSTITUTION.md` defines the system's purpose, boundaries, invariants, and required quality of normal operation, and this document defines how to reduce and improve it without losing them.

Neither constitutional document may be deleted as an ordinary simplification step. Requirements within them remain open to deliberate revision against the system's purpose. Such revision must make its effect on purpose, boundaries, required quality, or improvement order explicit; it is not permission to bypass the current contract during a run or rewrite past results.

## Purpose

The system exists to obtain useful evidence about how changes to agent rules and skills affect actual behavior and outcomes, and to advance decisions about adoption, rejection, retaining the current baseline, and conditions of use within available evidence and resources. When adopting a result, it must establish the same evaluated instruction bytes as the stable baseline without changing what was evaluated.

Controlled comparison, validation, records, and identity guarantees are means to these decisions, not independent ends. Formal experimental completeness, elimination of every uncertainty, and passing checks are not the purpose. Runs that do not support promotion may still provide useful observations and artifacts.

Adoption is not generic release management. Transparent normal operation is a required quality of fulfilling this purpose. These principles do not expand the apparatus core into a general experiment-management or agent-orchestration platform.

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

Justify a requirement, check, record, repair, or rerun by the decision it enables or the specific error or harm it prevents. Its presence in a specification, schema, test, or invariant is not sufficient justification for retaining it unchanged. Reconsider both the guarantee's scope and the cost of providing it. Revise contracts deliberately rather than bypassing them during execution.

When evidence is incomplete or conditions deviate, first consider reuse of existing evidence, reevaluation of saved artifacts, and a narrower conclusion. Restrict the affected observation, inference, or operation instead of discarding unrelated evidence or requiring complete repair and repetition by default. Missing information is not success, and stating a limitation does not make a confounded comparison valid.

Validate required outcomes and properties. Require exact wording, procedures, representations, or bytes only where they are themselves necessary contracts. Do not force the subject into an evaluator's preferred implementation. Preserve genuine non-destructive behavior and byte-retention requirements where the task requires them.

Further rigor is justified only when its expected decision value or protection is proportionate to total time, resource use, information loss, and user burden. If not, delete the requirement, narrow where it applies, or retain the measurement as supporting evidence rather than a blanket gate. Do not introduce a new checklist, approval layer, scoring framework, or record to assert this rule.

Apply the improvement order to end-to-end work, including work imposed on humans and controller agents, not only to repository size. Removing an entry point while requiring users to reconstruct its behavior is not simplification. Prefer existing entry points, declarations, and records before adding a new layer or another source of truth.

Promotion must remain limited to preserving the identity, integrity, and provenance of the validated result while establishing it as the new stable baseline.

## User waiting and resource limits

Meet necessary safety and quality requirements, then assess time, cost, rework, and user burden against the actual operating decision. Do not require every measured indicator to improve simultaneously. An authorized, proportionate cost increase may be acceptable for a useful reduction in time or burden; this is not permission to exceed resource limits or ignore a required quality regression. Separate supporting measurements from criteria required for adoption, and do not change a fixed evaluation after seeing results to favor a candidate.

Evaluator repair, evidence organization, and measurement are supporting work. Return their findings to the original decision: what is now supported, what remains unresolved, and which specific missing evidence could change the choice. Finishing supporting work is not finishing the adoption decision. Do not make a new experiment the automatic next step or continue refining the apparatus when existing evidence can support the needed decision.

Assume that the user will not wait and is not willing to wait. Avoidable waiting, monitoring, and repeated intervention are usability defects even when an operation eventually succeeds. Do not require the user to restate this assumption or set a time budget for every task. Keeping initial setup and repair separate from routine use does not exempt them from reducing avoidable waiting.

Start from the ideal path with no avoidable user waiting. Apply the improvement order to remove unnecessary work and dependencies before accelerating retained steps. Within required quality, safety, approvals, and applicable cost and resource limits, prioritize reducing both elapsed time from the user's request to a usable result and the time during which the user is blocked from useful work. Speed is not an unlimited spending mandate. Early acknowledgement or returning control alone is not acceptance.

For irreducibly long operations, minimize necessary blocking and allow genuinely independent work to proceed. Use existing execution and result-retrieval paths so the user need not poll, reconstruct state, or return to advance mechanical steps. Do not claim that submission is completion, or treat deferred work still blocking the requested result as eliminated waiting.

Choose operation-appropriate latency targets when improving a path, rather than accepting its current duration as necessary. Apply established budgets and resource allowances alongside these targets. Judge the path with representative observations and reusable evidence, making unavoidable waits and any timing exclusions explicit. Numeric limits belong to the affected operation or approved operating profile, not to a universal threshold here.

Additional spend or scarce usage is justified only by a meaningful, proportionate reduction in time to a usable result or user burden, and must remain within authorized limits. Budget headroom is not a target to consume. Evaluate total resources across preparation, management, handoffs, implementation, review, retries, validation, and result delivery, not only one model's unit price or one stage's duration. Include one-time improvement effort and realistic recurring costs where they affect the decision. Distinguish reference cost estimates, actual charges, and consumption of limited usage allowances; missing measurements are not zero cost.

Reuse established budgets, approved operating profiles, and available evidence. Do not infer authorization for materially higher spending, greater usage, premium tiers, extra agents, or speculative duplicate runs merely from an instruction to be fast. Where a material increase is not covered by existing authorization, use an authorized lower-resource path if it meets the requirements, or surface the specific trade-off before incurring the increase. Do not require a new budget question for routine actions already within authorization. If the latency target cannot be met within the applicable limits, report the unmet target rather than silently exceeding a limit or declaring acceptance.

Preserve necessary protections and approvals, evidence integrity, adoption identity, and responsibility boundaries. Apply the currently effective contract at the operations it protects; deliberately revise unnecessary requirements rather than silently bypassing them. Speed and deferral must not relabel pending required validation as completed, while incomplete supporting diagnostics must not block unrelated safe analysis or result delivery. Do not add orchestration or budget-management layers, per-task checklists, cost reports, or duplicate records merely to assert this principle.

## Normal-path acceptance

When changing a normal entry point or the rules governing it, check the affected path with representative use after initial setup. Humans should not need to reconstruct environment-specific commands; controller agents should not need to rebuild routine state from multiple histories or repeatedly explain the same mechanical checks. Keep task-relevant specifications and evidence available on demand.

Apply the currently effective contract at the operations it protects, including necessary revalidation after relevant state changes. Unrelated diagnostics must not become blanket prerequisites. Keep first-time setup, migration inventories, and incident repair distinct from routine use.

Use existing tests and evidence where possible. These are acceptance criteria for system changes, not new per-task gates, declarations, reports, or review records. Do not modify the Subject workload or evaluated instruction bytes to demonstrate compliance. Assess reductions in repeated work, time to a usable result, and user blocking within the applicable cost and resource limits; do not treat hidden output, early acknowledgement, work transferred to another agent, or unaccounted resource increases as sufficient.

Assess whether the affected path returns usable evidence, an appropriately bounded conclusion, and the next decision without avoidable repair or repetition. Documentation of uncertainty, a rejected candidate, or a bounded inconclusive result may be a valid return; it is not automatic promotion or proof of equivalence. Use existing evidence to check this behavior where sufficient. Do not require new subject runs merely to demonstrate adherence to this policy, or encode the policy's prose as mandatory string matches.
