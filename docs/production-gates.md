# Production Gates

**Status**: Reference documentation for EPIC-17 (Production Protection Gates)
**Related**: [Precious Resources](precious-resources.md), [Approval Gates](design-approval-gates.md)

---

## Overview

Production gates prevent accidental deletion or destruction of precious resources. Gates are enforced at multiple layers:

| Layer | Enforcement | Blocks |
|-------|-------------|--------|
| **Kyverno** | Kubernetes admission | DELETE operations, destructive updates |
| **ConfigHub** | Authority layer | Unit deletion, revision that removes units |
| **Git** | PR review | Changes to prod Claims require approval |

---

## Gate Types

### Delete Gate

Blocks deletion of resources containing production data.

```yaml
annotations:
  confighub.io/delete-gate: "enabled"  # Default for precious resources
```

**Blocked operations**:
- `kubectl delete serverlesseventappclaim messagewall-prod`
- Deleting the Claim via ArgoCD sync
- Removing the Claim from ConfigHub

### Destroy Gate

Blocks updates that would effectively destroy the resource or its data.

```yaml
annotations:
  confighub.io/destroy-gate: "enabled"  # Default for precious resources
```

**Blocked operations**:
- Changing `environment: prod` to `environment: dev`
- Removing the `precious=true` annotation
- Changes that would recreate the underlying DynamoDB/S3

---

## Enforcement Layers

### Layer 1: Kyverno (Actuator Cluster)

Policy: `platform/kyverno/policies/gate-precious-resources.yaml`

Enforces gates at Kubernetes admission time. Blocks:
- DELETE of Claims with `confighub.io/precious=true`
- DELETE of DynamoDB Tables with `confighub.io/precious=true` label
- DELETE of S3 Buckets with `confighub.io/precious=true` label
- UPDATE that changes environment from `prod`
- UPDATE that removes `precious` annotation

**Error message example**:
```
Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:

resource ServerlessEventAppClaim/default/messagewall-prod was blocked due to the following policies

gate-precious-resources:
  block-delete-precious-claims: |
    DELETE BLOCKED: This Claim contains precious resources (dynamodb,s3).

    Deletion of precious production resources requires explicit approval.

    To proceed with deletion:
    1. Create an approval request: See docs/precious-resources.md
    2. Get approval from a platform operator
    3. Add annotation: confighub.io/break-glass=approved
    4. Re-attempt deletion within the approval window
```

### Layer 2: ConfigHub (Authority Layer)

ConfigHub gates operate at the unit level before changes reach the actuator.

**Configuration** (via `cub` CLI):
```bash
# Enable delete gate on a unit
cub unit update messagewall-prod \
  --space messagewall-prod \
  --set-gate delete=enabled

# Enable destroy gate
cub unit update messagewall-prod \
  --space messagewall-prod \
  --set-gate destroy=enabled

# View gate status
cub unit show messagewall-prod --space messagewall-prod --show-gates
```

**Blocked operations**:
- `cub unit delete` without approval
- Revisions that would remove the unit
- Bulk operations affecting gated units

### Layer 3: Git PR Review

Changes to production Claims require PR approval via CODEOWNERS.

```
# .github/CODEOWNERS
examples/claims/messagewall-prod.yaml @platform-team
```

---

## Override Mechanism: Break-Glass

For legitimate deletions (decommissioning, migration), use the break-glass process:

### Step 1: Request Approval

```bash
# Document the reason and get approval
# See ISSUE-17.4 for full approval workflow
```

### Step 2: Add Break-Glass Annotation

```yaml
metadata:
  annotations:
    confighub.io/break-glass: "approved"
    confighub.io/break-glass-reason: "Decommissioning per TICKET-123"
    confighub.io/break-glass-approver: "platform-lead@example.com"
    confighub.io/break-glass-expires: "2026-01-20T00:00:00Z"
```

### Step 3: Perform Operation

With break-glass annotation present, the delete/destroy operation proceeds.

### Step 4: Audit

All break-glass operations are logged and require post-incident review.

---

## Verifying Gate Status

### Check Kyverno Policy

```bash
# Verify policy is installed
kubectl get clusterpolicy gate-precious-resources

# Check policy status
kubectl describe clusterpolicy gate-precious-resources

# Test gate (dry-run)
kubectl delete serverlesseventappclaim messagewall-prod --dry-run=server
```

### Check Claim Annotations

```bash
# List gate status for all Claims
kubectl get serverlesseventappclaim -A \
  -o custom-columns=\
NAME:.metadata.name,\
PRECIOUS:.metadata.annotations.confighub\.io/precious,\
DELETE-GATE:.metadata.annotations.confighub\.io/delete-gate,\
DESTROY-GATE:.metadata.annotations.confighub\.io/destroy-gate
```

### Check ConfigHub Gates

```bash
# List units with gates enabled
cub unit list --space messagewall-prod --filter "gates.delete=enabled"

# Show gate details for a unit
cub unit show messagewall-prod --space messagewall-prod --show-gates
```

---

## Gate Configuration Reference

| Annotation | Values | Default | Description |
|------------|--------|---------|-------------|
| `confighub.io/precious` | `true`, `false` | — | Marks resource as precious |
| `confighub.io/delete-gate` | `enabled`, `disabled` | `enabled` (if precious) | Controls delete gate |
| `confighub.io/destroy-gate` | `enabled`, `disabled` | `enabled` (if precious) | Controls destroy gate |
| `confighub.io/break-glass` | `approved` | — | Overrides gates |
| `confighub.io/break-glass-reason` | string | — | Required justification |
| `confighub.io/break-glass-approver` | string | — | Who approved |
| `confighub.io/break-glass-expires` | ISO 8601 | — | Override expiration |

---

## Troubleshooting

### "DELETE BLOCKED" Error

1. Verify the resource is precious: check `confighub.io/precious` annotation
2. If deletion is intentional, follow the break-glass process
3. If deletion should be allowed, disable the gate: `confighub.io/delete-gate=disabled`

### Gate Not Blocking

1. Verify Kyverno policy is installed: `kubectl get clusterpolicy gate-precious-resources`
2. Check policy status: `kubectl describe clusterpolicy gate-precious-resources`
3. Verify annotations are present on the resource

### Break-Glass Not Working

1. Ensure annotation value is exactly `approved` (not `true`)
2. Check expiration hasn't passed
3. Verify annotation is on the correct resource

---

## Summary

| Question | Answer |
|----------|--------|
| What do gates protect? | Precious resources (DynamoDB, S3 with data) |
| Where enforced? | Kyverno (K8s), ConfigHub (authority), Git (PR) |
| How to override? | Break-glass annotation with approval |
| How to verify? | `kubectl describe clusterpolicy gate-precious-resources` |

---

## References

- [Precious Resources](precious-resources.md) — Resource classification
- [Approval Gates](design-approval-gates.md) — Approval workflow design
- [Tiered Authority Model](tiered-authority-model.md) — Gate posture by tier
- Kyverno Policy: `platform/kyverno/policies/gate-precious-resources.yaml`
