#!/bin/bash
set -euo pipefail

# Demo script for bulk configuration changes via ConfigHub
# ISSUE-8.5: Demonstrate bulk configuration change via ConfigHub
#
# This script demonstrates how ConfigHub enables bulk changes across multiple
# Lambda functions in a single operation, with a single revision tracked in
# the change history.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Defaults
SPACE="messagewall-dev"
UNIT="lambda"
DRY_RUN=false
VERIFY=false
CHANGE_TYPE=""
CHANGE_VALUE=""
CHANGE_DESC=""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

usage() {
    cat <<EOF
Usage: $(basename "$0") <CHANGE_TYPE> [OPTIONS]

Demonstrate bulk configuration changes via ConfigHub.

CHANGE TYPES:
    memory <MB>         Set memorySize for all Lambda functions (e.g., 256)
    timeout <SECONDS>   Set timeout for all Lambda functions (e.g., 15)
    env <NAME=VALUE>    Add/update environment variable on all Lambda functions
    remove-env <NAME>   Remove environment variable from all Lambda functions

OPTIONS:
    --space NAME        ConfigHub space (default: ${SPACE})
    --dry-run           Preview changes without applying
    --verify            Verify changes propagated to AWS after applying
    --desc "TEXT"       Custom change description
    -h, --help          Show this help message

EXAMPLES:
    # Preview changing memory to 256MB
    $(basename "$0") memory 256 --dry-run

    # Update memory and verify in AWS
    $(basename "$0") memory 256 --verify

    # Add LOG_LEVEL environment variable
    $(basename "$0") env LOG_LEVEL=DEBUG

    # Add a security-related env var with description
    $(basename "$0") env SECURITY_LOG_ENDPOINT=https://security.internal/ingest \\
        --desc "SEC-2024-001: Add security logging"

    # Remove an environment variable
    $(basename "$0") remove-env LOG_LEVEL

WHAT THIS DEMONSTRATES:
    1. Single operation updates BOTH Lambda functions
    2. Change is tracked as ONE ConfigHub revision
    3. Crossplane reconciles changes to AWS
    4. Full audit trail of who changed what and when

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

# Parse arguments
if [[ $# -lt 1 ]]; then
    usage
fi

CHANGE_TYPE="$1"
shift

case "$CHANGE_TYPE" in
    memory|timeout)
        if [[ $# -lt 1 ]]; then
            error "Missing value for $CHANGE_TYPE"
        fi
        CHANGE_VALUE="$1"
        shift
        ;;
    env)
        if [[ $# -lt 1 ]]; then
            error "Missing NAME=VALUE for env"
        fi
        CHANGE_VALUE="$1"
        if [[ ! "$CHANGE_VALUE" =~ ^[A-Z_][A-Z0-9_]*=.+$ ]]; then
            error "Invalid env format. Expected NAME=VALUE (e.g., LOG_LEVEL=DEBUG)"
        fi
        shift
        ;;
    remove-env)
        if [[ $# -lt 1 ]]; then
            error "Missing NAME for remove-env"
        fi
        CHANGE_VALUE="$1"
        shift
        ;;
    -h|--help)
        usage
        ;;
    *)
        error "Unknown change type: $CHANGE_TYPE"
        ;;
esac

# Parse remaining options
while [[ $# -gt 0 ]]; do
    case $1 in
        --space)
            SPACE="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --verify)
            VERIFY=true
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

# Fetch current configuration from ConfigHub
fetch_current_config() {
    log "Fetching current configuration from ConfigHub space '${SPACE}'..."

    TEMP_DIR=$(mktemp -d)
    CURRENT_FILE="${TEMP_DIR}/current.yaml"
    MODIFIED_FILE="${TEMP_DIR}/modified.yaml"

    if ! cub unit get --space "$SPACE" "$UNIT" --output yaml > "$CURRENT_FILE" 2>&1; then
        error "Failed to fetch unit '$UNIT' from space '$SPACE'"
    fi

    # Count the number of Lambda functions in the unit
    LAMBDA_COUNT=$(yq 'select(.kind == "Function") | .metadata.name' "$CURRENT_FILE" | wc -l | tr -d ' ')
    success "Fetched $LAMBDA_COUNT Lambda functions from ConfigHub"

    # Show current state
    echo ""
    echo "Current Lambda configurations:"
    yq 'select(.kind == "Function") | {"name": .metadata.name, "memory": .spec.forProvider.memorySize, "timeout": .spec.forProvider.timeout}' "$CURRENT_FILE"
}

# Apply memory change
apply_memory_change() {
    local memory_mb="$1"

    log "Setting memorySize to ${memory_mb}MB on all Lambda functions..."

    # Validate memory value
    if ! [[ "$memory_mb" =~ ^[0-9]+$ ]]; then
        error "Memory must be a number (in MB)"
    fi

    if [[ "$memory_mb" -lt 128 ]] || [[ "$memory_mb" -gt 10240 ]]; then
        error "Memory must be between 128 and 10240 MB"
    fi

    # Update memorySize for all Function resources
    yq eval '(select(.kind == "Function") | .spec.forProvider.memorySize) = '"$memory_mb" "$CURRENT_FILE" > "$MODIFIED_FILE"

    # Generate default description
    if [[ -z "$CHANGE_DESC" ]]; then
        CHANGE_DESC="Bulk change: Set Lambda memory to ${memory_mb}MB"
    fi
}

# Apply timeout change
apply_timeout_change() {
    local timeout_sec="$1"

    log "Setting timeout to ${timeout_sec}s on all Lambda functions..."

    # Validate timeout value
    if ! [[ "$timeout_sec" =~ ^[0-9]+$ ]]; then
        error "Timeout must be a number (in seconds)"
    fi

    if [[ "$timeout_sec" -lt 1 ]] || [[ "$timeout_sec" -gt 900 ]]; then
        error "Timeout must be between 1 and 900 seconds"
    fi

    # Update timeout for all Function resources
    yq eval '(select(.kind == "Function") | .spec.forProvider.timeout) = '"$timeout_sec" "$CURRENT_FILE" > "$MODIFIED_FILE"

    # Generate default description
    if [[ -z "$CHANGE_DESC" ]]; then
        CHANGE_DESC="Bulk change: Set Lambda timeout to ${timeout_sec}s"
    fi
}

# Apply environment variable change
apply_env_change() {
    local env_pair="$1"
    local env_name="${env_pair%%=*}"
    local env_value="${env_pair#*=}"

    log "Adding/updating environment variable ${env_name} on all Lambda functions..."

    # Update or add the environment variable for all Function resources
    # The environment structure in Crossplane is: spec.forProvider.environment[0].variables
    yq eval '
        (select(.kind == "Function") | .spec.forProvider.environment[0].variables.'"$env_name"') = "'"$env_value"'"
    ' "$CURRENT_FILE" > "$MODIFIED_FILE"

    # Generate default description
    if [[ -z "$CHANGE_DESC" ]]; then
        CHANGE_DESC="Bulk change: Set ${env_name} environment variable"
    fi
}

# Remove environment variable
apply_remove_env_change() {
    local env_name="$1"

    log "Removing environment variable ${env_name} from all Lambda functions..."

    # Remove the environment variable for all Function resources
    yq eval '
        del(select(.kind == "Function") | .spec.forProvider.environment[0].variables.'"$env_name"')
    ' "$CURRENT_FILE" > "$MODIFIED_FILE"

    # Generate default description
    if [[ -z "$CHANGE_DESC" ]]; then
        CHANGE_DESC="Bulk change: Remove ${env_name} environment variable"
    fi
}

# Show diff
show_diff() {
    echo ""
    echo "========================================"
    echo "CHANGES TO BE APPLIED"
    echo "========================================"
    echo ""

    if command -v diff &> /dev/null; then
        diff -u "$CURRENT_FILE" "$MODIFIED_FILE" --color=always || true
    else
        echo "Modified configuration:"
        yq 'select(.kind == "Function") | {"name": .metadata.name, "memory": .spec.forProvider.memorySize, "timeout": .spec.forProvider.timeout, "env": .spec.forProvider.environment[0].variables}' "$MODIFIED_FILE"
    fi

    echo ""
}

# Push changes to ConfigHub
push_changes() {
    if [[ "$DRY_RUN" == "true" ]]; then
        echo ""
        echo "========================================"
        echo "DRY RUN - No changes applied"
        echo "========================================"
        echo ""
        warn "Run without --dry-run to apply these changes"
        return
    fi

    echo ""
    echo "========================================"
    echo "APPLYING CHANGES TO CONFIGHUB"
    echo "========================================"
    echo ""

    log "Pushing changes to ConfigHub..."
    log "Change description: ${CHANGE_DESC}"

    if cub unit update --space "$SPACE" "$UNIT" "$MODIFIED_FILE" \
        --change-desc "$CHANGE_DESC" \
        --wait; then
        success "Changes pushed to ConfigHub successfully"
    else
        error "Failed to push changes to ConfigHub"
    fi

    echo ""
    log "ConfigHub will sync to the Kubernetes actuator via ArgoCD"
    log "Crossplane will then reconcile the changes to AWS"
}

# Verify changes in AWS
verify_aws_changes() {
    if [[ "$VERIFY" != "true" ]]; then
        return
    fi

    echo ""
    echo "========================================"
    echo "VERIFYING CHANGES IN AWS"
    echo "========================================"
    echo ""

    # Load environment config to get function names
    if [[ -f "${PROJECT_ROOT}/config/dev.env" ]]; then
        source "${PROJECT_ROOT}/config/dev.env"
    else
        warn "Cannot load config/dev.env, using defaults"
        RESOURCE_PREFIX="messagewall"
    fi

    log "Waiting for Crossplane to reconcile (this may take 30-60 seconds)..."
    sleep 10

    # Check each Lambda function
    for func_suffix in "api-handler" "snapshot-writer"; do
        func_name="${RESOURCE_PREFIX}-${func_suffix}"
        log "Checking ${func_name}..."

        if aws lambda get-function-configuration \
            --function-name "$func_name" \
            --query '{Memory: MemorySize, Timeout: Timeout, Env: Environment.Variables}' \
            --output table 2>/dev/null; then
            success "Verified ${func_name}"
        else
            warn "Could not verify ${func_name} (may still be reconciling)"
        fi
    done

    echo ""
    log "If values haven't updated yet, check:"
    log "  1. ArgoCD sync status: kubectl get application messagewall-dev -n argocd"
    log "  2. Crossplane status: kubectl get functions.lambda -o wide"
}

# Show summary
show_summary() {
    echo ""
    echo "========================================"
    echo "BULK CHANGE SUMMARY"
    echo "========================================"
    echo ""
    echo "Change type:      ${CHANGE_TYPE}"
    echo "Change value:     ${CHANGE_VALUE}"
    echo "ConfigHub space:  ${SPACE}"
    echo "Affected unit:    ${UNIT}"
    echo "Functions updated: ${LAMBDA_COUNT}"
    echo "Description:      ${CHANGE_DESC}"
    echo ""

    if [[ "$DRY_RUN" == "true" ]]; then
        echo "Status: DRY RUN (no changes made)"
    else
        echo "Status: APPLIED"
        echo ""
        echo "To view the change in ConfigHub:"
        echo "  cub unit history --space ${SPACE} ${UNIT}"
        echo ""
        echo "To verify in Kubernetes:"
        echo "  kubectl get functions.lambda -o wide"
    fi
    echo ""
}

# Cleanup
cleanup() {
    if [[ -n "${TEMP_DIR:-}" ]] && [[ -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
    fi
}
trap cleanup EXIT

# Main execution
main() {
    echo ""
    echo "========================================"
    echo "CONFIGHUB BULK CHANGE DEMO"
    echo "========================================"
    echo ""
    echo "This demo shows how to update multiple Lambda functions"
    echo "in a single ConfigHub operation with full audit trail."
    echo ""

    check_prerequisites
    fetch_current_config

    # Apply the requested change type
    case "$CHANGE_TYPE" in
        memory)
            apply_memory_change "$CHANGE_VALUE"
            ;;
        timeout)
            apply_timeout_change "$CHANGE_VALUE"
            ;;
        env)
            apply_env_change "$CHANGE_VALUE"
            ;;
        remove-env)
            apply_remove_env_change "$CHANGE_VALUE"
            ;;
    esac

    show_diff
    push_changes
    verify_aws_changes
    show_summary
}

main
