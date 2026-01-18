# Design: Policy to Risk Class Mapping

This document bridges EPIC-14 (policy guardrails) and EPIC-15 (agent-human boundaries) by defining how policies map to risk classes and how violations escalate to approval workflows.

**Status**: Design document for ISSUE-14.7 (superseded by [risk-taxonomy.md](risk-taxonomy.md) for risk class definitions)
**See also**: [risk-taxonomy.md](risk-taxonomy.md) — Authoritative risk class reference (ISSUE-15.1)

---

## Problem Statement

EPIC-14 implemented automated policy enforcement at multiple layers (ConfigHub, Kyverno). EPIC-15 introduces the concept of risk-based approval workflows where agents can propose changes but humans decide on high-risk operations.

The question this document answers: **How do policies connect to risk classes, and when does a policy violation or risk classification require human intervention?**

---

## Risk Class Definitions

Risk classes categorize configuration changes by their potential for harm. These definitions will be formalized in ISSUE-15.1; this document provides the working model.

### Low Risk

**Criteria:**
- Change is easily reversible (seconds to minutes)
- Blast radius is limited to a single non-stateful resource
- Change is within established bounds/constraints
- No security posture impact
- No data loss potential

**Examples:**
- Adjusting Lambda memory within bounds (128-1024 MB)
- Adjusting Lambda timeout within bounds (1-60 seconds)
- Changing `resourcePrefix` for a new deployment
- Updating `eventSource` identifier

**Agent authority**: Agents may apply low-risk changes without human approval if all policies pass.

---

### Medium Risk

**Criteria:**
- Change affects multiple resources or crosses component boundaries
- Change has moderate blast radius (environment-scoped)
- Reversal is possible but may require coordination
- May trigger environment-specific policy constraints

**Examples:**
- Changing `environment` field (dev → staging)
- Changing `region` (affects all resource ARNs)
- Initial deployment of a new Claim
- Changes that approach but don't exceed policy thresholds

**Agent authority**: Agents may apply medium-risk changes with notification to operators. No blocking approval required unless policy fails.

---

### High Risk

**Criteria:**
- Change is irreversible or expensive to reverse
- Change affects security posture (IAM, encryption, access control)
- Change could result in data loss or service outage
- Change targets production environment
- Change modifies permission boundaries or trust relationships

**Examples:**
- Any IAM policy modification (expanding or restricting permissions)
- Disabling encryption on stateful resources
- Production Lambda memory/timeout changes
- Resource deletion
- Environment promotion (staging → prod)

**Agent authority**: Agents may **propose** high-risk changes but cannot apply them without explicit human approval.

---

## Schema Field to Risk Class Mapping

Each field in the `ServerlessEventAppClaim` schema is assigned a base risk class. The effective risk may be elevated by context (e.g., production environment).

| Field | Base Risk | Production Risk | Notes |
|-------|-----------|-----------------|-------|
| `awsAccountId` | HIGH | HIGH | Immutable after creation; wrong value is catastrophic |
| `environment` | MEDIUM | N/A | Changing to/from prod elevates to HIGH |
| `resourcePrefix` | LOW | MEDIUM | Affects resource naming; prod changes higher risk |
| `region` | MEDIUM | HIGH | Affects all ARNs; may trigger cross-region issues |
| `lambdaMemory` | LOW | MEDIUM | Within bounds is low risk; prod needs oversight |
| `lambdaTimeout` | LOW | MEDIUM | Within bounds is low risk; prod needs oversight |
| `eventSource` | LOW | LOW | Identifier only; no security impact |
| `artifactBucket` | MEDIUM | HIGH | Affects code deployment source |

### Context Elevators

Certain contexts automatically elevate risk class:

1. **Production environment**: Any change to a `environment: prod` Claim elevates by one level (LOW→MEDIUM, MEDIUM→HIGH)
2. **New creation vs. modification**: Creating a new Claim is generally MEDIUM; modifying existing is context-dependent
3. **Deletion**: Always HIGH regardless of other factors

---

## Policy to Risk Class Mapping

Each EPIC-14 policy enforces constraints that correspond to risk classes. Policies don't *assign* risk classes—they *enforce thresholds* within them.

### Kyverno Policies (Actuation Layer)

| Policy | Severity | Risk Class Enforced | What It Prevents |
|--------|----------|---------------------|------------------|
| `validate-iam-no-wildcards` | Critical | HIGH | Privilege escalation via wildcard IAM |
| `audit-broad-iam-permissions` | Medium | LOW (audit only) | Warns about service-level wildcards |
| `validate-claim-prod-requirements` | High | HIGH | Under-provisioned production workloads |
| `validate-encryption-at-rest` | High | HIGH | Unencrypted data in production |
| `validate-s3-versioning` | Medium | MEDIUM (audit) | Missing rollback capability |
| `validate-aws-tags` | Medium | MEDIUM | Untracked resources (cost/ownership) |
| `mutate-aws-tags` | N/A | N/A | Mutation, not validation |

### ConfigHub Policies (Authority Layer)

| Policy | Risk Class Enforced | What It Prevents |
|--------|---------------------|------------------|
| `require-tags.rego` | MEDIUM | Missing required fields (environment, accountId) |
| `prod-requirements.rego` | HIGH | Under-provisioned production workloads |

---

## Escalation Model

This section defines how policy outcomes and risk classes combine to determine whether human approval is required.

### Decision Matrix

```
                    ┌─────────────────────────────────────────────────┐
                    │           POLICY OUTCOME                        │
                    ├───────────────┬─────────────────┬───────────────┤
                    │  PASS         │  WARN           │  FAIL         │
┌───────────────────┼───────────────┼─────────────────┼───────────────┤
│ LOW Risk          │ Auto-apply    │ Auto-apply      │ BLOCKED       │
│                   │               │ + log warning   │ (must fix)    │
├───────────────────┼───────────────┼─────────────────┼───────────────┤
│ MEDIUM Risk       │ Apply +       │ Apply +         │ BLOCKED       │
│                   │ notify        │ notify + warn   │ (must fix)    │
├───────────────────┼───────────────┼─────────────────┼───────────────┤
│ HIGH Risk         │ APPROVAL      │ APPROVAL        │ BLOCKED       │
│                   │ REQUIRED      │ REQUIRED        │ (must fix)    │
└───────────────────┴───────────────┴─────────────────┴───────────────┘
```

### Key Principles

1. **Policy violations always block.** No amount of human approval can override a failing policy. The policy must be updated or the configuration fixed.

2. **Policies are automated; approvals are human.** Policies enforce machine-verifiable constraints. Approvals handle context that machines cannot assess (business justification, timing, coordination).

3. **Risk class determines approval, not policy severity.** A "critical" severity policy doesn't mean the change requires approval—it means violations are blocked with prejudice. Approval requirements come from risk classification of the *change*, not the *policy*.

4. **Warnings are informational, not blocking.** Audit-mode policies (like `audit-broad-iam-permissions`) surface concerns but don't prevent changes.

---

## Escalation Workflows

### Low Risk: Auto-Apply

```
Agent/CI proposes change
        │
        ▼
Policy evaluation (ConfigHub + Kyverno)
        │
    ┌───┴───┐
    │ PASS? │
    └───┬───┘
        │ Yes
        ▼
Apply automatically
        │
        ▼
Log change (audit trail)
```

### Medium Risk: Apply with Notification

```
Agent/CI proposes change
        │
        ▼
Policy evaluation
        │
    ┌───┴───┐
    │ PASS? │
    └───┬───┘
        │ Yes
        ▼
Apply change
        │
        ▼
Notify operators (Slack, email, dashboard)
        │
        ▼
Log change with notification receipt
```

### High Risk: Approval Required

```
Agent/CI proposes change
        │
        ▼
Policy evaluation
        │
    ┌───┴───┐
    │ PASS? │
    └───┬───┘
        │ Yes
        ▼
Create approval request
        │
        ▼
┌───────────────────────────────────┐
│  APPROVAL GATE                    │
│                                   │
│  - Shows proposed change          │
│  - Shows risk classification      │
│  - Shows policy evaluation        │
│  - Requires explicit approval     │
└─────────────┬─────────────────────┘
              │
      ┌───────┴───────┐
      │   Approved?   │
      └───────┬───────┘
              │ Yes
              ▼
Apply change
              │
              ▼
Log approval + change
```

### Policy Failure: Blocked

```
Agent/CI proposes change
        │
        ▼
Policy evaluation
        │
    ┌───┴───┐
    │ PASS? │
    └───┬───┘
        │ No
        ▼
REJECT with policy violation message
        │
        ▼
Agent/developer must fix configuration
```

---

## Boundary: Policy Enforcement vs. Human Approval

This is a critical distinction for EPIC-15 implementation.

### Policy Enforcement (Automated)

**What it does:**
- Evaluates configuration against declarative rules
- Blocks violations with immediate, deterministic feedback
- Runs at every layer (CI, ConfigHub, Kyverno)
- Cannot be overridden without changing the policy

**What it cannot do:**
- Assess business justification
- Evaluate timing ("is 2am a good time for this change?")
- Coordinate with external systems or people
- Make judgment calls on edge cases

**Owned by:** Platform team (policy authors)

### Human Approval (Judgment)

**What it does:**
- Reviews proposed changes in context
- Evaluates business justification
- Considers timing and coordination
- Approves or rejects based on factors policies can't capture

**What it cannot do:**
- Override policy violations (must fix or update policy)
- Be automated away (by definition)
- Scale infinitely (approval fatigue is real—see ISSUE-15.13)

**Owned by:** Operators, on-call engineers, designated approvers

### The Boundary

```
┌─────────────────────────────────────────────────────────────────┐
│                         POLICY ENFORCEMENT                       │
│                                                                  │
│   "Is this configuration valid according to our rules?"         │
│                                                                  │
│   Inputs: Configuration, policy rules                           │
│   Output: PASS / WARN / FAIL                                    │
│   Authority: Platform team                                       │
│   Override: Change the policy (with review)                     │
└─────────────────────────────────────────────────────────────────┘
                              │
                              │ If PASS and HIGH risk:
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                         HUMAN APPROVAL                           │
│                                                                  │
│   "Should we apply this change right now?"                      │
│                                                                  │
│   Inputs: Proposed change, policy results, context              │
│   Output: APPROVED / REJECTED                                   │
│   Authority: Designated approvers                               │
│   Override: N/A (judgment by definition)                        │
└─────────────────────────────────────────────────────────────────┘
```

### When Approvals Become Theater

See ISSUE-15.13 for detailed analysis. Key warning signs:

- **Volume**: More than ~10 approval requests per day leads to rubber-stamping
- **Uniformity**: If 99% of requests are approved, the gate provides false confidence
- **Complexity**: If approvers can't understand what they're approving, they're not really deciding

Mitigations (to be designed in EPIC-15):
- Aggregate related changes into single approval requests
- Confidence thresholds: auto-approve if risk model confidence is high
- Escalation-only: only surface changes the system is uncertain about

---

## Integration Points

### EPIC-15 Issues That Build on This Design

| Issue | How It Uses This Design |
|-------|-------------------------|
| ISSUE-15.1 | Formalizes risk class definitions from this document |
| ISSUE-15.2 | Implements agent proposal workflow using escalation model |
| ISSUE-15.3 | Implements approval gate for HIGH risk changes |
| ISSUE-15.13 | Addresses approval fatigue identified in boundary section |
| ISSUE-15.14 | Explores machine-verifiable invariants as policy alternatives |

### EPIC-17 Issues (Production Protection)

| Issue | How It Relates |
|-------|----------------|
| ISSUE-17.3 | Delete/destroy gates are HIGH risk by definition |
| ISSUE-17.4 | Approval workflow for gated operations follows this model |

---

## Open Questions for EPIC-15

1. **Risk assessment automation**: Should risk class be computed from the change diff, or declared in the schema? Computed is more accurate but complex; declared is simpler but may miss context.

2. **Multi-change aggregation**: If an agent proposes 10 low-risk changes and 1 high-risk change together, does the batch require approval? (Proposed: yes, the highest risk in the batch determines the batch risk.)

3. **Approval delegation**: Can approvers delegate to other humans? To agents with high confidence? This affects ISSUE-15.14.

4. **Time-based risk**: Should changes during maintenance windows have lower effective risk? This is complex but may reduce approval fatigue.

---

## References

- [EPIC-14: Policy Guardrails](../beads/backlog.jsonl) - Source policies
- [EPIC-15: Agent-Human Boundaries](../beads/backlog.jsonl) - Consumer of this design
- [EPIC-17: Production Protection](../beads/backlog.jsonl) - Uses HIGH risk classification
- [Policy Guardrails Demo](demo-policy-guardrails.md) - Policy behavior examples
- [Four-Plane Model](planes.md) - Policy enforcement layers
- [Platform Invariants](invariants.md) - Invariant 9 (high-risk approval requirement)
