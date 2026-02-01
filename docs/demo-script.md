# Demo Script: ConfigHub as Configuration Data Substrate

This is the primary demo script for presenting the serverless message wall and Order Platform demos. It shows ConfigHub as a **configuration data substrate** where multiple sources (Developers, Security, FinOps, SRE, CI/CD) read and write configuration - not just a developer tool.

**Key message:** A service's configuration is no longer owned by developers in isolation. ConfigHub aggregates changes from across the organization with full audit trail.

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
│ Part 2: Deploy East (10 min)                                             │
│   Render claim → ConfigHub → Crossplane → AWS → Browser                  │
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
│   Stage a change without deploying, then promote                         │
└──────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌──────────────────────────────────────────────────────────────────────────┐
│ Part 6: ConfigHub Exploration (5 min)                                    │
│   Filter, browse, click into rendered DynamoDB and Lambda configs        │
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
- Docker images loaded

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

## Part 2: Deploy East (10 min)

**Say:**
> "Let's deploy to us-east-1. Watch the flow: Git overlay → rendered YAML → ConfigHub → Crossplane → AWS."

### Render the Claim

```bash
# Render the dev-east claim
kubectl kustomize infra/claims/overlays/dev-east
```

### Publish to ConfigHub

```bash
# Publish to ConfigHub (creates revision but doesn't apply yet)
./scripts/publish-claims.sh --overlay dev-east

# Show in ConfigHub
cub unit list --space messagewall-dev-east
```

### Apply to Make It Live

```bash
# Apply the revision (makes it live for ArgoCD to sync)
cub unit apply --space messagewall-dev-east messagewall-dev-east
```

### Watch Crossplane Reconcile

```bash
# In a split terminal, watch resources
kubectl get functions,buckets,tables -w --context kind-actuator-east
```

**Say:**
> "Crossplane sees the claim and creates 17 AWS resources: S3 bucket, DynamoDB table, two Lambda functions, IAM roles, EventBridge rules..."

### Verify in AWS Console

```bash
# Or via CLI
aws lambda list-functions --region us-east-1 | grep messagewall-east
aws dynamodb list-tables --region us-east-1 | grep messagewall-east
aws s3 ls | grep messagewall-east
```

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
# Publish and apply in one step
./scripts/publish-claims.sh --overlay dev-west --apply

# Wait for resources (optional, can skip if short on time)
kubectl wait --for=condition=Ready functions --all --context kind-actuator-west --timeout=120s

# Open in browser
BUCKET=$(aws s3 ls | grep messagewall-west | awk '{print $3}')
open "http://${BUCKET}.s3-website-us-west-2.amazonaws.com/"
```

**Say:**
> "Now 'us-west-2' in the URL. Dev is running in two regions, managed from a single ConfigHub authority."

---

## Part 4: Deploy Prod (5 min)

**Say:**
> "Now let's deploy production. Remember the differences: more memory, longer timeout, production annotations."

### Show the Prod Overlay

```bash
# Show what's different in prod
kubectl kustomize infra/claims/overlays/prod-east | grep -E '(lambdaMemory|lambdaTimeout|annotations:|tier:|oncall:)'
```

### Deploy Both Prod Regions

```bash
# Publish both prod overlays
./scripts/publish-claims.sh --overlay prod-east --apply
./scripts/publish-claims.sh --overlay prod-west --apply
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
> "What if you want to stage a change without deploying it immediately? ConfigHub tracks two revision numbers."

### Explain Head vs Live

> "**HeadRevisionNum** is the latest pushed revision. **LiveRevisionNum** is what's actually deployed. They can differ."

### Push a Change (Head Only)

```bash
# Get current config
cub unit get --space messagewall-prod-east messagewall-prod-east --data-only > /tmp/claim.yaml

# Edit timeout (30 → 45)
sed 's/lambdaTimeout: 30/lambdaTimeout: 45/' /tmp/claim.yaml > /tmp/claim-updated.yaml

# Push new revision (advances Head, not Live)
cub unit update --space messagewall-prod-east messagewall-prod-east /tmp/claim-updated.yaml
```

### Show the Gap

```bash
# See Head vs Live
cub unit list --space messagewall-prod-east
```

**Say:**
> "Head is now 2, Live is still 1. Nothing changed in Kubernetes or AWS yet."

### Show the Diff

```bash
# See what would change
cub unit diff --space messagewall-prod-east messagewall-prod-east
```

### Promote

```bash
# Make it live
cub unit apply --space messagewall-prod-east messagewall-prod-east
```

**Say:**
> "Now Live equals Head. ArgoCD syncs, Crossplane reconciles, and the Lambda timeout updates."

### What This Enables

> "This enables staged rollouts, change review before deployment, and emergency holds during incidents."

---

## Part 6: ConfigHub Exploration (5 min)

**Say:**
> "Let's explore ConfigHub. Every piece of infrastructure is queryable and browsable."

### Open ConfigHub UI

Open the ConfigHub web interface.

### Filter by Environment and Region

- Filter: `Environment=prod`
- Filter: `Region=us-east-1`

**Say:**
> "I can filter by any label - environment, region, team, application."

### Click into DynamoDB Table

Navigate to a DynamoDB table unit and show the fully rendered YAML.

**Say:**
> "This is the exact configuration that Crossplane applied. Every field is version-controlled and auditable."

### Click into Lambda Function

Navigate to a Lambda function unit and show:
- Memory and timeout settings
- Environment variables
- IAM role reference

**Say:**
> "If I want to know 'what memory does this Lambda have?' - I don't grep through Terraform or CloudFormation. I query ConfigHub."

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
> "Emergency fix is live. But now ConfigHub says 256 MB, AWS says 512 MB. They're out of sync."

### Show the Drift

```bash
# ConfigHub still shows old value
cub unit get --space messagewall-prod-east messagewall-prod-east --data-only | grep lambdaMemory

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
# Capture AWS state back to ConfigHub
./scripts/capture-drift-to-confighub.sh \
  --space messagewall-prod-east \
  --desc "INC-2024-001: Emergency memory increase for OOM incidents"
```

### Show Audit Trail

```bash
# View the history
cub unit history --space messagewall-prod-east messagewall-prod-east
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
# Show current state of a Lambda (after all previous demo parts)
cub unit get --space messagewall-dev-east messagewall-dev-east --data-only | \
  yq '.spec' | head -20
```

### Demonstrate Multiple Change Sources

**Walk through the different "authors" that modify configuration:**

| Source | Change | Why |
|--------|--------|-----|
| **Developer** | Initial claim, feature flags | Application functionality |
| **Security Team** | `SECURITY_LOG_ENDPOINT` env var | Compliance requirement |
| **FinOps/Cost** | Memory adjusted from 128→256 MB | Cost optimization after analysis |
| **SRE/Reliability** | Timeout increased to 30s | Stability improvement |
| **CI/CD Pipeline** | Version tags, build metadata | Deployment tracking |

```bash
# Security team adds logging endpoint (simulated)
./scripts/demo-bulk-change.sh env SECURITY_LOG_ENDPOINT=https://security.internal/ingest \
  --space messagewall-dev-east \
  --desc "SEC-2024-001: Add security audit logging" \
  --dry-run

# FinOps adjusts memory after cost analysis (simulated)
./scripts/demo-bulk-change.sh memory 256 \
  --space messagewall-dev-east \
  --desc "FINOPS-Q4: Optimize Lambda memory allocation" \
  --dry-run

# SRE adds reliability tag (simulated)
./scripts/demo-bulk-change.sh tag oncall-team=platform \
  --space messagewall-dev-east \
  --desc "SRE: Tag for incident routing" \
  --dry-run
```

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
> ConfigHub makes this safe by providing:
> - **Audit trail**: Every change has an author and reason
> - **Version history**: See exactly what changed and when
> - **Review gates**: High-risk changes require approval
> - **Rollback**: Any revision can be restored"

### View the Change History

```bash
# Show revision history - multiple authors, multiple reasons
cub unit get --space messagewall-dev-east messagewall-dev-east

# Each revision shows: who, when, why
```

**Say:**
> "In the future, AI agents will also propose configuration changes. The same substrate that accepts changes from Security, FinOps, and SRE will accept agent-proposed optimizations - with the same audit trail and approval gates."

---

## Closing

> "Let me summarize what we've seen:
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
> - Staged rollouts (Head vs Live)
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
# Publish claims
./scripts/publish-claims.sh --overlay dev-east --apply

# Publish Order Platform
./scripts/publish-order-platform.sh --apply

# Bulk security edit
./scripts/demo-bulk-security.sh --apply

# View ConfigHub spaces
cub space list

# View units in a space
cub unit list --space messagewall-dev-east

# View revision history
cub unit history --space messagewall-dev-east messagewall-dev-east
```

### Timing Cheat Sheet

| Part | Topic | Time |
|------|-------|------|
| 1 | The Claim | 5 min |
| 2 | Deploy East | 10 min |
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
- [Bulk Changes](bulk-changes-and-change-management.md) - Risk mitigation strategies
- [ConfigHub + Crossplane Narrative](confighub-crossplane-narrative.md) - Architecture deep-dive
