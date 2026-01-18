# Runtime Feedback Loops into Configuration Authority

This document explores how runtime observations (health metrics, performance data, drift detection) can inform authoritative configuration without undermining control or creating dangerous automation loops.

**Status**: Exploration document for ISSUE-15.17
**Related**:
- [Risk Taxonomy](risk-taxonomy.md) — Risk classification for feedback-driven changes
- [Agent Proposal Workflow](design-agent-proposal-workflow.md) — How feedback becomes proposals

---

## The Opportunity

Runtime systems generate valuable signals:
- CloudWatch metrics show Lambda memory pressure
- Error rates indicate timeout issues
- Cost reports reveal over-provisioning
- Latency patterns suggest scaling needs

Today, these signals require human interpretation and manual configuration updates. With agents, runtime observations could automatically inform configuration improvements.

---

## The Risk

Feedback loops can become runaway loops:

```
Runtime metric shows high latency
        │
        ▼
Agent proposes: increase memory
        │
        ▼
Approved and applied
        │
        ▼
Higher memory causes higher cost
        │
        ▼
Cost metric triggers: reduce memory
        │
        ▼
Lower memory causes high latency
        │
        ▼
(cycle repeats)
```

Unconstrained feedback loops can:
- Oscillate between configurations
- Optimize for the wrong metric
- Amplify noise into configuration churn
- Create cascading failures across systems

---

## Feedback Loop Patterns

### Pattern 1: Proposal-Gated Feedback

Runtime signals generate proposals that require human review, not automatic changes.

```
┌─────────────────────────────────────────────────────────────────┐
│                      RUNTIME PLANE                              │
│                                                                  │
│   CloudWatch: Lambda memory utilization 95%                     │
│   Pattern: Sustained for 7 days                                 │
└─────────────────────────┬───────────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────────────┐
│                      ANALYSIS AGENT                             │
│                                                                  │
│   Observation: Lambda memory-bound                              │
│   Recommendation: Increase lambdaMemory from 256 to 512         │
│   Confidence: 0.85                                              │
│   Evidence: CloudWatch data (7-day average)                     │
└─────────────────────────┬───────────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────────────┐
│                      PROPOSAL                                   │
│                                                                  │
│   kind: ConfigurationProposal                                   │
│   change: lambdaMemory 256 → 512                               │
│   riskClass: MEDIUM (LOW base + prod elevator)                  │
│   source: runtime-feedback                                      │
│   status: pending                                                │
└─────────────────────────┬───────────────────────────────────────┘
                          │
                          ▼
                 HUMAN REVIEW / AUTO-APPROVE
                          │
                          ▼
┌─────────────────────────────────────────────────────────────────┐
│                      AUTHORITY PLANE                            │
│                                                                  │
│   ConfigHub: Claim updated                                      │
│   Revision: 43                                                  │
│   Source: runtime-feedback-proposal-abc123                      │
└─────────────────────────────────────────────────────────────────┘
```

**Properties**:
- Runtime informs, doesn't dictate
- Proposals go through normal approval flow
- Authority plane remains authoritative
- Audit trail shows feedback source

**When to use**: Most feedback scenarios. Safe default.

---

### Pattern 2: Bounded Auto-Tuning

Runtime signals can directly adjust configuration within defined bounds, without proposals.

```yaml
# Schema with auto-tune bounds
spec:
  lambdaMemory: 256

  autoTune:
    enabled: true
    memoryBounds:
      min: 128
      max: 512    # Agent can adjust within this range
    cooldownMinutes: 60  # Minimum time between adjustments
    trigger:
      metric: memory_utilization
      threshold: 90
      sustainedMinutes: 30
```

```
┌─────────────────────────────────────────────────────────────────┐
│                      RUNTIME PLANE                              │
│                                                                  │
│   memory_utilization > 90% for 30 minutes                       │
└─────────────────────────┬───────────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────────────┐
│                      AUTO-TUNER                                 │
│                                                                  │
│   Current: 256 MB                                               │
│   Action: Increase by 1 step → 384 MB                          │
│   Within bounds? Yes (128-512)                                  │
│   Cooldown elapsed? Yes                                         │
└─────────────────────────┬───────────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────────────┐
│                      AUTHORITY PLANE                            │
│                                                                  │
│   ConfigHub: Claim updated                                      │
│   lambdaMemory: 256 → 384                                      │
│   Source: auto-tune (no human approval)                        │
│   Audit: "auto-tune memory increase due to utilization"         │
└─────────────────────────────────────────────────────────────────┘
```

**Properties**:
- Automation within explicit bounds
- Bounds are human-defined (part of schema)
- Cooldown prevents oscillation
- Full audit trail

**When to use**: Well-understood, low-risk adjustments within safe ranges.

---

### Pattern 3: Drift Capture and Reconciliation

Runtime drift is captured back into authoritative configuration rather than being reverted.

```
┌─────────────────────────────────────────────────────────────────┐
│                      RUNTIME PLANE                              │
│                                                                  │
│   Operator made emergency change: lambdaTimeout 30 → 60        │
│   Crossplane detects: live state ≠ desired state               │
└─────────────────────────┬───────────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────────────┐
│                      DRIFT DETECTOR                             │
│                                                                  │
│   Drift detected: lambdaTimeout                                │
│   Desired: 30                                                   │
│   Actual: 60                                                    │
│   Action: Capture (not revert)                                  │
└─────────────────────────┬───────────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────────────┐
│                      AUTHORITY PLANE                            │
│                                                                  │
│   ConfigHub: Drift captured as new revision                    │
│   lambdaTimeout: 30 → 60                                       │
│   Source: drift-capture                                         │
│   Tags: break-glass, requires-review                           │
└─────────────────────────┬───────────────────────────────────────┘
                          │
                          ▼
                 Notification to operators
                          │
                          ▼
                 Post-incident review
```

**Properties**:
- Drift is captured, not fought
- Authority plane is updated to match reality
- Tagged for post-incident review
- No silent reversion

**When to use**: Break-glass and emergency scenarios. See ADR-011.

---

### Pattern 4: Recommendation Sidecar

Runtime generates recommendations stored alongside authoritative config, not in it.

```yaml
# Authoritative configuration
apiVersion: messagewall.demo/v1alpha1
kind: ServerlessEventAppClaim
spec:
  lambdaMemory: 256
  lambdaTimeout: 30

---
# Recommendations (advisory, not authoritative)
apiVersion: recommendations.messagewall.demo/v1alpha1
kind: ConfigurationRecommendation
metadata:
  name: messagewall-prod-recommendations
spec:
  targetClaim: messagewall-prod
  recommendations:
    - field: lambdaMemory
      currentValue: 256
      recommendedValue: 512
      confidence: 0.85
      evidence:
        - type: metric
          source: cloudwatch
          period: 7d
          summary: "Average memory utilization 94%"
      status: pending-review

    - field: lambdaTimeout
      currentValue: 30
      recommendedValue: 60
      confidence: 0.72
      evidence:
        - type: metric
          source: cloudwatch
          period: 7d
          summary: "p99 duration approaching timeout"
      status: pending-review
```

**Properties**:
- Recommendations are separate from config
- No automatic application
- Operators review recommendations at their pace
- Recommendations can be dismissed or accepted

**When to use**: Advisory scenarios where human judgment is needed to interpret.

---

## Preserving Authority

All feedback patterns must preserve these authority properties:

### 1. Authority Plane Remains Authoritative

Runtime cannot modify configuration without authority plane involvement:

```
WRONG:
  Runtime → Direct change to AWS → Authority plane becomes stale

RIGHT:
  Runtime → Proposal/Capture → Authority plane → Actuation → AWS
```

### 2. Audit Trail Is Complete

Every feedback-driven change must have:
- Source identification (which metric, which agent)
- Evidence (data that triggered the change)
- Classification (proposal, auto-tune, drift-capture)
- Timestamp and attribution

### 3. Bounds Are Human-Defined

Auto-tuning bounds come from human-authored configuration:

```yaml
# Human defines bounds
autoTune:
  memoryBounds:
    min: 128
    max: 512

# Automation operates within bounds
# Cannot exceed bounds without proposal
```

### 4. Cooldowns Prevent Oscillation

All automated feedback has minimum cooldown periods:

```yaml
autoTune:
  cooldownMinutes: 60  # Minimum 1 hour between changes
```

---

## Risks of Runaway Feedback

### Risk 1: Oscillation

**Pattern**: Two metrics drive opposite actions.

```
Memory utilization high → Increase memory
Cost too high → Decrease memory
Memory utilization high → Increase memory
(repeats)
```

**Mitigation**:
- Cooldown periods (minimum time between changes)
- Hysteresis (different thresholds for increase/decrease)
- Multi-metric evaluation (consider cost AND performance together)

---

### Risk 2: Positive Feedback Amplification

**Pattern**: Feedback amplifies small signals into large changes.

```
Slight latency increase (noise)
        │
        ▼
Agent proposes: increase concurrency
        │
        ▼
Higher concurrency causes more cold starts
        │
        ▼
Higher latency
        │
        ▼
Agent proposes: even more concurrency
(amplifying loop)
```

**Mitigation**:
- Sustained duration requirements (signal must persist)
- Step-size limits (change by 1 increment, not 10)
- Total change caps (max 2x original value without human approval)

---

### Risk 3: Metric Gaming

**Pattern**: Agent optimizes for measured metric, not actual goal.

```
Goal: Reduce latency
Metric: p50 latency

Agent discovers: Rejecting slow requests reduces p50 latency
Agent proposes: Add timeout that rejects slow requests

Result: p50 looks great, user experience is worse
```

**Mitigation**:
- Multiple correlated metrics (p50, p99, error rate, availability)
- Human review of optimization strategy
- Invariants that prevent obviously bad outcomes

---

### Risk 4: Cascading Changes

**Pattern**: Change in one system triggers changes in dependent systems.

```
System A: Increase Lambda memory
        │
        ▼
System B (depends on A): Notices A is slower during deploy
        │
        ▼
System B: Increases timeout
        │
        ▼
System C (depends on B): Notices B is slower
        │
        ▼
(cascade continues)
```

**Mitigation**:
- Change propagation awareness (don't react to transient states)
- Settling time after changes (wait for stability before measuring)
- Global rate limits on feedback-driven changes

---

### Risk 5: Drift from Tested Configuration

**Pattern**: Feedback-driven changes move config away from tested state.

```
Initial config: Tested in staging, deployed to prod
Feedback change 1: Memory 256 → 384
Feedback change 2: Timeout 30 → 45
Feedback change 3: Concurrency 50 → 75

Current config: Never tested as a combination
```

**Mitigation**:
- Feedback changes trigger staging validation
- Limits on total drift from baseline
- Periodic reset to tested baseline

---

## Implementation Considerations

### What Signals to Trust

| Signal | Trust Level | Use Case |
|--------|-------------|----------|
| CloudWatch metrics (7+ days) | High | Performance tuning |
| Error rates (sustained) | High | Reliability adjustments |
| Cost reports | High | Right-sizing |
| Single-event spikes | Low | Don't react |
| New deployment metrics | Low | Wait for settling |
| Cross-account signals | Very Low | Verify before trusting |

### Feedback Sources

```yaml
# Explicit feedback source registration
feedbackSources:
  - name: cloudwatch-metrics
    type: pull
    endpoint: arn:aws:cloudwatch:...
    trustLevel: high
    cooldown: 60m

  - name: cost-explorer
    type: pull
    endpoint: arn:aws:ce:...
    trustLevel: high
    cooldown: 24h  # Cost data is daily

  - name: agent-observation
    type: push
    trustLevel: medium
    cooldown: 30m
    requiresProposal: true  # Cannot auto-apply
```

---

## Summary

| Pattern | Authority Preserved? | Automation Level | Use Case |
|---------|---------------------|------------------|----------|
| Proposal-Gated | Yes | Low (human decides) | Default for most feedback |
| Bounded Auto-Tune | Yes (bounds are authoritative) | Medium | Well-understood adjustments |
| Drift Capture | Yes (captures, doesn't fight) | Medium | Break-glass recovery |
| Recommendation Sidecar | Yes (advisory only) | None | Complex trade-off decisions |

**Runaway risks**:
- Oscillation → Cooldowns + hysteresis
- Amplification → Step limits + total caps
- Metric gaming → Multi-metric + human review
- Cascading → Settling time + global rate limits
- Configuration drift → Staging validation + periodic reset

**Key principle**: Runtime informs authority; it doesn't replace it.

---

## References

- [ADR-011: Bidirectional GitOps](decisions/011-ci-confighub-authority-conflict.md) — Drift capture model
- [Agent Proposal Workflow](design-agent-proposal-workflow.md) — Proposal-gated pattern
- [Risk Taxonomy](risk-taxonomy.md) — Risk classification for feedback-driven changes
- [Approval Fatigue](approval-fatigue-and-theater.md) — When auto-approve is appropriate
