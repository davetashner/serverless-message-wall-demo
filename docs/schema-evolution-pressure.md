# Schema Evolution Pressure from Intelligent Agents

This document analyzes how increasingly capable AI agents may stress or bypass schema-first design, and proposes strategies for managing schema evolution in an agent-heavy environment.

**Status**: Analysis document for ISSUE-15.15
**Related**: [ServerlessEventApp Schema](serverless-event-app-schema.md)

---

## The Tension

Schema-first design provides safety through constraint:
- Only valid configurations can be expressed
- Platform controls what's possible
- Changes go through defined channels

Intelligent agents create pressure in the opposite direction:
- Agents discover optimizations not in the schema
- Agents want to express novel configurations
- Agents find workarounds when constrained

**The question**: How do we evolve schemas to serve agent capabilities without losing the safety benefits of constraints?

---

## Schema Growth Risks

### Risk 1: Schema Sprawl

**Pattern**: Schema grows to accommodate every agent request.

**Example**:
```yaml
# Version 1: Clean, minimal
spec:
  lambdaMemory: 256
  lambdaTimeout: 30

# Version 47: After agents requested features
spec:
  lambdaMemory: 256
  lambdaTimeout: 30
  lambdaConcurrency: 100
  lambdaVpcConfig:
    subnetIds: [...]
    securityGroupIds: [...]
  lambdaTracing:
    mode: Active
  lambdaEnvironment:
    variables:
      KEY1: value1
      KEY2: value2
  lambdaLayers: [...]
  lambdaProvisioned: true
  lambdaProvisionedConcurrency: 50
  lambdaDeadLetterConfig:
    targetArn: ...
  lambdaSnapStart: true
  lambdaEphemeralStorage: 1024
  # ... 30 more fields
```

**Consequences**:
- Schema becomes hard to understand
- Defaults become impossible to get right
- Composition complexity explodes
- Testing combinatorial explosion

---

### Risk 2: Escape Hatch Abuse

**Pattern**: Agents use generic extension fields to bypass schema constraints.

**Example**:
```yaml
spec:
  lambdaMemory: 256
  # Agent can't set VPC config in schema, so uses annotations
  annotations:
    platform.messagewall.demo/lambda-vpc-subnet-1: subnet-abc123
    platform.messagewall.demo/lambda-vpc-subnet-2: subnet-def456
    platform.messagewall.demo/lambda-security-group: sg-xyz789
```

**Consequences**:
- Bypasses policy enforcement
- Breaks Composition assumptions
- Creates shadow configuration
- Makes auditing impossible

---

### Risk 3: Version Fragmentation

**Pattern**: Multiple schema versions with breaking changes.

**Example**:
```yaml
# Some Claims use v1alpha1
apiVersion: messagewall.demo/v1alpha1
kind: ServerlessEventAppClaim

# Others use v1beta1 with different field names
apiVersion: messagewall.demo/v1beta1
kind: ServerlessEventAppClaim
spec:
  compute:
    memory: 256  # Was lambdaMemory
    timeout: 30  # Was lambdaTimeout
```

**Consequences**:
- Tooling must support all versions
- Agents must detect version and adapt
- Migration burden accumulates
- Bulk changes become version-aware

---

### Risk 4: Field Overloading

**Pattern**: Existing fields are repurposed for unintended uses.

**Example**:
```yaml
spec:
  # Agent encodes VPC info in resourcePrefix (not intended use)
  resourcePrefix: messagewall-vpc-subnet-abc123-sg-xyz789
```

**Consequences**:
- Validation becomes ineffective
- Semantic meaning is lost
- Debugging becomes archaeology

---

### Risk 5: Configuration Drift via Annotations

**Pattern**: Authoritative configuration diverges from schema.

**Example**:
```yaml
metadata:
  annotations:
    # Agent stores computed recommendations here
    agent.messagewall.demo/recommended-memory: "512"
    agent.messagewall.demo/last-analyzed: "2026-01-18"
    agent.messagewall.demo/optimization-score: "0.87"
spec:
  lambdaMemory: 256  # Actual config differs from recommendation
```

**Problem**: Which is authoritative? Schema values or annotations?

---

## Extension Strategies

### Strategy 1: Blessed Extension Points

Define explicit extension points that are safe to use and well-understood by the platform.

```yaml
spec:
  lambdaMemory: 256
  lambdaTimeout: 30

  # Blessed extension point with validation
  extensions:
    performance:
      provisionedConcurrency: 50
    networking:
      vpcEnabled: true
      vpcId: vpc-abc123
```

**Properties**:
- Extension points are named and documented
- Extensions have their own schema (validation applies)
- Composition knows how to handle extensions
- Can be promoted to core schema later

**Trade-off**: More complexity upfront, but controlled growth.

---

### Strategy 2: Feature Flags

Expose optional capabilities via feature flags that enable additional fields.

```yaml
spec:
  lambdaMemory: 256

  # Feature flags unlock additional fields
  features:
    vpcNetworking: true   # Enables spec.vpc.*
    provisionedConcurrency: true  # Enables spec.concurrency.*

  # Only valid if features.vpcNetworking = true
  vpc:
    subnetIds: [subnet-abc]
    securityGroupIds: [sg-xyz]
```

**Properties**:
- Core schema stays minimal
- Features are opt-in and explicit
- Validation is conditional on feature flags
- Easy to deprecate features

**Trade-off**: More conditionals in validation and Composition.

---

### Strategy 3: Layered Configuration

Separate concerns into layers, each with its own lifecycle.

```yaml
# Layer 1: Application Intent (developer owns)
apiVersion: messagewall.demo/v1alpha1
kind: ServerlessEventAppClaim
spec:
  environment: prod
  lambdaMemory: 256

---
# Layer 2: Platform Overlay (platform team owns)
apiVersion: messagewall.demo/v1alpha1
kind: PlatformOverlay
metadata:
  name: messagewall-prod-platform
spec:
  targetClaim: messagewall-prod
  overrides:
    vpc:
      enabled: true
      subnetIds: [subnet-abc]
    logging:
      level: INFO
      destination: cloudwatch
```

**Properties**:
- Developers can't accidentally set platform concerns
- Platform team controls infrastructure details
- Clean separation of authority
- Each layer has appropriate schema

**Trade-off**: More objects to manage. Composition must merge layers.

---

### Strategy 4: Composition-Time Defaults with Override

Let the Composition provide intelligent defaults, with schema fields for overrides.

```yaml
# Schema exposes minimal fields
spec:
  lambdaMemory: 256
  # vpc: (not in schema - Composition decides)

# Composition logic:
# - If environment=prod, enable VPC with default config
# - If environment=dev, no VPC (simpler, cheaper)
```

To override Composition behavior, use annotations (with policy approval):

```yaml
metadata:
  annotations:
    platform.messagewall.demo/override-vpc: "enabled"
    platform.messagewall.demo/override-approved-by: "alice@example.com"
    platform.messagewall.demo/override-approved-at: "2026-01-18"
```

**Properties**:
- Schema stays minimal
- Intelligent defaults from Composition
- Overrides are visible and auditable
- Policy can control who can override

**Trade-off**: Overrides become opaque. Must rely on Composition documentation.

---

## Escape Hatch Design

When agents need capabilities not in the schema, provide a controlled escape hatch.

### Escape Hatch Requirements

1. **Visibility**: Escape hatch usage is logged and auditable
2. **Approval**: Escape hatch requires approval (HIGH risk by default)
3. **Expiration**: Escape hatch configurations expire, forcing schema promotion or removal
4. **Validation**: Escape hatch values still validated against constraints
5. **Prohibition on abuse**: Repeated escape hatch use for same purpose triggers schema review

### Escape Hatch Schema

```yaml
spec:
  lambdaMemory: 256

  # Controlled escape hatch
  experimental:
    enabled: true
    approvedBy: alice@example.com
    expiresAt: "2026-04-18"
    features:
      - name: vpc-networking
        config:
          subnetIds: [subnet-abc]
          securityGroupIds: [sg-xyz]
        justification: "PCI compliance requires VPC isolation"
```

### Escape Hatch Policies

```rego
# Escape hatch requires approval
deny[msg] {
    input.spec.experimental.enabled == true
    not input.spec.experimental.approvedBy
    msg := "Experimental features require approvedBy field"
}

# Escape hatch must have expiration
deny[msg] {
    input.spec.experimental.enabled == true
    not input.spec.experimental.expiresAt
    msg := "Experimental features require expiresAt field"
}

# Escape hatch expiration is enforced
deny[msg] {
    input.spec.experimental.enabled == true
    expires := time.parse_rfc3339_ns(input.spec.experimental.expiresAt)
    now := time.now_ns()
    expires < now
    msg := "Experimental features have expired"
}
```

---

## Promoting Extensions to Core Schema

When an extension is widely used and stable, it should be promoted to the core schema.

### Promotion Criteria

| Criterion | Threshold |
|-----------|-----------|
| Usage | > 30% of Claims use this extension |
| Stability | Extension unchanged for > 3 months |
| Feedback | No major issues reported |
| Composition | Composition support is complete and tested |
| Documentation | Extension is fully documented |
| Policy | Policies exist for the extension |

### Promotion Process

1. **Proposal**: Write schema extension proposal with rationale
2. **Review**: Platform team reviews for consistency and safety
3. **Beta**: Add to schema as beta field (may change)
4. **Migration**: Update existing Claims using escape hatch
5. **Stable**: Promote to stable after validation period
6. **Cleanup**: Deprecate escape hatch usage for this feature

### Example: Promoting VPC Networking

```
1. Many Claims use experimental.features.vpc-networking
2. Platform team proposes adding spec.vpc to schema
3. Schema updated:
   spec:
     vpc:
       enabled: false  # default
       subnetIds: []
       securityGroupIds: []
4. Migration tool updates Claims:
   - Move experimental.features.vpc-networking to spec.vpc
   - Remove experimental block if empty
5. After 90 days, deprecation warning for experimental vpc usage
6. After 180 days, reject experimental vpc usage
```

---

## Guidelines for Schema Evolution

### Do

- **Start minimal**: Add fields only when needed, not speculatively
- **Use semantic names**: `lambdaMemory` not `mem` or `lambda_memory_mb`
- **Provide defaults**: Every optional field has a sensible default
- **Version explicitly**: Use apiVersion for breaking changes
- **Document everything**: Every field has description and examples
- **Validate early**: Reject invalid values at schema level, not in Composition

### Don't

- **Don't add AWS-specific fields**: Keep schema cloud-agnostic at intent level
- **Don't expose internal details**: IDs, ARNs, provider-specific names
- **Don't add "admin" overrides**: Every field should have proper validation
- **Don't break backwards compatibility**: Additive changes only for stable fields
- **Don't duplicate information**: One source of truth for each concept

### Red Flags

| Pattern | What to do instead |
|---------|-------------------|
| Agent requests arbitrary annotations | Add blessed extension point |
| Same escape hatch used by > 5 Claims | Promote to schema |
| Field with > 10 possible values | Consider sub-schema or enum |
| Field that requires AWS knowledge | Abstract to intent-level concept |
| Field that 90% of users don't understand | Make it a Composition default |

---

## Agent-Schema Interaction Model

How should agents interact with schema evolution?

### Agent Responsibilities

1. **Respect schema constraints**: Don't attempt workarounds
2. **Use escape hatch properly**: With justification and expiration
3. **Report schema gaps**: Flag when schema is insufficient for task
4. **Propose extensions**: Submit structured extension requests

### Platform Responsibilities

1. **Review agent feedback**: Track common schema gap reports
2. **Evolve schema intentionally**: Based on real needs, not speculation
3. **Maintain escape hatch**: Ensure it's available but controlled
4. **Deprecate gracefully**: Give agents time to adapt to changes

### Feedback Loop

```
Agent encounters schema limitation
        │
        ▼
Agent uses escape hatch (with approval)
        │
        ▼
Platform tracks escape hatch usage
        │
        ├── Usage < threshold → Continue monitoring
        │
        └── Usage > threshold → Trigger schema review
                                      │
                                      ▼
                              Promote to core schema
                                      │
                                      ▼
                              Update agents and Claims
```

---

## Summary

| Risk | Mitigation |
|------|------------|
| Schema sprawl | Minimal core + blessed extensions |
| Escape hatch abuse | Approval + expiration + audit |
| Version fragmentation | Additive changes only, clear deprecation |
| Field overloading | Strong validation, semantic naming |
| Configuration drift | Single source of truth, extension points |

**Key principles**:
1. Schema is a constraint system, not a feature dump
2. Extensions are first-class citizens, not workarounds
3. Escape hatches are temporary bridges, not permanent fixtures
4. Agent feedback drives evolution, but platform decides

---

## References

- [ServerlessEventApp Schema Reference](serverless-event-app-schema.md)
- [ADR-010: ConfigHub Stores Claims](decisions/010-confighub-claim-vs-expanded.md)
- [Risk Taxonomy](risk-taxonomy.md) — Extension changes and risk
- EPIC-16: Developer Authoring Experience — Schema decisions
