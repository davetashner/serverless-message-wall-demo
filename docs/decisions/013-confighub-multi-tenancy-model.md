# ADR-013: ConfigHub Multi-Tenancy Model for Demo

## Status
Accepted

## Context

The demo showcases two distinct scenarios that demonstrate ConfigHub's value as a configuration authority:

1. **Messagewall Infrastructure** - AWS resources (Lambda, DynamoDB, S3, EventBridge, IAM) managed via Crossplane. Owned by the messagewall product team within ACME Corp. Demonstrates centrally managed cloud infrastructure without any Kubernetes workloads.

2. **Order Platform Workloads** - Standard Kubernetes deployments representing a business capability supported by 5 different teams. Demonstrates multi-tenant Kubernetes in an enterprise setting where teams deploy to shared clusters but cannot modify each other's configuration.

Both scenarios demonstrate that ConfigHub manages configuration for **any API** - not just Kubernetes. The messagewall uses Crossplane (which happens to use K8s CRDs), while Order Platform uses native K8s Deployments. The unifying theme is ConfigHub as the single authority.

### Key Requirements

1. **Team isolation**: Teams in Order Platform cannot edit other teams' configuration
2. **Environment separation**: Dev and prod per team for staged rollouts
3. **Bulk operations**: Ability to update all dev environments or all teams at once
4. **Clear ownership**: Messagewall team owns infrastructure; app teams own their workloads

### ConfigHub Constraints

Per [ConfigHub Authorization docs](https://docs.confighub.com/background/concepts/authorization/):

- **Space = ACL boundary**: Permissions are controlled at the Organization and Space levels
- **Unit-level ACLs not available**: "permissions may be added to individual configuration Units and Triggers in the future, but it is recommended that you rely on Space-level permissions"
- **Labels enable bulk operations**: Spaces can be labeled and queried for multi-dimensional organization

## Decision

### Space Structure

Use **one ConfigHub space per team per environment**, with labels for bulk targeting:

```
ConfigHub Spaces (12 total):

# Infrastructure - Messagewall team owns these
messagewall-dev          [Application=messagewall, Environment=dev]
messagewall-prod         [Application=messagewall, Environment=prod]

# Order Platform - 5 teams × 2 environments = 10 spaces
order-platform-ops-dev        [Application=order-platform, Team=platform-ops, Environment=dev]
order-platform-ops-prod       [Application=order-platform, Team=platform-ops, Environment=prod]
order-data-dev                [Application=order-platform, Team=data, Environment=dev]
order-data-prod               [Application=order-platform, Team=data, Environment=prod]
order-customer-dev            [Application=order-platform, Team=customer, Environment=dev]
order-customer-prod           [Application=order-platform, Team=customer, Environment=prod]
order-integrations-dev        [Application=order-platform, Team=integrations, Environment=dev]
order-integrations-prod       [Application=order-platform, Team=integrations, Environment=prod]
order-compliance-dev          [Application=order-platform, Team=compliance, Environment=dev]
order-compliance-prod         [Application=order-platform, Team=compliance, Environment=prod]
```

### Kubernetes Namespace Mapping

One workload cluster with namespaces per team per environment:

```
Workload Cluster Namespaces:
├── platform-ops-dev
├── platform-ops-prod
├── data-dev
├── data-prod
├── customer-dev
├── customer-prod
├── integrations-dev
├── integrations-prod
├── compliance-dev
└── compliance-prod
```

### Team-to-Microservice Mapping

| Team | Microservices | Business Context |
|------|---------------|------------------|
| platform-ops | heartbeat, sentinel | Observability, health monitoring |
| data | counter, reporter | Data aggregation, reporting |
| customer | greeter, weather | Customer-facing features |
| integrations | pinger, ticker | External integrations, scheduling |
| compliance | auditor, quoter | Audit logging, policy enforcement |

### Label Strategy

All spaces include labels for multi-dimensional querying:

```bash
# Create a space with labels
cub space create order-data-dev \
  --label Application=order-platform \
  --label Team=data \
  --label Environment=dev
```

### Bulk Operations via Labels

```bash
# Update all dev environments across all Order Platform teams
cub unit update --where "Labels.Application = 'order-platform' AND Labels.Environment = 'dev'" ...

# Update all environments for a single team
cub unit update --where "Labels.Team = 'data'" ...

# Update everything in Order Platform
cub unit update --where "Labels.Application = 'order-platform'" ...
```

### ArgoCD Applications

Each team-environment combination has its own ArgoCD Application syncing from its ConfigHub space:

```yaml
# Example: order-data-dev Application
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: order-data-dev
spec:
  source:
    plugin:
      name: confighub
      env:
        - name: CONFIGHUB_SPACE
          value: order-data-dev
  destination:
    namespace: data-dev
```

Consider using ApplicationSet to reduce manifest count from 10 to 1.

## Alternatives Considered

### Alternative 1: Two spaces with unit naming convention

```
order-platform-dev    (all dev workloads)
order-platform-prod   (all prod workloads)
```

**Rejected**: ConfigHub does not support unit-level ACLs. All users with space access could edit any team's units, violating team isolation requirement.

### Alternative 2: Environment-only spaces (like messagewall)

```
order-platform-dev
order-platform-prod
```

**Rejected**: Same as Alternative 1. Does not provide team isolation.

### Alternative 3: Single space with views

Use one space with ConfigHub views to present team-specific slices.

**Rejected**: Views provide read-only filtering for UI/queries but do not enforce write access control. Teams could still modify other teams' units.

## Consequences

### Benefits

- **True team isolation**: Space-level ACLs prevent cross-team modifications
- **Clear ownership**: Each space has a single owning team
- **Staged rollouts**: Bulk update dev first, validate, then prod
- **Flexible bulk operations**: Labels enable targeting by any dimension
- **Realistic demo**: Mirrors actual enterprise multi-tenant patterns

### Trade-offs

- **12 spaces to manage**: More operational overhead than 2-4 spaces
- **10 ArgoCD Applications**: One per team-env (mitigated by ApplicationSet)
- **Space proliferation**: Adding teams or environments increases space count linearly

### Future Considerations

- If ConfigHub adds unit-level ACLs, could consolidate to fewer spaces
- ApplicationSet can generate Applications from ConfigHub space labels
- Platform team may need a separate space for cross-cutting concerns

## References

- [ConfigHub Authorization](https://docs.confighub.com/background/concepts/authorization/)
- [ConfigHub Environments Guide](https://docs.confighub.com/guide/environments/)
- [ADR-005: ConfigHub Integration Architecture](005-confighub-integration-architecture.md)
- [ADR-009: ConfigHub Worker for Kubernetes Sync](009-argocd-confighub-sync.md)
- EPIC-19: ConfigHub multi-tenancy design
- EPIC-36: Workload cluster with observable microservices
