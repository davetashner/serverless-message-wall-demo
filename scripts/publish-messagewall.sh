#!/bin/bash
set -euo pipefail

# Publish messagewall infrastructure manifests to ConfigHub
# Supports single-region (base) and multi-region (east/west) deployments

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
INFRA_DIR="${PROJECT_ROOT}/infra"

# Region mapping
declare -A REGION_CONFIGS=(
    ["base"]="messagewall-dev"
    ["east"]="messagewall-dev-east"
    ["west"]="messagewall-dev-west"
)

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Publish messagewall infrastructure manifests to ConfigHub spaces.

Manifest directories map to ConfigHub spaces:
  infra/base/              → messagewall-dev       (single-region, us-east-1)
  infra/messagewall-east/  → messagewall-dev-east  (us-east-1)
  infra/messagewall-west/  → messagewall-dev-west  (us-west-2)

OPTIONS:
    --region REGION   Region to publish: base, east, west, or all (default: base)
    --apply           Apply revisions after publishing (make them live)
    --dry-run         Show what would be published without executing
    -h, --help        Show this help message

PREREQUISITES:
    - cub CLI installed and authenticated (cub auth login)
    - ConfigHub spaces exist (run setup-multiregion-spaces.sh for multi-region)

EXAMPLES:
    # Publish base (single-region) manifests
    $(basename "$0")

    # Publish and apply
    $(basename "$0") --apply

    # Publish to east region only
    $(basename "$0") --region east --apply

    # Publish to west region only
    $(basename "$0") --region west --apply

    # Publish to all regions (base, east, west)
    $(basename "$0") --region all --apply

EOF
    exit 0
}

DRY_RUN=false
APPLY=false
REGION="base"

while [[ $# -gt 0 ]]; do
    case $1 in
        --region)
            REGION="$2"
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
        -h|--help)
            usage
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

# Validate region
if [[ "${REGION}" != "base" && "${REGION}" != "east" && "${REGION}" != "west" && "${REGION}" != "all" ]]; then
    echo "Error: Invalid region '${REGION}'. Must be: base, east, west, or all"
    exit 1
fi

# Check prerequisites
if ! command -v cub &> /dev/null; then
    echo "Error: cub CLI is not installed"
    exit 1
fi

if ! cub auth status &> /dev/null; then
    echo "Error: Not authenticated to ConfigHub. Run: cub auth login"
    exit 1
fi

echo "Publishing messagewall manifests to ConfigHub..."
echo ""

publish_count=0
error_count=0

publish_region() {
    local region_key="$1"
    local space_name="${REGION_CONFIGS[$region_key]}"
    local manifest_dir

    if [[ "${region_key}" == "base" ]]; then
        manifest_dir="${INFRA_DIR}/base"
    else
        manifest_dir="${INFRA_DIR}/messagewall-${region_key}"
    fi

    if [[ ! -d "${manifest_dir}" ]]; then
        echo "Warning: Directory not found: ${manifest_dir}"
        return
    fi

    echo "Publishing to space: ${space_name} (from ${manifest_dir})"

    for manifest in "${manifest_dir}"/*.yaml; do
        if [[ ! -f "$manifest" ]]; then
            continue
        fi

        unit_name=$(basename "$manifest" .yaml)

        if [[ "${DRY_RUN}" == "true" ]]; then
            echo "  [DRY RUN] Would publish ${unit_name} from ${manifest}"
        else
            echo "  Publishing: ${unit_name}"

            # Create unit if it doesn't exist
            if ! cub unit create --space "${space_name}" "${unit_name}" --allow-exists 2>/dev/null; then
                echo "    Warning: Could not create unit ${unit_name}"
            fi

            # Publish new revision
            if cub unit update --space "${space_name}" "${unit_name}" "${manifest}" 2>/dev/null; then
                ((publish_count++)) || true

                if [[ "${APPLY}" == "true" ]]; then
                    echo "    Applying revision..."
                    cub unit apply --space "${space_name}" "${unit_name}" 2>/dev/null || true
                fi
            else
                echo "    Error: Failed to publish ${unit_name}"
                ((error_count++)) || true
            fi
        fi
    done

    echo ""
}

# Publish based on region selection
if [[ "${REGION}" == "all" ]]; then
    for region_key in "base" "east" "west"; do
        publish_region "${region_key}"
    done
else
    publish_region "${REGION}"
fi

echo "Publishing complete."
echo "  Published: ${publish_count} units"
if [[ ${error_count} -gt 0 ]]; then
    echo "  Errors: ${error_count}"
fi

if [[ "${APPLY}" == "false" ]] && [[ "${DRY_RUN}" == "false" ]]; then
    echo ""
    echo "Note: Revisions created but not applied. To make them live:"
    echo "  $(basename "$0") --apply"
fi
