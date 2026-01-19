#!/bin/bash
# Demo: Production Gate Workflow
#
# This script demonstrates the complete EPIC-17 gate workflow:
# 1. Create a precious test resource
# 2. Attempt delete (blocked by gate)
# 3. Apply break-glass override
# 4. Delete succeeds with override
#
# Usage:
#   ./scripts/demo-gate-workflow.sh [OPTIONS]
#
# Options:
#   --skip-create    Skip resource creation (use existing)
#   --skip-cleanup   Leave test resource after demo
#   --verbose        Show detailed output
#   -h, --help       Show help
#
# Prerequisites:
#   - kubectl configured for actuator cluster
#   - Kyverno installed with gate-precious-resources policy
#   - ServerlessEventAppClaim CRD installed
#
# See docs/demo-production-gates.md for detailed walkthrough.

set -euo pipefail

SKIP_CREATE=false
SKIP_CLEANUP=false
VERBOSE=false
RESOURCE_NAME="messagewall-gate-demo"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Demonstrate EPIC-17 production gate workflow.

OPTIONS:
    --skip-create    Skip resource creation (use existing)
    --skip-cleanup   Leave test resource after demo
    --verbose        Show detailed output
    -h, --help       Show this help message

WHAT THIS DEMONSTRATES:
    1. Gate blocks unauthorized delete of precious resources
    2. Gate blocks destructive updates (environment change)
    3. Break-glass override allows legitimate deletion
    4. Full audit trail via annotations

EOF
    exit 0
}

log_step() {
    echo -e "\n${BLUE}=== $1 ===${NC}\n"
}

log_pass() {
    echo -e "${GREEN}✓${NC} $1"
}

log_fail() {
    echo -e "${RED}✗${NC} $1"
}

log_info() {
    if [[ "${VERBOSE}" == "true" ]]; then
        echo -e "${YELLOW}INFO:${NC} $1"
    fi
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --skip-create)
            SKIP_CREATE=true
            shift
            ;;
        --skip-cleanup)
            SKIP_CLEANUP=true
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
echo "  EPIC-17: Production Gate Demo"
echo "========================================"

# -------------------------------------------------------------------
# Prerequisites Check
# -------------------------------------------------------------------
log_step "Checking Prerequisites"

if ! command -v kubectl &> /dev/null; then
    log_fail "kubectl not found"
    exit 2
fi

if ! kubectl cluster-info &> /dev/null; then
    log_fail "Cannot connect to Kubernetes cluster"
    exit 2
fi
log_pass "Kubernetes cluster accessible"

if kubectl get clusterpolicy gate-precious-resources &> /dev/null; then
    log_pass "Gate policy installed"
else
    log_fail "Gate policy not installed (apply platform/kyverno/policies/gate-precious-resources.yaml)"
    exit 2
fi

# -------------------------------------------------------------------
# Step 1: Create Test Resource
# -------------------------------------------------------------------
if [[ "${SKIP_CREATE}" == "false" ]]; then
    log_step "Step 1: Creating Test Resource"

    # Clean up any existing resource first
    kubectl delete serverlesseventappclaim "${RESOURCE_NAME}" 2>/dev/null || true
    sleep 1

    cat <<EOF | kubectl apply -f -
apiVersion: messagewall.demo/v1alpha1
kind: ServerlessEventAppClaim
metadata:
  name: ${RESOURCE_NAME}
  namespace: default
  annotations:
    confighub.io/precious: "true"
    confighub.io/precious-resources: "dynamodb,s3"
    confighub.io/data-classification: "test-data"
    confighub.io/delete-gate: "enabled"
    confighub.io/destroy-gate: "enabled"
spec:
  environment: prod
  awsAccountId: "000000000000"
  resourcePrefix: "demo-gate-test"
  region: us-east-1
  lambdaMemory: 256
  lambdaTimeout: 30
EOF

    sleep 2
    log_pass "Created ${RESOURCE_NAME} with precious=true annotation"
else
    log_step "Step 1: Using Existing Resource"
    log_info "Skipping creation as requested"
fi

# -------------------------------------------------------------------
# Step 2: Attempt Delete (Should Be Blocked)
# -------------------------------------------------------------------
log_step "Step 2: Attempting Delete (Expect BLOCKED)"

DELETE_OUTPUT=$(kubectl delete serverlesseventappclaim "${RESOURCE_NAME}" 2>&1 || true)

if echo "${DELETE_OUTPUT}" | grep -q "DELETE BLOCKED\|denied the request"; then
    log_pass "Gate BLOCKED the delete attempt"
    echo ""
    echo "Gate message (excerpt):"
    echo "${DELETE_OUTPUT}" | head -20
else
    log_fail "Gate did NOT block - something is wrong"
    echo "Output: ${DELETE_OUTPUT}"
    exit 1
fi

# -------------------------------------------------------------------
# Step 3: Attempt Destroy (Should Be Blocked)
# -------------------------------------------------------------------
log_step "Step 3: Attempting Environment Change (Expect BLOCKED)"

DESTROY_OUTPUT=$(kubectl patch serverlesseventappclaim "${RESOURCE_NAME}" \
    --type=merge -p '{"spec":{"environment":"dev"}}' 2>&1 || true)

if echo "${DESTROY_OUTPUT}" | grep -q "DESTROY BLOCKED\|denied the request"; then
    log_pass "Gate BLOCKED the destructive update"
    echo ""
    echo "Gate message (excerpt):"
    echo "${DESTROY_OUTPUT}" | head -15
else
    log_fail "Gate did NOT block destructive update"
    echo "Output: ${DESTROY_OUTPUT}"
fi

# -------------------------------------------------------------------
# Step 4: Apply Break-Glass Override
# -------------------------------------------------------------------
log_step "Step 4: Applying Break-Glass Override"

# Calculate expiration (1 hour from now)
if date -u -d "+1 hour" +"%Y-%m-%dT%H:%M:%SZ" &>/dev/null; then
    EXPIRES=$(date -u -d "+1 hour" +"%Y-%m-%dT%H:%M:%SZ")
else
    EXPIRES=$(date -u -v+1H +"%Y-%m-%dT%H:%M:%SZ")
fi

kubectl annotate serverlesseventappclaim "${RESOURCE_NAME}" \
    confighub.io/break-glass=approved \
    confighub.io/break-glass-reason="EPIC-17 gate demonstration" \
    confighub.io/break-glass-approver="demo-script" \
    confighub.io/break-glass-expires="${EXPIRES}" \
    --overwrite

log_pass "Break-glass override applied"
log_info "Expires: ${EXPIRES}"

# Show the annotations
echo ""
echo "Current annotations:"
kubectl get serverlesseventappclaim "${RESOURCE_NAME}" -o jsonpath='{.metadata.annotations}' | \
    python3 -c "import sys,json; d=json.load(sys.stdin); [print(f'  {k}: {v}') for k,v in sorted(d.items()) if 'confighub' in k]" 2>/dev/null || \
    kubectl get serverlesseventappclaim "${RESOURCE_NAME}" -o yaml | grep -A15 "annotations:" | head -16

# -------------------------------------------------------------------
# Step 5: Execute Delete (Should Succeed)
# -------------------------------------------------------------------
log_step "Step 5: Executing Delete with Override"

if kubectl delete serverlesseventappclaim "${RESOURCE_NAME}"; then
    log_pass "Delete SUCCEEDED with break-glass override"
else
    log_fail "Delete failed even with break-glass"
    exit 1
fi

# Verify deletion
if kubectl get serverlesseventappclaim "${RESOURCE_NAME}" &>/dev/null; then
    log_fail "Resource still exists!"
else
    log_pass "Resource confirmed deleted"
fi

# -------------------------------------------------------------------
# Summary
# -------------------------------------------------------------------
log_step "Demo Complete"

echo "Summary:"
echo "  1. Created precious resource with gate annotations"
echo "  2. DELETE was BLOCKED by Kyverno policy"
echo "  3. Environment change was BLOCKED by Kyverno policy"
echo "  4. Applied break-glass override with expiration"
echo "  5. DELETE SUCCEEDED with proper override"
echo ""
echo "This demonstrates defense-in-depth for production resources."
echo "See docs/demo-production-gates.md for manual walkthrough."

echo ""
echo "========================================"
echo "  Demo completed successfully!"
echo "========================================"
