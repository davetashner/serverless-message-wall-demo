#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Default values
CLUSTER_NAME="actuator"
AWS_REGION=""

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --name)
            CLUSTER_NAME="$2"
            shift 2
            ;;
        --region)
            AWS_REGION="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 [--name <cluster-name>] [--region <aws-region>]"
            echo ""
            echo "Options:"
            echo "  --name    Cluster name (default: actuator)"
            echo "  --region  AWS region for this cluster (e.g., us-east-1, us-west-2)"
            echo ""
            echo "Examples:"
            echo "  $0                                    # Create 'actuator' cluster"
            echo "  $0 --name actuator-east --region us-east-1"
            echo "  $0 --name actuator-west --region us-west-2"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

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
kubectl get nodes

# Store region configuration if provided
if [[ -n "$AWS_REGION" ]]; then
    echo ""
    echo "Storing region configuration..."
    kubectl create configmap cluster-config \
        --namespace default \
        --context "kind-${CLUSTER_NAME}" \
        --from-literal=aws-region="${AWS_REGION}" \
        --dry-run=client -o yaml | kubectl apply -f - --context "kind-${CLUSTER_NAME}"
    echo "Region '${AWS_REGION}' stored in cluster-config ConfigMap"
fi

echo ""
echo "Cluster '${CLUSTER_NAME}' is ready."
echo "Context: kind-${CLUSTER_NAME}"
if [[ -n "$AWS_REGION" ]]; then
    echo "AWS Region: ${AWS_REGION}"
fi
