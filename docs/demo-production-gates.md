# Demo: Production Gates

**Status**: Demonstration runbook for ISSUE-17.5 (EPIC-17)
**Purpose**: Walk through the complete gate/approval flow using a safe test environment

---

## Overview

This runbook demonstrates:
1. Gate blocking a delete attempt
2. Approval request process
3. Override application
4. Successful deletion after approval

**Safety**: Uses a test Claim (`messagewall-gate-demo`) that can be safely deleted.

---

## Prerequisites

```bash
# Verify Kyverno is installed
kubectl get pods -n kyverno

# Verify gate policy is installed
kubectl get clusterpolicy gate-precious-resources

# Verify you have a running actuator cluster
kubectl cluster-info
```

---

## Part 1: Setup Test Resource

Create a test Claim marked as precious (mimics production):

```bash
# Create the demo Claim
cat <<'EOF' | kubectl apply -f -
apiVersion: messagewall.demo/v1alpha1
kind: ServerlessEventAppClaim
metadata:
  name: messagewall-gate-demo
  namespace: default
  annotations:
    confighub.io/precious: "true"
    confighub.io/precious-resources: "dynamodb,s3"
    confighub.io/data-classification: "test-data"
    confighub.io/delete-gate: "enabled"
    confighub.io/destroy-gate: "enabled"
spec:
  environment: prod
  awsAccountId: "000000000000"
  resourcePrefix: "demo-gate-test"
  region: us-east-1
  lambdaMemory: 256
  lambdaTimeout: 30
EOF

# Verify it was created
kubectl get serverlesseventappclaim messagewall-gate-demo
```

**Expected output**:
```
NAME                     AGE
messagewall-gate-demo    5s
```

---

## Part 2: Attempt Delete (Blocked)

Try to delete the precious resource:

```bash
kubectl delete serverlesseventappclaim messagewall-gate-demo
```

**Expected output** (gate blocks):
```
Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:

resource ServerlessEventAppClaim/default/messagewall-gate-demo was blocked due to the following policies

gate-precious-resources:
  block-delete-precious-claims: |
    DELETE BLOCKED: This Claim contains precious resources (dynamodb,s3).

    Deletion of precious production resources requires explicit approval.

    To proceed with deletion:
    1. Create an approval request: See docs/precious-resources.md
    2. Get approval from a platform operator
    3. Add annotation: confighub.io/break-glass=approved
    4. Re-attempt deletion within the approval window

    Resource: default/messagewall-gate-demo
    Data classification: test-data
```

**Demo point**: Gate successfully blocked unauthorized deletion.

---

## Part 3: Attempt Destroy (Blocked)

Try to change the environment (destructive update):

```bash
kubectl patch serverlesseventappclaim messagewall-gate-demo \
  --type=merge -p '{"spec":{"environment":"dev"}}'
```

**Expected output** (gate blocks):
```
Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:

resource ServerlessEventAppClaim/default/messagewall-gate-demo was blocked due to the following policies

gate-precious-resources:
  block-destroy-precious-claims: |
    DESTROY BLOCKED: Cannot change environment of precious Claim from prod.

    Changing the environment would destroy production data.
    This operation requires explicit approval.

    Current environment: prod
    Requested environment: dev

    See docs/precious-resources.md for the approval process.
```

**Demo point**: Gate prevents destructive changes, not just deletions.

---

## Part 4: Request Approval

In a real scenario, you would:
1. Create a ticket explaining why deletion is needed
2. Get approval from Platform Lead / Environment Owner
3. Document the backup and rollback plan

For this demo, we simulate approval:

```bash
echo "
=== APPROVAL REQUEST ===
Resource: messagewall-gate-demo
Action: delete
Requester: demo-user
Justification: Testing gate workflow for EPIC-17 demonstration
Backup: N/A (test resource with no real data)
Rollback: Re-apply the Claim YAML
Approver: platform-demo-approver
Approved at: $(date -Iseconds)
========================
"
```

---

## Part 5: Apply Break-Glass Override

Add the break-glass annotation (simulating approved override):

```bash
# Calculate expiration (1 hour from now)
EXPIRES=$(date -u -d "+1 hour" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || \
          date -u -v+1H +"%Y-%m-%dT%H:%M:%SZ")

kubectl annotate serverlesseventappclaim messagewall-gate-demo \
  confighub.io/break-glass=approved \
  confighub.io/break-glass-reason="EPIC-17 gate demonstration" \
  confighub.io/break-glass-approver="platform-demo-approver" \
  confighub.io/break-glass-expires="${EXPIRES}" \
  --overwrite

# Verify annotations
kubectl get serverlesseventappclaim messagewall-gate-demo -o yaml | grep -A10 "annotations:"
```

**Expected output**:
```yaml
  annotations:
    confighub.io/break-glass: approved
    confighub.io/break-glass-approver: platform-demo-approver
    confighub.io/break-glass-expires: "2026-01-19T12:00:00Z"
    confighub.io/break-glass-reason: EPIC-17 gate demonstration
    confighub.io/delete-gate: enabled
    confighub.io/destroy-gate: enabled
    confighub.io/precious: "true"
    ...
```

**Demo point**: Break-glass is applied via annotation, fully auditable.

---

## Part 6: Execute Deletion (Succeeds)

Now delete succeeds because break-glass is approved:

```bash
kubectl delete serverlesseventappclaim messagewall-gate-demo
```

**Expected output**:
```
serverlesseventappclaim.messagewall.demo "messagewall-gate-demo" deleted
```

**Verify deletion**:
```bash
kubectl get serverlesseventappclaim messagewall-gate-demo
```

**Expected output**:
```
Error from server (NotFound): serverlesseventappclaims.messagewall.demo "messagewall-gate-demo" not found
```

**Demo point**: With proper approval, legitimate deletions proceed.

---

## Part 7: Post-Action Review

In production, you would:
1. Update the ticket with completion status
2. Verify no unintended side effects
3. Archive the approval request

For this demo:
```bash
echo "
=== POST-ACTION REVIEW ===
Resource: messagewall-gate-demo
Action: delete
Status: COMPLETED
Executed at: $(date -Iseconds)
Side effects: None (test resource)
Audit: Kyverno admission logs + kubectl audit log
==========================
"
```

---

## Full Demo Script

Run the entire demo automatically:

```bash
#!/bin/bash
# scripts/demo-gate-workflow.sh

set -e

echo "=== EPIC-17 Gate Demo ==="
echo ""

# Setup
echo "1. Creating test resource..."
cat <<'EOF' | kubectl apply -f -
apiVersion: messagewall.demo/v1alpha1
kind: ServerlessEventAppClaim
metadata:
  name: messagewall-gate-demo
  namespace: default
  annotations:
    confighub.io/precious: "true"
    confighub.io/precious-resources: "dynamodb,s3"
    confighub.io/data-classification: "test-data"
    confighub.io/delete-gate: "enabled"
spec:
  environment: prod
  awsAccountId: "000000000000"
  resourcePrefix: "demo-gate-test"
  region: us-east-1
  lambdaMemory: 256
  lambdaTimeout: 30
EOF
sleep 2

# Attempt delete (should fail)
echo ""
echo "2. Attempting delete (should be BLOCKED)..."
if kubectl delete serverlesseventappclaim messagewall-gate-demo 2>&1 | grep -q "DELETE BLOCKED"; then
    echo "   ✓ Gate blocked deletion as expected"
else
    echo "   ✗ Gate did not block (check policy installation)"
fi

# Apply break-glass
echo ""
echo "3. Applying break-glass override..."
EXPIRES=$(date -u -d "+1 hour" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -v+1H +"%Y-%m-%dT%H:%M:%SZ")
kubectl annotate serverlesseventappclaim messagewall-gate-demo \
  confighub.io/break-glass=approved \
  confighub.io/break-glass-reason="Demo" \
  confighub.io/break-glass-approver="demo" \
  confighub.io/break-glass-expires="${EXPIRES}" \
  --overwrite
echo "   ✓ Break-glass applied"

# Delete (should succeed)
echo ""
echo "4. Deleting with override (should SUCCEED)..."
if kubectl delete serverlesseventappclaim messagewall-gate-demo; then
    echo "   ✓ Deletion succeeded with break-glass"
else
    echo "   ✗ Deletion failed unexpectedly"
fi

echo ""
echo "=== Demo Complete ==="
```

---

## Cleanup

If the demo was interrupted, clean up:

```bash
# Remove test resource (may need break-glass if gate is active)
kubectl annotate serverlesseventappclaim messagewall-gate-demo \
  confighub.io/break-glass=approved \
  confighub.io/break-glass-reason="Cleanup" \
  confighub.io/break-glass-approver="cleanup" \
  confighub.io/break-glass-expires="2099-01-01T00:00:00Z" \
  --overwrite 2>/dev/null || true

kubectl delete serverlesseventappclaim messagewall-gate-demo 2>/dev/null || true
```

---

## Troubleshooting

### Gate Not Blocking

```bash
# Check policy is installed
kubectl get clusterpolicy gate-precious-resources

# Check policy status
kubectl describe clusterpolicy gate-precious-resources | grep -A5 "Status:"

# Check Kyverno is running
kubectl get pods -n kyverno
```

### Break-Glass Not Working

```bash
# Verify annotation value is exactly "approved"
kubectl get serverlesseventappclaim messagewall-gate-demo \
  -o jsonpath='{.metadata.annotations.confighub\.io/break-glass}'

# Check expiration hasn't passed
kubectl get serverlesseventappclaim messagewall-gate-demo \
  -o jsonpath='{.metadata.annotations.confighub\.io/break-glass-expires}'
```

---

## Summary

| Step | Action | Expected Result |
|------|--------|-----------------|
| 1 | Create precious resource | Resource created with gate annotations |
| 2 | Attempt delete | **BLOCKED** by Kyverno |
| 3 | Attempt destroy | **BLOCKED** by Kyverno |
| 4 | Request approval | Document justification |
| 5 | Apply break-glass | Annotation added |
| 6 | Execute delete | **SUCCEEDS** |
| 7 | Post-action review | Document completion |

---

## References

- [Production Gates](production-gates.md) — Gate mechanism
- [Gate Override Workflow](gate-override-workflow.md) — Full approval process
- [Precious Resources](precious-resources.md) — Resource classification
