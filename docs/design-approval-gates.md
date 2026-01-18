# Design: Approval Gates for High-Risk Changes

**Status**: Design document for ISSUE-15.3
**Depends on**: [risk-taxonomy.md](risk-taxonomy.md), [design-agent-proposal-workflow.md](design-agent-proposal-workflow.md)

---

## Core Principle

**Policy enforcement is automated. Approval is human judgment.**

| Layer | Question | Authority | Blocking |
|-------|----------|-----------|----------|
| **Policy** | "Is this valid?" | Machine rules | Always (invalid = blocked) |
| **Approval** | "Should we apply now?" | Human approvers | HIGH risk only |

---

## Approval Requirements by Risk Class

| Risk Class | Approval | Delay | Rationale |
|------------|----------|-------|-----------|
| **LOW** | No | 5 min auto-apply | Safe; human can override during window |
| **MEDIUM** | No | 1 hour + notify | Warrants awareness; operator can intervene |
| **HIGH** | **Yes** | Blocked | Outage/data loss potential; explicit decision required |

---

## Approval Workflow

```mermaid
flowchart LR
    subgraph "1. Proposal"
        A[Agent/CI] --> B[Create Proposal]
    end

    subgraph "2. Risk Assessment"
        B --> C{Compute Risk}
        C --> D[Base risk + elevators]
    end

    subgraph "3. Routing"
        D --> E{Risk Class}
        E -->|LOW| F[Auto-apply queue]
        E -->|MEDIUM| G[Notify + auto-apply]
        E -->|HIGH| H[Approval required]
    end

    subgraph "4. Decision"
        H --> I[Notify approvers]
        I --> J{Review}
        J -->|Approve| K[Record decision]
        J -->|Reject| L[Record + close]
    end

    subgraph "5. Application"
        F --> M[Apply to ConfigHub]
        G --> M
        K --> M
        M --> N[Sync to Actuator]
    end

    style L fill:#f66
    style N fill:#6f6
```

*Figure: Approval workflow from proposal through risk-based routing to application.*

---

## Approver Roles

| Role | Can Approve | Scope |
|------|-------------|-------|
| Platform Operator | Yes | All spaces |
| Environment Owner | Yes | Their environment |
| On-Call Engineer | Yes | Any (during rotation) |
| Agent | **No** | — |
| CI/Automation | **No** | — |

**Escalation**: 4h → secondary on-call, 24h → platform lead, 7 days → auto-reject (expired)

---

## Approval Record

Every decision recorded with: approver, role, timestamp, decision, reason, session metadata.
Provides accountability, audit trail, and reason capture.

---

## Blocking Behavior

HIGH risk proposals:
- State: `pending` (cannot progress to `applied`)
- Visible in approvals queue
- Approvers notified immediately
- **No auto-approve**, remains blocked until decision
- `--force` flag does **not** bypass approval

---

## Emergency Override (Break-Glass)

For true emergencies:
```bash
cub break-glass apply --space messagewall-prod --reason "..." --file fix.yaml
```

Break-glass applies immediately but:
- Logs with emergency flag
- Creates retroactive approval request
- Notifies all operators
- Requires post-incident review

See EPIC-17 for detailed break-glass workflow.

---

## Implementation: Git PR-Based Approvals (Phase 1)

| Concept | GitHub Implementation |
|---------|----------------------|
| Proposal | Pull Request |
| Risk Class | PR Label (`risk:low/medium/high`) |
| Approval | GitHub PR approval |
| Applied | PR merged |

CI workflow: compute risk → apply label → require approval for HIGH → block merge without approval.
CODEOWNERS controls who can approve.

---

## Metrics

| Metric | Alert Threshold |
|--------|-----------------|
| Pending count | > 10 |
| Oldest pending age | > 24 hours |
| Time to decision (p50) | > 4 hours |
| Rejected ratio | > 30% |

---

## Summary

**Key guarantees**:
1. HIGH risk blocked without approval
2. LOW risk auto-applies
3. All decisions auditable
4. Only humans can approve

---

## References

- [risk-taxonomy.md](risk-taxonomy.md), [design-agent-proposal-workflow.md](design-agent-proposal-workflow.md)
- [invariants.md](invariants.md) — Invariant 9
- EPIC-17 — Production protection gates
