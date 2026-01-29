#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

CLUSTER_CONTEXT="kind-workload"
NAMESPACE="argocd"
SECRET_NAME="confighub-actuator-credentials"
# Any space works for worker home - we use org-role admin for cross-space access
SPACE="order-platform-ops-dev"

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Configure ConfigHub credentials for ArgoCD on the workload cluster.

This script creates a ConfigHub worker with org-admin access (required for
reading from multiple spaces) and stores its credentials as a Kubernetes
Secret that the ArgoCD CMP plugin uses to authenticate.

OPTIONS:
    --space NAME        Space to create worker in (default: ${SPACE})
    --worker-id ID      Use existing worker UUID (skip creation)
    --worker-secret SEC Use existing worker secret
    --dry-run           Print what would be done without executing
    -h, --help          Show this help message

PREREQUISITES:
    - cub CLI installed and authenticated (cub auth login)
    - kubectl configured with access to the workload cluster
    - ArgoCD installed (run bootstrap-workload-argocd.sh first)
    - ConfigHub spaces created (run setup-order-platform-spaces.sh first)

EXAMPLES:
    # Create new worker and configure
    $(basename "$0")

    # Use existing worker credentials
    $(basename "$0") --worker-id <UUID> --worker-secret <SECRET>

EOF
    exit 0
}

DRY_RUN=false
WORKER_ID=""
WORKER_SECRET=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --space)
            SPACE="$2"
            shift 2
            ;;
        --worker-id)
            WORKER_ID="$2"
            shift 2
            ;;
        --worker-secret)
            WORKER_SECRET="$2"
            shift 2
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
echo "Checking prerequisites..."

if ! command -v kubectl &> /dev/null; then
    echo "Error: kubectl is not installed"
    exit 1
fi

if ! kubectl cluster-info --context "${CLUSTER_CONTEXT}" &> /dev/null; then
    echo "Error: Cannot reach cluster '${CLUSTER_CONTEXT}'"
    exit 1
fi

# Check if ArgoCD is installed
if ! kubectl get namespace "${NAMESPACE}" --context "${CLUSTER_CONTEXT}" &> /dev/null; then
    echo "Error: ArgoCD namespace '${NAMESPACE}' not found. Run bootstrap-workload-argocd.sh first."
    exit 1
fi

# If no existing credentials provided, create a new worker
if [[ -z "${WORKER_ID}" ]] || [[ -z "${WORKER_SECRET}" ]]; then
    echo ""
    echo "No existing credentials provided. Creating new ConfigHub worker..."

    if ! command -v cub &> /dev/null; then
        echo "Error: cub CLI is not installed"
        echo "Install from: https://github.com/confighub/cub/releases"
        exit 1
    fi

    # Check if authenticated by trying to list spaces
    AUTH_CHECK=$(cub space list 2>&1 || true)
    if echo "$AUTH_CHECK" | grep -qE "(not authenticated|worker associated|401|403|expired)"; then
        echo "Error: ConfigHub credentials expired or invalid."
        echo "Run: cub auth login"
        exit 1
    fi

    # Check if space exists (use word boundary for column-aligned output)
    if ! echo "$AUTH_CHECK" | grep -qE "^${SPACE}[[:space:]]"; then
        echo "Error: ConfigHub space '${SPACE}' does not exist."
        echo "Create Order Platform spaces first with:"
        echo "  scripts/setup-order-platform-spaces.sh"
        exit 1
    fi

    WORKER_NAME="argocd-reader"

    if [[ "${DRY_RUN}" == "true" ]]; then
        echo "[DRY RUN] Would create worker: ${WORKER_NAME} in space: ${SPACE}"
        echo "[DRY RUN] With --org-role admin for cross-space read access"
    else
        echo "Creating worker '${WORKER_NAME}' in space '${SPACE}' with org-admin access..."
        echo "(org-admin is required to read units from all 10 Order Platform spaces)"

        # Create worker with org-admin role for cross-space access
        # The worker is homed in one space but can access all spaces via org role
        WORKER_OUTPUT=$(cub worker create --space "${SPACE}" "${WORKER_NAME}" --org-role admin --allow-exists 2>&1) || {
            echo "Error creating worker:"
            echo "${WORKER_OUTPUT}"
            echo ""
            echo "If the space doesn't exist, create it first:"
            echo "  scripts/setup-order-platform-spaces.sh"
            exit 1
        }

        # Extract UUID from output: "Successfully created bridgeworker argocd-reader (UUID)"
        WORKER_ID=$(echo "${WORKER_OUTPUT}" | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' || echo "")

        if [[ -z "${WORKER_ID}" ]]; then
            # Worker may already exist, get its ID
            echo "Fetching existing worker ID..."
            WORKER_INFO=$(cub worker get --space "${SPACE}" "${WORKER_NAME}" 2>&1) || {
                echo "Error getting worker info"
                exit 1
            }
            WORKER_ID=$(echo "${WORKER_INFO}" | grep -E '^ID' | awk '{print $2}')

            # Ensure it has admin role
            echo "Updating worker to have org-admin role..."
            cub worker update --space "${SPACE}" "${WORKER_NAME}" --org-role admin 2>/dev/null || true
        fi

        echo "Worker UUID: ${WORKER_ID}"
        echo ""
        echo "Fetching worker secret..."

        # Get worker secret
        WORKER_SECRET=$(cub worker get-secret --space "${SPACE}" "${WORKER_NAME}" 2>&1) || {
            echo "Error getting worker secret"
            echo "You may need to provide credentials manually:"
            echo "  $(basename "$0") --worker-id <UUID> --worker-secret <SECRET>"
            exit 1
        }

        if [[ -z "${WORKER_SECRET}" ]]; then
            echo "Error: Failed to get worker secret"
            echo "You may need to provide credentials manually:"
            echo "  $(basename "$0") --worker-id <UUID> --worker-secret <SECRET>"
            exit 1
        fi

        echo "Worker credentials retrieved successfully"
    fi
fi

echo ""
echo "Credentials:"
echo "  Worker ID:     ${WORKER_ID}"
echo "  Worker Secret: ${WORKER_SECRET:0:20}..."

# Check if secret already exists
if kubectl get secret "${SECRET_NAME}" -n "${NAMESPACE}" --context "${CLUSTER_CONTEXT}" &> /dev/null; then
    echo ""
    echo "Secret '${SECRET_NAME}' already exists in namespace '${NAMESPACE}'"
    echo "Replacing existing secret..."

    if [[ "${DRY_RUN}" == "true" ]]; then
        echo "[DRY RUN] Would delete existing secret"
    else
        kubectl delete secret "${SECRET_NAME}" -n "${NAMESPACE}" --context "${CLUSTER_CONTEXT}"
    fi
fi

# Create the secret
if [[ "${DRY_RUN}" == "true" ]]; then
    echo ""
    echo "[DRY RUN] Would create secret '${SECRET_NAME}' in namespace '${NAMESPACE}'"
    echo "[DRY RUN] With keys: CONFIGHUB_WORKER_ID, CONFIGHUB_WORKER_SECRET"
else
    echo ""
    echo "Creating Kubernetes secret..."
    kubectl create secret generic "${SECRET_NAME}" \
        --namespace "${NAMESPACE}" \
        --context "${CLUSTER_CONTEXT}" \
        --from-literal=CONFIGHUB_WORKER_ID="${WORKER_ID}" \
        --from-literal=CONFIGHUB_WORKER_SECRET="${WORKER_SECRET}"

    echo "Secret created successfully"
fi

echo ""
echo "ConfigHub credentials configured for ArgoCD on workload cluster."
echo ""
echo "Next steps:"
echo "  1. Restart the ArgoCD repo-server to pick up the new credentials:"
echo "     kubectl rollout restart deployment argocd-repo-server -n argocd --context ${CLUSTER_CONTEXT}"
echo ""
echo "  2. Apply the ArgoCD ApplicationSet to create Order Platform apps:"
echo "     kubectl apply -f platform/argocd/applicationset-order-platform.yaml --context ${CLUSTER_CONTEXT}"
echo ""
echo "  3. Check sync status:"
echo "     kubectl get applications -n argocd --context ${CLUSTER_CONTEXT}"
