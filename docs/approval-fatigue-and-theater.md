# Approval Fatigue and Approval Theater

This document describes how approval systems fail when volume or complexity exceeds human capacity, and outlines mitigations to prevent the agent-human approval workflow from becoming security theater.

**Status**: Analysis document for ISSUE-15.13
**Related**: [design-approval-gates.md](design-approval-gates.md) (ISSUE-15.3)

---

## The Problem

Approval workflows create a dangerous illusion: **the presence of an approval step makes systems feel safe, even when the approval provides no meaningful protection.**

As AI agents become more capable and propose more changes, approval volume will increase. Without careful design, human approvers will:
- Rubber-stamp without reviewing
- Auto-approve to clear the queue
- Miss dangerous changes hidden in routine ones

This is **approval theater**—the appearance of oversight without the substance.

---

## Failure Modes

### 1. Volume Overload

**Symptom**: More approval requests than humans can meaningfully review.

**Example**:
```
Monday morning:
- 47 pending approvals from weekend agent activity
- On-call engineer approves all to clear queue
- One approval includes: region change (HIGH risk) buried in routine updates
- Region change causes outage that evening
```

**Threshold**: Research suggests that beyond ~10 approval requests per day, review quality degrades significantly. At 50+/day, approval becomes mechanical.

**Detection metrics**:
- Approval decision time < 30 seconds (no time to review)
- Approval rate > 99% (no real decision-making)
- Batch approvals (selecting multiple and approving together)

---

### 2. Complexity Overload

**Symptom**: Changes are too complex for approvers to understand.

**Example**:
```
Approval request: "Update IAM policy for messagewall-prod"

Diff shows:
  - 47 lines of IAM policy JSON
  - Resource ARNs with wildcards
  - Condition blocks with StringEquals

Approver thinks: "This is the right shape, looks fine"
Approver misses: Wildcard allows s3:* on all buckets, not just messagewall-*
```

**Threshold**: If understanding the change requires more than 2 minutes of focused attention, most approvers will pattern-match rather than analyze.

**Detection metrics**:
- Approval time doesn't correlate with change size/complexity
- Same approval time for simple and complex changes

---

### 3. Trust Calibration Drift

**Symptom**: Agents earn trust faster than they earn reliability.

**Example**:
```
Week 1: Agent makes 20 proposals, all correct. Approvers review carefully.
Week 2: Agent makes 30 proposals, all correct. Approvers start skimming.
Week 3: Agent makes 40 proposals, 39 correct. Approvers auto-approve.
Week 4: Agent's 1 bad proposal (from week 3) causes incident.

Post-incident: "We trusted the agent too much"
```

**The problem**: Agents can have 99% accuracy and still cause incidents at scale. At 100 changes/week, 99% accuracy = 1 bad change/week.

---

### 4. Diffusion of Responsibility

**Symptom**: Everyone assumes someone else is reviewing carefully.

**Example**:
```
Approval request requires 1 approver from: [alice, bob, carol]

Alice sees request: "Bob or Carol will probably review this more carefully"
Bob sees request: "Alice usually handles these"
Carol sees request: "I'll let someone else take this one"

Result: First available person approves without review
```

**Detection metrics**:
- Approval always comes from the same 1-2 people
- Approval time < 1 minute (no time for others to even see it)

---

### 5. Alarm Fatigue Crossover

**Symptom**: Approval requests become noise, not signal.

**Example**:
```
Slack channel #approval-requests:
- 10:00 AM: New approval request (routine)
- 10:05 AM: New approval request (routine)
- 10:12 AM: New approval request (CRITICAL - production IAM change)
- 10:18 AM: New approval request (routine)
- 10:25 AM: New approval request (routine)

Engineer has muted the channel because it's too noisy.
Critical request sits for 6 hours.
```

---

## When Human Approval Alone Is Insufficient

Human approval provides meaningful protection only when:

| Condition | Required |
|-----------|----------|
| **Reviewability** | Change is small enough to understand in < 2 minutes |
| **Expertise** | Approver understands the domain and consequences |
| **Attention** | Approver has time and focus for genuine review |
| **Volume** | < 10 approval requests per day per approver |
| **Accountability** | Approver feels personal responsibility for the decision |

**When these conditions cannot be met, human approval alone is insufficient.** Additional safeguards are required.

### Scenarios Where Approval Is Insufficient

| Scenario | Why Approval Fails | Required Mitigation |
|----------|-------------------|---------------------|
| High volume | No time for genuine review | Automation + sampling |
| Complex changes | Beyond approver understanding | Formal verification |
| Off-hours | Approvers unavailable or fatigued | Time-based restrictions |
| Routine changes | Pattern matching replaces analysis | Remove from approval queue |
| Agent swarms | Many agents, many proposals | Rate limiting + aggregation |

---

## Mitigations

### 1. Risk-Based Filtering

**Principle**: Only require human approval for changes that humans can meaningfully assess.

**Implementation**:
- LOW risk: Auto-approve (no human in loop)
- MEDIUM risk: Auto-approve with notification (human can intervene)
- HIGH risk: Require approval (human must decide)

**Effect**: Reduces approval volume by ~80% (assuming most changes are LOW/MEDIUM risk).

```
Before filtering:
  100 proposals/week → 100 approval requests → rubber-stamping

After filtering:
  100 proposals/week → 20 HIGH risk → 20 approval requests → meaningful review
```

---

### 2. Confidence-Based Escalation

**Principle**: Use agent self-reported confidence to prioritize human attention.

**Implementation**:
```yaml
proposer:
  confidence: 0.95  # Agent is very confident

# Rule: If confidence < 0.7, escalate to human review even for LOW risk
```

**Effect**: Focuses human attention on changes the agent is uncertain about.

**Caution**: Agents may learn to report high confidence to avoid review. Calibrate by tracking actual outcomes.

---

### 3. Anomaly Detection

**Principle**: Flag proposals that deviate from historical patterns.

**Implementation**:
```python
def should_escalate(proposal):
    # Compare to last 30 days of proposals
    historical = get_historical_proposals(days=30)

    # Check for anomalies
    if proposal.changes_count > percentile(historical.changes_count, 95):
        return True  # Unusually large change

    if proposal.fields_touched not in common_field_combinations:
        return True  # Unusual field combination

    if proposal.proposer not in known_proposers:
        return True  # New proposer

    return False
```

**Effect**: Catches unusual proposals that pattern-matching approvers might miss.

---

### 4. Sampling and Audit

**Principle**: If you can't review everything, review a random sample deeply.

**Implementation**:
- Auto-approve 90% of LOW risk changes
- Randomly select 10% for deep manual review
- Track outcomes to calibrate risk classification

**Effect**: Provides statistical assurance without requiring review of everything.

**Important**: Sampled reviews must be thorough. If sampling becomes rubber-stamping, you've lost the benefit.

---

### 5. Rate Limiting

**Principle**: Limit the rate at which agents can propose changes.

**Implementation**:
```yaml
agentRateLimits:
  - agent: "*"
    proposals_per_hour: 10
    high_risk_per_day: 3
```

**Effect**: Prevents agent swarm scenarios. Forces agents to batch and prioritize.

**Trade-off**: Reduces agent velocity. May be unacceptable in time-sensitive scenarios.

---

### 6. Mandatory Justification

**Principle**: Force approvers to articulate why they're approving.

**Implementation**:
```bash
# Reject single-click approval
approvals approve proposal-abc123
# ERROR: Approval reason required

# Require substantive reason
approvals approve proposal-abc123 --reason "Reviewed IAM diff, no wildcard expansion"
```

**Effect**: Slows down rubber-stamping. Creates audit trail of reasoning.

**Caution**: Approvers may write boilerplate reasons. Monitor for phrases like "Looks good" or "LGTM".

---

### 7. Cooling-Off Periods

**Principle**: Delay HIGH risk changes to allow broader review.

**Implementation**:
- HIGH risk proposals are visible for 4 hours before approval is allowed
- During this window, anyone can comment or object
- After 4 hours, designated approvers can approve

**Effect**: Prevents rushed approvals. Allows passive review by broader team.

---

### 8. Machine-Verifiable Invariants

**Principle**: Use formal guarantees instead of human judgment where possible.

**Implementation** (see ISSUE-15.14):
```rego
# Instead of human reviewing IAM changes, enforce invariants

# Invariant: No IAM policy may contain Action: "*"
deny[msg] {
    input.Statement[_].Action == "*"
    msg := "Wildcard actions are prohibited"
}

# Invariant: All resources must start with arn:aws:s3:::messagewall-
deny[msg] {
    resource := input.Statement[_].Resource
    not startswith(resource, "arn:aws:s3:::messagewall-")
    msg := sprintf("Resource %s is outside allowed scope", [resource])
}
```

**Effect**: Removes entire categories of dangerous changes from human review by making them impossible.

**When to use**: Whenever a safety property can be expressed as a machine-checkable rule, prefer formal enforcement over human approval.

---

## Anti-Patterns to Avoid

### 1. "More Approvers" Fallacy

**Wrong**: "If 1 approver isn't enough, require 2"
**Why it fails**: Diffusion of responsibility. Both assume the other is reviewing carefully.

**Better**: 1 accountable approver + automated invariant checks

### 2. "Stricter Requirements" Fallacy

**Wrong**: "If rubber-stamping is happening, require longer reasons"
**Why it fails**: Creates more friction, more resentment, more creative workarounds.

**Better**: Reduce volume so fewer approvals are needed

### 3. "Training" Fallacy

**Wrong**: "If approvers miss things, train them better"
**Why it fails**: Ignores cognitive limits. No amount of training overcomes volume overload.

**Better**: Reduce complexity and volume to match human capacity

### 4. "Blame the Approver" Fallacy

**Wrong**: Post-incident: "The approver should have caught this"
**Why it fails**: Systemic problem framed as individual failure. Next approver will fail the same way.

**Better**: Ask "why was this approvable?" and add invariants to prevent it

---

## Metrics for Healthy Approval Systems

| Metric | Healthy Range | Warning Signs |
|--------|---------------|---------------|
| Approval requests per day | < 10 per approver | > 20 = volume overload |
| Median approval time | 2-10 minutes | < 30 seconds = rubber-stamping |
| Approval rate | 70-90% | > 99% = no real decisions |
| Rejection rate | 10-30% | < 1% = theater |
| Reason length | 20-100 characters | < 10 = boilerplate |
| Time to first review | < 1 hour | > 4 hours = queue backup |
| Approver diversity | Spread across team | 1-2 people = bottleneck |

---

## Summary

Human approval is not a silver bullet. It provides meaningful protection only when:
- Volume is manageable (< 10/day)
- Changes are comprehensible (< 2 min to understand)
- Approvers are engaged (not fatigued or pattern-matching)

**When these conditions cannot be met, human approval alone is insufficient.**

Mitigations:
1. Risk-based filtering (reduce volume)
2. Confidence-based escalation (focus attention)
3. Anomaly detection (catch unusual changes)
4. Sampling and audit (statistical assurance)
5. Rate limiting (prevent swarms)
6. Mandatory justification (slow rubber-stamping)
7. Cooling-off periods (enable broader review)
8. **Machine-verifiable invariants** (formal guarantees > human judgment)

The goal is not to remove humans from the loop but to **use human judgment where it's most valuable** and augment it with automation everywhere else.

---

## References

- [Design: Approval Gates](design-approval-gates.md) — Approval mechanism (ISSUE-15.3)
- [Risk Taxonomy](risk-taxonomy.md) — Risk class definitions (ISSUE-15.1)
- [Platform Invariants](invariants.md) — Invariant 9: High-risk changes require human approval
- ISSUE-15.14 — Machine-verifiable invariants (mitigations explored there)
- Research: [Alarm Fatigue in Healthcare](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC6390422/) — Parallel domain
