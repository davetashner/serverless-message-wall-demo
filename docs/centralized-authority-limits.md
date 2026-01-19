# Limits of Centralized Configuration Authority

**Status**: Design document for ISSUE-18.1
**Related**: [ConfigHub Bypass Criteria](confighub-bypass-criteria.md), [ADR-011](decisions/011-ci-confighub-authority-conflict.md), [planes.md](planes.md)

---

## Why Centralization Works

Centralized configuration authority (ConfigHub) provides real value:

| Benefit | How It Helps |
|---------|--------------|
| **Single source of truth** | No conflicting versions across systems |
| **Audit trail** | Every change tracked with who/when/why |
| **Bulk operations** | Update 50 Lambdas in one revision |
| **Policy enforcement** | Block violations before actuation |
| **Approval gates** | Human review for high-risk changes |

These benefits assume a stable environment with moderate change velocity where coordination overhead is justified.

---

## When Centralization Breaks Down

Centralized authority fails when **coordination costs exceed coordination benefits**. Three failure modes:

### 1. Latency Mismatch

**Problem**: ConfigHub adds latency to every change (API calls, policy checks, approval workflows). When the environment changes faster than the authority can process, the system falls behind.

**Symptoms**:
- Queue of pending changes grows unbounded
- Approved configuration is stale by the time it's applied
- Operators bypass the system "just this once" (repeatedly)

**Example — Ephemeral preview environments**:
```
PR opened → preview env needed in <60 seconds
ConfigHub flow: create unit → policy check → apply → sync → ready
Actual time: 3-5 minutes
Result: Teams create envs directly, bypassing ConfigHub
```

**Example — Auto-scaling events**:
```
Load spike → HPA scales pods 10→50 in seconds
ConfigHub can't keep up with replica count changes
Result: Observed state diverges from "authoritative" state
```

### 2. Coordination Overhead

**Problem**: Centralized authority requires all changes to flow through a single chokepoint. When many actors make changes simultaneously, coordination becomes the bottleneck.

**Symptoms**:
- Revision conflicts during concurrent bulk operations
- Agents waiting on locks or retrying failed applies
- "Thundering herd" after ConfigHub recovers from downtime

**Example — Agent-driven experimentation**:
```
10 agents each testing 5 configuration variants
= 50 concurrent proposals competing for authority
ConfigHub becomes serialization bottleneck
Agents spend more time waiting than experimenting
```

**Example — CI pipelines across 20 services**:
```
Monorepo push triggers 20 parallel CI jobs
All 20 try to update ConfigHub simultaneously
Conflict rate increases quadratically with concurrency
```

### 3. Authority Mismatch

**Problem**: Some configuration doesn't benefit from centralized authority. Forcing it through ConfigHub adds overhead without adding value.

**Symptoms**:
- Teams create "shadow" configuration outside the system
- ConfigHub units exist but are never queried
- Reconciliation runs but nothing changes

**Example — Local development**:
```
Developer runs `kind` cluster on laptop
ConfigHub has no visibility or control
Forcing registration would add friction with zero benefit
```

**Example — Throwaway load tests**:
```
Performance team spins up 100 Lambda variants
Tests run for 2 hours, then everything deleted
ConfigHub history of deleted resources is noise, not signal
```

---

## High-Churn Scenarios

These scenarios consistently stress centralized authority:

| Scenario | Churn Rate | Why Authority Struggles |
|----------|------------|------------------------|
| **Ephemeral environments** | Minutes | Lifetime < coordination latency |
| **Preview/PR environments** | Per-commit | Volume exceeds review capacity |
| **Load/chaos testing** | Seconds | Synthetic config pollutes history |
| **Agent experimentation** | Continuous | Proposals outnumber humans |
| **Feature flag rollouts** | Real-time | Latency-sensitive, high-frequency |
| **Auto-scaling decisions** | Reactive | Observed state, not desired state |

---

## What ConfigHub Should NOT Control

Based on the failure modes above, ConfigHub should explicitly avoid governing:

### 1. Resources shorter-lived than the coordination cycle

If a resource will be deleted before ConfigHub can process its creation, don't register it.

**Rule of thumb**: Resources living < 1 hour should bypass ConfigHub.

### 2. Configuration that changes faster than humans can review

If changes happen at machine speed and humans can't meaningfully approve them, centralized approval is theater.

**Examples**: HPA replica counts, cache TTLs, circuit breaker states.

### 3. Experimentation and iteration loops

Agents and developers exploring configuration space should not pollute the authority plane with throwaway variants.

**Pattern**: Experiment locally/ephemerally → promote winner to ConfigHub.

### 4. Observed state masquerading as configuration

Current replica count, last health check result, and cache hit ratio are observations, not configuration. Don't store them as authoritative.

### 5. Resources where bypass is inevitable

If operators will bypass the system under pressure, design for that reality rather than pretending it won't happen.

**Examples**: Break-glass fixes, incident response, "the demo is in 10 minutes."

---

## The Centralization Spectrum

Not all configuration needs the same level of authority:

```
Low ◄─────────────────────────────────────────────► High
Governance                                         Governance

Local dev    Ephemeral    Pre-prod    Staging    Production
sandboxes    PR envs      testing     (shared)   (precious)

No ConfigHub  Optional    Tracked     Required   Required +
              tracking    (relaxed)   (enforced) approval gates
```

Different tiers need different authority postures. See [ISSUE-18.2](../beads/backlog.jsonl) for tiered authority design.

---

## Implications for Design

### Accept that bypass will happen

Design reconciliation paths for when (not if) configuration changes outside ConfigHub. See [break-glass reconciliation](confighub-bypass-criteria.md#break-glass-reconciliation).

### Distinguish "authoritative" from "observed"

ConfigHub stores desired state. Don't conflate it with systems that report current state (monitoring, service mesh, Kubernetes API).

### Right-size authority to environment tier

Production databases need delete gates and approval workflows. Throwaway PR environments need fast creation and automatic cleanup.

### Design for agent velocity

If agents will propose 100x more changes than humans, the approval model must evolve. See [approval fatigue](approval-fatigue-and-theater.md) and [machine-verifiable invariants](machine-verifiable-invariants.md).

---

## Summary

Centralized configuration authority provides real value for stable, long-lived, precious resources. It breaks down when:

1. **Latency** — changes happen faster than the authority can process
2. **Coordination** — concurrent actors bottleneck on a single chokepoint
3. **Mismatch** — the resource doesn't benefit from centralized control

ConfigHub should focus on what matters (production, stateful, long-lived) and explicitly release control of what doesn't (ephemeral, experimental, observed state).

For specific bypass guidance, see [When to Bypass ConfigHub](confighub-bypass-criteria.md).

---

## References

- [ConfigHub Bypass Criteria](confighub-bypass-criteria.md) — when to bypass (policy)
- [ADR-011: Bidirectional GitOps](decisions/011-ci-confighub-authority-conflict.md) — authority model
- [Four-Plane Model](planes.md) — where authority fits
- [Approval Fatigue](approval-fatigue-and-theater.md) — when human review breaks down
- [Agent Model Validation](agent-model-validation.md) — testing agent velocity assumptions
