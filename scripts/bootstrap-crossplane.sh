#!/bin/bash
set -euo pipefail

CLUSTER_CONTEXT="kind-actuator"
NAMESPACE="crossplane-system"
RELEASE_NAME="crossplane"

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

# Add Crossplane Helm repo (idempotent)
echo "Adding Crossplane Helm repo..."
helm repo add crossplane-stable https://charts.crossplane.io/stable 2>/dev/null || true
helm repo update

# Check if Crossplane is already installed
if helm status "${RELEASE_NAME}" --namespace "${NAMESPACE}" --kube-context "${CLUSTER_CONTEXT}" &> /dev/null; then
    echo "Crossplane is already installed."
    echo ""
    echo "Pods:"
    kubectl get pods -n "${NAMESPACE}" --context "${CLUSTER_CONTEXT}"
    exit 0
fi

# Create namespace if it doesn't exist
kubectl create namespace "${NAMESPACE}" --context "${CLUSTER_CONTEXT}" 2>/dev/null || true

# Install Crossplane
echo "Installing Crossplane..."
helm install "${RELEASE_NAME}" crossplane-stable/crossplane \
    --namespace "${NAMESPACE}" \
    --kube-context "${CLUSTER_CONTEXT}" \
    --wait

echo ""
echo "Crossplane installed successfully."
echo ""
echo "Pods:"
kubectl get pods -n "${NAMESPACE}" --context "${CLUSTER_CONTEXT}"
