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

print_narrator "Two clusters: kind-actuator (Crossplane) and kind-workload (microservices)"

pause

print_header "STEP 2: Actuator Cluster - Crossplane Controllers"

print_step "kubectl get pods -n crossplane-system --context kind-actuator"
kubectl get pods -n crossplane-system --context kind-actuator 2>/dev/null || echo "(Crossplane not installed - run bootstrap scripts first)"

print_narrator "Crossplane controllers manage AWS resources declaratively"

pause

print_header "STEP 3: Workload Cluster - Observable Microservices"

print_step "kubectl get pods -n microservices --context kind-workload"
kubectl get pods -n microservices --context kind-workload 2>/dev/null || echo "(Microservices not deployed - publish to ConfigHub first)"

print_narrator "10 distinct microservices, each with unique logging behavior"

pause

print_header "STEP 4: Watch Microservice Activity"

print_narrator "Each microservice logs sparse, distinct messages"
print_narrator "Watch logs from multiple services (Ctrl+C to stop):"

echo ""
echo "Examples:"
echo "  kubectl logs -f deployment/heartbeat -n microservices --context kind-workload"
echo "  kubectl logs -f deployment/counter -n microservices --context kind-workload"
echo "  kubectl logs -f deployment/quoter -n microservices --context kind-workload"
echo ""

read -p "Watch heartbeat logs? (y/N) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    print_step "kubectl logs -f deployment/heartbeat -n microservices --context kind-workload"
    timeout 30 kubectl logs -f deployment/heartbeat -n microservices --context kind-workload 2>/dev/null || true
fi

pause

print_header "STEP 5: ConfigHub - The Single Authority"

print_narrator "Both clusters sync from ConfigHub spaces:"
echo ""
echo "  messagewall-dev        → actuator cluster (Crossplane resources)"
echo "  messagewall-workloads  → workload cluster (microservices)"
echo ""

print_step "cub space list"
cub space list 2>/dev/null || echo "(Run: cub auth login)"

pause

print_header "STEP 6: ArgoCD Sync Status"

print_step "Actuator cluster ArgoCD:"
kubectl get application -n argocd --context kind-actuator 2>/dev/null || echo "(ArgoCD not installed)"

echo ""

print_step "Workload cluster ArgoCD:"
kubectl get application -n argocd --context kind-workload 2>/dev/null || echo "(ArgoCD not installed)"

print_narrator "Both clusters sync from ConfigHub via ArgoCD CMP plugin"

pause

print_header "STEP 7: Demonstrate Bulk Change via ConfigHub"

print_narrator "A change in ConfigHub propagates to all affected clusters"
echo ""
echo "Example: Update LOG_INTERVAL for all microservices"
echo ""
echo "  # Edit the manifest"
echo "  vi infra/workloads/heartbeat.yaml"
echo ""
echo "  # Publish to ConfigHub"
echo "  cub unit update --space messagewall-workloads heartbeat --file infra/workloads/heartbeat.yaml"
echo "  cub unit apply --space messagewall-workloads heartbeat"
echo ""
echo "  # Watch ArgoCD sync"
echo "  kubectl get application messagewall-workloads -n argocd --context kind-workload -w"
echo ""

pause

print_header "DEMO COMPLETE"

cat <<'EOF'

Key Takeaways:

  1. ConfigHub is the SINGLE AUTHORITY for all configuration
     - Infrastructure (Crossplane) and workloads (pods) in one system

  2. Multiple clusters sync from ConfigHub
     - Each cluster has ArgoCD + CMP plugin
     - Changes flow from ConfigHub to clusters automatically

  3. Observable microservices make activity visible
     - 10 distinct pods with unique logging
     - Easy to see in kubectl get pods / logs

  4. Crossplane reconciles AWS resources
     - See demo-reconciliation.sh for self-healing demo

Next Steps:
  - Run scripts/demo-reconciliation.sh to see Crossplane self-healing
  - Make a bulk change in ConfigHub and watch it propagate

EOF
