#!/bin/bash
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

print_header() {
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

print_step() {
    echo ""
    echo -e "${GREEN}▶ $1${NC}"
}

print_narrator() {
    echo -e "${YELLOW}   $1${NC}"
}

pause() {
    echo ""
    read -p "Press Enter to continue..."
}

cat <<'EOF'

╔═══════════════════════════════════════════════════════════════════╗
║           MULTI-CLUSTER CONFIGHUB DEMO                            ║
║                                                                   ║
║  This demo shows ConfigHub managing TWO Kubernetes clusters:      ║
║                                                                   ║
║    • actuator cluster  - Crossplane managing AWS infrastructure   ║
║    • workload cluster  - Microservices running as pods            ║
║                                                                   ║
║  One ConfigHub. Multiple actuators. Unified control.              ║
╚═══════════════════════════════════════════════════════════════════╝

EOF

pause

print_header "STEP 1: Show Available Clusters"

print_step "kubectl config get-contexts"
kubectl config get-contexts

print_narrator "Actuator clusters (Crossplane) and optionally kind-workload (microservices for Parts 8-9)"

pause

print_header "STEP 2: Actuator Cluster - Crossplane Controllers"

print_step "kubectl get pods -n crossplane-system --context kind-actuator-east"
kubectl get pods -n crossplane-system --context kind-actuator-east 2>/dev/null || echo "(Crossplane not installed - run bootstrap scripts first)"

print_narrator "Crossplane controllers manage AWS resources declaratively"

pause

print_header "STEP 3: Workload Cluster - Order Platform Microservices"

print_step "kubectl get pods --all-namespaces --context kind-workload | grep -E '^(platform|data|customer|integrations|compliance)'"
kubectl get pods --all-namespaces --context kind-workload 2>/dev/null | grep -E '^(platform|data|customer|integrations|compliance)' || echo "(Microservices not deployed - publish to ConfigHub first)"

print_narrator "20 microservices across 5 teams × 2 environments (dev/prod)"

pause

print_header "STEP 4: Watch Microservice Activity"

print_narrator "Each microservice logs sparse, distinct messages"
print_narrator "Watch logs from multiple services (Ctrl+C to stop):"

echo ""
echo "Examples:"
echo "  kubectl logs -f deployment/heartbeat -n platform-ops-dev --context kind-workload"
echo "  kubectl logs -f deployment/counter -n data-dev --context kind-workload"
echo "  kubectl logs -f deployment/quoter -n compliance-dev --context kind-workload"
echo ""

read -p "Watch heartbeat logs? (y/N) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    print_step "kubectl logs -f deployment/heartbeat -n platform-ops-dev --context kind-workload"
    timeout 30 kubectl logs -f deployment/heartbeat -n platform-ops-dev --context kind-workload 2>/dev/null || true
fi

pause

print_header "STEP 5: ConfigHub - The Single Authority"

print_narrator "Both clusters sync from ConfigHub spaces:"
echo ""
echo "  Infrastructure (actuator cluster):"
echo "    messagewall-dev          → Crossplane AWS resources"
echo ""
echo "  Order Platform (workload cluster) - 10 spaces:"
echo "    order-platform-ops-dev   → platform-ops team dev namespace"
echo "    order-data-dev           → data team dev namespace"
echo "    order-customer-dev       → customer team dev namespace"
echo "    order-integrations-dev   → integrations team dev namespace"
echo "    order-compliance-dev     → compliance team dev namespace"
echo "    (+ 5 prod spaces)"
echo ""

print_step "cub space list | grep -E '(messagewall|order-)'"
cub space list 2>/dev/null | grep -E '(messagewall|order-)' || echo "(Run: cub auth login)"

pause

print_header "STEP 6: ArgoCD Sync Status"

print_step "Actuator cluster ArgoCD:"
kubectl get application -n argocd --context kind-actuator-east 2>/dev/null || echo "(ArgoCD not installed)"

echo ""

print_step "Workload cluster ArgoCD:"
kubectl get application -n argocd --context kind-workload 2>/dev/null || echo "(ArgoCD not installed)"

print_narrator "Both clusters sync from ConfigHub via ArgoCD CMP plugin"

pause

print_header "STEP 7: Demonstrate Bulk Change via ConfigHub"

print_narrator "A change in ConfigHub propagates to all affected clusters"
echo ""
echo "Example: Update LOG_INTERVAL for all dev environments"
echo ""
echo "  # Edit the manifests"
echo "  vi infra/order-platform/platform-ops/dev/heartbeat.yaml"
echo ""
echo "  # Publish changes to all dev spaces"
echo "  ./scripts/publish-order-platform.sh --env dev --apply"
echo ""
echo "  # Watch ArgoCD sync all dev applications"
echo "  kubectl get applications -n argocd --context kind-workload -w"
echo ""
echo "Or update ALL environments at once:"
echo "  ./scripts/publish-order-platform.sh --apply"
echo ""

pause

print_header "DEMO COMPLETE"

cat <<'EOF'

Key Takeaways:

  1. ConfigHub is the SINGLE AUTHORITY for all configuration
     - Infrastructure (Crossplane) and workloads (pods) in one system

  2. Multi-tenant organization
     - 5 teams × 2 environments = 10 ConfigHub spaces
     - Each team owns their own space (isolation)
     - Labels enable bulk operations across spaces

  3. Multiple clusters sync from ConfigHub
     - Each cluster has ArgoCD + CMP plugin
     - Changes flow from ConfigHub to clusters automatically

  4. Observable microservices make activity visible
     - 20 pods across 5 teams (dev + prod)
     - Easy to see in kubectl get pods / logs

  5. Crossplane reconciles AWS resources
     - See demo-reconciliation.sh for self-healing demo

Next Steps:
  - Run scripts/demo-reconciliation.sh to see Crossplane self-healing
  - Make a bulk change with: ./scripts/publish-order-platform.sh --apply

EOF
