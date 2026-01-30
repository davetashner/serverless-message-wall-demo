#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Default values
CLUSTER_CONTEXT="kind-actuator"
AWS_PROFILE=""

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --context)
            CLUSTER_CONTEXT="$2"
            shift 2
            ;;
        --profile)
            AWS_PROFILE="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 [--context <kubectl-context>] [--profile <aws-profile>]"
            echo ""
            echo "Options:"
            echo "  --context  Kubernetes context (default: kind-actuator)"
            echo "  --profile  AWS CLI profile for credentials (default: default profile)"
            echo ""
            echo "For multi-region isolation, use separate IAM users per region:"
            echo "  - crossplane-actuator-east (profile: crossplane-east)"
            echo "  - crossplane-actuator-west (profile: crossplane-west)"
            echo ""
            echo "Examples:"
            echo "  $0                                    # Install on kind-actuator"
            echo "  $0 --context kind-actuator-east --profile crossplane-east"
            echo "  $0 --context kind-actuator-west --profile crossplane-west"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

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

# Check if AWS credentials secret exists, create from aws cli if not
if ! kubectl get secret aws-credentials -n crossplane-system --context "${CLUSTER_CONTEXT}" &> /dev/null; then
    echo "AWS credentials secret not found. Attempting to create from aws cli config..."

    # Check if aws cli is configured
    if ! command -v aws &> /dev/null; then
        echo "Error: aws cli not installed. Install it first: https://aws.amazon.com/cli/"
        exit 1
    fi

    PROFILE_ARG=""
    if [[ -n "$AWS_PROFILE" ]]; then
        PROFILE_ARG="--profile ${AWS_PROFILE}"
        echo "Using AWS profile: ${AWS_PROFILE}"
    fi

    AWS_ACCESS_KEY_ID=$(aws configure get aws_access_key_id ${PROFILE_ARG} 2>/dev/null || true)
    AWS_SECRET_ACCESS_KEY=$(aws configure get aws_secret_access_key ${PROFILE_ARG} 2>/dev/null || true)

    if [[ -z "$AWS_ACCESS_KEY_ID" || -z "$AWS_SECRET_ACCESS_KEY" ]]; then
        echo "Error: AWS credentials not configured in aws cli${AWS_PROFILE:+ for profile '$AWS_PROFILE'}."
        echo "Run 'aws configure${AWS_PROFILE:+ --profile $AWS_PROFILE}' first, or create the secret manually:"
        echo "  kubectl create secret generic aws-credentials \\"
        echo "    --namespace crossplane-system \\"
        echo "    --from-literal=credentials=\"[default]"
        echo "aws_access_key_id = <ACCESS_KEY>"
        echo "aws_secret_access_key = <SECRET_KEY>\""
        exit 1
    fi

    kubectl create secret generic aws-credentials \
        --namespace crossplane-system \
        --context "${CLUSTER_CONTEXT}" \
        --from-literal=credentials="[default]
aws_access_key_id = ${AWS_ACCESS_KEY_ID}
aws_secret_access_key = ${AWS_SECRET_ACCESS_KEY}"

    echo "AWS credentials secret created from aws cli config."
fi

# Apply providers
echo "Installing AWS family providers..."
kubectl apply -f "${PROJECT_ROOT}/platform/crossplane/providers.yaml" --context "${CLUSTER_CONTEXT}"

# Wait for providers to be healthy (continue even if some timeout)
echo "Waiting for providers to become healthy (this may take 2-3 minutes)..."
PROVIDERS_HEALTHY=true
if ! kubectl wait provider.pkg.crossplane.io --all --for=condition=Healthy --timeout=240s --context "${CLUSTER_CONTEXT}" 2>&1; then
    echo ""
    echo "Warning: Some providers may still be initializing. Continuing anyway..."
    PROVIDERS_HEALTHY=false
fi

# Always apply ProviderConfig (providers may finish initializing after)
echo "Applying ProviderConfig..."
kubectl apply -f "${PROJECT_ROOT}/platform/crossplane/provider-config.yaml" --context "${CLUSTER_CONTEXT}"

echo ""
if [[ "$PROVIDERS_HEALTHY" == "true" ]]; then
    echo "AWS providers installed successfully."
else
    echo "AWS providers installed (some may still be initializing)."
fi
echo ""
echo "Providers:"
kubectl get providers.pkg.crossplane.io --context "${CLUSTER_CONTEXT}"

# Final health check
UNHEALTHY=$(kubectl get providers.pkg.crossplane.io --context "${CLUSTER_CONTEXT}" --no-headers 2>/dev/null | grep -v "True.*True" || true)
if [[ -n "$UNHEALTHY" ]]; then
    echo ""
    echo "Note: Some providers are not yet healthy. They should become ready shortly."
    echo "Check status with: kubectl get providers --context ${CLUSTER_CONTEXT}"
fi

# Show region info if configured
AWS_REGION=$(kubectl get configmap cluster-config -n default --context "${CLUSTER_CONTEXT}" -o jsonpath='{.data.aws-region}' 2>/dev/null || true)
if [[ -n "$AWS_REGION" ]]; then
    echo ""
    echo "This cluster is configured for AWS region: ${AWS_REGION}"
    echo "Infrastructure manifests should use 'region: ${AWS_REGION}' in forProvider specs."
fi
