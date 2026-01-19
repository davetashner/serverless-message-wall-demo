# Precious Resources

**Status**: Reference documentation for EPIC-17 (Production Protection Gates)
**Related**: [Tiered Authority Model](tiered-authority-model.md), [ConfigHub Spaces](confighub-spaces.md), [Risk Taxonomy](risk-taxonomy.md)

---

## Overview

**Precious resources** are stateful infrastructure components whose deletion or destruction would cause irreversible data loss. These resources require explicit protection gates in production environments.

---

## Definition

A resource is **precious** if:

1. **Stateful**: It stores data that cannot be reconstructed from configuration alone
2. **Business-critical**: Loss of data impacts customers, operations, or compliance
3. **Irreversible**: Deletion or destruction cannot be undone without backups

**Not precious**: Resources that can be recreated from configuration (Lambda functions, IAM roles, EventBridge rules).

---

## Resource Classification

### Database Units (Precious)

| Resource Type | Why Precious | Protection Required |
|---------------|--------------|---------------------|
| **DynamoDB Table** | Stores application state (messages, metadata) | Delete gate, destroy gate |
| **RDS Database** | Stores relational data | Delete gate, destroy gate |
| **ElastiCache Cluster** | May store session data | Delete gate (if persistent) |

### Storage Units (Precious)

| Resource Type | Why Precious | Protection Required |
|---------------|--------------|---------------------|
| **S3 Bucket** | Stores application data, state snapshots | Delete gate, destroy gate |
| **EFS Volume** | Persistent file storage | Delete gate, destroy gate |
| **EBS Volume** | Block storage with data | Delete gate |

### Not Database Units (Recreatable)

| Resource Type | Why Not Precious |
|---------------|------------------|
| **Lambda Function** | Recreated from code artifact |
| **IAM Role/Policy** | Recreated from configuration |
| **EventBridge Rule** | Recreated from configuration |
| **API Gateway** | Recreated from configuration |
| **CloudWatch Logs** | Operational data, not business data |

---

## Labeling Convention

### Unit-Level Labeling

ConfigHub units containing precious resources are labeled in their metadata:

```yaml
# Unit metadata in ConfigHub
unit: messagewall-prod
metadata:
  precious: "true"
  precious-resources: "dynamodb,s3"
  data-classification: "customer-data"
```

### Claim-Level Annotations

Crossplane Claims carry annotations identifying precious child resources:

```yaml
apiVersion: messagewall.demo/v1alpha1
kind: ServerlessEventAppClaim
metadata:
  name: messagewall-prod
  namespace: default
  annotations:
    confighub.io/precious: "true"
    confighub.io/precious-resources: "dynamodb,s3"
    confighub.io/data-classification: "customer-data"
spec:
  environment: prod
  # ...
```

### Label Schema

| Label | Values | Description |
|-------|--------|-------------|
| `precious` | `"true"` / `"false"` | Whether unit contains any precious resources |
| `precious-resources` | Comma-separated list | Which resource types are precious |
| `data-classification` | `test-data`, `customer-data`, `pii` | Data sensitivity level |

---

## Precious Resources in This Demo

### messagewall-prod Claim

The production ServerlessEventAppClaim contains two precious resources:

| Resource | Crossplane Kind | AWS Resource | Data Stored |
|----------|-----------------|--------------|-------------|
| **DynamoDB Table** | `dynamodb.aws.upbound.io/Table` | `messagewall-prod-{account}` | Messages, metadata |
| **S3 Bucket** | `s3.aws.upbound.io/Bucket` | `messagewall-prod-{account}` | Static site, state.json |

Both resources contain application data that would be lost if the Claim is deleted.

### messagewall-dev Claim

The development Claim contains the same resource types, but:
- Data is synthetic/test data
- Delete gates are **optional** (per tiered authority model)
- `precious: "false"` or no label

---

## Querying Precious Units

### List All Precious Database Units in Production

Using `cub` CLI (ConfigHub command-line tool):

```bash
# List all units with precious=true in prod space
cub unit list --space messagewall-prod --filter "metadata.precious=true"

# List units with specific precious resources
cub unit list --space messagewall-prod --filter "metadata.precious-resources~dynamodb"
```

### Using kubectl (Crossplane Claims)

```bash
# List Claims with precious annotation
kubectl get serverlesseventappclaim -A \
  -o jsonpath='{range .items[?(@.metadata.annotations.confighub\.io/precious=="true")]}{.metadata.name}{"\n"}{end}'

# Get details of precious Claims
kubectl get serverlesseventappclaim -A \
  -l environment=prod \
  -o custom-columns=\
NAME:.metadata.name,\
NAMESPACE:.metadata.namespace,\
PRECIOUS:.metadata.annotations.confighub\.io/precious,\
RESOURCES:.metadata.annotations.confighub\.io/precious-resources
```

### Inventory Script

```bash
#!/bin/bash
# scripts/list-precious-units.sh
# List all precious database units across all production spaces

echo "Precious Database Units in Production"
echo "======================================"
echo ""

for space in $(cub space list --filter "metadata.tier=production" -o name); do
    echo "Space: ${space}"
    cub unit list --space "${space}" \
        --filter "metadata.precious=true" \
        --filter "metadata.precious-resources~dynamodb" \
        -o table
    echo ""
done
```

---

## Protection Requirements by Classification

| Data Classification | Delete Gate | Destroy Gate | Backup Required |
|---------------------|-------------|--------------|-----------------|
| `test-data` | Optional | Optional | No |
| `customer-data` | Required | Required | Yes (daily) |
| `pii` | Required | Required + audit | Yes (hourly) |

---

## Relationship to EPIC-17 Issues

| Issue | Relationship |
|-------|--------------|
| **ISSUE-17.2** (this doc) | Defines classification and query patterns |
| **ISSUE-17.3** | Enforces delete/destroy gates on precious units |
| **ISSUE-17.4** | Defines approval workflow for gated operations |
| **ISSUE-17.5** | Demonstrates the gate workflow |

---

## Summary

| Question | Answer |
|----------|--------|
| What is precious? | Stateful, irreversible, business-critical |
| Which types? | DynamoDB, S3 (with data), RDS, etc. |
| How labeled? | `precious: "true"` + `precious-resources: "..."` |
| Where enforced? | ConfigHub gates (delete/destroy require approval) |
| How to query? | `cub unit list --filter "metadata.precious=true"` |

---

## References

- [Tiered Authority Model](tiered-authority-model.md) — Gate posture by environment tier
- [ConfigHub Spaces](confighub-spaces.md) — Space configuration and metadata
- [Risk Taxonomy](risk-taxonomy.md) — Risk classification for changes
- [Approval Gates](design-approval-gates.md) — Approval workflow for high-risk operations
