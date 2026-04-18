---
name: master-plan
description: >
  Create and manage master plans that decompose large initiatives into multiple coordinated
  ExecPlans with dependencies and integration points. TRIGGER when: user wants to plan a
  large initiative, coordinate multiple exec-plans, or track multi-plan progress.
argument-hint: <create|implement|status|update|discuss> [plan-name-or-path]
user-invocable: true
---

# MasterPlan Skill

You are managing master plans (MasterPlans) — coordination documents that decompose large initiatives into multiple ExecPlans with defined dependencies and integration points. Before doing anything, read the full specifications:

- [MASTERPLAN.md](MASTERPLAN.md) — requirements for MasterPlan documents
- [ExecPlan specification](../{{exec-plan.skill.name}}/PLANS.md) — requirements for child ExecPlan documents
- [ExecPlan skill](../{{exec-plan.skill.name}}/SKILL.md) — the ExecPlan skeleton and implementation protocol

Follow all three to the letter.

MasterPlans live in the `docs/masterplans/` directory at the repository root. Each master plan is a single Markdown file named with a sequential number prefix followed by a slug derived from its title (e.g., `docs/masterplans/1-kafka-consumer-pipeline.md`).

To determine the next number, scan `docs/masterplans/` for existing `.md` files, extract the leading integer from each filename, and use one greater than the highest found. If the directory is empty or does not exist, start at 1.

Child ExecPlans created by a MasterPlan live in `docs/plans/` following the standard ExecPlan naming convention (sequential numbering, slug from title). Each child ExecPlan must include a `MasterPlan:` reference line immediately after its title heading, linking back to the parent:

    # Add Kafka Consumer Group Support

    MasterPlan: docs/masterplans/1-kafka-consumer-pipeline.md

    This ExecPlan is a living document. ...


## Git Trailers

Every commit made while working under a MasterPlan must include a `MasterPlan:` git trailer:

    MasterPlan: docs/masterplans/<N>-<slug>.md

When implementing a specific child ExecPlan, include both trailers:

    Implement consumer group rebalance handling

    Add consumer group module with cooperative rebalance protocol.
    Wire partition assignment into the existing consumer loop.

    MasterPlan: docs/masterplans/1-kafka-consumer-pipeline.md
    ExecPlan: docs/plans/3-add-consumer-group.md


## Modes of Operation

Determine the mode from the first argument. If no argument is given, ask the user what they want to do.


### Mode: create

Create a new MasterPlan and all its child ExecPlans. The remaining arguments describe the initiative.

1. Research the codebase thoroughly before writing anything. Use Glob, Grep, and Read to understand the repository: file structure, key modules, build system, test infrastructure, dependency management, and existing patterns. A MasterPlan coordinates multiple plans, so you need both broad and deep understanding of the codebase. The research must be proportional to the initiative's scope.

2. Identify the natural work streams. Group by functional concern, not by file. Each work stream should produce an independently verifiable behavior. Aim for two to seven child plans per the decomposition principles in MASTERPLAN.md. If you identify more than seven, introduce phases to group them into implementation waves.

3. For each work stream, determine its purpose and scope (what exists after it is complete that did not exist before), the key files and modules it touches, its dependencies on other work streams (hard, soft, or integration per MASTERPLAN.md), and integration points with other work streams (shared types, interfaces, files, or configurations).

4. Write the MasterPlan document to `docs/masterplans/<N>-<slug>.md` using the skeleton below. The MasterPlan must be self-contained: someone reading only this document must understand the full decomposition, the rationale behind it, and how to proceed.

5. Create each child ExecPlan in `docs/plans/` following the ExecPlan specification and skeleton. Each child plan must:

   - Include `MasterPlan: <path>` immediately after its title heading.
   - Be fully self-contained per `claude/skills/{{exec-plan.skill.name}}/PLANS.md` — a novice with only the child plan and the working tree must be able to implement it end-to-end.
   - Reference other child plans only by file path when describing dependencies or integration points, never by assumed shared context.
   - Include all relevant codebase context discovered during research, even if it overlaps with other child plans. Self-containment takes precedence over avoiding repetition.

6. After creating all documents, verify the MasterPlan's Exec-Plan Registry contains the correct paths, dependencies, and initial statuses for every child plan.

7. Present a summary to the user: the initiative's purpose, the number of child plans created, a one-line description of each with its dependencies, and all file paths.

For large initiatives (five or more child plans), consider using the Agent tool to research and draft child exec-plans in parallel. Each agent should receive the full codebase context relevant to its work stream plus the integration points it must respect. After parallel creation, review all child plans for cross-plan consistency — shared types must agree, dependency references must be correct, and integration points must be documented identically in each plan that touches them.


### Mode: implement

Implement child ExecPlans under an existing MasterPlan. The first argument is the master plan file path. An optional second argument names a specific child ExecPlan to implement.

1. Read the entire MasterPlan file. Parse the Exec-Plan Registry to understand the current state of all child plans.

2. Determine which child plan to implement next:

   - If a specific child plan path was given as a second argument, use that plan. Verify its hard dependencies are all marked Complete first; if not, report the unmet dependencies and stop.
   - Otherwise, find the first child plan in the registry whose hard dependencies are all Complete and whose own status is Not Started or In Progress.
   - If no plan is implementable (all remaining plans have unsatisfied hard dependencies), report the blocking situation — which plans are blocked and what they are waiting on — and stop.

3. Update the child plan's status to In Progress in the MasterPlan's Exec-Plan Registry.

4. Read the child ExecPlan file. Follow the implementation protocol described in `claude/skills/{{exec-plan.skill.name}}/SKILL.md` (Mode: implement) to carry out the work. This means: identify the current state from the Progress section, proceed step by step through milestones, update the child plan's living sections at every stopping point, resolve ambiguities autonomously, and commit frequently. Every commit must include both `MasterPlan:` and `ExecPlan:` git trailers.

5. After completing the child plan:

   - Finalize the child plan's living sections per the exec-plan protocol (Outcomes & Retrospective, etc.).
   - Update the MasterPlan's Exec-Plan Registry: mark the child plan Complete.
   - Update the MasterPlan's Progress section: check off the corresponding milestones.
   - Record any cross-plan discoveries in the MasterPlan's Surprises & Discoveries section — especially anything that affects other child plans' assumptions, interfaces, or feasibility.

6. Check for the next implementable child plan. If one exists, present it and ask the user whether to continue implementation or stop here. If the user chooses to continue, repeat from step 2. If no plans remain, fill in the MasterPlan's Outcomes & Retrospective section.


### Mode: status

Show the current state of a MasterPlan and all its child plans.

If a master plan path is given:

1. Read the MasterPlan file. Parse the Exec-Plan Registry.

2. For each child plan in the registry, read its Progress section and compute completion percentage (checked items vs total items).

3. Present a summary: the initiative title, overall progress (child plans completed / total), and a table showing each child plan's number, title, status, progress percentage, current milestone, and any blockers.

4. Highlight dependency bottlenecks — child plans that are blocked and what they are waiting on. If multiple plans can proceed in parallel, note this.

If no path is given, scan `docs/masterplans/` for all `.md` files and show a summary table of each master plan's title and aggregate progress.


### Mode: update

Revise an existing MasterPlan to reflect new information, changed requirements, or decomposition adjustments. The argument is the master plan file path.

1. Read the entire MasterPlan file.

2. Make the requested changes. Common update scenarios:

   Adding a child plan: create the new ExecPlan in `docs/plans/`, add it to the Exec-Plan Registry, update the Dependency Graph and Integration Points sections.

   Cancelling a child plan: mark it Cancelled in the registry with a brief reason, update dependencies of plans that depended on it (remove or redirect the dependency), record rationale in the Decision Log.

   Splitting a child plan: create the new replacement plans, mark the original Cancelled with a reference to its replacements, redistribute progress items, update all sections.

   Merging child plans: create the merged plan incorporating content from both originals, mark the originals Cancelled with a reference to the merged plan, update all sections.

   Reordering: update the Dependency Graph and Exec-Plan Registry, propagate changed dependency references to affected child plans.

3. Ensure changes are comprehensively reflected across all sections of the MasterPlan, including living document sections (Progress, Surprises & Discoveries, Decision Log).

4. Cascade changes to affected child ExecPlans when necessary — update dependency references, integration point descriptions, or context sections that reference changed plans.

5. Append a revision note at the bottom of the MasterPlan describing what changed and why.


### Mode: discuss

Discuss or review an existing MasterPlan. The argument is the master plan file path.

1. Read the entire MasterPlan file. Read all child ExecPlan files referenced in the Exec-Plan Registry to have full context.

2. Engage with the user's questions or proposed changes. Common discussion topics include decomposition alternatives, dependency ordering, scope of individual child plans, integration concerns, risk assessment, and phase planning.

3. For every decision reached during discussion, update the Decision Log in the MasterPlan with the decision, rationale, and date.

4. If the discussion results in changes to the MasterPlan or any child plans, update all affected sections and documents. Per MASTERPLAN.md, revisions must be comprehensively reflected across all sections. Append a revision note at the bottom of the MasterPlan.


## MasterPlan Skeleton

When creating a new master plan, use this structure. Every section is mandatory.

    # <Initiative Title>

    This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
    Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

    This document is maintained in accordance with `claude/skills/{{mp.skill.name}}/MASTERPLAN.md`.


    ## Vision & Scope

    Explain in a few sentences what the system looks like after the entire initiative is
    complete. State the user-visible behaviors that will be enabled. Describe the scope
    boundary: what is included and what is explicitly excluded.


    ## Decomposition Strategy

    Explain how and why the initiative was decomposed into these specific work streams.
    Describe the principles that guided the decomposition (functional concerns, dependency
    minimization, independent verifiability). State alternatives considered and why they
    were rejected.


    ## Exec-Plan Registry

    | # | Title | Path | Hard Deps | Soft Deps | Status |
    |---|-------|------|-----------|-----------|--------|
    | 1 | ... | docs/plans/... | None | None | Not Started |
    | 2 | ... | docs/plans/... | EP-1 | None | Not Started |

    Status values: Not Started, In Progress, Complete, Cancelled.
    Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-1, EP-3).


    ## Dependency Graph

    Describe the ordering constraints between child plans in prose. Explain why each hard
    dependency exists — what artifact or behavior from the earlier plan does the later plan
    require? Identify which plans can proceed in parallel and under what conditions.


    ## Integration Points

    For each shared artifact (type, module, configuration, database table) that multiple
    child plans touch, document: which plans are involved, what the shared artifact is,
    which plan is responsible for defining it, and how later plans should consume or extend
    it.

    (None identified, or list each integration point.)


    ## Progress

    Track milestone-level progress across all child plans. Each entry names the child plan
    and the milestone. This section provides an at-a-glance view of the entire initiative.

    - [ ] EP-1: <first milestone description>
    - [ ] EP-1: <second milestone description>
    - [ ] EP-2: <first milestone description>


    ## Surprises & Discoveries

    Document cross-plan insights, dependency changes, scope adjustments, or unexpected
    interactions between child plans. Provide concise evidence.

    (None yet.)


    ## Decision Log

    Record every decomposition or coordination decision made while working on the master
    plan.

    - Decision: ...
      Rationale: ...
      Date: ...


    ## Outcomes & Retrospective

    Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
    Compare the result against the original vision.

    (To be filled during and after implementation.)
# --- seihou:master-plan ---



## Intention Tracking

When starting work in **create** or **implement** mode, use the `AskUserQuestion` tool to ask the user if they want to associate this work with an intention. Provide two options:

- **Yes** — "I have an Intention ID to associate with this initiative"
- **Skip** — "Proceed without linking an intention"

If the user provides an Intention ID, store it for the duration of the session and:

1. **Add it to the top of the MasterPlan.** When creating a new MasterPlan, include the Intention ID immediately after the title heading:

        # <Initiative Title>

        Intention: <IntentionId>

        This MasterPlan is a living document. ...

    When working with an existing MasterPlan that does not yet have an `Intention:` line, insert it in the same position (after the title, before the living-document preamble).

2. **Propagate it to every child ExecPlan** created during this session. Each child plan gets the same `Intention:` line after its title heading.

3. **Include an `Intention:` git trailer on every commit** alongside the other trailers:

        Implement consumer group rebalance handling

        Add consumer group module with cooperative rebalance protocol.

        MasterPlan: docs/masterplans/1-kafka-consumer-pipeline.md
        ExecPlan: docs/plans/3-add-consumer-group.md
        Intention: INTENT-42

Ask once at the start of a session. Do not ask again on subsequent operations within the same session. If the user skips or declines, proceed without the trailer.
# --- /seihou:master-plan ---
