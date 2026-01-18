# Design: Approval Gates for High-Risk Changes

This document defines the explicit approval mechanism that gates application of high-risk configuration changes. It implements ISSUE-15.3 by specifying when approvals are required, who can approve, and how the approval workflow operates.

**Status**: Design document for ISSUE-15.3
**Depends on**:
- [risk-taxonomy.md](risk-taxonomy.md) (ISSUE-15.1)
- [design-agent-proposal-workflow.md](design-agent-proposal-workflow.md) (ISSUE-15.2)

---

## Problem Statement

The risk taxonomy (ISSUE-15.1) classifies changes as LOW, MEDIUM, or HIGH risk. The proposal workflow (ISSUE-15.2) allows agents to propose changes without applying them directly.

This issue completes the picture by defining:
1. **When** approvals are required (risk class → approval requirement)
2. **Who** can approve (approver roles and permissions)
3. **How** the approval gate blocks and releases changes

---

## Core Principle

**Policy enforcement is automated. Approval is human judgment.**

```
┌─────────────────────────────────────────────────────────────────┐
│                      POLICY ENFORCEMENT                         │
│                                                                  │
│   Question: "Is this configuration valid?"                       │
│   Answer: PASS / FAIL (deterministic)                           │
│   Authority: Policies (machine-verifiable rules)                │
│   Override: Change the policy (with review)                     │
│                                                                  │
│   Blocking: Always. Invalid = blocked. No exceptions.           │
└─────────────────────────────────────────────────────────────────┘
                              │
                              │ If PASS and HIGH risk:
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                       APPROVAL GATE                             │
│                                                                  │
│   Question: "Should we apply this change now?"                  │
│   Answer: APPROVED / REJECTED (judgment)                        │
│   Authority: Designated approvers (humans)                      │
│   Override: N/A (approval is the override mechanism)            │
│                                                                  │
│   Blocking: Only for HIGH risk. LOW/MEDIUM can auto-approve.   │
└─────────────────────────────────────────────────────────────────┘
```

---

## Approval Requirements by Risk Class

| Risk Class | Approval Required | Behavior |
|------------|-------------------|----------|
| **LOW** | No | Apply automatically after 5-minute delay |
| **MEDIUM** | No | Apply automatically after 1-hour delay (with notification) |
| **HIGH** | **Yes** | Blocked until explicit human approval |

### LOW Risk: Auto-Apply

```
Proposal (LOW risk)
        │
        ▼
Policy check: PASS
        │
        ▼
5-minute delay (allows human override)
        │
        ├── Human approves early → Apply immediately
        ├── Human rejects → Do not apply
        └── No action → Auto-apply after 5 minutes
```

**Rationale**: LOW risk changes are safe enough that blocking on approval would create friction without meaningful safety benefit. The 5-minute delay provides a window for humans to intervene if they're watching.

### MEDIUM Risk: Auto-Apply with Notification

```
Proposal (MEDIUM risk)
        │
        ▼
Policy check: PASS
        │
        ▼
Notify operators immediately
        │
        ▼
1-hour delay
        │
        ├── Human approves early → Apply immediately
        ├── Human rejects → Do not apply
        └── No action → Auto-apply after 1 hour
```

**Rationale**: MEDIUM risk changes warrant awareness but not blocking. Operators are notified and can intervene if needed. The 1-hour window balances safety with operational velocity.

### HIGH Risk: Explicit Approval Required

```
Proposal (HIGH risk)
        │
        ▼
Policy check: PASS
        │
        ▼
Notify operators immediately
        │
        ▼
┌────────────────────────────┐
│   APPROVAL GATE (BLOCKED)  │
│                            │
│   Waiting for explicit     │
│   human approval           │
│                            │
│   Will NOT auto-apply      │
└─────────────┬──────────────┘
              │
      ┌───────┴───────┐
      │               │
  APPROVED        REJECTED
      │               │
      ▼               ▼
   Apply         Do not apply
```

**Rationale**: HIGH risk changes could cause outages, data loss, or security issues. These require a human to consciously decide "yes, do this now." No timeout, no auto-approve.

---

## Approval Workflow

### Step 1: Proposal Creation

Agent or CI creates a proposal (per ISSUE-15.2):

```yaml
apiVersion: proposals.messagewall.demo/v1alpha1
kind: ConfigurationProposal
metadata:
  name: proposal-abc123
spec:
  target:
    kind: ServerlessEventAppClaim
    name: messagewall-prod
  change:
    type: patch
    patch:
      - op: replace
        path: /spec/region
        value: eu-west-1
  rationale:
    summary: "Migrate production to EU region for GDPR compliance"
```

### Step 2: Risk Assessment

System computes risk class:

```yaml
status:
  riskClass: HIGH
  riskRationale: "region change (MEDIUM base) + prod elevator = HIGH"
```

### Step 3: Approval Request

For HIGH risk, an approval request is created:

```yaml
apiVersion: approvals.messagewall.demo/v1alpha1
kind: ApprovalRequest
metadata:
  name: approval-for-proposal-abc123
spec:
  proposal: proposal-abc123
  riskClass: HIGH

  # What's being requested
  summary: "Migrate messagewall-prod region from us-east-1 to eu-west-1"
  impact: |
    - All resource ARNs will change
    - ~5 minute downtime during migration
    - Data will remain in DynamoDB (region change only affects new resources)

  # Who should approve
  requiredApprovers:
    - role: platform-operator
      count: 1

  # Notification targets
  notify:
    - channel: slack
      target: "#platform-alerts"
    - channel: email
      target: "platform-team@example.com"

status:
  state: pending                           # pending | approved | rejected
  approvals: []
  createdAt: "2026-01-18T10:30:00Z"
```

### Step 4: Approval Decision

An authorized approver reviews and decides:

```bash
# View pending approval requests
approvals list --pending

# Output:
# NAME                          PROPOSAL              RISK   AGE    APPROVERS
# approval-for-proposal-abc123  proposal-abc123       HIGH   5m     0/1

# Show details
approvals show approval-for-proposal-abc123

# Approve
approvals approve approval-for-proposal-abc123 \
  --reason "GDPR deadline is Jan 30. Reviewed migration plan. Approved."

# Or reject
approvals reject approval-for-proposal-abc123 \
  --reason "Need load test results in EU region first."
```

### Step 5: Application

On approval, the proposal is applied:

```yaml
status:
  state: approved
  approvals:
    - approver: "alice@example.com"
      role: platform-operator
      decidedAt: "2026-01-18T11:45:00Z"
      reason: "GDPR deadline is Jan 30. Reviewed migration plan. Approved."
  appliedAt: "2026-01-18T11:45:01Z"
  resultingRevision: 43
```

---

## Approver Roles

### Who Can Approve?

| Role | Can Approve | Scope |
|------|-------------|-------|
| Platform Operator | Yes | All spaces |
| Environment Owner | Yes | Their environment only |
| On-Call Engineer | Yes | Any (during their rotation) |
| Agent | **No** | Agents cannot approve anything |
| CI/Automation | **No** | Only humans can approve |

### Role Assignment

Approver roles are assigned per-space in ConfigHub:

```yaml
# Space configuration
apiVersion: confighub.io/v1
kind: Space
metadata:
  name: messagewall-prod
spec:
  approvers:
    - identity: "alice@example.com"
      role: environment-owner
    - identity: "platform-team@example.com"
      role: platform-operator
    - identity: "oncall@example.com"
      role: on-call-engineer
```

### Escalation

If an approval request is pending for more than:
- 4 hours: Escalate to secondary on-call
- 24 hours: Escalate to platform lead
- 7 days: Auto-reject with "expired" reason

---

## Approval Record

Every approval decision is recorded with full attribution:

```yaml
status:
  approvals:
    - approver: "alice@example.com"
      role: platform-operator
      decidedAt: "2026-01-18T11:45:00Z"
      decision: approved
      reason: "GDPR deadline is Jan 30. Reviewed migration plan. Approved."
      metadata:
        sessionId: "github-oauth-session-xyz"
        ipAddress: "10.0.1.42"
        userAgent: "Mozilla/5.0..."
```

This provides:
- **Accountability**: Who approved what and when
- **Audit trail**: For compliance and post-incident review
- **Reason capture**: Understanding the "why" for future reference

---

## Blocking Behavior

### HIGH Risk Without Approval

When a HIGH risk proposal is created:

1. **State**: Proposal enters `pending` state
2. **Blocking**: Proposal cannot progress to `applied` state
3. **Visibility**: Appears in "pending approvals" queue
4. **Notifications**: Approvers are notified immediately
5. **Timeout**: No auto-approve. Remains blocked indefinitely until decision.

```
┌─────────────────────────────────────────────────────────────────┐
│                        BLOCKED STATE                            │
│                                                                  │
│  Proposal: proposal-abc123                                       │
│  Risk Class: HIGH                                                │
│  Status: PENDING APPROVAL                                        │
│                                                                  │
│  This proposal cannot be applied without explicit approval.     │
│                                                                  │
│  Required: 1 approver from [platform-operator, env-owner]       │
│  Current approvals: 0                                            │
│                                                                  │
│  Actions:                                                        │
│    → approvals approve approval-for-proposal-abc123             │
│    → approvals reject approval-for-proposal-abc123              │
└─────────────────────────────────────────────────────────────────┘
```

### Attempting to Bypass

If someone attempts to apply a HIGH risk change without approval:

```bash
# Attempt to force apply
cub unit apply messagewall-prod --revision 43 --force

# Result:
# ERROR: Revision 43 contains HIGH risk changes requiring approval.
#        Approval request: approval-for-proposal-abc123
#        Status: pending (0/1 approvals)
#
# To proceed, an authorized approver must run:
#   approvals approve approval-for-proposal-abc123
#
# The --force flag does not bypass approval requirements.
```

**There is no bypass.** HIGH risk changes require approval. Period.

---

## Emergency Override

For true emergencies where approval is impossible:

### Break-Glass Procedure

```bash
# 1. Document the emergency
echo "Emergency: Production down. Must revert region change immediately." > /tmp/emergency.txt

# 2. Execute break-glass command (requires special credentials)
cub break-glass apply \
  --space messagewall-prod \
  --reason "$(cat /tmp/emergency.txt)" \
  --file emergency-fix.yaml

# 3. Post-incident: Break-glass is captured and creates an approval request retroactively
```

**Break-glass does not bypass the audit trail.** It applies immediately but:
- Logs the action with emergency flag
- Creates a retroactive approval request
- Notifies all platform operators
- Requires post-incident review

See ISSUE-17.4 (EPIC-17) for detailed break-glass workflow.

---

## Implementation: Git PR-Based Approvals (Phase 1)

For the MVP, approvals are implemented via GitHub PR reviews:

### Mapping

| Concept | GitHub Implementation |
|---------|----------------------|
| Proposal | Pull Request |
| Risk Class | PR Label (`risk:low`, `risk:medium`, `risk:high`) |
| Approval Request | PR marked with `approval-required` label |
| Approver | GitHub user in CODEOWNERS for the path |
| Approval | GitHub PR approval |
| Rejection | GitHub PR rejection or close |
| Applied | PR merged |

### Workflow

```yaml
# .github/workflows/proposal-approval.yaml
name: Proposal Approval Gate

on:
  pull_request:
    types: [opened, labeled, synchronize]

jobs:
  risk-assessment:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Compute risk class
        id: risk
        run: |
          # Analyze changed Claims, compute risk class
          RISK=$(./scripts/compute-proposal-risk.sh)
          echo "risk=$RISK" >> $GITHUB_OUTPUT

      - name: Apply risk label
        run: gh pr edit ${{ github.event.number }} --add-label "risk:${{ steps.risk.outputs.risk }}"

      - name: Require approval for HIGH risk
        if: steps.risk.outputs.risk == 'high'
        run: |
          gh pr edit ${{ github.event.number }} --add-label "approval-required"
          gh pr comment ${{ github.event.number }} --body "⚠️ **HIGH RISK CHANGE** - Requires explicit approval from a platform operator before merge."

  block-without-approval:
    runs-on: ubuntu-latest
    if: contains(github.event.pull_request.labels.*.name, 'risk:high')
    steps:
      - name: Check for approval
        run: |
          APPROVALS=$(gh pr view ${{ github.event.number }} --json reviews --jq '[.reviews[] | select(.state == "APPROVED")] | length')
          if [ "$APPROVALS" -lt 1 ]; then
            echo "::error::HIGH risk change requires at least 1 approval"
            exit 1
          fi
```

### CODEOWNERS for Approval Authority

```
# Platform operators can approve any Claims
examples/claims/*.yaml @platform-team

# Production requires additional approval
examples/claims/messagewall-prod.yaml @platform-team @prod-approvers
```

---

## Metrics and Monitoring

Track approval workflow health:

| Metric | Description | Alert Threshold |
|--------|-------------|-----------------|
| `approvals_pending_count` | Number of pending approvals | > 10 |
| `approvals_pending_age_hours` | Age of oldest pending approval | > 24 hours |
| `approvals_time_to_decision_p50` | Median time from request to decision | > 4 hours |
| `approvals_rejected_ratio` | Ratio of rejected to total decisions | > 30% |
| `approvals_auto_applied_ratio` | Ratio of auto-applied (LOW/MEDIUM) to total | < 50% (may indicate risk class miscalibration) |

---

## Summary

| Risk Class | Approval Required | Auto-Apply | Timeout |
|------------|-------------------|------------|---------|
| LOW | No | Yes (after 5 min) | N/A |
| MEDIUM | No | Yes (after 1 hour) | N/A |
| HIGH | **Yes** | **Never** | 7 days (then expires) |

**Key guarantees**:
1. HIGH risk changes are blocked without approval
2. LOW risk changes apply without blocking
3. Approval decisions are fully auditable
4. Agents cannot approve—only humans can

---

## References

- [Risk Taxonomy](risk-taxonomy.md) — Risk class definitions (ISSUE-15.1)
- [Agent Proposal Workflow](design-agent-proposal-workflow.md) — Proposal format and lifecycle (ISSUE-15.2)
- [Platform Invariants](invariants.md) — Invariant 9: High-risk changes require human approval
- EPIC-17: Production Protection — Delete/destroy gates (related approval workflow)
