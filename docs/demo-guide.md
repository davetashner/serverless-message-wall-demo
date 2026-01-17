# Demo Guide: Serverless Message Wall with Crossplane Actuator

This guide provides talking points and demonstration steps for presenting the serverless message wall demo. The demo showcases Kubernetes as an infrastructure actuator using Crossplane, with policy enforcement via Kyverno.

## Demo Narrative

### The Big Idea

> "What if Kubernetes never ran your application code? What if it only actuated infrastructure?"

This demo answers that question by showing:
1. A fully serverless application running entirely on AWS managed services
2. Kubernetes running only Crossplane controllers (no app pods)
3. Policy enforcement ensuring all resources are properly tagged
4. A path toward ConfigHub as the authoritative configuration store

### Key Messages

1. **Kubernetes as Actuator**: The cluster runs zero application code. It's purely a control plane for infrastructure.

2. **Declarative Infrastructure**: AWS resources are defined as Kubernetes custom resources and reconciled by Crossplane.

3. **Policy Enforcement**: Kyverno ensures every AWS resource has required tags for cost allocation and cleanup.

4. **Event-Driven Architecture**: The application uses events (EventBridge) rather than synchronous Lambda-to-Lambda calls.

5. **Blast Radius Control**: IAM permission boundaries prevent privilege escalation even if Crossplane is compromised.

---

## Demo Flow

### Part 1: The Actuator Cluster (5-10 min)

**Setup Context:**
> "Let's look at what's running in our Kubernetes cluster."

```bash
kubectl get pods -A --context kind-actuator | grep -v kube-system
```

**Talking Points:**
- Point out there are ONLY infrastructure controllers running
- No application pods, no services, no ingresses for app traffic
- Crossplane pods reconcile AWS resources
- Kyverno pods enforce policies

**Show Crossplane Providers:**
```bash
kubectl get providers.pkg.crossplane.io
```

> "We've installed modular AWS providers - only the services we need (S3, DynamoDB, Lambda, EventBridge, IAM). This is lighter weight than the monolithic provider."

### Part 2: Policy Enforcement with Kyverno (5-10 min)

**Show the Policies:**
```bash
kubectl get clusterpolicy
```

**Explain the Two-Layer Approach:**
> "We have two policies working together:"
> 1. **Mutation** - Automatically adds required tags to any AWS resource
> 2. **Validation** - Rejects resources that somehow bypass mutation

**Demonstrate Mutation:**
```bash
# Create a bucket WITHOUT tags
cat <<EOF | kubectl apply -f -
apiVersion: s3.aws.upbound.io/v1beta2
kind: Bucket
metadata:
  name: messagewall-demo-bucket
spec:
  forProvider:
    region: us-east-1
  providerConfigRef:
    name: default
EOF

# Show that tags were automatically added
kubectl get bucket messagewall-demo-bucket -o jsonpath='{.spec.forProvider.tags}' | jq .
```

**Key Tags to Highlight:**
- `createdBy: crossplane` - Identifies how the resource was created
- `managedBy: messagewall-demo` - Identifies the project
- `environment: dev` - Environment classification

> "These tags flow through to AWS. You can use them in Cost Explorer, for cleanup scripts, or for compliance reporting."

**Show Tags in AWS Console:**
```bash
# Wait for bucket to sync
kubectl wait bucket messagewall-demo-bucket --for=condition=Ready --timeout=60s

# Verify in AWS
aws s3api get-bucket-tagging --bucket messagewall-demo-bucket
```

**Demonstrate Validation (Optional):**
> "What happens if mutation is bypassed?"

```bash
# Temporarily delete mutation policy
kubectl delete clusterpolicy mutate-aws-resource-tags

# Try to create a bucket - should be REJECTED
cat <<EOF | kubectl apply -f -
apiVersion: s3.aws.upbound.io/v1beta2
kind: Bucket
metadata:
  name: messagewall-rejected-bucket
spec:
  forProvider:
    region: us-east-1
  providerConfigRef:
    name: default
EOF

# Restore mutation policy
kubectl apply -f platform/kyverno/policies/mutate-aws-tags.yaml
```

> "The validation policy acts as a safety net. This is defense in depth."

**Clean Up Demo Bucket:**
```bash
kubectl delete bucket messagewall-demo-bucket
```

### Part 3: IAM Security Model (5 min)

**Show the Scoped Permissions:**
> "Crossplane doesn't have admin access to AWS. It's scoped to only manage `messagewall-*` resources."

```bash
cat platform/iam/crossplane-actuator-policy.json | jq '.Statement[].Resource'
```

**Permission Boundary:**
> "Even more importantly, any IAM roles Crossplane creates are capped by a permission boundary. This prevents privilege escalation."

```bash
cat platform/iam/messagewall-role-boundary.json | jq .
```

**Key Point:**
> "If Crossplane is compromised, the attacker can only affect messagewall resources. They cannot create admin roles or access other parts of AWS."

### Part 4: ConfigHub Integration and Bulk Changes (10-15 min)

> "ConfigHub is now integrated as the authoritative configuration store."

**Show the Architecture Diagram:**
```
Git (authoring) → Render CRDs (CI) → ConfigHub (authoritative) → ArgoCD → Actuator → AWS
```

**Explain the Integration:**
1. Developers author Crossplane manifests in Git
2. CI renders them to fully-resolved YAML and publishes to ConfigHub
3. ConfigHub stores the rendered config as the source of truth
4. ArgoCD pulls from ConfigHub and applies to the actuator cluster
5. Crossplane reconciles to AWS

> "This enables bulk configuration changes, policy enforcement at the config layer, and a complete audit trail."

**Bulk Change Demo - Using the Demo Script:**

> "Imagine security mandates a new environment variable on all Lambda functions. Traditionally, you'd edit 50 files and create a massive PR. With ConfigHub, we can do this in a single operation."

**Step 1: Preview the change (always safe to run):**
```bash
# See what would change WITHOUT making any modifications
./scripts/demo-bulk-change.sh env SECURITY_LOG_ENDPOINT=https://security.internal/ingest --dry-run
```

**Step 2: Apply the change:**
```bash
# Add the env var to both Lambda functions in one operation
./scripts/demo-bulk-change.sh env SECURITY_LOG_ENDPOINT=https://security.internal/ingest \
  --desc "SEC-2024-001: Add security logging"
```

**Step 3: Verify in AWS:**
```bash
# Check that Crossplane reconciled the change
./scripts/demo-bulk-change.sh env SECURITY_LOG_ENDPOINT=https://security.internal/ingest --verify
```

**Other Bulk Change Examples:**
```bash
# Update memory on all Lambda functions
./scripts/demo-bulk-change.sh memory 256 --dry-run
./scripts/demo-bulk-change.sh memory 256

# Update timeout
./scripts/demo-bulk-change.sh timeout 15 --dry-run
./scripts/demo-bulk-change.sh timeout 15

# Add/update environment variable
./scripts/demo-bulk-change.sh env LOG_LEVEL=DEBUG

# Remove environment variable
./scripts/demo-bulk-change.sh remove-env LOG_LEVEL
```

**What This Demonstrates:**
1. **Single operation** - Both Lambda functions updated at once
2. **Single revision** - One ConfigHub change, not two
3. **Preview before apply** - `--dry-run` shows exact changes
4. **Audit trail** - `--desc` provides change context
5. **End-to-end verification** - `--verify` confirms AWS state

**View Change History:**
```bash
# See all revisions for the Lambda unit
cub unit history --space messagewall-dev lambda
```

**Key Points:**
- **Find then fix**: Query by any attribute, modify in bulk
- **Preview before apply**: See exactly what will change with `--dry-run`
- **Staged rollouts**: Apply to dev first, validate, then production
- **Approval gates**: Require human approval for high-risk changes
- **Full audit trail**: Every change is attributed and timestamped

> See `docs/bulk-changes-and-change-management.md` for detailed scenarios and risk mitigation strategies.

### Part 5: Break-Glass Recovery (5-10 min)

> "What happens when you need to make an emergency change directly in AWS?"

**Explain the Scenario:**
> "Sometimes incidents require immediate action—faster than the normal ConfigHub flow allows. This is called 'break-glass' access."

**Run the Break-Glass Demo:**
```bash
./scripts/demo-break-glass-recovery.sh
```

This interactive demo shows:
1. Simulated incident (Lambda memory pressure)
2. Emergency AWS-side change (bypassing normal flow)
3. Drift detection (ConfigHub vs AWS divergence)
4. Reconciliation (importing emergency change into ConfigHub)
5. Audit trail preservation (incident context captured)

**Key Points:**
- Break-glass is for emergencies, not convenience
- Without reconciliation, Crossplane will revert the emergency change
- Always include incident context in reconciliation
- ConfigHub preserves full audit trail of break-glass events

**Commands Demonstrated:**
```bash
# Direct AWS change (break-glass)
aws lambda update-function-configuration \
  --function-name messagewall-api-handler \
  --memory-size 512

# Reconcile back to ConfigHub
cub unit update --space messagewall-dev lambda <config> \
  --change-desc "Break-glass: INC-2024-001 - Memory increase for incident"

# View audit trail
cub unit history --space messagewall-dev lambda
```

> See `docs/confighub-crossplane-narrative.md` for a complete walkthrough of the ConfigHub + Crossplane architecture.

### Part 6: Controlled Rollout of Revisions (5-10 min)

> "What if you want to push changes but NOT deploy them immediately?"

**Explain HeadRevisionNum vs LiveRevisionNum:**
> "ConfigHub tracks two revision numbers for each unit:"
> 1. **HeadRevisionNum** - The latest revision (what CI just pushed)
> 2. **LiveRevisionNum** - The deployed revision (what's running in Kubernetes)

**Run the Controlled Rollout Demo:**
```bash
./scripts/demo-revision-rollout.sh
```

This interactive demo shows:
1. Current state: Head and Live may already differ
2. Creating a change: `cub unit update` advances Head only
3. Verifying separation: Head changed, Live unchanged, Kubernetes unchanged
4. Reviewing pending changes: `cub unit diff` shows what would deploy
5. Promoting: `cub unit apply` advances Live
6. ArgoCD syncs: Only Live content reaches Kubernetes

**Key Commands:**
```bash
# See revision state for all units
cub unit list --space messagewall-dev --columns Unit.Slug,Unit.HeadRevisionNum,Unit.LiveRevisionNum

# See pending changes (Live vs Head)
cub unit diff --space messagewall-dev lambda

# Promote a specific unit
cub unit apply --space messagewall-dev lambda

# Promote all units with pending changes
cub unit apply --space messagewall-dev --where "HeadRevisionNum > LiveRevisionNum"
```

**What This Enables:**
- **Staged rollouts**: Push to dev, validate, then promote to prod
- **Emergency holds**: Stop promotion during incidents
- **Change review**: See exactly what will deploy before promoting
- **Audit trail**: Track who promoted what and when

**How ArgoCD Works with This:**
> "ArgoCD auto-sync is enabled, but the ConfigHub CMP plugin only fetches LiveRevisionNum content. This means CI can push freely without affecting Kubernetes until someone explicitly promotes."

---

## Quick Reference Commands

### Cluster Status
```bash
kubectl get pods -A --context kind-actuator
kubectl get providers.pkg.crossplane.io
kubectl get clusterpolicy
```

### Create Test Resource
```bash
cat <<EOF | kubectl apply -f -
apiVersion: s3.aws.upbound.io/v1beta2
kind: Bucket
metadata:
  name: messagewall-demo-bucket
spec:
  forProvider:
    region: us-east-1
  providerConfigRef:
    name: default
EOF
```

### Verify Tags
```bash
kubectl get bucket messagewall-demo-bucket -o jsonpath='{.spec.forProvider.tags}' | jq .
```

### Check AWS
```bash
aws s3api get-bucket-tagging --bucket messagewall-demo-bucket
```

### Clean Up
```bash
kubectl delete bucket messagewall-demo-bucket
```

---

## Common Questions

### "Why not just use Terraform?"

Terraform is imperative (run to apply changes). Crossplane is declarative and continuously reconciles. If someone manually changes an S3 bucket in the console, Crossplane will revert it. Terraform won't know until the next `terraform apply`.

### "Why Kyverno instead of OPA?"

Kyverno can **mutate** resources (add tags automatically), not just validate. OPA/Gatekeeper is validation-only. For this use case, we want tags added automatically, not just rejected if missing.

### "What if Kyverno goes down?"

We're running in fail-open mode for this demo. If Kyverno is unavailable, requests pass through. This is documented in ADR-007. For production, you'd run fail-closed with multiple replicas.

### "Why permission boundaries?"

Standard IAM policies say what a user CAN do. Permission boundaries cap what roles they CREATE can do. Even if Crossplane has `iam:CreateRole`, the roles it creates are limited by the boundary. This prevents privilege escalation.

---

## Files to Reference During Demo

| Topic | Files |
|-------|-------|
| IAM Security | `platform/iam/*.json`, `docs/decisions/006-crossplane-and-iam-strategy.md` |
| Kyverno Policies | `platform/kyverno/policies/*.yaml`, `docs/decisions/007-kyverno-policy-enforcement.md` |
| Crossplane Setup | `platform/crossplane/*.yaml` |
| Bootstrap Scripts | `scripts/bootstrap-*.sh` |
| Architecture Decisions | `docs/decisions/*.md` |
| Bulk Changes & Risk Mitigation | `docs/bulk-changes-and-change-management.md` |
| ConfigHub Integration | `docs/decisions/005-confighub-integration-architecture.md` |
| **Bulk Change Demo Script** | `scripts/demo-bulk-change.sh` |
| **Controlled Rollout Demo** | `scripts/demo-revision-rollout.sh` |
| **Break-Glass Recovery Demo** | `scripts/demo-break-glass-recovery.sh` |
| **ConfigHub + Crossplane Narrative** | `docs/confighub-crossplane-narrative.md` |
| ArgoCD + ConfigHub Sync | `docs/decisions/009-argocd-confighub-sync.md`, `platform/argocd/` |
