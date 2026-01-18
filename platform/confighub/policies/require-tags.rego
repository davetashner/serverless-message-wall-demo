# require-tags.rego
# ConfigHub OPA policy that validates required tags/labels on Claims
#
# This policy mirrors the Kyverno tag validation (platform/kyverno/policies/validate-aws-tags.yaml)
# to provide defense-in-depth: violations are caught at the authority layer (ConfigHub)
# before they reach the actuation layer (Kyverno).
#
# See ISSUE-14.3 and ADR-005 for the defense-in-depth rationale.

package messagewall.policies.tags

import future.keywords.in
import future.keywords.if
import future.keywords.contains

# Deny Claims missing required environment field
deny contains msg if {
    input.kind == "ServerlessEventAppClaim"
    not input.spec.environment
    msg := "ServerlessEventAppClaim must specify spec.environment (dev, staging, or prod)"
}

# Deny Claims with invalid environment values
deny contains msg if {
    input.kind == "ServerlessEventAppClaim"
    env := input.spec.environment
    not env in {"dev", "staging", "prod"}
    msg := sprintf("Invalid environment '%s'. Must be one of: dev, staging, prod", [env])
}

# Deny Claims missing required awsAccountId
deny contains msg if {
    input.kind == "ServerlessEventAppClaim"
    not input.spec.awsAccountId
    msg := "ServerlessEventAppClaim must specify spec.awsAccountId (12-digit AWS account ID)"
}

# Validate awsAccountId format (12 digits)
deny contains msg if {
    input.kind == "ServerlessEventAppClaim"
    account_id := input.spec.awsAccountId
    not regex.match(`^[0-9]{12}$`, account_id)
    msg := sprintf("Invalid awsAccountId '%s'. Must be exactly 12 digits", [account_id])
}

# Deny Claims missing metadata.name (required for tracking)
deny contains msg if {
    input.kind == "ServerlessEventAppClaim"
    not input.metadata.name
    msg := "ServerlessEventAppClaim must have metadata.name"
}

# Warn if resourcePrefix doesn't match naming convention
warn contains msg if {
    input.kind == "ServerlessEventAppClaim"
    prefix := input.spec.resourcePrefix
    prefix != ""
    not regex.match(`^[a-z][a-z0-9-]*$`, prefix)
    msg := sprintf("resourcePrefix '%s' should match pattern: lowercase letters, numbers, hyphens only", [prefix])
}

# Helper: Check if all required fields are present for audit logging
required_fields_present if {
    input.spec.environment
    input.spec.awsAccountId
    input.metadata.name
}
