#!/bin/bash
# Full teardown of messagewall demo
#
# This script:
#   1. Deletes Crossplane Claims (triggers AWS resource deletion)
#   2. Deletes ArgoCD applications (both clusters)
#   3. Waits for Crossplane to delete AWS resources
#   4. Cleans up ConfigHub spaces
#   5. Deletes kind clusters
#   6. Verifies AWS cleanup (optionally force-deletes orphans)
#
# Usage:
#   ./scripts/teardown-all.sh [--force-aws] [--yes]
#
# Options:
#   --force-aws   Force delete orphaned AWS resources via CLI
#   --yes         Skip confirmation prompt

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

FORCE_AWS=false
SKIP_CONFIRM=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --force-aws)
            FORCE_AWS=true
            shift
            ;;
        --yes)
            SKIP_CONFIRM=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--force-aws] [--yes]"
            exit 1
            ;;
    esac
done

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
echo "  • Crossplane Claims (triggers AWS resource deletion)"
echo "  • ArgoCD applications (both clusters)"
echo "  • All AWS resources managed by Crossplane"
echo "  • ConfigHub workers, units, and ${#CONFIGHUB_SPACES[@]} spaces"
echo "  • Kind clusters (actuator, workload)"
if [[ "$FORCE_AWS" == "true" ]]; then
    echo -e "  • ${YELLOW}Force delete any orphaned AWS resources${NC}"
fi
echo ""

if [[ "$SKIP_CONFIRM" != "true" ]]; then
    read -p "Are you sure? (yes/no) " -r
    if [[ ! $REPLY == "yes" ]]; then
        echo "Aborted."
        exit 0
    fi
fi

# ─────────────────────────────────────────────────────────────
# Step 1: Delete Crossplane Claims (MUST happen before cluster deletion)
# This triggers Crossplane to delete the composed AWS resources
# ─────────────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}Step 1: Delete Crossplane Claims${NC}"
echo "This triggers deletion of AWS resources..."

if kubectl get crd serverlesseventappclaims.messagewall.demo --context kind-actuator &>/dev/null; then
    # Delete all ServerlessEventAppClaims
    CLAIMS=$(kubectl get serverlesseventappclaim --all-namespaces --context kind-actuator -o name 2>/dev/null || true)
    if [[ -n "$CLAIMS" ]]; then
        echo "  Deleting Claims:"
        echo "$CLAIMS" | while read -r claim; do
            echo "    - $claim"
        done
        kubectl delete serverlesseventappclaim --all --all-namespaces --context kind-actuator --wait=false
        echo -e "  ${GREEN}Claims deleted${NC}"
    else
        echo "  No Claims found"
    fi
else
    echo "  ServerlessEventAppClaim CRD not installed"
fi

# Also delete any orphaned CompositeResources (XRs) not managed by Claims
if kubectl get crd serverlesseventapps.messagewall.demo --context kind-actuator &>/dev/null; then
    XRS=$(kubectl get serverlesseventapp --context kind-actuator -o name 2>/dev/null || true)
    if [[ -n "$XRS" ]]; then
        echo "  Deleting CompositeResources..."
        kubectl delete serverlesseventapp --all --context kind-actuator --wait=false
    fi
fi

echo ""

# ─────────────────────────────────────────────────────────────
# Step 2: Delete ArgoCD applications from BOTH clusters
# ─────────────────────────────────────────────────────────────
echo -e "${YELLOW}Step 2: Delete ArgoCD applications (both clusters)${NC}"
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
# Step 3: Wait for Crossplane to delete AWS resources
# ─────────────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}Step 3: Wait for Crossplane AWS cleanup${NC}"

# Helper function to empty stuck S3 buckets
empty_stuck_s3_buckets() {
    local stuck_buckets
    # Find S3 bucket resources that are stuck (SYNCED=False, READY=False)
    stuck_buckets=$(kubectl get managed --context kind-actuator 2>/dev/null | grep 'bucket.s3' | grep -E 'False.*False' | awk '{print $3}' || true)
    if [[ -n "$stuck_buckets" ]]; then
        for bucket in $stuck_buckets; do
            if [[ -n "$bucket" && "$bucket" != "EXTERNAL-NAME" ]]; then
                echo -e "  ${CYAN}Emptying stuck S3 bucket: $bucket${NC}"
                aws s3 rm "s3://$bucket" --recursive 2>/dev/null || true
            fi
        done
    fi
}

if kubectl get managed --context kind-actuator &>/dev/null; then
    echo "Waiting for AWS resources to be deleted (up to 2 minutes)..."
    SHOWN_STUCK_DIAGNOSTIC=false
    EMPTIED_BUCKETS=false

    for i in {1..24}; do
        REMAINING=$(kubectl get managed --context kind-actuator --no-headers 2>/dev/null | wc -l | tr -d ' ')
        if [[ "$REMAINING" -eq 0 ]]; then
            echo -e "\n${GREEN}All Crossplane managed resources deleted${NC}"
            break
        fi

        # Check for stuck resources
        STUCK=$(kubectl get managed --context kind-actuator 2>/dev/null | grep -E 'False.*False' || true)
        if [[ -n "$STUCK" ]]; then
            # Show diagnostic only once
            if [[ "$SHOWN_STUCK_DIAGNOSTIC" == "false" ]]; then
                echo ""
                echo -e "${CYAN}Some resources are stuck:${NC}"
                kubectl get managed --context kind-actuator 2>/dev/null | grep -E 'False.*False' | head -5
                echo ""
                SHOWN_STUCK_DIAGNOSTIC=true
            fi

            # Proactively empty S3 buckets (only try once)
            if [[ "$EMPTIED_BUCKETS" == "false" ]]; then
                empty_stuck_s3_buckets
                EMPTIED_BUCKETS=true
            fi
        fi

        # Simple progress indicator
        ELAPSED=$((i * 5))
        printf "\r  %d resources remaining... (%ds)" "$REMAINING" "$ELAPSED"
        sleep 5
    done
    echo ""  # Clear the progress line

    # Final check
    REMAINING=$(kubectl get managed --context kind-actuator --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$REMAINING" -gt 0 ]]; then
        echo -e "${YELLOW}Warning: $REMAINING resources still exist${NC}"
        kubectl get managed --context kind-actuator 2>/dev/null
        echo ""
        if [[ "$FORCE_AWS" == "true" ]]; then
            echo -e "${YELLOW}Will force-delete after cluster teardown...${NC}"
        else
            echo -e "${CYAN}Tip: Run with --force-aws to delete orphaned resources${NC}"
        fi
    fi
else
    echo "Actuator cluster not reachable, skipping Crossplane cleanup"
fi

# ─────────────────────────────────────────────────────────────
# Step 4: Delete ConfigHub namespace from BOTH clusters (stops workers)
# ─────────────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}Step 4: Stop ConfigHub workers (both clusters)${NC}"

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
# Step 5: Clean up ALL ConfigHub spaces (12 total)
# Order: workers -> units -> spaces (with retries)
# ─────────────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}Step 5: Clean up ConfigHub (${#CONFIGHUB_SPACES[@]} spaces)${NC}"

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
# Step 6: Delete kind clusters
# ─────────────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}Step 6: Delete kind clusters${NC}"

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
# Step 7: Verify AWS resources are gone (and optionally force-delete)
# ─────────────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}Step 7: Verify AWS cleanup${NC}"

AWS_ORPHANS=false

LAMBDAS=$(aws lambda list-functions --query 'Functions[?starts_with(FunctionName, `messagewall`)].FunctionName' --output text 2>/dev/null || true)
if [[ -n "$LAMBDAS" && "$LAMBDAS" != "None" ]]; then
    echo -e "${RED}Remaining Lambda functions:${NC} $LAMBDAS"
    AWS_ORPHANS=true
else
    echo -e "${GREEN}No Lambda functions${NC}"
fi

TABLES=$(aws dynamodb list-tables --query 'TableNames[?starts_with(@, `messagewall`)]' --output text 2>/dev/null || true)
if [[ -n "$TABLES" && "$TABLES" != "None" ]]; then
    echo -e "${RED}Remaining DynamoDB tables:${NC} $TABLES"
    AWS_ORPHANS=true
else
    echo -e "${GREEN}No DynamoDB tables${NC}"
fi

BUCKETS=$(aws s3 ls 2>/dev/null | grep messagewall | awk '{print $3}' || true)
if [[ -n "$BUCKETS" ]]; then
    echo -e "${RED}Remaining S3 buckets:${NC} $BUCKETS"
    AWS_ORPHANS=true
else
    echo -e "${GREEN}No S3 buckets${NC}"
fi

ROLES=$(aws iam list-roles --query 'Roles[?starts_with(RoleName, `messagewall`)].RoleName' --output text 2>/dev/null || true)
if [[ -n "$ROLES" && "$ROLES" != "None" ]]; then
    echo -e "${RED}Remaining IAM roles:${NC} $ROLES"
    AWS_ORPHANS=true
else
    echo -e "${GREEN}No IAM roles${NC}"
fi

RULES=$(aws events list-rules --query 'Rules[?starts_with(Name, `messagewall`)].Name' --output text 2>/dev/null || true)
if [[ -n "$RULES" && "$RULES" != "None" ]]; then
    echo -e "${RED}Remaining EventBridge rules:${NC} $RULES"
    AWS_ORPHANS=true
else
    echo -e "${GREEN}No EventBridge rules${NC}"
fi

# Force-delete orphaned AWS resources if requested
if [[ "$AWS_ORPHANS" == "true" && "$FORCE_AWS" == "true" ]]; then
    echo ""
    echo -e "${YELLOW}Force-deleting orphaned AWS resources...${NC}"

    # Delete EventBridge targets and rules first
    for RULE in $RULES; do
        echo "  Deleting EventBridge rule: $RULE"
        # Get and delete targets first
        TARGETS=$(aws events list-targets-by-rule --rule "$RULE" --query 'Targets[].Id' --output text 2>/dev/null || true)
        if [[ -n "$TARGETS" ]]; then
            aws events remove-targets --rule "$RULE" --ids $TARGETS 2>/dev/null || true
        fi
        aws events delete-rule --name "$RULE" 2>/dev/null || true
    done

    # Delete Lambda functions
    for LAMBDA in $LAMBDAS; do
        echo "  Deleting Lambda: $LAMBDA"
        aws lambda delete-function --function-name "$LAMBDA" 2>/dev/null || true
    done

    # Delete IAM roles (delete policies first)
    for ROLE in $ROLES; do
        echo "  Deleting IAM role: $ROLE"
        # Delete inline policies
        POLICIES=$(aws iam list-role-policies --role-name "$ROLE" --query 'PolicyNames' --output text 2>/dev/null || true)
        for POLICY in $POLICIES; do
            aws iam delete-role-policy --role-name "$ROLE" --policy-name "$POLICY" 2>/dev/null || true
        done
        # Detach managed policies
        ATTACHED=$(aws iam list-attached-role-policies --role-name "$ROLE" --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null || true)
        for ARN in $ATTACHED; do
            aws iam detach-role-policy --role-name "$ROLE" --policy-arn "$ARN" 2>/dev/null || true
        done
        aws iam delete-role --role-name "$ROLE" 2>/dev/null || true
    done

    # Empty and delete S3 buckets
    for BUCKET in $BUCKETS; do
        echo "  Deleting S3 bucket: $BUCKET"
        aws s3 rm "s3://$BUCKET" --recursive 2>/dev/null || true
        aws s3 rb "s3://$BUCKET" 2>/dev/null || true
    done

    # Delete DynamoDB tables
    for TABLE in $TABLES; do
        echo "  Deleting DynamoDB table: $TABLE"
        aws dynamodb delete-table --table-name "$TABLE" 2>/dev/null || true
    done

    echo -e "${GREEN}Orphaned AWS resources deleted${NC}"
elif [[ "$AWS_ORPHANS" == "true" ]]; then
    echo ""
    echo -e "${YELLOW}Orphaned AWS resources remain.${NC}"
    echo "Run with --force-aws to delete them:"
    echo "  ./scripts/teardown-all.sh --force-aws --yes"
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
echo "  # 5. Create ConfigHub spaces"
echo "  cub space create messagewall-dev --label Environment=dev --label Application=messagewall"
echo "  scripts/setup-order-platform-spaces.sh"
echo ""
echo "  # 6. Configure ConfigHub credentials"
echo "  scripts/setup-argocd-confighub-auth.sh"
echo "  scripts/setup-workload-confighub-auth.sh"
echo ""
echo "  # 7. Deploy workloads and infrastructure"
echo "  scripts/publish-order-platform.sh --apply"
echo "  scripts/deploy-messagewall.sh"
echo ""
