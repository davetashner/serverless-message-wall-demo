#!/bin/bash
# Clean up all message wall resources
# Deletes Crossplane-managed AWS resources
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "${SCRIPT_DIR}")"
CLUSTER_CONTEXT="kind-actuator"
INFRA_DIR="${PROJECT_ROOT}/infra/base"
BUCKET_NAME="messagewall-demo-dev"
REGION="us-east-1"

echo "=== Message Wall Cleanup ==="
echo ""
echo "This will delete all message wall resources from AWS."
echo ""

# Check if cluster is reachable
if ! kubectl cluster-info --context "${CLUSTER_CONTEXT}" &> /dev/null; then
    echo "Warning: Cannot reach cluster '${CLUSTER_CONTEXT}'."
    echo "Will attempt direct AWS cleanup instead."
    CLUSTER_AVAILABLE=false
else
    CLUSTER_AVAILABLE=true
fi

# Empty S3 bucket before deletion (required for bucket deletion)
echo "Emptying S3 bucket..."
if aws s3 ls "s3://${BUCKET_NAME}" --region "${REGION}" &> /dev/null; then
    aws s3 rm "s3://${BUCKET_NAME}" --recursive --region "${REGION}" 2>/dev/null || true
    echo "S3 bucket emptied."
else
    echo "S3 bucket does not exist or is already empty."
fi
echo ""

if [[ "${CLUSTER_AVAILABLE}" == "true" ]]; then
    # Delete in reverse order of creation
    echo "Deleting EventBridge resources..."
    kubectl delete -f "${INFRA_DIR}/eventbridge.yaml" --context "${CLUSTER_CONTEXT}" --ignore-not-found=true 2>/dev/null || true

    echo "Deleting Function URL..."
    kubectl delete -f "${INFRA_DIR}/function-url.yaml" --context "${CLUSTER_CONTEXT}" --ignore-not-found=true 2>/dev/null || true

    echo "Deleting Lambda functions..."
    kubectl delete -f "${INFRA_DIR}/lambda.yaml" --context "${CLUSTER_CONTEXT}" --ignore-not-found=true 2>/dev/null || true

    echo "Deleting IAM roles..."
    kubectl delete -f "${INFRA_DIR}/iam.yaml" --context "${CLUSTER_CONTEXT}" --ignore-not-found=true 2>/dev/null || true

    echo "Deleting DynamoDB table..."
    kubectl delete -f "${INFRA_DIR}/dynamodb.yaml" --context "${CLUSTER_CONTEXT}" --ignore-not-found=true 2>/dev/null || true

    echo "Deleting S3 bucket..."
    kubectl delete -f "${INFRA_DIR}/s3.yaml" --context "${CLUSTER_CONTEXT}" --ignore-not-found=true 2>/dev/null || true

    echo ""
    echo "Waiting for resources to be deleted..."
    echo "(This may take a few minutes)"

    # Wait for resources to be deleted
    for i in {1..60}; do
        REMAINING=$(kubectl get bucket,table,function.lambda,role.iam,functionurl,rule.cloudwatchevents --context "${CLUSTER_CONTEXT}" 2>/dev/null | grep -c "messagewall" || true)
        if [[ "${REMAINING}" -eq 0 ]]; then
            break
        fi
        echo "  ${REMAINING} resources remaining..."
        sleep 5
    done
else
    echo "Cluster not available. Manual AWS cleanup may be required."
    echo "Use the AWS Console or CLI to delete resources with 'messagewall-' prefix."
fi

echo ""
echo "=== Cleanup Complete ==="
echo ""
echo "Note: If any resources failed to delete, check the AWS Console."
