# Current Focus

Last updated: 2026-01-18

## What We Were Working On

Backlog restructuring — broke EPIC-15 (agent-human boundaries) into smaller, focused epics:
- EPIC-15: Narrowed to risk taxonomy and conceptual model
- EPIC-17: Production protection via ConfigHub gates (concrete, actionable)
- EPIC-18: Tiered authority across environments (design work)
- EPIC-19: ConfigHub multi-tenancy (placeholder for future)

## Key Decisions This Session

1. **EPIC-15 split** — The original epic mixed concrete implementation with forward-looking exploration. Split by theme for clarity.
2. **Dependency added** — ISSUE-15.1 (risk classes) now depends on ISSUE-14.7 (policy-to-risk-class mapping)
3. **EPIC-17 prioritized over EPIC-15** — Production protection is more concrete and actionable; risk taxonomy can follow.
4. **Keep advanced agent considerations** — User wants to design for the agent future based on current AI trajectory.

## Not Ready Yet

These items exist in the backlog but have unresolved prerequisites or context:

| Item | Why Not Ready | Blocked By |
|------|---------------|------------|
| EPIC-11 (XRD implementation) | User indicated not ready; may need EPIC-17/prod space first | Clarify with user |
| ISSUE-15.1 | Depends on policy-to-risk-class mapping | ISSUE-14.7 |
| EPIC-19 | Placeholder; big topic for later | User decision |

## Recommended Next Items

1. **ISSUE-14.7** — Design policy-to-risk-class mapping (last item in EPIC-14, prerequisite for EPIC-15)
2. **EPIC-17** — Production protection via ConfigHub gates (concrete, no blockers)

## Open Questions

- When will we be ready for EPIC-11 (XRD)? What's blocking it?
- Should EPIC-17 come before or after ISSUE-14.7?
