# ISSUE-8.4: Implement ConfigHub Actuation via ArgoCD

## Summary

Install ArgoCD in the actuator cluster with a ConfigHub plugin that syncs manifests from ConfigHub to Kubernetes. This completes the flow: Git → CI → ConfigHub → ArgoCD → Actuator → AWS.

## Architecture Decision

**Approach**: ArgoCD Config Management Plugin (CMP) using `cub` CLI

Why CMP over Git-branch approach:
- ConfigHub remains the single source of truth (not Git)
- No intermediate storage that could drift
- Demonstrates ConfigHub as a real control plane

```
ConfigHub (authoritative) ──poll──> ArgoCD CMP ──apply──> Kubernetes ──reconcile──> AWS
```

## Files to Create

| File | Purpose |
|------|---------|
| `scripts/bootstrap-argocd.sh` | Install ArgoCD via Helm |
| `platform/argocd/values.yaml` | ArgoCD Helm values (demo mode) |
| `platform/argocd/cmp-plugin.yaml` | ConfigHub CMP ConfigMap |
| `platform/argocd/application-dev.yaml` | ArgoCD Application for dev |
| `scripts/setup-argocd-confighub-auth.sh` | Create ConfigHub credentials Secret |
| `docs/decisions/009-argocd-confighub-sync.md` | ADR documenting this decision |

## Files to Update

| File | Change |
|------|--------|
| `docs/setup-actuator-cluster.md` | Add Phase 5 (ArgoCD) and Phase 6 (ConfigHub auth) |
| `docs/planes.md` | Update data flow diagram to show ArgoCD |
| `CLAUDE.md` | Add bootstrap-argocd.sh to commands |
| `beads/backlog.jsonl` | Mark ISSUE-8.4 as done |

## Implementation Steps

### Step 1: Create bootstrap-argocd.sh
Follow pattern of existing bootstrap scripts:
- Check prerequisites (helm, kubectl)
- Add argo Helm repo
- Idempotency check
- Install with `--wait`
- Apply CMP ConfigMap
- Show status

### Step 2: Create ArgoCD Helm values
```yaml
# Demo mode: single replicas, no HA
controller:
  replicas: 1
server:
  replicas: 1
  extraArgs:
    - --insecure  # Local kind cluster
repoServer:
  replicas: 1
  volumes:
    - name: cmp-plugin
      configMap:
        name: argocd-cmp-confighub
    - name: confighub-credentials
      secret:
        secretName: confighub-actuator-credentials
```

### Step 3: Create ConfigHub CMP Plugin
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-cmp-confighub
  namespace: argocd
data:
  plugin.yaml: |
    apiVersion: argoproj.io/v1alpha1
    kind: ConfigManagementPlugin
    metadata:
      name: confighub
    spec:
      init:
        command: ["/bin/sh", "-c"]
        args: ["cub auth login --as-worker"]
      generate:
        command: ["/bin/sh", "-c"]
        args:
          - |
            for unit in $(cub unit list --space "$CONFIGHUB_SPACE" --output names); do
              cub unit get --space "$CONFIGHUB_SPACE" "$unit" --output yaml
              echo "---"
            done
```

### Step 4: Create ArgoCD Application
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: messagewall-dev
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://hub.confighub.com
    path: messagewall-dev
    plugin:
      name: confighub
      env:
        - name: CONFIGHUB_SPACE
          value: messagewall-dev
  destination:
    server: https://kubernetes.default.svc
    namespace: default
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

### Step 5: Create credentials setup script
```bash
# Create ConfigHub worker for ArgoCD
cub worker create --space messagewall-dev actuator-sync

# Store as Kubernetes Secret
kubectl create secret generic confighub-actuator-credentials \
  --namespace argocd \
  --from-literal=CONFIGHUB_WORKER_ID="..." \
  --from-literal=CONFIGHUB_WORKER_SECRET="..."
```

### Step 6: Create ADR-009
Document the decision to use ArgoCD CMP for ConfigHub sync.

### Step 7: Update documentation
- Update setup guide with new phases
- Update planes.md with ArgoCD in the flow
- Update CLAUDE.md with new commands

## Acceptance Criteria Mapping

| Criteria | How Satisfied |
|----------|---------------|
| Actuation mechanism documented | ADR-009 + updated setup guide |
| ConfigHub-approved config reaches actuator | ArgoCD CMP pulls from ConfigHub |
| No direct kubectl apply from CI | CI only publishes to ConfigHub; ArgoCD applies |
| Status observable in ConfigHub and K8s | `cub unit list` + `kubectl get application` |

## Verification

1. Run bootstrap-argocd.sh - ArgoCD pods should be running
2. Run setup-argocd-confighub-auth.sh - Secret created
3. Apply application-dev.yaml - Application created
4. Check sync status: `kubectl get application messagewall-dev -n argocd`
5. Verify Crossplane resources are applied: `kubectl get managed`
6. Push a change to Git → CI publishes to ConfigHub → ArgoCD syncs → AWS updated

## Open Question

The CMP approach requires a sidecar container with `cub` CLI. For the demo, we have two options:
1. Build a custom Docker image with `cub` CLI
2. Use init container to download `cub` CLI at runtime

I recommend option 2 (init container download) for simplicity.
