# ADR-011: Bidirectional GitOps with ConfigHub as Authority

## Status
Accepted

## Implementation

The three-phase sync model is implemented via:

- **Phase 1**: `scripts/sync-confighub-to-git.sh` and `.github/workflows/confighub-sync-to-git.yml`
- **Phase 2**: Updated `.github/workflows/confighub-publish.yml` with conflict detection
- **Phase 3**: `scripts/capture-drift-to-confighub.sh`

See [docs/bidirectional-sync.md](../bidirectional-sync.md) for operational documentation

## Context

### The Traditional GitOps Model

Traditional GitOps treats Git as the single source of truth:

```
Git (source of truth) → GitOps Operator → Live State
```

The operator continuously reconciles live state to match Git. Any drift is "corrected" by reverting to Git's version.

### The Problem with Unidirectional GitOps

Brian Grant (ConfigHub co-founder, original Kubernetes architect) describes a critical failure mode:

> "To address a production outage, I needed to deploy a fix quickly. The normal process took too long, so I deployed a new release another way, and it fixed the problem. Seconds later, the previous release was redeployed by a reconciliation loop, taking the service down again."

**Traditional GitOps fights you when you need to make operational changes.** The automation becomes an obstacle rather than a help.

Other problems with Git-as-authority:
- **Bulk changes are hard**: Changing a value across 50 services requires editing 50 files
- **Break-glass is dangerous**: Emergency changes get reverted
- **CI overwrites operator intent**: A subsequent deploy erases operational adjustments
- **Slow feedback loop**: Must commit, push, wait for pipeline, wait for sync

### The Question We're Really Asking

Our original framing was: "How do we prevent CI from overwriting ConfigHub changes?"

**The real question is**: How do we implement bidirectional sync where ConfigHub is authoritative, Git remains a useful authoring surface, and changes flow in all directions without conflict?

### Bidirectional GitOps

Brian Grant argues that GitOps should shed its dependency on Git as the source of truth:

> "The key insight of GitOps was the continuous reconciliation of a specific declarative configuration from its source of truth... the GitOps principles don't say that git is a required component of GitOps, or that drift always has to be clobbered when discovered."

**Bidirectional GitOps** means:
- Changes can flow from configuration store → live state (apply)
- Changes can flow from live state → configuration store (capture)
- Git becomes an *authoring surface*, not the authority

## Decision

### The Three-Way Sync Model

Adopt a bidirectional GitOps architecture with ConfigHub as the authoritative hub:

```
                    Git
                (authoring)
                   ↓  ↑
                   │  │ sync
                   ↓  ↑
    ┌─────────────────────────────────┐
    │     ConfigHub (authority)       │
    │  • Stores resolved Claims       │
    │  • Tracks all revisions         │
    │  • Enables bulk changes         │
    │  • Enforces policies            │
    └─────────────────────────────────┘
                   ↓  ↑
             apply │  │ drift capture
                   ↓  ↑
              Live State
         (Kubernetes → AWS)
```

### Sync Directions

| Direction | Trigger | What Happens |
|-----------|---------|--------------|
| **Git → ConfigHub** | Developer merges PR | CI renders Claim, publishes to ConfigHub as *proposal* or directly (depending on policy) |
| **ConfigHub → Live** | Operator applies revision | Worker/ArgoCD syncs Claim to Kubernetes, Crossplane provisions AWS |
| **Live → ConfigHub** | Drift detected or break-glass | Changes captured back to ConfigHub, creating new revision |
| **ConfigHub → Git** | Operator approves sync-back | Automation creates PR to update Git with ConfigHub state |

### Key Principles

1. **ConfigHub is authoritative**: The configuration in ConfigHub is what *should* be running. Not Git. Not the live state.

2. **Git is for authoring, not authority**: Developers write Claims in Git. CI proposes them to ConfigHub. But Git doesn't override ConfigHub—it feeds into it.

3. **Live state informs, doesn't dictate**: Drift detection captures what's actually running, but ConfigHub decides whether to accept or revert it.

4. **Bidirectional sync prevents conflicts**: Instead of CI blindly overwriting ConfigHub, changes flow both ways and conflicts are surfaced for resolution.

### Implementation Approach

#### Phase 1: ConfigHub → Git Sync (Visibility)

When an operator makes a change in ConfigHub (bulk change, policy adjustment, break-glass), automation creates a PR to sync that change back to Git.

```
Operator changes ConfigHub (e.g., lambdaMemory: 256 across prod)
        │
        ▼
ConfigHub webhook triggers automation
        │
        ▼
Automation creates PR: "Sync: Update lambdaMemory to 256 in prod Claims"
        │
        ▼
Developer reviews and merges
        │
        ▼
Git now matches ConfigHub
```

**Benefits**:
- Git stays informed of all changes
- Full history in Git for compliance/audit
- Developers see what operators changed
- Next CI run won't have stale data

#### Phase 2: Git → ConfigHub as Proposal

CI doesn't directly update ConfigHub. Instead, it creates a *proposal* that can be reviewed before becoming the new Head revision.

```
Developer merges to main
        │
        ▼
CI renders Claim, creates ConfigHub proposal
        │
        ▼
If ConfigHub Head differs from proposal:
  → Surface as "pending review" (operator must resolve)
If ConfigHub Head matches expected:
  → Auto-promote proposal to Head
        │
        ▼
Operator reviews conflicts, chooses resolution
```

**Benefits**:
- CI can't silently overwrite operator changes
- Conflicts are explicit, not silent
- Operators retain control

#### Phase 3: Live → ConfigHub Capture

When drift is detected (or after break-glass), capture the live state back to ConfigHub.

```
Emergency: Operator changes AWS directly
        │
        ▼
Crossplane detects drift (or operator triggers capture)
        │
        ▼
Drift captured as new ConfigHub revision
  → Tagged as "break-glass" or "drift-capture"
        │
        ▼
ConfigHub → Git sync creates PR
        │
        ▼
Full audit trail preserved
```

**Benefits**:
- Break-glass doesn't fight automation
- Changes are captured, not lost
- Reconciliation happens through ConfigHub, not against it

### Conflict Resolution

When Git and ConfigHub diverge, the conflict is surfaced rather than silently resolved:

| Scenario | Resolution |
|----------|------------|
| Git has change, ConfigHub unchanged | Auto-apply Git change to ConfigHub |
| ConfigHub has change, Git unchanged | Sync ConfigHub to Git (PR) |
| Both changed (conflict) | Surface for human resolution; operator chooses winner or merges |

## Rationale

### Why Not Keep Git as Authority?

Git-as-authority has fundamental limitations:
- **Poor queryability**: Can't ask "which services have memory < 256?"
- **No bulk mutation**: Must edit files one by one
- **Slow operational changes**: Commit → PR → merge → CI → deploy
- **Fights operational intent**: Reverts break-glass changes

### Why ConfigHub as Authority?

ConfigHub provides what Git cannot:
- **Queryable configuration**: Find resources by any attribute
- **Bulk mutation**: Change many resources with one command
- **Instant operational changes**: Apply immediately, sync to Git later
- **Revision history**: Every change tracked with attribution
- **Policy enforcement**: Validate before apply

### Why Keep Git at All?

Git remains valuable for:
- **Authoring experience**: IDEs, code review, PRs
- **Template/rendering pipelines**: Generate Claims from higher-level specs
- **Compliance**: Immutable audit log of authored intent
- **Collaboration**: PR-based review workflow

Git becomes a *tributary* feeding into ConfigHub, not the ocean itself.

## Consequences

1. **Authority shifts to ConfigHub**: This is explicit and intentional. ConfigHub is the source of truth for what *should* be running.

2. **Git role changes**: Git is for authoring and audit, not authority. This may require updating team mental models.

3. **Bidirectional sync infrastructure needed**: Webhooks, automation, PR creation for ConfigHub → Git sync.

4. **Conflict resolution process needed**: When Git and ConfigHub diverge, someone must resolve. This is better than silent overwrites.

5. **Break-glass becomes safe**: Operators can make emergency changes knowing they'll be captured, not reverted.

6. **Bulk changes are first-class**: Operators can update configuration across environments instantly, then sync to Git.

## Open Questions

1. **Does ConfigHub support proposals today?** If not, Phase 2 may require feature development or workarounds.

2. **What triggers ConfigHub → Git sync?** Webhook on revision change? Manual trigger? Scheduled job?

3. **How are conflicts presented?** Dashboard? PR comments? Slack notification?

4. **What's the Git PR format?** Should sync PRs be auto-merged or require review?

## References

- [What is Bidirectional GitOps? - Brian Grant](https://itnext.io/what-is-bidirectional-gitops-ce0ced75fa1c)
- [Realizing the potential of GitOps - Brian Grant](https://itnext.io/realizing-the-potential-of-gitops-263051baff04)
- [ADR-005: ConfigHub Integration Architecture](./005-confighub-integration-architecture.md)
- [ADR-010: ConfigHub Stores Claims, Not Expanded Resources](./010-confighub-claim-vs-expanded.md)
- [docs/planes.md](../planes.md) - Authority plane definition
