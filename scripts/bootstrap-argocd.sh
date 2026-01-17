#!/bin/bash
set -euo pipefail

CLUSTER_CONTEXT="kind-actuator"
NAMESPACE="argocd"
RELEASE_NAME="argocd"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
VALUES_FILE="${PROJECT_ROOT}/platform/argocd/values.yaml"
CMP_PLUGIN_FILE="${PROJECT_ROOT}/platform/argocd/cmp-plugin.yaml"

# Check if helm is installed
if ! command -v helm &> /dev/null; then
    echo "Error: helm is not installed. Install with: brew install helm"
    exit 1
fi

# Check if kubectl is installed
if ! command -v kubectl &> /dev/null; then
    echo "Error: kubectl is not installed. Install with: brew install kubectl"
    exit 1
fi

# Check if cluster is reachable
if ! kubectl cluster-info --context "${CLUSTER_CONTEXT}" &> /dev/null; then
    echo "Error: Cannot reach cluster '${CLUSTER_CONTEXT}'. Run bootstrap-kind.sh first."
    exit 1
fi

# Check if values file exists
if [[ ! -f "${VALUES_FILE}" ]]; then
    echo "Error: Values file not found: ${VALUES_FILE}"
    exit 1
fi

# Add ArgoCD Helm repo (idempotent)
echo "Adding ArgoCD Helm repo..."
helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null || true
helm repo update

# Check if ArgoCD is already installed
if helm status "${RELEASE_NAME}" --namespace "${NAMESPACE}" --kube-context "${CLUSTER_CONTEXT}" &> /dev/null; then
    echo "ArgoCD is already installed."
    echo ""
    echo "Pods:"
    kubectl get pods -n "${NAMESPACE}" --context "${CLUSTER_CONTEXT}"
    echo ""
    echo "To access ArgoCD UI:"
    echo "  kubectl port-forward svc/argocd-server -n argocd 8080:443"
    echo "  Open https://localhost:8080"
    echo ""
    echo "Get admin password:"
    echo "  kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
    exit 0
fi

# Create namespace if it doesn't exist
kubectl create namespace "${NAMESPACE}" --context "${CLUSTER_CONTEXT}" 2>/dev/null || true

# Apply CMP plugin ConfigMap BEFORE Helm install (required for volume mount)
if [[ -f "${CMP_PLUGIN_FILE}" ]]; then
    echo "Applying ConfigHub CMP plugin ConfigMap..."
    kubectl apply -f "${CMP_PLUGIN_FILE}" --context "${CLUSTER_CONTEXT}"
fi

# Install ArgoCD
echo "Installing ArgoCD..."
helm install "${RELEASE_NAME}" argo/argo-cd \
    --namespace "${NAMESPACE}" \
    --kube-context "${CLUSTER_CONTEXT}" \
    --values "${VALUES_FILE}" \
    --wait --timeout 5m

echo ""
echo "ArgoCD installed successfully."
echo ""
echo "Pods:"
kubectl get pods -n "${NAMESPACE}" --context "${CLUSTER_CONTEXT}"
echo ""
echo "To access ArgoCD UI:"
echo "  kubectl port-forward svc/argocd-server -n argocd 8080:443"
echo "  Open https://localhost:8080"
echo ""
echo "Get admin password:"
echo "  kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
echo ""
echo "Next steps:"
echo "  1. Run scripts/setup-argocd-confighub-auth.sh to configure ConfigHub credentials"
echo "  2. Apply platform/argocd/application-dev.yaml to start syncing from ConfigHub"
