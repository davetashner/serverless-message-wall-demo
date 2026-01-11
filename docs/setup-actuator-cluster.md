# Setting Up the Actuator Cluster

This guide walks through setting up the Kubernetes actuator cluster with Crossplane and Kyverno. The actuator cluster is responsible for managing AWS resources declaratively.

## Prerequisites

- Docker Desktop (running)
- AWS CLI configured with credentials
- Homebrew (for installing tools)

## Overview

The setup consists of four phases:

1. **AWS IAM Setup** - Create the permission boundary and Crossplane user
2. **Kubernetes Cluster** - Create a local kind cluster
3. **Crossplane** - Install Crossplane and AWS providers
4. **Kyverno** - Install policy engine for tag enforcement

## Phase 1: AWS IAM Setup (One-Time)

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
aws iam create-policy \
  --policy-name CrossplaneActuatorPolicy \
  --policy-document file://platform/iam/crossplane-actuator-policy.json

aws iam attach-user-policy \
  --user-name crossplane-actuator \
  --policy-arn arn:aws:iam::<ACCOUNT_ID>:policy/CrossplaneActuatorPolicy

# Generate access keys (save these securely!)
aws iam create-access-key --user-name crossplane-actuator
```

### Store Credentials in Kubernetes

After creating the cluster (Phase 2), store the credentials:

```bash
kubectl create secret generic aws-credentials \
  --namespace crossplane-system \
  --from-literal=credentials="[default]
aws_access_key_id = <ACCESS_KEY>
aws_secret_access_key = <SECRET_KEY>"
```

## Phase 2: Create Kubernetes Cluster

```bash
./scripts/bootstrap-kind.sh
```

This creates a kind cluster named `actuator`. The script is idempotent.

**Verify:**
```bash
kubectl cluster-info --context kind-actuator
kubectl get nodes
```

## Phase 3: Install Crossplane

```bash
./scripts/bootstrap-crossplane.sh
```

This installs Crossplane using Helm.

**Verify:**
```bash
kubectl get pods -n crossplane-system
```

### Install AWS Providers

```bash
./scripts/bootstrap-aws-providers.sh
```

This installs the AWS family providers (S3, DynamoDB, Lambda, CloudWatchEvents, IAM) and configures the ProviderConfig.

**Verify:**
```bash
kubectl get providers.pkg.crossplane.io
kubectl get providerconfig
```

## Phase 4: Install Kyverno

```bash
./scripts/bootstrap-kyverno.sh
```

This installs Kyverno with:
- **Fail-open mode** - If Kyverno is unavailable, requests are allowed (demo mode)
- **Policy reports enabled** - For auditability

**Verify:**
```bash
kubectl get pods -n kyverno
kubectl get clusterpolicy
```

### Apply Tag Policies

The Kyverno policies are applied automatically, but you can verify:

```bash
kubectl get clusterpolicy mutate-aws-resource-tags -o yaml
kubectl get clusterpolicy validate-aws-resource-tags -o yaml
```

## Verification: End-to-End Test

Create a test S3 bucket without tags and verify Kyverno adds them:

```bash
cat <<EOF | kubectl apply -f -
apiVersion: s3.aws.upbound.io/v1beta2
kind: Bucket
metadata:
  name: messagewall-test-bucket
spec:
  forProvider:
    region: us-east-1
  providerConfigRef:
    name: default
EOF
```

Check that tags were added:

```bash
kubectl get bucket messagewall-test-bucket -o jsonpath='{.spec.forProvider.tags}' | jq .
```

Expected output includes: `createdBy: crossplane`, `managedBy: messagewall-demo`, `environment: dev`

Clean up:

```bash
kubectl delete bucket messagewall-test-bucket
```

## Troubleshooting

### Crossplane provider not healthy

Check provider logs:
```bash
kubectl logs -n crossplane-system -l pkg.crossplane.io/provider=provider-aws-s3
```

### IAM permission errors

Check that the IAM policy includes required permissions. The policy may need updates as Crossplane providers evolve. See the `platform/iam/` directory for current policies.

### Kyverno not mutating resources

Check if the policy is ready:
```bash
kubectl get clusterpolicy mutate-aws-resource-tags -o jsonpath='{.status.conditions}'
```

## File Reference

| File | Purpose |
|------|---------|
| `scripts/bootstrap-kind.sh` | Create kind cluster |
| `scripts/bootstrap-crossplane.sh` | Install Crossplane |
| `scripts/bootstrap-aws-providers.sh` | Install AWS providers |
| `scripts/bootstrap-kyverno.sh` | Install Kyverno |
| `platform/iam/*.json` | IAM policies |
| `platform/crossplane/*.yaml` | Provider configuration |
| `platform/kyverno/values.yaml` | Kyverno Helm values |
| `platform/kyverno/policies/*.yaml` | Kyverno policies |
