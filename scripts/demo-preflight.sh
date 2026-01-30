#!/bin/bash
# demo-preflight.sh - Pre-flight checks before running the 9-part demo
#
# Run this before presenting to ensure everything is ready.
# Exit code 0 = all checks passed, non-zero = something needs attention.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "${SCRIPT_DIR}")"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

ERRORS=0
WARNINGS=0

pass() { echo -e "${GREEN}✓${NC} $1"; }
fail() { echo -e "${RED}✗${NC} $1"; ERRORS=$((ERRORS + 1)); }
warn() { echo -e "${YELLOW}!${NC} $1"; WARNINGS=$((WARNINGS + 1)); }
info() { echo -e "${BLUE}ℹ${NC} $1"; }

echo ""
echo "═══════════════════════════════════════════════════════"
echo "  DEMO PRE-FLIGHT CHECKS (9-Part Demo)"
echo "═══════════════════════════════════════════════════════"
echo ""

#------------------------------------------------------------------------------
# 1. Kind Clusters
#------------------------------------------------------------------------------
echo -e "${BOLD}Kind Clusters:${NC}"

# Check actuator-east cluster
if kind get clusters 2>/dev/null | grep -q "^actuator-east$"; then
    pass "actuator-east cluster exists"
else
    fail "actuator-east cluster missing (run: scripts/bootstrap-kind.sh --name actuator-east --region us-east-1)"
fi

# Check actuator-west cluster
if kind get clusters 2>/dev/null | grep -q "^actuator-west$"; then
    pass "actuator-west cluster exists"
else
    fail "actuator-west cluster missing (run: scripts/bootstrap-kind.sh --name actuator-west --region us-west-2)"
fi

# Check workload cluster
if kind get clusters 2>/dev/null | grep -q "^workload$"; then
    pass "workload cluster exists"
else
    fail "workload cluster missing (run: scripts/bootstrap-workload-cluster.sh)"
fi

echo ""

#------------------------------------------------------------------------------
# 2. Crossplane Health (both actuator clusters)
#------------------------------------------------------------------------------
echo -e "${BOLD}Crossplane (actuator clusters):${NC}"

for REGION in east west; do
    CONTEXT="kind-actuator-${REGION}"

    if ! kubectl cluster-info --context "${CONTEXT}" &>/dev/null; then
        fail "Cannot connect to ${CONTEXT}"
        continue
    fi

    CROSSPLANE_RUNNING=$(kubectl get pods -n crossplane-system --context "${CONTEXT}" --no-headers 2>/dev/null | grep -c "Running" || true)
    if [[ "$CROSSPLANE_RUNNING" -gt 0 ]]; then
        pass "${CONTEXT}: $CROSSPLANE_RUNNING Crossplane pods running"
    else
        fail "${CONTEXT}: Crossplane not healthy (run: scripts/bootstrap-crossplane.sh --context ${CONTEXT})"
    fi

    # Check providers
    PROVIDER_OUTPUT=$(kubectl get providers.pkg.crossplane.io --context "${CONTEXT}" 2>/dev/null || true)
    PROVIDER_COUNT=$(echo "$PROVIDER_OUTPUT" | grep -c "True.*True" || true)
    if [[ "$PROVIDER_COUNT" -gt 0 ]]; then
        pass "${CONTEXT}: $PROVIDER_COUNT AWS providers healthy"
    else
        fail "${CONTEXT}: Crossplane providers not healthy (run: scripts/bootstrap-aws-providers.sh --context ${CONTEXT})"
    fi
done

echo ""

#------------------------------------------------------------------------------
# 3. Kyverno Health (both actuator clusters)
#------------------------------------------------------------------------------
echo -e "${BOLD}Kyverno (actuator clusters):${NC}"

for REGION in east west; do
    CONTEXT="kind-actuator-${REGION}"

    if ! kubectl cluster-info --context "${CONTEXT}" &>/dev/null; then
        continue
    fi

    KYVERNO_OUTPUT=$(kubectl get pods -n kyverno --context "${CONTEXT}" --no-headers 2>/dev/null || true)
    KYVERNO_PODS=$(echo "$KYVERNO_OUTPUT" | grep -c "Running" || true)
    if [[ "$KYVERNO_PODS" -gt 0 ]]; then
        pass "${CONTEXT}: $KYVERNO_PODS Kyverno pods running"
    else
        fail "${CONTEXT}: Kyverno not running (run: scripts/bootstrap-kyverno.sh --context ${CONTEXT})"
    fi

    POLICY_COUNT=$(kubectl get clusterpolicy --context "${CONTEXT}" 2>/dev/null | grep -c "True" || true)
    POLICY_COUNT=${POLICY_COUNT:-0}
    if [[ ${POLICY_COUNT} -gt 0 ]]; then
        pass "${CONTEXT}: $POLICY_COUNT Kyverno policies loaded"
    else
        warn "${CONTEXT}: No Kyverno policies (run: kubectl apply -f platform/kyverno/policies/ --context ${CONTEXT})"
    fi
done

echo ""

#------------------------------------------------------------------------------
# 4. ArgoCD Health (all three clusters)
#------------------------------------------------------------------------------
echo -e "${BOLD}ArgoCD:${NC}"

for CONTEXT in kind-actuator-east kind-actuator-west kind-workload; do
    if ! kubectl cluster-info --context "${CONTEXT}" &>/dev/null; then
        continue
    fi

    ARGOCD_OUTPUT=$(kubectl get pods -n argocd --context "${CONTEXT}" --no-headers 2>/dev/null || true)
    ARGOCD_PODS=$(echo "$ARGOCD_OUTPUT" | grep -c "Running" || true)
    if [[ "$ARGOCD_PODS" -gt 0 ]]; then
        pass "${CONTEXT}: $ARGOCD_PODS ArgoCD pods running"
    else
        warn "${CONTEXT}: ArgoCD not running"
    fi
done

echo ""

#------------------------------------------------------------------------------
# 5. AWS Credentials
#------------------------------------------------------------------------------
echo -e "${BOLD}AWS Access:${NC}"

if aws sts get-caller-identity &>/dev/null; then
    ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
    pass "AWS credentials valid (account: $ACCOUNT)"
else
    fail "AWS credentials not configured"
fi

echo ""

#------------------------------------------------------------------------------
# 6. ConfigHub CLI and Authentication
#------------------------------------------------------------------------------
echo -e "${BOLD}ConfigHub CLI:${NC}"

if ! command -v cub &> /dev/null; then
    fail "cub CLI not installed"
else
    pass "cub CLI installed"

    if cub auth status &> /dev/null; then
        pass "ConfigHub authenticated"
    else
        fail "Not authenticated (run: cub auth login)"
    fi
fi

echo ""

#------------------------------------------------------------------------------
# 7. ConfigHub Spaces - Messagewall (4 spaces)
#------------------------------------------------------------------------------
echo -e "${BOLD}ConfigHub Spaces (Messagewall):${NC}"

if command -v cub &> /dev/null && cub auth status &> /dev/null; then
    SPACE_OUTPUT=$(cub space list 2>/dev/null || true)

    MESSAGEWALL_SPACES=(
        "messagewall-dev-east"
        "messagewall-dev-west"
        "messagewall-prod-east"
        "messagewall-prod-west"
    )

    MESSAGEWALL_FOUND=0
    for SPACE in "${MESSAGEWALL_SPACES[@]}"; do
        if echo "$SPACE_OUTPUT" | grep -q "${SPACE}"; then
            pass "Space '${SPACE}' exists"
            MESSAGEWALL_FOUND=$((MESSAGEWALL_FOUND + 1))
        else
            fail "Space '${SPACE}' not found (run: scripts/setup-multiregion-spaces.sh)"
        fi
    done

    if [[ $MESSAGEWALL_FOUND -eq 4 ]]; then
        info "All 4 messagewall spaces found"
    fi
else
    warn "Skipping ConfigHub space checks (not authenticated)"
fi

echo ""

#------------------------------------------------------------------------------
# 8. ConfigHub Spaces - Order Platform (10 spaces)
#------------------------------------------------------------------------------
echo -e "${BOLD}ConfigHub Spaces (Order Platform):${NC}"

if command -v cub &> /dev/null && cub auth status &> /dev/null; then
    SPACE_OUTPUT=$(cub space list 2>/dev/null || true)

    ORDER_PLATFORM_SPACES=(
        "order-platform-ops-dev"
        "order-platform-ops-prod"
        "order-data-dev"
        "order-data-prod"
        "order-customer-dev"
        "order-customer-prod"
        "order-integrations-dev"
        "order-integrations-prod"
        "order-compliance-dev"
        "order-compliance-prod"
    )

    ORDER_FOUND=0
    ORDER_MISSING=0
    for SPACE in "${ORDER_PLATFORM_SPACES[@]}"; do
        if echo "$SPACE_OUTPUT" | grep -q "${SPACE}"; then
            ORDER_FOUND=$((ORDER_FOUND + 1))
        else
            ORDER_MISSING=$((ORDER_MISSING + 1))
        fi
    done

    if [[ $ORDER_FOUND -eq 10 ]]; then
        pass "All 10 order-platform spaces exist"
    elif [[ $ORDER_FOUND -gt 0 ]]; then
        warn "$ORDER_FOUND/10 order-platform spaces found (run: scripts/setup-order-platform-spaces.sh)"
    else
        fail "No order-platform spaces found (run: scripts/setup-order-platform-spaces.sh)"
    fi
else
    warn "Skipping ConfigHub space checks (not authenticated)"
fi

echo ""

#------------------------------------------------------------------------------
# 9. Docker Images in Workload Cluster
#------------------------------------------------------------------------------
echo -e "${BOLD}Docker Images (workload cluster):${NC}"

if kind get clusters 2>/dev/null | grep -q "^workload$"; then
    # Check if messagewall-microservice image is loaded
    # We check by looking at the node's images
    IMAGE_CHECK=$(docker exec workload-control-plane crictl images 2>/dev/null | grep "messagewall-microservice" || true)
    if [[ -n "$IMAGE_CHECK" ]]; then
        pass "messagewall-microservice:latest loaded in workload cluster"
    else
        fail "messagewall-microservice:latest not loaded (run: cd app/microservices && ./build.sh && kind load docker-image messagewall-microservice:latest --name workload)"
    fi
else
    warn "Skipping image check (workload cluster not running)"
fi

echo ""

#------------------------------------------------------------------------------
# 10. Order Platform Pods (optional - shows readiness)
#------------------------------------------------------------------------------
if kind get clusters 2>/dev/null | grep -q "^workload$" && kubectl cluster-info --context kind-workload &>/dev/null; then
    echo -e "${BOLD}Order Platform (workload cluster):${NC}"

    PODS_RUNNING=$(kubectl get pods --all-namespaces --context kind-workload --no-headers 2>/dev/null | grep -E '^(platform-ops|data|customer|integrations|compliance)' | grep -c "Running" || true)
    if [[ "$PODS_RUNNING" -ge 20 ]]; then
        pass "All $PODS_RUNNING Order Platform pods running"
    elif [[ "$PODS_RUNNING" -gt 0 ]]; then
        info "$PODS_RUNNING/20 Order Platform pods running"
    else
        info "No Order Platform pods running yet (will deploy in Part 8)"
    fi

    APPS_SYNCED=$(kubectl get applications -n argocd --context kind-workload --no-headers 2>/dev/null | grep -c "Synced" || true)
    if [[ "$APPS_SYNCED" -ge 10 ]]; then
        pass "$APPS_SYNCED/10 ArgoCD applications synced"
    elif [[ "$APPS_SYNCED" -gt 0 ]]; then
        info "$APPS_SYNCED/10 ArgoCD applications synced"
    else
        info "No ArgoCD applications synced yet (will deploy in Part 8)"
    fi

    echo ""
fi

#------------------------------------------------------------------------------
# Summary
#------------------------------------------------------------------------------
echo "═══════════════════════════════════════════════════════"

if [[ ${ERRORS} -eq 0 && ${WARNINGS} -eq 0 ]]; then
    echo -e "${GREEN}PRE-FLIGHT PASSED${NC} - All systems ready!"
    echo ""
    echo "Next steps:"
    echo "  1. Open demo script: cat docs/demo-script.md"
    echo "  2. Start with Part 1: The Claim"
    echo ""
    exit 0
elif [[ ${ERRORS} -eq 0 ]]; then
    echo -e "${YELLOW}PRE-FLIGHT PASSED WITH WARNINGS${NC} - Demo should work"
    echo ""
    exit 0
else
    echo -e "${RED}PRE-FLIGHT FAILED${NC} - ${ERRORS} error(s), ${WARNINGS} warning(s)"
    echo ""
    echo "Quick fixes:"
    echo "  # Create clusters"
    echo "  scripts/bootstrap-kind.sh --name actuator-east --region us-east-1"
    echo "  scripts/bootstrap-kind.sh --name actuator-west --region us-west-2"
    echo "  scripts/bootstrap-workload-cluster.sh"
    echo ""
    echo "  # Install Crossplane on actuator clusters"
    echo "  scripts/bootstrap-crossplane.sh --context kind-actuator-east"
    echo "  scripts/bootstrap-crossplane.sh --context kind-actuator-west"
    echo ""
    echo "  # Create ConfigHub spaces"
    echo "  scripts/setup-multiregion-spaces.sh"
    echo "  scripts/setup-order-platform-spaces.sh"
    echo ""
    echo "  # Load Docker images"
    echo "  cd app/microservices && ./build.sh && cd ../.."
    echo "  kind load docker-image messagewall-microservice:latest --name workload"
    echo ""
    exit 1
fi
