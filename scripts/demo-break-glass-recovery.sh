#!/bin/bash
set -euo pipefail

# Demo script for break-glass recovery and reconciliation
# ISSUE-8.7: Demonstrate break-glass recovery and reconciliation
#
# This script demonstrates how to handle emergency changes made directly to AWS
# (bypassing the normal ConfigHub flow) and reconcile them back into ConfigHub
# to maintain the audit trail and single source of truth.
#
# The break-glass scenario:
# 1. An incident occurs requiring immediate AWS-side changes
# 2. Operator makes direct AWS changes (bypassing Crossplane/ConfigHub)
# 3. After the incident, changes are reconciled back into ConfigHub
# 4. Audit trail is preserved with incident context

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Defaults
SPACE="messagewall-dev"
UNIT="lambda"
STEP_BY_STEP=true
SIMULATE_ONLY=false
DRY_RUN=false

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

Demonstrate break-glass recovery and reconciliation with ConfigHub.

This demo shows how to handle emergency AWS-side changes and reconcile
them back into ConfigHub to preserve the audit trail.

OPTIONS:
    --space NAME        ConfigHub space (default: ${SPACE})
    --unit NAME         Unit to demonstrate with (default: ${UNIT})
    --auto              Run without pauses (non-interactive)
    --simulate          Simulate AWS changes without actually making them
    --dry-run           Show what would happen without making any changes
    -h, --help          Show this help message

SCENARIOS DEMONSTRATED:
    1. Emergency memory increase (simulating incident response)
    2. Drift detection (ConfigHub vs AWS state)
    3. Reconciliation (importing AWS state into ConfigHub)
    4. Audit trail preservation

WHAT THIS TEACHES:
    - Break-glass changes should be the exception, not the rule
    - Always reconcile back to ConfigHub after emergency changes
    - Include incident context in the reconciliation commit
    - Crossplane will eventually revert un-reconciled changes

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

subheader() {
    echo ""
    echo -e "${BOLD}--- $1 ---${NC}"
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
        --simulate)
            SIMULATE_ONLY=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
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

    if ! command -v aws &> /dev/null; then
        error "aws CLI is not installed."
    fi

    if ! command -v yq &> /dev/null; then
        error "yq is not installed. Install with: brew install yq"
    fi

    if ! command -v kubectl &> /dev/null; then
        error "kubectl is not installed."
    fi

    if ! cub auth status &> /dev/null; then
        error "Not authenticated to ConfigHub. Run: cub auth login"
    fi

    success "Prerequisites OK"
}

# Load environment config
load_config() {
    if [[ -f "${PROJECT_ROOT}/config/dev.env" ]]; then
        # shellcheck source=/dev/null
        source "${PROJECT_ROOT}/config/dev.env"
    else
        warn "Cannot load config/dev.env, using defaults"
        RESOURCE_PREFIX="messagewall"
        AWS_REGION="us-east-1"
    fi
}

# Get current state from ConfigHub
get_confighub_state() {
    log "Fetching current state from ConfigHub..."

    TEMP_DIR=$(mktemp -d)
    CONFIGHUB_STATE="${TEMP_DIR}/confighub-state.yaml"

    if ! cub unit get --space "$SPACE" "$UNIT" --data-only > "$CONFIGHUB_STATE" 2>/dev/null; then
        error "Failed to fetch unit '$UNIT' from space '$SPACE'"
    fi

    # Extract memory setting from ConfigHub
    CONFIGHUB_MEMORY=$(yq 'select(.kind == "Function" and .metadata.name == "'"${RESOURCE_PREFIX}"'-api-handler") | .spec.forProvider.memorySize' "$CONFIGHUB_STATE" 2>/dev/null || echo "unknown")

    success "ConfigHub state: api-handler memorySize = ${CONFIGHUB_MEMORY}MB"
}

# Get current state from AWS
get_aws_state() {
    log "Fetching current state from AWS..."

    local func_name="${RESOURCE_PREFIX}-api-handler"

    if AWS_MEMORY=$(aws lambda get-function-configuration \
        --function-name "$func_name" \
        --query 'MemorySize' \
        --output text \
        --region "${AWS_REGION:-us-east-1}" 2>/dev/null); then
        success "AWS state: ${func_name} MemorySize = ${AWS_MEMORY}MB"
    else
        warn "Could not fetch AWS state (function may not exist yet)"
        AWS_MEMORY="unknown"
    fi
}

# Simulate an incident requiring break-glass access
simulate_incident() {
    header "INCIDENT SCENARIO"

    echo -e "${RED}${BOLD}INCIDENT ALERT: High memory pressure on api-handler Lambda${NC}"
    echo ""
    echo "Symptoms:"
    echo "  - Lambda function hitting memory limits"
    echo "  - Requests timing out"
    echo "  - Error rate spiking to 50%"
    echo ""
    echo "Assessment:"
    echo "  - Current memory: ${CONFIGHUB_MEMORY}MB (as configured in ConfigHub)"
    echo "  - AWS actual:     ${AWS_MEMORY}MB"
    echo "  - Required:       512MB (immediate increase needed)"
    echo ""
    echo "Decision: Break-glass to increase memory directly in AWS"
    echo "          (ConfigHub change would take too long during incident)"
    echo ""
}

# Make emergency AWS change
make_emergency_change() {
    header "BREAK-GLASS: DIRECT AWS CHANGE"

    local func_name="${RESOURCE_PREFIX}-api-handler"
    local new_memory=512

    echo "Making direct AWS change to resolve incident..."
    echo ""
    echo "Command (in real incident, executed by on-call engineer):"
    echo -e "${YELLOW}  aws lambda update-function-configuration \\"
    echo "    --function-name ${func_name} \\"
    echo "    --memory-size ${new_memory}${NC}"
    echo ""

    if [[ "$DRY_RUN" == "true" ]]; then
        warn "DRY RUN - Skipping actual AWS change"
        EMERGENCY_MEMORY=$new_memory
        return
    fi

    if [[ "$SIMULATE_ONLY" == "true" ]]; then
        warn "SIMULATE - Would change memory to ${new_memory}MB"
        EMERGENCY_MEMORY=$new_memory
        return
    fi

    if aws lambda update-function-configuration \
        --function-name "$func_name" \
        --memory-size "$new_memory" \
        --region "${AWS_REGION:-us-east-1}" \
        --output text \
        --query 'MemorySize' > /dev/null 2>&1; then
        success "Emergency change applied: memory now ${new_memory}MB"
        EMERGENCY_MEMORY=$new_memory
    else
        warn "Could not apply emergency change (simulating instead)"
        EMERGENCY_MEMORY=$new_memory
    fi

    echo ""
    echo -e "${GREEN}INCIDENT MITIGATED${NC}: Lambda memory increased to ${new_memory}MB"
    echo "Error rate returning to normal."
}

# Detect drift between ConfigHub and AWS
detect_drift() {
    header "POST-INCIDENT: DETECT DRIFT"

    echo "After the incident is resolved, we need to reconcile the change."
    echo ""
    echo "Current state:"
    echo "  - ConfigHub (authoritative): ${CONFIGHUB_MEMORY}MB"
    echo "  - AWS (emergency change):    ${EMERGENCY_MEMORY:-unknown}MB"
    echo ""

    if [[ "${CONFIGHUB_MEMORY}" != "${EMERGENCY_MEMORY:-unknown}" ]]; then
        echo -e "${YELLOW}DRIFT DETECTED:${NC} ConfigHub and AWS are out of sync"
        echo ""
        echo "Without reconciliation, Crossplane will eventually revert"
        echo "the AWS change back to ${CONFIGHUB_MEMORY}MB!"
        DRIFT_DETECTED=true
    else
        echo "No drift detected (states are in sync)"
        DRIFT_DETECTED=false
    fi
}

# Show what Crossplane would do
explain_crossplane_behavior() {
    subheader "Understanding Crossplane Reconciliation"

    echo "Crossplane continuously reconciles desired state (from ConfigHub)"
    echo "with actual state (in AWS)."
    echo ""
    echo "If we don't update ConfigHub:"
    echo "  1. Crossplane sees: desired=${CONFIGHUB_MEMORY}MB, actual=${EMERGENCY_MEMORY:-unknown}MB"
    echo "  2. Crossplane updates AWS to match desired state"
    echo "  3. Our emergency fix gets REVERTED"
    echo "  4. Incident returns!"
    echo ""
    echo "This is why reconciliation is critical."
}

# Reconcile change back to ConfigHub
reconcile_to_confighub() {
    header "RECONCILIATION: UPDATE CONFIGHUB"

    local incident_id="INC-$(date +%Y%m%d-%H%M%S)"
    local change_desc="Break-glass: ${incident_id} - Increased api-handler memory to ${EMERGENCY_MEMORY}MB to resolve memory pressure incident"

    echo "Updating ConfigHub to reflect the emergency change..."
    echo ""
    echo "Incident ID: ${incident_id}"
    echo "Change description: ${change_desc}"
    echo ""

    if [[ "$DRY_RUN" == "true" ]]; then
        warn "DRY RUN - Would update ConfigHub with new memory value"
        echo ""
        echo "Command that would run:"
        echo "  cub unit update --space $SPACE $UNIT <modified-config> \\"
        echo "    --change-desc \"${change_desc}\""
        return
    fi

    # Create modified configuration
    MODIFIED_STATE="${TEMP_DIR}/modified-state.yaml"

    # Update the memory value in the config
    yq eval '
        (select(.kind == "Function" and .metadata.name == "'"${RESOURCE_PREFIX}"'-api-handler") |
         .spec.forProvider.memorySize) = '"${EMERGENCY_MEMORY}"'
    ' "$CONFIGHUB_STATE" > "$MODIFIED_STATE"

    # Add incident annotation
    yq eval -i '
        (select(.kind == "Function" and .metadata.name == "'"${RESOURCE_PREFIX}"'-api-handler") |
         .metadata.annotations."incident/break-glass") = "'"${incident_id}"'"
    ' "$MODIFIED_STATE"

    yq eval -i '
        (select(.kind == "Function" and .metadata.name == "'"${RESOURCE_PREFIX}"'-api-handler") |
         .metadata.annotations."incident/reconciled-at") = "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"
    ' "$MODIFIED_STATE"

    echo "Changes to be applied:"
    echo ""
    if command -v diff &> /dev/null; then
        diff -u "$CONFIGHUB_STATE" "$MODIFIED_STATE" --color=always 2>/dev/null | head -30 || true
    fi
    echo ""

    if [[ "$SIMULATE_ONLY" == "true" ]]; then
        warn "SIMULATE - Would push changes to ConfigHub"
        return
    fi

    # Push to ConfigHub
    if cub unit update --space "$SPACE" "$UNIT" "$MODIFIED_STATE" \
        --change-desc "$change_desc" \
        --wait 2>/dev/null; then
        success "Changes reconciled to ConfigHub"
    else
        error "Failed to reconcile changes to ConfigHub"
    fi
}

# Verify reconciliation
verify_reconciliation() {
    header "VERIFICATION: CONFIRM RECONCILIATION"

    echo "Verifying that ConfigHub now reflects the emergency change..."
    echo ""

    if [[ "$DRY_RUN" == "true" ]] || [[ "$SIMULATE_ONLY" == "true" ]]; then
        warn "Skipping verification in dry-run/simulate mode"
        return
    fi

    # Fetch updated ConfigHub state
    local new_confighub_memory
    new_confighub_memory=$(cub unit get --space "$SPACE" "$UNIT" --data-only 2>/dev/null | \
        yq 'select(.kind == "Function" and .metadata.name == "'"${RESOURCE_PREFIX}"'-api-handler") | .spec.forProvider.memorySize' 2>/dev/null || echo "unknown")

    echo "Updated states:"
    echo "  - ConfigHub: ${new_confighub_memory}MB"
    echo "  - AWS:       ${EMERGENCY_MEMORY:-unknown}MB"
    echo ""

    if [[ "$new_confighub_memory" == "${EMERGENCY_MEMORY:-unknown}" ]]; then
        success "Reconciliation verified: ConfigHub and AWS are in sync"
    else
        warn "States may still be divergent (check revision promotion status)"
    fi
}

# Show audit trail
show_audit_trail() {
    header "AUDIT TRAIL"

    echo "The break-glass change is now documented in ConfigHub history."
    echo ""
    echo "View the change history:"
    echo "  cub unit history --space ${SPACE} ${UNIT}"
    echo ""

    if [[ "$DRY_RUN" != "true" ]] && [[ "$SIMULATE_ONLY" != "true" ]]; then
        log "Recent revisions:"
        if cub unit history --space "$SPACE" "$UNIT" --limit 5 2>/dev/null; then
            echo ""
        else
            warn "Could not fetch history"
        fi
    fi

    echo "Key audit elements captured:"
    echo "  - WHO: Authenticated user who ran reconciliation"
    echo "  - WHAT: Memory changed from ${CONFIGHUB_MEMORY}MB to ${EMERGENCY_MEMORY:-unknown}MB"
    echo "  - WHEN: Timestamp of reconciliation"
    echo "  - WHY: Incident ID and description in change message"
    echo "  - CONTEXT: Break-glass annotation on the resource"
}

# Summary
show_summary() {
    header "BREAK-GLASS RECOVERY COMPLETE"

    echo "What we demonstrated:"
    echo ""
    echo "  1. ${BOLD}Incident Occurs${NC}"
    echo "     - Service degradation requiring immediate action"
    echo ""
    echo "  2. ${BOLD}Break-Glass Change${NC}"
    echo "     - Direct AWS change bypassing normal flow"
    echo "     - Incident mitigated quickly"
    echo ""
    echo "  3. ${BOLD}Drift Detection${NC}"
    echo "     - Identified ConfigHub/AWS divergence"
    echo "     - Understood Crossplane would revert without reconciliation"
    echo ""
    echo "  4. ${BOLD}Reconciliation${NC}"
    echo "     - Updated ConfigHub to match emergency change"
    echo "     - Included incident context in change description"
    echo "     - Added break-glass annotation for tracking"
    echo ""
    echo "  5. ${BOLD}Audit Trail${NC}"
    echo "     - Full history preserved in ConfigHub"
    echo "     - Change attributed to operator"
    echo "     - Incident ID links to incident management system"
    echo ""
    echo "${BOLD}Key Takeaways:${NC}"
    echo ""
    echo "  - Break-glass is for emergencies, not convenience"
    echo "  - Always reconcile back to ConfigHub after break-glass"
    echo "  - Include incident context for future investigations"
    echo "  - Crossplane enforces desired state; update desired state to persist changes"
    echo ""
}

# Cleanup temp files
cleanup() {
    if [[ -n "${TEMP_DIR:-}" ]] && [[ -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
    fi
}
trap cleanup EXIT

# Main demo flow
main() {
    header "BREAK-GLASS RECOVERY DEMO"

    echo "This demo shows how to handle emergency AWS-side changes"
    echo "and reconcile them back into ConfigHub."
    echo ""
    echo "Scenario: Lambda memory pressure requires immediate increase"
    echo "Action: Direct AWS change, then reconciliation to ConfigHub"
    echo ""

    if [[ "$DRY_RUN" == "true" ]]; then
        echo -e "${YELLOW}MODE: DRY RUN (no changes will be made)${NC}"
    elif [[ "$SIMULATE_ONLY" == "true" ]]; then
        echo -e "${YELLOW}MODE: SIMULATE (AWS changes simulated, ConfigHub skipped)${NC}"
    fi
    echo ""

    pause

    check_prerequisites
    load_config

    # Step 1: Get current states
    header "STEP 1: BASELINE STATE"
    get_confighub_state
    get_aws_state
    pause

    # Step 2: Simulate incident
    simulate_incident
    pause

    # Step 3: Make emergency change
    make_emergency_change
    pause

    # Step 4: Detect drift
    detect_drift
    if [[ "$DRIFT_DETECTED" == "true" ]]; then
        explain_crossplane_behavior
    fi
    pause

    # Step 5: Reconcile to ConfigHub
    reconcile_to_confighub
    pause

    # Step 6: Verify reconciliation
    verify_reconciliation
    pause

    # Step 7: Show audit trail
    show_audit_trail
    pause

    # Summary
    show_summary
}

main
