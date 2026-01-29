#!/bin/bash
# Pre-flight checks before running the demo
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() { echo -e "${GREEN}✓${NC} $1"; }
fail() { echo -e "${RED}✗${NC} $1"; FAILED=true; }
warn() { echo -e "${YELLOW}!${NC} $1"; }

FAILED=false

echo ""
echo "═══════════════════════════════════════════════════════"
echo "  DEMO PRE-FLIGHT CHECKS"
echo "═══════════════════════════════════════════════════════"
echo ""

# Check clusters exist
echo "Clusters:"
if kind get clusters 2>/dev/null | grep -q "^actuator$"; then
    pass "actuator cluster exists"
else
    fail "actuator cluster missing (run: ./scripts/bootstrap-kind.sh)"
fi

if kind get clusters 2>/dev/null | grep -q "^workload$"; then
    pass "workload cluster exists"
else
    fail "workload cluster missing (run: ./scripts/bootstrap-workload-cluster.sh)"
fi

echo ""
echo "Crossplane (actuator cluster):"
CROSSPLANE_RUNNING=$(kubectl get pods -n crossplane-system --context kind-actuator --no-headers 2>/dev/null | grep -c "Running" || true)
if [[ "$CROSSPLANE_RUNNING" -gt 0 ]]; then
    pass "$CROSSPLANE_RUNNING Crossplane pods running"
else
    fail "Crossplane not healthy"
fi

MANAGED_COUNT=$(kubectl get managed --context kind-actuator --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [[ "$MANAGED_COUNT" -gt 0 ]]; then
    pass "$MANAGED_COUNT managed resources found"
else
    warn "No managed resources (AWS infra not deployed - that's OK for workload demo)"
fi

SYNCED_FALSE=$(kubectl get managed --context kind-actuator 2>/dev/null | grep -c "False" || true)
if [[ "$SYNCED_FALSE" -eq 0 ]]; then
    pass "All resources SYNCED=True"
else
    warn "$SYNCED_FALSE resources not synced"
fi

echo ""
echo "Order Platform (workload cluster):"
# Count pods across all Order Platform namespaces (5 teams × 2 envs × 2 services = 20 pods expected)
PODS_RUNNING=$(kubectl get pods --all-namespaces --context kind-workload --no-headers 2>/dev/null | grep -E '^(platform-ops|data|customer|integrations|compliance)' | grep -c "Running" || true)
if [[ "$PODS_RUNNING" -ge 20 ]]; then
    pass "All $PODS_RUNNING Order Platform pods running"
elif [[ "$PODS_RUNNING" -gt 0 ]]; then
    warn "$PODS_RUNNING/20 pods running"
else
    fail "No Order Platform pods running"
fi

APPS_SYNCED=$(kubectl get applications -n argocd --context kind-workload --no-headers 2>/dev/null | grep -c "Synced" || true)
if [[ "$APPS_SYNCED" -ge 10 ]]; then
    pass "$APPS_SYNCED/10 ArgoCD applications synced"
elif [[ "$APPS_SYNCED" -gt 0 ]]; then
    warn "$APPS_SYNCED/10 applications synced"
else
    fail "No ArgoCD applications synced"
fi

echo ""
echo "AWS Access:"
if aws sts get-caller-identity &>/dev/null; then
    ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
    pass "AWS credentials valid (account: $ACCOUNT)"
else
    fail "AWS credentials not configured"
fi

LAMBDA_COUNT=$(aws lambda list-functions --query 'Functions[?starts_with(FunctionName, `messagewall`)].FunctionName' --output text 2>/dev/null | wc -w | tr -d ' ')
if [[ "$LAMBDA_COUNT" -ge 2 ]]; then
    pass "$LAMBDA_COUNT messagewall Lambda functions found"
else
    warn "Only $LAMBDA_COUNT Lambda functions found (expected 2+)"
fi

echo ""
echo "═══════════════════════════════════════════════════════"

if [[ "$FAILED" == "true" ]]; then
    echo -e "${RED}PRE-FLIGHT FAILED${NC} — Fix issues above before demo"
    echo ""
    exit 1
else
    echo -e "${GREEN}PRE-FLIGHT PASSED${NC} — Ready for demo!"
    echo ""
    echo "Next steps:"
    echo "  1. Restart providers (recommended):"
    echo "     kubectl rollout restart deployment -n crossplane-system --context kind-actuator"
    echo ""
    echo "  2. Open demo layout:"
    echo "     ./scripts/demo-iterm-layout.sh"
    echo ""
    echo "  3. Follow the runbook:"
    echo "     cat scripts/DEMO-RUNBOOK.md"
    echo ""
fi
