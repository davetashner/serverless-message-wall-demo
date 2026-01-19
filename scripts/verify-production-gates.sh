#!/bin/bash
# Verify production gates are properly configured and enforced
#
# This script checks:
# 1. Kyverno gate policy is installed and ready
# 2. Production Claims have correct gate annotations
# 3. Gates actually block deletion (dry-run test)
#
# Usage:
#   ./scripts/verify-production-gates.sh [OPTIONS]
#
# Options:
#   --test-delete    Perform dry-run delete test (requires running cluster)
#   --verbose        Show detailed output
#   -h, --help       Show help
#
# Exit codes:
#   0 - All gates verified
#   1 - Gates not properly configured
#   2 - Missing prerequisites
#
# See docs/production-gates.md for gate documentation.

set -euo pipefail

TEST_DELETE=false
VERBOSE=false
ERRORS=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Verify production gates are properly configured.

OPTIONS:
    --test-delete    Perform dry-run delete test (requires running cluster)
    --verbose        Show detailed output
    -h, --help       Show this help message

CHECKS:
    1. Kyverno policy file exists and is valid YAML
    2. Production Claim has precious annotations
    3. Gate annotations are present and enabled
    4. (Optional) Dry-run delete is blocked by Kyverno

EXIT CODES:
    0 - All checks passed
    1 - One or more checks failed
    2 - Missing prerequisites

EOF
    exit 0
}

log_pass() {
    echo -e "${GREEN}[PASS]${NC} $1"
}

log_fail() {
    echo -e "${RED}[FAIL]${NC} $1"
    ((ERRORS++))
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_info() {
    if [[ "${VERBOSE}" == "true" ]]; then
        echo -e "[INFO] $1"
    fi
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --test-delete)
            TEST_DELETE=true
            shift
            ;;
        --verbose)
            VERBOSE=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

echo "========================================"
echo "Production Gates Verification"
echo "========================================"
echo ""

# -------------------------------------------------------------------
# Check 1: Kyverno policy file exists
# -------------------------------------------------------------------
echo "--- Check 1: Kyverno Policy File ---"

POLICY_FILE="platform/kyverno/policies/gate-precious-resources.yaml"
if [[ -f "${POLICY_FILE}" ]]; then
    log_pass "Policy file exists: ${POLICY_FILE}"
else
    log_fail "Policy file missing: ${POLICY_FILE}"
fi

# Validate YAML syntax
if command -v python3 &> /dev/null; then
    if python3 -c "import yaml; yaml.safe_load(open('${POLICY_FILE}'))" 2>/dev/null; then
        log_pass "Policy YAML is valid"
    else
        log_fail "Policy YAML is invalid"
    fi
else
    log_warn "python3 not available, skipping YAML validation"
fi

# Check policy contains required rules
if grep -q "block-delete-precious-claims" "${POLICY_FILE}" 2>/dev/null; then
    log_pass "Delete gate rule present"
else
    log_fail "Delete gate rule missing"
fi

if grep -q "block-destroy-precious-claims" "${POLICY_FILE}" 2>/dev/null; then
    log_pass "Destroy gate rule present"
else
    log_fail "Destroy gate rule missing"
fi

echo ""

# -------------------------------------------------------------------
# Check 2: Production Claim has precious annotations
# -------------------------------------------------------------------
echo "--- Check 2: Production Claim Annotations ---"

CLAIM_FILE="examples/claims/messagewall-prod.yaml"
if [[ -f "${CLAIM_FILE}" ]]; then
    log_pass "Production Claim file exists: ${CLAIM_FILE}"
else
    log_fail "Production Claim file missing: ${CLAIM_FILE}"
    echo ""
    echo "Total errors: ${ERRORS}"
    exit 1
fi

# Check for precious annotation
if grep -q 'confighub.io/precious.*"true"' "${CLAIM_FILE}" 2>/dev/null; then
    log_pass "precious=true annotation present"
else
    log_fail "precious=true annotation missing"
fi

# Check for delete-gate annotation
if grep -q 'confighub.io/delete-gate.*"enabled"' "${CLAIM_FILE}" 2>/dev/null; then
    log_pass "delete-gate=enabled annotation present"
else
    log_warn "delete-gate annotation not explicitly set (defaults to enabled)"
fi

# Check for destroy-gate annotation
if grep -q 'confighub.io/destroy-gate.*"enabled"' "${CLAIM_FILE}" 2>/dev/null; then
    log_pass "destroy-gate=enabled annotation present"
else
    log_warn "destroy-gate annotation not explicitly set (defaults to enabled)"
fi

# Check for precious-resources annotation
if grep -q 'confighub.io/precious-resources' "${CLAIM_FILE}" 2>/dev/null; then
    RESOURCES=$(grep 'confighub.io/precious-resources' "${CLAIM_FILE}" | sed 's/.*: *"\([^"]*\)".*/\1/')
    log_pass "precious-resources: ${RESOURCES}"
else
    log_warn "precious-resources annotation missing (recommended for clarity)"
fi

echo ""

# -------------------------------------------------------------------
# Check 3: Kyverno cluster policy (if cluster available)
# -------------------------------------------------------------------
echo "--- Check 3: Cluster Policy Status ---"

if ! command -v kubectl &> /dev/null; then
    log_warn "kubectl not available, skipping cluster checks"
elif ! kubectl cluster-info &> /dev/null; then
    log_warn "Kubernetes cluster not reachable, skipping cluster checks"
else
    # Check if policy is installed
    if kubectl get clusterpolicy gate-precious-resources &> /dev/null; then
        log_pass "ClusterPolicy gate-precious-resources is installed"

        # Check policy status
        READY=$(kubectl get clusterpolicy gate-precious-resources -o jsonpath='{.status.ready}' 2>/dev/null || echo "unknown")
        if [[ "${READY}" == "true" ]]; then
            log_pass "Policy status: ready"
        else
            log_warn "Policy status: ${READY} (may still be initializing)"
        fi
    else
        log_warn "ClusterPolicy not installed (apply with: kubectl apply -f ${POLICY_FILE})"
    fi
fi

echo ""

# -------------------------------------------------------------------
# Check 4: Dry-run delete test (optional)
# -------------------------------------------------------------------
if [[ "${TEST_DELETE}" == "true" ]]; then
    echo "--- Check 4: Delete Gate Test (dry-run) ---"

    if ! command -v kubectl &> /dev/null; then
        log_fail "kubectl not available for delete test"
    elif ! kubectl cluster-info &> /dev/null; then
        log_fail "Kubernetes cluster not reachable for delete test"
    else
        # Check if the Claim exists
        if kubectl get serverlesseventappclaim messagewall-prod &> /dev/null; then
            echo "Testing delete gate with dry-run..."

            # Attempt dry-run delete
            DELETE_OUTPUT=$(kubectl delete serverlesseventappclaim messagewall-prod --dry-run=server 2>&1 || true)

            if echo "${DELETE_OUTPUT}" | grep -q "DELETE BLOCKED\|denied the request\|gate-precious-resources"; then
                log_pass "Delete gate BLOCKED the operation (as expected)"
                log_info "Output: ${DELETE_OUTPUT}"
            elif echo "${DELETE_OUTPUT}" | grep -q "deleted"; then
                log_fail "Delete gate DID NOT block the operation!"
                echo "Output: ${DELETE_OUTPUT}"
            else
                log_warn "Unexpected output from delete test"
                echo "Output: ${DELETE_OUTPUT}"
            fi
        else
            log_warn "Claim messagewall-prod not found in cluster (skipping delete test)"
        fi
    fi

    echo ""
fi

# -------------------------------------------------------------------
# Summary
# -------------------------------------------------------------------
echo "========================================"
echo "Summary"
echo "========================================"

if [[ ${ERRORS} -eq 0 ]]; then
    echo -e "${GREEN}All checks passed!${NC}"
    echo ""
    echo "Production gates are properly configured."
    echo "See docs/production-gates.md for usage details."
    exit 0
else
    echo -e "${RED}${ERRORS} check(s) failed.${NC}"
    echo ""
    echo "Please fix the issues above before proceeding."
    echo "See docs/production-gates.md for configuration details."
    exit 1
fi
