# Demo Script: Serverless Message Wall

**Duration:** 15-20 minutes
**Audience:** Platform engineers, infrastructure teams evaluating control planes

> **Pre-requisites:** Run `./scripts/demo-preflight.sh` before presenting to verify everything is ready.

---

## Setup (Before Demo)

```bash
# Load environment variables
source ./scripts/demo-env.sh

# Verify everything is ready
./scripts/demo-preflight.sh
```

---

## Act 1: The Hook (2 min)

### Open with the question:

> "What if Kubernetes never ran your application code? What if it only actuated infrastructure?"

### Show the app working:

1. **Open the website in browser:**
   ```bash
   echo "Website: $WEBSITE_URL"
   open "$WEBSITE_URL"  # or xdg-open on Linux
   ```

2. **Post a message** using the UI

3. **Watch it appear** in the message list

> "This is a fully serverless application. The message you just posted went through Lambda, DynamoDB, EventBridge, and S3. Zero containers. Let's see what's actually running in Kubernetes..."

---

## Act 2: The Empty Cluster (2 min)

### Show what's running:

```bash
kubectl get pods -A --context kind-actuator | grep -v kube-system
```

**Talking point:**
> "Only infrastructure controllers. Crossplane reconciles AWS resources. Kyverno enforces policies. No application pods, no services, no ingresses for traffic."

### Show the AWS resources as Kubernetes objects:

```bash
kubectl get managed --context kind-actuator
```

**Talking point:**
> "S3 buckets, DynamoDB tables, Lambda functions - all managed as Kubernetes custom resources. Crossplane continuously reconciles them to AWS."

---

## Act 3: Event-Driven Flow (3 min)

### Explain the architecture:

```
Browser POST → Lambda (api-handler) → DynamoDB
                                         ↓
                                    EventBridge
                                         ↓
                            Lambda (snapshot-writer)
                                         ↓
                                   S3 (state.json)
                                         ↓
                                Browser GET ← polls
```

**Talking point:**
> "No Lambda-to-Lambda calls. The API handler writes to DynamoDB and emits an event. A separate Lambda reacts to that event and updates S3. Loose coupling."

### Live demo - post via API:

```bash
# Post a message from the terminal
curl -s -X POST "$API_URL" \
  -H "Content-Type: application/json" \
  -d '{"author":"Demo","content":"Hello from the terminal!"}' | jq

# Check DynamoDB (most recent item)
aws dynamodb scan --table-name $TABLE_NAME \
  --query 'Items | sort_by(@, &timestamp.S) | [-1]' | jq

# Check state.json in S3
aws s3 cp s3://$BUCKET_NAME/state.json - | jq '.messages[-1]'
```

**Talking point:**
> "The message flowed through the entire event-driven pipeline. No synchronous chains, no tight coupling."

---

## Act 4: Automatic Policy Enforcement (3 min)

**Talking point:**
> "Every AWS resource needs tags for cost allocation and cleanup. What if someone forgets?"

### Create a bucket WITHOUT tags:

```bash
cat <<EOF | kubectl apply -f - --context kind-actuator
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

### Show Kyverno added tags automatically:

```bash
kubectl get bucket messagewall-demo-bucket -o jsonpath='{.spec.forProvider.tags}' \
  --context kind-actuator | jq
```

**Talking point:**
> "We didn't specify any tags. Kyverno's mutation policy added them automatically. `createdBy`, `managedBy`, `environment` - all injected."

### Verify in AWS (optional, if bucket is ready):

```bash
kubectl wait bucket messagewall-demo-bucket --for=condition=Ready \
  --timeout=60s --context kind-actuator

aws s3api get-bucket-tagging --bucket messagewall-demo-bucket
```

### Clean up:

```bash
kubectl delete bucket messagewall-demo-bucket --context kind-actuator
```

**Talking point:**
> "This is defense in depth. Kyverno mutates resources to add tags, and also validates to reject resources that somehow bypass mutation."

---

## Act 5: Bulk Changes with ConfigHub (5 min)

**Talking point:**
> "Imagine security mandates a new environment variable on all Lambda functions. Traditional approach: edit 50 files, create a massive PR, wait for review. With ConfigHub:"

### Show current state:

```bash
cub unit get --space messagewall-dev lambda --data-only | \
  yq 'select(.kind == "Function") | {"name": .metadata.name, "env": .spec.forProvider.environment[0].variables}'
```

### Preview the change (dry-run):

```bash
./scripts/demo-bulk-change.sh env AUDIT_ENDPOINT=https://audit.internal --dry-run
```

**Talking point:**
> "See exactly what will change. Both Lambda functions, one diff, no surprises."

### Apply the change:

```bash
./scripts/demo-bulk-change.sh env AUDIT_ENDPOINT=https://audit.internal \
  --desc "SEC-2024-042: Add audit logging endpoint"
```

### Show the audit trail:

```bash
cub revision list --space messagewall-dev lambda
```

**Talking point:**
> "One operation. One revision. Full attribution - who changed what, when, and why."

### Sync to Kubernetes and verify in AWS:

```bash
# Sync ConfigHub to Kubernetes
cub unit get --space messagewall-dev lambda --data-only | \
  kubectl apply -f - --context kind-actuator

# Wait for Crossplane to reconcile
sleep 10

# Verify in AWS
aws lambda get-function-configuration \
  --function-name messagewall-api-handler \
  --query 'Environment.Variables'
```

**Talking point:**
> "ConfigHub → Kubernetes → AWS. The change is now live. In production, ArgoCD would sync this automatically."

---

## Closing (1 min)

### Key takeaways:

| Concept | What We Showed |
|---------|----------------|
| **Kubernetes as actuator** | Zero app pods - only Crossplane and Kyverno |
| **Event-driven architecture** | EventBridge, not Lambda chains |
| **Automatic policy enforcement** | Kyverno adds tags without manual intervention |
| **Bulk changes with audit trail** | One ConfigHub operation, full attribution |

### The big idea:

> "Kubernetes doesn't run your application. It actuates your infrastructure. Policies enforce compliance automatically. ConfigHub enables bulk changes with full audit trail. This is the control plane for the agent era - where high-velocity changes need machine-verifiable safety."

---

## Quick Reference

### Environment Variables

```bash
source ./scripts/demo-env.sh
echo "API_URL: $API_URL"
echo "WEBSITE_URL: $WEBSITE_URL"
echo "BUCKET_NAME: $BUCKET_NAME"
echo "TABLE_NAME: $TABLE_NAME"
```

### Reset for Next Demo

```bash
# Remove the audit endpoint we added
./scripts/demo-bulk-change.sh remove-env AUDIT_ENDPOINT

# Sync to Kubernetes
cub unit get --space messagewall-dev lambda --data-only | \
  kubectl apply -f - --context kind-actuator
```

### Troubleshooting

| Problem | Solution |
|---------|----------|
| Cluster not reachable | `kubectl config use-context kind-actuator` |
| ConfigHub auth failed | `cub auth login` |
| Bucket not ready | Wait for Crossplane: `kubectl get bucket -w` |
| Website not loading | Check S3 website: `aws s3 ls s3://$BUCKET_NAME/` |
