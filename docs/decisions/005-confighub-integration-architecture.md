# ADR-005: ConfigHub Integration Architecture

## Status
Accepted

## Context
ConfigHub (confighub.com) is an external tool that stores fully-rendered Kubernetes manifests as data with a queryable/mutatable API. We want to integrate ConfigHub into the deployment flow so that:
- ConfigHub becomes the authoritative source of truth for resolved configuration
- The Kubernetes actuator receives manifests from ConfigHub, not directly from Git
- Policy enforcement and bulk changes happen in ConfigHub before actuation

## Decision
Adopt the following deployment flow:

```
Git (authoring)
    │
    ▼
Render Crossplane CRDs (CI/pipeline)
    │
    ▼
ConfigHub (authoritative store)
    │
    ▼
Kubernetes Actuator (pulls/receives from ConfigHub)
    │
    ▼
AWS Resources (managed by Crossplane)
```

## Rationale
- Git remains the authoring surface for developers
- Rendering happens in CI, producing fully-resolved manifests (no placeholders)
- ConfigHub holds the authoritative resolved configuration, enabling:
  - Policy checks before apply
  - Bulk configuration changes via API
  - Audit trail of all changes
  - Drift detection between intended and actual state
- Kubernetes actuator only applies what ConfigHub approves

## Open Questions
- **Actuation mechanism**: ConfigHub may use ArgoCD to push manifests to the actuator cluster, or the actuator may pull from ConfigHub. This will be clarified in EPIC-8 implementation.

## Consequences
- CI pipeline must render and publish to ConfigHub (not directly to cluster)
- Actuator cluster needs connectivity to ConfigHub
- Direct `kubectl apply` from CI is prohibited for ConfigHub-managed resources
- Break-glass procedures must reconcile back to ConfigHub after emergency changes
