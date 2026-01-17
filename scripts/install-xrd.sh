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

echo "==> Installing ServerlessEventApp XRD..."

# Step 1: Install Crossplane function
echo "--> Installing function-patch-and-transform..."
kubectl apply -f "$PROJECT_ROOT/platform/crossplane/functions/function-patch-and-transform.yaml"

# Wait for function to be healthy
echo "--> Waiting for function to be healthy..."
kubectl wait --for=condition=Healthy function/function-patch-and-transform --timeout=120s || {
    echo "Warning: Function not healthy yet, continuing anyway..."
}

# Step 2: Install XRD
echo "--> Installing ServerlessEventApp XRD..."
kubectl apply -f "$PROJECT_ROOT/platform/crossplane/xrd/serverless-event-app.yaml"

# Wait for XRD to be established
echo "--> Waiting for XRD to be established..."
kubectl wait --for=condition=Established xrd/serverlesseventapps.messagewall.demo --timeout=60s

# Step 3: Install Composition
echo "--> Installing AWS Composition..."
kubectl apply -f "$PROJECT_ROOT/platform/crossplane/compositions/serverless-event-app-aws.yaml"

echo ""
echo "==> ServerlessEventApp XRD installed successfully!"
echo ""
echo "Verify installation:"
echo "  kubectl get xrd serverlesseventapps.messagewall.demo"
echo "  kubectl get composition serverlesseventapp-aws"
echo "  kubectl get functions"
echo ""
echo "Apply a Claim:"
echo "  kubectl apply -f examples/claims/messagewall-dev.yaml"
