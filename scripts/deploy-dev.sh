#!/bin/bash
# Deploy the message wall infrastructure to dev environment
# This script is idempotent and waits for resources to be ready
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "${SCRIPT_DIR}")"
CLUSTER_CONTEXT="kind-actuator"
INFRA_DIR="${PROJECT_ROOT}/infra/base"

echo "=== Message Wall Dev Deployment ==="
echo ""

# Check if cluster is reachable
if ! kubectl cluster-info --context "${CLUSTER_CONTEXT}" &> /dev/null; then
    echo "Error: Cannot reach cluster '${CLUSTER_CONTEXT}'."
    echo "Make sure the kind cluster is running and Crossplane is installed."
    exit 1
fi

# Check if Crossplane providers are healthy
echo "Checking Crossplane providers..."
if ! kubectl get providers --context "${CLUSTER_CONTEXT}" | grep -q "True.*True"; then
    echo "Error: Crossplane AWS providers are not healthy."
    echo "Run bootstrap-aws-providers.sh first."
    exit 1
fi
echo "Crossplane providers are healthy."
echo ""

# Build and upload Lambda artifacts
echo "Building Lambda artifacts..."
"${PROJECT_ROOT}/app/api-handler/build.sh"
"${PROJECT_ROOT}/app/snapshot-writer/build.sh"

echo ""
echo "Uploading Lambda artifacts to S3..."
# Note: S3 bucket must exist first, so we apply infra in stages

# Stage 1: Core infrastructure (S3, DynamoDB, IAM)
echo ""
echo "Stage 1: Applying core infrastructure..."
kubectl apply -f "${INFRA_DIR}/s3.yaml" --context "${CLUSTER_CONTEXT}"
kubectl apply -f "${INFRA_DIR}/dynamodb.yaml" --context "${CLUSTER_CONTEXT}"
kubectl apply -f "${INFRA_DIR}/iam.yaml" --context "${CLUSTER_CONTEXT}"

echo "Waiting for S3 bucket to be ready..."
kubectl wait --for=condition=Ready bucket/messagewall-demo-bucket --timeout=120s --context "${CLUSTER_CONTEXT}"

echo "Waiting for DynamoDB table to be ready..."
kubectl wait --for=condition=Ready table/messagewall-demo-table --timeout=120s --context "${CLUSTER_CONTEXT}"

echo "Waiting for IAM roles to be ready..."
kubectl wait --for=condition=Ready role.iam/messagewall-api-role --timeout=120s --context "${CLUSTER_CONTEXT}"
kubectl wait --for=condition=Ready role.iam/messagewall-snapshot-role --timeout=120s --context "${CLUSTER_CONTEXT}"

# Upload Lambda artifacts now that bucket exists
echo ""
echo "Uploading Lambda artifacts..."
aws s3 cp "${PROJECT_ROOT}/app/api-handler/api-handler.zip" s3://messagewall-demo-dev/artifacts/api-handler.zip
aws s3 cp "${PROJECT_ROOT}/app/snapshot-writer/snapshot-writer.zip" s3://messagewall-demo-dev/artifacts/snapshot-writer.zip

# Stage 2: Lambda functions
echo ""
echo "Stage 2: Applying Lambda functions..."
kubectl apply -f "${INFRA_DIR}/lambda.yaml" --context "${CLUSTER_CONTEXT}"

echo "Waiting for Lambda functions to be ready..."
kubectl wait --for=condition=Ready function.lambda/messagewall-api-handler --timeout=120s --context "${CLUSTER_CONTEXT}"
kubectl wait --for=condition=Ready function.lambda/messagewall-snapshot-writer --timeout=120s --context "${CLUSTER_CONTEXT}"

# Stage 3: Function URL and EventBridge
echo ""
echo "Stage 3: Applying Function URL and EventBridge..."
kubectl apply -f "${INFRA_DIR}/function-url.yaml" --context "${CLUSTER_CONTEXT}"
kubectl apply -f "${INFRA_DIR}/eventbridge.yaml" --context "${CLUSTER_CONTEXT}"

echo "Waiting for Function URL to be ready..."
kubectl wait --for=condition=Ready functionurl/messagewall-api-handler-url --timeout=120s --context "${CLUSTER_CONTEXT}"

echo "Waiting for EventBridge rule to be ready..."
kubectl wait --for=condition=Ready rule.cloudwatchevents/messagewall-snapshot-trigger --timeout=120s --context "${CLUSTER_CONTEXT}"

# Upload static website
echo ""
echo "Uploading static website..."
aws s3 cp "${PROJECT_ROOT}/app/web/index.html" s3://messagewall-demo-dev/index.html --content-type "text/html"

# Get endpoints
echo ""
echo "=== Deployment Complete ==="
echo ""
FUNCTION_URL=$(kubectl get functionurl messagewall-api-handler-url -o jsonpath='{.status.atProvider.functionUrl}' --context "${CLUSTER_CONTEXT}")
echo "Website:      http://messagewall-demo-dev.s3-website-us-east-1.amazonaws.com/"
echo "API:          ${FUNCTION_URL}"
echo ""
echo "Run './scripts/smoke-test.sh' to verify the deployment."
