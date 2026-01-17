#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

VERBOSE=false
ERRORS=0

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Validate AWS credentials, permissions, and resource availability for the messagewall demo."
    echo ""
    echo "Options:"
    echo "  -v, --verbose    Show detailed output and permission tests"
    echo "  -h, --help       Show this help message"
}

log_pass() {
    echo -e "${GREEN}✓${NC} $1"
}

log_fail() {
    echo -e "${RED}✗${NC} $1"
    ((ERRORS++)) || true
}

log_warn() {
    echo -e "${YELLOW}!${NC} $1"
}

log_info() {
    echo "  $1"
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

echo "Validating AWS configuration for messagewall demo..."
echo ""

# Check AWS CLI is installed
echo "Checking prerequisites..."
if ! command -v aws &> /dev/null; then
    log_fail "AWS CLI is not installed. Install with: brew install awscli"
    exit 1
fi
log_pass "AWS CLI is installed"

# Check AWS credentials
echo ""
echo "Checking AWS credentials..."
if ! CALLER_IDENTITY=$(aws sts get-caller-identity 2>&1); then
    log_fail "AWS credentials not configured or invalid"
    log_info "Configure with: aws configure"
    log_info "Or set AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY environment variables"
    exit 1
fi
log_pass "AWS credentials are valid"

# Extract account ID and identity
ACCOUNT_ID=$(echo "$CALLER_IDENTITY" | jq -r '.Account')
USER_ARN=$(echo "$CALLER_IDENTITY" | jq -r '.Arn')
log_info "Account ID: $ACCOUNT_ID"
log_info "Identity: $USER_ARN"

# Check region
AWS_REGION=${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}
log_info "Region: $AWS_REGION"

if [[ "$AWS_REGION" != "us-east-1" ]]; then
    log_warn "Region is not us-east-1. The demo is configured for us-east-1 (see ADR-001)."
fi

# Check permission boundary policy exists
echo ""
echo "Checking IAM resources..."
BOUNDARY_POLICY_NAME="MessageWallRoleBoundary"
BOUNDARY_POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${BOUNDARY_POLICY_NAME}"

if aws iam get-policy --policy-arn "$BOUNDARY_POLICY_ARN" &> /dev/null; then
    log_pass "Permission boundary policy exists: $BOUNDARY_POLICY_NAME"
else
    log_fail "Permission boundary policy not found: $BOUNDARY_POLICY_NAME"
    log_info "Create it with:"
    log_info "  aws iam create-policy \\"
    log_info "    --policy-name $BOUNDARY_POLICY_NAME \\"
    log_info "    --policy-document file://${PROJECT_ROOT}/platform/iam/messagewall-role-boundary.json"
fi

# Check crossplane-actuator user exists
CROSSPLANE_USER="crossplane-actuator"
if aws iam get-user --user-name "$CROSSPLANE_USER" &> /dev/null; then
    log_pass "Crossplane user exists: $CROSSPLANE_USER"
else
    log_fail "Crossplane user not found: $CROSSPLANE_USER"
    log_info "Create it with: aws iam create-user --user-name $CROSSPLANE_USER"
fi

# Check if CrossplaneActuatorPolicy is attached
ACTUATOR_POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/CrossplaneActuatorPolicy"
if aws iam get-policy --policy-arn "$ACTUATOR_POLICY_ARN" &> /dev/null; then
    log_pass "Crossplane actuator policy exists: CrossplaneActuatorPolicy"

    # Check if policy is attached to user
    ATTACHED_POLICIES=$(aws iam list-attached-user-policies --user-name "$CROSSPLANE_USER" 2>/dev/null || echo '{"AttachedPolicies":[]}')
    if echo "$ATTACHED_POLICIES" | jq -e ".AttachedPolicies[] | select(.PolicyArn == \"$ACTUATOR_POLICY_ARN\")" &> /dev/null; then
        log_pass "Policy is attached to $CROSSPLANE_USER"
    else
        log_fail "CrossplaneActuatorPolicy is not attached to $CROSSPLANE_USER"
        log_info "Attach it with:"
        log_info "  aws iam attach-user-policy \\"
        log_info "    --user-name $CROSSPLANE_USER \\"
        log_info "    --policy-arn $ACTUATOR_POLICY_ARN"
    fi
else
    log_fail "Crossplane actuator policy not found: CrossplaneActuatorPolicy"
    log_info "Create it with:"
    log_info "  aws iam create-policy \\"
    log_info "    --policy-name CrossplaneActuatorPolicy \\"
    log_info "    --policy-document file://${PROJECT_ROOT}/platform/iam/crossplane-actuator-policy.json"
fi

# Check for access keys
if aws iam list-access-keys --user-name "$CROSSPLANE_USER" 2>/dev/null | jq -e '.AccessKeyMetadata | length > 0' &> /dev/null; then
    log_pass "Access keys exist for $CROSSPLANE_USER"
else
    log_warn "No access keys found for $CROSSPLANE_USER"
    log_info "Create with: aws iam create-access-key --user-name $CROSSPLANE_USER"
fi

# Verbose permission checks
if [[ "$VERBOSE" == "true" ]]; then
    echo ""
    echo "Testing resource access (dry-run)..."

    # Test S3 permissions - looking for 404 (not found) or 403 (forbidden) means we can query
    S3_RESULT=$(aws s3api head-bucket --bucket "messagewall-test-nonexistent-bucket" 2>&1 || true)
    if echo "$S3_RESULT" | grep -qiE "Not Found|404|NoSuchBucket"; then
        log_pass "S3: Can query buckets (bucket not found as expected)"
    elif echo "$S3_RESULT" | grep -qiE "Forbidden|403|AccessDenied"; then
        log_pass "S3: Can query buckets (access denied for non-messagewall bucket)"
    else
        log_info "S3: Response - ${S3_RESULT:-no output}"
    fi

    # Test DynamoDB permissions
    DYNAMO_RESULT=$(aws dynamodb describe-table --table-name "messagewall-nonexistent" --region "$AWS_REGION" 2>&1 || true)
    if echo "$DYNAMO_RESULT" | grep -qiE "ResourceNotFoundException|not found|does not exist"; then
        log_pass "DynamoDB: Can query tables (table not found as expected)"
    elif echo "$DYNAMO_RESULT" | grep -qiE "AccessDenied"; then
        log_warn "DynamoDB: Access denied (check IAM permissions)"
    else
        log_info "DynamoDB: Response - ${DYNAMO_RESULT:-no output}"
    fi

    # Test Lambda permissions
    LAMBDA_RESULT=$(aws lambda get-function --function-name "messagewall-nonexistent" --region "$AWS_REGION" 2>&1 || true)
    if echo "$LAMBDA_RESULT" | grep -qiE "ResourceNotFoundException|Function not found"; then
        log_pass "Lambda: Can query functions (function not found as expected)"
    elif echo "$LAMBDA_RESULT" | grep -qiE "AccessDenied"; then
        log_warn "Lambda: Access denied (check IAM permissions)"
    else
        log_info "Lambda: Response - ${LAMBDA_RESULT:-no output}"
    fi

    # Test EventBridge permissions
    EVENTS_RESULT=$(aws events describe-rule --name "messagewall-nonexistent" --region "$AWS_REGION" 2>&1 || true)
    if echo "$EVENTS_RESULT" | grep -qiE "ResourceNotFoundException|Rule .* does not exist"; then
        log_pass "EventBridge: Can query rules (rule not found as expected)"
    elif echo "$EVENTS_RESULT" | grep -qiE "AccessDenied"; then
        log_warn "EventBridge: Access denied (check IAM permissions)"
    else
        log_info "EventBridge: Response - ${EVENTS_RESULT:-no output}"
    fi
fi

# Summary
echo ""
echo "----------------------------------------"
if [[ $ERRORS -eq 0 ]]; then
    echo -e "${GREEN}All checks passed!${NC}"
    echo ""
    echo "Your AWS environment is configured for the messagewall demo."
    echo "Next step: Store credentials in Kubernetes secret after cluster creation"
    echo ""
    echo "  kubectl create secret generic aws-credentials \\"
    echo "    --namespace crossplane-system \\"
    echo "    --from-literal=credentials=\"[default]"
    echo "aws_access_key_id = <ACCESS_KEY>"
    echo "aws_secret_access_key = <SECRET_KEY>\""
else
    echo -e "${RED}Found $ERRORS issue(s) that need to be resolved.${NC}"
    echo ""
    echo "See the setup guide for details: docs/setup-actuator-cluster.md"
    exit 1
fi
