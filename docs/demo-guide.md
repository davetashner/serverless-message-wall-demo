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

### Part 4: Looking Ahead - ConfigHub Integration (2-3 min)

> "This is the foundation. The next step is ConfigHub integration."

**Show the Architecture Diagram:**
```
Git (authoring) → Render CRDs → ConfigHub (authoritative) → Actuator → AWS
```

**Explain the Vision:**
1. Developers author Crossplane manifests in Git
2. CI renders them to fully-resolved YAML
3. ConfigHub stores the rendered config as the source of truth
4. Actuator pulls from ConfigHub (not directly from Git)
5. Changes can be made in ConfigHub and flow to AWS

> "This enables bulk configuration changes, policy enforcement at the config layer, and a complete audit trail."

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
