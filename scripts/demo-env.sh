#!/bin/bash
# demo-env.sh - Export environment variables for demo
#
# Usage: source ./scripts/demo-env.sh
#
# This script exports all the environment variables needed for running
# the demo. Source it before presenting.

# Handle both sourced and executed contexts
if [[ -n "${BASH_SOURCE[0]}" && "${BASH_SOURCE[0]}" != "$0" ]]; then
    # Sourced
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
    # Executed directly
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
fi
PROJECT_ROOT="$(dirname "${SCRIPT_DIR}")"
STATE_FILE="${PROJECT_ROOT}/.setup-state.json"
CLUSTER_CONTEXT="kind-actuator"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

# Check for state file
if [[ ! -f "${STATE_FILE}" ]]; then
    echo -e "${RED}Error: Setup state file not found: ${STATE_FILE}${NC}" >&2
    echo "Run ./scripts/setup.sh first." >&2
    return 1 2>/dev/null || exit 1
fi

# Extract configuration from state file
export AWS_REGION=$(grep '"aws_region"' "${STATE_FILE}" | sed 's/.*: *"//' | sed 's/".*//')
export BUCKET_NAME=$(grep '"bucket_name"' "${STATE_FILE}" | sed 's/.*: *"//' | sed 's/".*//')
export RESOURCE_PREFIX=$(grep '"resource_prefix"' "${STATE_FILE}" | sed 's/.*: *"//' | sed 's/".*//')
export AWS_ACCOUNT_ID=$(grep '"aws_account_id"' "${STATE_FILE}" | sed 's/.*: *"//' | sed 's/".*//')

# Derived values
export TABLE_NAME="${BUCKET_NAME}"
export WEBSITE_URL="http://${BUCKET_NAME}.s3-website-${AWS_REGION}.amazonaws.com/"
export CONFIGHUB_SPACE="messagewall-dev"

# Get API URL from Kubernetes (if cluster is reachable)
if kubectl cluster-info --context "${CLUSTER_CONTEXT}" &> /dev/null; then
    API_URL=$(kubectl get functionurl "${RESOURCE_PREFIX}-api-handler-url" \
        -o jsonpath='{.status.atProvider.functionUrl}' \
        --context "${CLUSTER_CONTEXT}" 2>/dev/null || true)

    if [[ -n "${API_URL}" ]]; then
        export API_URL
    else
        echo -e "${RED}Warning: Could not get API URL from Kubernetes${NC}" >&2
        echo "Function URL may not be ready yet." >&2
    fi
else
    echo -e "${RED}Warning: Cluster '${CLUSTER_CONTEXT}' not reachable${NC}" >&2
    echo "API_URL will not be set." >&2
fi

# Export cluster context for convenience
export CLUSTER_CONTEXT

# Print summary
echo -e "${GREEN}Demo environment loaded:${NC}"
echo "  AWS_REGION:      ${AWS_REGION}"
echo "  BUCKET_NAME:     ${BUCKET_NAME}"
echo "  TABLE_NAME:      ${TABLE_NAME}"
echo "  RESOURCE_PREFIX: ${RESOURCE_PREFIX}"
echo "  WEBSITE_URL:     ${WEBSITE_URL}"
echo "  API_URL:         ${API_URL:-<not available>}"
echo "  CONFIGHUB_SPACE: ${CONFIGHUB_SPACE}"
echo "  CLUSTER_CONTEXT: ${CLUSTER_CONTEXT}"
