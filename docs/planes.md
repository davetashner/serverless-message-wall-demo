# Four-Plane Model

This document defines the four planes that organize configuration and execution in the serverless message wall platform. Each plane has a distinct responsibility, and artifacts belong to exactly one plane.

## Overview

```
┌─────────────────────────────────────────────────────────────────────────┐
│  INTENT PLANE          │  What humans want                             │
│  (Git)                 │  Source code, templates, issues               │
├────────────────────────┼────────────────────────────────────────────────┤
│  AUTHORITY PLANE       │  What configuration is true                   │
│  (Rendered config)     │  Resolved manifests, validated values         │
├────────────────────────┼────────────────────────────────────────────────┤
│  ACTUATION PLANE       │  How infrastructure gets created              │
│  (Kubernetes)          │  Crossplane controllers, Kyverno policies     │
├────────────────────────┼────────────────────────────────────────────────┤
│  RUNTIME PLANE         │  Where application logic executes             │
│  (AWS)                 │  Lambda, DynamoDB, S3, EventBridge            │
└────────────────────────┴────────────────────────────────────────────────┘
```

---

## Intent Plane

**Definition**: The Intent Plane is where humans express what they want the system to do. It contains source code, infrastructure templates, and design decisions. Artifacts here are authored by humans and versioned in Git. They may contain placeholders or parameters that require resolution before they become actionable.

**What happens here**:
- Engineers write application code (Python Lambda handlers, HTML/JS frontend)
- Infrastructure is defined as Crossplane manifest templates with `${VARIABLE}` placeholders
- Architecture decisions are documented in ADRs
- Work is tracked in the Beads issue system

**Artifacts**:
| Path | Description |
|------|-------------|
| `app/api-handler/` | Lambda handler code (Python) |
| `app/snapshot-writer/` | Lambda handler code (Python) |
| `app/web/` | Static website (HTML, JavaScript) |
| `infra/base/*.yaml.template` | Crossplane manifest templates |
| `platform/iam/*.json.template` | IAM policy templates |
| `docs/decisions/` | Architecture Decision Records |
| `beads/backlog.jsonl` | Issue tracking |
| `beads/principles.md` | Guiding principles |

**Key property**: Intent artifacts are the source of truth for *what* the system should be, but they cannot be applied directly—they must flow through the Authority Plane first.

---

## Authority Plane

**Definition**: The Authority Plane is where configuration becomes concrete and authoritative. Templates from the Intent Plane are rendered with actual values, validated, and become the single source of truth for what should exist. Changes to the system must flow through this plane.

**What happens here**:
- The setup wizard (`scripts/setup.sh`) collects environment-specific values
- Templates are rendered into concrete manifests via `envsubst`
- Configuration values are validated (account ID format, bucket name rules, region format)
- The resulting manifests become the authoritative configuration

**Current implementation**:
| Path | Description |
|------|-------------|
| `infra/base/*.yaml` | Rendered Crossplane manifests (generated from templates) |
| `platform/iam/*.json` | Rendered IAM policies |
| `.setup-state.json` | Setup wizard state (tracks applied configuration) |

**Future direction (ConfigHub)**:
The Authority Plane will evolve to use ConfigHub as a dedicated configuration control plane. ConfigHub will:
- Store rendered configuration as queryable, versioned data
- Enable bulk changes across multiple resources in one operation
- Enforce policy checks before configuration reaches the Actuation Plane
- Provide approval gates for high-risk changes
- Track configuration history and enable rollback

See [ADR-005](decisions/005-confighub-integration.md) for the full ConfigHub integration architecture.

**Key property**: The Authority Plane answers "what configuration is currently true?" It is the checkpoint between human intent and infrastructure actuation.

---

## Actuation Plane

**Definition**: The Actuation Plane is where infrastructure gets created and maintained. It runs controllers that watch authoritative configuration and reconcile the actual state of cloud resources to match. In this platform, Kubernetes serves exclusively as an actuator—no application code runs here.

**What happens here**:
- ArgoCD syncs configuration from ConfigHub to Kubernetes via a Config Management Plugin
- Crossplane controllers watch Kubernetes CRDs and create/update/delete AWS resources
- Kyverno policies mutate resources (adding required tags) and validate compliance
- The reconciliation loop continuously corrects drift between desired and actual state
- IAM boundaries constrain what resources can be created

**Artifacts**:
| Path | Description |
|------|-------------|
| `platform/crossplane/providers.yaml` | AWS provider installation |
| `platform/crossplane/provider-config.yaml` | AWS credentials and region |
| `platform/kyverno/policies/mutate-aws-tags.yaml` | Tag injection policy |
| `platform/kyverno/policies/validate-aws-tags.yaml` | Tag validation policy |
| `platform/kyverno/values.yaml` | Kyverno Helm configuration |
| `platform/argocd/values.yaml` | ArgoCD Helm configuration |
| `platform/argocd/cmp-plugin.yaml` | ConfigHub CMP plugin |
| `platform/argocd/application-dev.yaml` | ArgoCD Application for dev |
| `scripts/bootstrap-kind.sh` | Local cluster creation |
| `scripts/bootstrap-crossplane.sh` | Crossplane installation |
| `scripts/bootstrap-aws-providers.sh` | AWS provider setup |
| `scripts/bootstrap-kyverno.sh` | Kyverno installation |
| `scripts/bootstrap-argocd.sh` | ArgoCD installation |
| `scripts/setup-argocd-confighub-auth.sh` | ConfigHub credentials setup |

**Key property**: The Actuation Plane is stateless with respect to application logic. It only knows how to reconcile declared resources to their desired state. If Kubernetes disappears, the Runtime Plane continues operating—we just lose the ability to make changes.

---

## Runtime Plane

**Definition**: The Runtime Plane is where application logic executes and users interact with the system. It consists entirely of AWS managed services—no Kubernetes pods serve application traffic. The Runtime Plane is the "product" that users experience.

**What happens here**:
- API Handler Lambda receives browser requests, updates DynamoDB, emits events
- Snapshot Writer Lambda generates state.json from DynamoDB and writes to S3
- S3 serves the static website and state snapshot to browsers
- EventBridge routes events between Lambda functions asynchronously
- CloudWatch Logs captures execution logs for observability

**Artifacts** (AWS resources, not repo files):
| Resource | Description |
|----------|-------------|
| `messagewall-api-handler` Lambda | Handles POST requests |
| `messagewall-snapshot-writer` Lambda | Generates state.json |
| `messagewall-*` DynamoDB table | Stores messages and count |
| `messagewall-*` S3 bucket | Hosts website and state |
| `messagewall-*` EventBridge rule | Triggers snapshot on message |
| CloudWatch Log Groups | Lambda execution logs |

**Key property**: The Runtime Plane is fully managed by AWS. There are no servers to patch, no containers to restart, no Kubernetes pods serving traffic. The platform team manages the Actuation Plane; AWS manages the Runtime Plane.

---

## Data Flow Between Planes

```
                    ┌──────────────────┐
                    │   INTENT PLANE   │
                    │                  │
                    │  Templates       │
                    │  Source code     │
                    │  ADRs            │
                    └────────┬─────────┘
                             │
                             │ CI renders templates
                             │ with environment values
                             ▼
                    ┌──────────────────┐
                    │ AUTHORITY PLANE  │
                    │                  │
                    │  ConfigHub       │
                    │  (authoritative) │
                    │  Policy checks   │
                    └────────┬─────────┘
                             │
                             │ ArgoCD CMP pulls from ConfigHub
                             │ (no direct kubectl from CI)
                             ▼
                    ┌──────────────────┐
                    │ ACTUATION PLANE  │
                    │                  │
                    │  ArgoCD (sync)   │
                    │  Crossplane      │
                    │  Kyverno         │
                    │  (Kubernetes)    │
                    └────────┬─────────┘
                             │
                             │ Crossplane reconciles
                             │ AWS API calls
                             ▼
                    ┌──────────────────┐
                    │  RUNTIME PLANE   │
                    │                  │
                    │  Lambda          │
                    │  DynamoDB        │
                    │  S3, EventBridge │
                    └──────────────────┘
                             │
                             │ Browser requests
                             ▼
                         [ Users ]
```

---

## Why This Separation Matters

1. **Clear ownership**: Each plane has a distinct owner and change process. Platform engineers own Intent and Actuation; the Authority Plane mediates; AWS owns Runtime execution.

2. **Blast radius control**: A bug in a Crossplane manifest doesn't crash running Lambdas. A Lambda error doesn't corrupt the authoritative configuration.

3. **Independent evolution**: The Actuation Plane can be replaced (e.g., swap Crossplane for Terraform) without changing Intent or Runtime. ConfigHub can be introduced to the Authority Plane without rewriting templates.

4. **Audit and compliance**: Each plane boundary is a checkpoint. Configuration changes are visible as they flow from Intent → Authority → Actuation → Runtime.

5. **Recovery**: If the Actuation Plane fails, the Runtime continues serving users. Re-bootstrapping the cluster and reapplying authoritative config restores control.

---

## References

- [ADR-005: ConfigHub Integration Architecture](decisions/005-confighub-integration.md)
- [ADR-006: Crossplane Installation and IAM Strategy](decisions/006-crossplane-and-iam-strategy.md)
- [ADR-007: Kyverno Policy Enforcement](decisions/007-kyverno-policy-enforcement.md)
- [ADR-009: ArgoCD Config Management Plugin for ConfigHub Sync](decisions/009-argocd-confighub-sync.md)
- [Platform Invariants](invariants.md)
