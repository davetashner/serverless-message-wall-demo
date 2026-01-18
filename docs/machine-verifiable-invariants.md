# Machine-Verifiable Invariants

This document explores how formal invariants can complement or replace human approval for certain categories of changes. When a safety property can be expressed as a machine-checkable rule, enforcement is more reliable than human judgment.

**Status**: Exploration document for ISSUE-15.14
**Related**: [approval-fatigue-and-theater.md](approval-fatigue-and-theater.md) (ISSUE-15.13)

---

## The Case for Invariants

Human approval fails at scale (ISSUE-15.13). But certain safety properties don't require human judgment—they have deterministic, machine-checkable answers:

| Question | Human Judgment? | Machine Checkable? |
|----------|-----------------|-------------------|
| "Is this a good architectural decision?" | Yes | No |
| "Does this IAM policy contain wildcards?" | No | **Yes** |
| "Is this the right time for this change?" | Yes | No |
| "Does this change delete a production database?" | No | **Yes** |
| "Should we prioritize this feature?" | Yes | No |
| "Does Lambda memory exceed 10GB limit?" | No | **Yes** |

**Principle**: For machine-checkable properties, use invariant enforcement. For judgment calls, use human approval.

---

## What Is an Invariant?

An **invariant** is a property that must always be true. Violations are not warnings—they are errors that prevent the operation from proceeding.

```
┌─────────────────────────────────────────────────────────────────┐
│                         INVARIANT                               │
│                                                                  │
│   "No IAM policy may grant Action: '*'"                         │
│                                                                  │
│   Enforcement: BLOCK (not warn, not log, not escalate)          │
│   Override: Change the invariant (with review)                  │
│   Applies to: All configurations, all environments, all actors  │
└─────────────────────────────────────────────────────────────────┘
```

### Invariants vs. Policies

| Aspect | Policy | Invariant |
|--------|--------|-----------|
| Purpose | Enforce best practices | Prevent catastrophic states |
| Response | May warn, may block | Always blocks |
| Exceptions | May have environment-specific rules | No exceptions |
| Override | Approvers can override | Must change the invariant itself |
| Scope | May vary by context | Universal |

---

## Candidate Invariants for This Platform

### Category 1: IAM and Permissions

These invariants prevent privilege escalation and overly broad access.

#### INV-IAM-001: No Wildcard Actions

```rego
# Prevent Action: "*" in any IAM policy statement
invariant_no_wildcard_actions[msg] {
    statement := input.Statement[_]
    statement.Action == "*"
    msg := "IAM policy contains Action: '*' which is prohibited"
}

invariant_no_wildcard_actions[msg] {
    statement := input.Statement[_]
    action := statement.Action[_]
    action == "*"
    msg := "IAM policy contains Action: '*' in action list which is prohibited"
}
```

**What it prevents**: Complete AWS account compromise via IAM policy.

**Example blocked**:
```json
{
  "Statement": [{
    "Effect": "Allow",
    "Action": "*",
    "Resource": "*"
  }]
}
```

---

#### INV-IAM-002: No Wildcard Resources on Dangerous Services

```rego
# Prevent Resource: "*" on services that can exfiltrate data
dangerous_services := {"s3", "dynamodb", "secretsmanager", "ssm", "rds"}

invariant_no_dangerous_wildcards[msg] {
    statement := input.Statement[_]
    statement.Effect == "Allow"
    action := statement.Action[_]
    service := split(action, ":")[0]
    dangerous_services[service]
    statement.Resource == "*"
    msg := sprintf("Wildcard resource on %s is prohibited", [service])
}
```

**What it prevents**: Data exfiltration via overly broad S3/DynamoDB access.

---

#### INV-IAM-003: Permission Boundary Required

```rego
# All IAM roles must have the MessageWallRoleBoundary attached
invariant_permission_boundary[msg] {
    input.kind == "Role"
    not input.spec.forProvider.permissionsBoundary
    msg := "IAM roles must have permissionsBoundary set"
}

invariant_permission_boundary[msg] {
    input.kind == "Role"
    boundary := input.spec.forProvider.permissionsBoundary
    not contains(boundary, "MessageWallRoleBoundary")
    msg := "IAM roles must use MessageWallRoleBoundary"
}
```

**What it prevents**: Roles that can escape the platform's permission constraints.

---

### Category 2: Resource Naming and Scope

These invariants ensure resources stay within the platform's operational boundary.

#### INV-SCOPE-001: Resource Name Prefix

```rego
# All resources must have names starting with allowed prefixes
allowed_prefixes := ["messagewall-"]

invariant_resource_prefix[msg] {
    resource_name := input.metadata.name
    not any_prefix_matches(resource_name, allowed_prefixes)
    msg := sprintf("Resource name '%s' must start with one of: %v", [resource_name, allowed_prefixes])
}

any_prefix_matches(name, prefixes) {
    prefix := prefixes[_]
    startswith(name, prefix)
}
```

**What it prevents**: Resources created outside the platform's managed scope.

---

#### INV-SCOPE-002: Region Restriction

```rego
# Resources must be in approved regions
approved_regions := ["us-east-1", "us-west-2", "eu-west-1"]

invariant_approved_region[msg] {
    input.spec.forProvider.region
    region := input.spec.forProvider.region
    not approved_regions[region]
    msg := sprintf("Region '%s' is not approved. Allowed: %v", [region, approved_regions])
}
```

**What it prevents**: Resources in unexpected regions (compliance, data residency).

---

### Category 3: Deletion Protection

These invariants prevent irreversible data loss.

#### INV-DELETE-001: No Direct Production Database Deletion

```rego
# DynamoDB tables in production cannot be deleted without deletion protection disabled first
invariant_prod_db_deletion[msg] {
    input.kind == "Table"
    is_production(input)
    input.metadata.deletionTimestamp  # Deletion is being attempted
    input.spec.forProvider.deletionProtectionEnabled != false
    msg := "Production DynamoDB tables require deletionProtectionEnabled=false before deletion"
}

is_production(resource) {
    resource.metadata.labels.environment == "prod"
}
```

**What it prevents**: Accidental production database deletion.

---

#### INV-DELETE-002: S3 Bucket Must Be Empty Before Deletion

```rego
# S3 buckets cannot be deleted if they contain objects
invariant_bucket_empty[msg] {
    input.kind == "Bucket"
    input.metadata.deletionTimestamp
    bucket_not_empty(input.status.atProvider.name)
    msg := "S3 bucket must be empty before deletion"
}
```

**What it prevents**: Data loss from S3 bucket deletion.

---

### Category 4: Encryption and Security

These invariants ensure security baselines are met.

#### INV-ENCRYPT-001: Production Data At Rest Encryption

```rego
# Production DynamoDB tables must have encryption enabled
invariant_dynamodb_encryption[msg] {
    input.kind == "Table"
    is_production(input)
    not input.spec.forProvider.serverSideEncryption.enabled
    msg := "Production DynamoDB tables must have server-side encryption enabled"
}
```

**What it prevents**: Unencrypted data at rest in production.

---

#### INV-ENCRYPT-002: S3 Default Encryption

```rego
# Production S3 buckets must have default encryption
invariant_s3_encryption[msg] {
    input.kind == "Bucket"
    is_production(input)
    not has_default_encryption(input)
    msg := "Production S3 buckets must have default encryption configured"
}
```

---

### Category 5: Resource Limits

These invariants prevent resource exhaustion and cost overruns.

#### INV-LIMIT-001: Lambda Memory Bounds

```rego
# Lambda memory must be within platform bounds
invariant_lambda_memory[msg] {
    input.kind == "ServerlessEventAppClaim"
    memory := input.spec.lambdaMemory
    memory < 128
    msg := sprintf("Lambda memory %d is below minimum 128 MB", [memory])
}

invariant_lambda_memory[msg] {
    input.kind == "ServerlessEventAppClaim"
    memory := input.spec.lambdaMemory
    memory > 3008  # Platform limit, not AWS limit
    msg := sprintf("Lambda memory %d exceeds platform maximum 3008 MB", [memory])
}
```

**What it prevents**: Under-provisioned or over-provisioned Lambdas.

---

#### INV-LIMIT-002: Lambda Timeout Bounds

```rego
# Lambda timeout must be within platform bounds
invariant_lambda_timeout[msg] {
    input.kind == "ServerlessEventAppClaim"
    timeout := input.spec.lambdaTimeout
    timeout > 300  # Platform limit: 5 minutes max
    msg := sprintf("Lambda timeout %d exceeds platform maximum 300 seconds", [timeout])
}
```

---

## Examples: Invariants Preventing Irreversible Harm

### Example 1: Privilege Escalation Attempt

An agent proposes an IAM policy change:

```yaml
# Agent proposal
change:
  patch:
    - op: replace
      path: /spec/forProvider/policy
      value: |
        {
          "Statement": [{
            "Effect": "Allow",
            "Action": ["s3:*", "dynamodb:*", "iam:*"],
            "Resource": "*"
          }]
        }
```

**Invariant evaluation**:
```
INV-IAM-002: FAIL
  - s3:* with Resource: "*" is prohibited
  - dynamodb:* with Resource: "*" is prohibited
  - iam:* with Resource: "*" is prohibited

Result: BLOCKED (invariant violation)
```

**Human approval is not asked.** The change is impossible regardless of who proposes it or how confident they are.

---

### Example 2: Production Database Deletion

An automation script attempts to clean up resources:

```bash
kubectl delete table messagewall-prod-data
```

**Invariant evaluation**:
```
INV-DELETE-001: FAIL
  - Table has deletionProtectionEnabled: true
  - Production tables require explicit protection removal first

Result: BLOCKED (invariant violation)
```

To actually delete, someone must first:
1. Set `deletionProtectionEnabled: false` (HIGH risk, requires approval)
2. Wait for approval
3. Then delete

This is intentional friction for irreversible actions.

---

### Example 3: Region Change with Data

An agent proposes moving production to EU:

```yaml
change:
  patch:
    - op: replace
      path: /spec/region
      value: eu-west-1
```

**Invariant evaluation**:
```
INV-SCOPE-002: PASS (eu-west-1 is approved)

But wait - what about existing data?
```

This is where human judgment is needed. Invariants don't know:
- Is there data that can't be moved?
- Is there a migration plan?
- Is this the right time?

**Result**: Invariants pass. Change is HIGH risk (region + prod). Human approval required.

---

## Boundary: Invariants vs. Human Judgment

```
┌─────────────────────────────────────────────────────────────────────────┐
│                     MACHINE-VERIFIABLE INVARIANTS                       │
│                                                                          │
│   Use for properties that are:                                          │
│   ✓ Deterministic (no ambiguity)                                       │
│   ✓ Universal (true in all contexts)                                    │
│   ✓ Automatable (can be checked by code)                               │
│   ✓ Preventing catastrophic states (not just best practices)           │
│                                                                          │
│   Examples:                                                              │
│   • No wildcard IAM permissions                                         │
│   • All production data encrypted                                       │
│   • Resources must be in approved regions                               │
│   • Deletion protection on production databases                         │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    │ Invariants pass
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                         HUMAN JUDGMENT                                   │
│                                                                          │
│   Use for decisions that require:                                       │
│   ✓ Context awareness (timing, business needs)                          │
│   ✓ Trade-off analysis (competing priorities)                           │
│   ✓ Stakeholder coordination (who else is affected?)                   │
│   ✓ Risk tolerance calibration (how conservative should we be?)        │
│                                                                          │
│   Examples:                                                              │
│   • Is this the right time for a production change?                     │
│   • Is the migration plan sufficient?                                   │
│   • Should we prioritize stability or velocity?                         │
│   • Is the business justification compelling?                           │
└─────────────────────────────────────────────────────────────────────────┘
```

### Decision Tree

```
Configuration Change
        │
        ▼
┌───────────────────┐
│ Invariant Check   │
└─────────┬─────────┘
          │
    ┌─────┴─────┐
    │           │
  FAIL        PASS
    │           │
    ▼           ▼
BLOCKED    ┌───────────────────┐
(no human  │ Risk Assessment   │
 can       └─────────┬─────────┘
 override)           │
              ┌──────┴──────┐
              │             │
          LOW/MEDIUM      HIGH
              │             │
              ▼             ▼
         Auto-apply    ┌───────────────┐
         (or notify)   │ Human Approval│
                       └───────────────┘
```

### What Humans Should NOT Be Asked

If you find yourself asking humans to approve these, you should convert them to invariants:

| Question | Convert to Invariant |
|----------|---------------------|
| "This policy has wildcards, is that OK?" | `INV-IAM-001` blocks wildcards |
| "This deletes a production table, proceed?" | `INV-DELETE-001` requires protection removal first |
| "Lambda memory is very high, approve?" | `INV-LIMIT-001` enforces bounds |
| "Resource is in unusual region, allow?" | `INV-SCOPE-002` restricts regions |

Humans should only approve when machine verification is insufficient.

---

## Agent-to-Agent Approval via Invariants

A radical implication: **If invariants are comprehensive enough, agents could approve other agents.**

### The Vision

```
Agent A proposes change
        │
        ▼
All invariants pass (machine-verified)
        │
        ▼
Risk class: LOW (schema-derived)
        │
        ▼
Agent B reviews and approves
        │
        ▼
Change applied
```

### Requirements for Agent-to-Agent Approval

1. **Comprehensive invariants**: All catastrophic states must be prevented by invariants
2. **Low risk only**: HIGH risk still requires humans
3. **Different agent**: Proposing agent cannot approve its own changes
4. **Full audit**: All decisions logged for human review

### Risks

- **Invariant gaps**: If invariants miss a catastrophic state, agents can cause harm
- **Collusion**: Adversarial agents could game the system
- **Trust erosion**: Humans may not accept agent-to-agent approval

### Recommendation

Agent-to-agent approval is a future consideration, not a current goal. First:
1. Build comprehensive invariants
2. Validate invariants catch all catastrophic states
3. Earn trust through successful human-agent workflows
4. Then consider expanding agent authority

---

## Implementing Invariants

### Where Invariants Run

| Layer | What It Checks | Enforcement |
|-------|---------------|-------------|
| Pre-commit | Developer's local changes | Warning (can skip) |
| CI | PR changes | Block merge |
| ConfigHub | Changes to authority store | Block apply |
| Kyverno | Changes to Kubernetes | Block admission |

### Invariant Registry

All invariants should be documented in a central registry:

```yaml
# platform/invariants/registry.yaml
invariants:
  - id: INV-IAM-001
    title: No Wildcard Actions
    severity: critical
    category: iam
    enforcement:
      - layer: confighub
        policy: platform/confighub/policies/iam-invariants.rego
      - layer: kyverno
        policy: platform/kyverno/policies/validate-iam-no-wildcards.yaml
    testCases:
      - input: test/fixtures/iam-wildcard-action.yaml
        expected: fail

  - id: INV-DELETE-001
    title: Production Database Deletion Protection
    severity: critical
    category: deletion
    enforcement:
      - layer: kyverno
        policy: platform/kyverno/policies/validate-deletion-protection.yaml
```

---

## Summary

| Invariant Category | Example | What It Prevents |
|-------------------|---------|------------------|
| IAM/Permissions | No wildcard actions | Privilege escalation |
| Resource Scope | Name prefix required | Scope escape |
| Deletion Protection | Prod DB protection | Data loss |
| Encryption | At-rest encryption required | Data exposure |
| Resource Limits | Memory/timeout bounds | Resource abuse |

**Key principle**: Use invariants for machine-verifiable safety properties. Reserve human judgment for context-dependent decisions.

**Boundary**:
- Invariants → Deterministic, universal, catastrophe-preventing
- Human approval → Context-aware, trade-off-requiring, judgment-needing

---

## References

- [Approval Fatigue and Theater](approval-fatigue-and-theater.md) — Why human approval alone is insufficient
- [Platform Invariants](invariants.md) — Currently enforced invariants
- [Policy Guardrails Demo](demo-policy-guardrails.md) — Policy examples
- EPIC-14 — Policy implementation
