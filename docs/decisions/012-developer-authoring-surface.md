# ADR-012: Developer Authoring Surface

## Status
Accepted

## Context

EPIC-16 asks: what do developers actually author when deploying applications to this platform?

Two options exist:

1. **Crossplane Claims**: Developers write `ServerlessEventAppClaim` YAML directly
2. **Higher-level spec** (e.g., OAM): Developers write an abstract spec that compiles into Claims

This decision affects:
- Developer cognitive load (what must they learn?)
- Tooling requirements (do we need a compiler?)
- Policy enforcement (what do policies validate?)
- Authority boundaries (what does ConfigHub store?)

### Prior Decisions That Constrain This Choice

Several architectural decisions have already shaped the answer:

| Decision | Constraint |
|----------|------------|
| ADR-010 | ConfigHub stores Claims, not expanded resources |
| ADR-005 | Claims are "fully-rendered manifests" at the developer abstraction level |
| Four-plane model | Claims sit at the Intent/Authority boundary |
| EPIC-11 XRD | Schema designed with 8 developer-facing fields, no AWS concepts |

### The Current State

The platform already has:
- `ServerlessEventAppClaim` XRD with a minimal schema
- Example Claims in `examples/claims/`
- Schema documentation in `docs/serverless-event-app-schema.md`
- Kyverno policies that validate Claim-level constraints
- ConfigHub units that store Claims

Developers have been authoring Claims directly throughout the demo's development.

## Decision

**Developers author Crossplane Claims directly as the canonical authoring surface.**

OAM (or any higher-level spec) is an **optional convenience layer** that compiles into Claims. It is not required for baseline platform usage.

```
┌─────────────────────────────────────────────────┐
│              Developer Authoring                │
│                                                 │
│   ┌─────────────┐         ┌─────────────────┐  │
│   │  OAM Spec   │─compile─▶│                 │  │
│   │ (optional)  │         │                 │  │
│   └─────────────┘         │  Crossplane     │  │
│                           │  Claim          │  │
│   ┌─────────────┐         │  (canonical)    │  │
│   │ Direct YAML │────────▶│                 │  │
│   │ authoring   │         │                 │  │
│   └─────────────┘         └────────┬────────┘  │
│                                    │           │
└────────────────────────────────────┼───────────┘
                                     │
                                     ▼
                              ConfigHub (authority)
                                     │
                                     ▼
                              Kubernetes (actuation)
                                     │
                                     ▼
                              AWS (runtime)
```

## Rationale

### Why Claims Are the Canonical Surface

**1. Alignment with authority model (ADR-010)**

ConfigHub stores Claims. If developers authored something else (OAM), we'd need:
- A compiler (OAM → Claim)
- Two schemas to maintain
- Policies written against both layers
- Confusion about which is authoritative

With Claims as canonical, there's one schema, one policy surface, one thing stored in ConfigHub.

**2. The Claim schema is already minimal**

The `ServerlessEventAppClaim` has 8 fields:

| Field | Purpose |
|-------|---------|
| `awsAccountId` | Target AWS account |
| `environment` | dev/staging/prod |
| `region` | AWS region |
| `resourcePrefix` | Naming prefix |
| `lambdaMemory` | Function memory (MB) |
| `lambdaTimeout` | Function timeout (seconds) |
| `eventSource` | Event bus name |
| `artifactBucket` | Lambda artifact location |

No IAM policies. No VPC configuration. No execution roles. AWS complexity is hidden in the Composition. Adding OAM on top would add abstraction without removing complexity.

**3. Four-plane model positions Claims at the right boundary**

From `docs/planes.md`:

```
Intent Plane (Git)        ← Developer writes Claim here
        │
        ▼
Authority Plane (ConfigHub) ← Claim is authoritative here
        │
        ▼
Actuation Plane (Kubernetes) ← Crossplane expands Claim
        │
        ▼
Runtime Plane (AWS)
```

The Claim sits exactly at the Intent/Authority boundary. A higher-level spec above Claims would blur this boundary—where does OAM live? Is it Intent? Is it pre-Intent?

**4. Policy enforcement has one target**

Policies in EPIC-14 validate Claims:

```rego
deny[msg] {
  input.kind == "ServerlessEventAppClaim"
  input.spec.environment == "prod"
  input.spec.lambdaMemory < 256
  msg := "Production Claims must have lambdaMemory >= 256"
}
```

If OAM were canonical, we'd need policies at both layers—OAM validation and Claim validation. With Claims canonical, policies are written once.

**5. No compiler means no compiler bugs**

A compiler from OAM → Claim is code that must be maintained, tested, and debugged. It's another failure mode. With direct Claim authoring, WYSIWYG—what developers write is what ConfigHub stores.

### Why OAM Remains an Option (Not Rejected)

OAM has legitimate use cases:

- **Organizational standardization**: If a company uses OAM across multiple platforms, consistency is valuable
- **Vendor neutrality**: OAM is platform-agnostic; Claims are Crossplane-specific
- **Ecosystem tooling**: OAM has growing IDE and validation tooling

For these cases, OAM can compile into Claims as a convenience. But:
- The Claim is what's stored in ConfigHub
- The Claim is what policies validate
- The Claim is what gets applied to Kubernetes

OAM is a pre-processor, not the canonical format.

### What We're Not Choosing

**We are not choosing OAM as canonical because:**

1. It adds a translation layer without reducing complexity
2. It creates two schemas to maintain
3. It requires policies at two levels
4. It blurs the Intent/Authority boundary
5. The Claim schema is already minimal (8 fields)

**We are not choosing to eliminate Claims because:**

1. Crossplane requires them
2. ConfigHub stores them
3. Policies validate them
4. The four-plane model depends on them

## Consequences

1. **Developer learning curve**: Developers must learn the Claim schema. Mitigation: Schema is minimal (8 fields) with good documentation.

2. **No standard authoring format**: Claims are Crossplane-specific. Teams wanting OAM can add it as a pre-processor.

3. **Schema evolution is Claim evolution**: Changes to what developers author mean changing the XRD. This is intentional—XRD is the single schema definition.

4. **ISSUE-16.1 and 16.2 become optional**: The OAM vocabulary (16.1) and OAM compiler (16.2) are nice-to-haves for teams that want them, not blockers for the platform.

5. **ISSUE-16.4 is already done**: Canonical examples exist in `examples/claims/`.

## Implementation

No implementation required—the platform already uses Claims as the authoring surface.

To formalize:
- Update EPIC-16 issues to reflect OAM as optional
- Ensure `docs/serverless-event-app-schema.md` is the canonical developer reference
- Consider adding a "Developer Quick Start" that walks through Claim authoring

## Related Documents

- [ADR-005: ConfigHub Integration Architecture](./005-confighub-integration-architecture.md)
- [ADR-010: ConfigHub Stores Claims, Not Expanded Resources](./010-confighub-claim-vs-expanded.md)
- [ADR-011: Bidirectional GitOps with ConfigHub as Authority](./011-ci-confighub-authority-conflict.md)
- [docs/planes.md](../planes.md) - Four-plane model
- [docs/serverless-event-app-schema.md](../serverless-event-app-schema.md) - Claim schema reference
- [examples/claims/](../../examples/claims/) - Canonical Claim examples
