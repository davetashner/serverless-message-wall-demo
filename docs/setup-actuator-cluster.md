# Setting Up the Actuator Cluster

This guide walks through setting up the Kubernetes actuator cluster with Crossplane and Kyverno. The actuator cluster is responsible for managing AWS resources declaratively.

## Quick Start with Setup Wizard

The fastest way to get started is using the setup wizard:

```bash
# Run the interactive setup wizard
./scripts/setup.sh

# Or, run with --deploy to automatically bootstrap and deploy
./scripts/setup.sh --deploy
```

The wizard will:
1. Collect your AWS account ID, region, and naming preferences
2. Generate all configuration files from templates
3. Optionally run the full deployment sequence

For manual setup or more control, follow the phases below.

## Prerequisites

Run the prerequisites checker:

```bash
./scripts/check-prerequisites.sh
```

Required tools:
- Docker Desktop (running)
- kind
- kubectl
- helm
- AWS CLI (configured with credentials)

## Overview

The setup consists of six phases:

1. **Configuration** - Run setup wizard to generate files
2. **AWS IAM Setup** - Create the permission boundary and Crossplane user
3. **Kubernetes Cluster** - Create a local kind cluster with Crossplane
4. **Deployment** - Deploy the message wall application
5. **ConfigHub Worker** - Install ConfigHub worker for sync (optional)
6. **ArgoCD** - Install ArgoCD for observability (optional)

## Phase 1: Configuration

```bash
./scripts/setup.sh
```

This interactive wizard prompts for:

| Value | Default | Description |
|-------|---------|-------------|
| AWS Account ID | Auto-detected | Your 12-digit AWS account ID |
| AWS Region | us-east-1 | AWS region for resources |
| Resource Prefix | messagewall | Prefix for all resource names |
| Environment | dev | Environment name (dev, staging, prod) |

For CI/CD or automation, use non-interactive mode:

```bash
./scripts/setup.sh \
  --account-id 123456789012 \
  --region us-west-2 \
  --resource-prefix myapp \
  --environment staging \
  --non-interactive
```

## Phase 2: AWS IAM Setup (One-Time)

Before Crossplane can manage AWS resources, you need to create IAM resources that scope its permissions. See [ADR-006](decisions/006-crossplane-and-iam-strategy.md) for the rationale.

### Create Permission Boundary

```bash
aws iam create-policy \
  --policy-name MessageWallRoleBoundary \
  --policy-document file://platform/iam/messagewall-role-boundary.json \
  --description "Permission boundary for Lambda roles created by Crossplane"
```

### Create Crossplane User

```bash
# Create user
aws iam create-user --user-name crossplane-actuator

# Create and attach policy
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

aws iam create-policy \
  --policy-name CrossplaneActuatorPolicy \
  --policy-document file://platform/iam/crossplane-actuator-policy.json

aws iam attach-user-policy \
  --user-name crossplane-actuator \
  --policy-arn arn:aws:iam::${ACCOUNT_ID}:policy/CrossplaneActuatorPolicy

# Generate access keys (save these securely!)
aws iam create-access-key --user-name crossplane-actuator
```

### Store Credentials in Kubernetes

After creating the cluster (Phase 3), store the credentials:

```bash
kubectl create secret generic aws-credentials \
  --namespace crossplane-system \
  --from-literal=credentials="[default]
aws_access_key_id = <ACCESS_KEY>
aws_secret_access_key = <SECRET_KEY>"
```

## Phase 3: Create Kubernetes Cluster with Crossplane

```bash
./scripts/bootstrap-kind.sh
./scripts/bootstrap-crossplane.sh
./scripts/bootstrap-aws-providers.sh
```

**Verify:**
```bash
kubectl get providers.pkg.crossplane.io
# All providers should show INSTALLED=True, HEALTHY=True
```

### Optional: Install Kyverno for Policy Enforcement

```bash
./scripts/bootstrap-kyverno.sh
```

## Phase 4: Deploy the Application

```bash
./scripts/deploy-dev.sh
```

This deploys all infrastructure (S3, DynamoDB, Lambda, EventBridge) via Crossplane.

### Finalize the Web Application

After deployment, the Lambda Function URL is known. Update the web app:

```bash
./scripts/finalize-web.sh
```

### Verify the Deployment

```bash
./scripts/smoke-test.sh
```

Or manually:
1. Open the website URL printed by the deploy script
2. Post a message
3. Refresh and verify it appears

## Phase 5: Install ConfigHub Worker (Optional)

If you're using ConfigHub as the configuration control plane, install a ConfigHub worker to sync from ConfigHub to the actuator cluster.

### Create and Install the Worker

```bash
# Create worker in ConfigHub (if not already created)
cub worker create --space messagewall-dev actuator-sync --allow-exists

# Install worker in Kubernetes
cub worker install actuator-sync --space messagewall-dev \
    --provider-types kubernetes --export --include-secret | kubectl apply -f -
```

**Verify:**
```bash
kubectl get pods -n confighub
# Worker pod should be Running

kubectl logs -n confighub -l app=actuator-sync --tail=10
# Should show "Successfully connected to event stream"
```

### Configure Units to Sync

```bash
# Set target for all units
cub unit set-target actuator-sync-kubernetes-yaml-cluster \
    --space messagewall-dev \
    --unit dynamodb,eventbridge,function-url,iam,lambda,s3

# Apply units to sync to Kubernetes
cub unit apply --space messagewall-dev \
    --unit dynamodb,eventbridge,function-url,iam,lambda,s3 --wait
```

**Verify sync status:**
```bash
cub unit list --space messagewall-dev
# All units should show STATUS=Ready
```

With this setup, changes published to ConfigHub will automatically sync to the actuator cluster and reconcile to AWS.

## Phase 6: Install ArgoCD (Optional)

ArgoCD provides a UI for observability and can manage non-ConfigHub resources.

```bash
./scripts/bootstrap-argocd.sh
```

**Access the ArgoCD UI:**
```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
# Open https://localhost:8080
# Username: admin
# Password: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
```

## All-in-One Deployment

To run the entire setup and deployment sequence:

```bash
./scripts/setup.sh --deploy
```

Or interactively:
```bash
./scripts/setup.sh
# Answer the prompts, then say "yes" when asked to deploy
```

## Cleanup

To remove all AWS resources:

```bash
./scripts/cleanup.sh
```

## Troubleshooting

### Crossplane provider not healthy

Check provider logs:
```bash
kubectl logs -n crossplane-system -l pkg.crossplane.io/provider=provider-aws-s3
```

### IAM permission errors

Check that the IAM policy includes required permissions. The policy may need updates as Crossplane providers evolve. See the `platform/iam/` directory for current policies.

### Function URL not found

Wait for all resources to be ready:
```bash
kubectl get functionurl -w
```

Then re-run finalize:
```bash
./scripts/finalize-web.sh
```

## File Reference

| File | Purpose |
|------|---------|
| `scripts/setup.sh` | Configuration wizard |
| `scripts/check-prerequisites.sh` | Verify required tools |
| `scripts/bootstrap-kind.sh` | Create kind cluster |
| `scripts/bootstrap-crossplane.sh` | Install Crossplane |
| `scripts/bootstrap-aws-providers.sh` | Install AWS providers |
| `scripts/bootstrap-kyverno.sh` | Install Kyverno (optional) |
| `scripts/bootstrap-argocd.sh` | Install ArgoCD (optional) |
| `scripts/setup-argocd-confighub-auth.sh` | Configure ConfigHub credentials |
| `scripts/deploy-dev.sh` | Deploy infrastructure |
| `scripts/finalize-web.sh` | Update web app with Function URL |
| `scripts/smoke-test.sh` | Verify deployment |
| `scripts/cleanup.sh` | Remove all resources |
| `scripts/test-setup.sh` | Test suite for wizard |
| `platform/iam/*.json` | IAM policies (generated) |
| `platform/argocd/*.yaml` | ArgoCD configuration |
| `infra/base/*.yaml` | Crossplane manifests (generated) |
