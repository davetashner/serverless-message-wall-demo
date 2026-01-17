#!/bin/bash
# Test ServerlessEventApp XRD
#
# This script provides three test modes:
#   - unit: Uses crossplane beta render to verify Composition output
#   - integration: Applies Claim and verifies resources are created
#   - smoke: Posts a message and verifies state.json updates
#
# Usage:
#   ./scripts/test-xrd.sh unit          # Run unit tests only
#   ./scripts/test-xrd.sh integration   # Run integration tests
#   ./scripts/test-xrd.sh smoke         # Run smoke tests
#   ./scripts/test-xrd.sh all           # Run all tests (default)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Test mode from argument
TEST_MODE="${1:-all}"

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

pass() {
    echo -e "${GREEN}PASS${NC}: $1"
    ((TESTS_PASSED++))
}

fail() {
    echo -e "${RED}FAIL${NC}: $1"
    ((TESTS_FAILED++))
}

skip() {
    echo -e "${YELLOW}SKIP${NC}: $1"
}

run_test() {
    local test_name="$1"
    local test_cmd="$2"
    ((TESTS_RUN++))

    if eval "$test_cmd" >/dev/null 2>&1; then
        pass "$test_name"
        return 0
    else
        fail "$test_name"
        return 1
    fi
}

# ============================================================
# UNIT TESTS
# Uses crossplane beta render to verify Composition output
# ============================================================
run_unit_tests() {
    echo ""
    echo "==> Running unit tests..."

    # Check if crossplane CLI is available
    if ! command -v crossplane &> /dev/null; then
        skip "crossplane CLI not found - skipping render tests"
        return 0
    fi

    # Create a test composite resource
    local test_xr=$(mktemp)
    cat > "$test_xr" << 'EOF'
apiVersion: messagewall.demo/v1alpha1
kind: ServerlessEventApp
metadata:
  name: test-render
spec:
  environment: dev
  awsAccountId: "123456789012"
  resourcePrefix: messagewall
  region: us-east-1
  lambdaMemory: 128
  lambdaTimeout: 10
  eventSource: messagewall.api-handler
EOF

    # Run crossplane render
    local render_output=$(mktemp)
    if crossplane beta render "$test_xr" \
        "$PROJECT_ROOT/platform/crossplane/compositions/serverless-event-app-aws.yaml" \
        "$PROJECT_ROOT/platform/crossplane/functions/function-patch-and-transform.yaml" \
        > "$render_output" 2>&1; then

        # Test: Render produces output
        if [ -s "$render_output" ]; then
            pass "Composition renders successfully"
        else
            fail "Composition render produced no output"
        fi

        # Test: S3 Bucket is in output
        if grep -q "kind: Bucket" "$render_output"; then
            pass "S3 Bucket is composed"
        else
            fail "S3 Bucket not found in render output"
        fi

        # Test: DynamoDB Table is in output
        if grep -q "kind: Table" "$render_output"; then
            pass "DynamoDB Table is composed"
        else
            fail "DynamoDB Table not found in render output"
        fi

        # Test: Lambda Functions are in output
        local lambda_count=$(grep -c "kind: Function" "$render_output" 2>/dev/null || echo "0")
        if [ "$lambda_count" -ge 2 ]; then
            pass "Lambda Functions are composed (found $lambda_count)"
        else
            fail "Expected at least 2 Lambda Functions, found $lambda_count"
        fi

        # Test: IAM Roles are in output
        local role_count=$(grep -c "kind: Role" "$render_output" 2>/dev/null || echo "0")
        if [ "$role_count" -ge 2 ]; then
            pass "IAM Roles are composed (found $role_count)"
        else
            fail "Expected at least 2 IAM Roles, found $role_count"
        fi

        # Test: FunctionURL is in output
        if grep -q "kind: FunctionURL" "$render_output"; then
            pass "Lambda FunctionURL is composed"
        else
            fail "Lambda FunctionURL not found in render output"
        fi

        # Test: EventBridge resources are in output
        if grep -q "kind: Rule" "$render_output" && grep -q "kind: Target" "$render_output"; then
            pass "EventBridge resources are composed"
        else
            fail "EventBridge resources not found in render output"
        fi

    else
        fail "Composition render failed"
        cat "$render_output"
    fi

    rm -f "$test_xr" "$render_output"
}

# ============================================================
# INTEGRATION TESTS
# Applies Claim and verifies resources are created
# ============================================================
run_integration_tests() {
    echo ""
    echo "==> Running integration tests..."

    # Check if kubectl is configured
    if ! kubectl cluster-info &>/dev/null; then
        skip "kubectl not configured - skipping integration tests"
        return 0
    fi

    # Check if XRD is installed
    if ! kubectl get xrd serverlesseventapps.messagewall.demo &>/dev/null; then
        skip "XRD not installed - run install-xrd.sh first"
        return 0
    fi

    # Test: XRD is established
    run_test "XRD is established" \
        "kubectl get xrd serverlesseventapps.messagewall.demo -o jsonpath='{.status.conditions[?(@.type==\"Established\")].status}' | grep -q True"

    # Test: Composition exists
    run_test "Composition exists" \
        "kubectl get composition serverlesseventapp-aws"

    # Test: Function is healthy
    run_test "Function is healthy" \
        "kubectl get function function-patch-and-transform -o jsonpath='{.status.conditions[?(@.type==\"Healthy\")].status}' | grep -q True"

    # Check if there's an existing claim to test status
    if kubectl get serverlesseventappclaim messagewall-dev -n default &>/dev/null; then
        echo "--> Testing existing Claim..."

        # Test: Claim exists and has status
        run_test "Claim has status" \
            "kubectl get serverlesseventappclaim messagewall-dev -n default -o jsonpath='{.status}' | grep -q ."

        # Test: Managed resources exist
        local managed_count=$(kubectl get managed -l crossplane.io/claim-name=messagewall-dev 2>/dev/null | wc -l || echo "0")
        if [ "$managed_count" -gt 1 ]; then
            pass "Managed resources created (found $((managed_count - 1)))"
        else
            fail "No managed resources found for Claim"
        fi
    else
        skip "No existing Claim found - apply examples/claims/messagewall-dev.yaml to test"
    fi
}

# ============================================================
# SMOKE TESTS
# Posts a message and verifies state.json updates
# ============================================================
run_smoke_tests() {
    echo ""
    echo "==> Running smoke tests..."

    # Check if kubectl is configured
    if ! kubectl cluster-info &>/dev/null; then
        skip "kubectl not configured - skipping smoke tests"
        return 0
    fi

    # Get API endpoint from Claim status
    local api_endpoint=$(kubectl get serverlesseventappclaim messagewall-dev -n default \
        -o jsonpath='{.status.apiEndpoint}' 2>/dev/null || echo "")

    if [ -z "$api_endpoint" ]; then
        skip "API endpoint not available - Claim may not be ready"
        return 0
    fi

    # Get website endpoint from Claim status
    local website_endpoint=$(kubectl get serverlesseventappclaim messagewall-dev -n default \
        -o jsonpath='{.status.websiteEndpoint}' 2>/dev/null || echo "")

    if [ -z "$website_endpoint" ]; then
        skip "Website endpoint not available - Claim may not be ready"
        return 0
    fi

    echo "--> API endpoint: $api_endpoint"
    echo "--> Website endpoint: $website_endpoint"

    # Test: POST a message
    local test_message="XRD test message $(date +%s)"
    local post_response=$(curl -s -X POST "$api_endpoint" \
        -H "Content-Type: application/json" \
        -d "{\"text\": \"$test_message\"}" 2>&1)

    if echo "$post_response" | grep -q "success\|created\|ok" -i; then
        pass "POST message succeeded"
    else
        fail "POST message failed: $post_response"
    fi

    # Wait a moment for EventBridge to trigger snapshot
    echo "--> Waiting for snapshot update..."
    sleep 3

    # Test: GET state.json contains the message
    local state_json=$(curl -s "${website_endpoint}/state.json" 2>&1)
    if echo "$state_json" | grep -q "$test_message"; then
        pass "state.json updated with new message"
    else
        # May need more time
        sleep 5
        state_json=$(curl -s "${website_endpoint}/state.json" 2>&1)
        if echo "$state_json" | grep -q "$test_message"; then
            pass "state.json updated with new message (delayed)"
        else
            fail "Message not found in state.json"
        fi
    fi
}

# ============================================================
# MAIN
# ============================================================
main() {
    echo "================================================"
    echo "ServerlessEventApp XRD Test Suite"
    echo "================================================"

    case "$TEST_MODE" in
        unit)
            run_unit_tests
            ;;
        integration)
            run_integration_tests
            ;;
        smoke)
            run_smoke_tests
            ;;
        all)
            run_unit_tests
            run_integration_tests
            run_smoke_tests
            ;;
        *)
            echo "Unknown test mode: $TEST_MODE"
            echo "Usage: $0 [unit|integration|smoke|all]"
            exit 1
            ;;
    esac

    echo ""
    echo "================================================"
    echo "Test Summary"
    echo "================================================"
    echo "Tests run:    $TESTS_RUN"
    echo -e "Tests passed: ${GREEN}$TESTS_PASSED${NC}"
    echo -e "Tests failed: ${RED}$TESTS_FAILED${NC}"
    echo ""

    if [ "$TESTS_FAILED" -gt 0 ]; then
        echo -e "${RED}Some tests failed!${NC}"
        exit 1
    else
        echo -e "${GREEN}All tests passed!${NC}"
        exit 0
    fi
}

main "$@"
