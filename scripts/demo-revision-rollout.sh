#!/bin/bash
set -euo pipefail

# Demo script for controlled rollout of ConfigHub revisions
# ISSUE-8.6: Demonstrate controlled rollout of ConfigHub revisions
#
# This script demonstrates the separation between creating revisions (cub unit update)
# and deploying them (cub unit apply). ConfigHub tracks:
# - HeadRevisionNum: Latest revision (what CI pushed)
# - LiveRevisionNum: Deployed revision (what's running in Kubernetes)
#
# The key insight: changes can accumulate in ConfigHub without affecting
# the running system until an operator explicitly promotes them.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Defaults
SPACE="messagewall-dev"
UNIT="lambda"
AUTO_CLEANUP=false
STEP_BY_STEP=true

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Demonstrate controlled rollout of ConfigHub revisions.

This demo shows how HeadRevisionNum (latest) and LiveRevisionNum (deployed)
can diverge, allowing operators to review and selectively promote changes.

OPTIONS:
    --space NAME        ConfigHub space (default: ${SPACE})
    --unit NAME         Unit to demonstrate with (default: ${UNIT})
    --auto              Run without pauses (non-interactive)
    --cleanup           Revert demo changes at the end
    -h, --help          Show this help message

WHAT THIS DEMONSTRATES:
    1. HeadRevisionNum vs LiveRevisionNum separation
    2. CI can push changes without affecting production
    3. Operators can review pending changes
    4. Explicit promotion with 'cub unit apply'
    5. ArgoCD syncs only promoted (Live) revisions

EOF
    exit 0
}

log() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

success() {
    echo -e "${GREEN}[OK]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

header() {
    echo ""
    echo -e "${BOLD}${CYAN}========================================"
    echo "$1"
    echo -e "========================================${NC}"
    echo ""
}

pause() {
    if [[ "$STEP_BY_STEP" == "true" ]]; then
        echo ""
        read -r -p "Press Enter to continue..."
        echo ""
    fi
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --space)
            SPACE="$2"
            shift 2
            ;;
        --unit)
            UNIT="$2"
            shift 2
            ;;
        --auto)
            STEP_BY_STEP=false
            shift
            ;;
        --cleanup)
            AUTO_CLEANUP=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            error "Unknown option: $1"
            ;;
    esac
done

# Check prerequisites
check_prerequisites() {
    log "Checking prerequisites..."

    if ! command -v cub &> /dev/null; then
        error "cub CLI is not installed. Install from: https://hub.confighub.com/cub/install.sh"
    fi

    if ! command -v yq &> /dev/null; then
        error "yq is not installed. Install with: brew install yq"
    fi

    if ! cub auth status &> /dev/null; then
        error "Not authenticated to ConfigHub. Run: cub auth login"
    fi

    success "Prerequisites OK"
}

# Show current revision state
show_revision_state() {
    local label="$1"

    log "$label"
    echo ""
    echo "Unit revisions in space '$SPACE':"
    cub unit list --space "$SPACE" --no-header \
        --columns Unit.Slug,Unit.HeadRevisionNum,Unit.LiveRevisionNum 2>/dev/null | \
        awk 'BEGIN {printf "%-20s %-15s %-15s\n", "UNIT", "HEAD (latest)", "LIVE (deployed)"}
             {printf "%-20s %-15s %-15s\n", $1, $2, $3}'
    echo ""
}

# Show diff between Live and Head
show_pending_changes() {
    log "Checking for pending changes (Live vs Head)..."
    echo ""

    if cub unit diff --space "$SPACE" "$UNIT" -u 2>/dev/null | head -50; then
        echo ""
        success "Diff shown above (Live → Head)"
    else
        log "No differences between Live and Head"
    fi
}

# Create a demo change
create_demo_change() {
    local change_desc="$1"
    local temp_file
    temp_file=$(mktemp)

    log "Creating a demo change..."

    # Fetch current config
    cub unit get --space "$SPACE" "$UNIT" --data-only > "$temp_file" 2>/dev/null

    # Make a small change (update annotation with timestamp)
    local timestamp
    timestamp=$(date +%Y%m%d-%H%M%S)
    yq eval '(select(.kind == "Function") | .metadata.annotations."demo/last-update") = "'"$timestamp"'"' \
        "$temp_file" > "${temp_file}.new"

    # Push the change (creates new revision, advances HeadRevisionNum)
    if cub unit update --space "$SPACE" "$UNIT" "${temp_file}.new" \
        --change-desc "$change_desc" --wait 2>/dev/null; then
        success "Change pushed to ConfigHub"
    else
        error "Failed to push change"
    fi

    rm -f "$temp_file" "${temp_file}.new"
}

# Promote revision
promote_revision() {
    log "Promoting Head revision to Live..."

    if cub unit apply --space "$SPACE" "$UNIT" --wait 2>/dev/null; then
        success "Revision promoted (Live now matches Head)"
    else
        error "Failed to promote revision"
    fi
}

# Check ArgoCD sync status
check_argocd_status() {
    log "Checking ArgoCD sync status..."

    if command -v kubectl &> /dev/null; then
        if kubectl get application messagewall-dev -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null; then
            echo ""
        else
            warn "Could not check ArgoCD status (application may not exist)"
        fi
    else
        warn "kubectl not available, skipping ArgoCD check"
    fi
}

# Main demo flow
main() {
    header "CONFIGHUB CONTROLLED ROLLOUT DEMO"

    echo "This demo shows how ConfigHub separates revision creation from deployment."
    echo ""
    echo "Key concepts:"
    echo "  • HeadRevisionNum: Latest revision (what CI pushed)"
    echo "  • LiveRevisionNum: Deployed revision (what's in Kubernetes)"
    echo "  • 'cub unit update': Creates revisions (advances Head)"
    echo "  • 'cub unit apply': Promotes revisions (advances Live)"
    echo ""
    echo "ArgoCD only syncs LiveRevisionNum, so changes don't affect Kubernetes"
    echo "until explicitly promoted."
    echo ""

    pause

    check_prerequisites

    # Step 1: Show initial state
    header "STEP 1: Initial State"
    show_revision_state "Current revision numbers:"
    pause

    # Step 2: Show any existing pending changes
    header "STEP 2: Check for Pending Changes"
    show_pending_changes
    pause

    # Step 3: Create a change (simulating CI push)
    header "STEP 3: Create a New Revision (Simulating CI Push)"
    echo "We'll create a new revision by updating an annotation."
    echo "This simulates what happens when CI pushes a change."
    echo ""
    echo "Command: cub unit update --space $SPACE $UNIT <config> --change-desc '...'"
    echo ""
    pause

    create_demo_change "Demo: Controlled rollout test $(date +%H:%M:%S)"

    # Step 4: Show that Head advanced but Live stayed the same
    header "STEP 4: Verify Head Advanced, Live Unchanged"
    show_revision_state "After creating new revision:"
    echo "Notice: HeadRevisionNum increased, but LiveRevisionNum is unchanged."
    echo "The new revision exists in ConfigHub but is NOT deployed to Kubernetes."
    pause

    # Step 5: Show the pending diff
    header "STEP 5: Review Pending Changes"
    echo "Operators can review what would change before promoting."
    echo ""
    echo "Command: cub unit diff --space $SPACE $UNIT"
    echo ""
    show_pending_changes
    pause

    # Step 6: Promote the revision
    header "STEP 6: Promote Revision to Live"
    echo "The operator decides to deploy the change."
    echo ""
    echo "Command: cub unit apply --space $SPACE $UNIT"
    echo ""
    pause

    promote_revision

    # Step 7: Verify Live now matches Head
    header "STEP 7: Verify Promotion"
    show_revision_state "After promotion:"
    echo "LiveRevisionNum now matches HeadRevisionNum."
    echo "ArgoCD will detect this change and sync to Kubernetes."
    pause

    # Step 8: Check ArgoCD
    header "STEP 8: ArgoCD Sync Status"
    check_argocd_status
    echo ""
    echo "ArgoCD polls ConfigHub and syncs only Live revisions."
    echo "The CMP plugin fetches content at LiveRevisionNum, not HeadRevisionNum."

    # Summary
    header "DEMO COMPLETE"
    echo "What we demonstrated:"
    echo ""
    echo "  1. CI can push changes → HeadRevisionNum advances"
    echo "  2. LiveRevisionNum stays unchanged → Kubernetes unaffected"
    echo "  3. Operator reviews pending changes with 'cub unit diff'"
    echo "  4. Operator promotes with 'cub unit apply'"
    echo "  5. LiveRevisionNum advances → ArgoCD syncs to Kubernetes"
    echo ""
    echo "This enables:"
    echo "  • Staged rollouts (push to dev, promote to prod separately)"
    echo "  • Emergency holds (stop promotion during incidents)"
    echo "  • Change review before deployment"
    echo "  • Audit trail of who promoted what and when"
    echo ""

    echo "Useful commands:"
    echo "  cub unit list --space $SPACE --columns Unit.Slug,Unit.HeadRevisionNum,Unit.LiveRevisionNum"
    echo "  cub unit diff --space $SPACE $UNIT"
    echo "  cub unit apply --space $SPACE $UNIT"
    echo "  cub unit apply --space $SPACE --where 'HeadRevisionNum > LiveRevisionNum'"
    echo ""
}

main
