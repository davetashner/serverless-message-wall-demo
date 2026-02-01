# Proposal: WET Authoring Pathway

**Status:** Draft
**Author:** Claude
**Date:** 2026-01-31

## Background: Brian Grant's Configuration as Data Vision

This proposal is informed by Brian Grant's [Configuration as Data](https://github.com/bgrant0607/config-data) analysis, which argues:

1. **The 200% Knowledge Problem**: Abstraction layers (Helm charts, Terraform modules, Crossplane Compositions) force users to understand BOTH the output format AND the abstraction mechanism. This doubles cognitive load rather than reducing it.

2. **Abstraction is the Wrong Solution**: Configuration complexity is a **UX problem**, not a software engineering problem. Encapsulation (hiding things behind interfaces) creates the 200% problem. The solution is **progressive disclosure** (good UX for explicit configuration), not more abstraction.

3. **WET (Write Every Time)**: Configuration should be explicit data that tools can read AND write. No runtime rendering, no template magic. What you see is what gets deployed.

4. **Output Constraints, Not Input Restrictions**: Instead of restricting what goes into templates (abstraction parameters), validate the actual output (admission control, policy engines). This enables flexibility while maintaining guardrails.

5. **Multiple Tool Authorship**: Configuration is a shared substrate. Developers, security scanners, cost optimizers, AI assistants, and operational automation all legitimately write configuration. The one-author model is a bottleneck.

---

## Problem Statement

The current demo uses Crossplane XRD + Composition—a runtime abstraction layer:

```
Developer → Claim (8 fields) → [Composition] → 17 ManagedResources → AWS
                                  (runtime magic)
```

**This embodies the anti-patterns CaD identifies:**

| Anti-Pattern | How Current Demo Exhibits It |
|--------------|------------------------------|
| 200% knowledge problem | Developer must understand Claim schema AND reverse-engineer Composition behavior |
| Runtime rendering | Composition transforms Claim to resources at apply time—opaque transformation |
| Single author | Only the Claim interface can modify resources; other tools cannot |
| Abstraction bloat | Composition is 775 lines of patch/transform logic |
| Input restrictions | Claim schema limits what can be expressed; no access to underlying fields |

**The CaD question:** Can we give developers a simple starting experience while storing **explicit, tool-writable** configuration that any authorized system can modify?

---

## Proposed Solution: Progressive Disclosure, Not Abstraction

The key insight from CaD: **don't hide the configuration—make it navigable**.

```
Developer → Tool (progressive disclosure) → Explicit Resources → ConfigHub → Crossplane → AWS
                     (UX)                      (data)            (multi-writer)   (actuator)
```

### What Changes

| Current (Abstraction) | Proposed (Progressive Disclosure) |
|-----------------------|-----------------------------------|
| Claim hides 17 resources | All 17 resources explicit in ConfigHub |
| Developer cannot see/modify individual resources | Developer CAN see everything, but doesn't HAVE to |
| Other tools cannot modify (Claim is the interface) | Any tool can modify any resource |
| Runtime Composition (opaque transform) | Authoring-time tool (generates explicit YAML) |

### Key Principles

1. **Explicit over implicit** - All 17 resources stored as-is in ConfigHub
2. **Progressive disclosure** - Simple CLI shows 8 common fields; `--advanced` shows everything
3. **Tool-writable** - Security/FinOps/SRE can modify any resource field directly
4. **Output constraints** - Kyverno policies validate resources, not Claim parameters
5. **No 200% problem** - Learn Kubernetes resources, not Kubernetes + Composition

---

## Tool Design: `mw` CLI with Progressive Disclosure

The tool embodies **progressive disclosure UX**—start simple, expand when needed.

### Level 1: Quick Start (2 fields)

```bash
# Absolute minimum - just env and account
mw create --env dev --account 205074708100

# Generates 17 explicit resources with sensible defaults
# Output: manifests/messagewall-dev.yaml (1200 lines, but you don't need to read it)
```

**What you typed:** 2 required fields
**What you get:** Complete, working infrastructure

### Level 2: Common Customization (5-8 fields)

```bash
# Adjust memory, timeout, region
mw create --env dev --account 205074708100 \
  --region us-west-2 \
  --memory 256 \
  --timeout 30
```

**Progressive disclosure:** Show common fields without overwhelming.

### Level 3: Full Control (any field)

```bash
# Edit specific resource after generation
mw edit api-handler --set spec.forProvider.memorySize=512

# Or use ConfigHub directly
cub unit get --space messagewall-dev-east api-handler --data-only | \
  yq '.spec.forProvider.memorySize = 512' | \
  cub unit update --space messagewall-dev-east api-handler -
```

**The key difference from abstraction:** You're editing the ACTUAL resource, not reverse-engineering what abstraction parameter produces that output.

### Interactive Mode with Explanation

```bash
$ mw create --interactive

Welcome to Messagewall Infrastructure Generator

This tool creates 17 AWS resources for a serverless message wall.
You can customize common settings now, or edit individual resources later.

Required:
  Environment (dev/staging/prod): dev
  AWS Account ID: 205074708100

Common Options (press Enter for defaults):
  Region [us-east-1]:
  Lambda Memory (128-10240 MB) [128]: 256
  Lambda Timeout (1-900 sec) [10]:

Generated 17 resources. Preview:
  - Bucket: messagewall-dev-205074708100
  - Table: messagewall-dev-205074708100
  - Lambda: messagewall-dev-api-handler (256MB, 10s)
  - Lambda: messagewall-dev-snapshot-writer (256MB, 10s)
  ... and 13 more

View all resources? [y/N]:
Save to ConfigHub space messagewall-dev-east? [Y/n]:
```

### Output: Explicit, Inspectable, Modifiable

```yaml
# Generated by: mw create --env dev --region us-east-1
# Timestamp: 2026-01-31T15:00:00Z
#
# This is EXPLICIT configuration - no runtime transformation.
# You can edit ANY field directly. Other tools can too.
#
# Resources: 17 total
#   - 1 S3 Bucket + 5 configs (ownership, public-access, website, cors, policy)
#   - 1 DynamoDB Table
#   - 2 IAM Roles + 2 Policies
#   - 2 Lambda Functions + 2 Permissions
#   - 1 Function URL
#   - 1 EventBridge Rule + Target + Permission
---
apiVersion: s3.aws.upbound.io/v1beta2
kind: Bucket
metadata:
  name: messagewall-dev-east-bucket
  labels:
    app.kubernetes.io/part-of: messagewall
    environment: dev
  annotations:
    crossplane.io/external-name: messagewall-dev-205074708100
    mw.demo/generator-version: "1.0"
spec:
  forProvider:
    region: us-east-1
  providerConfigRef:
    name: default
---
# ... 16 more explicit resources
```

### Why This Isn't Just "Another Abstraction"

| Abstraction (Composition) | Progressive Disclosure (mw tool) |
|---------------------------|----------------------------------|
| Hides 17 resources behind 8-field interface | Shows 17 resources; offers 8-field starting point |
| Developer cannot access underlying fields | Developer can edit ANY field |
| "What parameter produces X output?" | "Edit X directly" |
| Only Claim interface can be modified | Any tool can modify any resource |
| Output constraints applied to Claim | Output constraints applied to actual resources |

**The test:** Can a security scanner add a tag to the Lambda function without understanding the abstraction layer?
- **Abstraction:** No—must modify Claim, hope Composition exposes that field
- **Progressive disclosure:** Yes—edit the Lambda resource directly

---

## Implementation Pathway

### Phase 1: Extract Composition Logic into Go/Python Tool

**Goal:** Create `mw` CLI that produces the same output as the Composition

1. Parse the existing Composition YAML
2. Implement the patch/transform logic in code
3. Generate explicit resource YAML
4. Validate output matches Composition output

**Acceptance Criteria:**
- `mw create --env dev` produces identical resources to current Claim
- Resources can be applied directly to Crossplane (no XRD needed)
- Diff between Composition output and tool output is empty

### Phase 2: Add Developer Experience Features

**Goal:** Make the tool pleasant to use

1. Interactive prompts with validation
2. `--dry-run` for preview
3. `--diff` to show changes from current state
4. Schema validation against allowed values
5. Helpful error messages

**Acceptance Criteria:**
- New developer can create infrastructure in <2 minutes
- Invalid inputs produce clear error messages
- Output includes provenance comments (who/when/inputs)

### Phase 3: ConfigHub Integration

**Goal:** Tool publishes directly to ConfigHub

```bash
# Generate and publish in one step
mw create --env dev --publish --space messagewall-dev-east

# Or separate steps
mw create --env dev --output manifests/
cub unit update --space messagewall-dev-east claim manifests/
```

**Acceptance Criteria:**
- Tool can authenticate to ConfigHub
- Output format matches ConfigHub unit expectations
- Change descriptions auto-generated from inputs

### Phase 4: Remove XRD/Composition from Demo

**Goal:** Demonstrate pure WET workflow

1. Deprecate Claim-based workflow
2. Update demo scripts to use `mw` tool
3. Remove Composition from actuator cluster
4. Document the WET philosophy

**Acceptance Criteria:**
- Demo runs without XRD/Composition installed
- Developer experience is equivalent or better
- ConfigHub shows explicit resources, not Claims

---

## Comparison: Composition vs Tool

| Aspect | XRD/Composition | `mw` Tool |
|--------|-----------------|-----------|
| Rendering | Runtime (Crossplane) | Authoring time |
| Visibility | Claim only in ConfigHub | Full resources in ConfigHub |
| Diffs | Claim-level only | Resource-level diffs |
| Debugging | "Why did it generate X?" | "I can see exactly what was generated" |
| Rollback | Rollback Claim | Rollback any resource |
| Bulk changes | Modify Claim fields | Modify explicit resources directly |
| Multi-source writes | Limited (Claim is the interface) | Any system can modify any resource |

### WET Enables True Multi-Source Configuration

This is where the CaD vision comes alive. With explicit resources in ConfigHub, **any authorized tool can modify any field**:

```bash
# Developer creates initial infrastructure
mw create --env dev --account 205074708100 --publish messagewall-dev-east

# Security scanner adds compliance tag (no abstraction layer to navigate)
cub unit get --space messagewall-dev-east api-handler --data-only | \
  yq '.spec.forProvider.tags["security-reviewed"] = "2026-01-31"' | \
  cub unit update --space messagewall-dev-east api-handler - \
    --change-desc "SEC-001: Mark as security reviewed"

# FinOps system right-sizes memory based on metrics
cub unit get --space messagewall-dev-east api-handler --data-only | \
  yq '.spec.forProvider.memorySize = 192' | \
  cub unit update --space messagewall-dev-east api-handler - \
    --change-desc "FINOPS-Q1: Right-size based on usage metrics"

# SRE adds operational metadata during incident
cub unit get --space messagewall-dev-east api-handler --data-only | \
  yq '.spec.forProvider.environment[0].variables.DEBUG_MODE = "true"' | \
  cub unit update --space messagewall-dev-east api-handler - \
    --change-desc "INC-456: Enable debug logging for investigation"
```

**Why this doesn't work with Composition:**

| With Composition | With WET |
|------------------|----------|
| Security scanner: "I want to add a tag. Does the Claim expose tags? No. Can I modify the underlying Lambda? Only if I bypass the abstraction, creating drift." | Security scanner: "I want to add a tag. Let me modify `.spec.forProvider.tags` on the Lambda resource. Done." |
| FinOps: "I want to set memory to 192MB. The Claim only exposes lambdaMemory, which applies to BOTH Lambdas equally. I can't tune them individually." | FinOps: "I want to set api-handler to 192MB and snapshot-writer to 128MB. Let me modify each Lambda resource independently." |

**The configuration substrate becomes writable by the organization, not just by developers.**

---

## Tool Technology Options

### Option A: Go CLI (Recommended)

**Pros:**
- Single binary, easy distribution
- Same language as Crossplane/Kubernetes ecosystem
- Fast execution
- Can use Crossplane libraries for schema validation

**Cons:**
- More upfront development effort

### Option B: Python Script

**Pros:**
- Faster to prototype
- Easier YAML manipulation (ruamel.yaml preserves formatting)
- Team may have more Python experience

**Cons:**
- Requires Python runtime
- Dependency management

### Option C: Shell + yq/jq

**Pros:**
- No compilation needed
- Leverages existing tools
- Easy to understand/modify

**Cons:**
- Complex logic becomes unwieldy
- Error handling is difficult
- Cross-platform concerns

### Recommendation

Start with **Python** for rapid iteration, plan migration to **Go** for production distribution.

---

## Migration Strategy

### For Existing Claims

```bash
# Export current Claim
kubectl get serverlesseventappclaim messagewall-dev-east -o yaml > claim.yaml

# Convert to explicit resources
mw convert --from-claim claim.yaml --output manifests/

# Publish to ConfigHub
cub unit update --space messagewall-dev-east resources manifests/

# Remove Claim from cluster
kubectl delete serverlesseventappclaim messagewall-dev-east
```

### Demo Transition

1. **Parallel operation**: Run both Claim and explicit resources
2. **Comparison validation**: Ensure identical AWS state
3. **Switch demo scripts**: Use `mw` tool
4. **Remove Composition**: Clean up XRD/Composition

---

## How This Changes the Demo Narrative

### Current Demo Message

> "Crossplane abstracts AWS complexity behind a simple Claim interface."

This frames the value as **hiding complexity** (abstraction).

### New Demo Message

> "ConfigHub is a configuration data substrate where developers, security, FinOps, and SRE all read and write. The `mw` tool gives developers a simple starting point, but the explicit resources can be modified by anyone."

This frames the value as **shared configuration** (multi-source substrate).

### Demo Flow Comparison

| Step | Current (Composition) | Proposed (WET) |
|------|----------------------|----------------|
| 1. Deploy | `kubectl apply -f claim.yaml` | `mw create --publish` |
| 2. Security adds tag | "Not exposed in Claim, sorry" | `cub unit update api-handler ...` |
| 3. FinOps tunes memory | "Must modify Claim, affects both Lambdas" | `cub unit update api-handler ... && cub unit update snapshot-writer ...` |
| 4. View what's deployed | "Look at Claim, reverse-engineer Composition" | "Look at the actual Lambda resources in ConfigHub" |
| 5. Debug issue | "What does this Claim field produce?" | "Read the Lambda spec directly" |

### New Demo Talking Points

1. **"The developer created this infrastructure with 2 fields—but look at what's actually stored"** (show 17 explicit resources)

2. **"Security just added a compliance tag. They didn't need to understand any abstraction layer—they modified the Lambda directly."**

3. **"FinOps tuned the api-handler to 192MB and snapshot-writer to 128MB. With a Claim, they couldn't do this—the abstraction exposed a single `lambdaMemory` field for both."**

4. **"Every change—developer, security, finops—is visible in the same ConfigHub history. Same audit trail. Same approval gates."**

5. **"This is what 'configuration as data' means: configuration is a substrate that the organization writes to, not an artifact that developers own."**

---

## Open Questions

1. **Resource granularity in ConfigHub**: One unit with all 17 resources, or separate units per resource? (Affects multi-source writes)
2. **Update semantics**: `mw update` regenerates everything vs `mw edit <resource>` modifies one?
3. **Provenance tracking**: How to show "this field was set by mw-tool, this one by security scanner, this one by finops"?
4. **Schema evolution**: When the tool learns new fields, how do existing resources upgrade?
5. **Conflict resolution**: If developer and security scanner modify the same field, who wins?

---

## Next Steps

1. [ ] Review proposal with stakeholders
2. [ ] Decide on technology (Go vs Python)
3. [ ] Prototype Phase 1 (extract Composition logic)
4. [ ] Validate output parity with Composition
5. [ ] Iterate on developer experience

---

---

## Appendix: Why Not Just "Better Abstractions"?

Brian Grant's analysis addresses this directly:

> "Abstraction is the wrong way to simplify configuration. The standard approach of wrapping configuration in abstractions with input parameters has systematically failed to deliver simplicity. This is using a software engineering technique to solve what is fundamentally a UX problem."

The failure mode of abstractions:

1. **Interface bloat**: The abstraction interface grows to accommodate flexibility, eventually becoming as complex as the output
2. **200% knowledge**: Users learn the abstraction AND the output format, doubling cognitive load
3. **Exclusivity**: Only the abstraction interface can modify resources; other tools are locked out
4. **Reverse-engineering**: "What parameter produces this output?" becomes a constant question

The CaD alternative:

1. **Schema-aware tooling**: Build good UX for actual resource schemas, not bespoke abstraction interfaces
2. **Progressive disclosure**: Start simple, expand when needed—but you're always working with real resources
3. **Output constraints**: Use Kyverno/OPA to validate actual resources, not abstraction inputs
4. **Multi-writer**: Configuration is data that any authorized tool can modify

**The test for whether we've escaped abstraction thinking:**

> "If a tool outside my pipeline needs to modify a resource field, can it do so directly, or must it understand my abstraction layer?"

---

## Related Documents

- [Brian Grant's Configuration as Data Analysis](../../brian-grant-blogs/analysis.md) - Foundational theory
- [XRD Schema](../platform/crossplane/xrd/serverless-event-app.yaml) - Current abstraction (to be replaced)
- [AWS Composition](../platform/crossplane/compositions/serverless-event-app-aws.yaml) - Current runtime rendering (to be replaced)
- [Demo Script Part 10](demo-script.md#part-10-multi-source-configuration) - Multi-source demo narrative
- [ConfigHub + Crossplane Narrative](confighub-crossplane-narrative.md) - Architecture overview
