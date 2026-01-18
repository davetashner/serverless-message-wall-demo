# Risk Taxonomy for Configuration Changes

This document formally defines how configuration changes are classified by risk level, determining the level of automation and human oversight required for each change.

**Status**: Authoritative reference (ISSUE-15.1)
**Supersedes**: Working model in [design-policy-risk-class-mapping.md](design-policy-risk-class-mapping.md)

---

## Purpose

When agents or automation propose configuration changes, the platform must decide:
1. Can this change be applied automatically?
2. Does it require human notification?
3. Does it require human approval?

This taxonomy provides clear, testable criteria for classifying any configuration change into a risk level that determines the answer.

---

## Risk Classes

### LOW Risk

Changes that are safe to apply automatically without human involvement.

**Criteria** (all must be true):
- [ ] Reversible within seconds to minutes
- [ ] Affects a single, non-stateful resource
- [ ] Stays within established bounds/constraints
- [ ] No security posture impact
- [ ] No data loss potential
- [ ] Does not affect production environment

**Agent Authority**: Agents may apply LOW risk changes without human approval if all policies pass.

**Notification**: Optional (may be batched into daily summaries).

**Examples**:
- Adjusting `lambdaMemory` from 128 to 256 in dev environment
- Adjusting `lambdaTimeout` from 10 to 15 in dev environment
- Changing `eventSource` identifier

---

### MEDIUM Risk

Changes that are likely safe but warrant human awareness.

**Criteria** (any of these):
- [ ] Affects multiple resources or crosses component boundaries
- [ ] Has moderate blast radius (environment-scoped)
- [ ] Reversal is possible but requires coordination
- [ ] Approaches policy thresholds without exceeding them
- [ ] Targets staging environment

**Agent Authority**: Agents may apply MEDIUM risk changes with notification. No blocking approval required unless policy fails.

**Notification**: Required. Operators are notified within minutes of the change.

**Examples**:
- Changing `environment` field (dev → staging)
- Changing `region` (affects all resource ARNs)
- Initial deployment of a new Claim
- Changing `resourcePrefix` (affects resource naming globally)

---

### HIGH Risk

Changes that require explicit human approval before application.

**Criteria** (any of these):
- [ ] Irreversible or expensive to reverse
- [ ] Affects security posture (IAM, encryption, access control)
- [ ] Could result in data loss or service outage
- [ ] Targets production environment
- [ ] Modifies permission boundaries or trust relationships
- [ ] Involves resource deletion

**Agent Authority**: Agents may **propose** HIGH risk changes but cannot apply them without explicit human approval.

**Notification**: Required. Approval request is created and approvers are notified immediately.

**Examples**:
- Any change to production environment (`environment: prod`)
- Any IAM policy modification
- Disabling encryption on stateful resources
- Resource deletion
- Environment promotion (staging → prod)
- Changing `awsAccountId` (would point to different AWS account)

---

## Schema Field Risk Classification

Each field in the `ServerlessEventAppClaim` schema has a **base risk class** that may be elevated by context.

### Spec Fields

| Field | Type | Required | Base Risk | Production Risk | Rationale |
|-------|------|----------|-----------|-----------------|-----------|
| `awsAccountId` | string | Yes | **HIGH** | HIGH | Immutable after creation; wrong value deploys to wrong account |
| `environment` | enum | Yes | MEDIUM | N/A | Changing to/from prod is itself the risk elevator |
| `resourcePrefix` | string | No | LOW | MEDIUM | Affects all resource names; prod changes affect prod resources |
| `region` | enum | No | MEDIUM | **HIGH** | Affects all ARNs; cross-region moves require coordination |
| `lambdaMemory` | integer | No | LOW | MEDIUM | Within bounds is low risk; prod needs change tracking |
| `lambdaTimeout` | integer | No | LOW | MEDIUM | Within bounds is low risk; prod needs change tracking |
| `eventSource` | string | No | LOW | LOW | Identifier only; no security or data impact |
| `artifactBucket` | string | No | MEDIUM | **HIGH** | Changes where Lambda code is sourced from |

### Change Operations

| Operation | Base Risk | Notes |
|-----------|-----------|-------|
| Create new Claim | MEDIUM | New resource creation is inherently coordinated |
| Modify existing Claim | *field-dependent* | See field table above |
| Delete Claim | **HIGH** | Always high risk; destroys all composed resources |

---

## Context Elevators

Certain contexts automatically elevate the risk class of a change.

### 1. Production Environment

Any change targeting a Claim with `environment: prod` elevates by one level:
- LOW → MEDIUM
- MEDIUM → HIGH
- HIGH → HIGH (cannot exceed HIGH)

**Rationale**: Production affects real users. Even "safe" changes warrant additional scrutiny.

### 2. Deletion Operations

Deleting a Claim or triggering deletion of composed resources is always **HIGH** risk, regardless of environment.

**Rationale**: Deletion is irreversible (without backup restoration). Data loss potential is inherent.

### 3. Cross-Account Changes

Any change to `awsAccountId` is **HIGH** risk regardless of other factors.

**Rationale**: Pointing to the wrong AWS account could deploy infrastructure to an unintended account with different security posture, billing, or data residency.

### 4. Security-Impacting Changes

Changes that affect security posture are elevated to **HIGH**:
- Changing IAM-related configurations
- Disabling encryption settings
- Changing network/access configurations

**Note**: The current `ServerlessEventAppClaim` schema doesn't directly expose these fields—they're managed by the Composition. If the schema evolves to include direct security controls, this elevator applies.

---

## Risk Calculation Algorithm

To determine the effective risk of a change:

```
1. Start with the base risk class of the field(s) being changed
2. If multiple fields are changed, use the highest base risk
3. Apply context elevators:
   a. If environment = prod: elevate by one level
   b. If operation = delete: set to HIGH
   c. If awsAccountId is changing: set to HIGH
4. Cap at HIGH (cannot exceed)
5. Result is the effective risk class
```

### Examples

**Example 1**: Change `lambdaMemory` from 128 to 256 in dev
- Base risk: LOW
- Elevators: none (dev environment)
- **Effective risk: LOW** → Auto-apply

**Example 2**: Change `lambdaMemory` from 256 to 512 in prod
- Base risk: LOW
- Elevators: production environment (LOW → MEDIUM)
- **Effective risk: MEDIUM** → Apply with notification

**Example 3**: Change `region` from us-east-1 to eu-west-1 in prod
- Base risk: MEDIUM
- Elevators: production environment (MEDIUM → HIGH)
- **Effective risk: HIGH** → Approval required

**Example 4**: Delete dev Claim
- Base risk: N/A (operation-level)
- Elevators: deletion (always HIGH)
- **Effective risk: HIGH** → Approval required

**Example 5**: Initial deployment of a prod Claim
- Base risk: MEDIUM (new creation)
- Elevators: production environment (MEDIUM → HIGH)
- **Effective risk: HIGH** → Approval required

---

## Validation Against Real Claims

### messagewall-dev Claim

```yaml
spec:
  environment: dev
  awsAccountId: "123456789012"
  resourcePrefix: messagewall
  region: us-east-1
  lambdaMemory: 128
  lambdaTimeout: 10
  eventSource: messagewall.api-handler
```

| Change Scenario | Effective Risk | Reason |
|-----------------|----------------|--------|
| Initial apply | MEDIUM | New creation |
| Change `lambdaMemory` to 256 | LOW | Within bounds, dev env |
| Change `lambdaTimeout` to 30 | LOW | Within bounds, dev env |
| Change `region` to us-west-2 | MEDIUM | Cross-region coordination |
| Delete Claim | HIGH | Deletion always HIGH |
| Change `awsAccountId` | HIGH | Cross-account always HIGH |

### messagewall-prod Claim

```yaml
spec:
  environment: prod
  awsAccountId: "123456789012"
  resourcePrefix: messagewall
  region: us-east-1
  lambdaMemory: 256
  lambdaTimeout: 30
  eventSource: messagewall.api-handler
```

| Change Scenario | Effective Risk | Reason |
|-----------------|----------------|--------|
| Initial apply | HIGH | New creation + prod elevator |
| Change `lambdaMemory` to 512 | MEDIUM | LOW base + prod elevator |
| Change `lambdaTimeout` to 60 | MEDIUM | LOW base + prod elevator |
| Change `region` to eu-west-1 | HIGH | MEDIUM base + prod elevator |
| Change `resourcePrefix` | MEDIUM | LOW base + prod elevator |
| Delete Claim | HIGH | Deletion always HIGH |

---

## Integration with Policy Enforcement

Risk classification and policy enforcement are complementary but distinct:

| Concern | Mechanism | What It Does |
|---------|-----------|--------------|
| **Policy Enforcement** | Kyverno, ConfigHub policies | Blocks invalid configurations (hard rules) |
| **Risk Classification** | This taxonomy | Determines approval workflow (soft gates) |

### Key Principle

**Policy violations always block.** Risk classification only applies to changes that pass policy checks.

A HIGH risk change that passes all policies still requires human approval.
A LOW risk change that violates a policy is blocked—risk class is irrelevant.

```
Configuration Change
        │
        ▼
┌───────────────────┐
│ Policy Evaluation │ ─── FAIL ──→ BLOCKED (must fix)
└─────────┬─────────┘
          │ PASS
          ▼
┌───────────────────┐
│ Risk Assessment   │
└─────────┬─────────┘
          │
    ┌─────┼─────┐
    │     │     │
    ▼     ▼     ▼
  LOW   MEDIUM  HIGH
    │     │       │
    ▼     ▼       ▼
 Apply  Apply  Approval
 Auto   +Notify Required
```

---

## Open Questions

These questions are deferred to future EPIC-15 issues:

### 1. Risk Assessment Automation (ISSUE-15.2)

Should risk class be:
- **Computed** from the change diff (more accurate, more complex)?
- **Declared** in the schema (simpler, may miss context)?

**Current stance**: Start with computed; fall back to declared for ambiguous cases.

### 2. Multi-Change Aggregation (ISSUE-15.2)

If an agent proposes 10 LOW risk changes and 1 HIGH risk change together:
- Does the batch require approval?
- **Proposed answer**: Yes. The highest risk in a batch determines batch risk.

### 3. Approval Delegation (ISSUE-15.3, ISSUE-15.14)

Can approvers delegate to:
- Other humans?
- Agents with high confidence?

**Deferred** to ISSUE-15.14 (machine-verifiable invariants).

### 4. Time-Based Risk Modifiers

Should changes during maintenance windows have lower effective risk?

**Deferred**. This is complex and may contribute to approval fatigue (ISSUE-15.13).

---

## References

- [Design: Policy to Risk Class Mapping](design-policy-risk-class-mapping.md) — Working model this formalizes
- [Platform Invariants](invariants.md) — Invariant 9: High-risk changes require human approval
- [ServerlessEventApp Schema](serverless-event-app-schema.md) — Schema field definitions
- [Policy Guardrails Demo](demo-policy-guardrails.md) — Policy behavior examples
- EPIC-15: Agent-Human Change Boundaries — Consumer of this taxonomy
- EPIC-17: Production Protection — Uses HIGH risk classification for gates
