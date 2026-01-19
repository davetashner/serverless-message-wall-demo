# Gate Override Workflow

**Status**: Reference documentation for ISSUE-17.4 (EPIC-17)
**Related**: [Production Gates](production-gates.md), [Approval Gates](design-approval-gates.md), [Precious Resources](precious-resources.md)

---

## Overview

This document defines the approval workflow for overriding production delete/destroy gates. Gates exist to prevent accidental data loss; overrides require explicit human approval with documented justification.

---

## When Override Is Needed

| Scenario | Example | Override Required |
|----------|---------|-------------------|
| **Decommissioning** | Shutting down a service permanently | Yes |
| **Migration** | Moving data to a new system | Yes |
| **Disaster Recovery** | Recreating from backup in new region | Yes |
| **Cost Optimization** | Removing unused prod resources | Yes |
| **Bug Fix** | Deleting corrupted resource to recreate | Yes |

**Not override scenarios** (fix differently):
- Accidental Claim in wrong namespace → move, don't delete
- Wrong configuration → update, don't delete/recreate
- Testing gates → use `--dry-run`, not real delete

---

## Approval Policy

### Who Can Approve

| Role | Scope | Notes |
|------|-------|-------|
| **Platform Lead** | Any production resource | Final authority |
| **Environment Owner** | Resources in their space | Must be designated in ConfigHub |
| **On-Call Engineer** | Any (during incident) | Time-bounded, requires post-incident review |
| **Security Team** | Security-related deletions | Required for compliance resources |

**Cannot approve**:
- The requester (no self-approval)
- Agents or automation
- Users without explicit role assignment

### Required Approvers by Resource Type

| Resource | Minimum Approvers | Required Roles |
|----------|-------------------|----------------|
| DynamoDB (customer data) | 2 | Platform Lead + Environment Owner |
| S3 (with PII) | 2 | Platform Lead + Security |
| S3 (artifacts only) | 1 | Environment Owner |
| Any prod resource | 1 | Platform Lead OR Environment Owner |

---

## Approval Request Process

### Step 1: Create Request

```yaml
# File: requests/delete-messagewall-prod-2026-01-19.yaml
apiVersion: confighub.io/v1alpha1
kind: GateOverrideRequest
metadata:
  name: delete-messagewall-prod-2026-01-19
spec:
  # What
  targetUnit: messagewall-prod
  targetSpace: messagewall-prod
  action: delete  # or: destroy

  # Why
  justification: |
    Decommissioning messagewall-prod as part of migration to new architecture.
    All data has been migrated to messagewall-v2-prod per MIGRATION-456.
    Backup verified at s3://backups/messagewall-prod-final-2026-01-19.tar.gz

  # Evidence
  ticketRef: "TICKET-789"
  migrationDoc: "docs/migrations/messagewall-v2.md"
  backupLocation: "s3://backups/messagewall-prod-final-2026-01-19.tar.gz"
  backupVerified: true

  # Scope limits
  validFrom: "2026-01-19T10:00:00Z"
  validUntil: "2026-01-19T18:00:00Z"  # 8-hour window

  # Rollback
  rollbackPlan: |
    1. Restore from backup: scripts/restore-from-backup.sh messagewall-prod
    2. Re-apply Claim: kubectl apply -f examples/claims/messagewall-prod.yaml
    3. Verify data: scripts/smoke-test.sh --env prod

  requester: "alice@example.com"
  requestedAt: "2026-01-19T09:00:00Z"
```

### Step 2: Submit for Approval

```bash
# Option A: GitHub PR (recommended for audit trail)
git checkout -b override/delete-messagewall-prod
cp requests/delete-messagewall-prod-2026-01-19.yaml .
git add . && git commit -m "chore: Request override for messagewall-prod deletion"
git push && gh pr create --title "Override: Delete messagewall-prod" \
  --body "See request YAML for justification and rollback plan"

# Option B: ConfigHub CLI
cub gate request \
  --space messagewall-prod \
  --unit messagewall-prod \
  --action delete \
  --justification "Decommissioning per TICKET-789" \
  --valid-hours 8
```

### Step 3: Approval Review

Approvers must verify:

| Check | Question |
|-------|----------|
| **Necessity** | Is deletion truly required? Can we archive instead? |
| **Data Safety** | Is data backed up? Has backup been verified? |
| **Timing** | Is the window appropriate? Not during peak hours? |
| **Rollback** | Is the rollback plan complete and tested? |
| **Authorization** | Does requester have business authority? |

### Step 4: Record Approval

```yaml
# Approver adds to the request
status:
  approvals:
    - approver: "bob@example.com"
      role: "Platform Lead"
      decision: approved
      timestamp: "2026-01-19T09:30:00Z"
      notes: "Verified backup exists and migration complete"
    - approver: "carol@example.com"
      role: "Environment Owner"
      decision: approved
      timestamp: "2026-01-19T09:45:00Z"
      notes: "Confirmed with product team"
  state: approved
  approvedAt: "2026-01-19T09:45:00Z"
```

### Step 5: Apply Override

```bash
# Add break-glass annotation to the Claim
kubectl annotate serverlesseventappclaim messagewall-prod \
  confighub.io/break-glass=approved \
  confighub.io/break-glass-reason="Decommissioning per TICKET-789" \
  confighub.io/break-glass-approver="bob@example.com,carol@example.com" \
  confighub.io/break-glass-expires="2026-01-19T18:00:00Z" \
  confighub.io/break-glass-request="delete-messagewall-prod-2026-01-19"
```

### Step 6: Execute Action

```bash
# Now deletion will succeed (within the approval window)
kubectl delete serverlesseventappclaim messagewall-prod

# Verify
kubectl get serverlesseventappclaim messagewall-prod
# Expected: "not found"
```

### Step 7: Post-Action Review

Within 24 hours:
1. Verify action completed as expected
2. Confirm no unintended side effects
3. Update ticket with completion status
4. Archive the approval request
5. Remove any temporary access grants

---

## Override Scope and Limits

### Time Bounds

| Override Type | Default Window | Maximum Window |
|---------------|----------------|----------------|
| Standard delete | 8 hours | 24 hours |
| Emergency (incident) | 4 hours | 8 hours |
| Bulk operation | 24 hours | 72 hours |

After expiration, break-glass annotation must be removed and re-requested.

### Scope Limits

Each override is scoped to:
- **One unit** (no wildcards)
- **One action** (delete OR destroy, not both)
- **One space** (no cross-space overrides)

Bulk deletions require separate approvals for each unit, or a bulk override request with higher approval threshold (Platform Lead + 2 Environment Owners).

---

## Audit Requirements

### What Is Logged

| Event | Data Captured |
|-------|---------------|
| Request created | Requester, target, justification, timestamp |
| Approval granted | Approver, role, notes, timestamp |
| Approval denied | Approver, role, reason, timestamp |
| Override applied | Who applied annotation, timestamp |
| Action executed | Who ran delete, timestamp, outcome |
| Override expired | Automatic, timestamp |

### Retention

- Override requests: 7 years (compliance)
- Approval records: 7 years
- Audit logs: 2 years minimum

### Access to Audit Trail

```bash
# List all override requests for a space
cub audit list --space messagewall-prod --type gate-override

# Get details of specific override
cub audit show delete-messagewall-prod-2026-01-19

# Export for compliance
cub audit export --space messagewall-prod --format csv --output overrides.csv
```

---

## Denial and Escalation

### If Approval Is Denied

1. Requester receives denial with reason
2. Requester may address concerns and re-request
3. Maximum 3 re-requests before escalation required

### Escalation Path

```
Environment Owner (denied)
    ↓
Platform Lead (appeal)
    ↓
VP Engineering (final appeal, rare)
```

### Emergency Escalation

During active incident:
1. On-call can grant temporary override (4 hours max)
2. Must document in incident ticket
3. Post-incident review required within 48 hours
4. Permanent approval may be sought after incident

---

## Quick Reference

### Approval Checklist

- [ ] Justification documented with ticket reference
- [ ] Backup verified and location documented
- [ ] Rollback plan written and reviewed
- [ ] Approval window is reasonable (not too long)
- [ ] Required approvers have signed off
- [ ] Break-glass annotation includes all required fields

### Required Annotations for Override

```yaml
annotations:
  confighub.io/break-glass: "approved"           # Required
  confighub.io/break-glass-reason: "..."         # Required
  confighub.io/break-glass-approver: "..."       # Required
  confighub.io/break-glass-expires: "..."        # Required (ISO 8601)
  confighub.io/break-glass-request: "..."        # Recommended (links to request)
```

---

## Summary

| Question | Answer |
|----------|--------|
| Who can approve? | Platform Lead, Environment Owner, On-Call (incident) |
| How many approvers? | 1-2 depending on resource sensitivity |
| How long is approval valid? | 8 hours default, 24 hours max |
| What's logged? | Everything: request, approval, execution, outcome |
| Can I self-approve? | No |

---

## References

- [Production Gates](production-gates.md) — Gate enforcement mechanism
- [Approval Gates](design-approval-gates.md) — General approval design
- [Precious Resources](precious-resources.md) — Resource classification
- [Risk Taxonomy](risk-taxonomy.md) — Risk classification
