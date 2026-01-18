# ADR-005: ConfigHub Integration Architecture

## Status
Accepted

## Context
ConfigHub (confighub.com) is a configuration management platform that stores fully-rendered Kubernetes manifests as queryable, mutable data. Unlike template-based systems, ConfigHub treats "configuration as data" — you can find resources by attribute, modify them in bulk, and track every change.

We want to integrate ConfigHub into the deployment flow so that:
- ConfigHub becomes the authoritative source of truth for resolved configuration
- The Kubernetes actuator receives manifests from ConfigHub, not directly from Git
- Policy enforcement and bulk changes happen in ConfigHub before actuation

## Decision
Adopt the following deployment flow:

```
Git (authoring)
    │
    ▼
Render Crossplane CRDs (CI/pipeline)
    │
    ▼
ConfigHub (authoritative store)
    │
    ▼
Kubernetes Actuator (pulls/receives from ConfigHub)
    │
    ▼
AWS Resources (managed by Crossplane)
```

### ConfigHub Primitives Used

| Primitive | How We Use It |
|-----------|--------------|
| **Space** | One space per environment (dev, staging, prod) |
| **Unit** | One unit per Crossplane managed resource (Lambda, S3, DynamoDB, etc.) |
| **Revision** | Every change creates a new revision with full history |
| **ChangeSet** | Groups related changes (e.g., "security-patch-2024-01") |
| **Function** | Bulk operations like `set-env-var`, `set-container-resources` |
| **Trigger** | Approval gates before applying to production |

### Bulk Change Workflow

```
1. Query: ch unit list --where "kind=Function AND environment=prod"
2. Preview: ch fn set-env-var --var X --value Y --dry-run
3. Bundle: ch changeset create "reason-for-change"
4. Modify: ch fn set-env-var --var X --value Y --changeset "reason"
5. Validate: ch fn vet-schemas --changeset "reason"
6. Approve: ch changeset request-approval --approvers "team"
7. Apply: ch changeset apply --target actuator-cluster
```

## Rationale
- Git remains the authoring surface for developers
- Rendering happens in CI, producing fully-resolved manifests (no placeholders)
- ConfigHub holds the authoritative resolved configuration, enabling:
  - **Queryability**: Find all resources matching criteria (e.g., all Lambdas with memorySize < 256)
  - **Bulk mutation**: Change many resources with one command
  - **Validation functions**: Run policy checks before apply
  - **Approval triggers**: Require human approval for high-risk changes
  - **Audit trail**: Every change is attributed, timestamped, and linked to a changeset
  - **Rollback**: Revert to any previous revision instantly
- Kubernetes actuator only applies what ConfigHub approves
- Crossplane provides continuous reconciliation (drift correction)

## Open Questions
- **Actuation mechanism**: ConfigHub may use ArgoCD to push manifests to the actuator cluster, or the actuator may pull from ConfigHub. This will be clarified in EPIC-8 implementation.

## Policy Enforcement (Defense in Depth)

Policies run at multiple enforcement points to catch violations early and provide defense in depth:

```
┌─────────────────────────────────────────────────────────────────────────┐
│  CI / Pre-commit          │  Earliest feedback (optional)              │
│  (OPA / conftest)         │  Catch obvious violations before merge     │
├───────────────────────────┼─────────────────────────────────────────────┤
│  ConfigHub                │  Authority layer enforcement               │
│  (OPA policies)           │  Block violations before apply             │
├───────────────────────────┼─────────────────────────────────────────────┤
│  Kyverno                  │  Actuation layer enforcement               │
│  (Admission control)      │  Final gate before Kubernetes accepts      │
└───────────────────────────┴─────────────────────────────────────────────┘
```

**Why multiple layers?**

1. **Fail fast**: CI catches violations before they reach ConfigHub, saving time
2. **Defense in depth**: If one layer misses a violation, another catches it
3. **Different visibility**: ConfigHub policies see Claims; Kyverno sees expanded resources
4. **Break-glass safety**: Kyverno enforces policies even during emergency direct-apply

**Same policy, different contexts**:
- ConfigHub validates the Claim (e.g., "prod Claims must have lambdaMemory >= 256")
- Kyverno validates expanded resources (e.g., "all Lambda resources must have required tags")

Some policies may be duplicated across layers intentionally. This is acceptable because:
- The cost of duplication is low (policies are declarative)
- The cost of a missed violation is high (security risk, compliance failure)

See [ADR-007: Kyverno Policy Enforcement](./007-kyverno-policy-enforcement.md) for Kyverno-specific policies.

## Consequences
- CI pipeline must render and publish to ConfigHub (not directly to cluster)
- Actuator cluster needs connectivity to ConfigHub
- Direct `kubectl apply` from CI is prohibited for ConfigHub-managed resources
- Break-glass procedures must reconcile back to ConfigHub after emergency changes
- Policies should be evaluated at multiple layers for defense in depth

## Related Documents
- `docs/bulk-changes-and-change-management.md` - Detailed scenarios and risk mitigation
- `docs/demo-guide.md` - Demo talking points including ConfigHub section
