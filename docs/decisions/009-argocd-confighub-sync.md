# ADR-009: ConfigHub Worker for Kubernetes Sync

## Status
Accepted (Updated)

## Context

With ConfigHub established as the authoritative store for rendered Crossplane manifests (ADR-005, ISSUE-8.1-8.3), we need a mechanism for the actuator cluster to pull approved configuration and apply it to Kubernetes. The flow is:

```
Git (authoring) → CI (render) → ConfigHub (authority) → ??? → Kubernetes (actuation) → AWS (runtime)
```

The missing piece is how ConfigHub-approved manifests reach the actuator cluster. We need a solution that:

1. Pulls from ConfigHub (not pushes from CI)
2. Continuously reconciles desired vs actual state
3. Supports GitOps workflows (sync, prune, rollback)
4. Avoids direct `kubectl apply` from CI pipelines

## Decision

### Use ConfigHub Worker with Kubernetes Provider

Install a ConfigHub worker directly in the actuator cluster using `cub worker install`. The worker connects to ConfigHub and applies units to Kubernetes.

```
ConfigHub (authoritative) ──stream──> ConfigHub Worker ──apply──> Kubernetes ──reconcile──> AWS
```

### Why ConfigHub Worker over Alternatives

**Alternative 1: ArgoCD CMP**
- Install ArgoCD with a Config Management Plugin that calls `cub` CLI
- **Considered but rejected**: ArgoCD requires a Git repository even with CMPs. Would need a dummy repo or workaround.

**Alternative 2: Git-branch mirror**
- CI publishes to ConfigHub AND pushes to a `rendered/` Git branch
- ArgoCD watches the Git branch
- **Rejected**: Creates a second source of truth. ConfigHub and Git could drift.

**Alternative 3: ConfigHub webhook → kubectl apply**
- ConfigHub calls a webhook that runs `kubectl apply`
- **Rejected**: Push-based model, no reconciliation loop, requires exposing webhook endpoint.

**Chosen: ConfigHub Worker**
- Native ConfigHub solution - purpose-built for this use case
- Event-driven via streaming connection (not polling)
- Handles authentication, reconnection, and error recovery
- Supports multiple provider types (Kubernetes, OpenTofu, etc.)
- Simple installation via `cub worker install`

## Implementation

### Installation Steps

1. **Create ConfigHub worker** in the space:
   ```bash
   cub worker create --space messagewall-dev actuator-sync --allow-exists
   ```

2. **Install worker in Kubernetes** with the Kubernetes provider:
   ```bash
   cub worker install actuator-sync --space messagewall-dev \
       --provider-types kubernetes --export --include-secret | kubectl apply -f -
   ```

3. **Set target for units** to associate with the worker:
   ```bash
   cub unit set-target actuator-sync-kubernetes-yaml-cluster \
       --space messagewall-dev \
       --unit dynamodb,eventbridge,function-url,iam,lambda,s3
   ```

4. **Apply units** to sync to Kubernetes:
   ```bash
   cub unit apply --space messagewall-dev --unit dynamodb,eventbridge,function-url,iam,lambda,s3 --wait
   ```

### What Gets Created

The `cub worker install` command creates:

| Resource | Purpose |
|----------|---------|
| `confighub` Namespace | Isolates worker resources |
| `confighub-worker` ServiceAccount | Identity for worker pod |
| `confighub-worker-admin` ClusterRoleBinding | Grants cluster-admin for applying resources |
| `confighub-worker-secret` Secret | Worker authentication credentials |
| `actuator-sync-*` Deployment | The worker pod that syncs from ConfigHub |

### ArgoCD (Optional)

ArgoCD is still installed for observability and for managing non-ConfigHub resources. The CMP sidecar is configured but the primary sync mechanism is the ConfigHub worker.

## Consequences

### Benefits
- **Single source of truth**: ConfigHub is authoritative; no Git branch to sync
- **Event-driven**: Worker receives events via streaming connection (not polling)
- **Native integration**: Purpose-built for ConfigHub; no custom plugins needed
- **Observable**: `cub unit list` shows status; worker logs show sync activity
- **Pull-based**: Actuator pulls from ConfigHub; CI never touches the cluster directly

### Trade-offs
- **Cluster-admin access**: Worker needs broad permissions to apply arbitrary resources
- **Worker credentials**: Requires ConfigHub worker setup per environment
- **Manual target setup**: Units must be targeted to the worker before applying

### Future Improvements
- Auto-target units to workers based on labels or conventions
- Add worker health monitoring and alerting
- Implement multi-environment promotion via ConfigHub pipelines

## References

- [ADR-005: ConfigHub Integration Architecture](005-confighub-integration.md)
- [ConfigHub Worker Guide](https://docs.confighub.com/guide/workers/)
- [ISSUE-8.4 Plan](../../ISSUE-8.4-plan.md)
