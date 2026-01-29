#!/bin/bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# All ConfigHub spaces to clean up
CONFIGHUB_SPACES=(
    # Messagewall infrastructure
    messagewall-dev
    messagewall-prod
    # Order Platform - 5 teams × 2 environments
    order-platform-ops-dev
    order-platform-ops-prod
    order-data-dev
    order-data-prod
    order-customer-dev
    order-customer-prod
    order-integrations-dev
    order-integrations-prod
    order-compliance-dev
    order-compliance-prod
)

echo ""
echo "═══════════════════════════════════════════════════════"
echo "  FULL TEARDOWN"
echo "═══════════════════════════════════════════════════════"
echo ""
echo -e "${RED}This will destroy:${NC}"
echo "  • ArgoCD applications (both clusters)"
echo "  • All AWS resources managed by Crossplane"
echo "  • ConfigHub workers, units, and ${#CONFIGHUB_SPACES[@]} spaces:"
for SPACE in "${CONFIGHUB_SPACES[@]}"; do
    echo "      - $SPACE"
done
echo "  • Kind clusters (actuator, workload)"
echo ""
read -p "Are you sure? (yes/no) " -r
if [[ ! $REPLY == "yes" ]]; then
    echo "Aborted."
    exit 0
fi

# ─────────────────────────────────────────────────────────────
# Step 1: Delete ArgoCD applications from BOTH clusters
# This triggers Crossplane to delete resources, which deletes AWS resources
# ─────────────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}Step 1: Delete ArgoCD applications (both clusters)${NC}"
echo "ArgoCD apps keep resources alive via self-heal..."

for CLUSTER in kind-actuator kind-workload; do
    echo ""
    echo "Cluster: $CLUSTER"
    if kubectl get applications -n argocd --context "$CLUSTER" &>/dev/null; then
        APPS=$(kubectl get applications -n argocd --context "$CLUSTER" -o name 2>/dev/null || true)
        if [[ -n "$APPS" ]]; then
            echo "  Deleting ArgoCD applications..."
            kubectl delete applications --all -n argocd --context "$CLUSTER" --wait=true
            # Also delete ApplicationSets if any
            kubectl delete applicationsets --all -n argocd --context "$CLUSTER" --wait=true 2>/dev/null || true
            echo -e "  ${GREEN}ArgoCD applications deleted${NC}"
        else
            echo "  No ArgoCD applications found"
        fi
    else
        echo "  ArgoCD not reachable, skipping"
    fi
done

# ─────────────────────────────────────────────────────────────
# Step 2: Wait for Crossplane to delete AWS resources
# ─────────────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}Step 2: Wait for Crossplane AWS cleanup${NC}"

if kubectl get managed --context kind-actuator &>/dev/null; then
    echo "Waiting for AWS resources to be deleted (up to 5 minutes)..."
    for i in {1..60}; do
        REMAINING=$(kubectl get managed --context kind-actuator --no-headers 2>/dev/null | wc -l | tr -d ' ')
        if [[ "$REMAINING" -eq 0 ]]; then
            echo -e "${GREEN}All Crossplane managed resources deleted${NC}"
            break
        fi

        # Check for stuck resources
        STUCK=$(kubectl get managed --context kind-actuator 2>/dev/null | grep -E 'False.*False' || true)
        if [[ -n "$STUCK" ]]; then
            echo -e "${CYAN}Some resources are stuck. Checking issues...${NC}"
            kubectl get managed --context kind-actuator 2>/dev/null | grep -E 'False.*False' | head -5
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
    REMAINING=$(kubectl get managed --context kind-actuator --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$REMAINING" -gt 0 ]]; then
        echo -e "${YELLOW}Warning: $REMAINING resources still exist${NC}"
        kubectl get managed --context kind-actuator 2>/dev/null
    fi
else
    echo "Actuator cluster not reachable, skipping Crossplane cleanup"
fi

# ─────────────────────────────────────────────────────────────
# Step 3: Delete ConfigHub namespace from BOTH clusters (stops workers)
# ─────────────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}Step 3: Stop ConfigHub workers (both clusters)${NC}"

for CLUSTER in kind-actuator kind-workload; do
    echo ""
    echo "Cluster: $CLUSTER"
    if kubectl get namespace confighub --context "$CLUSTER" &>/dev/null; then
        echo "  Deleting confighub namespace..."
        kubectl delete namespace confighub --context "$CLUSTER" --wait=true
        echo -e "  ${GREEN}ConfigHub namespace deleted${NC}"
    else
        echo "  ConfigHub namespace not found"
    fi
done

echo "Waiting for workers to disconnect..."
sleep 5

# ─────────────────────────────────────────────────────────────
# Step 4: Clean up ALL ConfigHub spaces (12 total)
# Order: workers -> units -> spaces (with retries)
# ─────────────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}Step 4: Clean up ConfigHub (${#CONFIGHUB_SPACES[@]} spaces)${NC}"

if command -v cub &>/dev/null; then
    EXISTING_SPACES=$(cub space list 2>/dev/null || true)

    for SPACE in "${CONFIGHUB_SPACES[@]}"; do
        if echo "$EXISTING_SPACES" | grep -q "^$SPACE "; then
            echo ""
            echo "Cleaning up ConfigHub space: $SPACE"

            # Delete workers
            WORKERS=$(cub worker list --space "$SPACE" 2>/dev/null | tail -n +2 | awk '{print $1}' || true)
            if [[ -n "$WORKERS" ]]; then
                for WORKER in $WORKERS; do
                    echo "  Deleting worker: $WORKER"
                    cub worker delete "$WORKER" --space "$SPACE" 2>/dev/null || true
                done
            fi

            # Delete units
            UNITS=$(cub unit list --space "$SPACE" 2>/dev/null | tail -n +2 | awk '{print $1}' || true)
            if [[ -n "$UNITS" ]]; then
                for UNIT in $UNITS; do
                    echo "  Deleting unit: $UNIT"
                    cub unit delete "$UNIT" --space "$SPACE" 2>/dev/null || true
                done
                # Wait for unit deletions to propagate
                sleep 2
            fi

            # Delete space with retry
            echo "  Deleting space: $SPACE"
            DELETED=false
            for ATTEMPT in 1 2 3; do
                ERROR=$(cub space delete "$SPACE" 2>&1)
                if [[ $? -eq 0 ]]; then
                    DELETED=true
                    break
                fi
                # Check if space is actually gone despite error
                if ! cub space list 2>/dev/null | grep -q "^$SPACE "; then
                    DELETED=true
                    break
                fi
                if [[ $ATTEMPT -lt 3 ]]; then
                    echo "    Retry $ATTEMPT/3 (waiting for resources to clear)..."
                    sleep 3
                fi
            done

            if [[ "$DELETED" == "true" ]]; then
                echo -e "  ${GREEN}Space $SPACE deleted${NC}"
            else
                echo -e "  ${RED}Failed to delete space $SPACE${NC}"
                echo -e "  ${CYAN}Error: $ERROR${NC}"
                echo -e "  ${CYAN}Try: cub space delete $SPACE${NC}"
            fi
        else
            echo "Space $SPACE not found, skipping"
        fi
    done

    # Final verification
    echo ""
    REMAINING=$(cub space list 2>/dev/null | grep -E 'messagewall|order-' || true)
    if [[ -n "$REMAINING" ]]; then
        echo -e "${YELLOW}Remaining spaces (manual cleanup needed):${NC}"
        echo "$REMAINING"
    else
        echo -e "${GREEN}All ConfigHub spaces cleaned up${NC}"
    fi
else
    echo "cub CLI not found, skipping ConfigHub cleanup"
    echo "Manual cleanup required for these spaces:"
    printf '  %s\n' "${CONFIGHUB_SPACES[@]}"
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
echo "To start fresh (see beads/current-focus.md for full guide):"
echo ""
echo "  # 1. Create clusters"
echo "  scripts/bootstrap-kind.sh"
echo "  scripts/bootstrap-workload-cluster.sh"
echo ""
echo "  # 2. Build and load microservice image"
echo "  cd app/microservices && ./build.sh"
echo "  kind load docker-image messagewall-microservice:latest --name workload"
echo ""
echo "  # 3. Install Crossplane and Kyverno on actuator"
echo "  scripts/bootstrap-crossplane.sh"
echo "  scripts/bootstrap-aws-providers.sh"
echo "  scripts/bootstrap-kyverno.sh"
echo ""
echo "  # 4. Install ArgoCD on both clusters"
echo "  scripts/bootstrap-argocd.sh"
echo "  scripts/bootstrap-workload-argocd.sh"
echo ""
echo "  # 5. Configure ConfigHub credentials"
echo "  scripts/setup-argocd-confighub-auth.sh"
echo "  scripts/setup-workload-confighub-auth.sh"
echo ""
echo "  # 6. Create ConfigHub spaces and publish"
echo "  scripts/setup-order-platform-spaces.sh"
echo "  scripts/publish-order-platform.sh --apply"
echo ""
