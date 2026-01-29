#!/bin/bash
# Deploy messagewall infrastructure to AWS via Crossplane
#
# This script:
#   1. Installs XRD/Composition if not present
#   2. Builds Lambda artifacts if not present
#   3. Gets AWS account ID
#   4. Creates S3 bucket (via initial Claim apply)
#   5. Uploads Lambda artifacts to S3
#   6. Waits for all resources to be ready
#
# Prerequisites:
#   - Actuator cluster running with Crossplane and AWS providers
#   - AWS CLI configured with valid credentials
#   - MessageWallRoleBoundary IAM policy exists in AWS
#
# Usage:
#   ./scripts/deploy-messagewall.sh [--env dev|prod]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONTEXT="kind-actuator"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Default values
ENVIRONMENT="dev"
RESOURCE_PREFIX="messagewall"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --env)
            ENVIRONMENT="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--env dev|prod]"
            exit 1
            ;;
    esac
done

echo ""
echo "═══════════════════════════════════════════════════════"
echo "  DEPLOY MESSAGEWALL INFRASTRUCTURE"
echo "═══════════════════════════════════════════════════════"
echo ""
echo "Environment: $ENVIRONMENT"
echo "Context: $CONTEXT"
echo ""

# ─────────────────────────────────────────────────────────────
# Step 0: Verify prerequisites
# ─────────────────────────────────────────────────────────────
echo -e "${YELLOW}Step 0: Verify prerequisites${NC}"

# Check cluster
if ! kubectl cluster-info --context "$CONTEXT" &>/dev/null; then
    echo -e "${RED}ERROR: Cannot connect to cluster '$CONTEXT'${NC}"
    echo "Run: ./scripts/bootstrap-kind.sh"
    exit 1
fi
echo "  ✓ Cluster reachable"

# Check Crossplane
if ! kubectl get pods -n crossplane-system --context "$CONTEXT" 2>/dev/null | grep -q Running; then
    echo -e "${RED}ERROR: Crossplane not running${NC}"
    echo "Run: ./scripts/bootstrap-crossplane.sh && ./scripts/bootstrap-aws-providers.sh"
    exit 1
fi
echo "  ✓ Crossplane running"

# Check AWS credentials
if ! aws sts get-caller-identity &>/dev/null; then
    echo -e "${RED}ERROR: AWS credentials not configured${NC}"
    echo "Run: aws configure"
    exit 1
fi
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "  ✓ AWS credentials valid (account: $AWS_ACCOUNT_ID)"

# Check MessageWallRoleBoundary policy exists
if ! aws iam get-policy --policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/MessageWallRoleBoundary" &>/dev/null; then
    echo -e "${RED}ERROR: MessageWallRoleBoundary IAM policy not found${NC}"
    echo "Create it first. See docs/setup-actuator-cluster.md"
    exit 1
fi
echo "  ✓ MessageWallRoleBoundary policy exists"

echo ""

# ─────────────────────────────────────────────────────────────
# Step 1: Install XRD if not present
# ─────────────────────────────────────────────────────────────
echo -e "${YELLOW}Step 1: Install XRD${NC}"

if kubectl get xrd serverlesseventapps.messagewall.demo --context "$CONTEXT" &>/dev/null; then
    echo "  XRD already installed"
else
    echo "  Installing XRD..."
    "$SCRIPT_DIR/install-xrd.sh"
fi

echo ""

# ─────────────────────────────────────────────────────────────
# Step 2: Build Lambda artifacts
# ─────────────────────────────────────────────────────────────
echo -e "${YELLOW}Step 2: Build Lambda artifacts${NC}"

API_HANDLER_ZIP="$PROJECT_ROOT/app/api-handler/api-handler.zip"
SNAPSHOT_WRITER_ZIP="$PROJECT_ROOT/app/snapshot-writer/snapshot-writer.zip"

if [[ -f "$API_HANDLER_ZIP" ]]; then
    echo "  api-handler.zip exists"
else
    echo "  Building api-handler..."
    (cd "$PROJECT_ROOT/app/api-handler" && ./build.sh)
fi

if [[ -f "$SNAPSHOT_WRITER_ZIP" ]]; then
    echo "  snapshot-writer.zip exists"
else
    echo "  Building snapshot-writer..."
    (cd "$PROJECT_ROOT/app/snapshot-writer" && ./build.sh)
fi

echo ""

# ─────────────────────────────────────────────────────────────
# Step 3: Apply Claim (creates S3 bucket and other resources)
# ─────────────────────────────────────────────────────────────
echo -e "${YELLOW}Step 3: Apply Claim${NC}"

CLAIM_NAME="${RESOURCE_PREFIX}-${ENVIRONMENT}"
BUCKET_NAME="${RESOURCE_PREFIX}-${ENVIRONMENT}-${AWS_ACCOUNT_ID}"

# Create Claim with correct AWS account ID
cat <<EOF | kubectl apply --context "$CONTEXT" -f -
apiVersion: messagewall.demo/v1alpha1
kind: ServerlessEventAppClaim
metadata:
  name: ${CLAIM_NAME}
  namespace: default
spec:
  environment: ${ENVIRONMENT}
  awsAccountId: "${AWS_ACCOUNT_ID}"
  resourcePrefix: ${RESOURCE_PREFIX}
  region: us-east-1
  lambdaMemory: 128
  lambdaTimeout: 10
EOF

echo "  Claim '${CLAIM_NAME}' applied"
echo ""

# ─────────────────────────────────────────────────────────────
# Step 4: Wait for S3 bucket to be ready, then upload artifacts
# ─────────────────────────────────────────────────────────────
echo -e "${YELLOW}Step 4: Upload Lambda artifacts${NC}"

echo "  Waiting for S3 bucket to be ready..."
for i in {1..60}; do
    if aws s3 ls "s3://${BUCKET_NAME}" &>/dev/null; then
        echo "  ✓ Bucket ready: ${BUCKET_NAME}"
        break
    fi
    if [[ $i -eq 60 ]]; then
        echo -e "${RED}ERROR: Timeout waiting for S3 bucket${NC}"
        echo "Check Crossplane status: kubectl get managed --context $CONTEXT"
        exit 1
    fi
    sleep 5
done

echo "  Uploading artifacts..."
aws s3 cp "$API_HANDLER_ZIP" "s3://${BUCKET_NAME}/artifacts/api-handler.zip"
aws s3 cp "$SNAPSHOT_WRITER_ZIP" "s3://${BUCKET_NAME}/artifacts/snapshot-writer.zip"
echo "  ✓ Artifacts uploaded"

echo ""

# ─────────────────────────────────────────────────────────────
# Step 5: Wait for all resources to be ready
# ─────────────────────────────────────────────────────────────
echo -e "${YELLOW}Step 5: Wait for all resources${NC}"

echo "  Waiting for Claim to be ready (up to 5 minutes)..."
for i in {1..60}; do
    READY=$(kubectl get serverlesseventappclaim "${CLAIM_NAME}" --context "$CONTEXT" \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")

    if [[ "$READY" == "True" ]]; then
        echo -e "  ${GREEN}✓ All resources ready!${NC}"
        break
    fi

    if [[ $i -eq 60 ]]; then
        echo -e "${YELLOW}Warning: Claim not fully ready after 5 minutes${NC}"
        echo "Check status: kubectl get managed --context $CONTEXT"
    fi

    # Show progress
    RESOURCE_COUNT=$(kubectl get managed --context "$CONTEXT" -l "crossplane.io/claim-name=${CLAIM_NAME}" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    READY_COUNT=$(kubectl get managed --context "$CONTEXT" -l "crossplane.io/claim-name=${CLAIM_NAME}" --no-headers 2>/dev/null | grep -c "True.*True" || echo "0")
    echo "  Resources: ${READY_COUNT}/${RESOURCE_COUNT} ready..."
    sleep 5
done

echo ""

# ─────────────────────────────────────────────────────────────
# Step 6: Show endpoints
# ─────────────────────────────────────────────────────────────
echo -e "${YELLOW}Step 6: Deployment complete${NC}"

API_ENDPOINT=$(kubectl get serverlesseventappclaim "${CLAIM_NAME}" --context "$CONTEXT" \
    -o jsonpath='{.status.apiEndpoint}' 2>/dev/null || echo "pending...")
WEBSITE_ENDPOINT=$(kubectl get serverlesseventappclaim "${CLAIM_NAME}" --context "$CONTEXT" \
    -o jsonpath='{.status.websiteEndpoint}' 2>/dev/null || echo "pending...")

echo ""
echo "═══════════════════════════════════════════════════════"
echo -e "${GREEN}DEPLOYMENT COMPLETE${NC}"
echo "═══════════════════════════════════════════════════════"
echo ""
echo "Claim:    ${CLAIM_NAME}"
echo "API:      ${API_ENDPOINT}"
echo "Website:  ${WEBSITE_ENDPOINT}"
echo ""
echo "View resources:"
echo "  kubectl get managed --context $CONTEXT"
echo "  kubectl get serverlesseventappclaim ${CLAIM_NAME} --context $CONTEXT -o yaml"
echo ""
echo "Test the API:"
echo "  curl -X POST ${API_ENDPOINT} -d '{\"message\": \"Hello!\"}'"
echo ""
