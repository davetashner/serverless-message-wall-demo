# Current Focus

Last updated: 2026-01-19

## Latest Session: Commit Standards & Agentic PR Workflow

Implemented comprehensive commit and PR standards with enforcement:

### What Was Added

| Item | Purpose |
|------|---------|
| `CONTRIBUTING.md` | Full standards documentation |
| `commitlint.config.js` | Conventional Commits enforcement |
| `.husky/commit-msg` | Local commit validation hook |
| `.husky/pre-push` | Optional pre-push review hook (disabled by default) |
| `scripts/review-changes.sh` | Local AI code review (uses Max subscription) |
| `scripts/pr-feedback-loop.sh` | Watches PR for feedback, auto-fixes |
| `.github/workflows/validate-commits.yml` | CI commit message check |
| `.github/workflows/validate-pr.yml` | CI evidence section check |
| `.github/workflows/claude-pr-review.yml` | CI AI review (disabled, needs API key) |
| `.github/pull_request_template.md` | PR template with Evidence section |

### Key Standards

- **Commits**: Conventional Commits format required (`type(scope): Subject`)
- **PRs**: Must include `## Evidence` section (except docs-only)
- **Review**: Run `./scripts/review-changes.sh` before pushing

### Agentic Workflow

```bash
# Review changes locally (free with Max)
./scripts/review-changes.sh

# Review and auto-fix issues
./scripts/review-changes.sh --fix

# After pushing PR, iterate on feedback
./scripts/pr-feedback-loop.sh <PR_NUMBER>
```

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
| EPIC-11 | XRD abstraction | 4 | Blocked (ask user) |
| EPIC-16 | Developer authoring/OAM | 4 | Pending |
| EPIC-17 | Production protection gates | 5 | Pending |
| EPIC-19 | Multi-tenancy design | 3 | Pending |

## Not Ready Yet

| Item | Why | Blocked By |
|------|-----|------------|
| EPIC-11 | User indicated not ready | Ask user |
| EPIC-19 | Deferred | User decision |
| EPIC-21–35 | Design-only, no issues | Break down when ready |

## Recommended Next Items

**Demo/foundation track:**
1. EPIC-16 — Developer authoring experience
2. EPIC-17 — Production protection gates

**Enterprise scale (need issue breakdown):**
1. EPIC-28 — Self-service tenant onboarding
2. EPIC-29 — Enterprise identity and access
