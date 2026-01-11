#!/bin/bash
set -euo pipefail

CLUSTER_CONTEXT="kind-actuator"
NAMESPACE="kyverno"
RELEASE_NAME="kyverno"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Check if helm is installed
if ! command -v helm &> /dev/null; then
    echo "Error: helm is not installed. Install with: brew install helm"
    exit 1
fi

# Check if cluster is reachable
if ! kubectl cluster-info --context "${CLUSTER_CONTEXT}" &> /dev/null; then
    echo "Error: Cannot reach cluster '${CLUSTER_CONTEXT}'. Run bootstrap-kind.sh first."
    exit 1
fi

# Add Kyverno Helm repo (idempotent)
echo "Adding Kyverno Helm repo..."
helm repo add kyverno https://kyverno.github.io/kyverno/ 2>/dev/null || true
helm repo update

# Check if Kyverno is already installed
if helm status "${RELEASE_NAME}" --namespace "${NAMESPACE}" --kube-context "${CLUSTER_CONTEXT}" &> /dev/null; then
    echo "Kyverno is already installed."
    echo ""
    echo "Pods:"
    kubectl get pods -n "${NAMESPACE}" --context "${CLUSTER_CONTEXT}"
    exit 0
fi

# Install Kyverno
echo "Installing Kyverno..."
helm install "${RELEASE_NAME}" kyverno/kyverno \
    --namespace "${NAMESPACE}" \
    --create-namespace \
    --kube-context "${CLUSTER_CONTEXT}" \
    --values "${PROJECT_ROOT}/platform/kyverno/values.yaml" \
    --wait

echo ""
echo "Kyverno installed successfully."
echo ""
echo "Configuration:"
echo "  - Failure policy: Ignore (fail open)"
echo "  - Policy reports: Enabled"
echo "  - Replicas: 1 (demo mode)"
echo ""
echo "Pods:"
kubectl get pods -n "${NAMESPACE}" --context "${CLUSTER_CONTEXT}"
