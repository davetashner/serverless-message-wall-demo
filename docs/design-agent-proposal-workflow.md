# Design: Agent Proposal Workflow

This document defines how AI agents propose configuration changes without applying them directly. It implements ISSUE-15.2 by specifying the proposal format, storage mechanism, review process, and integration with the risk taxonomy.

**Status**: Design document for ISSUE-15.2
**Depends on**: [risk-taxonomy.md](risk-taxonomy.md) (ISSUE-15.1)

---

## Problem Statement

AI agents can analyze configurations, identify improvements, and generate valid changes. However, allowing agents to apply changes directly creates risk:

- **No human oversight**: Changes bypass review
- **Blast radius uncertainty**: Agents may not fully understand consequences
- **Trust calibration**: Agent reliability must be established over time

The solution is a **proposal workflow** where agents propose changes that humans (or policy gates) approve before application.

---

## Design Principles

1. **Agents propose, humans decide** (for HIGH risk changes)
2. **Proposals are first-class objects** with identity, attribution, and lifecycle
3. **Risk classification determines workflow** (from ISSUE-15.1)
4. **Proposals must be valid** — syntax and policy checks run at proposal time
5. **Audit trail is mandatory** — every proposal is recorded with provenance

---

## Proposal Format

A proposal is a structured object that describes an intended configuration change.

### Proposal Schema

```yaml
apiVersion: proposals.messagewall.demo/v1alpha1
kind: ConfigurationProposal
metadata:
  name: proposal-<uuid>
  labels:
    agent: <agent-identifier>
    target-claim: <claim-name>
    target-space: <confighub-space>
spec:
  # What is being changed
  target:
    kind: ServerlessEventAppClaim
    name: messagewall-prod
    space: messagewall-prod
    currentRevision: 42                    # Revision this proposal is based on

  # The change itself (one of: patch, replacement)
  change:
    type: patch                            # "patch" or "replacement"
    patch:                                 # JSON Patch format (RFC 6902)
      - op: replace
        path: /spec/lambdaMemory
        value: 512

  # Why the change is proposed
  rationale:
    summary: "Increase Lambda memory for improved cold start performance"
    details: |
      Analysis of CloudWatch metrics shows p99 cold start latency of 2.3s.
      Increasing memory from 256MB to 512MB typically reduces this by 40-50%
      based on Lambda's proportional CPU allocation.
    references:
      - type: metric
        source: cloudwatch
        id: "arn:aws:cloudwatch:us-east-1:123456789012:alarm/cold-start-latency"

  # Agent attribution
  proposer:
    type: agent
    id: "claude-code-session-abc123"
    model: "claude-opus-4-5-20251101"
    confidence: 0.85                       # Agent's self-assessed confidence (0-1)

status:
  # Computed by the system
  riskClass: MEDIUM                        # From risk taxonomy
  riskRationale: "LOW base (lambdaMemory) + prod elevator = MEDIUM"

  # Policy evaluation (run at proposal time)
  policyResult:
    outcome: PASS
    evaluatedAt: "2026-01-18T10:30:00Z"
    policies:
      - name: validate-claim-prod-requirements
        result: PASS
      - name: require-tags
        result: PASS

  # Lifecycle
  state: pending                           # pending | approved | rejected | applied | expired
  createdAt: "2026-01-18T10:30:00Z"
  expiresAt: "2026-01-25T10:30:00Z"        # Proposals expire after 7 days

  # Approval tracking (populated when approved/rejected)
  decision:
    outcome: null                          # approved | rejected
    decidedBy: null
    decidedAt: null
    reason: null
```

### Change Formats

#### JSON Patch (preferred for targeted changes)

```yaml
change:
  type: patch
  patch:
    - op: replace
      path: /spec/lambdaMemory
      value: 512
    - op: replace
      path: /spec/lambdaTimeout
      value: 60
```

#### Full Replacement (for complex restructuring)

```yaml
change:
  type: replacement
  replacement:
    apiVersion: messagewall.demo/v1alpha1
    kind: ServerlessEventAppClaim
    metadata:
      name: messagewall-prod
      namespace: default
    spec:
      environment: prod
      awsAccountId: "123456789012"
      lambdaMemory: 512
      lambdaTimeout: 60
      # ... full claim
```

---

## Proposal Lifecycle

```
Agent creates proposal
        │
        ▼
┌───────────────────┐
│ VALIDATION        │
│                   │
│ • Syntactically   │
│   valid?          │
│ • Target exists?  │
│ • Base revision   │
│   current?        │
└─────────┬─────────┘
          │ Valid
          ▼
┌───────────────────┐
│ POLICY EVALUATION │
│                   │
│ • Run ConfigHub   │
│   policies        │
│ • Record results  │
└─────────┬─────────┘
          │
    ┌─────┴─────┐
    │           │
  PASS        FAIL
    │           │
    ▼           ▼
┌─────────┐  ┌─────────┐
│ RISK    │  │ BLOCKED │
│ ASSESS  │  │         │
│         │  │ Agent   │
│ Compute │  │ must    │
│ risk    │  │ fix     │
│ class   │  │ config  │
└────┬────┘  └─────────┘
     │
     ▼
┌───────────────────────────────────────┐
│           PENDING STATE               │
│                                       │
│  Proposal awaits decision based on    │
│  risk class:                          │
│                                       │
│  LOW:    Auto-approve after 5 min     │
│          (allows human override)      │
│                                       │
│  MEDIUM: Notify operators, auto-      │
│          approve after 1 hour if no   │
│          objection                    │
│                                       │
│  HIGH:   Require explicit approval    │
│          No auto-approve              │
└─────────────────┬─────────────────────┘
                  │
          ┌───────┴───────┐
          │               │
      APPROVED        REJECTED
          │               │
          ▼               ▼
┌───────────────┐  ┌───────────────┐
│ APPLY         │  │ RECORD        │
│               │  │               │
│ Update        │  │ Log rejection │
│ ConfigHub     │  │ with reason   │
│ Live revision │  │               │
└───────────────┘  └───────────────┘
```

---

## Proposal Storage

Proposals can be stored in multiple locations depending on integration depth:

### Option A: ConfigHub Proposals (Preferred)

Store proposals as ConfigHub objects in a dedicated `proposals` space:

```bash
# Agent creates proposal
cub unit create \
  --space messagewall-proposals \
  --kind ConfigurationProposal \
  --name proposal-abc123 \
  --file proposal.yaml

# List pending proposals
cub unit list \
  --space messagewall-proposals \
  --where "status.state=pending"

# Approve proposal
cub proposal approve proposal-abc123 --reason "Reviewed metrics, change is justified"
```

**Benefits**:
- Full ConfigHub history and auditability
- Policy enforcement at proposal time
- Native integration with ConfigHub workflows

### Option B: Git Pull Requests (Alternative)

Store proposals as PRs against the Claims repository:

```bash
# Agent creates branch and PR
git checkout -b agent/proposal-abc123
# ... modify claim file ...
git commit -m "Proposal: Increase prod Lambda memory to 512MB"
git push origin agent/proposal-abc123
gh pr create --title "Agent Proposal: ..." --body "$(cat proposal-metadata.md)"
```

**Benefits**:
- Familiar PR review workflow
- Works without ConfigHub proposal feature
- GitHub/GitLab native approvals

**Limitations**:
- No structured proposal schema (metadata in PR body)
- Harder to query across proposals
- Risk classification must be computed by CI

### Recommended Approach

**Phase 1**: Use Git PRs with structured proposal metadata in PR description. Label PRs by risk class.

**Phase 2**: When ConfigHub supports proposals natively, migrate to Option A.

---

## Risk Classification Integration

Proposals are classified using the risk taxonomy from ISSUE-15.1.

### Classification at Proposal Time

```python
def classify_proposal(proposal):
    """Compute effective risk class for a proposal."""

    # Extract changed fields from patch
    changed_fields = extract_changed_fields(proposal.change)

    # Get base risk from schema mapping
    base_risks = [FIELD_RISK_MAP[field] for field in changed_fields]
    highest_base = max(base_risks, key=risk_order)

    # Apply elevators
    effective = highest_base

    # Production elevator
    if proposal.target.environment == "prod":
        effective = elevate(effective)

    # Deletion elevator
    if proposal.change.type == "delete":
        effective = "HIGH"

    return effective
```

### Workflow by Risk Class

| Risk Class | Notification | Auto-Approve | Approval Required |
|------------|--------------|--------------|-------------------|
| LOW | Optional | Yes (5 min delay) | No |
| MEDIUM | Required (immediate) | Yes (1 hour delay) | No |
| HIGH | Required (immediate) | No | Yes (explicit) |

### Example: Agent Proposes Memory Increase in Prod

```yaml
# Proposal
spec:
  target:
    name: messagewall-prod
  change:
    patch:
      - op: replace
        path: /spec/lambdaMemory
        value: 512

# Risk calculation
# lambdaMemory base risk: LOW
# + production elevator: +1 level
# = Effective risk: MEDIUM

status:
  riskClass: MEDIUM
  riskRationale: "LOW base (lambdaMemory) + prod elevator = MEDIUM"
```

Result: Operators are notified. If no objection in 1 hour, proposal auto-applies.

---

## Review Interface

### CLI Review

```bash
# List pending proposals
proposals list --pending

# Show proposal details
proposals show proposal-abc123

# Approve with reason
proposals approve proposal-abc123 \
  --reason "Reviewed agent analysis, change is justified"

# Reject with reason
proposals reject proposal-abc123 \
  --reason "Insufficient evidence for memory increase. Need load test data."
```

### Dashboard View (Future)

A proposals dashboard would show:
- Pending proposals sorted by risk class (HIGH first)
- Agent attribution and confidence scores
- Policy evaluation results
- Diff preview (current → proposed)
- Approve/reject buttons with reason prompt

---

## Agent Constraints

### What Agents Can Do

- Create proposals for any valid configuration change
- Include rationale and supporting evidence
- Set confidence level for their proposals
- Create multiple related proposals as a batch

### What Agents Cannot Do

- Apply proposals directly (bypass approval)
- Approve their own proposals
- Modify proposals after submission (must create new proposal)
- Delete or expire proposals (system-managed)

### Agent Identification

Each proposal includes agent attribution:

```yaml
proposer:
  type: agent                              # "agent" | "human" | "automation"
  id: "claude-code-session-abc123"         # Session/instance identifier
  model: "claude-opus-4-5-20251101"        # Model identifier
  confidence: 0.85                         # Self-assessed confidence
```

This enables:
- Auditing which agent proposed what
- Confidence-based filtering (low confidence → require review)
- Agent reliability tracking over time

---

## Proposal Expiration

Proposals expire after 7 days if not acted upon. This prevents:
- Stale proposals from accumulating
- Proposals based on outdated revisions from being applied
- Decision fatigue from large proposal backlogs

### Expiration Behavior

```
Proposal created (state: pending)
        │
        ├── 7 days pass, no decision
        │
        ▼
Proposal expires (state: expired)
        │
        ▼
Agent notified: "Proposal expired. Create new proposal if still needed."
```

### Revision Staleness

If the target Claim's revision advances while a proposal is pending:

```yaml
# Proposal was based on revision 42
spec:
  target:
    currentRevision: 42

# But Claim is now at revision 45
```

Options:
1. **Block apply**: Require agent to rebase proposal on latest revision
2. **Merge if compatible**: Apply patch if no conflicts
3. **Warn and proceed**: Apply with warning about skipped revisions

**Recommendation**: Block apply (Option 1). Forces agent to re-evaluate proposal against current state.

---

## Integration Points

### With ISSUE-15.3 (Human Approval for HIGH Risk)

This design provides the proposal objects that ISSUE-15.3 gates with approval requirements.

```
Proposal (this issue)  →  Approval Gate (15.3)  →  Apply
```

### With ISSUE-15.13 (Approval Fatigue)

The auto-approve delays for LOW/MEDIUM risk reduce approval volume. Only HIGH risk proposals require explicit approval, addressing fatigue concerns.

### With ISSUE-15.14 (Machine-Verifiable Invariants)

Proposals include policy evaluation results. Future invariants could enable:
- Agent-to-agent approval within strict bounds
- Automatic approval if invariants guarantee safety

---

## Open Questions

### 1. Batch Proposals

Should agents be able to submit multiple related proposals as a batch?

**Proposed answer**: Yes. Batch proposals share a common rationale and are approved/rejected together. The batch risk class is the highest of any component.

### 2. Proposal Amendments

Can a proposal be amended after submission?

**Proposed answer**: No. Create a new proposal and let the old one expire. This preserves audit trail integrity.

### 3. Competing Proposals

What if two proposals target the same field?

**Proposed answer**: First approved wins. The second proposal becomes stale (revision mismatch) and must be rebased.

---

## Implementation Phases

### Phase 1: Git PR-Based Proposals (MVP)

- Agents create PRs with proposal metadata in description
- CI computes risk class and adds label
- GitHub/GitLab reviews serve as approval
- Merge = approve, close without merge = reject

### Phase 2: ConfigHub Native Proposals

- Proposals stored as ConfigHub objects
- Native approval workflow in ConfigHub
- CLI and dashboard support

### Phase 3: Confidence-Based Automation

- High-confidence LOW risk proposals auto-apply immediately
- Agent reliability scores inform approval thresholds
- Anomaly detection flags unusual proposals for review

---

## References

- [Risk Taxonomy](risk-taxonomy.md) — Risk class definitions (ISSUE-15.1)
- [ADR-011: Bidirectional GitOps](decisions/011-ci-confighub-authority-conflict.md) — Proposal concept for CI
- [ADR-010: ConfigHub Stores Claims](decisions/010-confighub-claim-vs-expanded.md) — What proposals target
- [Design: Policy to Risk Class Mapping](design-policy-risk-class-mapping.md) — Policy integration
