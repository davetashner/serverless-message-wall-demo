#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Setup production ConfigHub space for messagewall
#
# This script creates the messagewall-prod ConfigHub space with appropriate
# metadata for production-tier governance. It also sets up the worker and
# ArgoCD integration for syncing to the actuator cluster.
#
# Prerequisites:
#   - cub CLI installed and authenticated (cub auth login)
#   - kubectl configured with access to the actuator cluster
#   - ArgoCD installed (run bootstrap-argocd.sh first)
#
# Usage:
#   ./scripts/setup-prod-space.sh [OPTIONS]
#
# Options:
#   --dry-run    Show what would be done without executing
#   --skip-argocd Skip ArgoCD credential setup
#   -h, --help   Show this help message

set -euo pipefail

SPACE="messagewall-prod"
WORKER_NAME="actuator-sync"
CLUSTER_CONTEXT="kind-actuator"
DRY_RUN=false
SKIP_ARGOCD=false

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Setup production ConfigHub space for the messagewall demo.

This script:
  1. Creates the messagewall-prod ConfigHub space
  2. Creates a worker for the actuator to sync from the space
  3. Configures ArgoCD credentials (optional)

OPTIONS:
    --dry-run       Show what would be done without executing
    --skip-argocd   Skip ArgoCD credential setup
    -h, --help      Show this help message

PREREQUISITES:
    - cub CLI installed and authenticated (cub auth login)
    - kubectl configured with access to the actuator cluster
    - ArgoCD installed (run bootstrap-argocd.sh first)

EXAMPLES:
    # Full setup
    $(basename "$0")

    # Preview only
    $(basename "$0") --dry-run

    # Skip ArgoCD (just create space and worker)
    $(basename "$0") --skip-argocd

EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --skip-argocd)
            SKIP_ARGOCD=true
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

echo "=== Production Space Setup ==="
echo ""
echo "Space: ${SPACE}"
echo "Worker: ${WORKER_NAME}"
echo "Dry run: ${DRY_RUN}"
echo ""

# Check prerequisites
echo "Checking prerequisites..."

if ! command -v cub &> /dev/null; then
    echo "Error: cub CLI is not installed"
    echo "Install from: https://github.com/confighub/cub/releases"
    exit 1
fi

if ! cub auth status &> /dev/null; then
    echo "Error: Not authenticated to ConfigHub. Run: cub auth login"
    exit 1
fi

echo "  cub CLI: OK"
echo "  ConfigHub auth: OK"

if [[ "${SKIP_ARGOCD}" == "false" ]]; then
    if ! command -v kubectl &> /dev/null; then
        echo "Error: kubectl is not installed"
        exit 1
    fi

    if ! kubectl cluster-info --context "${CLUSTER_CONTEXT}" &> /dev/null; then
        echo "Error: Cannot reach cluster '${CLUSTER_CONTEXT}'"
        exit 1
    fi
    echo "  kubectl: OK"
    echo "  Cluster access: OK"
fi

echo ""

# Step 1: Create the space
echo "Step 1: Creating ConfigHub space '${SPACE}'..."

if [[ "${DRY_RUN}" == "true" ]]; then
    echo "  [DRY RUN] Would run: cub space create ${SPACE}"
else
    if cub space get "${SPACE}" &> /dev/null; then
        echo "  Space '${SPACE}' already exists"
    else
        cub space create "${SPACE}"
        echo "  Space created"
    fi
fi

echo ""

# Step 2: Create worker
echo "Step 2: Creating worker '${WORKER_NAME}' in space '${SPACE}'..."

if [[ "${DRY_RUN}" == "true" ]]; then
    echo "  [DRY RUN] Would run: cub worker create --space ${SPACE} ${WORKER_NAME} --allow-exists"
else
    cub worker create --space "${SPACE}" "${WORKER_NAME}" --allow-exists
    echo "  Worker created/verified"
fi

echo ""

# Step 3: Configure ArgoCD (optional)
if [[ "${SKIP_ARGOCD}" == "false" ]]; then
    echo "Step 3: Configuring ArgoCD credentials..."

    if [[ "${DRY_RUN}" == "true" ]]; then
        echo "  [DRY RUN] Would run: ./scripts/setup-argocd-confighub-auth.sh --space ${SPACE}"
    else
        ./scripts/setup-argocd-confighub-auth.sh --space "${SPACE}"
    fi

    echo ""
    echo "Step 4: Apply ArgoCD Application..."

    if [[ "${DRY_RUN}" == "true" ]]; then
        echo "  [DRY RUN] Would run: kubectl apply -f platform/argocd/application-prod.yaml"
    else
        kubectl apply -f platform/argocd/application-prod.yaml --context "${CLUSTER_CONTEXT}"
        echo "  Application created"
    fi
else
    echo "Step 3: Skipping ArgoCD setup (--skip-argocd)"
fi

echo ""
echo "=== Setup Complete ==="
echo ""
echo "Production space '${SPACE}' is ready."
echo ""
echo "Next steps:"
echo "  1. Publish a Claim to the space:"
echo "     cub unit update --space ${SPACE} messagewall examples/claims/messagewall-prod.yaml"
echo ""
echo "  2. Apply the revision to make it live:"
echo "     cub unit apply --space ${SPACE} messagewall"
echo ""
echo "  3. Check sync status:"
echo "     kubectl get application messagewall-prod -n argocd"
echo ""
echo "For production governance details, see: docs/confighub-spaces.md"
