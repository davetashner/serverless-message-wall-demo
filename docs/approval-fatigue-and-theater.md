# Approval Fatigue and Approval Theater

**Status**: Analysis document for ISSUE-15.13
**Related**: [design-approval-gates.md](design-approval-gates.md)

---

## The Problem

**Approval theater**: The appearance of oversight without substance. As agent proposal volume increases, approvers rubber-stamp, miss dangerous changes, or auto-approve to clear queues.

---

## Failure Modes

| Mode | Symptom | Threshold/Detection |
|------|---------|---------------------|
| **Volume Overload** | More requests than humans can review | > 10/day degrades quality; decision time < 30s |
| **Complexity Overload** | Changes too complex to understand | > 2 min to understand → pattern matching |
| **Trust Drift** | Agents earn trust faster than reliability | 99% accuracy at scale = 1 incident/week |
| **Diffusion of Responsibility** | Everyone assumes others are reviewing | Same 1-2 approvers; time < 1 min |
| **Alarm Fatigue** | Requests become noise | Critical requests sit unnoticed |

---

## When Human Approval Is Insufficient

Human approval works only when: reviewable (< 2 min), expert approver, focused attention, low volume (< 10/day), personal accountability.

| Scenario | Why It Fails | Mitigation |
|----------|--------------|------------|
| High volume | No time for review | Automation + sampling |
| Complex changes | Beyond understanding | Formal verification |
| Routine changes | Pattern matching | Remove from queue |
| Agent swarms | Too many proposals | Rate limiting |

---

## Mitigations

| # | Mitigation | Effect |
|---|------------|--------|
| 1 | **Risk-based filtering** | LOW/MEDIUM auto-approve → ~80% volume reduction |
| 2 | **Confidence-based escalation** | Low-confidence agents escalate to human |
| 3 | **Anomaly detection** | Flag unusual proposals (size, fields, proposer) |
| 4 | **Sampling and audit** | Random 10% deep review for statistical assurance |
| 5 | **Rate limiting** | Prevent agent swarms (e.g., 10/hour, 3 HIGH/day) |
| 6 | **Mandatory justification** | Require reason; slow rubber-stamping |
| 7 | **Cooling-off periods** | HIGH risk visible 4h before approval allowed |
| 8 | **Machine-verifiable invariants** | Formal guarantees > human judgment |

**Key insight**: Whenever safety can be expressed as a machine-checkable rule, prefer invariant enforcement over human approval.

---

## Anti-Patterns

| Fallacy | Why It Fails | Better Approach |
|---------|--------------|-----------------|
| "More approvers" | Diffusion of responsibility | 1 accountable + invariants |
| "Stricter requirements" | More friction, more workarounds | Reduce volume |
| "Training" | Ignores cognitive limits | Reduce complexity |
| "Blame the approver" | Systemic → individual framing | Add invariants |

---

## Metrics for Healthy Systems

| Metric | Healthy | Warning |
|--------|---------|---------|
| Requests/day/approver | < 10 | > 20 |
| Approval time | 2-10 min | < 30 sec |
| Approval rate | 70-90% | > 99% |
| Rejection rate | 10-30% | < 1% |

---

## Summary

Human approval works only when: low volume, comprehensible changes, engaged approvers.

**Goal**: Use human judgment where most valuable; augment with automation everywhere else.

---

## References

- [design-approval-gates.md](design-approval-gates.md), [risk-taxonomy.md](risk-taxonomy.md)
- [machine-verifiable-invariants.md](machine-verifiable-invariants.md) (ISSUE-15.14)
