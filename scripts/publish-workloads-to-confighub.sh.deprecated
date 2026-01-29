#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
WORKLOADS_DIR="${PROJECT_ROOT}/infra/workloads"
SPACE="messagewall-workloads"

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Publish microservice deployment manifests to ConfigHub.

Creates ConfigHub units for each microservice and publishes the manifests.
Optionally applies the revisions to make them live.

OPTIONS:
    --space NAME    ConfigHub space name (default: ${SPACE})
    --apply         Apply revisions after publishing (make them live)
    --dry-run       Show what would be published without doing it
    -h, --help      Show this help message

PREREQUISITES:
    - cub CLI installed and authenticated (cub auth login)
    - ConfigHub space exists (cub space create ${SPACE})

EXAMPLES:
    # Publish manifests (creates revisions but doesn't apply)
    $(basename "$0")

    # Publish and apply (make revisions live immediately)
    $(basename "$0") --apply

EOF
    exit 0
}

DRY_RUN=false
APPLY=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --space)
            SPACE="$2"
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

# Check prerequisites
if ! command -v cub &> /dev/null; then
    echo "Error: cub CLI is not installed"
    exit 1
fi

if ! cub auth status &> /dev/null; then
    echo "Error: Not authenticated to ConfigHub. Run: cub auth login"
    exit 1
fi

# Check if space exists, create if not
echo "Checking ConfigHub space '${SPACE}'..."
if ! cub space get "${SPACE}" &> /dev/null; then
    if [[ "${DRY_RUN}" == "true" ]]; then
        echo "[DRY RUN] Would create space: ${SPACE}"
    else
        echo "Creating space '${SPACE}'..."
        cub space create "${SPACE}" --metadata "environment=workloads"
    fi
fi

echo ""
echo "Publishing microservice manifests to ConfigHub space '${SPACE}'..."
echo ""

# Publish each manifest
for manifest in "${WORKLOADS_DIR}"/*.yaml; do
    if [[ ! -f "$manifest" ]]; then
        continue
    fi

    name=$(basename "$manifest" .yaml)
    echo "Publishing: ${name}"

    if [[ "${DRY_RUN}" == "true" ]]; then
        echo "  [DRY RUN] Would publish ${manifest} as unit '${name}'"
    else
        # Create unit if it doesn't exist
        cub unit create --space "${SPACE}" "${name}" --allow-exists 2>/dev/null || true

        # Publish new revision
        cub unit update --space "${SPACE}" "${name}" --file "${manifest}"

        if [[ "${APPLY}" == "true" ]]; then
            echo "  Applying revision..."
            cub unit apply --space "${SPACE}" "${name}"
        fi
    fi
done

echo ""
echo "Published all microservice manifests."

if [[ "${APPLY}" == "false" ]] && [[ "${DRY_RUN}" == "false" ]]; then
    echo ""
    echo "Note: Revisions created but not applied. To make them live:"
    echo ""
    echo "  # Apply all at once:"
    for manifest in "${WORKLOADS_DIR}"/*.yaml; do
        name=$(basename "$manifest" .yaml)
        echo "  cub unit apply --space ${SPACE} ${name}"
    done
    echo ""
    echo "  # Or use --apply flag next time:"
    echo "  $(basename "$0") --apply"
fi

echo ""
echo "ArgoCD will sync once revisions are applied and LiveRevisionNum > 0."
