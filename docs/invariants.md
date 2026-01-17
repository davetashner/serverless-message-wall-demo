# Platform Invariants and Non-Goals

This document defines what must always be true about the platform (invariants) and what is explicitly out of scope (non-goals). These constraints guide design decisions and prevent scope creep.

---

## Invariants

Invariants are properties that must hold at all times. Violating an invariant is a bug that must be fixed.

### Currently Enforced

#### 1. Kubernetes is actuator-only

**Statement**: The Kubernetes cluster runs only infrastructure controllers (Crossplane, Kyverno). No application code, no user-facing services, no data processing workloads run in the cluster.

**Why it matters**: This creates a clean separation between the Actuation Plane and Runtime Plane. If the cluster fails, the application continues running. The cluster is a control plane, not a data plane.

**Enforcement**: Code review. There are no Deployment, StatefulSet, or Service resources for application workloads in the repo.

**References**: [beads/principles.md](../beads/principles.md)

---

#### 2. All AWS resources are tagged

**Statement**: Every AWS resource created by Crossplane must have the tags `createdBy`, `managedBy`, and `environment`.

**Why it matters**: Tags enable cost allocation, identify ownership, and allow safe bulk cleanup. Untagged resources are orphans that accumulate cost and risk.

**Enforcement**:
- Kyverno mutation policy injects tags automatically
- Kyverno validation policy rejects resources missing required tags
- See [ADR-007](decisions/007-kyverno-policy-enforcement.md)

---

#### 3. All infrastructure is declared in Git

**Statement**: AWS resources are created only through Crossplane manifests that originate from the Git repository. No resources are created via AWS Console, CLI, or other ad-hoc methods.

**Why it matters**: Git provides version history, code review, and rollback capability. Manual changes create drift that's hard to track and reproduce.

**Enforcement**:
- Crossplane reconciliation detects and corrects drift
- IAM policies scope Crossplane to `messagewall-*` resources only
- Manual changes outside this prefix are not platform-managed

---

#### 4. Crossplane IAM is least-privilege with boundaries

**Statement**: The Crossplane IAM user can only create resources with the `messagewall-*` prefix. All IAM roles created by Crossplane must have the `MessageWallRoleBoundary` permission boundary attached.

**Why it matters**: Limits blast radius if Crossplane is compromised. Even with full Crossplane access, an attacker cannot escalate to arbitrary AWS permissions or affect resources outside the demo scope.

**Enforcement**:
- `crossplane-actuator-policy.json` restricts resource names
- `messagewall-role-boundary.json` caps role permissions
- See [ADR-006](decisions/006-crossplane-and-iam-strategy.md)

---

#### 5. Event-driven, not synchronous

**Statement**: Lambda functions do not call each other directly. Communication happens through EventBridge events or shared state (DynamoDB, S3).

**Why it matters**: Synchronous Lambda-to-Lambda calls create tight coupling, cascading failures, and double-billing. Event-driven architecture is more resilient and easier to reason about.

**Enforcement**: Code review. Lambda IAM roles do not include `lambda:Invoke` permissions for other functions.

**References**: [beads/principles.md](../beads/principles.md)

---

#### 6. Configuration uses simple substitution

**Statement**: Infrastructure templates use `${VARIABLE}` placeholder syntax resolved by `envsubst`. No complex templating engines, no conditionals, no loops in templates.

**Why it matters**: Simple substitution is predictable and debuggable. Complex templating creates a language-within-a-language that's hard to reason about and test.

**Enforcement**:
- Setup wizard uses `envsubst` only
- See [ADR-008](decisions/008-setup-wizard.md)

---

### Planned (Future)

These invariants will be enforced once ConfigHub integration is complete.

#### 7. ConfigHub is the authority for resolved configuration *(planned)*

**Statement**: Once rendered, configuration lives in ConfigHub as the single source of truth. Git remains the authoring surface, but ConfigHub holds the authoritative resolved state.

**Why it matters**: ConfigHub enables bulk changes, policy enforcement, approval gates, and configuration history that Git alone cannot provide.

**Enforcement**: Will be enforced by CI pipeline rejecting direct kubectl apply; all changes must flow through ConfigHub.

**References**: [ADR-005](decisions/005-confighub-integration.md), EPIC-8, EPIC-13

---

#### 8. Policy checks run before actuation *(planned)*

**Statement**: Configuration must pass policy checks (IAM wildcard detection, Lambda bounds, etc.) before it can be applied to the Actuation Plane.

**Why it matters**: Catching misconfigurations before deployment prevents outages and security issues. Shift-left validation reduces mean time to feedback.

**Enforcement**: Will be enforced by ConfigHub policy functions or OPA checks that gate the apply flow.

**References**: EPIC-14

---

#### 9. High-risk changes require human approval *(planned)*

**Statement**: Changes classified as high-risk (e.g., IAM policy modifications, resource deletion) cannot be applied without explicit human approval.

**Why it matters**: Prevents automated systems (including AI agents) from making dangerous changes without oversight.

**Enforcement**: Will be enforced by ConfigHub approval workflow with risk classification.

**References**: EPIC-15

---

## Non-Goals

Non-goals are things we explicitly choose not to do. They are not failures or missing features—they are deliberate scope boundaries.

### Production Hardening

**Statement**: This platform is demo-first. Production concerns like high availability, multi-region failover, and SLA guarantees are out of scope.

**Examples of what we won't do**:
- Multi-AZ or multi-region deployment
- Auto-scaling configuration
- Circuit breakers or retry policies
- SLA monitoring and alerting

**Rationale**: The goal is to demonstrate the architecture clearly, not to build a production system. Adding production concerns would obscure the core concepts.

**Time-boxed until**: This remains a non-goal unless the project scope changes to include production workloads.

---

### Complex State Management

**Statement**: The data model is intentionally simple. Advanced patterns like CQRS, event sourcing, or complex transactions are out of scope.

**Examples of what we won't do**:
- Multi-table DynamoDB designs
- Transaction coordination between services
- Caching layers (ElastiCache, DAX)
- Complex query patterns

**Rationale**: A single-table design with simple read/write patterns is sufficient for the demo and easier to understand.

**Time-boxed until**: This remains a non-goal for this demo application.

---

### Fine-Grained Access Control

**Statement**: RBAC for multiple users/teams, audit logging of individual actions, and namespace isolation are out of scope.

**Examples of what we won't do**:
- Per-team Crossplane permissions
- Kubernetes RBAC beyond cluster-admin
- Detailed audit trails of who changed what

**Rationale**: The demo assumes a single operator. Multi-tenant concerns add complexity without demonstrating new architectural concepts.

**Time-boxed until**: This may become relevant if ConfigHub integration includes multi-user scenarios.

---

### Secrets Management

**Statement**: Production-grade secrets management (rotation, encryption at rest, access auditing) is out of scope.

**Examples of what we won't do**:
- AWS Secrets Manager integration
- Automatic credential rotation
- Encryption of secrets at rest in Kubernetes

**Current approach**: AWS credentials stored in a Kubernetes Secret. Acceptable for a local demo cluster.

**Time-boxed until**: This remains a non-goal unless the demo moves to a shared or long-lived cluster.

---

### Performance Optimization

**Statement**: The platform is not tuned for performance. Optimization work is out of scope.

**Examples of what we won't do**:
- Lambda memory/timeout tuning for latency
- DynamoDB provisioned capacity or DAX
- S3 CloudFront distribution
- Cold start optimization

**Rationale**: Performance optimization obscures the architectural concepts being demonstrated.

**Time-boxed until**: This remains a non-goal for the demo.

---

### Multi-Environment at Scale

**Statement**: The current template approach requires re-running setup for each environment. A more sophisticated multi-environment system is out of scope.

**Examples of what we won't do**:
- Kustomize overlays for environments
- Helm chart with values per environment
- Automated environment promotion pipelines

**Current approach**: Each environment is a separate setup wizard run with different values.

**Time-boxed until**: ConfigHub integration (EPIC-8, EPIC-13) will address multi-environment as a side effect.

---

## How to Use This Document

1. **When designing new features**: Check invariants to ensure the design doesn't violate core properties. Check non-goals to avoid scope creep.

2. **When reviewing PRs**: Verify that changes maintain all enforced invariants.

3. **When prioritizing work**: If something is listed as a non-goal, deprioritize requests for it unless the scope decision has been revisited.

4. **When planned invariants become enforced**: Update this document to move them from "Planned" to "Currently Enforced" and document the enforcement mechanism.

---

## References

- [Four-Plane Model](planes.md)
- [ADR-005: ConfigHub Integration](decisions/005-confighub-integration.md)
- [ADR-006: Crossplane and IAM Strategy](decisions/006-crossplane-and-iam-strategy.md)
- [ADR-007: Kyverno Policy Enforcement](decisions/007-kyverno-policy-enforcement.md)
- [ADR-008: Setup Wizard](decisions/008-setup-wizard.md)
- [Guiding Principles](../beads/principles.md)
