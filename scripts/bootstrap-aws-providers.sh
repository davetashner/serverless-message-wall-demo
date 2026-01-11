#!/bin/bash
set -euo pipefail

CLUSTER_CONTEXT="kind-actuator"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Check if cluster is reachable
if ! kubectl cluster-info --context "${CLUSTER_CONTEXT}" &> /dev/null; then
    echo "Error: Cannot reach cluster '${CLUSTER_CONTEXT}'. Run bootstrap-kind.sh first."
    exit 1
fi

# Check if Crossplane is installed
if ! kubectl get deployment crossplane -n crossplane-system --context "${CLUSTER_CONTEXT}" &> /dev/null; then
    echo "Error: Crossplane is not installed. Run bootstrap-crossplane.sh first."
    exit 1
fi

# Check if AWS credentials secret exists
if ! kubectl get secret aws-credentials -n crossplane-system --context "${CLUSTER_CONTEXT}" &> /dev/null; then
    echo "Error: AWS credentials secret not found in crossplane-system namespace."
    echo "Create it with:"
    echo "  kubectl create secret generic aws-credentials \\"
    echo "    --namespace crossplane-system \\"
    echo "    --from-literal=credentials=\"[default]"
    echo "aws_access_key_id = <ACCESS_KEY>"
    echo "aws_secret_access_key = <SECRET_KEY>\""
    exit 1
fi

# Apply providers
echo "Installing AWS family providers..."
kubectl apply -f "${PROJECT_ROOT}/platform/crossplane/providers.yaml" --context "${CLUSTER_CONTEXT}"

# Wait for providers to be healthy
echo "Waiting for providers to become healthy (this may take 1-2 minutes)..."
kubectl wait provider.pkg.crossplane.io --all --for=condition=Healthy --timeout=180s --context "${CLUSTER_CONTEXT}"

# Apply ProviderConfig
echo "Applying ProviderConfig..."
kubectl apply -f "${PROJECT_ROOT}/platform/crossplane/provider-config.yaml" --context "${CLUSTER_CONTEXT}"

echo ""
echo "AWS providers installed successfully."
echo ""
echo "Providers:"
kubectl get providers.pkg.crossplane.io --context "${CLUSTER_CONTEXT}"
