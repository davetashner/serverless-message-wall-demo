# Current Focus

Last updated: 2026-01-30

## Demo Goal: E2E with Multi-Tenancy

Target: Two compelling demos showing ConfigHub as authority for both infrastructure AND workloads:

1. **Messagewall Infrastructure** - AWS resources via Crossplane (no K8s workloads)
2. **Order Platform Workloads** - Multi-tenant K8s deployments (5 teams × 2 envs)

---

## ConfigHub Space Structure (ADR-013)

```
ConfigHub Spaces (12 total):

# Infrastructure - Messagewall team
messagewall-dev          [Application=messagewall, Environment=dev]
messagewall-prod         [Application=messagewall, Environment=prod]

# Order Platform - 5 teams × 2 envs = 10 spaces
order-platform-ops-dev   [Application=order-platform, Team=platform-ops, Environment=dev]
order-platform-ops-prod  [Application=order-platform, Team=platform-ops, Environment=prod]
order-data-dev           [Application=order-platform, Team=data, Environment=dev]
order-data-prod          [Application=order-platform, Team=data, Environment=prod]
order-customer-dev       [Application=order-platform, Team=customer, Environment=dev]
order-customer-prod      [Application=order-platform, Team=customer, Environment=prod]
order-integrations-dev   [Application=order-platform, Team=integrations, Environment=dev]
order-integrations-prod  [Application=order-platform, Team=integrations, Environment=prod]
order-compliance-dev     [Application=order-platform, Team=compliance, Environment=dev]
order-compliance-prod    [Application=order-platform, Team=compliance, Environment=prod]
```

---

## Quick Start: Run the Demo

```bash
# 1. Create both clusters
scripts/bootstrap-kind.sh              # actuator cluster
scripts/bootstrap-workload-cluster.sh  # workload cluster

# 2. Build and load microservice image
cd app/microservices && ./build.sh && cd ../..
kind load docker-image messagewall-microservice:latest --name workload

# 3. Install Crossplane and Kyverno on actuator
scripts/bootstrap-crossplane.sh
scripts/bootstrap-aws-providers.sh     # auto-creates AWS credentials from aws cli
scripts/bootstrap-kyverno.sh

# 4. Install ArgoCD on both clusters
scripts/bootstrap-argocd.sh              # actuator
scripts/bootstrap-workload-argocd.sh     # workload

# 5. Create ConfigHub spaces (BEFORE auth setup - spaces must exist first)
cub space create messagewall-dev --label Environment=dev --label Application=messagewall
scripts/setup-order-platform-spaces.sh   # creates 10 Order Platform spaces

# 6. Configure ConfigHub credentials (requires spaces to exist)
scripts/setup-argocd-confighub-auth.sh        # actuator - creates worker in messagewall-dev
scripts/setup-workload-confighub-auth.sh      # workload - creates worker in order-platform-ops-dev

# 7. Publish Order Platform manifests to ConfigHub
scripts/publish-order-platform.sh --apply

# 8. Restart ArgoCD repo-servers and apply configurations
kubectl rollout restart deployment argocd-repo-server -n argocd --context kind-actuator
kubectl rollout restart deployment argocd-repo-server -n argocd --context kind-workload
kubectl apply -f platform/argocd/applicationset-order-platform.yaml --context kind-workload

# 9. Verify deployment
kubectl get applications -n argocd --context kind-workload
kubectl get pods --all-namespaces --context kind-workload | grep -E '^(platform|data|customer|integrations|compliance)'
```

---

## Team-to-Microservice Mapping

| Team | Namespace | Microservices | Business Context |
|------|-----------|---------------|------------------|
| platform-ops | platform-ops-{env} | heartbeat, sentinel | Observability, health |
| data | data-{env} | counter, reporter | Data aggregation |
| customer | customer-{env} | greeter, weather | Customer features |
| integrations | integrations-{env} | pinger, ticker | External integrations |
| compliance | compliance-{env} | auditor, quoter | Audit, policy |

---

## Demo Narrative

**Opening:** "ConfigHub is the single authority for ALL configuration - infrastructure AND workloads."

1. Show both clusters: `kubectl config get-contexts`
2. Show Crossplane pods in actuator cluster (infrastructure actuator)
3. Show microservice pods in workload cluster (10 services across 5 teams)
4. Show ConfigHub spaces: `cub space list`
5. **Bulk operation demo:** Update all dev environments at once
   ```bash
   scripts/publish-order-platform.sh --env dev --apply
   ```
6. **Team isolation:** Show that team A's space doesn't affect team B
7. **Crossplane reconciliation:** Delete Lambda, watch it heal
8. **Closing:** "One authority, multiple actuators, team isolation, continuous enforcement"

---

## Key Files Changed (EPIC-19 Implementation)

**New structure:**
- `infra/order-platform/{team}/{env}/` - Manifests per team/env
- `scripts/setup-order-platform-spaces.sh` - Create ConfigHub spaces
- `scripts/publish-order-platform.sh` - Publish to ConfigHub
- `platform/argocd/applicationset-order-platform.yaml` - ArgoCD ApplicationSet
- `docs/decisions/013-confighub-multi-tenancy-model.md` - Design rationale

**Deprecated:**
- `infra/workloads/` - Removed (replaced by order-platform)
- `scripts/publish-workloads-to-confighub.sh.deprecated`
- `platform/argocd/application-workloads.yaml.deprecated`

---

## Known Issues & Fixes (Session 2026-01-29)

### ArgoCD CMP Environment Variables
**Problem:** ArgoCD prefixes Application env vars with `ARGOCD_ENV_` prefix when passing to CMP sidecar.
**Fix:** In CMP generate script, use `${ARGOCD_ENV_CONFIGHUB_SPACE:-$CONFIGHUB_SPACE}` to handle both cases.

### ConfigHub Worker Permissions
**Problem:** Workers with `--org-role viewer` or `user` cannot list units in spaces.
**Fix:** Worker needs `--org-role admin` to have read access across all spaces.
```bash
cub worker update argocd-reader --space order-platform-ops-dev --org-role admin
```

### ConfigHub Worker Authentication
**Problem:** Worker credentials in ArgoCD secret named `confighub-actuator-credentials` (not `argocd-confighub-worker`).
**Setup:** Secret must contain `CONFIGHUB_WORKER_ID` and `CONFIGHUB_WORKER_SECRET` keys.

### HeadRevisionNum vs LiveRevisionNum
**Problem:** `cub unit apply` requires a Target; LiveRevisionNum=0 until target is set.
**Fix:** For pull-based ArgoCD sync, use HeadRevisionNum (latest pushed) instead of LiveRevisionNum.

### ArgoCD Deployment Env Var Conflict
**Problem:** Container-level CONFIGHUB_SPACE env var overrides Application env var.
**Fix:** Remove hardcoded CONFIGHUB_SPACE from deployment spec:
```bash
kubectl patch deployment argocd-repo-server -n argocd --type json \
  -p '[{"op": "remove", "path": "/spec/template/spec/containers/1/env/1"}]'
```

---

## Session 2026-01-30: Multi-Region XRD Demo Prep

### Progress Made

**East Region (us-east-1) - WORKING:**
- ✅ XRD and Composition applied to `kind-actuator-east`
- ✅ Claim `messagewall-dev-east` deployed via Crossplane
- ✅ All 17 AWS resources created (S3, DynamoDB, Lambda, EventBridge, IAM)
- ✅ Lambda artifacts uploaded to `messagewall-east-dev-205074708100`
- ✅ Static website deployed
- ✅ Function URL working: `https://thphwfdj6atcicaet3e4bmoyei0jfiwz.lambda-url.us-east-1.on.aws/`
- ✅ End-to-end flow tested: POST → DynamoDB → EventBridge → state.json

**West Region (us-west-2) - IN PROGRESS:**
- ✅ XRD and Composition applied to `kind-actuator-west`
- ✅ Claim `messagewall-dev-west` created
- ✅ Lambda artifacts uploaded to `messagewall-west-dev-205074708100`
- ✅ Permissions boundary updated to include us-west-2
- ⏳ Function URL permission not syncing (Crossplane reconciliation issues)
- ⏳ Kind cluster stability issues (Kyverno pods restarting)

### Composition Fix Made

Added missing `function-url-permission` resource to the composition at `platform/crossplane/compositions/serverless-event-app-aws.yaml`. This creates the Lambda resource-based policy required for public Function URL access.

### Known Issues (Session 2026-01-30)

**MessageWallRoleBoundary - Multi-Region:**
The permissions boundary only allowed `us-east-1`. Updated to include both regions:
```bash
# Fixed in AWS IAM policy v2
arn:aws:dynamodb:us-east-1:... AND arn:aws:dynamodb:us-west-2:...
arn:aws:logs:us-east-1:... AND arn:aws:logs:us-west-2:...
```

**Kind Cluster Stability:**
The `kind-actuator-west` cluster has intermittent stability issues:
- Kyverno pods restarting frequently
- Crossplane timeouts
- etcd request timeouts

**Function URL Permission Not Syncing:**
The Crossplane FunctionURL and Permission resources show stale status. May need:
1. Delete the claim and recreate
2. Or manually clear stuck annotations

### Next Steps

1. **Fix West Deployment:**
   - Investigate Kind cluster stability
   - Ensure FunctionURL and Permission resources sync properly
   - Test end-to-end west flow

2. **Verify Both Regions:**
   ```bash
   # East
   curl -X POST https://thphwfdj6atcicaet3e4bmoyei0jfiwz.lambda-url.us-east-1.on.aws/ \
     -H "Content-Type: application/json" -d '{"text":"East test"}'

   # West (once working)
   curl -X POST <west-url> -H "Content-Type: application/json" -d '{"text":"West test"}'
   ```

3. **Update index.html URLs:**
   - East website needs east API URL
   - West website needs west API URL

4. **Run Demo Script (Part 2-3 of docs/demo-script.md)**

### New Backlog Item

Added **EPIC-43: Platform configuration in ConfigHub** - Store XRDs, Compositions, and ProviderConfigs in a dedicated `messagewall-platform` ConfigHub space for versioned, auditable platform changes.

---

## Previous Work

### EPIC-36 Status (Partially Complete)

Issues 36.1-36.8 done. Remaining:
- ISSUE-36.9: Bulk timeout demo script
- ISSUE-36.10: Bulk tags demo script
- ISSUE-36.11: iTerm layout script

### EPIC-17 Status (Paused)

Production protection gates - paused pending demo completion.
