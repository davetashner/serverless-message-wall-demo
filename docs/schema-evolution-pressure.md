# Schema Evolution Pressure from Intelligent Agents

**Status**: Analysis document for ISSUE-15.15
**Related**: [ServerlessEventApp Schema](serverless-event-app-schema.md)

---

## The Tension

Schema-first design provides safety through constraint. Intelligent agents create pressure to express novel configurations and find workarounds.

**The question**: How do we evolve schemas to serve agent capabilities without losing safety?

---

## Schema Growth Risks

| Risk | Pattern | Consequences |
|------|---------|--------------|
| **Sprawl** | Schema grows for every agent request | Hard to understand, defaults impossible, testing explosion |
| **Escape Hatch Abuse** | Agents use annotations to bypass constraints | Bypasses policy, breaks Composition, shadow config |
| **Version Fragmentation** | Multiple versions with breaking changes | Migration burden, version-aware tooling |
| **Field Overloading** | Fields repurposed for unintended uses | Validation ineffective, meaning lost |
| **Drift via Annotations** | Annotations diverge from schema | Unclear authority |

---

## Extension Strategies

| Strategy | Approach | Trade-off |
|----------|----------|-----------|
| **Blessed Extension Points** | Explicit `extensions:` block with validation | More upfront complexity, controlled growth |
| **Feature Flags** | `features:` enables optional fields | Conditional validation, easy deprecation |
| **Layered Configuration** | Separate Claim (dev) + PlatformOverlay (ops) | More objects, clean separation |
| **Composition Defaults** | Composition decides; annotations for overrides | Minimal schema, opaque overrides |

---

## Escape Hatch Design

Controlled escape hatch for capabilities not in schema:

**Requirements**:
1. Logged and auditable
2. Requires approval (HIGH risk)
3. Expires (forces promotion or removal)
4. Still validated
5. Repeated use triggers schema review

```yaml
experimental:
  enabled: true
  approvedBy: alice@example.com
  expiresAt: "2026-04-18"
  features: [{ name: vpc-networking, config: {...}, justification: "..." }]
```

---

## Promoting Extensions

| Criterion | Threshold |
|-----------|-----------|
| Usage | > 30% of Claims |
| Stability | Unchanged 3+ months |
| Composition | Complete and tested |
| Documentation | Fully documented |

**Process**: Proposal → Review → Beta → Migration → Stable → Deprecate escape hatch

---

## Guidelines

**Do**: Start minimal, semantic names, provide defaults, version explicitly, validate early.

**Don't**: AWS-specific fields, internal details, admin overrides, break compatibility.

**Red flags**: Arbitrary annotations → add extension point. Same escape hatch 5+ times → promote to schema.

---

## Agent-Schema Interaction

- **Agents**: Respect constraints, use escape hatch properly, report gaps
- **Platform**: Review feedback, evolve intentionally, deprecate gracefully

**Feedback loop**: Agent uses escape hatch → Platform tracks usage → High usage triggers schema review → Promote to core

---

## Summary

**Key principles**:
1. Schema is constraint system, not feature dump
2. Extensions are first-class, not workarounds
3. Escape hatches are temporary bridges
4. Agent feedback drives evolution; platform decides

---

## References

- [ADR-010](decisions/010-confighub-claim-vs-expanded.md), [risk-taxonomy.md](risk-taxonomy.md)
- EPIC-16 — Schema decisions
