# ConfigHub Value in Non-Production Environments

**Status**: Design document for ISSUE-18.5
**Related**: [Tiered Authority Model](tiered-authority-model.md), [Centralized Authority Limits](centralized-authority-limits.md)

---

## The Question

If sandbox environments have no gates and no approval requirements, why use ConfigHub at all?

**Answer**: ConfigHub provides value beyond enforcement. Even without gates, it offers visibility, history, coordination, and tooling that make non-prod work easier.

---

## Value Proposition by Tier

### Production Value: Protection

In production, ConfigHub's value is **preventing bad things**:
- Gates block destructive actions
- Approval workflows catch mistakes
- Policies enforce compliance

### Non-Prod Value: Enablement

In sandbox/pre-prod, ConfigHub's value is **enabling good things**:
- Visibility into what exists
- History of what changed
- Coordination across experiments
- Tooling for bulk operations

---

## Benefits Beyond Enforcement

### 1. Visibility

**Problem without ConfigHub**: "What experiments are running right now?"

```bash
# Without ConfigHub: cobble together from multiple sources
kubectl get serverlesseventapps -A
aws lambda list-functions --query 'Functions[?starts_with(FunctionName, `sandbox`)]'
# Hope you didn't miss anything

# With ConfigHub: single query
cub unit list --space messagewall-sandbox
```

**Value**: One place to see all configuration, regardless of where resources live.

---

### 2. History and Diff

**Problem without ConfigHub**: "What changed between yesterday and today?"

```bash
# Without ConfigHub: hope you have good git discipline
git log --since="1 day ago" -- 'infra/**'
# Doesn't capture direct applies or agent changes

# With ConfigHub: built-in history
cub revision list --space messagewall-sandbox --since 24h
cub revision diff 41 42 --space messagewall-sandbox
```

**Value**: Every change recorded, even experiments that never touched git.

---

### 3. Bulk Operations

**Problem without ConfigHub**: "Update memory on all 15 test Lambdas"

```bash
# Without ConfigHub: write a script, hope it works
for f in $(kubectl get serverlesseventapps -o name); do
  kubectl patch $f --type=merge -p '{"spec":{"memory":"512Mi"}}'
done
# No rollback, no preview, no audit

# With ConfigHub: atomic bulk update
cub bulk update --space messagewall-sandbox \
  --filter 'spec.runtime == "python3.11"' \
  --set spec.memory=512Mi \
  --dry-run  # Preview first
```

**Value**: Safe bulk operations with preview, audit, and rollback.

---

### 4. Promotion Path

**Problem without ConfigHub**: "This experiment worked, now deploy to prod"

```bash
# Without ConfigHub: manual copy-paste, hope you got everything
cp sandbox/my-experiment.yaml prod/
# Edit file, remove sandbox-specific values
# Remember to update all the references
# Hope you didn't miss anything

# With ConfigHub: structured promotion
cub unit promote sandbox-exp-42 \
  --to-space messagewall-prod \
  --validate  # Runs prod policies before promotion
```

**Value**: Clean path from experiment to production with validation.

---

### 5. Coordination

**Problem without ConfigHub**: "Is anyone else using this test database?"

```bash
# Without ConfigHub: Slack message, hope someone responds
# "Hey team, I'm about to delete sandbox-db-1, anyone using it?"

# With ConfigHub: explicit ownership and queries
cub unit show sandbox-db-1 --space messagewall-sandbox
# owner: agent:alice-session-123
# last-touched: 2 hours ago
# dependents: [sandbox-api-1, sandbox-worker-1]
```

**Value**: Know who owns what and what depends on what.

---

### 6. Cost Attribution

**Problem without ConfigHub**: "Why is our sandbox AWS bill so high?"

```bash
# Without ConfigHub: parse AWS Cost Explorer, guess at attribution
# "Looks like someone left 50 Lambdas running..."

# With ConfigHub: query by owner
cub unit list --space messagewall-sandbox --group-by owner
# agent:bob-session-456: 23 units ($47/day estimated)
# agent:ci-pipeline: 12 units ($18/day estimated)
# agent:alice-session-123: 8 units ($12/day estimated)
```

**Value**: Know who's spending what, even in sandbox.

---

## Sandbox vs Production: Value Comparison

| Capability | Production Value | Sandbox Value |
|------------|------------------|---------------|
| **Gates** | Prevent mistakes | Not needed |
| **Approval** | Catch errors | Not needed |
| **Policy** | Enforce compliance | Warn only |
| **History** | Audit trail | Debug experiments |
| **Visibility** | Know what's deployed | Know what exists |
| **Bulk ops** | Controlled rollouts | Fast iteration |
| **Promotion** | Staged deployment | Path to prod |
| **Coordination** | Change management | Avoid conflicts |

**Key insight**: The same features serve different purposes at different tiers.

---

## When to Skip ConfigHub in Sandbox

ConfigHub is optional in sandbox. Skip it when:

| Scenario | Why Skip |
|----------|----------|
| Local-only experiments | No benefit to central registration |
| Sub-hour lifetime | Expires before registration is useful |
| Throwaway CI resources | Automated cleanup handles it |
| Learning/exploration | Overhead exceeds benefit |

See [ConfigHub Bypass Criteria](confighub-bypass-criteria.md) for details.

---

## Recommended Posture

| Tier | ConfigHub Usage | Rationale |
|------|-----------------|-----------|
| **Sandbox** | Optional | Use for visibility/history if helpful |
| **Pre-prod** | Required | Integration tests need coordination |
| **Staging** | Required | Release validation needs audit |
| **Production** | Required | Protection is mandatory |

### Making Optional Easy

For sandbox, ConfigHub should be low-friction:

```bash
# One-line registration
cub unit create --from-file my-experiment.yaml --space messagewall-sandbox --ttl 24h

# Auto-registration via label
kubectl apply -f my-experiment.yaml
# Label: confighub.io/register: "true" triggers automatic sync
```

If registration is hard, people won't do it. Make it trivial.

---

## Summary

ConfigHub value in non-prod:

| Value | How It Helps |
|-------|--------------|
| **Visibility** | See all experiments in one place |
| **History** | Track changes without git discipline |
| **Bulk ops** | Update many configs safely |
| **Promotion** | Clean path to production |
| **Coordination** | Know who owns what |
| **Cost** | Attribute spend to owners |

**Bottom line**: Use ConfigHub in sandbox because it makes your life easier, not because it's required.

---

## References

- [Tiered Authority Model](tiered-authority-model.md) — tier definitions
- [Centralized Authority Limits](centralized-authority-limits.md) — when centralization fails
- [ConfigHub Bypass Criteria](confighub-bypass-criteria.md) — when to skip ConfigHub
- [Agent Sandbox Freedoms](agent-sandbox-freedoms.md) — agent autonomy in non-prod
