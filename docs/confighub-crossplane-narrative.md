# ConfigHub + Crossplane: A Complete Demo Narrative

This document explains how ConfigHub, Crossplane, and AWS work together in the serverless message wall demo. It's designed to be understandable without prior ConfigHub or Crossplane knowledge.

## The Problem We're Solving

Modern cloud infrastructure faces several challenges:

1. **Configuration Sprawl**: Infrastructure definitions scattered across Git repos, CI/CD pipelines, and cloud consoles
2. **Drift**: Actual cloud state diverging from intended state
3. **Bulk Changes**: Updating many resources consistently (e.g., patching 50 Lambda functions)
4. **Audit Trail**: Knowing who changed what, when, and why
5. **Emergency Access**: Handling incidents while maintaining control

This demo shows how three technologies—ConfigHub, Crossplane, and AWS—work together to solve these problems.

---

## The Three Layers

### 1. ConfigHub: The Authority Layer

**What it is**: A configuration management platform that stores fully-rendered Kubernetes manifests as queryable, mutable data.

**Key insight**: Unlike Git (which stores text files) or Kubernetes (which stores runtime state), ConfigHub treats configuration as structured data you can query, modify in bulk, and version.

**What it does in this demo**:
- Stores the authoritative, fully-resolved Crossplane manifests
- Tracks every change with revision history
- Enables bulk operations across resources
- Provides approval gates before deployment
- Separates "what we want" (Head revision) from "what's deployed" (Live revision)

### 2. Crossplane: The Actuation Layer

**What it is**: A Kubernetes-based control plane that manages external resources (like AWS services) using the Kubernetes API and reconciliation model.

**Key insight**: Crossplane continuously reconciles desired state (from manifests) with actual state (in AWS). If someone changes an S3 bucket in the AWS console, Crossplane will revert it.

**What it does in this demo**:
- Runs in a local Kubernetes cluster (no application code, just controllers)
- Manages AWS resources: Lambda, DynamoDB, S3, EventBridge, IAM
- Continuously ensures AWS matches the declared configuration
- Reports status back to Kubernetes

### 3. AWS: The Runtime Layer

**What it is**: Amazon Web Services—the cloud provider where the actual application runs.

**What it does in this demo**:
- Runs Lambda functions (application logic)
- Stores data in DynamoDB
- Hosts static website on S3
- Routes events via EventBridge

---

## The Flow

```
Developer          ConfigHub           ArgoCD            Crossplane          AWS
    │                  │                  │                  │                │
    │  1. Author       │                  │                  │                │
    │  changes in Git  │                  │                  │                │
    │       │          │                  │                  │                │
    │       ▼          │                  │                  │                │
    │  CI renders      │                  │                  │                │
    │  manifests       │                  │                  │                │
    │       │          │                  │                  │                │
    │       ▼          │                  │                  │                │
    │  ─────────────────►                 │                  │                │
    │  2. Publish to   │                  │                  │                │
    │     ConfigHub    │                  │                  │                │
    │                  │                  │                  │                │
    │                  │  (Head advances) │                  │                │
    │                  │                  │                  │                │
    │  3. Operator     │                  │                  │                │
    │     reviews      │                  │                  │                │
    │       │          │                  │                  │                │
    │       ▼          │                  │                  │                │
    │  4. Promote      │                  │                  │                │
    │     (cub apply)  │                  │                  │                │
    │                  │                  │                  │                │
    │                  │  (Live advances) │                  │                │
    │                  │        │         │                  │                │
    │                  │        ▼         │                  │                │
    │                  │  ─────────────────►                 │                │
    │                  │  5. ArgoCD syncs │                  │                │
    │                  │     Live content │                  │                │
    │                  │                  │       │          │                │
    │                  │                  │       ▼          │                │
    │                  │                  │  ─────────────────►               │
    │                  │                  │  6. Crossplane   │                │
    │                  │                  │     reconciles   │                │
    │                  │                  │                  │       │        │
    │                  │                  │                  │       ▼        │
    │                  │                  │                  │    AWS resources
    │                  │                  │                  │    updated
```

### Step by Step

1. **Author**: Developer modifies infrastructure definitions in Git (e.g., changes Lambda memory)

2. **Render & Publish**: CI pipeline renders fully-resolved manifests and publishes to ConfigHub. This creates a new revision but does NOT deploy it.

3. **Review**: Operator can see pending changes using `cub unit diff`—what's in the latest revision vs. what's currently deployed.

4. **Promote**: Operator explicitly promotes the revision using `cub unit apply`. This advances the "Live" revision.

5. **Sync**: ArgoCD (watching ConfigHub) detects the Live revision changed and syncs to Kubernetes.

6. **Reconcile**: Crossplane sees the updated manifests and reconciles AWS to match.

---

## Key Concepts

### Head vs Live Revisions

ConfigHub tracks two revision pointers for each unit:

| Pointer | Meaning | Who Updates It |
|---------|---------|----------------|
| **HeadRevisionNum** | Latest revision (what was just pushed) | CI, bulk operations, imports |
| **LiveRevisionNum** | Deployed revision (what's running) | Operator via `cub unit apply` |

This separation enables:
- **Preview before deploy**: Push changes, review them, deploy when ready
- **Staged rollouts**: Deploy to dev, validate, then promote to prod
- **Emergency holds**: Stop deployment during incidents

### Continuous Reconciliation

Crossplane doesn't just apply configuration once—it continuously reconciles:

```
Every 60 seconds:
  1. Read desired state from Kubernetes manifests
  2. Read actual state from AWS APIs
  3. If different, update AWS to match desired state
```

This means:
- **Drift correction**: Manual AWS changes get reverted
- **Self-healing**: Deleted resources get recreated
- **Guaranteed consistency**: Desired state always wins

### The Authority Problem

Without a single source of truth, configuration can exist in multiple places:
- Git repository
- CI/CD pipeline state
- Kubernetes cluster
- AWS console

ConfigHub solves this by being the **authoritative store** for resolved configuration. Git is for authoring, but ConfigHub holds the final, rendered truth.

---

## Demo Scenarios

### Scenario 1: Bulk Configuration Change

**Problem**: Security requires a new environment variable on all Lambda functions.

**Traditional approach**: Edit files in Git, create PR, merge, deploy. For 50 functions, this means 50 file changes.

**ConfigHub approach**:

```bash
# Preview what would change
./scripts/demo-bulk-change.sh env SECURITY_LOG_ENDPOINT=https://security.internal/ingest --dry-run

# Apply to all Lambda functions in one operation
./scripts/demo-bulk-change.sh env SECURITY_LOG_ENDPOINT=https://security.internal/ingest \
  --desc "SEC-2024-001: Add security logging"

# Verify in AWS
./scripts/demo-bulk-change.sh env SECURITY_LOG_ENDPOINT=https://security.internal/ingest --verify
```

**What this demonstrates**:
- Single operation updates all functions
- Preview before apply (`--dry-run`)
- Audit trail with context (`--desc`)
- End-to-end verification

### Scenario 2: Controlled Rollout

**Problem**: CI pushes changes but you don't want them deployed immediately.

**Solution**: Head/Live separation

```bash
# Run the demo
./scripts/demo-revision-rollout.sh

# Key commands:
cub unit list --space messagewall-dev \
  --columns Unit.Slug,Unit.HeadRevisionNum,Unit.LiveRevisionNum

cub unit diff --space messagewall-dev lambda    # See pending changes
cub unit apply --space messagewall-dev lambda   # Deploy when ready
```

**What this demonstrates**:
- CI can push freely without affecting production
- Operator reviews and promotes explicitly
- Full visibility into what will change

### Scenario 3: Break-Glass Recovery

**Problem**: Incident requires immediate AWS change, bypassing normal flow.

**Solution**: Make emergency change, then reconcile

```bash
# Run the demo
./scripts/demo-break-glass-recovery.sh

# Flow:
# 1. Incident: Lambda hitting memory limits
# 2. Break-glass: Direct AWS change to increase memory
# 3. Reconcile: Update ConfigHub to match emergency change
# 4. Audit: Incident ID and context preserved in history
```

**What this demonstrates**:
- Emergency changes are possible when needed
- Reconciliation preserves single source of truth
- Without reconciliation, Crossplane would revert the change
- Audit trail captures incident context

---

## Risk Reduction

### 1. Blast Radius Control

**How it works**: IAM permission boundaries cap what Crossplane can do.

**Example**: Even if Crossplane is compromised, it cannot:
- Create admin roles
- Access resources outside the `messagewall-*` prefix
- Exceed the permission boundary

### 2. Policy Enforcement

**How it works**: Kyverno policies in Kubernetes validate and mutate resources.

**What's enforced**:
- All AWS resources get required tags automatically
- Resources without tags are rejected
- Tags enable cost allocation and cleanup

### 3. Continuous Reconciliation

**How it works**: Crossplane continuously enforces desired state.

**Risk reduction**:
- Manual AWS console changes get reverted
- Accidental deletions get restored
- Configuration drift is impossible (unless ConfigHub is updated)

### 4. Approval Gates

**How it works**: Head/Live separation requires explicit promotion.

**Risk reduction**:
- CI pushing bad config doesn't affect production
- High-risk changes can require approval
- Rollback is instant (promote a previous revision)

---

## Operability Gains

### 1. Queryability

Find resources by any attribute:

```bash
# Find all Lambda functions with < 256MB memory
cub unit list --space messagewall-dev \
  --where "kind=Function AND spec.forProvider.memorySize < 256"
```

### 2. Bulk Operations

Modify many resources with one command:

```bash
# Update timeout on all Lambda functions
./scripts/demo-bulk-change.sh timeout 30
```

### 3. Complete History

See every change ever made:

```bash
# View revision history
cub unit history --space messagewall-dev lambda

# Compare revisions
cub unit diff --space messagewall-dev lambda --from 5 --to 10
```

### 4. Instant Rollback

Revert to any previous state:

```bash
# Rollback to revision 5
cub unit apply --space messagewall-dev lambda --revision 5
```

### 5. Change Attribution

Every change records who made it and why:

```bash
# See who changed what
cub unit history --space messagewall-dev lambda --columns RevisionNum,CreatedBy,ChangeDesc
```

---

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              CONTROL PLANE                                   │
│                                                                             │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────────────────────┐  │
│  │     Git      │    │  ConfigHub   │    │    Kubernetes (Actuator)     │  │
│  │  (Authoring) │───▶│ (Authority)  │───▶│                              │  │
│  │              │    │              │    │  ┌────────────────────────┐  │  │
│  │  - Manifests │    │  - Revisions │    │  │      Crossplane        │  │  │
│  │  - CI/CD     │    │  - Bulk ops  │    │  │    ┌──────────────┐    │  │  │
│  │              │    │  - Approval  │    │  │    │   Provider   │    │  │  │
│  └──────────────┘    │  - History   │    │  │    │    (AWS)     │────┼──┼──┼──┐
│                      └──────────────┘    │  │    └──────────────┘    │  │  │  │
│                             ▲            │  └────────────────────────┘  │  │  │
│                             │            │                              │  │  │
│                             │            │  ┌────────────────────────┐  │  │  │
│                        ┌────┴────┐       │  │       Kyverno          │  │  │  │
│                        │ ArgoCD  │       │  │    (Policy Engine)     │  │  │  │
│                        │  (Sync) │       │  └────────────────────────┘  │  │  │
│                        └─────────┘       └──────────────────────────────┘  │  │
└─────────────────────────────────────────────────────────────────────────────┘  │
                                                                                  │
                                                                                  │
┌─────────────────────────────────────────────────────────────────────────────┐  │
│                              AWS (Runtime)                                   │◀─┘
│                                                                             │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐                  │
│  │    Lambda    │    │   DynamoDB   │    │      S3      │                  │
│  │              │    │              │    │              │                  │
│  │ - api-handler│    │ - Messages   │    │ - Website    │                  │
│  │ - snapshot   │    │ - Metadata   │    │ - state.json │                  │
│  └──────────────┘    └──────────────┘    │ - Artifacts  │                  │
│         │                   │            └──────────────┘                  │
│         │                   │                   ▲                          │
│         ▼                   │                   │                          │
│  ┌──────────────┐           │                   │                          │
│  │ EventBridge  │───────────┴───────────────────┘                          │
│  └──────────────┘                                                          │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Summary

| Layer | Technology | Responsibility |
|-------|------------|----------------|
| Authority | ConfigHub | Store resolved config, enable bulk ops, track history |
| Sync | ArgoCD | Pull from ConfigHub, apply to Kubernetes |
| Actuation | Crossplane | Reconcile Kubernetes manifests to AWS |
| Runtime | AWS | Run application workloads |

**Key principles**:
1. Git is for authoring; ConfigHub is for authority
2. Separation of Head (latest) and Live (deployed) enables controlled rollouts
3. Crossplane's continuous reconciliation prevents drift
4. Bulk operations happen at the authority layer, not in Git
5. Emergency changes are possible but must be reconciled

**The result**: A deployment pipeline that is observable, queryable, auditable, and safe—while remaining flexible enough to handle real-world operational needs.

---

## Related Documentation

- [ADR-005: ConfigHub Integration Architecture](decisions/005-confighub-integration-architecture.md)
- [ADR-009: ArgoCD ConfigHub Sync](decisions/009-argocd-confighub-sync.md)
- [Demo Guide](demo-guide.md)
- [Bulk Changes and Change Management](bulk-changes-and-change-management.md)
