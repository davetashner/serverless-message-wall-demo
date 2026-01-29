#!/bin/bash
set -euo pipefail

# Publish Order Platform manifests to ConfigHub
# Each team/env directory maps to a ConfigHub space
# See ADR-013 for design rationale

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ORDER_PLATFORM_DIR="${PROJECT_ROOT}/infra/order-platform"

TEAMS=("platform-ops" "data" "customer" "integrations" "compliance")
ENVS=("dev" "prod")

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Publish Order Platform manifests to ConfigHub spaces.

Each team/environment directory is published to its corresponding space:
  infra/order-platform/{team}/{env}/ → order-{team}-{env} space

OPTIONS:
    --team TEAM     Only publish for specific team (platform-ops, data, customer, integrations, compliance)
    --env ENV       Only publish for specific environment (dev, prod)
    --apply         Apply revisions after publishing (make them live)
    --dry-run       Show what would be published without executing
    -h, --help      Show this help message

PREREQUISITES:
    - cub CLI installed and authenticated (cub auth login)
    - ConfigHub spaces exist (run setup-order-platform-spaces.sh first)

EXAMPLES:
    # Publish all teams and environments
    $(basename "$0")

    # Publish and apply (make live)
    $(basename "$0") --apply

    # Publish only dev environments
    $(basename "$0") --env dev

    # Publish only data team
    $(basename "$0") --team data

    # Publish data team dev only
    $(basename "$0") --team data --env dev --apply

EOF
    exit 0
}

DRY_RUN=false
APPLY=false
FILTER_TEAM=""
FILTER_ENV=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --team)
            FILTER_TEAM="$2"
            shift 2
            ;;
        --env)
            FILTER_ENV="$2"
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

echo "Publishing Order Platform manifests to ConfigHub..."
echo ""

publish_count=0
error_count=0

for team in "${TEAMS[@]}"; do
    # Skip if filtering by team and doesn't match
    if [[ -n "${FILTER_TEAM}" && "${team}" != "${FILTER_TEAM}" ]]; then
        continue
    fi

    for env in "${ENVS[@]}"; do
        # Skip if filtering by env and doesn't match
        if [[ -n "${FILTER_ENV}" && "${env}" != "${FILTER_ENV}" ]]; then
            continue
        fi

        space_name="order-${team}-${env}"
        manifest_dir="${ORDER_PLATFORM_DIR}/${team}/${env}"

        if [[ ! -d "${manifest_dir}" ]]; then
            echo "Warning: Directory not found: ${manifest_dir}"
            continue
        fi

        echo "Publishing to space: ${space_name}"

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

                # Publish new revision (file is positional argument, not --file flag)
                if cub unit update --space "${space_name}" "${unit_name}" "${manifest}" 2>/dev/null; then
                    ((publish_count++))

                    if [[ "${APPLY}" == "true" ]]; then
                        echo "    Applying revision..."
                        cub unit apply --space "${space_name}" "${unit_name}" 2>/dev/null || true
                    fi
                else
                    echo "    Error: Failed to publish ${unit_name}"
                    ((error_count++))
                fi
            fi
        done

        echo ""
    done
done

echo "Publishing complete."
echo "  Published: ${publish_count} units"
if [[ ${error_count} -gt 0 ]]; then
    echo "  Errors: ${error_count}"
fi

if [[ "${APPLY}" == "false" ]] && [[ "${DRY_RUN}" == "false" ]]; then
    echo ""
    echo "Note: Revisions created but not applied. To make them live:"
    echo "  $(basename "$0") --apply"
    echo ""
    echo "Or apply selectively:"
    echo "  $(basename "$0") --env dev --apply    # Apply all dev"
    echo "  $(basename "$0") --team data --apply  # Apply all data team"
fi
