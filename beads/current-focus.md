# Current Focus

Last updated: 2026-01-28

## Weekend Goal: E2E Demo Ready by Next Week

Target: Complete EPIC-36 to have a compelling multi-cluster demo showing:
1. **ConfigHub as central authority** - managing both infrastructure and workloads
2. **Observable microservices** - 10 pods with distinct names, sparse logs visible in kubectl
3. **Crossplane reconciliation** - delete a Lambda, watch it heal back

---

## EPIC-36 Implementation Status

| Issue | Title | Status |
|-------|-------|--------|
| ISSUE-36.1 | Create workload cluster bootstrap script | **DONE** |
| ISSUE-36.2 | Install ArgoCD on workload cluster | **DONE** |
| ISSUE-36.3 | Design 10 microservices | **DONE** |
| ISSUE-36.4 | Create container image | **DONE** |
| ISSUE-36.5 | Create K8s manifests | **DONE** |
| ISSUE-36.6 | Publish to ConfigHub | **DONE** (script ready) |
| ISSUE-36.7 | Multi-cluster demo script | **DONE** |
| ISSUE-36.8 | Reconciliation demo script | **DONE** |

### Files Created

**Bootstrap scripts:**
- `scripts/bootstrap-workload-cluster.sh` - Create kind cluster "workload"
- `scripts/bootstrap-workload-argocd.sh` - Install ArgoCD on workload cluster
- `scripts/setup-workload-confighub-auth.sh` - Configure ConfigHub credentials
- `scripts/publish-workloads-to-confighub.sh` - Publish manifests to ConfigHub

**Container image:**
- `app/microservices/Dockerfile` - Minimal Alpine image
- `app/microservices/entrypoint.sh` - Service-specific logging
- `app/microservices/build.sh` - Build script

**Kubernetes manifests:**
- `infra/workloads/namespace.yaml`
- `infra/workloads/heartbeat.yaml`
- `infra/workloads/ticker.yaml`
- `infra/workloads/greeter.yaml`
- `infra/workloads/counter.yaml`
- `infra/workloads/weather.yaml`
- `infra/workloads/quoter.yaml`
- `infra/workloads/pinger.yaml`
- `infra/workloads/auditor.yaml`
- `infra/workloads/reporter.yaml`
- `infra/workloads/sentinel.yaml`

**ArgoCD config:**
- `platform/argocd/values-workload.yaml` - Helm values for workload cluster
- `platform/argocd/application-workloads.yaml` - ArgoCD Application

**Demo scripts:**
- `scripts/demo-multi-cluster.sh` - Multi-cluster narrative demo
- `scripts/demo-reconciliation.sh` - Crossplane self-healing demo

---

## Quick Start: Run the Demo

```bash
# 1. Create both clusters
scripts/bootstrap-kind.sh              # actuator cluster
scripts/bootstrap-workload-cluster.sh  # workload cluster

# 2. Build and load microservice image
cd app/microservices && ./build.sh
kind load docker-image messagewall-microservice:latest --name workload

# 3. Install ArgoCD on both clusters
scripts/bootstrap-argocd.sh           # actuator
scripts/bootstrap-workload-argocd.sh  # workload

# 4. Configure ConfigHub credentials
scripts/setup-argocd-confighub-auth.sh        # actuator
scripts/setup-workload-confighub-auth.sh      # workload

# 5. Publish microservices to ConfigHub
scripts/publish-workloads-to-confighub.sh --apply

# 6. Apply ArgoCD Applications
kubectl apply -f platform/argocd/application-dev.yaml --context kind-actuator
kubectl apply -f platform/argocd/application-workloads.yaml --context kind-workload

# 7. Run demos
scripts/demo-multi-cluster.sh
scripts/demo-reconciliation.sh
```

---

## Microservices Reference

| Name | Interval | Log Example |
|------|----------|-------------|
| heartbeat | 30s | `[heartbeat] pulse #127 - all systems nominal` |
| ticker | 45s | `[ticker] 2026-01-28T14:32:00Z - tick` |
| greeter | 40s | `[greeter] Hello from pod greeter-7f8b9!` |
| counter | 20s | `[counter] count=4582` |
| weather | 60s | `[weather] Current: sunny, 72F` |
| quoter | 55s | `[quoter] "The best way to predict..."` |
| pinger | 25s | `[pinger] upstream check: 23ms, status=ok` |
| auditor | 35s | `[auditor] event=config_read user=system` |
| reporter | 50s | `[reporter] summary: 10 pods, 0 alerts` |
| sentinel | 45s | `[sentinel] watchdog healthy` |

---

## Demo Narrative

**Opening:** "ConfigHub is the single authority for all configuration."

1. Show both clusters: `kubectl config get-contexts`
2. Show Crossplane pods in actuator cluster
3. Show microservice pods in workload cluster (10 distinct names)
4. Tail logs to show activity
5. Show ConfigHub spaces (messagewall-dev, messagewall-workloads)
6. Show ArgoCD sync status on both clusters
7. **Reconciliation demo:** Delete Lambda in AWS, watch Crossplane recreate it
8. **Closing:** "One authority, multiple actuators, continuous enforcement"

---

## Previous Work

### EPIC-17 Status (Paused)

| Issue | Status |
|-------|--------|
| ISSUE-17.1 | Done |
| ISSUE-17.2 | Done |
| ISSUE-17.3 | Pending |
| ISSUE-17.4 | Pending |
| ISSUE-17.5 | Pending |
