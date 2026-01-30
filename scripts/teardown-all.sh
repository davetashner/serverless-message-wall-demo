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
    # Messagewall infrastructure (single-region)
    messagewall-dev
    messagewall-prod
    # Messagewall infrastructure (multi-region)
    messagewall-dev-east
    messagewall-dev-west
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

# AWS regions to check for resources
AWS_REGIONS=(us-east-1 us-west-2)

echo ""
echo "═══════════════════════════════════════════════════════"
echo "  FULL TEARDOWN"
echo "═══════════════════════════════════════════════════════"
echo ""
echo -e "${RED}This will destroy:${NC}"
echo "  • Crossplane Claims (triggers AWS resource deletion)"
echo "  • ArgoCD applications (all clusters)"
echo "  • All AWS resources managed by Crossplane (us-east-1 and us-west-2)"
echo "  • ConfigHub workers, units, and ${#CONFIGHUB_SPACES[@]} spaces"
echo "  • Kind clusters (actuator, actuator-east, actuator-west, workload)"
if [[ "$FORCE_AWS" == "true" ]]; then
    echo -e "  • ${YELLOW}Force delete any orphaned AWS resources (both regions)${NC}"
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

# Check all possible actuator clusters (single-region and multi-region)
ACTUATOR_CLUSTERS=()
for CLUSTER in kind-actuator kind-actuator-east kind-actuator-west; do
    if kubectl cluster-info --context "$CLUSTER" &>/dev/null; then
        ACTUATOR_CLUSTERS+=("$CLUSTER")
    fi
done

if [[ ${#ACTUATOR_CLUSTERS[@]} -eq 0 ]]; then
    echo "  No actuator clusters found"
else
    for CLUSTER in "${ACTUATOR_CLUSTERS[@]}"; do
        echo ""
        echo "Cluster: $CLUSTER"

        if kubectl get crd serverlesseventappclaims.messagewall.demo --context "$CLUSTER" &>/dev/null; then
            # Delete all ServerlessEventAppClaims
            CLAIMS=$(kubectl get serverlesseventappclaim --all-namespaces --context "$CLUSTER" -o name 2>/dev/null || true)
            if [[ -n "$CLAIMS" ]]; then
                echo "  Deleting Claims:"
                echo "$CLAIMS" | while read -r claim; do
                    echo "    - $claim"
                done
                kubectl delete serverlesseventappclaim --all --all-namespaces --context "$CLUSTER" --wait=false
                echo -e "  ${GREEN}Claims deleted${NC}"
            else
                echo "  No Claims found"
            fi
        else
            echo "  ServerlessEventAppClaim CRD not installed"
        fi

        # Also delete any orphaned CompositeResources (XRs) not managed by Claims
        if kubectl get crd serverlesseventapps.messagewall.demo --context "$CLUSTER" &>/dev/null; then
            XRS=$(kubectl get serverlesseventapp --context "$CLUSTER" -o name 2>/dev/null || true)
            if [[ -n "$XRS" ]]; then
                echo "  Deleting CompositeResources..."
                kubectl delete serverlesseventapp --all --context "$CLUSTER" --wait=false
            fi
        fi
    done
fi

echo ""

# ─────────────────────────────────────────────────────────────
# Step 2: Delete ArgoCD applications from ALL clusters
# ─────────────────────────────────────────────────────────────
echo -e "${YELLOW}Step 2: Delete ArgoCD applications (all clusters)${NC}"
echo "ArgoCD apps keep resources alive via self-heal..."

# Check all possible clusters
ALL_CLUSTERS=()
for CLUSTER in kind-actuator kind-actuator-east kind-actuator-west kind-workload; do
    if kubectl cluster-info --context "$CLUSTER" &>/dev/null; then
        ALL_CLUSTERS+=("$CLUSTER")
    fi
done

for CLUSTER in "${ALL_CLUSTERS[@]}"; do
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

# Helper function to empty stuck S3 buckets for a given cluster
empty_stuck_s3_buckets() {
    local cluster=$1
    local stuck_buckets
    # Find S3 bucket resources that are stuck (SYNCED=False, READY=False)
    stuck_buckets=$(kubectl get managed --context "$cluster" 2>/dev/null | grep 'bucket.s3' | grep -E 'False.*False' | awk '{print $3}' || true)
    if [[ -n "$stuck_buckets" ]]; then
        for bucket in $stuck_buckets; do
            if [[ -n "$bucket" && "$bucket" != "EXTERNAL-NAME" ]]; then
                echo -e "  ${CYAN}Emptying stuck S3 bucket: $bucket${NC}"
                aws s3 rm "s3://$bucket" --recursive 2>/dev/null || true
            fi
        done
    fi
}

# Wait for Crossplane cleanup on all actuator clusters
if [[ ${#ACTUATOR_CLUSTERS[@]} -gt 0 ]]; then
    for CLUSTER in "${ACTUATOR_CLUSTERS[@]}"; do
        echo ""
        echo "Cluster: $CLUSTER"

        if kubectl get managed --context "$CLUSTER" &>/dev/null; then
            echo "  Waiting for AWS resources to be deleted (up to 2 minutes)..."
            SHOWN_STUCK_DIAGNOSTIC=false
            EMPTIED_BUCKETS=false

            for i in {1..24}; do
                REMAINING=$(kubectl get managed --context "$CLUSTER" --no-headers 2>/dev/null | wc -l | tr -d ' ')
                if [[ "$REMAINING" -eq 0 ]]; then
                    echo -e "\n  ${GREEN}All Crossplane managed resources deleted${NC}"
                    break
                fi

                # Check for stuck resources
                STUCK=$(kubectl get managed --context "$CLUSTER" 2>/dev/null | grep -E 'False.*False' || true)
                if [[ -n "$STUCK" ]]; then
                    # Show diagnostic only once
                    if [[ "$SHOWN_STUCK_DIAGNOSTIC" == "false" ]]; then
                        echo ""
                        echo -e "  ${CYAN}Some resources are stuck:${NC}"
                        kubectl get managed --context "$CLUSTER" 2>/dev/null | grep -E 'False.*False' | head -5
                        echo ""
                        SHOWN_STUCK_DIAGNOSTIC=true
                    fi

                    # Proactively empty S3 buckets (only try once)
                    if [[ "$EMPTIED_BUCKETS" == "false" ]]; then
                        empty_stuck_s3_buckets "$CLUSTER"
                        EMPTIED_BUCKETS=true
                    fi
                fi

                # Simple progress indicator
                ELAPSED=$((i * 5))
                printf "\r    %d resources remaining... (%ds)" "$REMAINING" "$ELAPSED"
                sleep 5
            done
            echo ""  # Clear the progress line

            # Final check
            REMAINING=$(kubectl get managed --context "$CLUSTER" --no-headers 2>/dev/null | wc -l | tr -d ' ')
            if [[ "$REMAINING" -gt 0 ]]; then
                echo -e "  ${YELLOW}Warning: $REMAINING resources still exist${NC}"
                kubectl get managed --context "$CLUSTER" 2>/dev/null
                echo ""
                if [[ "$FORCE_AWS" == "true" ]]; then
                    echo -e "  ${YELLOW}Will force-delete after cluster teardown...${NC}"
                else
                    echo -e "  ${CYAN}Tip: Run with --force-aws to delete orphaned resources${NC}"
                fi
            fi
        else
            echo "  No managed resources found"
        fi
    done
else
    echo "No actuator clusters found, skipping Crossplane cleanup"
fi

# ─────────────────────────────────────────────────────────────
# Step 4: Delete ConfigHub namespace from ALL clusters (stops workers)
# ─────────────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}Step 4: Stop ConfigHub workers (all clusters)${NC}"

for CLUSTER in "${ALL_CLUSTERS[@]}"; do
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

# Delete all possible clusters (single-region and multi-region)
for CLUSTER_NAME in workload actuator actuator-east actuator-west; do
    if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
        echo "Deleting $CLUSTER_NAME cluster..."
        kind delete cluster --name "$CLUSTER_NAME"
        echo -e "${GREEN}$CLUSTER_NAME cluster deleted${NC}"
    else
        echo "$CLUSTER_NAME cluster not found"
    fi
done

# ─────────────────────────────────────────────────────────────
# Step 7: Verify AWS resources are gone (and optionally force-delete)
# Checks both us-east-1 and us-west-2 regions
# ─────────────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}Step 7: Verify AWS cleanup (both regions)${NC}"

AWS_ORPHANS=false

# Collect orphaned resources across all regions
declare -A ALL_LAMBDAS ALL_TABLES ALL_RULES
ALL_BUCKETS=""
ALL_ROLES=""

for REGION in "${AWS_REGIONS[@]}"; do
    echo ""
    echo "Region: $REGION"

    LAMBDAS=$(aws lambda list-functions --region "$REGION" --query 'Functions[?starts_with(FunctionName, `messagewall`)].FunctionName' --output text 2>/dev/null || true)
    if [[ -n "$LAMBDAS" && "$LAMBDAS" != "None" ]]; then
        echo -e "  ${RED}Lambda functions:${NC} $LAMBDAS"
        ALL_LAMBDAS[$REGION]="$LAMBDAS"
        AWS_ORPHANS=true
    else
        echo -e "  ${GREEN}No Lambda functions${NC}"
    fi

    TABLES=$(aws dynamodb list-tables --region "$REGION" --query 'TableNames[?starts_with(@, `messagewall`)]' --output text 2>/dev/null || true)
    if [[ -n "$TABLES" && "$TABLES" != "None" ]]; then
        echo -e "  ${RED}DynamoDB tables:${NC} $TABLES"
        ALL_TABLES[$REGION]="$TABLES"
        AWS_ORPHANS=true
    else
        echo -e "  ${GREEN}No DynamoDB tables${NC}"
    fi

    RULES=$(aws events list-rules --region "$REGION" --query 'Rules[?starts_with(Name, `messagewall`)].Name' --output text 2>/dev/null || true)
    if [[ -n "$RULES" && "$RULES" != "None" ]]; then
        echo -e "  ${RED}EventBridge rules:${NC} $RULES"
        ALL_RULES[$REGION]="$RULES"
        AWS_ORPHANS=true
    else
        echo -e "  ${GREEN}No EventBridge rules${NC}"
    fi
done

# S3 buckets are global (check once)
echo ""
echo "Global resources:"
BUCKETS=$(aws s3 ls 2>/dev/null | grep messagewall | awk '{print $3}' || true)
if [[ -n "$BUCKETS" ]]; then
    echo -e "  ${RED}S3 buckets:${NC} $BUCKETS"
    ALL_BUCKETS="$BUCKETS"
    AWS_ORPHANS=true
else
    echo -e "  ${GREEN}No S3 buckets${NC}"
fi

# IAM roles are global (check once)
ROLES=$(aws iam list-roles --query 'Roles[?starts_with(RoleName, `messagewall`)].RoleName' --output text 2>/dev/null || true)
if [[ -n "$ROLES" && "$ROLES" != "None" ]]; then
    echo -e "  ${RED}IAM roles:${NC} $ROLES"
    ALL_ROLES="$ROLES"
    AWS_ORPHANS=true
else
    echo -e "  ${GREEN}No IAM roles${NC}"
fi

# Force-delete orphaned AWS resources if requested
if [[ "$AWS_ORPHANS" == "true" && "$FORCE_AWS" == "true" ]]; then
    echo ""
    echo -e "${YELLOW}Force-deleting orphaned AWS resources...${NC}"

    # Delete regional resources
    for REGION in "${AWS_REGIONS[@]}"; do
        # Delete EventBridge targets and rules
        if [[ -n "${ALL_RULES[$REGION]:-}" ]]; then
            for RULE in ${ALL_RULES[$REGION]}; do
                echo "  Deleting EventBridge rule ($REGION): $RULE"
                TARGETS=$(aws events list-targets-by-rule --region "$REGION" --rule "$RULE" --query 'Targets[].Id' --output text 2>/dev/null || true)
                if [[ -n "$TARGETS" ]]; then
                    aws events remove-targets --region "$REGION" --rule "$RULE" --ids $TARGETS 2>/dev/null || true
                fi
                aws events delete-rule --region "$REGION" --name "$RULE" 2>/dev/null || true
            done
        fi

        # Delete Lambda functions
        if [[ -n "${ALL_LAMBDAS[$REGION]:-}" ]]; then
            for LAMBDA in ${ALL_LAMBDAS[$REGION]}; do
                echo "  Deleting Lambda ($REGION): $LAMBDA"
                aws lambda delete-function --region "$REGION" --function-name "$LAMBDA" 2>/dev/null || true
            done
        fi

        # Delete DynamoDB tables
        if [[ -n "${ALL_TABLES[$REGION]:-}" ]]; then
            for TABLE in ${ALL_TABLES[$REGION]}; do
                echo "  Deleting DynamoDB table ($REGION): $TABLE"
                aws dynamodb delete-table --region "$REGION" --table-name "$TABLE" 2>/dev/null || true
            done
        fi
    done

    # Delete global resources
    # Delete IAM roles (delete policies first)
    for ROLE in $ALL_ROLES; do
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
    for BUCKET in $ALL_BUCKETS; do
        echo "  Deleting S3 bucket: $BUCKET"
        aws s3 rm "s3://$BUCKET" --recursive 2>/dev/null || true
        aws s3 rb "s3://$BUCKET" 2>/dev/null || true
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
echo "  # Option A: Single-region setup"
echo "  scripts/bootstrap-kind.sh"
echo "  scripts/bootstrap-crossplane.sh && scripts/bootstrap-aws-providers.sh"
echo "  scripts/deploy-messagewall.sh"
echo ""
echo "  # Option B: Multi-region setup"
echo "  scripts/bootstrap-kind.sh --name actuator-east --region us-east-1"
echo "  scripts/bootstrap-kind.sh --name actuator-west --region us-west-2"
echo "  scripts/bootstrap-crossplane.sh --context kind-actuator-east"
echo "  scripts/bootstrap-crossplane.sh --context kind-actuator-west"
echo "  scripts/bootstrap-aws-providers.sh --context kind-actuator-east"
echo "  scripts/bootstrap-aws-providers.sh --context kind-actuator-west --profile crossplane-west"
echo "  scripts/setup-multiregion-spaces.sh"
echo "  scripts/deploy-messagewall.sh --region east"
echo "  scripts/deploy-messagewall.sh --region west"
echo ""
echo "See docs/demo-guide.md for full multi-region demo instructions."
echo ""
