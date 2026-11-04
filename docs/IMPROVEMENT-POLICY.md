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

Backward compatibility is not a retention requirement. The compatibility and data-migration norm of the [common charter](https://github.com/yasuyuki/agent-rules/blob/main/skills/common-charter/SKILL.md) applies, as the Constitution's shared norms state.

Justify a requirement, check, record, repair, or rerun by the decision it enables or the specific error or harm it prevents. Its presence in a specification, schema, test, or invariant is not sufficient justification for retaining it unchanged. Reconsider both the guarantee's scope and the cost of providing it. Revise contracts deliberately rather than bypassing them during execution.

When evidence is incomplete or conditions deviate, first consider reuse of existing evidence, reevaluation of saved artifacts, and a narrower conclusion. Restrict the affected observation, inference, or operation instead of discarding unrelated evidence or requiring complete repair and repetition by default. Missing information is not success, and stating a limitation does not make a confounded comparison valid.

Validate required outcomes and properties. Require exact wording, procedures, representations, or bytes only where they are themselves necessary contracts. Do not force the subject into an evaluator's preferred implementation. Preserve genuine non-destructive behavior and byte-retention requirements where the task requires them.

Further rigor is justified only when its expected decision value or protection is proportionate to total time, resource use, information loss, and user burden. If not, delete the requirement, narrow where it applies, or retain the measurement as supporting evidence rather than a blanket gate. Do not introduce a new checklist, approval layer, scoring framework, or record to assert this rule.

Apply the improvement order to end-to-end work, including work imposed on humans and controller agents, not only to repository size. Removing an entry point while requiring users to reconstruct its behavior is not simplification. Prefer existing entry points, declarations, and records before adding a new layer or another source of truth.

Promotion must remain limited to preserving the identity, integrity, and provenance of the validated result while establishing it as the new stable baseline.

## Shared norms in the apparatus

The [common charter](https://github.com/yasuyuki/agent-rules/blob/main/skills/common-charter/SKILL.md) governs user waiting, resource limits and normal-path acceptance for this apparatus, as for every managed product. This policy keeps only what those norms mean for experiments.

Evaluator repair, evidence organization, and measurement are supporting work. Return their findings to the adoption decision. Do not make a new experiment the automatic next step or continue refining the apparatus when existing evidence can support the needed decision.

Do not modify the Subject workload or evaluated instruction bytes to demonstrate compliance with these norms, and do not require new subject runs merely to demonstrate adherence. Documentation of uncertainty, a rejected candidate, or a bounded inconclusive result may be a valid return; it is not automatic promotion or proof of equivalence.
