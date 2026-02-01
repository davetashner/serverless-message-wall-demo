# Bulk Changes and Change Management

This document explains how bulk configuration changes work in the serverless message wall architecture, how to mitigate the risks of making widespread changes, and how to integrate with change management processes.

**Audience**: Platform engineers, DevOps practitioners, and technical leaders who want to understand how Crossplane and ConfigHub enable safe bulk infrastructure changes. No deep Kubernetes knowledge required.

---

## The Big Idea: Configuration as a Multi-Source Data Substrate

**A service's configuration is no longer something a developer owns in isolation.**

Traditional model:
```
Developer → Git → Deploy → Production
```

Modern model with ConfigHub:
```
┌─────────────────────────────────────────────────────────────────┐
│                      ConfigHub (Substrate)                       │
│                                                                  │
│   ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐       │
│   │Developer │  │ Security │  │  FinOps  │  │   SRE    │       │
│   │  writes  │  │  writes  │  │  writes  │  │  writes  │       │
│   │ features │  │compliance│  │cost tuning│  │ reliability│    │
│   └────┬─────┘  └────┬─────┘  └────┬─────┘  └────┬─────┘       │
│        │             │             │             │              │
│        └─────────────┴─────────────┴─────────────┘              │
│                            │                                     │
│                     Unified Config                               │
│                            │                                     │
│              ┌─────────────┴─────────────┐                      │
│              ▼                           ▼                      │
│        Crossplane                    ArgoCD                     │
│         (AWS)                    (Kubernetes)                   │
└─────────────────────────────────────────────────────────────────┘
```

### Who Writes Configuration?

| Source | What They Write | Example |
|--------|-----------------|---------|
| **Developer** | Features, business logic config | `FEATURE_FLAG_NEW_UI=true` |
| **Security Team** | Compliance requirements | `SECURITY_LOG_ENDPOINT=https://...` |
| **FinOps/Cost** | Resource sizing, cost tags | `lambdaMemory: 256`, `cost-center: platform` |
| **SRE/Reliability** | Operational metadata, scaling | `oncall-team: platform`, `timeout: 30` |
| **CI/CD Pipeline** | Build info, deployment metadata | `build-sha: abc123`, `deployed-at: ...` |
| **AI Agents (future)** | Optimization proposals | Memory recommendations, scaling suggestions |

### Why This Matters

1. **No coordination meetings** - Each team writes their policies independently
2. **Full audit trail** - Every change has an author and reason
3. **Consistent enforcement** - Policies apply across all services automatically
4. **Safe rollback** - Any revision can be restored if a policy causes issues

---

## The Problem: Changing Many Things at Once

Imagine you need to make the same change across many AWS resources:

- **Security patching**: Add a new environment variable to all Lambda functions for a security fix
- **Compliance**: Ensure all resources have a new required tag
- **Reliability**: Increase memory limits across all functions due to traffic growth
- **Cost optimization**: Reduce timeout values for non-production environments

In traditional infrastructure management, you might:
1. Open each resource manually in the AWS Console
2. Make the change
3. Hope you didn't miss any
4. Repeat for every environment

This is slow, error-prone, and doesn't scale. Worse, there's no audit trail of what changed or why.

---

## The Solution: Configuration as Data

The serverless message wall uses a different approach:

```
Git (authoring) → Render → ConfigHub (authoritative) → Actuator → AWS
```

### What Each Layer Does

| Layer | Role | Analogy |
|-------|------|---------|
| **Git** | Where engineers write configuration | The "source code" of your infrastructure |
| **Render** | Turns templates into concrete config | Compiling code into an executable |
| **ConfigHub** | Stores approved, ready-to-deploy config | The artifact repository (like Docker Hub) |
| **Actuator** | Applies config to cloud resources | The runtime that executes your code |
| **AWS** | The actual infrastructure | Where your application runs |

### Why This Matters for Bulk Changes

Because configuration is stored as queryable data in ConfigHub:

1. **You can find resources** - "Show me all Lambda functions with memorySize < 256"
2. **You can change them together** - "Set memorySize = 256 for all matching functions"
3. **You can review before applying** - "Show me what will change"
4. **You have an audit trail** - "Who changed this, when, and why?"

---

## Bulk Change Scenario: Security Patching

Let's walk through a realistic example: **A security team requires all Lambda functions to log to a new centralized security monitoring system via an environment variable.**

### Current State

We have two Lambda functions in our message wall:

```yaml
# api-handler Lambda
spec:
  forProvider:
    memorySize: 128
    timeout: 10
    environment:
      - variables:
          TABLE_NAME: messagewall-demo-dev
          EVENT_BUS_NAME: default

# snapshot-writer Lambda
spec:
  forProvider:
    memorySize: 128
    timeout: 10
    environment:
      - variables:
          TABLE_NAME: messagewall-demo-dev
          BUCKET_NAME: messagewall-demo-dev
```

### The Requirement

Security team mandates: All Lambda functions must have `SECURITY_LOG_ENDPOINT=https://security.internal/ingest`

### Traditional Approach (Don't Do This)

```bash
# Manual, repetitive, error-prone
aws lambda update-function-configuration \
  --function-name messagewall-api-handler \
  --environment "Variables={TABLE_NAME=messagewall-demo-dev,EVENT_BUS_NAME=default,SECURITY_LOG_ENDPOINT=https://security.internal/ingest}"

aws lambda update-function-configuration \
  --function-name messagewall-snapshot-writer \
  --environment "Variables={TABLE_NAME=messagewall-demo-dev,BUCKET_NAME=messagewall-demo-dev,SECURITY_LOG_ENDPOINT=https://security.internal/ingest}"

# Now repeat for staging... and production... and the other 47 functions...
```

Problems:
- You have to know ALL the existing variables to avoid overwriting them
- No review step
- No approval process
- No rollback capability
- No audit trail

### ConfigHub Approach (Do This)

#### Step 1: Find Affected Resources

```bash
# Find all Lambda functions across all environments
ch unit list --where "kind=Function AND apiVersion contains lambda"
```

Output:
```
messagewall-api-handler       dev    Function  lambda.aws.upbound.io/v1beta1
messagewall-snapshot-writer   dev    Function  lambda.aws.upbound.io/v1beta1
messagewall-api-handler       prod   Function  lambda.aws.upbound.io/v1beta1
messagewall-snapshot-writer   prod   Function  lambda.aws.upbound.io/v1beta1
```

#### Step 2: Preview the Change

```bash
# See what will change WITHOUT changing anything
ch fn set-env-var --container-name "*" \
  --var SECURITY_LOG_ENDPOINT \
  --value "https://security.internal/ingest" \
  --where "kind=Function AND apiVersion contains lambda" \
  --dry-run
```

Output shows exactly what will change:
```diff
Unit: messagewall-api-handler (dev)
  spec.forProvider.environment[0].variables:
+   SECURITY_LOG_ENDPOINT: "https://security.internal/ingest"

Unit: messagewall-snapshot-writer (dev)
  spec.forProvider.environment[0].variables:
+   SECURITY_LOG_ENDPOINT: "https://security.internal/ingest"

... (4 units will be modified)
```

#### Step 3: Create a ChangeSet

```bash
# Bundle the changes together with a description
ch changeset create "security-logging-rollout" \
  --description "Add SECURITY_LOG_ENDPOINT per SEC-2024-001"
```

#### Step 4: Apply the Changes to Dev First

```bash
# Only apply to dev environment
ch fn set-env-var --container-name "*" \
  --var SECURITY_LOG_ENDPOINT \
  --value "https://security.internal/ingest" \
  --where "kind=Function AND apiVersion contains lambda AND environment=dev" \
  --changeset "security-logging-rollout"
```

#### Step 5: Validate

```bash
# Run validation functions
ch fn vet-schemas --changeset "security-logging-rollout"
ch fn vet-custom "lambda-env-vars-required" --changeset "security-logging-rollout"
```

#### Step 6: Get Approval (if required)

```bash
# Request approval from change management
ch changeset request-approval "security-logging-rollout" \
  --approvers "platform-team,security-team"
```

#### Step 7: Apply to Actuator

```bash
# Once approved, apply to Kubernetes actuator
ch changeset apply "security-logging-rollout" --target dev-actuator
```

#### Step 8: Verify in AWS

```bash
# Crossplane reconciles the change to AWS
aws lambda get-function-configuration --function-name messagewall-api-handler \
  --query 'Environment.Variables.SECURITY_LOG_ENDPOINT'

# Output: "https://security.internal/ingest"
```

#### Step 9: Repeat for Production

After validating in dev, repeat steps 4-8 for production with appropriate approval gates.

---

## Risk Mitigation Strategies

Bulk changes are powerful but dangerous. Here's how to avoid turning a quick fix into a major outage.

### 1. Preview Before Apply (Always)

**The Rule**: Never apply a bulk change without previewing it first.

```bash
# ALWAYS use --dry-run first
ch fn set-replicas --count 0 --where "env=prod" --dry-run

# Output might show you're about to scale 47 services to zero
# That's probably not what you wanted
```

**Why It Works**: Dry-run shows you exactly what will change. If the output surprises you, stop and investigate.

### 2. Staged Rollouts (Dev → Staging → Prod)

**The Rule**: Apply changes to lower environments first, validate, then promote.

```
┌─────────────────────────────────────────────────────────────┐
│                    Staged Rollout                           │
├─────────┬───────────────┬───────────────┬──────────────────┤
│  Step   │  Environment  │   Approval    │   Validation     │
├─────────┼───────────────┼───────────────┼──────────────────┤
│    1    │     Dev       │   Automated   │  Smoke tests     │
│    2    │   Staging     │   Tech lead   │  Integration     │
│    3    │  Production   │   CAB/P1      │  Canary metrics  │
└─────────┴───────────────┴───────────────┴──────────────────┘
```

**Why It Works**: Problems surface in dev/staging where the blast radius is small.

### 3. Blast Radius Control (Scoped Permissions)

**The Rule**: The actuator can only affect resources within its scope.

In this demo, the Crossplane actuator has IAM permissions limited to:
- Resources with `messagewall-*` prefix only
- Permission boundaries that cap what IAM roles it creates

Even if someone makes a catastrophic bulk change, they can only affect message wall resources—not the rest of AWS.

```json
// From crossplane-actuator-policy.json
"Resource": [
  "arn:aws:s3:::messagewall-*",
  "arn:aws:dynamodb:us-east-1:*:table/messagewall-*",
  "arn:aws:lambda:us-east-1:*:function:messagewall-*"
]
```

**Why It Works**: Defense in depth. A bad change can't escape its blast radius.

### 4. Validation Functions (Automated Guardrails)

**The Rule**: Define what "valid" configuration looks like. Reject changes that violate it.

```bash
# Example: Validate all Lambdas have reasonable memory
ch fn vet-celexpr "spec.forProvider.memorySize >= 128 && spec.forProvider.memorySize <= 3008" \
  --where "kind=Function"

# Example: Validate all resources have required tags
ch fn vet-celexpr "has(spec.forProvider.tags) && spec.forProvider.tags.exists(t, t.key == 'environment')" \
  --where "apiVersion contains aws"
```

**Why It Works**: Codified policies catch mistakes before they reach production.

### 5. ChangeSet Locking (Prevent Conflicts)

**The Rule**: A unit can only be in one changeset at a time.

If Alice is modifying Lambda memory and Bob tries to modify Lambda timeouts on the same functions, Bob's change is blocked until Alice's changeset is completed or abandoned.

**Why It Works**: Prevents conflicting changes from stepping on each other.

### 6. Rollback Capability (Always Have an Escape)

**The Rule**: Every change can be reverted to a previous known-good state.

```bash
# See revision history
ch unit history messagewall-api-handler

# Output:
# rev-47  2024-01-15  Add SECURITY_LOG_ENDPOINT
# rev-46  2024-01-10  Increase timeout to 15s
# rev-45  2024-01-05  Initial deployment

# Rollback to previous revision
ch unit revert messagewall-api-handler --to-revision rev-46
```

**Why It Works**: Fast recovery. If something breaks, revert immediately while investigating.

### 7. Audit Trail (Know What Happened)

**The Rule**: Every change is attributed, timestamped, and linked to its justification.

```bash
# Who changed what, when, and why?
ch changeset show "security-logging-rollout"

# Output:
# Created: 2024-01-15 10:30:00 by alice@company.com
# Description: Add SECURITY_LOG_ENDPOINT per SEC-2024-001
# Approved: 2024-01-15 14:00:00 by bob@company.com
# Applied: 2024-01-15 14:05:00 to dev-actuator
# Units modified: 4
```

**Why It Works**: Post-incident analysis. You can always trace back to root cause.

---

## Change Management Procedures

Different changes require different levels of scrutiny. Here's how to match the process to the risk.

### Change Classification Matrix

| Change Type | Risk Level | Approval | Example |
|-------------|------------|----------|---------|
| **Standard** | Low | Automated | Add a tag, fix a typo |
| **Normal** | Medium | Tech lead + automated validation | Increase memory, add env var |
| **Emergency** | High | P1 on-call + retrospective | Security patch, outage fix |
| **Major** | Very High | CAB + staged rollout | New service, architecture change |

### Procedure 1: Automated Changes (Low Risk)

For changes that pass all validation gates automatically:

```
┌──────────────┐     ┌──────────────┐     ┌──────────────┐     ┌──────────────┐
│   Engineer   │────▶│  ChangeSet   │────▶│  Validation  │────▶│    Apply     │
│  creates PR  │     │   created    │     │   passes     │     │ (automatic)  │
└──────────────┘     └──────────────┘     └──────────────┘     └──────────────┘
```

**Triggers for automatic approval:**
- All validation functions pass
- Change affects dev/staging only
- Change type is pre-approved (e.g., tag additions)

**Example**: Adding a cost-tracking tag to all resources

```bash
# This change is low risk, can be automated
ch fn set-tag --key cost-center --value "eng-platform" \
  --where "apiVersion contains aws" \
  --changeset "add-cost-tags"

# Validation passes → auto-applied to dev
# Manual approval still required for prod
```

### Procedure 2: Normal Changes (Medium Risk)

For changes that need human review:

```
┌──────────────┐     ┌──────────────┐     ┌──────────────┐     ┌──────────────┐     ┌──────────────┐
│   Engineer   │────▶│  ChangeSet   │────▶│  Validation  │────▶│   Review &   │────▶│    Apply     │
│  creates PR  │     │   created    │     │   passes     │     │   Approve    │     │  (staged)    │
└──────────────┘     └──────────────┘     └──────────────┘     └──────────────┘     └──────────────┘
```

**Triggers for review:**
- Validation passes but change affects behavior
- Change affects production
- First time this type of change is made

**Example**: Increasing Lambda memory across all functions

```bash
ch changeset create "memory-increase-q1" \
  --description "Increase Lambda memory to handle Q1 traffic per PERF-2024-012"

ch fn set-container-resources --memory 256 \
  --where "kind=Function AND apiVersion contains lambda" \
  --changeset "memory-increase-q1"

# Request tech lead approval
ch changeset request-approval "memory-increase-q1" --approvers "platform-leads"

# After approval, apply to dev first
ch changeset apply "memory-increase-q1" --target dev-actuator

# Validate in dev for 24 hours, then apply to prod
ch changeset apply "memory-increase-q1" --target prod-actuator
```

### Procedure 3: Emergency Changes (High Risk)

For urgent fixes during an incident:

```
┌──────────────┐     ┌──────────────┐     ┌──────────────┐     ┌──────────────┐
│   On-call    │────▶│   Direct     │────▶│    Apply     │────▶│ Retrospective│
│   engineer   │     │   change     │     │ (immediate)  │     │  & reconcile │
└──────────────┘     └──────────────┘     └──────────────┘     └──────────────┘
```

**Triggers for emergency path:**
- Active incident (P1/P2)
- On-call engineer has break-glass access

**Example**: Urgent security patch during incident

```bash
# Break-glass: Apply directly to actuator (bypass normal flow)
kubectl apply -f emergency-patch.yaml --context prod-actuator

# IMPORTANT: Reconcile back to ConfigHub after incident
ch unit import messagewall-api-handler --from-cluster prod-actuator
ch changeset create "emergency-sec-patch-reconcile" \
  --description "Reconcile emergency fix from INC-2024-001"
```

**Required follow-up:**
1. Create incident ticket
2. Reconcile ConfigHub to match what was applied
3. Post-incident review within 48 hours
4. Document the change for audit

### Procedure 4: Major Changes (Very High Risk)

For changes that affect architecture or many services:

```
┌──────────────┐     ┌──────────────┐     ┌──────────────┐     ┌──────────────┐     ┌──────────────┐
│   Proposal   │────▶│   Design     │────▶│     CAB      │────▶│   Staged     │────▶│   Monitor    │
│   & scope    │     │   review     │     │   approval   │     │   rollout    │     │   & verify   │
└──────────────┘     └──────────────┘     └──────────────┘     └──────────────┘     └──────────────┘
```

**Triggers for CAB approval:**
- Change affects multiple services
- Change introduces new technology
- Change has broad impact on users
- Rollback is complex or time-sensitive

**Example**: Migrating to a new AWS region

```bash
# Step 1: Create detailed proposal
ch changeset create "us-west-2-migration" \
  --description "Migrate all resources to us-west-2 per DR-2024-003" \
  --linked-doc "https://wiki/internal/dr-migration-plan"

# Step 2: Design review (async)
ch changeset request-review "us-west-2-migration" --reviewers "platform-architects"

# Step 3: CAB submission
ch changeset request-approval "us-west-2-migration" \
  --approvers "change-advisory-board" \
  --scheduled-date "2024-02-15" \
  --rollback-plan "https://wiki/internal/dr-rollback"

# Step 4: Staged rollout with monitoring
# Day 1: 5% canary
# Day 3: 25% if metrics stable
# Day 7: 100% with full team coverage
```

---

## Demo Walkthrough: Bulk Security Patching

This walkthrough is designed to be presented to technical leaders who may not be familiar with Kubernetes.

### Setup (2 minutes)

Show the current state of the message wall:

```bash
# The application works - show it in a browser
open http://messagewall-demo-dev.s3-website-us-east-1.amazonaws.com/

# The infrastructure is managed as data
kubectl get functions.lambda --context kind-actuator
```

### The Scenario (1 minute)

> "Security has mandated that all Lambda functions must send logs to a new security monitoring endpoint. We have two functions here, but imagine this is a company with 200 microservices and 500+ Lambda functions across three environments."

### Show the Current Config (1 minute)

```bash
# What does one function look like?
kubectl get function messagewall-api-handler -o yaml --context kind-actuator | grep -A 10 environment
```

### The Traditional Way (1 minute)

> "Traditionally, someone would open the AWS Console, find each function, add the environment variable, and repeat. That's 500 clicks, zero review, and no rollback. If you typo the URL, you might not know until an incident."

### The ConfigHub Way (3 minutes)

```bash
# Step 1: Find all Lambda functions
ch unit list --where "kind=Function"

# Step 2: Preview the change
ch fn set-env-var --var SECURITY_LOG_ENDPOINT --value "https://security.internal/ingest" \
  --where "kind=Function" --dry-run

# Step 3: Create changeset with tracking
ch changeset create "security-logging" --description "SEC-2024-001"

# Step 4: Apply to dev only
ch fn set-env-var --var SECURITY_LOG_ENDPOINT --value "https://security.internal/ingest" \
  --where "kind=Function AND environment=dev" --changeset "security-logging"

# Step 5: Apply to actuator
ch changeset apply "security-logging" --target dev-actuator
```

### Show the Result (1 minute)

```bash
# Crossplane reconciles the change to AWS
kubectl get function messagewall-api-handler -o yaml --context kind-actuator | grep -A 10 environment

# Verify in AWS
aws lambda get-function-configuration --function-name messagewall-api-handler \
  --query 'Environment.Variables'
```

### Key Points to Emphasize

1. **Find then fix** - Query for resources, then modify them as a batch
2. **Preview before apply** - See exactly what will change
3. **Tracked and attributed** - Every change is in a changeset with a description
4. **Staged rollout** - Apply to dev first, validate, then promote
5. **Auditable** - Full history of who changed what and why
6. **Reversible** - Every revision can be rolled back

### Handling Questions

**"What if the change breaks something?"**
> "We have validation functions that check for common issues before apply. And because every change creates a revision, we can rollback to the previous state instantly."

**"What about approval workflows?"**
> "ConfigHub supports approval triggers. For production changes, we require tech lead approval. For major changes, we integrate with the Change Advisory Board."

**"Isn't this just GitOps?"**
> "GitOps is about syncing Git to a cluster. This adds a layer where config is queryable and mutable as data. You can make changes across environments without editing 50 YAML files and creating a mega-PR."

**"What if someone bypasses this and changes AWS directly?"**
> "Crossplane continuously reconciles. If someone manually changes a Lambda in the console, Crossplane will revert it to match the declared state within minutes. That's drift correction."

---

## Summary

| Concept | Traditional | ConfigHub + Crossplane |
|---------|-------------|----------------------|
| Finding resources | Manual search or scripts | Query by any attribute |
| Making changes | One at a time | Bulk modify with one command |
| Reviewing changes | Hope diff is readable | Dry-run shows exact changes |
| Approval process | Tickets and meetings | Integrated approval triggers |
| Applying changes | kubectl/terraform/console | Apply to actuator, it reconciles |
| Rollback | Restore from backup | Revert to previous revision |
| Audit trail | Git history (maybe) | Every change is attributed |
| Drift correction | Manual or periodic | Continuous reconciliation |

The combination of Crossplane (continuous reconciliation) and ConfigHub (configuration as queryable, mutable data) gives you the power to make bulk changes safely while maintaining the controls that enterprise change management requires.
