#!/bin/bash
# Install ServerlessEventApp XRD and Composition
#
# This script installs:
#   - function-patch-and-transform Crossplane function
#   - ServerlessEventApp XRD (CompositeResourceDefinition)
#   - AWS Composition for ServerlessEventApp
#
# Prerequisites:
#   - kubectl configured with access to the actuator cluster
#   - Crossplane installed with AWS providers
#
# Usage:
#   ./scripts/install-xrd.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONTEXT="kind-actuator"

echo "==> Installing ServerlessEventApp XRD..."
echo "    Using context: $CONTEXT"

# Verify cluster is reachable
if ! kubectl cluster-info --context "$CONTEXT" &>/dev/null; then
    echo "ERROR: Cannot connect to cluster '$CONTEXT'"
    echo "Make sure the actuator cluster is running: ./scripts/bootstrap-kind.sh"
    exit 1
fi

# Step 1: Install Crossplane function
echo "--> Installing function-patch-and-transform..."
kubectl apply -f "$PROJECT_ROOT/platform/crossplane/functions/function-patch-and-transform.yaml" --context "$CONTEXT"

# Wait for function to be healthy
# Use fully-qualified name to avoid collision with lambda.aws.upbound.io/Function
echo "--> Waiting for function to be healthy..."
kubectl wait --for=condition=Healthy function.pkg.crossplane.io/function-patch-and-transform \
    --timeout=120s --context "$CONTEXT" || {
    echo "Warning: Function not healthy yet, continuing anyway..."
}

# Step 2: Install XRD
echo "--> Installing ServerlessEventApp XRD..."
kubectl apply -f "$PROJECT_ROOT/platform/crossplane/xrd/serverless-event-app.yaml" --context "$CONTEXT"

# Wait for XRD to be established
echo "--> Waiting for XRD to be established..."
kubectl wait --for=condition=Established xrd/serverlesseventapps.messagewall.demo \
    --timeout=60s --context "$CONTEXT"

# Step 3: Install Composition
echo "--> Installing AWS Composition..."
kubectl apply -f "$PROJECT_ROOT/platform/crossplane/compositions/serverless-event-app-aws.yaml" --context "$CONTEXT"

echo ""
echo "==> ServerlessEventApp XRD installed successfully!"
echo ""
echo "Verify installation:"
echo "  kubectl get xrd serverlesseventapps.messagewall.demo --context $CONTEXT"
echo "  kubectl get composition serverlesseventapp-aws --context $CONTEXT"
echo "  kubectl get function.pkg.crossplane.io --context $CONTEXT"
echo ""
echo "Deploy messagewall:"
echo "  ./scripts/deploy-messagewall.sh"
