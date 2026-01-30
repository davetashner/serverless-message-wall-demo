#!/bin/bash
set -euo pipefail

# Demo script for bulk security policy updates via ConfigHub
# ISSUE-42.3: Demonstrate bulk security context update across Order Platform
#
# This script updates all Order Platform deployments from permissive to
# restricted securityContext in a single operation across all 10 spaces.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Order Platform spaces: 5 teams x 2 environments = 10 spaces
TEAMS=("platform-ops" "data" "customer" "integrations" "compliance")
ENVS=("dev" "prod")

# Defaults
DRY_RUN=false
APPLY=false
CHANGE_DESC=""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Update all Order Platform deployments from permissive to restricted securityContext.

This script demonstrates how ConfigHub enables bulk security policy updates
across multiple teams and environments in a single operation.

CHANGES APPLIED:
    Before (permissive):
        securityContext:
          runAsNonRoot: false
          allowPrivilegeEscalation: true

    After (restricted):
        securityContext:
          runAsNonRoot: true
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          capabilities:
            drop: ["ALL"]

OPTIONS:
    --dry-run           Preview changes without applying
    --apply             Make the changes to ConfigHub
    --desc "TEXT"       Custom change description for audit trail
    -h, --help          Show this help message

EXAMPLES:
    # Preview what would change
    $(basename "$0") --dry-run

    # Apply security hardening with audit description
    $(basename "$0") --apply --desc "SEC-2024-042: Enforce restricted security policy"

SPACES AFFECTED:
    order-platform-ops-dev, order-platform-ops-prod
    order-data-dev, order-data-prod
    order-customer-dev, order-customer-prod
    order-integrations-dev, order-integrations-prod
    order-compliance-dev, order-compliance-prod

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
    echo -e "${CYAN}$1${NC}"
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --apply)
            APPLY=true
            shift
            ;;
        --desc)
            CHANGE_DESC="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            error "Unknown option: $1"
            ;;
    esac
done

# Validate options
if [[ "$DRY_RUN" == "false" && "$APPLY" == "false" ]]; then
    error "Must specify either --dry-run or --apply"
fi

if [[ "$DRY_RUN" == "true" && "$APPLY" == "true" ]]; then
    error "Cannot specify both --dry-run and --apply"
fi

# Set default change description
if [[ -z "$CHANGE_DESC" ]]; then
    CHANGE_DESC="Bulk security update: Enforce restricted securityContext policy"
fi

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

# Create temp directory for working files
TEMP_DIR=""
setup_temp_dir() {
    TEMP_DIR=$(mktemp -d)
}

cleanup() {
    if [[ -n "${TEMP_DIR:-}" ]] && [[ -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
    fi
}
trap cleanup EXIT

# Apply security context update using yq
# Updates container securityContext to restricted policy
apply_security_update() {
    local input_file="$1"
    local output_file="$2"

    # Update securityContext for all Deployment containers
    # This adds/replaces the securityContext with the restricted configuration
    yq eval '
        (select(.kind == "Deployment") | .spec.template.spec.containers[].securityContext) = {
            "runAsNonRoot": true,
            "allowPrivilegeEscalation": false,
            "readOnlyRootFilesystem": true,
            "capabilities": {
                "drop": ["ALL"]
            }
        }
    ' "$input_file" > "$output_file"
}

# Process a single space
process_space() {
    local space_name="$1"
    local mode="$2"  # "dry-run" or "apply"

    echo ""
    header "=== Processing space: ${space_name} ==="

    # Get list of units (deployments) in the space, excluding namespace units
    local units
    units=$(cub unit list --space "$space_name" --no-header --names 2>/dev/null | grep -v "^namespace$" || true)

    if [[ -z "$units" ]]; then
        warn "No deployment units found in space ${space_name}"
        return 0
    fi

    local unit_count=0
    for unit in $units; do
        ((unit_count++)) || true

        local current_file="${TEMP_DIR}/${space_name}-${unit}-current.yaml"
        local modified_file="${TEMP_DIR}/${space_name}-${unit}-modified.yaml"

        # Fetch current config
        if ! cub unit get --space "$space_name" "$unit" --data-only > "$current_file" 2>/dev/null; then
            warn "Failed to fetch unit ${unit} from ${space_name}"
            continue
        fi

        # Check if this is a Deployment
        local kind
        kind=$(yq '.kind' "$current_file" 2>/dev/null || echo "")
        if [[ "$kind" != "Deployment" ]]; then
            continue
        fi

        # Get deployment name for display
        local deploy_name
        deploy_name=$(yq '.metadata.name' "$current_file")

        # Apply security update
        apply_security_update "$current_file" "$modified_file"

        if [[ "$mode" == "dry-run" ]]; then
            # Show current vs proposed
            local current_context
            current_context=$(yq '.spec.template.spec.containers[0].securityContext // "null"' "$current_file")

            echo ""
            echo "  Deployment: ${deploy_name}"
            echo "    Current securityContext:"
            if [[ "$current_context" == "null" ]]; then
                echo "      (none - using defaults)"
            else
                yq '.spec.template.spec.containers[0].securityContext' "$current_file" | sed 's/^/      /'
            fi
            echo "    New securityContext:"
            yq '.spec.template.spec.containers[0].securityContext' "$modified_file" | sed 's/^/      /'
        else
            # Apply the change
            echo "  Updating: ${deploy_name}"
            if cub unit update --space "$space_name" "$unit" "$modified_file" \
                --change-desc "$CHANGE_DESC" 2>/dev/null; then
                success "    Updated ${unit}"
            else
                warn "    Failed to update ${unit}"
            fi
        fi
    done

    if [[ $unit_count -eq 0 ]]; then
        warn "No deployment units processed in ${space_name}"
    fi

    return 0
}

# Apply changes to all affected spaces
apply_to_all_spaces() {
    local mode="$1"  # "dry-run" or "apply"

    log "Applying to all Order Platform spaces (${mode} mode)..."

    for team in "${TEAMS[@]}"; do
        for env in "${ENVS[@]}"; do
            local space_name="order-${team}-${env}"
            process_space "$space_name" "$mode"
        done
    done
}

# Show summary
show_summary() {
    local mode="$1"

    echo ""
    echo "========================================"
    echo "BULK SECURITY UPDATE SUMMARY"
    echo "========================================"
    echo ""
    echo "Change description: ${CHANGE_DESC}"
    echo "Teams affected:     ${#TEAMS[@]} (${TEAMS[*]})"
    echo "Environments:       ${#ENVS[@]} (${ENVS[*]})"
    echo "Total spaces:       $((${#TEAMS[@]} * ${#ENVS[@]}))"
    echo ""

    if [[ "$mode" == "dry-run" ]]; then
        echo "Status: DRY RUN (no changes made)"
        echo ""
        echo "To apply these changes, run:"
        echo "  $(basename "$0") --apply --desc \"${CHANGE_DESC}\""
    else
        echo "Status: APPLIED"
        echo ""
        echo "Changes have been pushed to ConfigHub."
        echo "To apply the revisions to targets:"
        echo ""
        for team in "${TEAMS[@]}"; do
            for env in "${ENVS[@]}"; do
                echo "  cub unit apply --space order-${team}-${env} --where \"HeadRevisionNum > LiveRevisionNum\""
            done
        done
        echo ""
        echo "Or apply all at once (if spaces have targets configured):"
        echo "  for space in order-{platform-ops,data,customer,integrations,compliance}-{dev,prod}; do"
        echo "    cub unit apply --space \$space --where \"HeadRevisionNum > LiveRevisionNum\" --wait"
        echo "  done"
    fi
    echo ""
}

# Main execution
main() {
    echo ""
    echo "========================================"
    echo "CONFIGHUB BULK SECURITY UPDATE DEMO"
    echo "========================================"
    echo ""
    echo "This demo updates all Order Platform deployments to use"
    echo "restricted securityContext across 10 ConfigHub spaces."
    echo ""

    check_prerequisites
    setup_temp_dir

    local mode
    if [[ "$DRY_RUN" == "true" ]]; then
        mode="dry-run"
        echo ""
        echo "========================================"
        echo "DRY RUN - Previewing Changes"
        echo "========================================"
    else
        mode="apply"
        echo ""
        echo "========================================"
        echo "APPLYING SECURITY UPDATES"
        echo "========================================"
    fi

    apply_to_all_spaces "$mode"
    show_summary "$mode"
}

main
