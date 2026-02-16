# Demo Script: ConfigHub as Configuration Data Substrate

This is the primary demo script for presenting the serverless message wall and Order Platform demos. It shows ConfigHub as a **configuration data substrate** where multiple sources (Developers, Security, FinOps, SRE, CI/CD) read and write configuration - not just a developer tool.

**Key message:** A service's configuration is no longer owned by developers in isolation. ConfigHub aggregates changes from across the organization with full audit trail.

**Architecture change (ADR-014):** ConfigHub now stores **fully-expanded Crossplane managed resources** (19 per environment), not abstract Claims. The Composition is rendered at build time via `crossplane render`, giving ConfigHub full resource-level visibility, diffs, and rollback.

**Total time:** ~58-64 minutes (can be shortened by skipping Parts 5, 7)

---

## Demo Flow Overview

```
┌──────────────────────────────────────────────────────────────────────────┐
│ Part 1: The Claim (5 min)                                                │
│   Show XRD schema, Kustomize overlays, dev vs prod differences           │
└──────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌──────────────────────────────────────────────────────────────────────────┐
│ Part 2: Render & Deploy East (10 min)                                    │
│   Render composition → 19 resources → ConfigHub → Crossplane → AWS      │
└──────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌──────────────────────────────────────────────────────────────────────────┐
│ Part 3: Deploy West (3 min)                                              │
│   Same flow, faster - show us-west-2 in browser URL                      │
└──────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌──────────────────────────────────────────────────────────────────────────┐
│ Part 4: Deploy Prod (5 min)                                              │
│   Show prod differences, deploy both regions                             │
└──────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌──────────────────────────────────────────────────────────────────────────┐
│ Part 5: Revision Rollout (5-7 min)                                       │
│   Stage a resource-level change without deploying, then promote          │
└──────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌──────────────────────────────────────────────────────────────────────────┐
│ Part 6: ConfigHub Exploration (5 min)                                    │
│   Filter, browse 19 individual resources per environment                 │
└──────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌──────────────────────────────────────────────────────────────────────────┐
│ Part 7: Break-Glass Recovery (5-7 min)                                   │
│   Emergency AWS change, drift detection, reconciliation                  │
└──────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌──────────────────────────────────────────────────────────────────────────┐
│ Part 8: K8s Workloads (10 min)                                           │
│   Deploy 10 microservices to workload cluster via ConfigHub              │
└──────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌──────────────────────────────────────────────────────────────────────────┐
│ Part 9: Bulk Security Edit (5-7 min)                                     │
│   Change all deployments from permissive to restricted security          │
└──────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌──────────────────────────────────────────────────────────────────────────┐
│ Part 10: Multi-Source Configuration (5 min)                              │
│   Show how Security, FinOps, SRE all write to the same config substrate  │
└──────────────────────────────────────────────────────────────────────────┘
```

---

## Prerequisites

Run the preflight check before the demo:

```bash
./scripts/demo-preflight.sh
```

This verifies:
- Both actuator clusters running (actuator-east, actuator-west)
- Workload cluster running (optional - only needed for Parts 8-9)
- All ConfigHub spaces exist (4 messagewall + 10 order-platform)
- AWS credentials valid
- Docker running (required for `crossplane render`)
- crossplane CLI, kustomize, yq installed

**Note:** The workload cluster is only needed for Parts 8-9 (K8s Workloads). You can run Parts 1-7 with just the actuator clusters, saving ~1GB RAM until you need the workload cluster.

---

## Part 1: The Claim (5 min)

**Opening:**
> "Let's start with how developers request infrastructure. They don't write Terraform or CloudFormation - they write a simple claim."

### Show the Minimal Schema

```bash
# Show the XRD schema - required fields
cat platform/crossplane/xrd/serverless-event-app.yaml | grep -A 5 "required:" | head -10
```

**Say:**
> "Only two fields are required: environment and awsAccountId. Everything else has sensible defaults."

```yaml
spec:
  environment: dev              # Required: dev | staging | prod
  awsAccountId: "123456789012"  # Required: 12-digit AWS account
```

### Show the Full Schema

```bash
# Show all available fields from the docs
head -70 docs/claim-authoring.md | tail -30
```

**Say:**
> "Optional fields let you tune memory, timeout, region, and more. But you don't have to specify them."

### Show Kustomize Overlays

```bash
# Show the overlay structure
find infra/claims -type f | sort

# Show a dev overlay
cat infra/claims/overlays/dev-east/kustomization.yaml
```

### Call Out Dev vs Prod Differences

```bash
# Render and compare dev vs prod
echo "=== DEV ===" && kubectl kustomize infra/claims/overlays/dev-east | grep -E '(lambdaMemory|lambdaTimeout)'
echo ""
echo "=== PROD ===" && kubectl kustomize infra/claims/overlays/prod-east | grep -E '(lambdaMemory|lambdaTimeout|annotations:)' -A 2
```

**Say:**
> "Prod overlays increase Lambda memory from 128 to 256 MB, timeout from 10 to 30 seconds, and add production annotations for operational metadata."

| Setting | Dev | Prod | Why |
|---------|-----|------|-----|
| `lambdaMemory` | 128 MB | 256 MB | Prod handles more traffic |
| `lambdaTimeout` | 10 sec | 30 sec | Prod may have slower dependencies |
| `annotations` | (none) | `tier: production`, `oncall: platform-team` | Operational routing |

---

## Part 2: Render & Deploy East (10 min)

**Say:**
> "Let's deploy to us-east-1. Here's the new pipeline: the Claim goes through the Crossplane Composition at build time, producing 19 fully-expanded AWS resource definitions. ConfigHub stores each one individually."

### Render the Composition

```bash
# Render the dev-east claim through the Composition
./scripts/render-composition.sh --overlay dev-east --output-dir /tmp/rendered/dev-east
```

**Say:**
> "That took the 10-field Claim and expanded it through the Composition into 19 individual AWS resources: S3 bucket, DynamoDB table, two Lambdas, IAM roles, EventBridge rules, permissions..."

### Inspect the Expanded Resources

```bash
# See what was produced
ls -1 /tmp/rendered/dev-east/

# Look at a specific resource
cat /tmp/rendered/dev-east/api-handler.yaml
```

**Say:**
> "Each file is a single Crossplane managed resource. This is exactly what Crossplane will reconcile against AWS. No abstraction layer at runtime."

### Validate Policies

```bash
# Run policy checks on the expanded resources
./scripts/validate-policies.sh /tmp/rendered/dev-east
```

**Say:**
> "Policy validation runs on the fully-expanded resources, not the abstract Claim. We can check Lambda memory bounds, IAM wildcard policies - anything we want - before it ever reaches a cluster."

### Publish to ConfigHub

```bash
# Publish each resource as an individual ConfigHub unit
SPACE="messagewall-dev-east"
for yaml in /tmp/rendered/dev-east/*.yaml; do
  unit=$(basename "$yaml" .yaml)
  cub unit create --space "$SPACE" "$unit" --allow-exists 2>/dev/null || true
  cub unit update --space "$SPACE" "$unit" "$yaml" --change-desc "Demo: initial deploy"
done

# Show all 19 units in ConfigHub
cub unit list --space messagewall-dev-east
```

**Say:**
> "19 individual units, each queryable, diffable, and independently rollbackable. That's the power of expanding at build time."

### Apply to Make It Live

```bash
# Apply all units (makes them live for ArgoCD to sync)
for unit in $(cub unit list --space messagewall-dev-east --format json | jq -r '.[].name'); do
  cub unit apply --space messagewall-dev-east "$unit"
done
```

### Watch Crossplane Reconcile

```bash
# In a split terminal, watch resources
kubectl get functions,buckets,tables -w --context kind-actuator-east
```

**Say:**
> "Crossplane receives individual managed resources from ArgoCD and reconciles each one against AWS. No Composition evaluation at runtime - that already happened in CI."

### Open in Browser

```bash
# Get the website URL
BUCKET=$(aws s3 ls | grep messagewall-east | awk '{print $3}')
open "http://${BUCKET}.s3-website-us-east-1.amazonaws.com/"
```

**Say:**
> "Notice 'us-east-1' in the URL. This is our east region deployment."

---

## Part 3: Deploy West (3 min)

**Say:**
> "Let's quickly do the same for us-west-2."

```bash
# Render, validate, and publish in one flow
./scripts/render-composition.sh --overlay dev-west --output-dir /tmp/rendered/dev-west

SPACE="messagewall-dev-west"
for yaml in /tmp/rendered/dev-west/*.yaml; do
  unit=$(basename "$yaml" .yaml)
  cub unit create --space "$SPACE" "$unit" --allow-exists 2>/dev/null || true
  cub unit update --space "$SPACE" "$unit" "$yaml" --change-desc "Demo: initial deploy" --wait
done

# Wait for resources (optional, can skip if short on time)
kubectl wait --for=condition=Ready functions --all --context kind-actuator-west --timeout=120s

# Open in browser
BUCKET=$(aws s3 ls | grep messagewall-west | awk '{print $3}')
open "http://${BUCKET}.s3-website-us-west-2.amazonaws.com/"
```

**Say:**
> "Now 'us-west-2' in the URL. Dev is running in two regions. Each region has its own 19-unit ConfigHub space."

---

## Part 4: Deploy Prod (5 min)

**Say:**
> "Now let's deploy production. Remember the differences: more memory, longer timeout, production annotations."

### Show the Prod Overlay

```bash
# Show what's different in prod
kubectl kustomize infra/claims/overlays/prod-east | grep -E '(lambdaMemory|lambdaTimeout|annotations:|tier:|oncall:)'
```

### Render and Compare

```bash
# Render prod
./scripts/render-composition.sh --overlay prod-east --output-dir /tmp/rendered/prod-east

# Compare Lambda config: dev vs prod
echo "=== DEV ===" && grep -E '(memorySize|timeout):' /tmp/rendered/dev-east/api-handler.yaml
echo "=== PROD ===" && grep -E '(memorySize|timeout):' /tmp/rendered/prod-east/api-handler.yaml
```

**Say:**
> "Same Composition, different inputs. Prod Lambdas get 256 MB and 30-second timeouts. The expanded resources show the exact difference."

### Deploy Both Prod Regions

```bash
# Render and publish prod-east
for yaml in /tmp/rendered/prod-east/*.yaml; do
  unit=$(basename "$yaml" .yaml)
  cub unit create --space messagewall-prod-east "$unit" --allow-exists 2>/dev/null || true
  cub unit update --space messagewall-prod-east "$unit" "$yaml" --change-desc "Demo: prod deploy"
done

# Render and publish prod-west
./scripts/render-composition.sh --overlay prod-west --output-dir /tmp/rendered/prod-west
for yaml in /tmp/rendered/prod-west/*.yaml; do
  unit=$(basename "$yaml" .yaml)
  cub unit create --space messagewall-prod-west "$unit" --allow-exists 2>/dev/null || true
  cub unit update --space messagewall-prod-west "$unit" "$yaml" --change-desc "Demo: prod deploy"
done
```

### Verify Prod Resources

```bash
# Check prod Lambda has higher memory
aws lambda get-function-configuration \
  --function-name messagewall-east-prod-api-handler \
  --region us-east-1 \
  --query '{Memory: MemorySize, Timeout: Timeout}'
```

**On Admission Controls (brief mention):**
> "By the way, admission controls work here just like in Kubernetes - validating or mutating. ConfigHub Triggers can block non-compliant config before it even reaches the cluster. We won't demo that today, but it's the same pattern."

---

## Part 5: Revision Rollout (5-7 min)

**Say:**
> "What if you want to stage a change without deploying it immediately? With individual resources in ConfigHub, you can stage changes at the resource level."

### Explain Head vs Live

> "**HeadRevisionNum** is the latest pushed revision. **LiveRevisionNum** is what's actually deployed. They can differ - per resource."

### Push a Change (Head Only)

```bash
# Get current api-handler config
cub unit get --space messagewall-prod-east api-handler --data-only > /tmp/api-handler.yaml

# Edit timeout (10 → 45 in the forProvider spec)
sed 's/timeout: 10/timeout: 45/' /tmp/api-handler.yaml > /tmp/api-handler-updated.yaml

# Push new revision (advances Head, not Live)
cub unit update --space messagewall-prod-east api-handler /tmp/api-handler-updated.yaml \
  --change-desc "Stage: increase API handler timeout to 45s"
```

### Show the Gap

```bash
# See Head vs Live for api-handler
cub unit list --space messagewall-prod-east | grep api-handler
```

**Say:**
> "Head is now 2, Live is still 1. The other 18 resources are unchanged. Nothing changed in Kubernetes or AWS yet."

### Show the Diff

```bash
# See what would change
cub unit diff --space messagewall-prod-east api-handler
```

**Say:**
> "With expanded resources, the diff shows the exact YAML field that changed. Not 'lambdaTimeout went from 30 to 45' on an abstract claim - the actual `spec.forProvider.timeout` on the Lambda Function resource."

### Promote

```bash
# Make it live
cub unit apply --space messagewall-prod-east api-handler
```

**Say:**
> "Now Live equals Head for just that one resource. ArgoCD syncs, Crossplane reconciles, and the Lambda timeout updates. The other 18 resources were untouched."

### What This Enables

> "This enables per-resource staged rollouts. Change an IAM policy without touching Lambda. Update S3 CORS without affecting DynamoDB. Surgical precision."

---

## Part 6: ConfigHub Exploration (5 min)

**Say:**
> "Let's explore ConfigHub. Every piece of infrastructure is individually queryable and browsable."

### Open ConfigHub UI

Open the ConfigHub web interface.

### Show the 19 Resources

**Say:**
> "Each environment has 19 individual units. Let's browse them."

```bash
# List all units in dev-east
cub unit list --space messagewall-dev-east
```

### Click into DynamoDB Table

Navigate to the `table` unit and show the fully rendered YAML.

**Say:**
> "This is the exact Crossplane managed resource that gets applied. Every field - billing mode, hash key, range key - is visible and versioned."

### Click into Lambda Function

Navigate to the `api-handler` unit and show:
- Memory and timeout settings
- Environment variables (TABLE_NAME, EVENT_BUS_NAME)
- IAM role selector reference
- S3 bucket and key for the deployment artifact

**Say:**
> "If I want to know 'what memory does this Lambda have?' - I don't grep through Terraform or dig into Crossplane Compositions. I query ConfigHub for the `api-handler` unit."

### Click into IAM Role Policy

Navigate to the `api-role-policy` unit and show the embedded JSON policy document.

**Say:**
> "Even the IAM policy JSON is visible. Security team can audit exactly what permissions exist, per environment, without touching AWS."

### Filter by Kind

**Say:**
> "I can filter across spaces. Show me all Lambda Functions across all environments, or all IAM Roles."

---

## Part 7: Break-Glass Recovery (5-7 min)

**Say:**
> "What happens during an incident when you need to change AWS directly, bypassing the normal flow?"

### Simulate an Emergency

```bash
# Direct AWS change (break-glass)
aws lambda update-function-configuration \
  --function-name messagewall-east-prod-api-handler \
  --memory-size 512 \
  --region us-east-1
```

**Say:**
> "Emergency fix is live. But now ConfigHub's `api-handler` unit says 256 MB, AWS says 512 MB. They're out of sync."

### Show the Drift

```bash
# ConfigHub still shows old value
cub unit get --space messagewall-prod-east api-handler --data-only | grep memorySize

# AWS shows new value
aws lambda get-function-configuration \
  --function-name messagewall-east-prod-api-handler \
  --region us-east-1 \
  --query 'MemorySize'
```

**Say:**
> "Without reconciliation, Crossplane will REVERT this change in about 5 minutes. That would undo our emergency fix."

### Reconcile Back to ConfigHub

```bash
# Capture AWS state back to ConfigHub (update just the api-handler unit)
./scripts/capture-drift-to-confighub.sh \
  --space messagewall-prod-east \
  --unit api-handler \
  --desc "INC-2024-001: Emergency memory increase for OOM incidents"
```

**Say:**
> "We updated just the `api-handler` unit. The other 18 resources are untouched. Surgical precision for break-glass too."

### Show Audit Trail

```bash
# View the history for the specific resource
cub unit history --space messagewall-prod-east api-handler
```

**Say:**
> "The audit trail shows who made the emergency change and why. Break-glass is for emergencies - always reconcile back."

---

## Part 8: K8s Workloads (10 min)

### Create Workload Cluster (if not running)

If you skipped creating the workload cluster earlier to save RAM, create it now:

```bash
# Check if workload cluster exists
kind get clusters | grep workload || scripts/bootstrap-workload-cluster.sh

# Install ArgoCD on workload cluster
scripts/bootstrap-workload-argocd.sh

# Build and load microservice image
cd app/microservices && ./build.sh && cd ../..
kind load docker-image messagewall-microservice:latest --name workload
```

**Say:**
> "ConfigHub doesn't just store AWS infrastructure. It also stores Kubernetes application configuration."

### Show the Order Platform Structure

```bash
# 5 teams, each with dev and prod environments
find infra/order-platform -type d -maxdepth 2 | sort

# Count manifests (excluding namespace files)
echo "Microservice deployments:"
find infra/order-platform -name "*.yaml" ! -name "namespace.yaml" | wc -l
```

| Team | Microservices |
|------|---------------|
| platform-ops | heartbeat, sentinel |
| data | counter, reporter |
| customer | greeter, weather |
| integrations | pinger, ticker |
| compliance | auditor, quoter |

### Show Initial Security Context (Permissive)

```bash
# Show the permissive security context
grep -A 8 "securityContext" infra/order-platform/platform-ops/dev/heartbeat.yaml
```

**Say:**
> "These start with permissive security: runAsNonRoot is false, privilege escalation is allowed. We'll fix that shortly."

### Publish to ConfigHub

```bash
# Publish all Order Platform manifests
./scripts/publish-order-platform.sh --apply
```

### Watch Pods Deploy

```bash
# Watch pods come up
kubectl get pods -A --context kind-workload -w | grep -E '^(platform|data|customer|integrations|compliance)'
```

### Find in ConfigHub

```bash
# List all Order Platform spaces
cub space list | grep order

# List units in one team's space
cub unit list --space order-customer-dev
```

**Say:**
> "Each team has their own ConfigHub space. Team isolation is built in."

---

## Part 9: Bulk Security Edit (5-7 min)

**Say:**
> "Security audit: all containers must run with restricted security context. Let's update all 20 deployments at once."

### Show the Change

**Before:**
```yaml
securityContext:
  runAsNonRoot: false
  allowPrivilegeEscalation: true
```

**After:**
```yaml
securityContext:
  runAsNonRoot: true
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  capabilities:
    drop: ["ALL"]
```

### Preview the Change

```bash
# Dry-run shows what would change
./scripts/demo-bulk-security.sh --dry-run
```

**Say:**
> "This shows exactly which deployments will be updated and what changes. No surprises."

### Apply the Change

```bash
# Apply to all Order Platform deployments
./scripts/demo-bulk-security.sh --apply \
  --desc "SEC-2024-042: Enforce restricted security policy"
```

### Watch Pods Restart

```bash
# Pods restart with new security context
kubectl get pods -A --context kind-workload -w | grep -E '^(platform|data|customer|integrations|compliance)'
```

### Verify

```bash
# Check a pod's security context
kubectl get pod -n platform-ops-dev -l app=heartbeat \
  -o jsonpath='{.items[0].spec.containers[0].securityContext}' \
  --context kind-workload | jq .
```

**Say:**
> "One command, 20 deployments, full audit trail. That's the power of ConfigHub as a single authority."

---

## Part 10: Multi-Source Configuration (5 min)

**Say:**
> "Here's a key insight: configuration is no longer something a developer owns in isolation. ConfigHub is a **configuration data substrate** where multiple systems read and write on behalf of the organization."

### Show Multi-Source Change Scenario

**Explain the scenario:**
> "Let's trace how a single Lambda function's configuration accumulates changes from multiple sources over time."

```bash
# Show current state of the api-handler resource (after all previous demo parts)
cub unit get --space messagewall-dev-east api-handler --data-only | head -30
```

**Say:**
> "This is the fully-expanded Lambda Function resource. Not an abstract claim - the actual managed resource. Multiple teams can modify it directly."

### Demonstrate Multiple Change Sources

**Walk through the different "authors" that modify configuration:**

| Source | Change | Why |
|--------|--------|-----|
| **Developer** | Initial claim, feature flags | Application functionality |
| **Security Team** | `SECURITY_LOG_ENDPOINT` env var | Compliance requirement |
| **FinOps/Cost** | Memory adjusted from 128 to 256 MB | Cost optimization after analysis |
| **SRE/Reliability** | Timeout increased to 30s | Stability improvement |
| **CI/CD Pipeline** | Version tags, build metadata | Deployment tracking |

```bash
# Security team adds logging endpoint (simulated)
./scripts/demo-bulk-change.sh env SECURITY_LOG_ENDPOINT=https://security.internal/ingest \
  --space messagewall-dev-east \
  --unit api-handler \
  --desc "SEC-2024-001: Add security audit logging" \
  --dry-run

# FinOps adjusts memory after cost analysis (simulated)
./scripts/demo-bulk-change.sh memory 256 \
  --space messagewall-dev-east \
  --unit api-handler \
  --desc "FINOPS-Q4: Optimize Lambda memory allocation" \
  --dry-run

# SRE adds reliability tag (simulated)
./scripts/demo-bulk-change.sh tag oncall-team=platform \
  --space messagewall-dev-east \
  --unit api-handler \
  --desc "SRE: Tag for incident routing" \
  --dry-run
```

**Say:**
> "Each of these teams modifies the `api-handler` unit directly. The diff shows exactly which YAML fields changed. No ambiguity."

### The Key Insight

**Say:**
> "Notice that the developer didn't make any of these changes. Security, FinOps, and SRE teams each modified the service's configuration based on organizational policies.
>
> **This is the paradigm shift:** A service's configuration isn't owned by one team. It's a shared data substrate that multiple systems write to:
> - Security systems enforce compliance
> - Cost optimization systems tune resource allocation
> - Reliability systems add operational metadata
> - AI agents (future) propose optimizations
>
> And because we store the **expanded resources** (not abstract claims), every change is visible at the exact field level. No Composition expansion needed to understand the impact.
>
> ConfigHub makes this safe by providing:
> - **Audit trail**: Every change has an author and reason
> - **Version history**: See exactly what changed and when
> - **Review gates**: High-risk changes require approval
> - **Rollback**: Any revision can be restored - per resource"

### View the Change History

```bash
# Show revision history for api-handler - multiple authors, multiple reasons
cub unit history --space messagewall-dev-east api-handler

# Each revision shows: who, when, why
```

**Say:**
> "In the future, AI agents will also propose configuration changes. The same substrate that accepts changes from Security, FinOps, and SRE will accept agent-proposed optimizations - with the same audit trail and approval gates."

---

## Closing

> "Let me summarize what we've seen:
>
> **ConfigHub stores fully-expanded resources, not abstract claims:**
> - 19 individual AWS resources per environment, each queryable and rollbackable
> - The Composition runs at build time, not runtime - Crossplane is a pure reconciler
> - Diffs, policy checks, and approval gates operate on the actual resources
>
> **ConfigHub is a configuration data substrate, not just a developer tool:**
> - Multiple sources write configuration: Developers, Security, FinOps, SRE, CI/CD
> - No single team 'owns' a service's configuration in isolation
> - The organization shapes services through policies, not manual coordination
>
> **ConfigHub is the single authority for ALL configuration:**
> - Infrastructure (AWS via Crossplane)
> - Workloads (Kubernetes via ArgoCD)
> - Multi-region, multi-environment, multi-team
>
> **Key capabilities:**
> - Per-resource staged rollouts (Head vs Live)
> - Break-glass recovery with audit trail
> - Bulk operations across many resources
> - Full version history for every change
> - Multi-source authorship with unified audit trail
>
> **The future:** AI agents will propose configuration changes through the same substrate - with the same audit trail, approval gates, and rollback capabilities.
>
> **One authority, multiple sources, continuous enforcement.**"

---

## Quick Reference

### Key Commands

```bash
# Render composition (expands Claim → 19 managed resources)
./scripts/render-composition.sh --overlay dev-east --output-dir /tmp/rendered/dev-east

# Validate rendered resources
./scripts/validate-policies.sh /tmp/rendered/dev-east

# Publish rendered resources to ConfigHub
for yaml in /tmp/rendered/dev-east/*.yaml; do
  unit=$(basename "$yaml" .yaml)
  cub unit update --space messagewall-dev-east "$unit" "$yaml" --change-desc "CI: deploy"
done

# Publish Order Platform
./scripts/publish-order-platform.sh --apply

# Bulk security edit
./scripts/demo-bulk-security.sh --apply

# View ConfigHub spaces
cub space list

# View units in a space (19 resources per messagewall env)
cub unit list --space messagewall-dev-east

# View revision history for a specific resource
cub unit history --space messagewall-dev-east api-handler
```

### Timing Cheat Sheet

| Part | Topic | Time |
|------|-------|------|
| 1 | The Claim | 5 min |
| 2 | Render & Deploy East | 10 min |
| 3 | Deploy West | 3 min |
| 4 | Deploy Prod | 5 min |
| 5 | Revision Rollout | 5-7 min |
| 6 | ConfigHub Exploration | 5 min |
| 7 | Break-Glass Recovery | 5-7 min |
| 8 | K8s Workloads | 10 min |
| 9 | Bulk Security Edit | 5-7 min |
| 10 | Multi-Source Configuration | 5 min |
| **Total** | | **58-64 min** |

**For shorter demo:** Skip Parts 5 and 7 (saves ~12 min)
**For multi-source focus:** Prioritize Parts 9 and 10 to emphasize the substrate concept

---

## Related Documentation

- [Claim Authoring Guide](claim-authoring.md) - Kustomize overlay details
- [Demo Guide](demo-guide.md) - Reference material, Q&A, deeper dives
- [ADR-014](decisions/014-confighub-stores-expanded-resources.md) - Why expanded resources
- [Bulk Changes](bulk-changes-and-change-management.md) - Risk mitigation strategies
- [ConfigHub + Crossplane Narrative](confighub-crossplane-narrative.md) - Architecture deep-dive
