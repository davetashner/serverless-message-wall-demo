# ADR-010: ConfigHub Stores Claims, Not Expanded Resources

## Status
Accepted

## Context

With the introduction of `ServerlessEventApp` XRD (EPIC-11), we now have two possible representations of application configuration:

1. **Claim**: The developer-authored `ServerlessEventAppClaim` (~10 fields)
2. **Expanded Resources**: The 17 AWS managed resources produced by the Composition

We must decide which representation ConfigHub stores as the authoritative configuration. This decision affects:
- Authority boundaries (who controls what)
- Diff visibility (what changes are visible in ConfigHub)
- Bulk change mechanics (what can be mutated)
- Rollback granularity (what gets reverted)

## Decision

**ConfigHub stores the Claim (developer intent), not the expanded resources.**

The flow becomes:

```
Developer authors Claim (Git)
        │
        ▼
CI publishes Claim to ConfigHub
        │
        ▼
ConfigHub (authoritative: Claim)
        │
        ▼
ConfigHub Worker applies Claim to Kubernetes
        │
        ▼
Crossplane expands Claim → 17 Managed Resources
        │
        ▼
AWS Resources
```

## Rationale

### Trade-off Analysis

| Aspect | Store Claim | Store Expanded Resources |
|--------|-------------|--------------------------|
| **Authority** | ConfigHub controls intent; Crossplane controls expansion | ConfigHub controls everything; Crossplane is pass-through |
| **Diff visibility** | Diffs show intent changes ("memory: 128 → 256") | Diffs show all 17 resources (noisy) |
| **Bulk changes** | Mutate intent fields; Composition propagates | Must mutate each resource individually |
| **Schema evolution** | Composition changes don't require ConfigHub migration | Every Composition change requires re-publishing all resources |
| **Rollback** | Revert intent; Crossplane re-expands | Revert all 17 resources |
| **Queryability** | Query by intent (environment, memory) | Query by resource attributes |
| **Size** | ~20 lines per unit | ~500+ lines per unit (17 resources) |

### Why Claims Win

1. **Single source of intent**: The Claim is what developers care about. Storing it preserves the "one product, one Claim" mental model from EPIC-11.

2. **Composition as implementation detail**: How a Claim expands into AWS resources is a platform concern, not a configuration concern. Composition changes (bug fixes, new features) should not require republishing to ConfigHub.

3. **Clean diffs**: When a developer changes `lambdaMemory: 128` to `lambdaMemory: 256`, the ConfigHub diff shows exactly that—not 17 resource diffs.

4. **Bulk changes still work**: ConfigHub can still mutate Claims in bulk:
   ```bash
   cub unit list --where "kind=ServerlessEventAppClaim AND spec.environment=prod"
   cub fn patch --path spec.lambdaMemory --value 512
   ```

5. **Consistent with ADR-005**: ADR-005 established "Git → Render → ConfigHub → Actuator". The Claim *is* the rendered, resolved configuration for this abstraction level.

### What We Lose

- **Deep queryability**: Cannot query "all Lambda functions with runtime python3.11" because ConfigHub only sees Claims, not expanded Lambdas. Mitigation: Query the actuator cluster directly for resource-level queries.

- **Resource-level rollback**: Cannot rollback a single IAM policy; must rollback the entire Claim. Mitigation: This is acceptable because the Claim is the unit of deployment.

## Implementation

### CI Pipeline

CI renders and publishes Claims (not expanded resources):

```bash
# Publish Claim to ConfigHub
cub unit update \
  --space messagewall-dev \
  --kind ServerlessEventAppClaim \
  --name messagewall-dev \
  --file examples/claims/messagewall-dev.yaml
```

### ConfigHub Units

Each environment has one unit per application:

| Space | Unit Name | Kind |
|-------|-----------|------|
| `messagewall-dev` | `messagewall-dev` | `ServerlessEventAppClaim` |
| `messagewall-prod` | `messagewall-prod` | `ServerlessEventAppClaim` |

### Policy Enforcement

Policies run against Claims:

```rego
# Block production Claims with insufficient memory
deny[msg] {
  input.kind == "ServerlessEventAppClaim"
  input.spec.environment == "prod"
  input.spec.lambdaMemory < 256
  msg := "Production Claims must have lambdaMemory >= 256"
}
```

### Observing Expanded Resources

For visibility into what Crossplane actually provisions:

```bash
# In the actuator cluster
kubectl get managed -l crossplane.io/claim-name=messagewall-dev
```

ConfigHub status can link to the actuator's Claim status for aggregate readiness.

## Consequences

1. **ConfigHub sees intent, not infrastructure**: This is intentional. Infrastructure details live in the Composition.

2. **Composition changes are invisible to ConfigHub**: Platform team can update Compositions without touching ConfigHub. This is a feature, not a bug.

3. **Resource-level queries require cluster access**: Use `kubectl` or a Kubernetes dashboard for deep resource inspection.

4. **ADR-005 remains valid**: The Claim is the "fully-rendered manifest" at this abstraction level.

## Future Considerations

If we need resource-level visibility in ConfigHub (e.g., for compliance auditing), we could:
- Publish expanded resources to a separate "shadow" space for read-only inspection
- Build a ConfigHub integration that queries the actuator and presents resource details

These are not needed for the current demo scope.

## Related Documents

- [ADR-005: ConfigHub Integration Architecture](./005-confighub-integration-architecture.md)
- [ServerlessEventApp Schema Reference](../serverless-event-app-schema.md)
- [docs/planes.md](../planes.md) - Four-plane model (Intent, Authority, Actuation, Runtime)
