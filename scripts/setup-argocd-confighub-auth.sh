#!/bin/bash
set -euo pipefail

CLUSTER_CONTEXT="kind-actuator"
NAMESPACE="argocd"
SECRET_NAME="confighub-actuator-credentials"
SPACE="messagewall-dev"

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Configure ConfigHub credentials for ArgoCD to sync from ConfigHub.

This script creates a ConfigHub worker and stores its credentials as a
Kubernetes Secret that the ArgoCD CMP plugin uses to authenticate.

OPTIONS:
    --space NAME        ConfigHub space name (default: ${SPACE})
    --worker-id ID      Use existing worker ID (skip creation)
    --worker-secret SEC Use existing worker secret
    --dry-run           Print what would be done without executing
    -h, --help          Show this help message

PREREQUISITES:
    - cub CLI installed and authenticated (cub auth login)
    - kubectl configured with access to the actuator cluster
    - ArgoCD installed (run bootstrap-argocd.sh first)

EXAMPLES:
    # Create new worker and configure
    $(basename "$0")

    # Use existing worker credentials
    $(basename "$0") --worker-id wkr_xxx --worker-secret sec_xxx

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
    echo "Error: ArgoCD namespace '${NAMESPACE}' not found. Run bootstrap-argocd.sh first."
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

    WORKER_NAME="actuator-sync-$(date +%Y%m%d)"

    # Check if space exists
    if ! cub space list 2>/dev/null | grep -q "^${SPACE} "; then
        echo "Error: ConfigHub space '${SPACE}' does not exist."
        echo "Create it first with:"
        echo "  cub space create ${SPACE} --label Environment=dev --label Application=messagewall"
        exit 1
    fi

    if [[ "${DRY_RUN}" == "true" ]]; then
        echo "[DRY RUN] Would create worker: ${WORKER_NAME} in space: ${SPACE}"
    else
        echo "Creating worker '${WORKER_NAME}' in space '${SPACE}'..."

        # Create worker (may already exist, that's ok with --allow-exists)
        if ! cub worker create --space "${SPACE}" "${WORKER_NAME}" --allow-exists 2>&1; then
            echo ""
            echo "Failed to create worker. Check ConfigHub connectivity."
            exit 1
        fi

        echo "Fetching worker credentials..."

        # Get worker ID (the slug is the ID for worker operations)
        WORKER_ID="${WORKER_NAME}"

        # Get worker secret
        WORKER_SECRET=$(cub worker get-secret --space "${SPACE}" "${WORKER_NAME}" 2>&1) || {
            echo "Error getting worker secret"
            echo "You may need to provide credentials manually:"
            echo "  $(basename "$0") --worker-id <ID> --worker-secret <SECRET>"
            exit 1
        }

        if [[ -z "${WORKER_SECRET}" ]]; then
            echo "Error: Failed to get worker secret"
            echo "You may need to provide credentials manually:"
            echo "  $(basename "$0") --worker-id <ID> --worker-secret <SECRET>"
            exit 1
        fi

        echo "Worker credentials retrieved successfully"
    fi
fi

echo ""
echo "Credentials:"
echo "  Worker ID:     ${WORKER_ID:0:20}..."
echo "  Worker Secret: ${WORKER_SECRET:0:10}..."

# Check if secret already exists
if kubectl get secret "${SECRET_NAME}" -n "${NAMESPACE}" --context "${CLUSTER_CONTEXT}" &> /dev/null; then
    echo ""
    echo "Secret '${SECRET_NAME}' already exists in namespace '${NAMESPACE}'"
    read -p "Overwrite? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 0
    fi

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
echo "ConfigHub credentials configured for ArgoCD."
echo ""
echo "Next steps:"
echo "  1. Restart the ArgoCD repo-server to pick up the new credentials:"
echo "     kubectl rollout restart deployment argocd-repo-server -n argocd"
echo ""
echo "  2. Apply the ArgoCD Application to start syncing:"
echo "     kubectl apply -f platform/argocd/application-dev.yaml"
echo ""
echo "  3. Check sync status:"
echo "     kubectl get application messagewall-dev -n argocd"
