# When to Bypass ConfigHub

This document defines scenarios where bypassing ConfigHub is acceptable or even desirable. Not all configuration needs to flow through the authority plane, and understanding these boundaries prevents ConfigHub from becoming an obstacle rather than an enabler.

**Status**: Policy document for ISSUE-15.18
**Related**:
- [ADR-011: Bidirectional GitOps](decisions/011-ci-confighub-authority-conflict.md)
- [Platform Invariants](invariants.md)

---

## The Principle

ConfigHub provides value through:
- **Authority**: Single source of truth for what should be running
- **History**: Every change tracked with attribution
- **Bulk operations**: Query and modify many resources at once
- **Policy enforcement**: Validate before apply

But ConfigHub also has costs:
- **Latency**: Changes go through an extra hop
- **Coordination**: Multiple systems must synchronize
- **Complexity**: More moving parts to fail
- **Scope creep**: Not everything benefits from centralized authority

**Principle**: Use ConfigHub when its benefits outweigh its costs. Bypass when they don't.

---

## Bypass Criteria

### Criterion 1: Ephemeral Resources

**Description**: Resources that exist for minutes to hours and are automatically cleaned up.

**Examples**:
- Developer preview environments
- CI/CD test environments
- Load test infrastructure
- Temporary debugging resources

**Why bypass**: ConfigHub overhead exceeds resource lifetime. By the time the resource is registered, it may already be gone.

**Reconciliation expectation**: None required. Resource doesn't persist.

```yaml
# OK to bypass ConfigHub
kind: TestEnvironment
metadata:
  labels:
    ephemeral: "true"
    ttl: "2h"
    bypass-confighub: "true"
```

---

### Criterion 2: Local Development

**Description**: Developer's local machine or local Kubernetes cluster.

**Examples**:
- Local kind/minikube clusters
- Docker Compose stacks
- Local database instances
- Developer sandboxes

**Why bypass**: Local resources don't need organizational coordination or audit trails.

**Reconciliation expectation**: None required. Local resources are personal.

---

### Criterion 3: Platform Infrastructure

**Description**: Infrastructure that ConfigHub itself depends on.

**Examples**:
- ConfigHub's own deployment
- ArgoCD controllers
- Crossplane controllers
- Kyverno policy engine
- Certificate management

**Why bypass**: Circular dependency. ConfigHub can't manage its own prerequisites.

**Reconciliation expectation**: Managed via separate bootstrap process with its own audit trail.

```
Bootstrap chain (not in ConfigHub):
  1. Kubernetes cluster
  2. Crossplane
  3. Kyverno
  4. ArgoCD
  5. ConfigHub worker

Application resources (in ConfigHub):
  6. ServerlessEventAppClaims
  7. Application infrastructure
```

---

### Criterion 4: Break-Glass Emergencies

**Description**: Situations where normal workflows are too slow or unavailable.

**Examples**:
- Production outage requiring immediate fix
- ConfigHub itself is down
- Network partition prevents ConfigHub access
- Security incident requiring immediate lockdown

**Why bypass**: Speed of response outweighs coordination benefits.

**Reconciliation expectation**: **Required.** Capture changes back to ConfigHub as soon as possible.

```bash
# Emergency bypass
kubectl apply -f emergency-fix.yaml --context prod-cluster

# Immediate follow-up (within 1 hour)
cub drift-capture --space messagewall-prod --tag break-glass

# Post-incident (within 24 hours)
# Review captured changes
# Create formal proposal if change should persist
# Or revert to pre-incident state
```

---

### Criterion 5: Secrets and Credentials

**Description**: Sensitive data that shouldn't be stored in ConfigHub.

**Examples**:
- API keys
- Database passwords
- TLS certificates (private keys)
- OAuth client secrets

**Why bypass**: ConfigHub is not a secrets manager. Storing secrets there creates security risk.

**Reconciliation expectation**: Secret *references* may be in ConfigHub, but actual values bypass it.

```yaml
# In ConfigHub: Reference to secret
spec:
  databaseCredentials:
    secretRef:
      name: messagewall-db-creds
      namespace: default

# NOT in ConfigHub: Actual secret
# Managed via: AWS Secrets Manager, HashiCorp Vault, Kubernetes Secrets
```

---

### Criterion 6: Real-Time Operational Data

**Description**: Data that changes faster than ConfigHub can reasonably track.

**Examples**:
- Current pod replica count (managed by HPA)
- Cache contents
- Session data
- Request routing weights (managed by service mesh)

**Why bypass**: ConfigHub is for desired state, not observed state.

**Reconciliation expectation**: None required. This isn't configuration.

```yaml
# In ConfigHub: Desired state
spec:
  autoscaling:
    minReplicas: 2
    maxReplicas: 10

# NOT in ConfigHub: Current state
status:
  currentReplicas: 7  # Managed by HPA, changes frequently
```

---

### Criterion 7: Agent-Local Experimentation

**Description**: Agent exploring possibilities before proposing.

**Examples**:
- Agent testing configurations locally
- Agent running simulations
- Agent comparing alternatives
- Agent gathering data for recommendations

**Why bypass**: Experimentation shouldn't pollute authoritative configuration.

**Reconciliation expectation**: Successful experiments become proposals via normal workflow.

```
Agent workflow:
  1. Spawn test environment (bypass ConfigHub)
  2. Try configuration variants
  3. Measure results
  4. Destroy test environment
  5. Create proposal for winning variant (goes through ConfigHub)
```

---

### Criterion 8: Cross-Cutting Observability

**Description**: Monitoring, logging, and tracing infrastructure.

**Examples**:
- Prometheus scrape configs
- Datadog agents
- Log shipping configuration
- Distributed tracing setup

**Why bypass**: Observability often needs to exist before ConfigHub is available (to observe ConfigHub itself).

**Reconciliation expectation**: May be bootstrapped separately, but ongoing changes can optionally flow through ConfigHub if desired.

---

## Bypass Paths with Reconciliation

For scenarios where bypass is temporary (like break-glass), reconciliation is required.

### Immediate Capture

```bash
# After emergency change
cub drift-capture \
  --space messagewall-prod \
  --tag break-glass \
  --reason "Emergency fix for memory leak causing OOM"

# Creates ConfigHub revision from live state
# Tags it for post-incident review
```

### Post-Incident Review

```bash
# List break-glass changes
cub revision list --space messagewall-prod --tag break-glass

# Review each change
cub revision show 47 --space messagewall-prod

# Decision: Persist or revert
cub revision promote 47 --space messagewall-prod  # Keep the change
# or
cub revision revert 47 --space messagewall-prod   # Undo the change
```

### Audit Requirements

Even bypassed changes should be auditable:

| Bypass Scenario | Audit Requirement |
|-----------------|-------------------|
| Ephemeral resources | None |
| Local development | None |
| Platform infrastructure | Bootstrap runbook with change log |
| Break-glass | Mandatory capture within 1 hour |
| Secrets | Secret management system's audit log |
| Real-time data | Not configuration; no audit |
| Agent experiments | Experiments logged; winning proposal audited |
| Observability | Optional; bootstrap runbook |

---

## What ConfigHub Is NOT For

To avoid overreach, explicitly state what ConfigHub should not manage:

### ConfigHub Is Not a Secrets Manager

Use:
- AWS Secrets Manager
- HashiCorp Vault
- Kubernetes Secrets (for less sensitive data)

ConfigHub stores references, not values.

### ConfigHub Is Not a Service Mesh Control Plane

Use:
- Istio
- Linkerd
- AWS App Mesh

ConfigHub may store mesh policies, but real-time routing is mesh-controlled.

### ConfigHub Is Not a Kubernetes API Server

ConfigHub stores desired state for *application* resources. It doesn't replace:
- `kubectl` for debugging
- Direct API access for operators
- Real-time cluster state queries

### ConfigHub Is Not a CI/CD Pipeline

ConfigHub stores configuration, not:
- Build artifacts
- Test results
- Deployment logs

CI/CD pipelines publish TO ConfigHub, but aren't replaced by it.

### ConfigHub Is Not Universal

Some things don't need centralized authority:
- Personal tooling
- One-off scripts
- Exploratory work
- Throwaway resources

Not everything is production. Not everything needs governance.

---

## Decision Framework

When deciding whether to use ConfigHub:

```
Is this configuration that should persist?
│
├── No → Bypass (ephemeral, experiments, throwaway)
│
└── Yes → Does it contain secrets?
          │
          ├── Yes → Bypass (use secrets manager)
          │
          └── No → Is ConfigHub available?
                   │
                   ├── No → Bypass (break-glass, bootstrap)
                   │         └── Reconcile afterward if needed
                   │
                   └── Yes → Would ConfigHub add value?
                             │
                             ├── Yes → Use ConfigHub
                             │
                             └── No → Bypass
                                       │
                                       └── (Observability, local dev, etc.)
```

---

## Summary

| Scenario | Bypass OK? | Reconciliation Required? |
|----------|-----------|-------------------------|
| Ephemeral resources | Yes | No |
| Local development | Yes | No |
| Platform infrastructure | Yes | Separate bootstrap process |
| Break-glass emergencies | Yes | **Yes, within 1 hour** |
| Secrets and credentials | Yes | Reference in ConfigHub, value elsewhere |
| Real-time operational data | Yes | No (not configuration) |
| Agent experimentation | Yes | Winning variant becomes proposal |
| Cross-cutting observability | Yes | Optional |

**Key principles**:
1. ConfigHub is not mandatory for all workflows
2. Bypass is acceptable when benefits don't outweigh costs
3. Break-glass bypass requires reconciliation
4. Secrets never go in ConfigHub
5. Ephemeral resources don't need authority governance

---

## References

- [ADR-011: Bidirectional GitOps](decisions/011-ci-confighub-authority-conflict.md) — Drift capture model
- [Design: Approval Gates](design-approval-gates.md) — Break-glass procedure
- [Platform Invariants](invariants.md) — What must always be true
- [Runtime Feedback Loops](runtime-feedback-loops.md) — Drift capture pattern
