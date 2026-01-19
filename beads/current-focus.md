# Current Focus

Last updated: 2026-01-18

## What We Were Working On

Added **15 new epics (EPIC-21 through EPIC-35)** to address enterprise-scale gaps in the configuration management platform design.

### New Enterprise-Scale Epics

| Epic | Title | Phase | Notes |
|------|-------|-------|-------|
| EPIC-21 | Observability and control plane health | B | Platform SLOs, metrics, alerting |
| EPIC-22 | Cost management and FinOps | A | Cost attribution, budgets, chargeback |
| EPIC-23 | Disaster recovery and business continuity | C | Backup, cross-region, recovery |
| EPIC-24 | Federation and multi-cluster operations | C | Multi-region, distributed actuation |
| EPIC-25 | Secrets and credential management | A | Vault integration, rotation |
| EPIC-26 | Change velocity controls and rollback | B | Canary, blast radius, auto-rollback |
| EPIC-27 | Service catalog and discoverability | D | XRD catalog, self-service portal |
| EPIC-28 | Self-service tenant onboarding | A | Automated team provisioning |
| EPIC-29 | Enterprise identity and access | A | SSO, RBAC, compliance |
| EPIC-30 | Drift detection and reconciliation | B | Drift alerting, remediation policies |
| EPIC-31 | Schema lifecycle and migration | D | XRD versioning, deprecation |
| EPIC-32 | Control plane scalability | C | Performance benchmarks, scaling |
| EPIC-33 | Testing and preview environments | D | PR previews, chaos engineering |
| EPIC-34 | Network and connectivity patterns | C | VPC templates, private endpoints |
| EPIC-35 | Agent operational boundaries | D | Agent identity, rate limits, suspension |

### Recommended Phasing

**Phase A — Foundation for multi-team** (before onboarding second team):
- EPIC-22: Cost management (attribution, budgets)
- EPIC-25: Secrets management (Vault integration)
- EPIC-28: Self-service tenant onboarding
- EPIC-29: Enterprise identity (SSO, RBAC)

**Phase B — Operational maturity**:
- EPIC-21: Observability (platform health, SLOs)
- EPIC-26: Change velocity controls (blast radius, rollback)
- EPIC-30: Drift detection (alerting, remediation)

**Phase C — Scale and resilience**:
- EPIC-23: Disaster recovery
- EPIC-24: Federation and multi-cluster
- EPIC-32: Control plane scalability
- EPIC-34: Network patterns

**Phase D — Advanced automation**:
- EPIC-27: Service catalog
- EPIC-31: Schema lifecycle
- EPIC-33: Testing and preview environments
- EPIC-35: Agent operational boundaries

## Existing Pending Epics

These epics from the original backlog are still pending:

| Epic | Title | Issues | Status |
|------|-------|--------|--------|
| EPIC-11 | XRD abstraction | 4 open | Blocked (ask user) |
| EPIC-13 | Configuration authority | 1 open | ISSUE-13.3 (bidirectional sync) |
| EPIC-16 | Developer authoring/OAM | 4 open | Pending |
| EPIC-17 | Production protection gates | 5 open | Pending |
| EPIC-19 | Multi-tenancy design | 3 open | Pending |

## Not Ready Yet

| Item | Why Not Ready | Blocked By |
|------|---------------|------------|
| EPIC-11 (XRD implementation) | User indicated not ready | Unclear — ask user |
| EPIC-19 (multi-tenancy) | Placeholder for future | User decision to defer |
| EPIC-21–35 (enterprise scale) | Design-only, no issues yet | Break down when ready to start |

## Recommended Next Items

For the **demo/foundation** track (completing the message wall):
1. **EPIC-16** — Developer authoring experience (4 issues)
2. **EPIC-17** — Production protection via ConfigHub gates (5 issues)

For **enterprise scale** (new epics, need issue breakdown):
1. **EPIC-28** — Self-service tenant onboarding (Phase A foundation)
2. **EPIC-29** — Enterprise identity and access (Phase A foundation)

## Open Questions

- Ready to break down issues for any of the new enterprise epics?
- Which phase (A/B/C/D) aligns with near-term goals?
- Should EPIC-19 (multi-tenancy) be merged with EPIC-28 (tenant onboarding)?
- What's blocking EPIC-11 (XRD)?

## Session Stats

- 15 new epics added (EPIC-21 through EPIC-35)
- Backlog now covers enterprise-scale configuration management
- New epics are design-only (no issues yet) per user preference
