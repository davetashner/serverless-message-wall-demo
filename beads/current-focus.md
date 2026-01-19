# Current Focus

Last updated: 2026-01-19

## Latest Session: ADR-012 Developer Authoring Surface

Resolved ISSUE-16.3 by documenting the decision that emerged from prior architectural work.

### Key Decision

**Developers author Crossplane Claims directly as the canonical authoring surface.**

- Claims are stored in ConfigHub (ADR-010)
- Claims sit at the Intent/Authority boundary (four-plane model)
- Claims are minimal (8 fields, no AWS concepts)
- OAM is optional convenience layer that compiles to Claims

### What Changed

| Item | Change |
|------|--------|
| `docs/decisions/012-developer-authoring-surface.md` | New ADR documenting the decision |
| ISSUE-16.3 | Marked done |
| ISSUE-16.4 | Marked done (examples already exist) |
| ISSUE-16.1, 16.2 | Marked as optional per ADR-012 |

### EPIC-16 Status

| Issue | Status | Notes |
|-------|--------|-------|
| ISSUE-16.1 | Optional | OAM vocabulary (nice-to-have) |
| ISSUE-16.2 | Optional | OAM compiler (depends on 16.1) |
| ISSUE-16.3 | Done | ADR-012 |
| ISSUE-16.4 | Done | Examples exist |

---

## Previous Session: Commit Standards & Agentic PR Workflow

Implemented comprehensive commit and PR standards with enforcement.

### Key Standards

- **Commits**: Conventional Commits format required (`type(scope): Subject`)
- **PRs**: Must include `## Evidence` section (except docs-only)
- **Review**: Run `./scripts/review-changes.sh` before pushing

---

## Previous Session: Enterprise Epics

Added **15 new epics (EPIC-21 through EPIC-35)** for enterprise-scale platform features.

### Recommended Phasing

| Phase | Focus | Epics |
|-------|-------|-------|
| A | Multi-team foundation | EPIC-22, 25, 28, 29 |
| B | Operational maturity | EPIC-21, 26, 30 |
| C | Scale and resilience | EPIC-23, 24, 32, 34 |
| D | Advanced automation | EPIC-27, 31, 33, 35 |

## Pending Epics (Original Backlog)

| Epic | Title | Open Issues | Status |
|------|-------|-------------|--------|
| EPIC-11 | XRD abstraction | 5 | Blocked (ask user) |
| EPIC-16 | Developer authoring/OAM | 2 (optional) | Core decisions done |
| EPIC-17 | Production protection gates | 5 | Pending |
| EPIC-19 | Multi-tenancy design | 3 | Pending |

## Not Ready Yet

| Item | Why | Blocked By |
|------|-----|------------|
| EPIC-11 | User indicated not ready | Ask user |
| EPIC-16.1, 16.2 | OAM is optional per ADR-012 | User decision to pursue |
| EPIC-19 | Deferred | User decision |
| EPIC-21–35 | Design-only, no issues | Break down when ready |

## Recommended Next Items

**Demo/foundation track:**
1. EPIC-17 — Production protection gates (5 issues)

**Enterprise scale (need issue breakdown):**
1. EPIC-28 — Self-service tenant onboarding
2. EPIC-29 — Enterprise identity and access
