# ConfigHub Multi-Cluster Demo Runbook

**Goal:** Show ConfigHub as the single authority managing infrastructure (Crossplane) and workloads (microservices) across two Kubernetes clusters.

---

## 30 Minutes Before Demo

### Pre-flight Checklist

```bash
cd ~/Development/serverless-message-wall-demo

# 1. Run automated pre-flight checks
./scripts/demo-preflight.sh

# 2. Restart Crossplane providers (prevents stale reconciliation)
kubectl rollout restart deployment -n crossplane-system --selector=pkg.crossplane.io/provider --context kind-actuator

# 3. Verify Crossplane resources are healthy
kubectl get managed --context kind-actuator
# All should show SYNCED=True, READY=True

# 4. Verify Order Platform pods are running (20 pods across 5 teams)
kubectl get pods --all-namespaces --context kind-workload | grep -E '^(platform-ops|data|customer|integrations|compliance)'

# 5. Verify AWS access
aws sts get-caller-identity
aws lambda list-functions --query 'Functions[?starts_with(FunctionName, `messagewall`)].FunctionName'
```

### If Something Is Wrong

```bash
# Cluster missing? Recreate it:
./scripts/bootstrap-kind.sh              # actuator
./scripts/bootstrap-workload-cluster.sh  # workload

# Order Platform not running? Redeploy:
cd app/microservices && ./build.sh
kind load docker-image messagewall-microservice:latest --name workload
./scripts/publish-order-platform.sh --apply
kubectl rollout restart deployment argocd-repo-server -n argocd --context kind-workload

# Messagewall infrastructure not deployed? Deploy it:
./scripts/deploy-messagewall.sh

# Crossplane unhealthy? Check providers:
kubectl get pods -n crossplane-system --context kind-actuator
kubectl logs -n crossplane-system -l pkg.crossplane.io/provider=provider-aws-lambda --tail=20 --context kind-actuator
```

---

## Start the Demo

### Open the Demo Layout

```bash
./scripts/demo-iterm-layout.sh
```

This opens iTerm2 with 5 panes:
- **COMMAND** — You type here
- **ACTUATOR** — `kubectl get managed -w`
- **WORKLOAD** — `kubectl get pods -w` (Order Platform namespaces)
- **HEARTBEAT** — Live logs from heartbeat service (platform-ops-dev)
- **COUNTER** — Live logs from counter service (data-dev)

---

## Part 1: Set the Stage (2 min)

> **SAY:** "I'm going to show you ConfigHub managing two Kubernetes clusters from a single source of truth."

### Show the two clusters

```bash
kubectl config get-contexts
```

> **SAY:** "Two clusters: actuator runs Crossplane for AWS infrastructure, workload runs our Order Platform microservices."

### Point to ACTUATOR pane

> **SAY:** "Here you can see all the AWS resources Crossplane is managing — Lambda functions, DynamoDB tables, S3 buckets, IAM roles. All declared in ConfigHub."

### Point to WORKLOAD pane

> **SAY:** "And here are 20 microservices across 5 teams, each in their own namespace. Platform-ops, Data, Customer, Integrations, and Compliance."

### Point to HEARTBEAT and COUNTER panes

> **SAY:** "Live logs from two of them — you can see they're actively running."

---

## Part 2: Crossplane Self-Healing (3 min)

> **SAY:** "Let me show you what happens when someone manually changes AWS outside of ConfigHub."

### Show the Lambda exists

```bash
aws lambda get-function --function-name messagewall-api-handler --query 'Configuration.{Name:FunctionName,Timeout:Timeout,Memory:MemorySize}'
```

### Delete it directly in AWS

```bash
aws lambda delete-function --function-name messagewall-api-handler
```

> **SAY:** "I just deleted our API handler Lambda directly in AWS. This simulates an accidental deletion or unauthorized change."

### Verify it's gone

```bash
aws lambda get-function --function-name messagewall-api-handler
# Should show ResourceNotFoundException
```

### Trigger Crossplane reconciliation (speeds up detection)

```bash
kubectl annotate function.lambda.aws.upbound.io -l function=api-handler --overwrite reconcile=now --context kind-actuator
```

### Watch the ACTUATOR pane

> **SAY:** "Watch the ACTUATOR pane. Crossplane detects the drift and recreates the Lambda."

*(Wait ~30 seconds — the managed resource will briefly show SYNCED=False then return to SYNCED=True)*

### Verify it's back

```bash
aws lambda get-function --function-name messagewall-api-handler --query 'Configuration.FunctionName'
```

> **SAY:** "Crossplane recreated it automatically. The desired state in ConfigHub always wins. This is self-healing infrastructure."

---

## Part 3: Multi-Tenant Order Platform (2 min)

> **SAY:** "Now let's look at how ConfigHub manages multiple teams."

### Show ConfigHub spaces

```bash
cub space list | grep -E '(messagewall|order-)'
```

> **SAY:** "Each team has their own ConfigHub space. 5 teams times 2 environments equals 10 spaces for Order Platform, plus messagewall for infrastructure."

### Show team namespaces

```bash
kubectl get namespaces --context kind-workload | grep -E '(platform-ops|data|customer|integrations|compliance)'
```

### Show pods per team

```bash
kubectl get pods -n platform-ops-dev --context kind-workload
kubectl get pods -n data-dev --context kind-workload
```

> **SAY:** "Each team owns their namespace. Platform-ops runs heartbeat and sentinel. Data runs counter and reporter. Complete isolation."

---

## Part 4: Bulk Change via ConfigHub (3 min)

> **SAY:** "Now let's see how ConfigHub enables bulk changes across all environments."

### Show current state

```bash
# Show all dev namespaces at once
kubectl get pods -n platform-ops-dev -n data-dev -n customer-dev --context kind-workload
```

### Explain the bulk change

> **SAY:** "If I need to update all dev environments, I can do it in one operation through ConfigHub."

```bash
# Example: Publish changes to all dev environments
./scripts/publish-order-platform.sh --env dev --apply
```

### Watch ArgoCD sync

```bash
kubectl get applications -n argocd --context kind-workload
```

> **SAY:** "ArgoCD picks up the changes from ConfigHub and syncs all 5 dev environments simultaneously."

---

## Part 5: Closing (1 min)

> **SAY:** "To recap what you just saw:"

1. **One ConfigHub** — single source of truth for all configuration
2. **Multiple actuators** — Crossplane for AWS, ArgoCD for Kubernetes workloads
3. **Team isolation** — each team owns their own space and namespace
4. **Continuous enforcement** — drift is detected and corrected automatically
5. **Bulk changes** — update once, apply everywhere

> **SAY:** "This is how you manage infrastructure at scale with confidence."

---

## Emergency Recovery Commands

If something breaks during the demo:

```bash
# Lambda not recreating? Restart the provider:
kubectl rollout restart deployment -n crossplane-system -l pkg.crossplane.io/provider=provider-aws-lambda --context kind-actuator

# Microservice pod crashed? It'll auto-restart, or:
kubectl rollout restart deployment/heartbeat -n platform-ops-dev --context kind-workload

# ArgoCD not syncing? Restart repo-server:
kubectl rollout restart deployment argocd-repo-server -n argocd --context kind-workload

# Need to redeploy messagewall infrastructure?
./scripts/deploy-messagewall.sh
```

---

## Quick Reference

| Cluster | Context | What's Running |
|---------|---------|----------------|
| actuator | `kind-actuator` | Crossplane, manages AWS |
| workload | `kind-workload` | 20 microservices across 5 teams |

| Team | Namespace (dev) | Services |
|------|-----------------|----------|
| platform-ops | platform-ops-dev | heartbeat, sentinel |
| data | data-dev | counter, reporter |
| customer | customer-dev | greeter, weather |
| integrations | integrations-dev | pinger, ticker |
| compliance | compliance-dev | auditor, quoter |

| Service | Log Interval | Sample Output |
|---------|--------------|---------------|
| heartbeat | 30s | `pulse #127 - all systems nominal` |
| counter | 20s | `count=4582` |
| ticker | 45s | `tick` |
| greeter | 40s | `Hello from pod greeter-7f8b9!` |
| weather | 60s | `Current: sunny, 72F` |
| quoter | 55s | `"The best way to predict..."` |
| pinger | 25s | `upstream check: 23ms, status=ok` |
| auditor | 35s | `event=config_read user=system` |
| reporter | 50s | `summary: 10 pods, 0 alerts` |
| sentinel | 45s | `watchdog healthy` |
