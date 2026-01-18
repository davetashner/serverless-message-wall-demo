# ConfigHub Policies

This directory contains OPA (Rego) policies that run in ConfigHub before configuration is applied to the actuator cluster.

## Defense in Depth

These policies intentionally duplicate some Kyverno policies to provide defense in depth:

| Policy | ConfigHub (Authority) | Kyverno (Actuation) |
|--------|----------------------|---------------------|
| Required tags | `require-tags.rego` | `validate-aws-tags.yaml` |
| Prod requirements | `prod-requirements.rego` | `validate-claim-prod-requirements.yaml` |

**Why duplicate?**
- ConfigHub catches violations before apply (faster feedback)
- Kyverno catches violations during admission (final safety net)
- If one layer fails or is bypassed, the other still enforces

See [ADR-005](../../../docs/decisions/005-confighub-integration-architecture.md) for details.

## Policies

### require-tags.rego

Validates that ServerlessEventAppClaims have required fields:
- `spec.environment` (must be dev, staging, or prod)
- `spec.awsAccountId` (must be 12 digits)
- `metadata.name` (must be present)

### prod-requirements.rego

Enforces production environment constraints:
- Lambda memory >= 256 MB
- Lambda timeout >= 30 seconds

## Usage with ConfigHub

### Publishing Policies

```bash
# Publish policy to ConfigHub
cub policy create require-tags \
  --space messagewall-dev \
  --file platform/confighub/policies/require-tags.rego

# Attach policy to unit type
cub policy attach require-tags \
  --space messagewall-dev \
  --kind ServerlessEventAppClaim
```

### Testing Policies Locally

```bash
# Install OPA CLI
brew install opa

# Test policy against a sample Claim
opa eval \
  --input examples/claims/messagewall-dev.yaml \
  --data platform/confighub/policies/require-tags.rego \
  "data.messagewall.policies.tags.deny"

# Expected output for valid Claim: empty set []
# Expected output for invalid Claim: set of error messages
```

### Policy Violations

When a policy denies a unit update, ConfigHub returns an error:

```
Error: Policy violation in require-tags
  - ServerlessEventAppClaim must specify spec.environment (dev, staging, or prod)
```

The unit is not updated, and the violation is logged in ConfigHub's audit trail.

## Adding New Policies

1. Create a new `.rego` file in this directory
2. Follow the package naming convention: `package messagewall.policies.<name>`
3. Use `deny contains msg if { ... }` for blocking violations
4. Use `warn contains msg if { ... }` for non-blocking warnings
5. Test locally with `opa eval`
6. Publish to ConfigHub with `cub policy create`
