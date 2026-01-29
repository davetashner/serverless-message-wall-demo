#!/bin/bash
set -euo pipefail

CLUSTER_NAME="workload"

# Check if kind is installed
if ! command -v kind &> /dev/null; then
    echo "Error: kind is not installed. Install with: brew install kind"
    exit 1
fi

# Check if Docker is running
if ! docker info &> /dev/null; then
    echo "Error: Docker is not running. Please start Docker Desktop."
    exit 1
fi

# Check if cluster already exists
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
    echo "Cluster '${CLUSTER_NAME}' already exists."
    kubectl cluster-info --context "kind-${CLUSTER_NAME}"
    exit 0
fi

# Create the cluster
echo "Creating kind cluster '${CLUSTER_NAME}'..."
kind create cluster --name "${CLUSTER_NAME}"

# Verify cluster is reachable
echo ""
echo "Verifying cluster..."
kubectl cluster-info --context "kind-${CLUSTER_NAME}"
kubectl get nodes --context "kind-${CLUSTER_NAME}"

echo ""
echo "Cluster '${CLUSTER_NAME}' is ready."
echo ""
echo "You now have two clusters:"
echo "  kubectl --context kind-actuator ...   # Crossplane/infrastructure"
echo "  kubectl --context kind-workload ...   # Microservices/workloads"
echo ""
echo "Next: Run scripts/bootstrap-workload-argocd.sh to install ArgoCD"
