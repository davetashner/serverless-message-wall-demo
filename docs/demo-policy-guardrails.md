# Policy Guardrails Demo

This guide walks through how policy guardrails prevent dangerous configurations at multiple layers, demonstrating defense-in-depth.

## Overview

Policies run at two enforcement points:

```
Developer submits Claim
        │
        ▼
┌─────────────────────────┐
│  ConfigHub (Authority)  │  ← OPA policies validate before apply
│  "Is this Claim valid?" │
└───────────┬─────────────┘
            │ (if valid)
            ▼
┌─────────────────────────┐
│  Kyverno (Actuation)    │  ← Admission control validates at apply
│  "Should K8s accept?"   │
└───────────┬─────────────┘
            │ (if valid)
            ▼
      AWS Resources
```

**Why two layers?**
- **Faster feedback**: ConfigHub catches errors before actuation (no waiting for K8s)
- **Defense in depth**: If one layer is bypassed, the other still protects
- **Different visibility**: ConfigHub sees Claims; Kyverno sees expanded resources

---

## Demo 1: Production Requirements Violation

### Scenario
A developer tries to deploy a production Claim with insufficient Lambda memory.

### The Violation

```yaml
# bad-prod-claim.yaml
apiVersion: messagewall.demo/v1alpha1
kind: ServerlessEventAppClaim
metadata:
  name: messagewall-prod
  namespace: default
spec:
  environment: prod
  awsAccountId: "123456789012"
  lambdaMemory: 128    # ❌ Too low for prod (requires >= 256)
  lambdaTimeout: 10    # ❌ Too low for prod (requires >= 30)
```

### Layer 1: ConfigHub Catches It First

```bash
# Attempt to publish to ConfigHub
$ cub unit update --space messagewall-prod --file bad-prod-claim.yaml

Error: Policy violation in prod-requirements
  - Production Claims must have lambdaMemory >= 256 MB. Current: 128 MB.
  - Production Claims must have lambdaTimeout >= 30 seconds. Current: 10 seconds.

Unit not updated. Fix violations and retry.
```

**Result**: Claim rejected before it ever reaches the actuator cluster.

### Layer 2: Kyverno Would Also Catch It

If ConfigHub were bypassed (e.g., emergency direct apply), Kyverno provides a safety net:

```bash
# Direct apply to cluster (bypassing ConfigHub)
$ kubectl apply -f bad-prod-claim.yaml

Error from server: admission webhook "validate.kyverno.svc" denied the request:
  policy validate-claim-prod-requirements/prod-lambda-memory-minimum:
    Production Claims must have lambdaMemory >= 256 MB.
    Current value: 128 (default).
```

**Result**: Even bypassing ConfigHub, the claim is still rejected.

### The Fix

```yaml
# good-prod-claim.yaml
spec:
  environment: prod
  awsAccountId: "123456789012"
  lambdaMemory: 256    # ✅ Meets prod minimum
  lambdaTimeout: 30    # ✅ Meets prod minimum
```

---

## Demo 2: Wildcard IAM Permissions Blocked

### Scenario
An IAM policy attempts to grant overly permissive wildcard permissions.

### The Violation

```yaml
# In a RolePolicy resource
spec:
  forProvider:
    policy: |
      {
        "Version": "2012-10-17",
        "Statement": [{
          "Effect": "Allow",
          "Action": "*",           # ❌ Wildcard action
          "Resource": "*"          # ❌ Wildcard resource
        }]
      }
```

### Kyverno Blocks It

```bash
$ kubectl apply -f overly-permissive-role.yaml

Error from server: admission webhook "validate.kyverno.svc" denied the request:
  policy validate-iam-no-wildcards/block-wildcard-actions-in-role-policy:
    IAM RolePolicy contains wildcard Action ("*").
    Use specific actions like "s3:GetObject" instead of "s3:*".
```

### The Fix

```yaml
spec:
  forProvider:
    policy: |
      {
        "Version": "2012-10-17",
        "Statement": [{
          "Effect": "Allow",
          "Action": [
            "s3:GetObject",
            "s3:PutObject"
          ],
          "Resource": "arn:aws:s3:::my-bucket/*"
        }]
      }
```

---

## Demo 3: Missing Required Fields

### Scenario
A Claim is missing the required `environment` field.

### The Violation

```yaml
apiVersion: messagewall.demo/v1alpha1
kind: ServerlessEventAppClaim
metadata:
  name: messagewall-mystery
spec:
  awsAccountId: "123456789012"
  # environment: ???  ← Missing!
```

### ConfigHub Catches It

```bash
$ cub unit update --space messagewall-dev --file incomplete-claim.yaml

Error: Policy violation in require-tags
  - ServerlessEventAppClaim must specify spec.environment (dev, staging, or prod)

Unit not updated.
```

---

## Policy Summary

| Policy | Layer | What It Checks | Enforcement |
|--------|-------|----------------|-------------|
| `require-tags.rego` | ConfigHub | Required fields (environment, accountId) | Block |
| `prod-requirements.rego` | ConfigHub | Prod minimums (memory, timeout) | Block |
| `validate-claim-prod-requirements.yaml` | Kyverno | Prod minimums (memory, timeout) | Block |
| `validate-aws-tags.yaml` | Kyverno | Required AWS resource tags | Block |
| `validate-iam-no-wildcards.yaml` | Kyverno | No wildcard IAM permissions | Block |
| `validate-encryption-at-rest.yaml` | Kyverno | Prod S3/DynamoDB encryption | Block |
| `audit-broad-iam-permissions.yaml` | Kyverno | Service-level wildcards | Audit only |

---

## Why Defense in Depth Matters

### Without Defense in Depth

```
Single enforcement point
        │
    [If bypassed or fails]
        │
        ▼
  Dangerous config deployed
```

### With Defense in Depth

```
ConfigHub catches violation → stops here
        │
    [If bypassed]
        │
        ▼
Kyverno catches violation → stops here
        │
    [If both bypassed]
        │
        ▼
IAM Boundaries limit blast radius
```

Each layer reduces risk. The probability of all layers failing simultaneously is much lower than any single layer failing.

---

## Testing Policies Locally

### Test ConfigHub Policies with OPA

```bash
# Install OPA
brew install opa

# Test against a valid claim
$ opa eval \
  --input examples/claims/messagewall-dev.yaml \
  --data platform/confighub/policies/ \
  "data.messagewall.policies.tags.deny"

# Expected: [] (empty - no violations)

# Test against an invalid claim
$ opa eval \
  --input bad-prod-claim.yaml \
  --data platform/confighub/policies/ \
  "data.messagewall.policies.prod.deny"

# Expected: ["Production Claims must have lambdaMemory >= 256 MB..."]
```

### Test Kyverno Policies

```bash
# Dry-run apply to see if Kyverno would accept
$ kubectl apply --dry-run=server -f my-claim.yaml

# If denied, you'll see the policy violation message
```

---

## Related Documents

- [Architecture Flow](architecture-flow.md) - Policy enforcement points diagram
- [Four-Plane Model](planes.md) - Policy as cross-cutting concern
- [ADR-005](decisions/005-confighub-integration-architecture.md) - Defense in depth rationale
- [ConfigHub Policies README](../platform/confighub/policies/README.md) - Policy development guide
