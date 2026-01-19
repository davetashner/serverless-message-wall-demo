# ConfigHub Spaces

**Status**: Reference documentation for EPIC-17 (Production Protection Gates)
**Related**: [Tiered Authority Model](tiered-authority-model.md), [CI ConfigHub Setup](ci-confighub-setup.md)

---

## Overview

ConfigHub spaces organize configuration by environment. Each space represents a distinct deployment target with its own governance posture, approval requirements, and protection gates.

---

## Space-to-Environment Mapping

| Space | Environment | Tier | Description |
|-------|-------------|------|-------------|
| `messagewall-dev` | dev | Pre-prod | Development and testing |
| `messagewall-prod` | prod | Production | Live workloads, maximum protection |

### Naming Convention

```
{application}-{tier}[-{variant}]

Examples:
  messagewall-dev          # Development environment
  messagewall-prod         # Production environment
  messagewall-staging      # (Future) Staging environment
  messagewall-sandbox-42   # (Future) Agent experiment variant
```

---

## Space Metadata

Each space carries metadata for policy enforcement. Example for production:

```yaml
space: messagewall-prod
metadata:
  environment: prod
  tier: production
  tenant: messagewall
  data-classification: customer-data
  delete-protection: enabled
```

---

## Production Space (`messagewall-prod`)

### Governance

| Attribute | Value |
|-----------|-------|
| **ConfigHub registration** | Required |
| **Approval required** | LOW: auto-approve; MEDIUM: acknowledgment; HIGH: multi-party |
| **Policy enforcement** | Strictly enforced, no exceptions |
| **Delete gates** | Required for all stateful resources |
| **Data classification** | Real customer data |

### Protected Resources

The following resources in `messagewall-prod` have delete/destroy gates:

- **DynamoDB tables** — Marked as `precious=true`
- **S3 buckets** — Marked as `precious=true`

Attempts to delete these resources fail without explicit approval.

### Creating the Production Space

```bash
# Authenticate to ConfigHub
cub auth login

# Create the production space
cub space create messagewall-prod

# Set environment metadata (if supported by your ConfigHub version)
cub space update messagewall-prod --metadata environment=prod,tier=production
```

---

## Development Space (`messagewall-dev`)

### Governance

| Attribute | Value |
|-----------|-------|
| **ConfigHub registration** | Required |
| **Approval required** | None for LOW/MEDIUM; HIGH needs lead approval |
| **Policy enforcement** | Enforced (relaxed thresholds) |
| **Delete gates** | None (optional for databases) |
| **Data classification** | Synthetic or test data only |

### Creating the Development Space

```bash
cub auth login
cub space create messagewall-dev
```

---

## Space Configuration Files

Each environment has a configuration file in `config/`:

| File | Space | Purpose |
|------|-------|---------|
| `config/dev.env` | `messagewall-dev` | Development environment values |
| `config/prod.env` | `messagewall-prod` | Production environment values |

These files define environment-specific values (AWS account, bucket names, etc.) used when rendering Crossplane manifests.

---

## ArgoCD Applications

Each space has a corresponding ArgoCD Application that syncs from ConfigHub:

| Application | Space | File |
|-------------|-------|------|
| `messagewall-dev` | `messagewall-dev` | `platform/argocd/application-dev.yaml` |
| `messagewall-prod` | `messagewall-prod` | `platform/argocd/application-prod.yaml` |

The CMP plugin fetches `LiveRevisionNum` content from the space, enabling controlled rollout where CI pushes revisions but explicit `cub unit apply` is required to deploy.

---

## Setting Up a New Environment

To add a new environment (e.g., `staging`):

1. **Create the ConfigHub space**
   ```bash
   cub space create messagewall-staging
   ```

2. **Create the config file**
   ```bash
   cp config/dev.env config/staging.env
   # Edit staging.env with appropriate values
   ```

3. **Create the ArgoCD Application**
   ```bash
   cp platform/argocd/application-dev.yaml platform/argocd/application-staging.yaml
   # Edit to reference messagewall-staging space
   ```

4. **Create a ConfigHub worker for the actuator**
   ```bash
   cub worker create --space messagewall-staging actuator-sync
   ```

5. **Configure ArgoCD credentials**
   ```bash
   ./scripts/setup-argocd-confighub-auth.sh --space messagewall-staging
   ```

---

## References

- [Tiered Authority Model](tiered-authority-model.md) — Governance by tier
- [CI ConfigHub Setup](ci-confighub-setup.md) — Publishing to ConfigHub
- [ConfigHub Crossplane Narrative](confighub-crossplane-narrative.md) — Architecture overview
