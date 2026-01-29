#!/bin/bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

KUBE_CONTEXT="${KUBE_CONTEXT:-kind-actuator}"
CONFIGHUB_SPACES="${CONFIGHUB_SPACES:-messagewall-dev messagewall-prod}"

echo ""
echo "═══════════════════════════════════════════════════════"
echo "  FULL TEARDOWN"
echo "═══════════════════════════════════════════════════════"
echo ""
echo -e "${RED}This will destroy:${NC}"
echo "  • ArgoCD applications"
echo "  • All AWS resources managed by Crossplane"
echo "  • ConfigHub workers, units, and spaces"
echo "  • Kind clusters (actuator, workload)"
echo ""
read -p "Are you sure? (yes/no) " -r
if [[ ! $REPLY == "yes" ]]; then
    echo "Aborted."
    exit 0
fi

# ─────────────────────────────────────────────────────────────
# Step 1: Delete ArgoCD applications
# This triggers Crossplane to delete resources, which deletes AWS resources
# ─────────────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}Step 1: Delete ArgoCD applications${NC}"
echo "ArgoCD apps keep Crossplane resources alive via self-heal..."

if kubectl get applications -n argocd --context "$KUBE_CONTEXT" &>/dev/null; then
    APPS=$(kubectl get applications -n argocd --context "$KUBE_CONTEXT" -o name 2>/dev/null || true)
    if [[ -n "$APPS" ]]; then
        echo "Deleting ArgoCD applications..."
        kubectl delete applications --all -n argocd --context "$KUBE_CONTEXT" --wait=true
        echo -e "${GREEN}ArgoCD applications deleted${NC}"
    else
        echo "No ArgoCD applications found"
    fi
else
    echo "ArgoCD not reachable, skipping"
fi

# ─────────────────────────────────────────────────────────────
# Step 2: Wait for Crossplane to delete AWS resources
# ─────────────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}Step 2: Wait for Crossplane AWS cleanup${NC}"

if kubectl get managed --context "$KUBE_CONTEXT" &>/dev/null; then
    echo "Waiting for AWS resources to be deleted (up to 5 minutes)..."
    for i in {1..60}; do
        REMAINING=$(kubectl get managed --context "$KUBE_CONTEXT" --no-headers 2>/dev/null | wc -l | tr -d ' ')
        if [[ "$REMAINING" -eq 0 ]]; then
            echo -e "${GREEN}All Crossplane managed resources deleted${NC}"
            break
        fi

        # Check for stuck resources
        STUCK=$(kubectl get managed --context "$KUBE_CONTEXT" 2>/dev/null | grep -E 'False.*False' || true)
        if [[ -n "$STUCK" ]]; then
            echo -e "${CYAN}Some resources are stuck. Checking issues...${NC}"
            kubectl get managed --context "$KUBE_CONTEXT" 2>/dev/null | grep -E 'False.*False' | head -5
            echo ""
            echo -e "${CYAN}Common fixes:${NC}"
            echo "  • S3 buckets not empty: aws s3 rm s3://BUCKET --recursive"
            echo "  • IAM permission missing: check iam:ListInstanceProfilesForRole"
            echo ""
        fi

        echo "  $REMAINING resources remaining..."
        sleep 5
    done

    # Final check
    REMAINING=$(kubectl get managed --context "$KUBE_CONTEXT" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$REMAINING" -gt 0 ]]; then
        echo -e "${YELLOW}Warning: $REMAINING resources still exist${NC}"
        kubectl get managed --context "$KUBE_CONTEXT" 2>/dev/null
    fi
else
    echo "Actuator cluster not reachable, skipping Crossplane cleanup"
fi

# ─────────────────────────────────────────────────────────────
# Step 3: Delete ConfigHub namespace (stops workers)
# ─────────────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}Step 3: Stop ConfigHub workers in cluster${NC}"

if kubectl get namespace confighub --context "$KUBE_CONTEXT" &>/dev/null; then
    echo "Deleting confighub namespace..."
    kubectl delete namespace confighub --context "$KUBE_CONTEXT" --wait=true
    echo -e "${GREEN}ConfigHub namespace deleted${NC}"
    echo "Waiting for workers to disconnect..."
    sleep 5
else
    echo "ConfigHub namespace not found"
fi

# ─────────────────────────────────────────────────────────────
# Step 4: Clean up ConfigHub spaces
# Order: workers -> units -> spaces
# ─────────────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}Step 4: Clean up ConfigHub${NC}"

if command -v cub &>/dev/null; then
    for SPACE in $CONFIGHUB_SPACES; do
        if cub space list 2>/dev/null | grep -q "^$SPACE "; then
            echo "Cleaning up ConfigHub space: $SPACE"

            # Delete workers
            WORKERS=$(cub worker list --space "$SPACE" 2>/dev/null | tail -n +2 | awk '{print $1}' || true)
            for WORKER in $WORKERS; do
                echo "  Deleting worker: $WORKER"
                cub worker delete "$WORKER" --space "$SPACE" 2>/dev/null || true
            done

            # Delete units
            UNITS=$(cub unit list --space "$SPACE" 2>/dev/null | tail -n +2 | awk '{print $1}' || true)
            for UNIT in $UNITS; do
                echo "  Deleting unit: $UNIT"
                cub unit delete "$UNIT" --space "$SPACE" 2>/dev/null || true
            done

            # Delete space
            echo "  Deleting space: $SPACE"
            if cub space delete "$SPACE" 2>/dev/null; then
                echo -e "  ${GREEN}Space $SPACE deleted${NC}"
            else
                echo -e "  ${RED}Failed to delete space $SPACE${NC}"
            fi
        else
            echo "Space $SPACE not found, skipping"
        fi
    done
else
    echo "cub CLI not found, skipping ConfigHub cleanup"
    echo "Manual cleanup: cub space delete <space-name>"
fi

# ─────────────────────────────────────────────────────────────
# Step 5: Delete kind clusters
# ─────────────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}Step 5: Delete kind clusters${NC}"

if kind get clusters 2>/dev/null | grep -q "^workload$"; then
    echo "Deleting workload cluster..."
    kind delete cluster --name workload
    echo -e "${GREEN}Workload cluster deleted${NC}"
else
    echo "Workload cluster not found"
fi

if kind get clusters 2>/dev/null | grep -q "^actuator$"; then
    echo "Deleting actuator cluster..."
    kind delete cluster --name actuator
    echo -e "${GREEN}Actuator cluster deleted${NC}"
else
    echo "Actuator cluster not found"
fi

# ─────────────────────────────────────────────────────────────
# Step 6: Verify AWS resources are gone
# ─────────────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}Step 6: Verify AWS cleanup${NC}"

LAMBDAS=$(aws lambda list-functions --query 'Functions[?starts_with(FunctionName, `messagewall`)].FunctionName' --output text 2>/dev/null || true)
if [[ -n "$LAMBDAS" && "$LAMBDAS" != "None" ]]; then
    echo -e "${RED}Remaining Lambda functions:${NC} $LAMBDAS"
else
    echo -e "${GREEN}No Lambda functions${NC}"
fi

TABLES=$(aws dynamodb list-tables --query 'TableNames[?starts_with(@, `messagewall`)]' --output text 2>/dev/null || true)
if [[ -n "$TABLES" && "$TABLES" != "None" ]]; then
    echo -e "${RED}Remaining DynamoDB tables:${NC} $TABLES"
else
    echo -e "${GREEN}No DynamoDB tables${NC}"
fi

BUCKETS=$(aws s3 ls 2>/dev/null | grep messagewall | awk '{print $3}' || true)
if [[ -n "$BUCKETS" ]]; then
    echo -e "${RED}Remaining S3 buckets:${NC} $BUCKETS"
else
    echo -e "${GREEN}No S3 buckets${NC}"
fi

ROLES=$(aws iam list-roles --query 'Roles[?starts_with(RoleName, `messagewall`)].RoleName' --output text 2>/dev/null || true)
if [[ -n "$ROLES" && "$ROLES" != "None" ]]; then
    echo -e "${RED}Remaining IAM roles:${NC} $ROLES"
else
    echo -e "${GREEN}No IAM roles${NC}"
fi

RULES=$(aws events list-rules --query 'Rules[?starts_with(Name, `messagewall`)].Name' --output text 2>/dev/null || true)
if [[ -n "$RULES" && "$RULES" != "None" ]]; then
    echo -e "${RED}Remaining EventBridge rules:${NC} $RULES"
else
    echo -e "${GREEN}No EventBridge rules${NC}"
fi

echo ""
echo "═══════════════════════════════════════════════════════"
echo -e "${GREEN}TEARDOWN COMPLETE${NC}"
echo "═══════════════════════════════════════════════════════"
echo ""
echo "To start fresh:"
echo "  ./scripts/bootstrap-kind.sh"
echo "  ./scripts/bootstrap-crossplane.sh"
echo "  ./scripts/bootstrap-aws-providers.sh"
echo ""
