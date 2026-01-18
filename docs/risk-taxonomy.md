# Risk Taxonomy for Configuration Changes

**Status**: Authoritative reference (ISSUE-15.1)
**Supersedes**: [design-policy-risk-class-mapping.md](design-policy-risk-class-mapping.md)

---

## Risk Classes

This taxonomy classifies configuration changes by risk level to determine automation vs. human oversight.

### LOW Risk

Auto-apply without human involvement.

**Criteria** (all must be true):
- Reversible within minutes
- Single, non-stateful resource
- Within established bounds
- No security or data loss impact
- Non-production environment

**Examples**: Adjusting `lambdaMemory` or `lambdaTimeout` in dev, changing `eventSource` identifier.

---

### MEDIUM Risk

Auto-apply with notification. Operators can intervene.

**Criteria** (any):
- Multiple resources or cross-component
- Environment-scoped blast radius
- Reversal requires coordination
- Approaches policy thresholds
- Staging environment

**Examples**: Changing `environment` (dev→staging), `region`, `resourcePrefix`, or initial Claim deployment.

---

### HIGH Risk

Requires explicit human approval.

**Criteria** (any):
- Irreversible or expensive to reverse
- Security posture change (IAM, encryption)
- Data loss or outage potential
- Production environment
- Permission boundary changes
- Resource deletion

**Examples**: Production changes, IAM modifications, disabling encryption, deletions, `awsAccountId` changes.

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

Contexts that automatically elevate risk class:

| Elevator | Effect | Rationale |
|----------|--------|-----------|
| **Production** | +1 level (LOW→MEDIUM, MEDIUM→HIGH) | Real user impact |
| **Deletion** | Always HIGH | Irreversible data loss |
| **Cross-Account** | Always HIGH | Wrong account = wrong security/billing |
| **Security Changes** | Always HIGH | IAM, encryption, network changes |

---

## Risk Calculation Algorithm

```
1. Base risk = highest risk of changed field(s)
2. Apply elevators: prod (+1), delete (→HIGH), cross-account (→HIGH)
3. Cap at HIGH
```

### Examples

| Change | Base | Elevators | Effective | Action |
|--------|------|-----------|-----------|--------|
| `lambdaMemory` 128→256 in dev | LOW | none | LOW | Auto-apply |
| `lambdaMemory` 256→512 in prod | LOW | prod +1 | MEDIUM | Apply + notify |
| `region` change in prod | MEDIUM | prod +1 | HIGH | Approval required |
| Delete dev Claim | — | deletion | HIGH | Approval required |
| New prod Claim | MEDIUM | prod +1 | HIGH | Approval required |

---

## Validation Against Real Claims

### Dev Environment

| Change | Risk | Notes |
|--------|------|-------|
| Initial apply | MEDIUM | New creation |
| `lambdaMemory`/`lambdaTimeout` | LOW | Within bounds |
| `region` | MEDIUM | Cross-region coordination |
| Delete | HIGH | Always HIGH |
| `awsAccountId` | HIGH | Always HIGH |

### Prod Environment

| Change | Risk | Notes |
|--------|------|-------|
| Initial apply | HIGH | MEDIUM + prod elevator |
| `lambdaMemory`/`lambdaTimeout` | MEDIUM | LOW + prod elevator |
| `region` | HIGH | MEDIUM + prod elevator |
| `resourcePrefix` | MEDIUM | LOW + prod elevator |
| Delete | HIGH | Always HIGH |

---

## Integration with Policy Enforcement

| Concern | Mechanism | Behavior |
|---------|-----------|----------|
| **Policy Enforcement** | Kyverno, ConfigHub | Blocks invalid configs (hard rules) |
| **Risk Classification** | This taxonomy | Determines approval workflow (soft gates) |

**Key principle**: Policy violations always block. Risk classification only applies to changes that pass policy.

```
Change → Policy Check → [FAIL: blocked] or [PASS] → Risk Assessment → LOW/MEDIUM/HIGH workflow
```

---

## Open Questions

| Question | Status | Notes |
|----------|--------|-------|
| Risk computed vs declared? | Start computed | Fall back to declared for ambiguous cases |
| Multi-change batches? | Highest risk wins | See ISSUE-20.4 for compound risk design |
| Approval delegation? | Deferred | See ISSUE-15.14 (machine-verifiable invariants) |
| Time-based modifiers? | Deferred | May contribute to approval fatigue |

---

## References

- [design-policy-risk-class-mapping.md](design-policy-risk-class-mapping.md) — Working model this formalizes
- [invariants.md](invariants.md) — Platform invariants (Invariant 9)
- [demo-policy-guardrails.md](demo-policy-guardrails.md) — Policy examples
- EPIC-15, EPIC-17 — Consumers of this taxonomy
