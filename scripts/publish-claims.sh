#!/bin/bash
# DEPRECATED: Replaced by scripts/render-composition.sh + CI workflow (ADR-014)
# This script published Claims to ConfigHub. The new pipeline renders Claims
# through the Composition and publishes fully-expanded managed resources.
# See: docs/decisions/014-confighub-stores-expanded-resources.md
set -euo pipefail

# Publish rendered Kustomize claims to ConfigHub
# Uses kustomize to render overlays, then publishes to appropriate ConfigHub spaces

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
CLAIMS_DIR="${PROJECT_ROOT}/infra/claims"

# Get ConfigHub space name for an overlay
get_space_name() {
    local overlay="$1"
    case "$overlay" in
        dev-east)  echo "messagewall-dev-east" ;;
        dev-west)  echo "messagewall-dev-west" ;;
        prod-east) echo "messagewall-prod-east" ;;
        prod-west) echo "messagewall-prod-west" ;;
        *) echo "" ;;
    esac
}

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Render Kustomize overlays and publish claims to ConfigHub spaces.

Overlays map to ConfigHub spaces:
  infra/claims/overlays/dev-east/   → messagewall-dev-east
  infra/claims/overlays/dev-west/   → messagewall-dev-west
  infra/claims/overlays/prod-east/  → messagewall-prod-east
  infra/claims/overlays/prod-west/  → messagewall-prod-west

OPTIONS:
    --overlay NAME    Overlay to publish: dev-east, dev-west, prod-east, prod-west, or all
                      (default: all)
    --apply           Apply revisions after publishing (make them live)
    --dry-run         Show rendered output without publishing
    --output-dir DIR  Write rendered YAML to directory (for inspection)
    -h, --help        Show this help message

PREREQUISITES:
    - kustomize CLI or kubectl installed
    - cub CLI installed and authenticated (cub auth login)
    - ConfigHub spaces must exist

EXAMPLES:
    # Preview what would be published (all overlays)
    $(basename "$0") --dry-run

    # Publish dev-east overlay
    $(basename "$0") --overlay dev-east

    # Publish and apply prod-west overlay
    $(basename "$0") --overlay prod-west --apply

    # Publish all overlays
    $(basename "$0") --apply

    # Render to files for inspection
    $(basename "$0") --dry-run --output-dir /tmp/rendered-claims

EOF
    exit 0
}

DRY_RUN=false
APPLY=false
OVERLAY="all"
OUTPUT_DIR=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --overlay)
            OVERLAY="$2"
            shift 2
            ;;
        --apply)
            APPLY=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --output-dir)
            OUTPUT_DIR="$2"
            shift 2
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

# Validate overlay
case "${OVERLAY}" in
    dev-east|dev-west|prod-east|prod-west|all) ;;
    *)
        echo "Error: Invalid overlay '${OVERLAY}'"
        echo "Valid options: dev-east, dev-west, prod-east, prod-west, all"
        exit 1
        ;;
esac

# Check prerequisites - prefer kustomize CLI, fall back to kubectl kustomize
KUSTOMIZE_CMD=""
if command -v kustomize &> /dev/null; then
    KUSTOMIZE_CMD="kustomize build"
elif command -v kubectl &> /dev/null; then
    KUSTOMIZE_CMD="kubectl kustomize"
else
    echo "Error: Neither kustomize nor kubectl is installed"
    echo "Install kustomize with: brew install kustomize"
    exit 1
fi

if [[ "${DRY_RUN}" == "false" ]]; then
    if ! command -v cub &> /dev/null; then
        echo "Error: cub CLI is not installed"
        exit 1
    fi

    if ! cub auth status &> /dev/null; then
        echo "Error: Not authenticated to ConfigHub. Run: cub auth login"
        exit 1
    fi
fi

# Create output directory if specified
if [[ -n "${OUTPUT_DIR}" ]]; then
    mkdir -p "${OUTPUT_DIR}"
fi

echo "Publishing claims to ConfigHub..."
echo ""

publish_count=0
error_count=0

publish_overlay() {
    local overlay_name="$1"
    local space_name
    space_name=$(get_space_name "$overlay_name")
    local overlay_dir="${CLAIMS_DIR}/overlays/${overlay_name}"

    if [[ -z "${space_name}" ]]; then
        echo "Warning: Unknown overlay: ${overlay_name}"
        return
    fi

    if [[ ! -d "${overlay_dir}" ]]; then
        echo "Warning: Overlay directory not found: ${overlay_dir}"
        return
    fi

    echo "=== ${overlay_name} ==="
    echo "  Space: ${space_name}"
    echo "  Source: ${overlay_dir}"

    # Render the kustomize overlay
    local rendered
    if ! rendered=$(${KUSTOMIZE_CMD} "${overlay_dir}" 2>&1); then
        echo "  Error: kustomize build failed:"
        echo "${rendered}" | sed 's/^/    /'
        error_count=$((error_count + 1))
        return
    fi

    # Extract the claim name from rendered output
    local claim_name
    claim_name=$(echo "${rendered}" | grep -E '^  name:' | head -1 | awk '{print $2}')

    if [[ -z "${claim_name}" ]]; then
        echo "  Error: Could not extract claim name from rendered output"
        error_count=$((error_count + 1))
        return
    fi

    echo "  Claim: ${claim_name}"

    # Output to file if requested
    if [[ -n "${OUTPUT_DIR}" ]]; then
        local output_file="${OUTPUT_DIR}/${overlay_name}-claim.yaml"
        echo "${rendered}" > "${output_file}"
        echo "  Written to: ${output_file}"
    fi

    if [[ "${DRY_RUN}" == "true" ]]; then
        echo "  [DRY RUN] Would publish to ${space_name}"
        echo ""
        echo "Rendered YAML:"
        echo "${rendered}" | sed 's/^/    /'
        echo ""
    else
        # Create temp file for the rendered output
        local temp_file
        temp_file=$(mktemp)
        echo "${rendered}" > "${temp_file}"

        # Create unit if it doesn't exist
        local unit_name="${claim_name}"
        if ! cub unit create --space "${space_name}" "${unit_name}" --allow-exists 2>/dev/null; then
            echo "  Warning: Could not create unit ${unit_name}"
        fi

        # Publish new revision
        if cub unit update --space "${space_name}" "${unit_name}" "${temp_file}" 2>/dev/null; then
            publish_count=$((publish_count + 1))
            echo "  Published: ${unit_name}"

            if [[ "${APPLY}" == "true" ]]; then
                echo "  Applying revision..."
                cub unit apply --space "${space_name}" "${unit_name}" 2>/dev/null || true
            fi
        else
            echo "  Error: Failed to publish ${unit_name}"
            error_count=$((error_count + 1))
        fi

        rm -f "${temp_file}"
    fi

    echo ""
}

# Publish based on overlay selection
if [[ "${OVERLAY}" == "all" ]]; then
    for overlay_name in dev-east dev-west prod-east prod-west; do
        publish_overlay "${overlay_name}"
    done
else
    publish_overlay "${OVERLAY}"
fi

echo "Publishing complete."
if [[ "${DRY_RUN}" == "false" ]]; then
    echo "  Published: ${publish_count} claims"
    if [[ ${error_count} -gt 0 ]]; then
        echo "  Errors: ${error_count}"
    fi

    if [[ "${APPLY}" == "false" ]]; then
        echo ""
        echo "Note: Revisions created but not applied. To make them live:"
        echo "  $(basename "$0") --apply"
    fi
fi
