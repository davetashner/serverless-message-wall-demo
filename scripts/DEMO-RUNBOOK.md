# ConfigHub Multi-Cluster Demo Runbook

**Goal:** Show ConfigHub as the single authority managing infrastructure (Crossplane) and workloads (microservices) across two Kubernetes clusters.

---

## 30 Minutes Before Demo

### Pre-flight Checklist

```bash
cd ~/Development/serverless-message-wall-demo

# 1. Verify both clusters exist
kind get clusters
# Expected: actuator, workload

# 2. Restart Crossplane providers (prevents stale reconciliation)
kubectl rollout restart deployment -n crossplane-system --selector=pkg.crossplane.io/provider --context kind-actuator

# 3. Verify Crossplane resources are healthy
kubectl get managed --context kind-actuator
# All should show SYNCED=True, READY=True

# 4. Verify microservices are running
kubectl get pods -n microservices --context kind-workload
# All 10 should be Running

# 5. Verify AWS access
aws sts get-caller-identity
aws lambda list-functions --query 'Functions[?starts_with(FunctionName, `messagewall`)].FunctionName'
```

### If Something Is Wrong

```bash
# Cluster missing? Recreate it:
./scripts/bootstrap-kind.sh              # actuator
./scripts/bootstrap-workload-cluster.sh  # workload

# Microservices not running? Redeploy:
cd app/microservices && ./build.sh
kind load docker-image messagewall-microservice:latest --name workload
kubectl apply -f infra/workloads/ --context kind-workload

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
- **WORKLOAD** — `kubectl get pods -n microservices -w`
- **HEARTBEAT** — Live logs from heartbeat service
- **COUNTER** — Live logs from counter service

---

## Part 1: Set the Stage (2 min)

> **SAY:** "I'm going to show you ConfigHub managing two Kubernetes clusters from a single source of truth."

### Show the two clusters

```bash
kubectl config get-contexts
```

> **SAY:** "Two clusters: actuator runs Crossplane for AWS infrastructure, workload runs our microservices."

### Point to ACTUATOR pane

> **SAY:** "Here you can see all the AWS resources Crossplane is managing — Lambda functions, DynamoDB tables, S3 buckets, IAM roles. All declared in ConfigHub."

### Point to WORKLOAD pane

> **SAY:** "And here are 10 microservices running in our workload cluster. Each has a distinct name and logging pattern."

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

### Watch the ACTUATOR pane

> **SAY:** "Watch the ACTUATOR pane. Crossplane runs a reconciliation loop every 60 seconds. When it detects the drift..."

*(Wait up to 60 seconds — the managed resource will briefly show SYNCED=False then return to SYNCED=True)*

### Verify it's back

```bash
aws lambda get-function --function-name messagewall-api-handler --query 'Configuration.FunctionName'
```

> **SAY:** "Crossplane recreated it automatically. The desired state in ConfigHub always wins. This is self-healing infrastructure."

---

## Part 3: Bulk Change — Update Lambda Timeout (3 min)

> **SAY:** "Now let's see how ConfigHub enables bulk changes across all our infrastructure."

### Show current timeout

```bash
aws lambda get-function-configuration --function-name messagewall-api-handler --query '{Name:FunctionName,Timeout:Timeout}'
aws lambda get-function-configuration --function-name messagewall-snapshot-writer --query '{Name:FunctionName,Timeout:Timeout}'
```

> **SAY:** "Both Lambdas have a 10 second timeout. Let's change them both to 30 seconds through ConfigHub."

### Show the change in ConfigHub (or local manifests)

```bash
# If using local manifests:
grep -r "timeout:" infra/dev/
```

> **SAY:** "In ConfigHub, I update the timeout value. One change, applied everywhere."

### Watch ACTUATOR pane as Crossplane applies

> **SAY:** "Watch the ACTUATOR pane — Crossplane picks up the change and updates AWS."

### Verify in AWS

```bash
aws lambda get-function-configuration --function-name messagewall-api-handler --query '{Name:FunctionName,Timeout:Timeout}'
aws lambda get-function-configuration --function-name messagewall-snapshot-writer --query '{Name:FunctionName,Timeout:Timeout}'
```

> **SAY:** "Both updated. One source of truth, consistent enforcement."

---

## Part 4: Microservices Are Observable (1 min)

### Point to the log panes

> **SAY:** "Our microservices generate sparse, readable logs. In a real system, these could be services across multiple teams."

### Show all pods

```bash
kubectl get pods -n microservices --context kind-workload
```

> **SAY:** "10 services, each with distinct names. Easy to see what's running, easy to debug."

### Optionally show another service's logs

```bash
kubectl logs deployment/quoter -n microservices --context kind-workload --tail=5
```

---

## Part 5: Closing (1 min)

> **SAY:** "To recap what you just saw:"

1. **One ConfigHub** — single source of truth for all configuration
2. **Multiple actuators** — Crossplane for AWS, ArgoCD for Kubernetes workloads
3. **Continuous enforcement** — drift is detected and corrected automatically
4. **Bulk changes** — update once, apply everywhere

> **SAY:** "This is how you manage infrastructure at scale with confidence."

---

## Emergency Recovery Commands

If something breaks during the demo:

```bash
# Lambda not recreating? Restart the provider:
kubectl rollout restart deployment -n crossplane-system -l pkg.crossplane.io/provider=provider-aws-lambda --context kind-actuator

# Microservice pod crashed? It'll auto-restart, or:
kubectl rollout restart deployment/heartbeat -n microservices --context kind-workload

# Need to reset everything?
kubectl apply -f infra/workloads/ --context kind-workload
```

---

## Quick Reference

| Cluster | Context | What's Running |
|---------|---------|----------------|
| actuator | `kind-actuator` | Crossplane, manages AWS |
| workload | `kind-workload` | 10 microservices |

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
