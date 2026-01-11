# ADR-007: Kyverno Policy Enforcement for AWS Resource Tags

## Status
Accepted

## Context
We want to ensure all AWS resources created by Crossplane are tagged with metadata indicating their origin. This supports:
- Cost allocation and tracking in AWS
- Safe identification of Crossplane-managed resources for cleanup
- Audit trail proving resources were created through the approved GitOps flow
- Clear distinction between Crossplane-managed and manually-created resources

We need a policy engine that can both enforce tag requirements and automatically add tags to resources.

## Decision

### 1. Policy Engine: Kyverno

Use Kyverno for policy enforcement in the actuator cluster.

**Rationale:**
- **Mutation + Validation**: Can automatically add missing tags AND reject non-compliant resources
- **YAML-based policies**: No new policy language (unlike Rego for OPA)
- **Kubernetes-native**: Works naturally with Crossplane managed resources
- **Active ecosystem**: Well-maintained, good documentation

**Alternatives considered:**
- OPA/Gatekeeper: More powerful but steeper learning curve, limited mutation support
- CEL ValidatingAdmissionPolicy: Built-in but validation-only, no mutation
- Crossplane Compositions: Defaults only, not enforcement

### 2. Required Tags

All AWS managed resources must have the following tags:

| Tag Key | Value | Purpose |
|---------|-------|---------|
| `createdBy` | `crossplane` | Identifies resource origin |
| `managedBy` | `messagewall-demo` | Identifies the managing project |
| `environment` | `dev` (or per-environment) | Environment classification |

### 3. Policy Approach: Mutate + Validate

Implement a two-layer approach:

1. **Mutation Policy**: Automatically inject required tags into all AWS managed resources before they are created. This makes compliance the default.

2. **Validation Policy**: Reject any AWS managed resource that lacks required tags. This catches edge cases where mutation might be bypassed.

### 4. Policy Scope

Policies apply to all Crossplane AWS provider resources:
- `*.s3.aws.upbound.io/*`
- `*.dynamodb.aws.upbound.io/*`
- `*.lambda.aws.upbound.io/*`
- `*.cloudwatchevents.aws.upbound.io/*`
- `*.iam.aws.upbound.io/*`

Note: IAM resources (roles, policies) don't support AWS tags in the same way, so IAM resources may need different handling or exclusion.

## Implementation

### Mutation Policy

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: add-crossplane-aws-tags
spec:
  rules:
  - name: add-required-tags
    match:
      any:
      - resources:
          kinds:
          - "*.s3.aws.upbound.io/*"
          - "*.dynamodb.aws.upbound.io/*"
          - "*.lambda.aws.upbound.io/*"
          - "*.cloudwatchevents.aws.upbound.io/*"
    mutate:
      patchStrategicMerge:
        spec:
          forProvider:
            tags:
              createdBy: crossplane
              managedBy: messagewall-demo
              environment: dev
```

### Validation Policy

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-crossplane-aws-tags
spec:
  validationFailureAction: Enforce
  rules:
  - name: check-required-tags
    match:
      any:
      - resources:
          kinds:
          - "*.s3.aws.upbound.io/*"
          - "*.dynamodb.aws.upbound.io/*"
          - "*.lambda.aws.upbound.io/*"
          - "*.cloudwatchevents.aws.upbound.io/*"
    validate:
      message: "AWS resources must have createdBy, managedBy, and environment tags"
      pattern:
        spec:
          forProvider:
            tags:
              createdBy: "crossplane"
              managedBy: "?*"
              environment: "?*"
```

## Installation Configuration

Kyverno is installed via Helm with the following configuration (see `platform/kyverno/values.yaml`):

| Setting | Value | Rationale |
|---------|-------|-----------|
| `admissionController.failurePolicy` | `Ignore` (fail open) | Demo environment: if Kyverno is unavailable, allow requests through rather than blocking cluster operations. **Production should use `Fail` (fail closed).** |
| `reportsController.enabled` | `true` | Enables PolicyReport resources for auditability and visibility into policy violations |
| `backgroundController.enabled` | `true` | Enables background scanning of existing resources |
| Replicas | `1` | Single replica for local kind cluster; production should use `2+` for HA |

**Warning:** The fail-open configuration means that if Kyverno pods are unavailable, resources can be created without tag validation. This is acceptable for a demo but not for production environments where compliance is mandatory.

## Consequences

- Kyverno must be installed in the actuator cluster before deploying AWS resources
- All AWS resources will automatically receive required tags via mutation
- Resources without tags will be rejected at admission time
- AWS Cost Explorer can filter by `createdBy:crossplane` tag
- Cleanup scripts can safely target tagged resources
- IAM resources may need separate handling (tags work differently for IAM)
- PolicyReports provide audit trail of policy evaluations
