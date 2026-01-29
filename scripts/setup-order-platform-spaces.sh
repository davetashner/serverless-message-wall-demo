#!/bin/bash
set -euo pipefail

# Setup ConfigHub spaces for Order Platform multi-tenancy demo
# Creates 10 spaces (5 teams × 2 environments) with labels for bulk operations
# See ADR-013 for design rationale

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TEAMS=("platform-ops" "data" "customer" "integrations" "compliance")
ENVS=("dev" "prod")

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Create ConfigHub spaces for Order Platform multi-tenancy demo.

Creates 10 spaces (5 teams × 2 environments) with labels:
  - Application=order-platform
  - Team=<team-name>
  - Environment=<dev|prod>

OPTIONS:
    --dry-run       Show what would be created without executing
    -h, --help      Show this help message

PREREQUISITES:
    - cub CLI installed and authenticated (cub auth login)

EXAMPLES:
    # Create all spaces
    $(basename "$0")

    # Preview what would be created
    $(basename "$0") --dry-run

EOF
    exit 0
}

DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case $1 in
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

# Check if authenticated by trying to list spaces
AUTH_CHECK=$(cub space list 2>&1 || true)
if echo "$AUTH_CHECK" | grep -qE "(not authenticated|worker associated|401|403|expired)"; then
    echo "Error: ConfigHub credentials expired or invalid."
    echo "Run: cub auth login"
    exit 1
fi

echo "Creating ConfigHub spaces for Order Platform..."
echo ""

for team in "${TEAMS[@]}"; do
    for env in "${ENVS[@]}"; do
        space_name="order-${team}-${env}"

        if [[ "${DRY_RUN}" == "true" ]]; then
            echo "[DRY RUN] Would create space: ${space_name}"
            echo "          Labels: Application=order-platform, Team=${team}, Environment=${env}"
        else
            echo "Creating space: ${space_name}"
            cub space create "${space_name}" \
                --label "Application=order-platform" \
                --label "Team=${team}" \
                --label "Environment=${env}" \
                --allow-exists \
                || { echo "Failed to create space ${space_name}"; exit 1; }
        fi
    done
done

echo ""
echo "ConfigHub spaces created successfully."
echo ""
echo "Spaces created:"
for team in "${TEAMS[@]}"; do
    for env in "${ENVS[@]}"; do
        echo "  - order-${team}-${env}"
    done
done

echo ""
echo "Next steps:"
echo "  1. Publish manifests: ./scripts/publish-order-platform.sh"
echo "  2. Apply ArgoCD Applications: kubectl apply -f platform/argocd/application-order-platform.yaml"
