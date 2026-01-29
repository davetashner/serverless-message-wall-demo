#!/bin/bash
# demo-preflight.sh - Pre-flight checks before running the demo
#
# Run this before presenting to ensure everything is ready.
# Exit code 0 = all checks passed, non-zero = something needs attention.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "${SCRIPT_DIR}")"
STATE_FILE="${PROJECT_ROOT}/.setup-state.json"
CLUSTER_CONTEXT="kind-actuator"

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
echo "  DEMO PRE-FLIGHT CHECKS"
echo "═══════════════════════════════════════════════════════"
echo ""

#------------------------------------------------------------------------------
# 1. Configuration
#------------------------------------------------------------------------------
echo -e "${BOLD}Configuration:${NC}"

if [[ -f "${STATE_FILE}" ]]; then
    pass "Setup state file exists"
    AWS_REGION=$(grep '"aws_region"' "${STATE_FILE}" | sed 's/.*: *"//' | sed 's/".*//')
    BUCKET_NAME=$(grep '"bucket_name"' "${STATE_FILE}" | sed 's/.*: *"//' | sed 's/".*//')
    RESOURCE_PREFIX=$(grep '"resource_prefix"' "${STATE_FILE}" | sed 's/.*: *"//' | sed 's/".*//')
    info "Region: ${AWS_REGION}, Bucket: ${BUCKET_NAME}"
else
    fail "Setup state file missing (run: ./scripts/setup.sh)"
    AWS_REGION="us-east-1"
    BUCKET_NAME="messagewall-dev"
    RESOURCE_PREFIX="messagewall"
fi

echo ""

#------------------------------------------------------------------------------
# 2. Clusters
#------------------------------------------------------------------------------
echo -e "${BOLD}Clusters:${NC}"

if kind get clusters 2>/dev/null | grep -q "^actuator$"; then
    pass "actuator cluster exists"
else
    fail "actuator cluster missing (run: ./scripts/bootstrap-kind.sh)"
fi

# Workload cluster is optional (for Order Platform demo)
if kind get clusters 2>/dev/null | grep -q "^workload$"; then
    pass "workload cluster exists (Order Platform demo ready)"
else
    info "workload cluster not found (optional - for Order Platform demo)"
fi

echo ""

#------------------------------------------------------------------------------
# 3. Crossplane (actuator cluster)
#------------------------------------------------------------------------------
echo -e "${BOLD}Crossplane (actuator cluster):${NC}"

CROSSPLANE_RUNNING=$(kubectl get pods -n crossplane-system --context kind-actuator --no-headers 2>/dev/null | grep -c "Running" || true)
if [[ "$CROSSPLANE_RUNNING" -gt 0 ]]; then
    pass "$CROSSPLANE_RUNNING Crossplane pods running"
else
    fail "Crossplane not healthy (run: ./scripts/bootstrap-crossplane.sh)"
fi

# Check providers
PROVIDER_OUTPUT=$(kubectl get providers.pkg.crossplane.io --context "${CLUSTER_CONTEXT}" 2>/dev/null || true)
PROVIDER_COUNT=$(echo "$PROVIDER_OUTPUT" | grep -c "True.*True" || true)
if [[ "$PROVIDER_COUNT" -gt 0 ]]; then
    pass "$PROVIDER_COUNT AWS providers healthy"
else
    fail "Crossplane providers not healthy (run: ./scripts/bootstrap-aws-providers.sh)"
fi

# Check managed resources
MANAGED_COUNT=$(kubectl get managed --context kind-actuator --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [[ "$MANAGED_COUNT" -gt 0 ]]; then
    pass "$MANAGED_COUNT managed AWS resources"
else
    warn "No managed resources (run: ./scripts/deploy-dev.sh)"
fi

SYNCED_FALSE=$(kubectl get managed --context kind-actuator 2>/dev/null | grep -c "False" || true)
if [[ "$SYNCED_FALSE" -eq 0 ]]; then
    pass "All resources SYNCED=True"
else
    warn "$SYNCED_FALSE resources not synced"
fi

echo ""

#------------------------------------------------------------------------------
# 4. Kyverno
#------------------------------------------------------------------------------
echo -e "${BOLD}Kyverno:${NC}"

KYVERNO_OUTPUT=$(kubectl get pods -n kyverno --context "${CLUSTER_CONTEXT}" --no-headers 2>/dev/null || true)
KYVERNO_PODS=$(echo "$KYVERNO_OUTPUT" | grep -c "Running" || true)
if [[ "$KYVERNO_PODS" -gt 0 ]]; then
    pass "$KYVERNO_PODS Kyverno pods running"
else
    fail "Kyverno not running (run: ./scripts/bootstrap-kyverno.sh)"
fi

POLICY_COUNT=$(kubectl get clusterpolicy --context "${CLUSTER_CONTEXT}" 2>/dev/null | grep -c "True" || echo 0)
if [[ ${POLICY_COUNT} -gt 0 ]]; then
    pass "$POLICY_COUNT Kyverno policies loaded"
else
    warn "No Kyverno policies (run: kubectl apply -f platform/kyverno/policies/)"
fi

echo ""

#------------------------------------------------------------------------------
# 5. AWS Access & Resources
#------------------------------------------------------------------------------
echo -e "${BOLD}AWS Access:${NC}"

if aws sts get-caller-identity &>/dev/null; then
    ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
    pass "AWS credentials valid (account: $ACCOUNT)"
else
    fail "AWS credentials not configured"
fi

# Check S3 bucket
if aws s3 ls "s3://${BUCKET_NAME}" &> /dev/null; then
    pass "S3 bucket exists: ${BUCKET_NAME}"
else
    fail "S3 bucket not found: ${BUCKET_NAME}"
fi

# Check website accessibility
WEBSITE_URL="http://${BUCKET_NAME}.s3-website-${AWS_REGION}.amazonaws.com/"
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "${WEBSITE_URL}" 2>/dev/null || echo "000")
if [[ "${HTTP_CODE}" == "200" ]]; then
    pass "Website accessible (HTTP 200)"
else
    warn "Website returned HTTP ${HTTP_CODE}"
fi

# Check Lambda functions
LAMBDA_COUNT=$(aws lambda list-functions --query 'Functions[?starts_with(FunctionName, `messagewall`)].FunctionName' --output text 2>/dev/null | wc -w | tr -d ' ')
if [[ "$LAMBDA_COUNT" -ge 2 ]]; then
    pass "$LAMBDA_COUNT messagewall Lambda functions"
else
    warn "Only $LAMBDA_COUNT Lambda functions (expected 2)"
fi

# Check Function URL
if kubectl get functionurl "${RESOURCE_PREFIX}-api-handler-url" --context "${CLUSTER_CONTEXT}" &> /dev/null; then
    API_URL=$(kubectl get functionurl "${RESOURCE_PREFIX}-api-handler-url" \
        -o jsonpath='{.status.atProvider.functionUrl}' \
        --context "${CLUSTER_CONTEXT}" 2>/dev/null || true)
    if [[ -n "${API_URL}" ]]; then
        pass "Function URL ready"
        info "API: ${API_URL}"
    else
        warn "Function URL exists but not ready"
    fi
else
    fail "Function URL not found"
fi

echo ""

#------------------------------------------------------------------------------
# 6. ConfigHub
#------------------------------------------------------------------------------
echo -e "${BOLD}ConfigHub:${NC}"

CONFIGHUB_SPACE="messagewall-dev"

if ! command -v cub &> /dev/null; then
    fail "cub CLI not installed"
else
    pass "cub CLI installed"

    if cub auth status &> /dev/null; then
        pass "ConfigHub authenticated"
    else
        fail "Not authenticated (run: cub auth login)"
    fi

    SPACE_OUTPUT=$(cub space list 2>/dev/null || true)
    if echo "$SPACE_OUTPUT" | grep -q "${CONFIGHUB_SPACE}"; then
        pass "Space '${CONFIGHUB_SPACE}' exists"
    else
        fail "Space '${CONFIGHUB_SPACE}' not found"
    fi

    UNIT_OUTPUT=$(cub unit list --space "${CONFIGHUB_SPACE}" 2>/dev/null || true)
    if echo "$UNIT_OUTPUT" | grep -q "lambda"; then
        pass "Lambda unit exists in ConfigHub"
    else
        fail "Lambda unit not found in ConfigHub"
    fi
fi

echo ""

#------------------------------------------------------------------------------
# 7. Order Platform (optional)
#------------------------------------------------------------------------------
if kind get clusters 2>/dev/null | grep -q "^workload$"; then
    echo -e "${BOLD}Order Platform (workload cluster):${NC}"

    PODS_RUNNING=$(kubectl get pods --all-namespaces --context kind-workload --no-headers 2>/dev/null | grep -E '^(platform-ops|data|customer|integrations|compliance)' | grep -c "Running" || true)
    if [[ "$PODS_RUNNING" -ge 20 ]]; then
        pass "All $PODS_RUNNING Order Platform pods running"
    elif [[ "$PODS_RUNNING" -gt 0 ]]; then
        warn "$PODS_RUNNING/20 pods running"
    else
        warn "No Order Platform pods running"
    fi

    APPS_SYNCED=$(kubectl get applications -n argocd --context kind-workload --no-headers 2>/dev/null | grep -c "Synced" || true)
    if [[ "$APPS_SYNCED" -ge 10 ]]; then
        pass "$APPS_SYNCED/10 ArgoCD applications synced"
    elif [[ "$APPS_SYNCED" -gt 0 ]]; then
        warn "$APPS_SYNCED/10 applications synced"
    else
        warn "No ArgoCD applications synced"
    fi

    echo ""
fi

#------------------------------------------------------------------------------
# Summary
#------------------------------------------------------------------------------
echo "═══════════════════════════════════════════════════════"

if [[ ${ERRORS} -eq 0 && ${WARNINGS} -eq 0 ]]; then
    echo -e "${GREEN}PRE-FLIGHT PASSED${NC} — All systems ready!"
    echo ""
    echo "Next steps:"
    echo "  1. Load environment: source ./scripts/demo-env.sh"
    echo "  2. Open demo script:  cat docs/demo-script.md"
    echo ""
    exit 0
elif [[ ${ERRORS} -eq 0 ]]; then
    echo -e "${YELLOW}PRE-FLIGHT PASSED WITH WARNINGS${NC} — Demo should work"
    echo ""
    exit 0
else
    echo -e "${RED}PRE-FLIGHT FAILED${NC} — ${ERRORS} error(s), fix before demo"
    echo ""
    echo "Quick fixes:"
    echo "  ./scripts/setup.sh              # Generate config"
    echo "  ./scripts/bootstrap-kind.sh     # Create cluster"
    echo "  ./scripts/deploy-dev.sh         # Deploy AWS resources"
    echo "  cub auth login                  # Authenticate ConfigHub"
    echo ""
    exit 1
fi
