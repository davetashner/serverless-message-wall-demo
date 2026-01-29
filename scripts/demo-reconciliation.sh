#!/bin/bash
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

print_header() {
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

print_step() {
    echo ""
    echo -e "${GREEN}▶ $1${NC}"
}

print_narrator() {
    echo -e "${YELLOW}   $1${NC}"
}

print_warning() {
    echo -e "${RED}⚠ $1${NC}"
}

pause() {
    echo ""
    read -p "Press Enter to continue..."
}

CONTEXT="kind-actuator"

cat <<'EOF'

╔═══════════════════════════════════════════════════════════════════╗
║           CROSSPLANE RECONCILIATION DEMO                          ║
║                                                                   ║
║  This demo shows Crossplane's self-healing capability:            ║
║                                                                   ║
║    1. Show a Lambda function managed by Crossplane                ║
║    2. Delete the Lambda directly in AWS (simulating drift)        ║
║    3. Watch Crossplane detect and recreate the Lambda             ║
║                                                                   ║
║  "The desired state in ConfigHub ALWAYS wins."                    ║
╚═══════════════════════════════════════════════════════════════════╝

EOF

pause

print_header "STEP 1: Check Crossplane Status"

print_step "kubectl get managed --context ${CONTEXT}"
kubectl get managed --context "${CONTEXT}" 2>/dev/null || {
    echo ""
    print_warning "No Crossplane managed resources found."
    echo ""
    echo "This demo requires:"
    echo "  1. Crossplane installed (scripts/bootstrap-crossplane.sh)"
    echo "  2. AWS providers installed (scripts/bootstrap-aws-providers.sh)"
    echo "  3. Infrastructure deployed (scripts/deploy-dev.sh)"
    echo ""
    exit 1
}

pause

print_header "STEP 2: Find a Lambda to Delete"

print_step "kubectl get function.lambda.aws.upbound.io --context ${CONTEXT}"
LAMBDA_RESOURCES=$(kubectl get function.lambda.aws.upbound.io --context "${CONTEXT}" -o name 2>/dev/null)

if [[ -z "${LAMBDA_RESOURCES}" ]]; then
    print_warning "No Lambda functions found managed by Crossplane."
    echo ""
    echo "Deploy infrastructure first: scripts/deploy-dev.sh"
    exit 1
fi

echo "${LAMBDA_RESOURCES}"

# Get the first Lambda name
LAMBDA_NAME=$(echo "${LAMBDA_RESOURCES}" | head -1 | sed 's|function.lambda.aws.upbound.io/||')
echo ""
print_narrator "We'll delete: ${LAMBDA_NAME}"

pause

print_header "STEP 3: Get AWS Lambda Function Name"

print_step "kubectl get function.lambda.aws.upbound.io/${LAMBDA_NAME} -o jsonpath='{.status.atProvider.functionName}' --context ${CONTEXT}"
AWS_FUNCTION_NAME=$(kubectl get "function.lambda.aws.upbound.io/${LAMBDA_NAME}" -o jsonpath='{.status.atProvider.functionName}' --context "${CONTEXT}" 2>/dev/null)

if [[ -z "${AWS_FUNCTION_NAME}" ]]; then
    print_warning "Could not get AWS function name from status."
    echo "The Lambda may not be fully synced yet."
    exit 1
fi

echo "${AWS_FUNCTION_NAME}"
print_narrator "This is the actual AWS Lambda function name"

pause

print_header "STEP 4: Verify Lambda Exists in AWS"

print_step "aws lambda get-function --function-name ${AWS_FUNCTION_NAME}"
aws lambda get-function --function-name "${AWS_FUNCTION_NAME}" --query 'Configuration.{FunctionName:FunctionName,Runtime:Runtime,State:State}' --output table 2>/dev/null || {
    print_warning "Lambda not found in AWS. It may have been deleted already."
    echo ""
    echo "Check Crossplane status:"
    echo "  kubectl describe function.lambda.aws.upbound.io/${LAMBDA_NAME} --context ${CONTEXT}"
    exit 1
}

pause

print_header "STEP 5: DELETE THE LAMBDA (Simulating Drift)"

print_warning "This will delete the Lambda function directly in AWS!"
print_narrator "This simulates an out-of-band change that Crossplane will detect."
echo ""

read -p "Delete Lambda '${AWS_FUNCTION_NAME}' from AWS? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi

print_step "aws lambda delete-function --function-name ${AWS_FUNCTION_NAME}"
aws lambda delete-function --function-name "${AWS_FUNCTION_NAME}"

echo ""
print_narrator "Lambda deleted from AWS!"

pause

print_header "STEP 6: Verify Lambda is Gone"

print_step "aws lambda get-function --function-name ${AWS_FUNCTION_NAME}"
aws lambda get-function --function-name "${AWS_FUNCTION_NAME}" 2>&1 || true

print_narrator "Expected: ResourceNotFoundException - the Lambda is gone"

pause

print_header "STEP 7: Watch Crossplane Reconcile"

print_narrator "Crossplane runs a reconciliation loop every ~60 seconds"
print_narrator "It will detect the missing Lambda and recreate it"
echo ""

print_step "Watch the Crossplane resource status:"
echo ""
echo "  kubectl get function.lambda.aws.upbound.io/${LAMBDA_NAME} -w --context ${CONTEXT}"
echo ""
echo "Look for:"
echo "  - SYNCED=False (drift detected)"
echo "  - SYNCED=True, READY=True (recreated)"
echo ""

read -p "Watch resource status? (y/N) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    print_step "kubectl get function.lambda.aws.upbound.io/${LAMBDA_NAME} -w --context ${CONTEXT}"
    echo ""
    echo "(Ctrl+C to stop watching)"
    timeout 120 kubectl get "function.lambda.aws.upbound.io/${LAMBDA_NAME}" -w --context "${CONTEXT}" 2>/dev/null || true
fi

pause

print_header "STEP 8: Verify Lambda Recreated in AWS"

print_step "aws lambda get-function --function-name ${AWS_FUNCTION_NAME}"
aws lambda get-function --function-name "${AWS_FUNCTION_NAME}" --query 'Configuration.{FunctionName:FunctionName,Runtime:Runtime,State:State}' --output table 2>/dev/null && {
    echo ""
    print_narrator "SUCCESS! Crossplane recreated the Lambda automatically."
} || {
    print_warning "Lambda not yet recreated."
    echo ""
    echo "Crossplane reconciliation may take 1-2 minutes."
    echo "Check status with:"
    echo "  kubectl describe function.lambda.aws.upbound.io/${LAMBDA_NAME} --context ${CONTEXT}"
}

pause

print_header "DEMO COMPLETE"

cat <<'EOF'

Key Takeaways:

  1. DESIRED STATE ALWAYS WINS
     - ConfigHub holds the authoritative configuration
     - Crossplane continuously reconciles AWS to match

  2. SELF-HEALING INFRASTRUCTURE
     - Out-of-band changes are automatically reverted
     - No manual intervention required

  3. AUDIT TRAIL PRESERVED
     - Crossplane events show when drift was detected
     - ConfigHub tracks all configuration changes

  4. THIS IS GITOPS FOR INFRASTRUCTURE
     - Declare what you want, not how to get there
     - The system converges to desired state

Commands to explore:
  kubectl describe function.lambda.aws.upbound.io/${LAMBDA_NAME} --context ${CONTEXT}
  kubectl get events --field-selector involvedObject.name=${LAMBDA_NAME} --context ${CONTEXT}

EOF

# Substitute the actual Lambda name in the output
echo ""
echo "Lambda used in this demo: ${LAMBDA_NAME}"
echo "AWS function name: ${AWS_FUNCTION_NAME}"
