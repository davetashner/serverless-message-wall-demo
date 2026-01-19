#!/bin/bash
# capture-drift-to-confighub.sh
#
# Phase 3 of ADR-011 bidirectional sync: Live → ConfigHub capture
#
# This script captures the current live state from Kubernetes/Crossplane
# and updates ConfigHub if drift is detected. Used after:
#   - Break-glass emergency changes
#   - Discovered drift from any source
#   - Reconciliation after incidents
#
# Usage:
#   ./scripts/capture-drift-to-confighub.sh [OPTIONS]
#
# Prerequisites:
#   - kubectl configured to access the actuator cluster
#   - cub CLI installed and authenticated
#   - yq installed for YAML processing

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Defaults
ENV="dev"
SPACE=""
NAMESPACE="default"
DRY_RUN=false
TAG="drift-capture"
INCIDENT_ID=""
TRIGGER_SYNC=false

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Capture live state from Kubernetes and update ConfigHub.

Options:
    --env ENV           Environment (default: dev)
    --space SPACE       ConfigHub space (default: from config/<env>.env)
    --namespace NS      Kubernetes namespace (default: default)
    --tag TAG           Tag for the capture (default: drift-capture)
                        Use "break-glass" for emergency reconciliation
    --incident ID       Incident ID for break-glass changes
    --trigger-sync      Trigger ConfigHub → Git sync after capture
    --dry-run           Show what would change without updating
    -h, --help          Show this help message

Examples:
    $(basename "$0")                          # Capture drift from dev
    $(basename "$0") --tag break-glass --incident INC-123
    $(basename "$0") --dry-run                # Preview changes
    $(basename "$0") --trigger-sync           # Capture and sync to Git

Change Types:
    drift-capture   - Detected drift (automated or discovered)
    break-glass     - Emergency manual change
    reconciliation  - Post-incident sync
EOF
    exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --env)
            ENV="$2"
            shift 2
            ;;
        --space)
            SPACE="$2"
            shift 2
            ;;
        --namespace)
            NAMESPACE="$2"
            shift 2
            ;;
        --tag)
            TAG="$2"
            shift 2
            ;;
        --incident)
            INCIDENT_ID="$2"
            shift 2
            ;;
        --trigger-sync)
            TRIGGER_SYNC=true
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
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log() { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# Load environment config
ENV_FILE="$REPO_ROOT/config/${ENV}.env"
if [[ ! -f "$ENV_FILE" ]]; then
    error "Config file not found: $ENV_FILE"
fi

# shellcheck disable=SC1090
source "$ENV_FILE"

# Use provided space or from config
SPACE="${SPACE:-$CONFIGHUB_SPACE}"

echo "=== Live → ConfigHub Drift Capture ==="
echo "Environment: $ENV"
echo "ConfigHub Space: $SPACE"
echo "Kubernetes Namespace: $NAMESPACE"
echo "Capture Tag: $TAG"
[[ -n "$INCIDENT_ID" ]] && echo "Incident ID: $INCIDENT_ID"
echo "Dry run: $DRY_RUN"
echo ""

# Check prerequisites
command -v kubectl >/dev/null 2>&1 || error "kubectl not found"
command -v cub >/dev/null 2>&1 || error "cub CLI not found"
command -v yq >/dev/null 2>&1 || error "yq not found"

# Create temp directory
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

# Step 1: Export live state from Kubernetes
log "Exporting live state from Kubernetes..."
mkdir -p "$WORK_DIR/live"

# Export Crossplane managed resources
# Look for common Crossplane AWS resource types
RESOURCE_TYPES=(
    "bucket.s3.aws.upbound.io"
    "table.dynamodb.aws.upbound.io"
    "function.lambda.aws.upbound.io"
    "rule.cloudwatchevents.aws.upbound.io"
    "role.iam.aws.upbound.io"
    "policy.iam.aws.upbound.io"
    "functionurl.lambda.aws.upbound.io"
)

LIVE_RESOURCES_FOUND=0

for resource_type in "${RESOURCE_TYPES[@]}"; do
    short_name=$(echo "$resource_type" | cut -d. -f1)

    # Get resources matching our prefix
    if kubectl get "$resource_type" -n "$NAMESPACE" \
        -l "managedBy=messagewall-demo" \
        -o yaml > "$WORK_DIR/live/${short_name}-raw.yaml" 2>/dev/null; then

        # Check if we got any resources
        count=$(yq '.items | length' "$WORK_DIR/live/${short_name}-raw.yaml" 2>/dev/null || echo "0")
        if [[ "$count" -gt 0 ]]; then
            log "  Found $count ${short_name} resource(s)"
            LIVE_RESOURCES_FOUND=$((LIVE_RESOURCES_FOUND + count))

            # Clean up the export (remove status, managedFields, etc.)
            yq eval '.items[] | del(.status) | del(.metadata.managedFields) | del(.metadata.resourceVersion) | del(.metadata.uid) | del(.metadata.generation) | del(.metadata.creationTimestamp)' \
                "$WORK_DIR/live/${short_name}-raw.yaml" > "$WORK_DIR/live/${short_name}.yaml" 2>/dev/null || true
        else
            rm -f "$WORK_DIR/live/${short_name}-raw.yaml"
        fi
    fi
done

# Also try to get ServerlessEventApp claims if using XRD
if kubectl get serverlesseventapp -n "$NAMESPACE" -o yaml > "$WORK_DIR/live/claims-raw.yaml" 2>/dev/null; then
    count=$(yq '.items | length' "$WORK_DIR/live/claims-raw.yaml" 2>/dev/null || echo "0")
    if [[ "$count" -gt 0 ]]; then
        log "  Found $count ServerlessEventApp claim(s)"
        LIVE_RESOURCES_FOUND=$((LIVE_RESOURCES_FOUND + count))
        yq eval '.items[] | del(.status) | del(.metadata.managedFields) | del(.metadata.resourceVersion) | del(.metadata.uid) | del(.metadata.generation) | del(.metadata.creationTimestamp)' \
            "$WORK_DIR/live/claims-raw.yaml" > "$WORK_DIR/live/claims.yaml" 2>/dev/null || true
    fi
fi
rm -f "$WORK_DIR/live/"*-raw.yaml

if [[ "$LIVE_RESOURCES_FOUND" -eq 0 ]]; then
    warn "No managed resources found in namespace $NAMESPACE"
    warn "Make sure resources are labeled with managedBy=messagewall-demo"
    exit 0
fi

success "Exported $LIVE_RESOURCES_FOUND resource(s) from Kubernetes"

# Step 2: Export current ConfigHub state
log "Exporting current state from ConfigHub..."
mkdir -p "$WORK_DIR/confighub"

UNITS=$(cub unit list --space "$SPACE" --format json 2>/dev/null | jq -r '.[].name' || echo "")

if [[ -z "$UNITS" ]]; then
    warn "No units found in ConfigHub space $SPACE"
else
    for unit in $UNITS; do
        cub unit export --space "$SPACE" "$unit" > "$WORK_DIR/confighub/${unit}.yaml" 2>/dev/null || {
            warn "Failed to export unit $unit"
        }
    done
    success "Exported units from ConfigHub"
fi

# Step 3: Compare and detect drift
log "Comparing live state with ConfigHub state..."
echo ""

DRIFTS=""
HAS_DRIFT=false

# Compare each live resource with ConfigHub
for live_file in "$WORK_DIR/live/"*.yaml; do
    [[ -f "$live_file" ]] || continue
    resource_type=$(basename "$live_file" .yaml)

    # Find corresponding ConfigHub unit
    # The mapping depends on how units are structured
    # For now, assume unit names map to resource types
    ch_file="$WORK_DIR/confighub/${resource_type}.yaml"

    if [[ ! -f "$ch_file" ]]; then
        # Try alternative names
        for alt in "$WORK_DIR/confighub/"*.yaml; do
            [[ -f "$alt" ]] || continue
            # Check if the unit contains resources of this type
            if yq eval "select(.kind != null)" "$alt" 2>/dev/null | grep -q "kind:"; then
                ch_file="$alt"
                break
            fi
        done
    fi

    if [[ -f "$ch_file" ]]; then
        # Normalize and compare
        LIVE_CONTENT=$(yq eval -P "$live_file" 2>/dev/null || cat "$live_file")
        CH_CONTENT=$(yq eval -P "$ch_file" 2>/dev/null || cat "$ch_file")

        if [[ "$LIVE_CONTENT" != "$CH_CONTENT" ]]; then
            echo -e "${YELLOW}DRIFT: ${resource_type}${NC}"
            HAS_DRIFT=true
            DRIFTS+="- ${resource_type}\n"

            if [[ "$DRY_RUN" == "true" ]]; then
                echo "  Diff (ConfigHub → Live):"
                diff -u "$ch_file" "$live_file" 2>/dev/null | head -20 || true
                echo ""
            fi
        else
            echo -e "${GREEN}MATCH: ${resource_type}${NC}"
        fi
    else
        echo -e "${YELLOW}NEW: ${resource_type} (in live, not in ConfigHub)${NC}"
        HAS_DRIFT=true
        DRIFTS+="- ${resource_type} (new in live)\n"
    fi
done

echo ""

if [[ "$HAS_DRIFT" == "false" ]]; then
    success "No drift detected. Live state matches ConfigHub."
    exit 0
fi

echo -e "${YELLOW}Drift detected between live state and ConfigHub${NC}"
echo ""

if [[ "$DRY_RUN" == "true" ]]; then
    echo "Dry run complete. Changes that would be captured:"
    echo -e "$DRIFTS"
    exit 0
fi

# Step 4: Capture drift to ConfigHub
log "Capturing drift to ConfigHub..."

TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
CHANGE_DESC="${TAG}: Captured live state at ${TIMESTAMP}"
if [[ -n "$INCIDENT_ID" ]]; then
    CHANGE_DESC="${TAG} (${INCIDENT_ID}): Captured live state at ${TIMESTAMP}"
fi

for live_file in "$WORK_DIR/live/"*.yaml; do
    [[ -f "$live_file" ]] || continue
    resource_type=$(basename "$live_file" .yaml)

    # Add capture metadata
    ANNOTATED_FILE="$WORK_DIR/annotated-${resource_type}.yaml"

    # Add annotations for traceability
    yq eval '
        .metadata.annotations."drift-capture/timestamp" = "'"$TIMESTAMP"'" |
        .metadata.annotations."drift-capture/tag" = "'"$TAG"'" |
        .metadata.annotations."drift-capture/source" = "kubernetes-live"
    ' "$live_file" > "$ANNOTATED_FILE" 2>/dev/null || cp "$live_file" "$ANNOTATED_FILE"

    if [[ -n "$INCIDENT_ID" ]]; then
        yq eval -i '
            .metadata.annotations."drift-capture/incident" = "'"$INCIDENT_ID"'"
        ' "$ANNOTATED_FILE" 2>/dev/null || true
    fi

    # Update ConfigHub unit
    log "  Updating unit: $resource_type"
    if cub unit update --space "$SPACE" "$resource_type" "$ANNOTATED_FILE" \
        --change-desc "$CHANGE_DESC" \
        --wait 2>/dev/null; then
        success "    Captured: $resource_type"
    else
        warn "    Failed to update $resource_type (unit may not exist)"
        # Try creating the unit if it doesn't exist
        if cub unit create --space "$SPACE" "$resource_type" "$ANNOTATED_FILE" \
            --change-desc "$CHANGE_DESC" 2>/dev/null; then
            success "    Created: $resource_type"
        fi
    fi
done

success "Drift captured to ConfigHub"

# Step 5: Optionally trigger ConfigHub → Git sync
if [[ "$TRIGGER_SYNC" == "true" ]]; then
    log "Triggering ConfigHub → Git sync..."

    if [[ -x "$REPO_ROOT/scripts/sync-confighub-to-git.sh" ]]; then
        "$REPO_ROOT/scripts/sync-confighub-to-git.sh" --env "$ENV"
    else
        warn "Sync script not found or not executable"
        echo "Run manually: ./scripts/sync-confighub-to-git.sh --env $ENV"
    fi
fi

# Summary
echo ""
echo "=== Drift Capture Summary ==="
echo ""
echo "Captured drift:"
echo -e "$DRIFTS"
echo ""
echo "Capture tag: $TAG"
[[ -n "$INCIDENT_ID" ]] && echo "Incident ID: $INCIDENT_ID"
echo "Timestamp: $TIMESTAMP"
echo ""
echo "View changes in ConfigHub:"
echo "  cub unit history --space $SPACE"
echo ""
echo "To sync changes to Git:"
echo "  ./scripts/sync-confighub-to-git.sh --env $ENV"
