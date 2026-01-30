#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Regional configuration (bash 3.2 compatible - parallel arrays)
REGION_SUFFIXES=("east" "west")
REGION_VALUES=("us-east-1" "us-west-2")

# Environments to create
ENVIRONMENTS=("dev" "prod")

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Create ConfigHub spaces for multi-region messagewall deployment.

Creates:
  - messagewall-dev-east (Region=us-east-1)
  - messagewall-dev-west (Region=us-west-2)
  - messagewall-prod-east (Region=us-east-1)
  - messagewall-prod-west (Region=us-west-2)

OPTIONS:
    --dry-run    Print what would be done without executing
    -h, --help   Show this help message

PREREQUISITES:
    - cub CLI installed and authenticated (cub auth login)

EXAMPLES:
    $(basename "$0")              # Create regional spaces
    $(basename "$0") --dry-run    # Preview without creating

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
echo "Checking prerequisites..."

if ! command -v cub &> /dev/null; then
    echo "Error: cub CLI is not installed"
    echo "Install from: https://github.com/confighub/cub/releases"
    exit 1
fi

# Check if authenticated
SPACE_LIST=$(cub space list 2>&1 || true)
if echo "$SPACE_LIST" | grep -qE "(not authenticated|worker associated|401|403|expired)"; then
    echo "Error: ConfigHub credentials expired or invalid."
    echo "Run: cub auth login"
    exit 1
fi

echo "Creating multi-region ConfigHub spaces..."
echo ""

for env in "${ENVIRONMENTS[@]}"; do
    for i in "${!REGION_SUFFIXES[@]}"; do
        suffix="${REGION_SUFFIXES[$i]}"
        region="${REGION_VALUES[$i]}"
        space_name="messagewall-${env}-${suffix}"

        echo "Creating space: ${space_name} (Region=${region}, Environment=${env})"

        if [[ "${DRY_RUN}" == "true" ]]; then
            echo "  [DRY RUN] Would create space '${space_name}' with labels:"
            echo "    - Environment=${env}"
            echo "    - Application=messagewall"
            echo "    - Region=${region}"
        else
            # Check if space already exists
            if echo "$SPACE_LIST" | grep -qE "^${space_name}[[:space:]]"; then
                echo "  Space '${space_name}' already exists, skipping"
            else
                cub space create "${space_name}" \
                    --label Environment="${env}" \
                    --label Application=messagewall \
                    --label Region="${region}"
                echo "  Created successfully"
            fi
        fi
        echo ""
    done
done

echo "Multi-region ConfigHub spaces configured."
echo ""
echo "Spaces created:"
for env in "${ENVIRONMENTS[@]}"; do
    for i in "${!REGION_SUFFIXES[@]}"; do
        suffix="${REGION_SUFFIXES[$i]}"
        region="${REGION_VALUES[$i]}"
        echo "  - messagewall-${env}-${suffix} (Environment=${env}, Region=${region})"
    done
done
echo ""
echo "Next steps:"
echo "  1. Create regional actuator clusters:"
echo "     scripts/bootstrap-kind.sh --name actuator-east --region us-east-1"
echo "     scripts/bootstrap-kind.sh --name actuator-west --region us-west-2"
echo ""
echo "  2. Install Crossplane on each cluster:"
echo "     scripts/bootstrap-crossplane.sh --context kind-actuator-east"
echo "     scripts/bootstrap-crossplane.sh --context kind-actuator-west"
echo ""
echo "  3. Configure ArgoCD auth for each cluster:"
echo "     scripts/setup-argocd-confighub-auth.sh --context kind-actuator-east --space messagewall-dev-east"
echo "     scripts/setup-argocd-confighub-auth.sh --context kind-actuator-west --space messagewall-dev-west"
