# ADR-014: ConfigHub Stores Expanded Resources via Composition Render Pipeline

## Status
Accepted (supersedes ADR-010)

## Context

ADR-010 decided ConfigHub would store Claims (developer intent), not expanded resources. This was the right call at the time — Claims are simpler, smaller, and closer to what developers author.

However, for ConfigHub's core value proposition of "unambiguous, fully-rendered configuration," we need the expanded view. Operators and auditors need to see exactly what AWS resources exist, not just the abstract intent. Key gaps with claim-only storage:

- **No resource-level visibility**: Can't answer "what IAM policies exist in prod-east?" without running the Composition
- **No resource-level rollback**: Rolling back a claim rolls back everything; can't revert a single resource
- **No resource-level policy**: Can't enforce "no Lambda above 3GB" at the ConfigHub layer
- **Opaque diffs**: Changing `lambdaMemory: 256` in the claim doesn't show which Lambda resources change

The Crossplane Composition is already a deterministic transform — given the same inputs, it always produces the same outputs. This makes it safe to run at build time.

## Decision

ConfigHub stores the fully expanded Crossplane managed resources (19 per environment), produced by running `crossplane render` at build time in CI.

The pipeline:

```
Developer authors Claim (Git, Kustomize overlays)
    → CI: kustomize build → Claim YAML
    → CI: Convert Claim → XR (kind change for crossplane CLI)
    → CI: crossplane render → 19 managed resource YAMLs
    → CI: Validate expanded resources (policy checks)
    → CI: Publish each resource as a ConfigHub unit
    → ArgoCD CMP fetches units from ConfigHub (unchanged)
    → Crossplane reconciles individual managed resources → AWS
```

The Composition becomes a **build-time transform**. Crossplane in the cluster acts as a **pure reconciler** — it receives individual managed resources and ensures AWS matches.

## Consequences

### Positive
- Full resource-level visibility in ConfigHub (19 queryable units per env)
- Resource-level rollback, diff, and policy enforcement
- No runtime Composition expansion needed — simpler cluster behavior
- ConfigHub becomes the true "what should be deployed" authority
- Enables resource-level approval gates (e.g., IAM changes require security review)

### Negative
- CI pipeline is more complex (needs crossplane CLI, Docker for function rendering)
- 19 units per environment instead of 1 (more ConfigHub storage, but trivial)
- Composition changes require re-rendering all environments
- Build-time rendering means the Composition must be kept in sync with the XRD

### Migration
- Old `envsubst`-based template pipeline (`infra/base/*.yaml.template`, `config/*.env`) is deprecated
- Old publish scripts (`publish-messagewall.sh`, `publish-claims.sh`) are deprecated
- GitHub Actions workflow updated to use `scripts/render-composition.sh`

## Related
- ADR-010: Original decision (now superseded)
- ADR-011: Bidirectional GitOps (conflict detection preserved, now per-resource)
- ADR-012: Developer Authoring Surface (Claims remain the authoring surface)
