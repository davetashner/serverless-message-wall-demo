# prod-requirements.rego
# ConfigHub OPA policy that enforces production environment requirements
#
# This policy mirrors the Kyverno prod validation (platform/kyverno/policies/validate-claim-prod-requirements.yaml)
# to provide defense-in-depth: violations are caught at the authority layer (ConfigHub)
# before they reach the actuation layer (Kyverno).
#
# See ISSUE-14.2, ISSUE-14.5 and ADR-005 for details.

package messagewall.policies.prod

import future.keywords.if
import future.keywords.contains

# Default values matching the XRD schema
default_lambda_memory := 128
default_lambda_timeout := 10

# Production minimum requirements
prod_min_memory := 256
prod_min_timeout := 30

# Get effective Lambda memory (use default if not specified)
effective_memory := input.spec.lambdaMemory if {
    input.spec.lambdaMemory
} else := default_lambda_memory

# Get effective Lambda timeout (use default if not specified)
effective_timeout := input.spec.lambdaTimeout if {
    input.spec.lambdaTimeout
} else := default_lambda_timeout

# Deny production Claims with insufficient Lambda memory
deny contains msg if {
    input.kind == "ServerlessEventAppClaim"
    input.spec.environment == "prod"
    effective_memory < prod_min_memory
    msg := sprintf(
        "Production Claims must have lambdaMemory >= %d MB. Current: %d MB. Production workloads need sufficient memory for traffic spikes.",
        [prod_min_memory, effective_memory]
    )
}

# Deny production Claims with insufficient Lambda timeout
deny contains msg if {
    input.kind == "ServerlessEventAppClaim"
    input.spec.environment == "prod"
    effective_timeout < prod_min_timeout
    msg := sprintf(
        "Production Claims must have lambdaTimeout >= %d seconds. Current: %d seconds. Production workloads need sufficient timeout for cold starts.",
        [prod_min_timeout, effective_timeout]
    )
}

# Warn about high memory usage (cost optimization)
warn contains msg if {
    input.kind == "ServerlessEventAppClaim"
    effective_memory > 1024
    msg := sprintf(
        "Lambda memory is set to %d MB. Consider if this is necessary - higher memory increases costs.",
        [effective_memory]
    )
}

# Warn about long timeouts (may indicate issues)
warn contains msg if {
    input.kind == "ServerlessEventAppClaim"
    effective_timeout > 60
    msg := sprintf(
        "Lambda timeout is set to %d seconds. Long timeouts may indicate architectural issues.",
        [effective_timeout]
    )
}

# Summary helper for auditing
is_prod if {
    input.spec.environment == "prod"
}

meets_prod_requirements if {
    is_prod
    effective_memory >= prod_min_memory
    effective_timeout >= prod_min_timeout
}
